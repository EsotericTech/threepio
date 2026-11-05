/// Sends spans to an OpenTelemetry collector over HTTP.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../../errors.dart';
import 'otlp_json.dart';
import 'span_queue.dart';

final _log = Logger('threepio.observability.otlp');

/// Where finished spans go.
///
/// The seam between the code that produces spans (`LangfuseHandler`) and the
/// transport. [OtlpHttpTraceExporter] is the implementation for OTLP over
/// HTTP; tests use one that keeps the spans in a list.
abstract interface class SpanExporter {
  /// Takes [span] for export. Returns `false` when the span is discarded
  /// instead (the exporter was shut down, its queue is full, the trace is not
  /// sampled).
  ///
  /// Never throws and never waits: it is called on the path of the work the
  /// span describes. The span, with its attributes and events, must not be
  /// changed after it was added.
  bool add(OtlpSpan span);

  /// Sends everything taken so far and completes when that has been tried.
  ///
  /// Completes normally also when sending failed; failures are logged.
  Future<void> flush();

  /// Sends what is left and releases the exporter's resources. Spans added
  /// afterwards are discarded.
  Future<void> shutdown();
}

/// How [OtlpHttpTraceExporter] retries a request the collector did not take.
///
/// A request is tried again after a transport error, a timeout, or one of the
/// responses the protocol calls retryable (429, 502, 503, 504). The first wait
/// is [initialInterval]; each further wait is [multiplier] times the one
/// before, up to [maxInterval]. A `Retry-After` header of the response that
/// asks for a longer wait is honoured. Retrying stops, and the batch is
/// discarded, when the waits would add up to more than [maxElapsedTime].
///
/// The defaults are those of the OpenTelemetry exporters.
@immutable
final class OtlpRetryConfig {
  /// Creates a retry policy.
  const OtlpRetryConfig({
    this.enabled = true,
    this.initialInterval = const Duration(seconds: 5),
    this.maxInterval = const Duration(seconds: 30),
    this.maxElapsedTime = const Duration(minutes: 1),
    this.multiplier = 1.5,
  });

  /// One attempt per batch, no retry.
  static const OtlpRetryConfig none = OtlpRetryConfig(enabled: false);

  /// Whether a failed request is tried again at all.
  final bool enabled;

  /// The wait before the second attempt.
  final Duration initialInterval;

  /// The longest wait between two attempts.
  final Duration maxInterval;

  /// The longest time all waits of one batch may add up to.
  /// [Duration.zero] means no limit.
  final Duration maxElapsedTime;

  /// The factor by which the wait grows from one attempt to the next.
  final double multiplier;
}

/// The settings of an [OtlpHttpTraceExporter].
@immutable
final class OtlpExporterConfig {
  /// Creates the settings of an exporter that posts to [endpoint].
  const OtlpExporterConfig({
    required this.endpoint,
    this.headers = const {},
    this.serviceName = 'threepio',
    this.resourceAttributes = const {},
    this.scopeName = 'threepio_core',
    this.scopeVersion,
    this.timeout = const Duration(seconds: 10),
    this.maxQueueSize = 2048,
    this.maxExportBatchSize = 512,
    this.batchTimeout = const Duration(seconds: 5),
    this.retry = const OtlpRetryConfig(),
    this.sampleRate = 1,
    this.mask,
  });

  /// The full URL of the collector's trace endpoint, which for a standard
  /// collector ends in `/v1/traces`.
  final Uri endpoint;

  /// Headers sent with every request, such as `Authorization`.
  final Map<String, String> headers;

  /// The `service.name` the spans are reported under.
  final String serviceName;

  /// Further attributes of the resource the spans come from.
  final Map<String, Object?> resourceAttributes;

  /// The name of the instrumentation scope, which tells a backend what
  /// produced the spans.
  final String scopeName;

  /// The version of the instrumentation scope.
  final String? scopeVersion;

  /// How long one request may take.
  final Duration timeout;

  /// How many spans may wait to be sent. A span that arrives when the queue
  /// is full is discarded.
  final int maxQueueSize;

  /// The most spans sent in one request. Reaching it sends a batch at once.
  final int maxExportBatchSize;

  /// How long a span waits at most before it is sent with whatever else is
  /// queued: the flush interval.
  final Duration batchTimeout;

  /// When a failed request is tried again.
  final OtlpRetryConfig retry;

  /// The share of traces that is exported, from `0.0` to `1.0`. The decision
  /// is made per trace (see [isTraceSampled]), so a trace is exported whole
  /// or not at all.
  final double sampleRate;

  /// Applied to every string among the attributes of a span and of its
  /// events (also inside lists and maps) and to its status message, before
  /// the span is queued, to take out what must not leave the application
  /// (secrets, personal data). The name of a span is not masked. A span the
  /// function throws on is discarded.
  final String Function(String value)? mask;
}

/// The collector did not accept a batch of spans.
class OtlpExportException extends ThreepioException {
  /// An export that failed with [message]; [statusCode] is the HTTP status
  /// when the collector answered.
  const OtlpExportException(super.message, {this.statusCode, super.cause});

  /// The HTTP status of the response, or `null` when there was none.
  final int? statusCode;

  @override
  String toString() => 'OtlpExportException: $message';
}

/// Exports spans to an OpenTelemetry collector with OTLP over HTTP, in the
/// JSON encoding of the protocol.
///
/// The Dart counterpart of the batch span processor and the OTLP/HTTP
/// exporter of an OpenTelemetry SDK, which Eino's tracing handlers are built
/// on (`libs/acl/opentelemetry` in eino-ext uses gRPC, which this does not
/// speak). It works with any collector that accepts `application/json` on its
/// trace endpoint.
///
/// ```dart
/// final exporter = OtlpHttpTraceExporter(
///   OtlpExporterConfig(
///     endpoint: Uri.parse('http://localhost:4318/v1/traces'),
///     serviceName: 'my-app',
///   ),
/// );
/// exporter.add(span);
/// await exporter.shutdown();
/// ```
///
/// **Batching.** [add] puts a span into a bounded queue and returns at once.
/// A batch is sent when `maxExportBatchSize` spans are waiting or when the
/// oldest has waited for `batchTimeout`, one request at a time. [flush] sends
/// everything now.
///
/// **Losses.** Tracing never fails or delays the work it observes: a span
/// that cannot be queued and a batch that cannot be delivered after the
/// retries are discarded, counted in [discarded] and reported on the logger
/// `threepio.observability.otlp`.
///
/// Call [shutdown] before the application exits; spans still in the queue
/// are lost otherwise.
final class OtlpHttpTraceExporter implements SpanExporter {
  /// Creates an exporter.
  ///
  /// It sends through [httpClient] when one is given and leaves closing it
  /// to the caller; otherwise it creates a client of its own on first use and
  /// closes it in [shutdown].
  OtlpHttpTraceExporter(this.config, {http.Client? httpClient})
      : _client = httpClient,
        _ownsClient = httpClient == null,
        _queue = SpanQueue(maxSize: config.maxQueueSize) {
    if (config.maxExportBatchSize <= 0) {
      throw ArgumentError.value(
        config.maxExportBatchSize,
        'maxExportBatchSize',
        'must be positive',
      );
    }
    if (config.maxExportBatchSize > config.maxQueueSize) {
      throw ArgumentError(
        'maxExportBatchSize ${config.maxExportBatchSize} exceeds '
        'maxQueueSize ${config.maxQueueSize}',
      );
    }
    if (config.sampleRate.isNaN ||
        config.sampleRate < 0 ||
        config.sampleRate > 1) {
      throw ArgumentError.value(
        config.sampleRate,
        'sampleRate',
        'must be between 0 and 1',
      );
    }
    final retry = config.retry;
    if (retry.enabled) {
      // A wait of zero would retry in a tight loop that never adds up to
      // `maxElapsedTime`.
      if (retry.initialInterval <= Duration.zero) {
        throw ArgumentError.value(
          retry.initialInterval,
          'retry.initialInterval',
          'must be positive',
        );
      }
      if (!retry.multiplier.isFinite || retry.multiplier < 1) {
        throw ArgumentError.value(
          retry.multiplier,
          'retry.multiplier',
          'must be a number of at least 1',
        );
      }
      if (retry.maxElapsedTime < Duration.zero) {
        throw ArgumentError.value(
          retry.maxElapsedTime,
          'retry.maxElapsedTime',
          'must not be negative',
        );
      }
    }
  }

  /// The reason, in [discarded], for spans that arrived when the queue was
  /// full.
  static const String queueFull = 'queue_full_spans';

  /// The reason for spans of traces that are not sampled.
  static const String sampledOut = 'sampled_out_spans';

  /// The reason for spans whose attributes the mask function failed on.
  static const String maskFailed = 'mask_failed_spans';

  /// The reason for spans whose trace, span or parent id is not an id. One
  /// of them would get its whole batch refused by the collector.
  static const String invalid = 'invalid_spans';

  /// The reason for spans that arrived after [shutdown].
  static const String stopped = 'exporter_stopped_spans';

  /// The reason for spans of batches the collector did not take.
  static const String exportFailed = 'export_failed_spans';

  /// The reason for spans the collector reported as rejected in an otherwise
  /// successful response.
  static const String rejected = 'rejected_spans';

  /// The settings of this exporter.
  final OtlpExporterConfig config;

  http.Client? _client;
  final bool _ownsClient;
  final SpanQueue _queue;
  final Map<String, int> _discarded = {};
  final Map<String, int> _unreported = {};

  Timer? _timer;
  bool _exporting = false;
  bool _drainAll = false;
  bool _stopped = false;
  Completer<void>? _idle;

  /// How many spans were discarded so far, by reason (the constants of this
  /// class).
  Map<String, int> get discarded => Map.unmodifiable(_discarded);

  /// The number of spans waiting to be sent.
  int get queued => _queue.length;

  @override
  bool add(OtlpSpan span) {
    if (_stopped) return _discard(stopped);
    final parent = span.parentSpanId;
    if (!isValidTraceId(span.traceId) ||
        !isValidSpanId(span.spanId) ||
        (parent != null && parent.isNotEmpty && !isValidSpanId(parent))) {
      return _discard(invalid);
    }
    if (!isTraceSampled(span.traceId, config.sampleRate)) {
      // Not reported in the log: this is what the sample rate asks for.
      _discarded.update(sampledOut, (count) => count + 1, ifAbsent: () => 1);
      return false;
    }
    final OtlpSpan masked;
    try {
      masked = _masked(span);
      // A mask that fails must not let the unmasked span out.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      _log.warning('The OTLP mask function failed', error, stackTrace);
      return _discard(maskFailed);
    }
    if (!_queue.add(masked)) return _discard(queueFull);

    if (_queue.length >= config.maxExportBatchSize) {
      _kick();
    } else {
      _timer ??= Timer(config.batchTimeout, _onTimer);
    }
    return true;
  }

  @override
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    while (!_stopped && (_queue.isNotEmpty || _exporting)) {
      _drainAll = true;
      _kick();
      if (_exporting) await (_idle ??= Completer<void>()).future;
    }
  }

  /// Sends what is left, then stops the exporter and closes the HTTP client
  /// it created.
  ///
  /// With a [timeout], the wait for the collector ends after that time and
  /// whatever has not been delivered by then is discarded; without one, the
  /// retry policy decides how long this takes.
  @override
  Future<void> shutdown({Duration? timeout}) async {
    if (_stopped) return;
    final flushed = flush();
    if (timeout == null) {
      await flushed;
    } else {
      await flushed.timeout(timeout, onTimeout: () {});
    }
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    final left = _queue.takeAll();
    if (left.isNotEmpty) _discard(stopped, left.length);
    _reportLosses();
    if (_ownsClient) {
      _client?.close();
      _client = null;
    }
  }

  void _onTimer() {
    _timer = null;
    _drainAll = true;
    _kick();
  }

  /// Starts the export loop unless it is running.
  ///
  /// The loop starts in a microtask: [add] is called on the path of the work
  /// a span describes and must not encode a batch there.
  void _kick() {
    if (_exporting) return;
    _exporting = true;
    scheduleMicrotask(() => unawaited(_loop()));
  }

  Future<void> _loop() async {
    try {
      while (_queue.isNotEmpty &&
          !_stopped &&
          (_drainAll || _queue.length >= config.maxExportBatchSize)) {
        _timer?.cancel();
        _timer = null;
        await _export(_queue.takeBatch(config.maxExportBatchSize));
      }
    } finally {
      _exporting = false;
      _drainAll = false;
      if (_queue.isNotEmpty && !_stopped) {
        _timer ??= Timer(config.batchTimeout, _onTimer);
      }
      _reportLosses();
      _idle?.complete();
      _idle = null;
    }
  }

  /// Sends one batch, retrying as [OtlpExporterConfig.retry] says. Never
  /// throws: a batch that cannot be delivered is discarded.
  Future<void> _export(List<OtlpSpan> batch) async {
    final List<int> body;
    try {
      body = utf8.encode(
        jsonEncode(
          encodeOtlpTraces(
            resource: {
              'service.name': config.serviceName,
              ...config.resourceAttributes,
            },
            scopeName: config.scopeName,
            scopeVersion: config.scopeVersion,
            spans: batch,
          ),
        ),
      );
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      _fail(batch, 0, error, stackTrace);
      return;
    }

    final retry = config.retry;
    var interval = retry.initialInterval;
    var waited = Duration.zero;
    for (var attempt = 1;; attempt++) {
      Object failure;
      StackTrace? failureTrace;
      Duration? retryAfter;
      try {
        final response = await _send(body);
        final status = response.statusCode;
        if (status >= 200 && status < 300) {
          _checkPartialSuccess(response.body);
          return;
        }
        failure = OtlpExportException(
          'the collector answered $status: ${_excerpt(response.body)}',
          statusCode: status,
        );
        if (!_retryableStatus(status)) {
          _fail(batch, attempt, failure, null);
          return;
        }
        retryAfter = _retryAfter(response.headers['retry-after']);
        // A transport error or a timeout; the next attempt may get through.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        failure = error;
        failureTrace = stackTrace;
      }

      // The collector may ask for a longer wait than the back-off, never
      // for a shorter one: `Retry-After: 0` must not turn into a tight loop.
      final wait =
          retryAfter != null && retryAfter > interval ? retryAfter : interval;
      final exhausted = retry.maxElapsedTime > Duration.zero &&
          waited + wait > retry.maxElapsedTime;
      if (!retry.enabled || exhausted || _stopped) {
        _fail(batch, attempt, failure, failureTrace);
        return;
      }
      await Future<void>.delayed(wait);
      waited += wait;
      // Stopped while waiting: the client may be gone, and nobody waits for
      // this batch any more.
      if (_stopped) {
        _fail(batch, attempt, failure, failureTrace);
        return;
      }
      final next = interval * retry.multiplier;
      interval = next > retry.maxInterval ? retry.maxInterval : next;
    }
  }

  Future<http.Response> _send(List<int> body) {
    if (_stopped && _client == null) {
      throw StateError('the exporter was shut down');
    }
    final client = _client ??= http.Client();
    return client
        .post(
          config.endpoint,
          headers: {...config.headers, 'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(config.timeout);
  }

  void _fail(
    List<OtlpSpan> batch,
    int attempts,
    Object error,
    StackTrace? stackTrace,
  ) {
    _discarded.update(
      exportFailed,
      (count) => count + batch.length,
      ifAbsent: () => batch.length,
    );
    _log.severe(
      'OTLP export failed for a batch of ${batch.length} spans after '
      '$attempts attempt(s); the spans are discarded',
      error,
      stackTrace,
    );
  }

  /// A collector may accept a request and still refuse some of its spans.
  void _checkPartialSuccess(String responseBody) {
    if (responseBody.isEmpty) return;
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, Object?>) return;
      final partial = decoded['partialSuccess'];
      if (partial is! Map<String, Object?>) return;
      final count = int.tryParse('${partial['rejectedSpans'] ?? 0}') ?? 0;
      if (count <= 0) return;
      _discarded.update(rejected, (n) => n + count, ifAbsent: () => count);
      _log.warning(
        'The OTLP collector rejected $count span(s): '
        '${partial['errorMessage'] ?? 'no reason given'}',
      );
    } on FormatException {
      // Not JSON; the status code said the request was fine.
    }
  }

  bool _discard(String reason, [int count = 1]) {
    _discarded.update(reason, (n) => n + count, ifAbsent: () => count);
    _unreported.update(reason, (n) => n + count, ifAbsent: () => count);
    return false;
  }

  /// One warning for everything that was discarded since the last one.
  void _reportLosses() {
    if (_unreported.isEmpty) return;
    final parts = [
      for (final reason in _unreported.keys.toList()..sort())
        '$reason=${_unreported[reason]}',
    ];
    _unreported.clear();
    _log.warning('OTLP exporter discarded telemetry: ${parts.join(' ')}');
  }

  OtlpSpan _masked(OtlpSpan span) {
    final mask = config.mask;
    if (mask == null) return span;
    final message = span.status.message;
    return OtlpSpan(
      traceId: span.traceId,
      spanId: span.spanId,
      parentSpanId: span.parentSpanId,
      name: span.name,
      kind: span.kind,
      startTime: span.startTime,
      endTime: span.endTime,
      attributes: _maskAttributes(span.attributes, mask),
      events: [
        for (final event in span.events)
          OtlpSpanEvent(
            name: event.name,
            time: event.time,
            attributes: _maskAttributes(event.attributes, mask),
          ),
      ],
      status: message == null
          ? span.status
          : OtlpStatus(code: span.status.code, message: mask(message)),
    );
  }

  static Map<String, Object?> _maskAttributes(
    Map<String, Object?> attributes,
    String Function(String) mask,
  ) =>
      {
        for (final MapEntry(:key, :value) in attributes.entries)
          key: _maskValue(value, mask),
      };

  static Object? _maskValue(Object? value, String Function(String) mask) =>
      switch (value) {
        final String text => mask(text),
        final Map<Object?, Object?> map => {
            for (final MapEntry(:key, :value) in map.entries)
              key: _maskValue(value, mask),
          },
        final Iterable<Object?> items => [
            for (final item in items) _maskValue(item, mask),
          ],
        _ => value,
      };

  static bool _retryableStatus(int status) =>
      status == 429 || status == 502 || status == 503 || status == 504;

  static Duration? _retryAfter(String? header) {
    final seconds = int.tryParse(header?.trim() ?? '');
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }

  static String _excerpt(String body) =>
      body.length <= 200 ? body : '${body.substring(0, 200)}...';
}
