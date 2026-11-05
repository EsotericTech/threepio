// The OTLP/HTTP exporter against a fake HTTP client. Time is fake: the flush
// interval and the retry waits are stepped through, never waited for.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/schema.dart' show ThreepioException;

import '../../support/log_capture.dart';

final _endpoint = Uri.parse('https://collector.test/v1/traces');

OtlpSpan _span(String name, {String? traceId, Map<String, Object?>? attributes}) =>
    OtlpSpan(
      traceId: traceId ?? 'a' * 32,
      spanId: 'b' * 16,
      name: name,
      startTime: DateTime.utc(2026),
      endTime: DateTime.utc(2026, 1, 1, 0, 0, 1),
      attributes: attributes ?? const {},
    );

/// What the collector received, and what it answers.
final class _Collector {
  _Collector([this.answer]);

  /// Answers request number `n` (from 1). Defaults to `200 {}`.
  FutureOr<http.Response> Function(int n, http.Request request)? answer;

  final List<http.Request> requests = [];
  bool closed = false;

  late final http.Client client = _ClosableClient(this);

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final answer = this.answer;
    return answer == null
        ? http.Response('{}', 200)
        : await answer(requests.length, request);
  }

  /// The span names of every request.
  List<List<String>> get batches => [
        for (final request in requests) _spanNames(request.body),
      ];

  static List<String> _spanNames(String body) {
    final spans = _spansOf(body);
    return [for (final span in spans) (span as Map)['name'] as String];
  }

  static List<Object?> _spansOf(String body) {
    final decoded = jsonDecode(body) as Map<String, Object?>;
    final resource = (decoded['resourceSpans']! as List).single as Map;
    final scope = (resource['scopeSpans'] as List).single as Map;
    return scope['spans'] as List;
  }
}

final class _ClosableClient extends MockClient {
  _ClosableClient(this._collector) : super(_collector.handle);

  final _Collector _collector;

  @override
  void close() {
    _collector.closed = true;
    super.close();
  }
}

OtlpExporterConfig _config({
  int maxQueueSize = 100,
  int maxExportBatchSize = 10,
  Duration batchTimeout = const Duration(seconds: 5),
  Duration timeout = const Duration(seconds: 10),
  OtlpRetryConfig retry = OtlpRetryConfig.none,
  double sampleRate = 1,
  String Function(String)? mask,
  Map<String, String> headers = const {},
}) =>
    OtlpExporterConfig(
      endpoint: _endpoint,
      headers: headers,
      serviceName: 'test-service',
      resourceAttributes: const {'deployment': 'test'},
      scopeName: 'test-scope',
      scopeVersion: '9.9.9',
      timeout: timeout,
      maxQueueSize: maxQueueSize,
      maxExportBatchSize: maxExportBatchSize,
      batchTimeout: batchTimeout,
      retry: retry,
      sampleRate: sampleRate,
      mask: mask,
    );

void main() {
  group('request', () {
    test('a flush posts the queued spans as OTLP JSON', () async {
      final collector = _Collector();
      final exporter = OtlpHttpTraceExporter(
        _config(headers: {'Authorization': 'Bearer t'}),
        httpClient: collector.client,
      );

      expect(exporter.add(_span('one', attributes: const {'k': 'v'})), isTrue);
      expect(exporter.add(_span('two')), isTrue);
      expect(exporter.queued, 2);
      await exporter.flush();

      final request = collector.requests.single;
      expect(request.method, 'POST');
      expect(request.url, _endpoint);
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(request.headers['Authorization'], 'Bearer t');

      final body = jsonDecode(request.body) as Map<String, Object?>;
      final resourceSpans = (body['resourceSpans']! as List).single as Map;
      expect((resourceSpans['resource'] as Map)['attributes'], [
        {
          'key': 'service.name',
          'value': {'stringValue': 'test-service'},
        },
        {
          'key': 'deployment',
          'value': {'stringValue': 'test'},
        },
      ]);
      final scopeSpans = (resourceSpans['scopeSpans'] as List).single as Map;
      expect(scopeSpans['scope'], {'name': 'test-scope', 'version': '9.9.9'});
      expect(collector.batches, [
        ['one', 'two'],
      ]);
      expect(exporter.queued, 0);
      expect(exporter.discarded, isEmpty);
      await exporter.shutdown();
    });

    test('a flush with nothing queued sends nothing', () async {
      final collector = _Collector();
      final exporter = OtlpHttpTraceExporter(_config(), httpClient: collector.client);
      await exporter.flush();
      await exporter.flush();
      expect(collector.requests, isEmpty);
      await exporter.shutdown();
    });
  });

  group('batching', () {
    test('a full batch is sent at once, the rest waits for the interval', () {
      fakeAsync((async) {
        final collector = _Collector();
        final exporter = OtlpHttpTraceExporter(
          _config(maxExportBatchSize: 3),
          httpClient: collector.client,
        );

        for (var i = 1; i <= 7; i++) {
          exporter.add(_span('s$i'));
        }
        async.flushMicrotasks();
        expect(collector.batches, [
          ['s1', 's2', 's3'],
          ['s4', 's5', 's6'],
        ]);
        expect(exporter.queued, 1);

        async.elapse(const Duration(seconds: 4));
        expect(collector.requests, hasLength(2));
        async.elapse(const Duration(seconds: 1));
        expect(collector.batches.last, ['s7']);
        expect(exporter.queued, 0);
        expect(async.pendingTimers, isEmpty, reason: 'an idle exporter has no timer');
      });
    });

    test('a span is sent after the flush interval at the latest', () {
      fakeAsync((async) {
        final collector = _Collector();
        final exporter = OtlpHttpTraceExporter(
          _config(batchTimeout: const Duration(seconds: 2)),
          httpClient: collector.client,
        );

        exporter.add(_span('first'));
        async.elapse(const Duration(milliseconds: 1500));
        exporter.add(_span('second'));
        expect(collector.requests, isEmpty);

        async.elapse(const Duration(milliseconds: 500));
        expect(collector.batches, [
          ['first', 'second'],
        ]);

        exporter.add(_span('third'));
        async.elapse(const Duration(seconds: 2));
        expect(collector.batches.last, ['third']);
      });
    });

    test('an explicit flush does not wait for the interval', () {
      fakeAsync((async) {
        final collector = _Collector();
        final exporter = OtlpHttpTraceExporter(_config(), httpClient: collector.client);
        var flushed = false;

        exporter.add(_span('now'));
        unawaited(exporter.flush().then((_) => flushed = true));
        async.flushMicrotasks();

        expect(flushed, isTrue);
        expect(collector.batches, [
          ['now'],
        ]);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('one request at a time; spans that arrive meanwhile follow', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        final collector = _Collector((n, request) async {
          if (n == 1) await gate.future;
          return http.Response('{}', 200);
        });
        final exporter = OtlpHttpTraceExporter(
          _config(maxExportBatchSize: 2),
          httpClient: collector.client,
        );

        exporter
          ..add(_span('a'))
          ..add(_span('b'));
        async.flushMicrotasks();
        exporter
          ..add(_span('c'))
          ..add(_span('d'))
          ..add(_span('e'));
        async.flushMicrotasks();
        expect(collector.requests, hasLength(1), reason: 'the first is in flight');

        var flushed = false;
        unawaited(exporter.flush().then((_) => flushed = true));
        async.flushMicrotasks();
        expect(flushed, isFalse);

        gate.complete();
        async.flushMicrotasks();
        expect(flushed, isTrue);
        expect(collector.batches, [
          ['a', 'b'],
          ['c', 'd'],
          ['e'],
        ]);
      });
    });
  });

  group('retry', () {
    const retry = OtlpRetryConfig(
      initialInterval: Duration(seconds: 2),
      maxInterval: Duration(seconds: 5),
      maxElapsedTime: Duration(seconds: 30),
      multiplier: 2,
    );

    test('a retryable answer is tried again after the back-off', () {
      fakeAsync((async) {
        final collector = _Collector(
          (n, request) => http.Response(n < 3 ? 'busy' : '{}', n < 3 ? 503 : 200),
        );
        final exporter = OtlpHttpTraceExporter(
          _config(retry: retry),
          httpClient: collector.client,
        );

        exporter.add(_span('s'));
        unawaited(exporter.flush());
        async.flushMicrotasks();
        expect(collector.requests, hasLength(1));

        async.elapse(const Duration(milliseconds: 1999));
        expect(collector.requests, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(collector.requests, hasLength(2));

        // The second wait is twice the first.
        async.elapse(const Duration(milliseconds: 3999));
        expect(collector.requests, hasLength(2));
        async.elapse(const Duration(milliseconds: 1));
        expect(collector.requests, hasLength(3));

        expect(collector.batches, everyElement(['s']));
        expect(exporter.discarded, isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('the wait grows to the maximum interval and no further', () {
      fakeAsync((async) {
        final times = <Duration>[];
        final collector = _Collector((n, request) {
          times.add(async.elapsed);
          return http.Response('busy', 503);
        });
        final exporter = OtlpHttpTraceExporter(
          _config(retry: retry),
          httpClient: collector.client,
        );

        exporter.add(_span('s'));
        unawaited(exporter.flush());
        async.elapse(const Duration(minutes: 2));

        // 2 s, 4 s, then 5 s each, until the waits would pass 30 s in all.
        expect(times.map((t) => t.inSeconds), [0, 2, 6, 11, 16, 21, 26]);
        expect(exporter.discarded, {OtlpHttpTraceExporter.exportFailed: 1});
      });
    });

    test('Retry-After: 0 does not turn the back-off into a tight loop', () {
      fakeAsync((async) {
        captureLogs('threepio.observability.otlp');
        final times = <Duration>[];
        final collector = _Collector((n, request) {
          times.add(async.elapsed);
          return http.Response('busy', 503, headers: {'retry-after': '0'});
        });
        final exporter = OtlpHttpTraceExporter(
          _config(retry: retry),
          httpClient: collector.client,
        );
        var flushed = false;

        exporter.add(_span('s'));
        unawaited(exporter.flush().then((_) => flushed = true));
        async.elapse(const Duration(minutes: 2));

        // The same schedule as without the header, and it ends.
        expect(times.map((t) => t.inSeconds), [0, 2, 6, 11, 16, 21, 26]);
        expect(flushed, isTrue);
        expect(exporter.discarded, {OtlpHttpTraceExporter.exportFailed: 1});
      });
    });

    test('a retry that is waiting when the exporter stops sends nothing more',
        () {
      fakeAsync((async) {
        captureLogs('threepio.observability.otlp');
        var clientsCreated = 0;
        final collector = _Collector((n, request) => http.Response('busy', 503));

        http.runWithClient(
          () {
            final exporter = OtlpHttpTraceExporter(
              _config(
                retry: const OtlpRetryConfig(
                  initialInterval: Duration(seconds: 30),
                ),
              ),
              httpClient: collector.client,
            )..add(_span('s'));
            unawaited(exporter.shutdown(timeout: const Duration(seconds: 1)));
            async.elapse(const Duration(minutes: 5));

            expect(exporter.discarded, {OtlpHttpTraceExporter.exportFailed: 1});
          },
          () {
            clientsCreated++;
            return _Collector().client;
          },
        );

        expect(collector.requests, hasLength(1));
        expect(clientsCreated, 0, reason: 'no client behind the caller\'s back');
        expect(collector.closed, isFalse);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a Retry-After that asks for more than the back-off is honoured', () {
      fakeAsync((async) {
        final collector = _Collector(
          (n, request) => n == 1
              ? http.Response('slow down', 429, headers: {'retry-after': '7'})
              : http.Response('{}', 200),
        );
        final exporter = OtlpHttpTraceExporter(
          _config(retry: retry),
          httpClient: collector.client,
        );

        exporter.add(_span('s'));
        unawaited(exporter.flush());
        async.elapse(const Duration(milliseconds: 6999));
        expect(collector.requests, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(collector.requests, hasLength(2));
      });
    });

    test('a transport error and a timeout are tried again', () {
      fakeAsync((async) {
        final never = Completer<http.Response>();
        final collector = _Collector((n, request) {
          if (n == 1) throw http.ClientException('connection reset');
          if (n == 2) return never.future;
          return http.Response('{}', 200);
        });
        final exporter = OtlpHttpTraceExporter(
          _config(retry: retry, timeout: const Duration(seconds: 3)),
          httpClient: collector.client,
        );

        exporter.add(_span('s'));
        unawaited(exporter.flush());
        async.elapse(const Duration(seconds: 2));
        expect(collector.requests, hasLength(2));
        // 3 s until the request times out, then the 4 s wait.
        async.elapse(const Duration(seconds: 7));
        expect(collector.requests, hasLength(3));
        expect(exporter.discarded, isEmpty);
      });
    });

    test('an answer that will not get better is not tried again', () {
      fakeAsync((async) {
        final logs = captureLogs('threepio.observability.otlp');
        final collector =
            _Collector((n, request) => http.Response('bad credentials', 401));
        final exporter = OtlpHttpTraceExporter(
          _config(retry: retry),
          httpClient: collector.client,
        );

        exporter
          ..add(_span('a'))
          ..add(_span('b'));
        unawaited(exporter.flush());
        async.elapse(const Duration(minutes: 1));

        expect(collector.requests, hasLength(1));
        expect(exporter.discarded, {OtlpHttpTraceExporter.exportFailed: 2});
        final record = logs.single;
        expect(record.level, Level.SEVERE);
        expect(record.message, contains('batch of 2 spans after 1 attempt'));
        expect(
          record.error,
          isA<OtlpExportException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.message, 'message', contains('bad credentials'))
              .having((e) => e, 'is a threepio exception', isA<ThreepioException>())
              .having((e) => '$e', 'toString', startsWith('OtlpExportException: ')),
        );
      });
    });

    test('without retries one failed attempt discards the batch', () {
      fakeAsync((async) {
        captureLogs('threepio.observability.otlp');
        final collector = _Collector((n, request) => http.Response('busy', 503));
        final exporter = OtlpHttpTraceExporter(_config(), httpClient: collector.client);

        exporter.add(_span('s'));
        unawaited(exporter.flush());
        async.elapse(const Duration(minutes: 1));

        expect(collector.requests, hasLength(1));
        expect(exporter.discarded, {OtlpHttpTraceExporter.exportFailed: 1});
      });
    });

    test('a failed batch does not stop the ones after it', () {
      fakeAsync((async) {
        captureLogs('threepio.observability.otlp');
        final collector = _Collector(
          (n, request) => http.Response(n == 1 ? 'no' : '{}', n == 1 ? 400 : 200),
        );
        final exporter = OtlpHttpTraceExporter(
          _config(maxExportBatchSize: 1),
          httpClient: collector.client,
        );

        exporter
          ..add(_span('lost'))
          ..add(_span('kept'));
        unawaited(exporter.flush());
        async.flushMicrotasks();

        expect(collector.batches, [
          ['lost'],
          ['kept'],
        ]);
        expect(exporter.discarded, {OtlpHttpTraceExporter.exportFailed: 1});
      });
    });

    test('the defaults are those of the OpenTelemetry exporters', () {
      const defaults = OtlpRetryConfig();
      expect(defaults.enabled, isTrue);
      expect(defaults.initialInterval, const Duration(seconds: 5));
      expect(defaults.maxInterval, const Duration(seconds: 30));
      expect(defaults.maxElapsedTime, const Duration(minutes: 1));
      expect(defaults.multiplier, 1.5);
      expect(OtlpRetryConfig.none.enabled, isFalse);
    });
  });

  group('losses', () {
    test('a full queue discards new spans and says so once', () async {
      final logs = captureLogs('threepio.observability.otlp');
      final collector = _Collector();
      final exporter = OtlpHttpTraceExporter(
        _config(maxQueueSize: 2, maxExportBatchSize: 2),
        httpClient: collector.client,
      );

      // Two fill the queue. The export they trigger only starts once the
      // code that adds spans yields, so the rest find the queue full.
      final accepted = [
        for (var i = 0; i < 5; i++) exporter.add(_span('s$i')),
      ];
      expect(accepted, [true, true, false, false, false]);
      expect(collector.requests, isEmpty, reason: 'add never sends by itself');
      await exporter.flush();

      expect(collector.batches, [
        ['s0', 's1'],
      ]);
      expect(exporter.discarded, {OtlpHttpTraceExporter.queueFull: 3});
      expect(
        logs.where((r) => r.level == Level.WARNING).map((r) => r.message),
        ['OTLP exporter discarded telemetry: queue_full_spans=3'],
      );
      await exporter.shutdown();
    });

    test('a span with an id that is not one is refused, not sent', () async {
      final logs = captureLogs('threepio.observability.otlp');
      final collector = _Collector();
      final exporter = OtlpHttpTraceExporter(_config(), httpClient: collector.client);
      OtlpSpan withIds({String? trace, String? span, String? parent}) => OtlpSpan(
            traceId: trace ?? 'a' * 32,
            spanId: span ?? 'b' * 16,
            parentSpanId: parent,
            name: 'bad',
            startTime: DateTime.utc(2026),
            endTime: DateTime.utc(2026),
          );

      expect(exporter.add(withIds(trace: 'not-a-trace-id')), isFalse);
      expect(exporter.add(withIds(trace: '0' * 32)), isFalse);
      expect(exporter.add(withIds(span: 'B' * 16)), isFalse);
      expect(exporter.add(withIds(parent: 'short')), isFalse);
      expect(exporter.add(withIds(parent: '')), isTrue, reason: 'no parent');
      expect(exporter.add(withIds(parent: 'c' * 16)), isTrue);
      expect(exporter.add(_span('good')), isTrue);
      await exporter.flush();

      expect(collector.batches, [
        ['bad', 'bad', 'good'],
      ]);
      expect(exporter.discarded, {OtlpHttpTraceExporter.invalid: 4});
      expect(logs.single.message, contains('invalid_spans=4'));
      await exporter.shutdown();
    });

    test('a trace that is not sampled is discarded whole, without a warning',
        () async {
      final logs = captureLogs('threepio.observability.otlp');
      final collector = _Collector();
      final exporter = OtlpHttpTraceExporter(
        _config(sampleRate: 0.5),
        httpClient: collector.client,
      );
      final kept = '${'0' * 16}${'0' * 16}'.replaceRange(31, 32, '1');
      final dropped = '${'0' * 16}${'f' * 16}';

      expect(exporter.add(_span('kept-1', traceId: kept)), isTrue);
      expect(exporter.add(_span('dropped-1', traceId: dropped)), isFalse);
      expect(exporter.add(_span('kept-2', traceId: kept)), isTrue);
      expect(exporter.add(_span('dropped-2', traceId: dropped)), isFalse);
      await exporter.flush();

      expect(collector.batches, [
        ['kept-1', 'kept-2'],
      ]);
      expect(exporter.discarded, {OtlpHttpTraceExporter.sampledOut: 2});
      expect(logs, isEmpty);
      await exporter.shutdown();
    });

    test('spans the collector rejects in a successful answer are counted',
        () async {
      final logs = captureLogs('threepio.observability.otlp');
      final collector = _Collector(
        (n, request) => http.Response(
          jsonEncode({
            'partialSuccess': {'rejectedSpans': '2', 'errorMessage': 'too big'},
          }),
          200,
        ),
      );
      final exporter = OtlpHttpTraceExporter(_config(), httpClient: collector.client);

      exporter.add(_span('s'));
      await exporter.flush();

      expect(exporter.discarded, {OtlpHttpTraceExporter.rejected: 2});
      expect(logs.single.message, contains('rejected 2 span(s): too big'));
      await exporter.shutdown();
    });

    test('an answer that is not JSON is fine when the status is', () async {
      final collector = _Collector((n, request) => http.Response('OK', 200));
      final exporter = OtlpHttpTraceExporter(_config(), httpClient: collector.client);

      exporter.add(_span('s'));
      await exporter.flush();
      expect(exporter.discarded, isEmpty);
      await exporter.shutdown();
    });
  });

  group('mask', () {
    test('is applied to every string attribute before the span is queued',
        () async {
      final collector = _Collector();
      final exporter = OtlpHttpTraceExporter(
        _config(mask: (value) => value.replaceAll('secret', '***')),
        httpClient: collector.client,
      );

      exporter.add(
        _span(
          'the secret name stays',
          attributes: const {
            'input': 'my secret is 42',
            'tags': ['secret', 'public'],
            'count': 3,
            'flag': true,
          },
        ),
      );
      await exporter.flush();

      final span = _Collector._spansOf(collector.requests.single.body).single as Map;
      expect(span['name'], 'the secret name stays');
      final attributes = {
        for (final entry in span['attributes'] as List)
          (entry as Map)['key']: entry['value'],
      };
      expect(attributes['input'], {'stringValue': 'my *** is 42'});
      expect(attributes['tags'], {
        'arrayValue': {
          'values': [
            {'stringValue': '***'},
            {'stringValue': 'public'},
          ],
        },
      });
      expect(attributes['count'], {'intValue': '3'});
      expect(attributes['flag'], {'boolValue': true});
      await exporter.shutdown();
    });

    test('reaches maps, the attributes of events and the status message',
        () async {
      final collector = _Collector();
      final exporter = OtlpHttpTraceExporter(
        _config(mask: (value) => value.replaceAll('secret', '***')),
        httpClient: collector.client,
      );

      exporter.add(
        OtlpSpan(
          traceId: 'a' * 32,
          spanId: 'b' * 16,
          name: 'n',
          startTime: DateTime.utc(2026),
          endTime: DateTime.utc(2026),
          attributes: const {
            'nested': {
              'token': 'secret-1',
              'deeper': ['secret-2', 7],
            },
          },
          events: [
            OtlpSpanEvent(
              name: 'exception',
              time: DateTime.utc(2026),
              attributes: const {'exception.message': 'failed with secret-3'},
            ),
          ],
          status: const OtlpStatus(
            code: OtlpStatusCode.error,
            message: 'secret-4 leaked',
          ),
        ),
      );
      await exporter.flush();

      final body = collector.requests.single.body;
      expect(body, isNot(contains('secret')));
      expect('***'.allMatches(body), hasLength(4));
      final span = _Collector._spansOf(body).single as Map;
      expect(span['status'], {'message': '***-4 leaked', 'code': 2});
      await exporter.shutdown();
    });
  });

  test('a span the mask function fails on is discarded, not sent unmasked',
      () async {
    final logs = captureLogs('threepio.observability.otlp');
    final collector = _Collector();
    final exporter = OtlpHttpTraceExporter(
      _config(
        mask: (value) =>
            value.contains('bad') ? throw const FormatException('mask') : value,
      ),
      httpClient: collector.client,
    );

    expect(exporter.add(_span('ok', attributes: const {'k': 'fine'})), isTrue);
    expect(exporter.add(_span('lost', attributes: const {'k': 'bad'})), isFalse);
    await exporter.flush();

    expect(collector.batches, [
      ['ok'],
    ]);
    expect(exporter.discarded, {OtlpHttpTraceExporter.maskFailed: 1});
    expect(logs.first.message, 'The OTLP mask function failed');
    await exporter.shutdown();
  });

  group('shutdown', () {
    test('sends what is left, then discards what arrives', () async {
      final logs = captureLogs('threepio.observability.otlp');
      final collector = _Collector();
      final exporter = OtlpHttpTraceExporter(_config(), httpClient: collector.client);

      exporter
        ..add(_span('a'))
        ..add(_span('b'));
      await exporter.shutdown();

      expect(collector.batches, [
        ['a', 'b'],
      ]);
      expect(exporter.add(_span('late')), isFalse);
      expect(exporter.discarded, {OtlpHttpTraceExporter.stopped: 1});
      await exporter.flush();
      await exporter.shutdown();
      expect(collector.requests, hasLength(1));
      expect(collector.closed, isFalse, reason: 'the client is the caller\'s');
      expect(logs, isEmpty, reason: 'the late span is reported with the next loss');
    });

    test('closes the client the exporter created itself', () async {
      final collector = _Collector();
      await http.runWithClient(
        () async {
          final exporter = OtlpHttpTraceExporter(_config())..add(_span('s'));
          await exporter.shutdown();
        },
        () => collector.client,
      );

      expect(collector.batches, [
        ['s'],
      ]);
      expect(collector.closed, isTrue);
    });

    test('an exporter that never sent anything creates no client', () async {
      var created = 0;
      await http.runWithClient(
        () => OtlpHttpTraceExporter(_config()).shutdown(),
        () {
          created++;
          return _Collector().client;
        },
      );
      expect(created, 0);
    });

    test('with a timeout it does not wait for a collector that hangs', () {
      fakeAsync((async) {
        final logs = captureLogs('threepio.observability.otlp');
        final collector =
            _Collector((n, request) => Completer<http.Response>().future);
        final exporter = OtlpHttpTraceExporter(
          _config(
            maxExportBatchSize: 1,
            timeout: const Duration(minutes: 10),
          ),
          httpClient: collector.client,
        );
        var done = false;

        exporter
          ..add(_span('in flight'))
          ..add(_span('queued'));
        unawaited(
          exporter
              .shutdown(timeout: const Duration(seconds: 3))
              .then((_) => done = true),
        );
        async.elapse(const Duration(milliseconds: 2999));
        expect(done, isFalse);
        async.elapse(const Duration(milliseconds: 1));

        expect(done, isTrue);
        expect(collector.requests, hasLength(1));
        expect(exporter.discarded, {OtlpHttpTraceExporter.stopped: 1});
        expect(
          logs.map((r) => r.message),
          contains('OTLP exporter discarded telemetry: exporter_stopped_spans=1'),
        );
        expect(exporter.add(_span('late')), isFalse);
      });
    });

    test('does not retry once it is stopping', () {
      fakeAsync((async) {
        captureLogs('threepio.observability.otlp');
        final collector = _Collector((n, request) => http.Response('busy', 503));
        final exporter = OtlpHttpTraceExporter(
          _config(retry: const OtlpRetryConfig(initialInterval: Duration(seconds: 5))),
          httpClient: collector.client,
        );

        exporter.add(_span('s'));
        unawaited(exporter.shutdown(timeout: const Duration(seconds: 1)));
        async.elapse(const Duration(minutes: 5));

        expect(collector.requests, hasLength(1));
        expect(exporter.discarded, {OtlpHttpTraceExporter.exportFailed: 1});
        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('settings', () {
    test('defaults', () {
      final config = OtlpExporterConfig(endpoint: _endpoint);
      expect(config.serviceName, 'threepio');
      expect(config.scopeName, 'threepio_core');
      expect(config.timeout, const Duration(seconds: 10));
      expect(config.maxQueueSize, 2048);
      expect(config.maxExportBatchSize, 512);
      expect(config.batchTimeout, const Duration(seconds: 5));
      expect(config.sampleRate, 1);
      expect(config.retry.enabled, isTrue);
      expect(config.mask, isNull);
    });

    test('a retry policy that could spin is refused', () {
      for (final retry in const [
        OtlpRetryConfig(initialInterval: Duration.zero),
        OtlpRetryConfig(initialInterval: Duration(seconds: -1)),
        OtlpRetryConfig(multiplier: 0.5),
        OtlpRetryConfig(multiplier: double.nan),
        OtlpRetryConfig(multiplier: double.infinity),
        OtlpRetryConfig(maxElapsedTime: Duration(seconds: -1)),
      ]) {
        expect(
          () => OtlpHttpTraceExporter(_config(retry: retry)),
          throwsArgumentError,
        );
      }
      // A policy that is switched off is not looked at.
      expect(
        OtlpHttpTraceExporter(
          _config(
            retry: const OtlpRetryConfig(
              enabled: false,
              initialInterval: Duration.zero,
            ),
          ),
        ),
        isA<SpanExporter>(),
      );
    });

    test('settings that cannot work are refused when the exporter is created',
        () {
      expect(
        () => OtlpHttpTraceExporter(_config(maxExportBatchSize: 0)),
        throwsArgumentError,
      );
      expect(
        () => OtlpHttpTraceExporter(_config(maxQueueSize: 5, maxExportBatchSize: 6)),
        throwsArgumentError,
      );
      expect(
        () => OtlpHttpTraceExporter(_config(maxQueueSize: 0, maxExportBatchSize: 0)),
        throwsArgumentError,
      );
      for (final rate in [-0.1, 1.1, double.nan]) {
        expect(
          () => OtlpHttpTraceExporter(_config(sampleRate: rate)),
          throwsArgumentError,
        );
      }
    });

    test('a sample rate of 0 exports nothing', () async {
      final collector = _Collector();
      final exporter = OtlpHttpTraceExporter(
        _config(sampleRate: 0),
        httpClient: collector.client,
      );
      expect(exporter.add(_span('s')), isFalse);
      await exporter.shutdown();
      expect(collector.requests, isEmpty);
    });
  });

  test('the exporter is a SpanExporter', () {
    final SpanExporter exporter = OtlpHttpTraceExporter(_config());
    expect(exporter, isA<SpanExporter>());
  });
}
