import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';

OtlpSpan _span(String name) => OtlpSpan(
      traceId: 'a' * 32,
      spanId: 'b' * 16,
      name: name,
      startTime: DateTime.utc(2026),
      endTime: DateTime.utc(2026),
    );

void main() {
  test('spans come out in the order they went in', () {
    final queue = SpanQueue();
    expect(queue.isEmpty, isTrue);
    expect(queue.maxSize, 2048);

    for (final name in ['a', 'b', 'c']) {
      expect(queue.add(_span(name)), isTrue);
    }
    expect(queue.length, 3);
    expect(queue.isNotEmpty, isTrue);

    expect(queue.takeBatch(2).map((s) => s.name), ['a', 'b']);
    expect(queue.takeBatch(2).map((s) => s.name), ['c']);
    expect(queue.takeBatch(2), isEmpty);
    expect(queue.isEmpty, isTrue);
  });

  test('a full queue turns spans away and counts them', () {
    final queue = SpanQueue(maxSize: 2);

    expect(queue.add(_span('a')), isTrue);
    expect(queue.add(_span('b')), isTrue);
    expect(queue.add(_span('c')), isFalse);
    expect(queue.add(_span('d')), isFalse);
    expect(queue.length, 2);
    expect(queue.dropped, 2);

    queue.takeBatch(1);
    expect(queue.add(_span('e')), isTrue, reason: 'there is room again');
    expect(queue.takeAll().map((s) => s.name), ['b', 'e']);
    expect(queue.dropped, 2);
  });

  test('taking nothing takes nothing', () {
    final queue = SpanQueue()..add(_span('a'));
    expect(queue.takeBatch(0), isEmpty);
    expect(queue.length, 1);
    expect(queue.takeAll(), hasLength(1));
    expect(queue.takeAll(), isEmpty);
  });

  test('the size has to be positive', () {
    expect(() => SpanQueue(maxSize: 0), throwsArgumentError);
    expect(() => SpanQueue(maxSize: -1), throwsArgumentError);
  });

  test('a queue stays bounded however many spans arrive', () {
    final queue = SpanQueue(maxSize: 10);
    for (var i = 0; i < 10000; i++) {
      queue.add(_span('$i'));
    }
    expect(queue.length, 10);
    expect(queue.dropped, 9990);
  });
}
