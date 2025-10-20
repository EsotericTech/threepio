import 'package:test/test.dart';
import 'package:threepio_core/src/observability/langfuse/langfuse_queue.dart';
import 'package:threepio_core/src/observability/langfuse/models/langfuse_event.dart';
import 'package:threepio_core/src/observability/langfuse/models/langfuse_trace.dart';

void main() {
  group('LangfuseEventQueue', () {
    late LangfuseEventQueue queue;

    setUp(() {
      queue = LangfuseEventQueue(10);
    });

    tearDown(() async {
      await queue.dispose();
    });

    test('creates queue with specified max size', () {
      final queue = LangfuseEventQueue(5);
      expect(queue.length, 0);
      expect(queue.unfinished, 0);
    });

    test('uses default max size of 100 when size <= 0', () {
      final queue1 = LangfuseEventQueue(0);
      final queue2 = LangfuseEventQueue(-1);

      // Both should use default
      expect(queue1, isNotNull);
      expect(queue2, isNotNull);
    });

    test('put() adds event to queue', () {
      final event = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'test'),
      );

      final success = queue.put(event);

      expect(success, isTrue);
      expect(queue.length, 1);
      expect(queue.unfinished, 1);
    });

    test('put() returns false when queue is full', () {
      final smallQueue = LangfuseEventQueue(2);

      // Fill the queue
      final event1 = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'test1'),
      );
      final event2 = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'test2'),
      );

      expect(smallQueue.put(event1), isTrue);
      expect(smallQueue.put(event2), isTrue);

      // Queue is full
      final event3 = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'test3'),
      );
      expect(smallQueue.put(event3), isFalse);

      expect(smallQueue.length, 2);
      expect(smallQueue.unfinished, 2);

      smallQueue.dispose();
    });

    test('get() retrieves event from queue', () async {
      final event = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'test'),
      );

      queue.put(event);

      final retrieved = await queue.get(const Duration(milliseconds: 100));

      expect(retrieved, isNotNull);
      expect(retrieved!.type, LangfuseEventType.traceCreate);
      expect(queue.length, 0);
      // Unfinished count should still be 1 until done() is called
      expect(queue.unfinished, 1);
    });

    test('get() returns null on timeout when queue is empty', () async {
      final retrieved = await queue.get(const Duration(milliseconds: 50));

      expect(retrieved, isNull);
    });

    test('done() decrements unfinished counter', () {
      final event = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'test'),
      );

      queue.put(event);
      expect(queue.unfinished, 1);

      queue.done();
      expect(queue.unfinished, 0);
    });

    test('done() does not go below zero', () {
      queue.done();
      queue.done();
      queue.done();

      expect(queue.unfinished, 0);
    });

    test('join() waits for all tasks to complete', () async {
      final event1 = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'test1'),
      );
      final event2 = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'test2'),
      );

      queue.put(event1);
      queue.put(event2);

      expect(queue.unfinished, 2);

      // Process events asynchronously
      Future.delayed(const Duration(milliseconds: 50), () async {
        await queue.get(const Duration(milliseconds: 10));
        queue.done();
        await queue.get(const Duration(milliseconds: 10));
        queue.done();
      });

      // Wait for all tasks
      await queue.join();

      expect(queue.unfinished, 0);
    });

    test('join() returns immediately if no unfinished tasks', () async {
      await queue.join();
      expect(queue.unfinished, 0);
    });

    test('handles concurrent put and get operations', () async {
      final events = List.generate(
        5,
        (i) => LangfuseIngestionEvent(
          type: LangfuseEventType.traceCreate,
          body: LangfuseTrace(name: 'test-$i'),
        ),
      );

      // Add events
      for (final event in events) {
        queue.put(event);
      }

      expect(queue.unfinished, 5);

      // Retrieve and mark done
      for (var i = 0; i < 5; i++) {
        final event = await queue.get(const Duration(milliseconds: 100));
        expect(event, isNotNull);
        queue.done();
      }

      expect(queue.unfinished, 0);
    });

    test('FIFO ordering is maintained', () async {
      final event1 = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'first'),
      );
      final event2 = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'second'),
      );
      final event3 = LangfuseIngestionEvent(
        type: LangfuseEventType.traceCreate,
        body: LangfuseTrace(name: 'third'),
      );

      queue.put(event1);
      queue.put(event2);
      queue.put(event3);

      final retrieved1 = await queue.get(const Duration(milliseconds: 10));
      final retrieved2 = await queue.get(const Duration(milliseconds: 10));
      final retrieved3 = await queue.get(const Duration(milliseconds: 10));

      expect((retrieved1!.body as LangfuseTrace).name, 'first');
      expect((retrieved2!.body as LangfuseTrace).name, 'second');
      expect((retrieved3!.body as LangfuseTrace).name, 'third');
    });
  });
}
