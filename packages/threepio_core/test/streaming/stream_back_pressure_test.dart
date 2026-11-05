// Back-pressure, laziness and close-while-waiting for every kind of reader.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';
import 'package:threepio_core/src/streaming/stream_utils.dart';

/// Lets every already scheduled microtask and zero-delay timer run.
Future<void> pumpEventQueue() => Future<void>.delayed(Duration.zero);

/// Whether [future] has completed by now.
Future<bool> isDone(Future<Object?> future) async {
  var done = false;
  unawaited(future.then((_) => done = true, onError: (_) => done = true));
  await pumpEventQueue();
  return done;
}

final throwsClosed = throwsA(isA<StreamClosedException>());
final throwsEof = throwsA(isA<StreamEOFException>());

/// A reader that is not one of the library's own.
class CountingReader implements StreamReader<int> {
  CountingReader(this.count);

  final int count;
  int next = 0;
  bool closed = false;
  bool automaticClose = false;

  @override
  Future<int> recv() async {
    if (closed) throw const StreamClosedException();
    if (next >= count) throw const StreamEOFException();
    return next++;
  }

  @override
  Future<void> close() async => closed = true;

  @override
  void setAutomaticClose() => automaticClose = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('pipe', () {
    test('sendAsync on capacity 0 completes when the item was received',
        () async {
      final (reader, writer) = pipe<int>();

      final sent = writer.sendAsync(1);
      expect(await isDone(sent), isFalse);

      expect(await reader.recv(), 1);
      expect(await sent, isFalse);
      await reader.close();
    });

    test('sendAsync completes at once when a recv is waiting', () async {
      final (reader, writer) = pipe<int>();

      final received = reader.recv();
      expect(await writer.sendAsync(1), isFalse);
      expect(await received, 1);
      await reader.close();
    });

    test('sendAsync waits only once the capacity is used up', () async {
      final (reader, writer) = pipe<int>(capacity: 2);

      expect(await isDone(writer.sendAsync(1)), isTrue);
      expect(await isDone(writer.sendAsync(2)), isTrue);
      final third = writer.sendAsync(3);
      final fourth = writer.sendAsync(4);
      expect(await isDone(third), isFalse);

      // Each received item frees one slot, for the sender that waited longest.
      expect(await reader.recv(), 1);
      expect(await third, isFalse);
      expect(await isDone(fourth), isFalse);

      expect(await reader.recv(), 2);
      expect(await fourth, isFalse);

      expect(await reader.collectAllAfter(writer), [3, 4]);
    });

    test('send never waits and counts against the capacity', () async {
      final (reader, writer) = pipe<int>(capacity: 1);

      expect(writer.send(1), isFalse);
      expect(writer.send(2), isFalse);
      final third = writer.sendAsync(3);
      expect(await isDone(third), isFalse);

      expect(await reader.recv(), 1);
      expect(await isDone(third), isFalse, reason: 'still behind item 2');
      expect(await reader.recv(), 2);
      expect(await third, isFalse);

      expect(await reader.collectAllAfter(writer), [3]);
    });

    test('sendErrorAsync waits like sendAsync', () async {
      final (reader, writer) = pipe<int>();

      final sent = writer.sendErrorAsync(const FormatException('broken'));
      expect(await isDone(sent), isFalse);

      await expectLater(reader.recv(), throwsFormatException);
      expect(await sent, isFalse);
      await reader.close();
    });

    test('closing the reader completes waiting senders with true', () async {
      final (reader, writer) = pipe<int>(capacity: 1);
      await writer.sendAsync(1);
      final waiting = [writer.sendAsync(2), writer.sendAsync(3)];

      await reader.close();

      expect(await Future.wait(waiting), [true, true]);
      expect(await writer.sendAsync(4), isTrue);
    });

    test('sendAsync after the writer closed completes with true', () async {
      final (reader, writer) = pipe<int>(capacity: 1);
      await writer.close();

      expect(await writer.sendAsync(1), isTrue);
      await expectLater(reader.recv(), throwsEof);
    });

    test('items sent before the writer closed are still received', () async {
      final (reader, writer) = pipe<int>();
      final sent = writer.sendAsync(1);
      await writer.close();

      expect(await reader.recv(), 1);
      expect(await sent, isFalse);
      await expectLater(reader.recv(), throwsEof);
    });

    test('rejects a negative capacity', () {
      expect(() => pipe<int>(capacity: -1), throwsArgumentError);
    });
  });

  group('fromStream', () {
    test('pauses the subscription while the reader falls behind', () async {
      final controller = StreamController<int>();
      final reader = StreamReader.fromStream(controller.stream);

      for (var i = 0; i < 63; i++) {
        controller.add(i);
      }
      await pumpEventQueue();
      expect(controller.isPaused, isFalse);

      controller.add(63);
      await pumpEventQueue();
      expect(controller.isPaused, isTrue);

      // Reading down to the low-water mark resumes it.
      for (var i = 0; i < 47; i++) {
        expect(await reader.recv(), i);
      }
      expect(controller.isPaused, isTrue);
      expect(await reader.recv(), 47);
      expect(controller.isPaused, isFalse);

      await controller.close();
      expect(await reader.collectAll(), List.generate(16, (i) => i + 48));
      await reader.close();
    });

    test('close while a recv waits cancels the subscription', () async {
      final controller = StreamController<int>();
      final reader = StreamReader.fromStream(controller.stream);

      final waiting = expectLater(reader.recv(), throwsClosed);
      await reader.close();

      await waiting;
      expect(controller.hasListener, isFalse);
    });
  });

  group('array', () {
    test('never waits, not even for the end', () async {
      final reader = StreamReader.fromIterable([1]);
      final results = <Object>[];

      unawaited(reader.recv().then(results.add));
      unawaited(reader.recv().then(results.add, onError: results.add));
      await Future<void>.microtask(() {});
      await Future<void>.microtask(() {});

      expect(results, [1, isA<StreamEOFException>()]);
    });

    test('recv after close throws StreamClosedException', () async {
      final reader = StreamReader.fromIterable([1, 2]);
      expect(await reader.recv(), 1);

      await reader.close();

      await expectLater(reader.recv(), throwsClosed);
    });

    test('copies start where the original was', () async {
      final reader = StreamReader.fromIterable([1, 2, 3]);
      expect(await reader.recv(), 1);

      final copies = reader.copy(2);

      expect(await copies[0].collectAll(), [2, 3]);
      expect(await copies[1].collectAll(), [2, 3]);
    });

    test('is released when the last of its copies is closed', () async {
      final reader = StreamReader.fromIterable([1, 2]);
      final copies = reader.copy(2);
      var released = false;
      unawaited(reader.done.then((_) => released = true));

      await copies[0].close();
      await pumpEventQueue();
      expect(released, isFalse);

      await copies[1].close();
      await pumpEventQueue();
      expect(released, isTrue);
    });

    test('is not affected by later changes to the iterable', () async {
      final items = [1, 2];
      final reader = StreamReader.fromIterable(items);

      items.add(3);

      expect(await reader.collectAll(), [1, 2]);
    });
  });

  group('convert', () {
    test('takes nothing from its source before recv is called', () async {
      final (reader, writer) = pipe<int>();
      var conversions = 0;
      final converted = reader.convert<int>((x) {
        conversions++;
        return x * 2;
      });

      final first = writer.sendAsync(1);
      final second = writer.sendAsync(2);
      expect(await isDone(first), isFalse);
      expect(conversions, 0);

      expect(await converted.recv(), 2);
      expect(await first, isFalse);
      expect(conversions, 1);
      expect(await isDone(second), isFalse, reason: 'nothing is read ahead');

      expect(await converted.recv(), 4);
      expect(await second, isFalse);
      await converted.close();
    });

    test('close while recv waits for the source', () async {
      final (reader, writer) = pipe<int>();
      final converted = reader.convert<int>((x) => x);

      final waiting = expectLater(converted.recv(), throwsClosed);
      await converted.close();

      await waiting;
      expect(writer.send(1), isTrue);
    });

    test('close while recv waits for an asynchronous converter', () async {
      final gate = Completer<int>();
      final converted =
          StreamReader.fromIterable([1]).convert<int>((x) => gate.future);

      final waiting = expectLater(converted.recv(), throwsClosed);
      await pumpEventQueue();
      await converted.close();

      await waiting;
      gate.complete(1);
      await pumpEventQueue();
      await expectLater(converted.recv(), throwsClosed);
    });

    test('close while recv waits for an asynchronous onEof', () async {
      final gate = Completer<int?>();
      final converted = StreamReader.fromIterable(<int>[])
          .convert<int>((x) => x, onEof: () => gate.future);

      final waiting = expectLater(converted.recv(), throwsClosed);
      await pumpEventQueue();
      await converted.close();

      await waiting;
      gate.complete(null);
    });

    test('closing does not run the converter or onEof', () async {
      final (reader, writer) = pipe<int>();
      var calls = 0;
      final converted = reader.convert<int>(
        (x) {
          calls++;
          return x;
        },
        onEof: () {
          calls++;
          return 99;
        },
      );
      writer.send(1);

      expect(await converted.recv(), 1);
      final waiting = expectLater(converted.recv(), throwsClosed);
      await pumpEventQueue();
      await converted.close();
      await waiting;
      await pumpEventQueue();

      expect(calls, 1);
    });

    test('accepts an asynchronous converter and keeps the order', () async {
      final converted = StreamReader.fromIterable([3, 1, 2]).convert<String>(
        (x) async {
          // Later items would finish first if conversions ran concurrently.
          for (var i = 0; i < x; i++) {
            await Future<void>.microtask(() {});
          }
          return 'v$x';
        },
      );

      final pending = [converted.recv(), converted.recv(), converted.recv()];

      expect(await Future.wait(pending), ['v3', 'v1', 'v2']);
      await expectLater(converted.recv(), throwsEof);
    });

    test('an asynchronous converter can drop items and fail', () async {
      final converted = StreamReader.fromIterable([1, 2, 3]).convert<int>(
        (x) async {
          if (x == 1) throw const NoValueException();
          if (x == 2) throw const FormatException('two');
          return x;
        },
      );

      await expectLater(converted.recv(), throwsFormatException);
      expect(await converted.recv(), 3);
      await expectLater(converted.recv(), throwsEof);
    });

    test('errWrapper replaces the errors of the source only', () async {
      final (reader, writer) = pipe<int>();
      writer
        ..sendError(Exception('from source'))
        ..send(1);
      await writer.close();

      final converted = reader.convert<int>(
        (x) => throw Exception('from converter'),
        errWrapper: (error) => StateError('wrapped: $error'),
      );

      await expectLater(
        converted.recv(),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('from source')),
        ),
      );
      await expectLater(
        converted.recv(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'text',
            contains('from converter'),
          ),
        ),
      );
      await expectLater(converted.recv(), throwsEof);
    });

    test('an errWrapper that throws delivers what it threw', () async {
      final (reader, writer) = pipe<int>();
      writer.sendError(Exception('from source'));
      await writer.close();

      final converted = reader.convert<int>(
        (x) => x,
        errWrapper: (error) => throw const FormatException('wrapper broke'),
      );

      await expectLater(converted.recv(), throwsFormatException);
      await expectLater(converted.recv(), throwsEof);
    });

    test('ends after dropping every item of a long array', () async {
      final converted = StreamReader.fromIterable(List.filled(200000, 0))
          .convert<int>((x) => throw const NoValueException());

      await expectLater(converted.recv(), throwsEof);
    });

    test('ends after dropping every item of a long pipe', () async {
      final (reader, writer) = pipe<int>();
      final converted = reader.convert<int>(
        (x) async => throw const NoValueException(),
        errWrapper: (error) => null,
      );

      final end = expectLater(converted.recv(), throwsEof);
      for (var i = 0; i < 5000; i++) {
        await writer.sendAsync(i);
        await writer.sendErrorAsync(Exception('skipped'));
      }
      await writer.close();

      await end;
    });

    test('a converted reader can be copied and converted again', () async {
      final copies = StreamReader.fromIterable([1, 2, 3])
          .convert<int>((x) => x * 2)
          .convert<String>((x) => '$x')
          .copy(2);

      expect(await copies[0].collectAll(), ['2', '4', '6']);
      expect(await copies[1].collectAll(), ['2', '4', '6']);
    });
  });

  group('copy', () {
    test('pulls the source only as far as the fastest copy has read',
        () async {
      final (reader, writer) = pipe<int>();
      final copies = reader.copy(2);

      final first = writer.sendAsync(1);
      final second = writer.sendAsync(2);
      expect(await isDone(first), isFalse);

      expect(await copies[0].recv(), 1);
      expect(await first, isFalse);
      expect(await isDone(second), isFalse);

      // The slower copy reads from the shared buffer, not from the source.
      expect(await copies[1].recv(), 1);
      expect(await isDone(second), isFalse);

      expect(await copies[1].recv(), 2);
      expect(await second, isFalse);
      expect(await copies[0].recv(), 2);

      await copies[0].close();
      await copies[1].close();
    });

    test('two copies waiting for the same item both receive it', () async {
      final (reader, writer) = pipe<int>();
      final copies = reader.copy(2);

      final pending = [copies[0].recv(), copies[1].recv()];
      await pumpEventQueue();
      writer.send(7);

      expect(await Future.wait(pending), [7, 7]);
      await copies[0].close();
      await copies[1].close();
    });

    test('close while a copy waits leaves the other copy and the source alone',
        () async {
      final (reader, writer) = pipe<int>();
      final copies = reader.copy(2);

      final waiting = expectLater(copies[0].recv(), throwsClosed);
      final other = copies[1].recv();
      await pumpEventQueue();
      await copies[0].close();
      await waiting;

      expect(writer.send(1), isFalse);
      expect(await other, 1);

      await copies[1].close();
      expect(writer.send(2), isTrue);
    });

    test('closing every copy while they wait releases the source', () async {
      final (reader, writer) = pipe<int>();
      final copies = reader.copy(2);

      final waiting = [
        expectLater(copies[0].recv(), throwsClosed),
        expectLater(copies[1].recv(), throwsClosed),
      ];
      await pumpEventQueue();
      await copies[0].close();
      await copies[1].close();

      await Future.wait(waiting);
      expect(writer.isClosed, isTrue);
      await expectLater(reader.done, completes);
    });

    test('a copy can be copied again', () async {
      final (reader, writer) = pipe<int>();
      final copies = reader.copy(2);
      final grandchildren = copies[1].copy(2);

      writer
        ..send(1)
        ..send(2);
      await writer.close();

      expect(await copies[0].collectAll(), [1, 2]);
      expect(await grandchildren[0].collectAll(), [1, 2]);
      expect(await grandchildren[1].collectAll(), [1, 2]);
    });
  });

  group('merge', () {
    test('delivers items in the order they arrived', () async {
      final (reader1, writer1) = pipe<String>();
      final (reader2, writer2) = pipe<String>();
      final (reader3, writer3) = pipe<String>();
      final merged = mergeStreamReaders([reader1, reader2, reader3]);

      writer3.send('c1');
      writer1.send('a1');
      writer3.send('c2');
      writer2.send('b1');
      writer1.send('a2');
      await writer1.close();
      await writer2.close();
      await writer3.close();

      expect(await merged.collectAll(), ['c1', 'a1', 'c2', 'b1', 'a2']);
    });

    test('reads at most one item ahead from each source', () async {
      final (reader1, writer1) = pipe<int>();
      final (reader2, writer2) = pipe<int>();
      final merged = mergeStreamReaders([reader1, reader2]);

      final sent1 = [writer1.sendAsync(1), writer1.sendAsync(2)];
      final sent2 = [writer2.sendAsync(10), writer2.sendAsync(20)];
      expect(await isDone(sent1[0]), isFalse, reason: 'nothing read yet');

      expect(await merged.recv(), 1);
      // The first item of each source was taken, the second ones were not.
      expect(await isDone(sent1[0]), isTrue);
      expect(await isDone(sent2[0]), isTrue);
      expect(await isDone(sent1[1]), isFalse);
      expect(await isDone(sent2[1]), isFalse);

      expect(await merged.recv(), 2);
      expect(await isDone(sent1[1]), isTrue);
      expect(await isDone(sent2[1]), isFalse);

      await merged.close();
      expect(await sent2[1], isTrue);
    });

    test('close while recv waits releases every source', () async {
      final (reader1, writer1) = pipe<int>();
      final (reader2, writer2) = pipe<int>();
      final merged = mergeStreamReaders([reader1, reader2]);

      final waiting = expectLater(merged.recv(), throwsClosed);
      await pumpEventQueue();
      await merged.close();

      await waiting;
      expect(writer1.send(1), isTrue);
      expect(writer2.send(1), isTrue);
      await expectLater(reader1.done, completes);
      await expectLater(reader2.done, completes);
    });

    test('a named merge can be closed while recv waits', () async {
      final (reader1, writer1) = pipe<int>();
      final merged = mergeNamedStreamReaders({
        'open': reader1,
        'done': StreamReader.fromIterable(<int>[]),
      });

      await expectLater(
        merged.recv(),
        throwsA(
          isA<SourceEOFException>()
              .having((e) => e.sourceName, 'sourceName', 'done'),
        ),
      );
      final waiting = expectLater(merged.recv(), throwsClosed);
      await pumpEventQueue();
      await merged.close();

      await waiting;
      expect(writer1.send(1), isTrue);
    });

    test('a source that fails goes on afterwards', () async {
      final (reader1, writer1) = pipe<int>();
      final merged =
          mergeStreamReaders([reader1, StreamReader.fromIterable(<int>[])]);

      writer1
        ..send(1)
        ..sendError(const FormatException('broken'))
        ..send(2);
      await writer1.close();

      expect(await merged.recv(), 1);
      await expectLater(merged.recv(), throwsFormatException);
      expect(await merged.recv(), 2);
      await expectLater(merged.recv(), throwsEof);
    });

    test('ends after a thousand empty sources', () async {
      final merged = mergeStreamReaders([
        for (var i = 0; i < 1000; i++) StreamReader.fromIterable(<int>[]),
      ]);

      await expectLater(merged.recv(), throwsEof);
    });

    test('the same reader cannot be merged twice', () {
      final reader = StreamReader.fromIterable([1]);

      expect(() => mergeStreamReaders([reader, reader]), throwsStateError);
    });

    test('a merge that is refused leaves its readers usable', () async {
      final (first, firstWriter) = pipe<int>();
      final second = StreamReader.fromIterable([2]);
      final taken = StreamReader.fromIterable([3])..copy(2);

      expect(
        () => mergeStreamReaders([first, second, first]),
        throwsStateError,
      );
      expect(
        () => mergeNamedStreamReaders({'a': first, 'b': second, 'c': taken}),
        throwsStateError,
      );
      expect(
        () => concatStreamReaders([first, second, taken]),
        throwsStateError,
      );

      // Neither reader was handed over: both still read and close.
      firstWriter.send(1);
      expect(await first.recv(), 1);
      expect(await second.recv(), 2);
      await first.close();
      expect(firstWriter.send(9), isTrue);
    });
  });

  group('concat', () {
    test('does not touch a source before the one in front of it ended',
        () async {
      final (reader1, writer1) = pipe<int>();
      final (reader2, writer2) = pipe<int>();
      final concatenated = concatStreamReaders([reader1, reader2]);

      final early = writer2.sendAsync(10);
      writer1.send(1);

      expect(await concatenated.recv(), 1);
      expect(await isDone(early), isFalse);

      await writer1.close();
      expect(await concatenated.recv(), 10);
      expect(await early, isFalse);

      await writer2.close();
      await expectLater(concatenated.recv(), throwsEof);
    });

    test('close while recv waits releases every source', () async {
      final (reader1, writer1) = pipe<int>();
      final (reader2, writer2) = pipe<int>();
      final concatenated = concatStreamReaders([reader1, reader2]);

      final waiting = expectLater(concatenated.recv(), throwsClosed);
      await pumpEventQueue();
      await concatenated.close();

      await waiting;
      expect(writer1.send(1), isTrue);
      expect(writer2.send(1), isTrue);
    });

    test('ends after a thousand empty sources', () async {
      final concatenated = concatStreamReaders([
        for (var i = 0; i < 1000; i++) StreamReader.fromIterable(<int>[]),
      ]);

      await expectLater(concatenated.recv(), throwsEof);
    });
  });

  group('hand-over', () {
    test('an item a failed recv was waiting for goes to the new owner',
        () async {
      final (reader, writer) = pipe<int>();

      final waiting = expectLater(reader.recv(), throwsClosed);
      final converted = reader.convert<int>((x) => x * 10);
      await waiting;

      writer.send(1);
      await writer.close();

      expect(await converted.collectAll(), [10]);
    });

    test('a closed reader hands over an empty stream', () async {
      final reader = StreamReader.fromIterable([1, 2]);
      await reader.close();

      final converted = reader.convert<int>((x) => x);

      await expectLater(converted.recv(), throwsEof);
    });

    test('close on a reader that was handed over does nothing', () async {
      final (reader, writer) = pipe<int>();
      final converted = reader.convert<int>((x) => x);

      await reader.close();

      expect(writer.send(1), isFalse);
      expect(await converted.recv(), 1);
      await converted.close();
    });

    test('a reader can be handed over only once', () {
      final reader = StreamReader.fromIterable([1]);
      reader.copy(2);

      expect(() => reader.copy(2), throwsStateError);
      expect(() => reader.convert<int>((x) => x), throwsStateError);
      expect(
        () => concatStreamReaders([reader, StreamReader.fromIterable([2])]),
        throwsStateError,
      );
    });
  });

  group('readers from elsewhere', () {
    test('are merged and concatenated through their public members',
        () async {
      final merged = mergeStreamReaders<int>([
        CountingReader(2),
        StreamReader.fromIterable([10]),
      ]);
      expect((await merged.collectAll())..sort(), [0, 1, 10]);

      final foreign = CountingReader(2);
      final concatenated = concatStreamReaders<int>([
        StreamReader.fromIterable([10]),
        foreign,
      ])
        ..setAutomaticClose();
      expect(foreign.automaticClose, isTrue);
      expect(await concatenated.collectAll(), [10, 0, 1]);

      await concatenated.close();
      expect(foreign.closed, isTrue);
    });
  });

  group('readers from elsewhere, closed behind our back', () {
    test('count as ended, not as failing for ever', () async {
      final foreign = CountingReader(5);
      final concatenated = concatStreamReaders<int>([
        StreamReader.fromIterable([10]),
        foreign,
      ]).convert<int>((x) => x, errWrapper: (error) => null);

      expect(await concatenated.recv(), 10);
      expect(await concatenated.recv(), 0);
      await foreign.close();

      await expectLater(concatenated.recv(), throwsEof);
    });
  });

  group('nextOrNull', () {
    test('returns the items and then null', () async {
      final reader = StreamReader.fromIterable(['a', 'b']);
      final seen = <String>[];

      for (var item = await reader.nextOrNull();
          item != null;
          item = await reader.nextOrNull()) {
        seen.add(item);
      }

      expect(seen, ['a', 'b']);
      expect(await reader.nextOrNull(), isNull);
    });

    test('throws what recv throws, apart from the end', () async {
      final (reader, writer) = pipe<int>();
      writer.sendError(const FormatException('broken'));

      await expectLater(reader.nextOrNull(), throwsFormatException);
      await reader.close();
      await expectLater(reader.nextOrNull(), throwsClosed);
    });
  });

  group('asStream', () {
    test('closes the reader when the listener stops early', () async {
      final (reader, writer) = pipe<int>();
      writer
        ..send(1)
        ..send(2);

      await for (final item in reader.asStream()) {
        expect(item, 1);
        break;
      }

      expect(writer.send(3), isTrue);
      await expectLater(reader.done, completes);
    });

    test('closes the reader at the end of the stream', () async {
      final controller = StreamController<int>();
      final reader = StreamReader.fromStream(controller.stream);
      controller.add(1);
      unawaited(controller.close());

      expect(await reader.asStream().toList(), [1]);

      await expectLater(reader.done, completes);
    });

    test('cancelling while it waits for an item closes the reader', () async {
      final (reader, writer) = pipe<int>();
      final waiting = writer.sendAsync(1);
      final received = <int>[];

      final subscription = reader.asStream().listen(received.add);
      await pumpEventQueue();
      expect(received, [1]);
      expect(await waiting, isFalse);

      // The stream is now waiting for a second item that never comes.
      await subscription.cancel();

      expect(writer.isClosed, isTrue);
      await expectLater(reader.done, completes);
    });

    test('cancelling cancels the subscription behind fromStream', () async {
      final controller = StreamController<int>();
      final subscription =
          StreamReader.fromStream(controller.stream).asStream().listen(null);
      await pumpEventQueue();

      await subscription.cancel();

      expect(controller.hasListener, isFalse);
    });

    test('an await for loop pulls one item per turn', () async {
      final (reader, writer) = pipe<int>();
      final sent = [
        writer.sendAsync(1),
        writer.sendAsync(2),
        writer.sendAsync(3),
      ];

      await for (final item in reader.asStream()) {
        expect(item, 1);
        // While the body runs, nothing further is taken from the pipe.
        await pumpEventQueue();
        expect(await isDone(sent[1]), isFalse);
        break;
      }

      expect(await Future.wait(sent), [false, true, true]);
    });

    test('skips the end-of-source markers of a named merge', () async {
      final merged = mergeNamedStreamReaders({
        'a': StreamReader.fromIterable([1]),
        'b': StreamReader.fromIterable([2]),
      });

      expect(await merged.asStream().toList(), [1, 2]);
    });

    test('pulls at the pace of its listener', () async {
      final (reader, writer) = pipe<int>();
      final sent = [writer.sendAsync(1), writer.sendAsync(2)];

      final subscription = reader.asStream().listen(null)..pause();
      await pumpEventQueue();
      expect(await isDone(sent[1]), isFalse);

      await subscription.cancel();
      expect(await sent[1], isTrue);
    });

    test('passes errors on to the listener', () async {
      final (reader, writer) = pipe<int>();
      writer
        ..send(1)
        ..sendError(const FormatException('broken'));

      await expectLater(
        reader.asStream(),
        emitsInOrder(<Object>[1, emitsError(isFormatException), emitsDone]),
      );
    });
  });

  group('setAutomaticClose', () {
    test('changes nothing about reading and closing', () async {
      final (reader, writer) = pipe<int>();
      reader
        ..setAutomaticClose()
        ..setAutomaticClose();

      writer.send(1);
      expect(await reader.recv(), 1);
      await reader.close();
      reader.setAutomaticClose();

      expect(writer.send(2), isTrue);
    });

    test('is accepted by every kind of reader', () async {
      final (reader, _) = pipe<int>();
      final controller = StreamController<int>();
      final readers = <StreamReader<int>>[
        StreamReader.fromIterable([1]),
        StreamReader.fromStream(controller.stream),
        StreamReader.fromIterable([1]).convert<int>((x) => x),
        ...reader.copy(2),
        mergeStreamReaders([
          StreamReader.fromIterable([1]),
          StreamReader.fromIterable([2]),
        ]),
        concatStreamReaders([
          StreamReader.fromIterable([1]),
          StreamReader.fromIterable([2]),
        ]),
      ];

      for (final reader in readers) {
        reader.setAutomaticClose();
        await reader.close();
      }
      expect(controller.hasListener, isFalse);
    });
  });
}

extension on StreamReader<int> {
  /// Closes [writer] and returns what is left to read.
  Future<List<int>> collectAllAfter(StreamWriter<int> writer) async {
    await writer.close();
    final rest = await collectAll();
    await close();
    return rest;
  }
}
