import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';

final _start = DateTime.utc(2026, 11, 5, 12, 0, 0, 0, 123);
final _end = DateTime.utc(2026, 11, 5, 12, 0, 1);

void main() {
  group('otlpAnyValue', () {
    test('writes each kind of value the way the protocol has it', () {
      expect(otlpAnyValue('text'), {'stringValue': 'text'});
      expect(otlpAnyValue(true), {'boolValue': true});
      expect(otlpAnyValue(42), {'intValue': '42'});
      expect(otlpAnyValue(-7), {'intValue': '-7'});
      expect(otlpAnyValue(0.5), {'doubleValue': 0.5});
      expect(otlpAnyValue(null), isEmpty);
    });

    test('numbers JSON has no literal for are written as strings', () {
      expect(otlpAnyValue(double.nan), {'doubleValue': 'NaN'});
      expect(otlpAnyValue(double.infinity), {'doubleValue': 'Infinity'});
      expect(otlpAnyValue(double.negativeInfinity), {'doubleValue': '-Infinity'});
      expect(() => jsonEncode(otlpAnyValue(double.nan)), returnsNormally);
    });

    test('lists and maps are nested values', () {
      expect(otlpAnyValue(['a', 1]), {
        'arrayValue': {
          'values': [
            {'stringValue': 'a'},
            {'intValue': '1'},
          ],
        },
      });
      expect(otlpAnyValue({'k': true, 'gone': null, 3: 'x'}), {
        'kvlistValue': {
          'values': [
            {
              'key': 'k',
              'value': {'boolValue': true},
            },
            {
              'key': '3',
              'value': {'stringValue': 'x'},
            },
          ],
        },
      });
    });

    test('anything else is its toString', () {
      expect(otlpAnyValue(Uri.parse('https://x.dev')), {'stringValue': 'https://x.dev'});
      expect(otlpAnyValue(const Duration(seconds: 1)), {'stringValue': '0:00:01.000000'});
    });
  });

  test('otlpAttributes leaves null values out and keeps the order', () {
    expect(otlpAttributes({'b': 1, 'none': null, 'a': 'x'}), [
      {
        'key': 'b',
        'value': {'intValue': '1'},
      },
      {
        'key': 'a',
        'value': {'stringValue': 'x'},
      },
    ]);
  });

  test('otlpUnixNano is nanoseconds since the epoch as a decimal string', () {
    expect(otlpUnixNano(DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true)), '0000');
    expect(otlpUnixNano(DateTime.utc(1970, 1, 1, 0, 0, 1)), '1000000000');
    expect(otlpUnixNano(_start), '${_start.microsecondsSinceEpoch}000');
    expect(
      otlpUnixNano(_start.toLocal()),
      otlpUnixNano(_start),
      reason: 'the time zone does not matter',
    );
  });

  group('OtlpSpan', () {
    test('a minimal span has only what the protocol needs', () {
      final span = OtlpSpan(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        name: 'work',
        startTime: _start,
        endTime: _end,
      );
      expect(span.toJson(), {
        'traceId': 'a' * 32,
        'spanId': 'b' * 16,
        'name': 'work',
        'kind': 1,
        'startTimeUnixNano': otlpUnixNano(_start),
        'endTimeUnixNano': otlpUnixNano(_end),
      });
      expect(span.kind, OtlpSpanKind.internal);
      expect(span.status.code, OtlpStatusCode.unset);
      expect('$span', contains('work'));
    });

    test('a full span carries its parent, attributes, events and status', () {
      final span = OtlpSpan(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        parentSpanId: 'c' * 16,
        name: 'call',
        kind: OtlpSpanKind.client,
        startTime: _start,
        endTime: _end,
        attributes: const {'model': 'm', 'tokens': 3},
        events: [
          OtlpSpanEvent(
            name: 'exception',
            time: _end,
            attributes: const {'exception.message': 'boom'},
          ),
          OtlpSpanEvent(name: 'bare', time: _end),
        ],
        status: const OtlpStatus(code: OtlpStatusCode.error, message: 'boom'),
      );

      final json = span.toJson();
      expect(json['parentSpanId'], 'c' * 16);
      expect(json['kind'], 3);
      expect(json['attributes'], [
        {
          'key': 'model',
          'value': {'stringValue': 'm'},
        },
        {
          'key': 'tokens',
          'value': {'intValue': '3'},
        },
      ]);
      expect(json['events'], [
        {
          'timeUnixNano': otlpUnixNano(_end),
          'name': 'exception',
          'attributes': [
            {
              'key': 'exception.message',
              'value': {'stringValue': 'boom'},
            },
          ],
        },
        {'timeUnixNano': otlpUnixNano(_end), 'name': 'bare'},
      ]);
      expect(json['status'], {'message': 'boom', 'code': 2});
      expect(() => jsonEncode(json), returnsNormally);
    });

    test('withAttributes replaces the attributes and nothing else', () {
      final span = OtlpSpan(
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        parentSpanId: 'c' * 16,
        name: 'n',
        startTime: _start,
        endTime: _end,
        attributes: const {'a': 1},
        status: const OtlpStatus(code: OtlpStatusCode.ok),
      );
      final copy = span.withAttributes(const {'b': 2});

      expect(copy.attributes, {'b': 2});
      expect(span.attributes, {'a': 1});
      expect(copy.traceId, span.traceId);
      expect(copy.spanId, span.spanId);
      expect(copy.parentSpanId, span.parentSpanId);
      expect(copy.startTime, span.startTime);
      expect(copy.endTime, span.endTime);
      expect(copy.status.code, OtlpStatusCode.ok);
    });
  });

  test('OtlpStatus writes its code as a number and leaves an empty message out',
      () {
    expect(const OtlpStatus().toJson(), {'code': 0});
    expect(const OtlpStatus(code: OtlpStatusCode.ok).toJson(), {'code': 1});
    expect(
      const OtlpStatus(code: OtlpStatusCode.error, message: '').toJson(),
      {'code': 2},
    );
    expect('${const OtlpStatus(code: OtlpStatusCode.error, message: 'x')}',
        'OtlpStatus(error, x)');
  });

  test('encodeOtlpTraces wraps the spans in a resource and a scope', () {
    final span = OtlpSpan(
      traceId: 'a' * 32,
      spanId: 'b' * 16,
      name: 'n',
      startTime: _start,
      endTime: _end,
    );

    final body = encodeOtlpTraces(
      resource: const {'service.name': 'svc'},
      scopeName: 'scope',
      scopeVersion: '1.2.3',
      spans: [span],
    );
    expect(body, {
      'resourceSpans': [
        {
          'resource': {
            'attributes': [
              {
                'key': 'service.name',
                'value': {'stringValue': 'svc'},
              },
            ],
          },
          'scopeSpans': [
            {
              'scope': {'name': 'scope', 'version': '1.2.3'},
              'spans': [span.toJson()],
            },
          ],
        },
      ],
    });

    final withoutVersion = encodeOtlpTraces(
      resource: const {},
      scopeName: 'scope',
      spans: const [],
    );
    final scopeSpans = ((withoutVersion['resourceSpans']! as List).single
        as Map)['scopeSpans'] as List;
    expect((scopeSpans.single as Map)['scope'], {'name': 'scope'});
  });

  group('ids', () {
    test('new ids are lower-case hexadecimal of the right length', () {
      final random = Random(7);
      for (var i = 0; i < 50; i++) {
        final traceId = newTraceId(random);
        final spanId = newSpanId(random);
        expect(traceId, matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(spanId, matches(RegExp(r'^[0-9a-f]{16}$')));
        expect(isValidTraceId(traceId), isTrue);
        expect(isValidSpanId(spanId), isTrue);
      }
    });

    test('an id of all zeros is never produced', () {
      expect(newSpanId(_ZeroThenOne()), isNot('0' * 16));
      expect(newTraceId(_ZeroThenOne()), isNot('0' * 32));
    });

    test('what is not an id is recognised', () {
      expect(isValidTraceId('0' * 32), isFalse);
      expect(isValidTraceId('a' * 31), isFalse);
      expect(isValidTraceId('A' * 32), isFalse);
      expect(isValidTraceId('g' * 32), isFalse);
      expect(isValidTraceId(''), isFalse);
      expect(isValidSpanId('0' * 16), isFalse);
      expect(isValidSpanId('a' * 32), isFalse);
      expect(isValidSpanId('${'0' * 15}1'), isTrue);
    });
  });

  group('isTraceSampled', () {
    test('1 keeps every trace and 0 none', () {
      final random = Random(1);
      for (var i = 0; i < 20; i++) {
        final id = newTraceId(random);
        expect(isTraceSampled(id, 1), isTrue);
        expect(isTraceSampled(id, 2), isTrue);
        expect(isTraceSampled(id, 0), isFalse);
        expect(isTraceSampled(id, -1), isFalse);
      }
    });

    test('depends on the id alone and keeps about the asked share', () {
      final random = Random(42);
      final ids = [for (var i = 0; i < 2000; i++) newTraceId(random)];

      final kept = ids.where((id) => isTraceSampled(id, 0.25)).length;
      expect(kept, inInclusiveRange(420, 580));
      for (final id in ids.take(50)) {
        expect(isTraceSampled(id, 0.25), isTraceSampled(id, 0.25));
      }
    });

    test('a trace kept at a low rate is kept at every higher one', () {
      final random = Random(3);
      for (var i = 0; i < 500; i++) {
        final id = newTraceId(random);
        if (isTraceSampled(id, 0.1)) expect(isTraceSampled(id, 0.6), isTrue);
      }
    });

    test('the decision is made on the low half of the id', () {
      final low = '${'f' * 16}${'0' * 16}';
      final high = '${'0' * 16}${'f' * 16}';
      expect(isTraceSampled(low, 0.001), isTrue);
      expect(isTraceSampled(high, 0.999), isFalse);
    });

    test('an id it cannot read is kept', () {
      expect(isTraceSampled('short', 0.5), isTrue);
      expect(isTraceSampled('z' * 32, 0.5), isTrue);
    });
  });
}

/// A source of randomness whose first sixteen bytes are zero.
final class _ZeroThenOne implements Random {
  int _calls = 0;

  @override
  int nextInt(int max) => _calls++ < 16 ? 0 : 1;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
