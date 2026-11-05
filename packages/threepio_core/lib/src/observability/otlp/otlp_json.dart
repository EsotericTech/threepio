/// Spans as the OpenTelemetry protocol (OTLP) describes them, and their JSON
/// encoding.
///
/// This is the small part of OpenTelemetry a tracing handler needs: finished
/// spans and the request body of `POST /v1/traces`. There is no tracer, no
/// propagation and no SDK behind it.
library;

import 'dart:math';

import 'package:meta/meta.dart';

/// What a span stands for in a distributed trace (OTLP `Span.SpanKind`).
///
/// The index of a value is its number in the protocol.
enum OtlpSpanKind {
  /// Not specified.
  unspecified,

  /// Work inside the application. The default.
  internal,

  /// The handling of a request that came from outside.
  server,

  /// A request to a remote service.
  client,

  /// The sending of a message to a broker.
  producer,

  /// The receiving of a message from a broker.
  consumer,
}

/// How a span ended (OTLP `Status.StatusCode`).
///
/// The index of a value is its number in the protocol.
enum OtlpStatusCode {
  /// Nothing is said about the outcome. The default.
  unset,

  /// The work is known to have succeeded.
  ok,

  /// The work failed.
  error,
}

/// The outcome of a span (OTLP `Status`).
@immutable
final class OtlpStatus {
  /// A status with [code] and, for an error, a [message] describing it.
  const OtlpStatus({this.code = OtlpStatusCode.unset, this.message});

  /// The outcome.
  final OtlpStatusCode code;

  /// What went wrong, when [code] is [OtlpStatusCode.error].
  final String? message;

  /// The JSON form of the status.
  Map<String, Object?> toJson() => {
        if (message != null && message!.isNotEmpty) 'message': message,
        'code': code.index,
      };

  @override
  String toString() => 'OtlpStatus(${code.name}'
      '${message == null ? '' : ', $message'})';
}

/// Something that happened at one moment during a span (OTLP `Span.Event`).
@immutable
final class OtlpSpanEvent {
  /// An event called [name] that happened at [time].
  const OtlpSpanEvent({
    required this.name,
    required this.time,
    this.attributes = const {},
  });

  /// The name of the event (`exception` for a recorded error).
  final String name;

  /// When it happened.
  final DateTime time;

  /// What is known about it. See [OtlpSpan.attributes] for the value types.
  final Map<String, Object?> attributes;

  /// The JSON form of the event.
  Map<String, Object?> toJson() => {
        'timeUnixNano': otlpUnixNano(time),
        'name': name,
        if (attributes.isNotEmpty) 'attributes': otlpAttributes(attributes),
      };
}

/// A finished span: one piece of work in a trace, with its start and end
/// (OTLP `Span`).
@immutable
final class OtlpSpan {
  /// Creates a span.
  ///
  /// [traceId] is 32 and [spanId] and [parentSpanId] are 16 lower-case
  /// hexadecimal digits; see [newTraceId] and [newSpanId].
  const OtlpSpan({
    required this.traceId,
    required this.spanId,
    required this.name,
    required this.startTime,
    required this.endTime,
    this.parentSpanId,
    this.kind = OtlpSpanKind.internal,
    this.attributes = const {},
    this.events = const [],
    this.status = const OtlpStatus(),
  });

  /// The trace the span belongs to: 32 hexadecimal digits.
  final String traceId;

  /// The span itself: 16 hexadecimal digits.
  final String spanId;

  /// The span this one is a part of, or `null` for the root of a trace.
  final String? parentSpanId;

  /// What the span is called.
  final String name;

  /// The kind of work.
  final OtlpSpanKind kind;

  /// When the work began.
  final DateTime startTime;

  /// When the work was over.
  final DateTime endTime;

  /// What is known about the work.
  ///
  /// A value is a [String], a [bool], an [int], a [double], a [List] of
  /// values or a [Map] from strings to values. Anything else is sent as its
  /// `toString()`; a `null` value is left out.
  final Map<String, Object?> attributes;

  /// What happened along the way.
  final List<OtlpSpanEvent> events;

  /// How the work ended.
  final OtlpStatus status;

  /// A copy of this span with other [attributes].
  OtlpSpan withAttributes(Map<String, Object?> attributes) => OtlpSpan(
        traceId: traceId,
        spanId: spanId,
        parentSpanId: parentSpanId,
        name: name,
        kind: kind,
        startTime: startTime,
        endTime: endTime,
        attributes: attributes,
        events: events,
        status: status,
      );

  /// The JSON form of the span.
  Map<String, Object?> toJson() => {
        'traceId': traceId,
        'spanId': spanId,
        if (parentSpanId != null && parentSpanId!.isNotEmpty)
          'parentSpanId': parentSpanId,
        'name': name,
        'kind': kind.index,
        'startTimeUnixNano': otlpUnixNano(startTime),
        'endTimeUnixNano': otlpUnixNano(endTime),
        if (attributes.isNotEmpty) 'attributes': otlpAttributes(attributes),
        if (events.isNotEmpty)
          'events': [for (final event in events) event.toJson()],
        if (status.code != OtlpStatusCode.unset) 'status': status.toJson(),
      };

  @override
  String toString() => 'OtlpSpan($name, trace: $traceId, span: $spanId'
      '${parentSpanId == null ? '' : ', parent: $parentSpanId'})';
}

/// The body of an OTLP/HTTP trace export request (`ExportTraceServiceRequest`)
/// in the JSON encoding of the protocol.
///
/// All [spans] are reported for one [resource] (the attributes of the
/// application, `service.name` first of all) and one instrumentation scope
/// ([scopeName], [scopeVersion]).
Map<String, Object?> encodeOtlpTraces({
  required Map<String, Object?> resource,
  required String scopeName,
  required Iterable<OtlpSpan> spans,
  String? scopeVersion,
}) =>
    {
      'resourceSpans': [
        {
          'resource': {'attributes': otlpAttributes(resource)},
          'scopeSpans': [
            {
              'scope': {
                'name': scopeName,
                if (scopeVersion != null && scopeVersion.isNotEmpty)
                  'version': scopeVersion,
              },
              'spans': [for (final span in spans) span.toJson()],
            },
          ],
        },
      ],
    };

/// [attributes] as the list of key-value pairs OTLP uses. `null` values are
/// left out.
List<Map<String, Object?>> otlpAttributes(Map<String, Object?> attributes) => [
      for (final MapEntry(:key, :value) in attributes.entries)
        if (value != null) {'key': key, 'value': otlpAnyValue(value)},
    ];

/// [value] as an OTLP `AnyValue`.
///
/// Integers are written as strings, as the JSON encoding of 64-bit numbers
/// requires.
Map<String, Object?> otlpAnyValue(Object? value) => switch (value) {
      null => const {},
      final String text => {'stringValue': text},
      final bool flag => {'boolValue': flag},
      final int number => {'intValue': '$number'},
      final double number when number.isFinite => {'doubleValue': number},
      // JSON has no literal for these; the protocol takes them as strings.
      final double number => {
          'doubleValue': number.isNaN
              ? 'NaN'
              : (number > 0 ? 'Infinity' : '-Infinity'),
        },
      final Map<Object?, Object?> map => {
          'kvlistValue': {
            'values': [
              for (final MapEntry(:key, :value) in map.entries)
                if (value != null)
                  {'key': '$key', 'value': otlpAnyValue(value)},
            ],
          },
        },
      final Iterable<Object?> items => {
          'arrayValue': {
            'values': [for (final item in items) otlpAnyValue(item)],
          },
        },
      _ => {'stringValue': '$value'},
    };

/// [time] in nanoseconds since the Unix epoch, as the decimal string OTLP
/// expects. The precision is that of [DateTime]: microseconds.
String otlpUnixNano(DateTime time) => '${time.microsecondsSinceEpoch}000';

/// A new trace id: 32 hexadecimal digits that are not all zero.
String newTraceId(Random random) => _randomHex(random, 16);

/// A new span id: 16 hexadecimal digits that are not all zero.
String newSpanId(Random random) => _randomHex(random, 8);

/// Whether [id] can be a trace id: 32 lower-case hexadecimal digits, not all
/// of them zero.
bool isValidTraceId(String id) => _isValidId(id, 32);

/// Whether [id] can be a span id: 16 lower-case hexadecimal digits, not all
/// of them zero.
bool isValidSpanId(String id) => _isValidId(id, 16);

/// Whether the trace [traceId] is among the share [rate] of traces that are
/// kept, `1.0` being all of them and `0.0` none.
///
/// The decision depends on the id alone, so every span of a trace gets the
/// same one wherever it is made. It is the rule of OpenTelemetry's
/// `TraceIdRatioBased` sampler at a precision of 52 bits.
bool isTraceSampled(String traceId, double rate) {
  if (rate >= 1) return true;
  if (rate <= 0) return false;
  if (traceId.length < 32) return true;
  // 13 hexadecimal digits are 52 bits, which a double holds exactly on every
  // platform.
  final sample = int.tryParse(traceId.substring(16, 29), radix: 16);
  if (sample == null) return true;
  return sample / _twoToThe52 < rate;
}

const double _twoToThe52 = 4503599627370496;

String _randomHex(Random random, int bytes) {
  while (true) {
    final buffer = StringBuffer();
    var nonZero = false;
    for (var i = 0; i < bytes; i++) {
      final byte = random.nextInt(256);
      if (byte != 0) nonZero = true;
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    if (nonZero) return buffer.toString();
  }
}

final _hex = RegExp(r'^[0-9a-f]+$');

bool _isValidId(String id, int length) =>
    id.length == length && _hex.hasMatch(id) && id.contains(RegExp('[1-9a-f]'));
