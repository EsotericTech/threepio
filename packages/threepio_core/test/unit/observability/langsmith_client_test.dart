// Tests of `LangSmithClient`, `LangSmithRun` and `LangSmithRunPatch`, the
// port of eino-ext `callbacks/langsmith/client.go`. Go has no test of its
// own for client.go (its tests replace the client with a mock); these check
// the requests against `MockClient`: method, URL, headers, the JSON bodies
// with Go's field names and `omitempty` rules, the statuses LangSmith may
// answer with and Go's error messages. Expected bodies are derived from the
// struct tags of `Run` and `RunPatch`.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_client.dart';
import 'package:threepio_core/threepio_core.dart';

final _start = DateTime.utc(2025, 10, 10, 12, 34, 56, 123, 456);

LangSmithRun _fullRun() => LangSmithRun(
      id: 'run-2',
      name: 'OpenAIChatModel',
      runType: LangSmithRunType.llm,
      startTime: _start,
      endTime: _start.add(const Duration(seconds: 2)),
      inputs: const {'input': '"hi"'},
      outputs: const {'output': '"hello"'},
      error: 'boom',
      parentRunId: 'run-1',
      traceId: 'run-1',
      extra: const {
        'metadata': {'env': 'test'},
      },
      sessionName: 'project',
      referenceExampleId: 'example-1',
      dottedOrder: '20251010T123456123456Zrun-1.20251010T123456123456Zrun-2',
      tags: const ['a', 'b'],
    );

LangSmithRun _minimalRun() => LangSmithRun(
      id: 'run-1',
      name: 'span',
      runType: LangSmithRunType.chain,
      startTime: DateTime.utc(2025, 10, 10, 12),
    );

final class _Unencodable {
  Map<String, Object?> toJson() => throw StateError('no json');
}

final class _TrackingClient extends http.BaseClient {
  _TrackingClient(this._inner);
  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => closed = true;
}

void main() {
  group('LangSmithRunType', () {
    test('wire values', () {
      expect(
        {for (final type in LangSmithRunType.values) type: type.value},
        {
          LangSmithRunType.chain: 'chain',
          LangSmithRunType.llm: 'llm',
          LangSmithRunType.tool: 'tool',
        },
      );
    });
  });

  group('LangSmithRun.toJson', () {
    test("every field, under Go's names and in Go's order", () {
      expect(
        jsonEncode(_fullRun().toJson()),
        '{"id":"run-2","name":"OpenAIChatModel","run_type":"llm",'
        '"start_time":"2025-10-10T12:34:56.123456Z",'
        '"end_time":"2025-10-10T12:34:58.123456Z",'
        r'"inputs":{"input":"\"hi\""},"outputs":{"output":"\"hello\""},'
        '"error":"boom","parent_run_id":"run-1","trace_id":"run-1",'
        '"extra":{"metadata":{"env":"test"}},"session_name":"project",'
        '"reference_example_id":"example-1",'
        '"dotted_order":"20251010T123456123456Zrun-1.'
        '20251010T123456123456Zrun-2","tags":["a","b"]}',
      );
    });

    test('empty optional fields are left out; inputs is written as null', () {
      expect(_minimalRun().toJson(), {
        'id': 'run-1',
        'name': 'span',
        'run_type': 'chain',
        'start_time': '2025-10-10T12:00:00Z',
        'inputs': null,
      });
    });

    test('empty maps and lists are left out like nil ones (omitempty)', () {
      final json = LangSmithRun(
        id: 'r',
        name: 'n',
        runType: LangSmithRunType.tool,
        startTime: _start,
        inputs: const {},
        outputs: const {},
        extra: const {},
        error: '',
      ).toJson();
      expect(json['inputs'], <String, Object?>{}, reason: 'no omitempty');
      expect(json, isNot(contains('outputs')));
      expect(json, isNot(contains('extra')));
      expect(json, isNot(contains('tags')));
      expect(json['error'], '', reason: 'a pointer to "" is written');
    });

    test('values that are not JSON are written as threepio writes them', () {
      final json = LangSmithRun(
        id: 'r',
        name: 'n',
        runType: LangSmithRunType.llm,
        startTime: _start,
        inputs: {
          'stream_inputs': [Message.user('hi')],
        },
      ).toJson();
      expect(json['inputs'], {
        'stream_inputs': [
          {'role': 'user', 'content': 'hi'},
        ],
      });
    });
  });

  group('LangSmithRunPatch.toJson', () {
    test('every field', () {
      final patch = LangSmithRunPatch(
        endTime: _start,
        inputs: const {'input': 'i'},
        outputs: const {'output': 'o'},
        error: 'failed',
        extra: const {
          'metadata': {'k': 1},
        },
      );
      expect(
        jsonEncode(patch.toJson()),
        '{"end_time":"2025-10-10T12:34:56.123456Z","inputs":{"input":"i"},'
        '"outputs":{"output":"o"},"error":"failed",'
        '"extra":{"metadata":{"k":1}}}',
      );
    });

    test('an empty patch is an empty object', () {
      expect(const LangSmithRunPatch().toJson(), isEmpty);
      expect(
        const LangSmithRunPatch(inputs: {}, outputs: {}, extra: {}).toJson(),
        isEmpty,
      );
    });
  });

  group('LangSmithClient', () {
    test('an empty URL is the default one', () {
      expect(
        LangSmithClient.defaultApiUrl,
        'https://api.smith.langchain.com',
      );
      expect(LangSmithClient(apiKey: 'test-key').apiUrl, LangSmithClient.defaultApiUrl);
      expect(
        LangSmithClient(apiKey: 'test-key', apiUrl: 'http://test').apiUrl,
        'http://test',
      );
      expect(LangSmithClient(apiKey: 'k').timeout, const Duration(seconds: 10));
    });

    test('createRun posts the run to /runs with the API key', () async {
      final requests = <http.Request>[];
      final client = LangSmithClient(
        apiKey: 'test-key',
        apiUrl: 'http://test',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );

      await client.createRun(RunContext.background(), _fullRun());

      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url, Uri.parse('http://test/runs'));
      expect(request.headers['x-api-key'], 'test-key');
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(request.body), _fullRun().toJson());
    });

    test('updateRun patches /runs/{id}', () async {
      final requests = <http.Request>[];
      final client = LangSmithClient(
        apiKey: 'test-key',
        apiUrl: 'http://test',
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('', 202);
        }),
      );

      await client.updateRun(
        RunContext.background(),
        'run-123',
        LangSmithRunPatch(endTime: _start, error: 'mock error'),
      );

      final request = requests.single;
      expect(request.method, 'PATCH');
      expect(request.url, Uri.parse('http://test/runs/run-123'));
      expect(request.headers['x-api-key'], 'test-key');
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(request.body), {
        'end_time': '2025-10-10T12:34:56.123456Z',
        'error': 'mock error',
      });
    });

    test('the default URL is used without one', () async {
      final urls = <Uri>[];
      final client = LangSmithClient(
        apiKey: 'test-key',
        httpClient: MockClient((request) async {
          urls.add(request.url);
          return http.Response('{}', 200);
        }),
      );
      await client.createRun(RunContext.background(), _minimalRun());
      await client.updateRun(
        RunContext.background(),
        'run-1',
        const LangSmithRunPatch(),
      );
      expect(urls, [
        Uri.parse('https://api.smith.langchain.com/runs'),
        Uri.parse('https://api.smith.langchain.com/runs/run-1'),
      ]);
    });

    test('a status other than 200 or 202 is an error with the status and '
        'body', () async {
      final client = LangSmithClient(
        apiKey: 'test-key',
        apiUrl: 'http://test',
        httpClient: MockClient(
          (request) async => request.method == 'POST'
              ? http.Response(
                  'boom',
                  500,
                  reasonPhrase: 'Internal Server Error',
                )
              : http.Response('missing', 404),
        ),
      );

      await expectLater(
        client.createRun(RunContext.background(), _minimalRun()),
        throwsA(
          isA<LangSmithException>()
              .having(
                (e) => e.message,
                'message',
                'failed to create run, status: 500 Internal Server Error, '
                    'body: boom',
              )
              .having((e) => e.statusCode, 'statusCode', 500),
        ),
      );
      await expectLater(
        client.updateRun(
          RunContext.background(),
          'run-1',
          const LangSmithRunPatch(),
        ),
        throwsA(
          isA<LangSmithException>()
              .having(
                (e) => e.message,
                'message',
                'failed to update run, status: 404, body: missing',
              )
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('a request that cannot be sent is an error', () async {
      final failure = http.ClientException('connection refused');
      final client = LangSmithClient(
        apiKey: 'test-key',
        apiUrl: 'http://test',
        httpClient: MockClient((request) async => throw failure),
      );
      await expectLater(
        client.createRun(RunContext.background(), _minimalRun()),
        throwsA(
          isA<LangSmithException>()
              .having(
                (e) => e.message,
                'message',
                startsWith('failed to execute request: '),
              )
              .having((e) => e.cause, 'cause', same(failure))
              .having((e) => e.statusCode, 'statusCode', isNull),
        ),
      );
    });

    test('a URL that is not one cannot be requested', () async {
      var requests = 0;
      final client = LangSmithClient(
        apiKey: 'test-key',
        apiUrl: 'http://[::1',
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        client.createRun(RunContext.background(), _minimalRun()),
        throwsA(
          isA<LangSmithException>().having(
            (e) => e.message,
            'message',
            startsWith('failed to create request: '),
          ),
        ),
      );
      expect(requests, 0);
    });

    test('a run that cannot be written as JSON is not sent', () async {
      var requests = 0;
      final client = LangSmithClient(
        apiKey: 'test-key',
        apiUrl: 'http://test',
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      final run = LangSmithRun(
        id: 'r',
        name: 'n',
        runType: LangSmithRunType.chain,
        startTime: _start,
        extra: {'bad': _Unencodable()},
      );
      await expectLater(
        client.createRun(RunContext.background(), run),
        throwsA(
          isA<LangSmithException>().having(
            (e) => e.message,
            'message',
            startsWith('failed to marshal run data: '),
          ),
        ),
      );
      await expectLater(
        client.updateRun(
          RunContext.background(),
          'r',
          LangSmithRunPatch(outputs: {'bad': _Unencodable()}),
        ),
        throwsA(
          isA<LangSmithException>().having(
            (e) => e.message,
            'message',
            startsWith('failed to marshal patch data: '),
          ),
        ),
      );
      expect(requests, 0);
    });

    test('a cancelled context sends nothing', () async {
      var requests = 0;
      final client = LangSmithClient(
        apiKey: 'test-key',
        apiUrl: 'http://test',
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      final token = CancelToken()..cancel('stop');
      await expectLater(
        client.createRun(RunContext.background(cancelToken: token), _minimalRun()),
        throwsA(isA<CancelledException>()),
      );
      expect(requests, 0);
    });

    test('cancelling during a request abandons it', () {
      fakeAsync((async) {
        final token = CancelToken();
        final client = LangSmithClient(
          apiKey: 'test-key',
          apiUrl: 'http://test',
          httpClient: MockClient((request) => Completer<http.Response>().future),
        );
        Object? failure;
        unawaited(
          client
              .createRun(RunContext.background(cancelToken: token), _minimalRun())
              .catchError((Object error) => failure = error),
        );
        async.flushMicrotasks();
        expect(failure, isNull);
        token.cancel('user stopped');
        async.flushMicrotasks();
        expect(
          failure,
          isA<CancelledException>().having((e) => e.reason, 'reason', 'user stopped'),
        );
        async.elapse(const Duration(seconds: 11));
      });
    });

    test('a request may take the timeout at most', () {
      fakeAsync((async) {
        final client = LangSmithClient(
          apiKey: 'test-key',
          apiUrl: 'http://test',
          timeout: const Duration(seconds: 3),
          httpClient: MockClient((request) => Completer<http.Response>().future),
        );
        Object? failure;
        unawaited(
          client
              .createRun(RunContext.background(), _minimalRun())
              .catchError((Object error) => failure = error),
        );
        async.elapse(const Duration(milliseconds: 2999));
        expect(failure, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(
          failure,
          isA<LangSmithException>()
              .having(
                (e) => e.message,
                'message',
                startsWith('failed to execute request: TimeoutException'),
              )
              .having((e) => e.cause, 'cause', isA<TimeoutException>()),
        );
      });
    });

    test('close leaves an injected HTTP client open; the client cannot be '
        'used afterwards', () async {
      final tracking = _TrackingClient(MockClient((request) async {
        throw StateError('not expected');
      }));
      final client = LangSmithClient(apiKey: 'test-key', httpClient: tracking)
        ..close()
        ..close();
      expect(tracking.closed, isFalse);
      await expectLater(
        client.createRun(RunContext.background(), _minimalRun()),
        throwsA(
          isA<LangSmithException>().having(
            (e) => e.cause,
            'cause',
            isA<StateError>(),
          ),
        ),
      );
    });

    test('the API key is in no error text', () async {
      final client = LangSmithClient(
        apiKey: 'test-key',
        apiUrl: 'http://test',
        httpClient: MockClient(
          (request) async => request.method == 'POST'
              ? throw http.ClientException('refused', request.url)
              : http.Response('denied', 401, reasonPhrase: 'Unauthorized'),
        ),
      );
      final failures = <Object>[];
      await client
          .createRun(RunContext.background(), _minimalRun())
          .catchError((Object error) => failures.add(error));
      await client
          .updateRun(RunContext.background(), 'r', const LangSmithRunPatch())
          .catchError((Object error) => failures.add(error));

      expect(failures, hasLength(2));
      for (final failure in failures) {
        expect(failure, isA<LangSmithException>());
        expect('$failure', isNot(contains('test-key')));
        expect(
          (failure as LangSmithException).message,
          isNot(contains('test-key')),
        );
      }
      expect('$client', isNot(contains('test-key')));
    });

    test('LangSmithException says what failed', () {
      const error = LangSmithException('failed to create run', statusCode: 500);
      expect('$error', 'LangSmithException: failed to create run');
      expect(error, isA<ThreepioException>());
    });

    test('toString of a run and a patch does not encode them', () {
      final run = LangSmithRun(
        id: 'r',
        name: 'n',
        runType: LangSmithRunType.chain,
        startTime: _start,
        extra: {'bad': _Unencodable()},
      );
      expect('$run', contains('id: r'));
      expect(
        '${LangSmithRunPatch(outputs: {'bad': _Unencodable()})}',
        contains('[bad]'),
      );
    });
  });
}
