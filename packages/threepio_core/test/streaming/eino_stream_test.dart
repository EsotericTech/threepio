// Ports of the tests in eino `schema/stream_test.go` (v0.9.22).
//
// Go's goroutines and sleeps are replaced by futures and explicit steps; no
// test waits on a real timer.
import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';
import 'package:threepio_core/src/streaming/stream_utils.dart';

/// Lets every already scheduled microtask and zero-delay timer run.
Future<void> pumpEventQueue() => Future<void>.delayed(Duration.zero);

/// Sends [items] with back-pressure and closes the writer, like the sending
/// goroutine of the Go tests. Completes with the number of accepted items.
Future<int> produce<T>(StreamWriter<T> writer, Iterable<T> items) async {
  var accepted = 0;
  for (final item in items) {
    if (await writer.sendAsync(item)) break;
    accepted++;
  }
  await writer.close();
  return accepted;
}

/// Reads [reader] to its end and returns the values and the errors, like the
/// receive loops of the Go tests.
Future<(List<T>, List<Object>)> drain<T>(StreamReader<T> reader) async {
  final values = <T>[];
  final errors = <Object>[];
  while (true) {
    try {
      values.add(await reader.recv());
    } on StreamEOFException {
      return (values, errors);
    } catch (error) {
      errors.add(error);
    }
  }
}

void main() {
  // TestStream
  test('a sender on an unbuffered pipe stops when the reader closes', () async {
    final (reader, writer) = pipe<int>();
    final sending = produce(writer, List.generate(10, (i) => i));

    final received = <int>[];
    for (var i = 0; i < 5; i++) {
      received.add(await reader.recv());
    }
    await reader.close();

    expect(received, [0, 1, 2, 3, 4]);
    // The sixth send was waiting for a receiver and learned of the close.
    expect(await sending, 5);
    expect(writer.isClosed, isTrue);
  });

  // TestStreamCopy
  test('two copies of a pipe both receive everything', () async {
    final (reader, writer) = pipe<String>(capacity: 10);
    final copies = reader.copy(2);

    writer
      ..send('a')
      ..send('b')
      ..send('c');
    await writer.close();

    expect((await drain(copies[0])).$1, ['a', 'b', 'c']);
    expect((await drain(copies[1])).$1, ['a', 'b', 'c']);

    for (final copy in copies) {
      await copy.close();
    }
  });

  // TestNewStreamCopy
  group('copies over a shared buffer', () {
    test('a copy waiting for the next item does not hold up the others',
        () async {
      final (reader, writer) = pipe<String>(capacity: 1);
      final copies = reader.copy(2);

      writer.send('a');
      expect(await copies[0].recv(), 'a');

      // The first copy now waits for an item that was not sent yet.
      var firstGotSecond = false;
      final second = copies[0].recv().then((value) {
        firstGotSecond = true;
        return value;
      });
      await pumpEventQueue();
      expect(firstGotSecond, isFalse);

      // The other copy still gets the first item at once.
      expect(await copies[1].recv(), 'a');
      expect(firstGotSecond, isFalse);

      writer.send('a');
      await writer.close();

      expect(await second, 'a');
      expect((await drain(copies[0])).$1, isEmpty);
      expect((await drain(copies[1])).$1, ['a']);

      await copies[0].close();
      await copies[1].close();
    });

    test('a copy keeps reading when another one is closed, even twice',
        () async {
      final (reader, writer) = pipe<String>(capacity: 1);
      final copies = reader.copy(2);

      writer.send('a');
      expect(await copies[0].recv(), 'a');
      final second = copies[0].recv();
      await pumpEventQueue();

      await copies[1].close();
      await copies[1].close();

      expect(writer.send('a'), isFalse);
      await writer.close();

      expect(await second, 'a');
      await expectLater(copies[0].recv(), throwsA(isA<StreamEOFException>()));
      await copies[0].close();
    });

    test('a hundred copies each receive a thousand items in order', () async {
      final (reader, writer) = pipe<int>(capacity: 2);
      const n = 1000;
      const m = 100;
      final sending = produce(writer, List.generate(n, (i) => i));

      final copies = reader.copy(m);
      final results = await Future.wait([
        for (final copy in copies)
          () async {
            final (values, errors) = await drain(copy);
            await copy.close();
            expect(errors, isEmpty);
            return values;
          }(),
      ]);

      expect(await sending, n);
      final expected = List.generate(n, (i) => i);
      for (final values in results) {
        expect(values, expected);
      }
    });

    test('copies may stop early; the source is released by the last close',
        () async {
      final (reader, writer) = pipe<int>(capacity: 20);
      const n = 1000;
      const m = 100;
      final sending = produce(writer, List.generate(n, (i) => i));

      reader.setAutomaticClose();
      final copies = reader.copy(m);
      var sourceReleased = false;
      unawaited(reader.done.then((_) => sourceReleased = true));

      await Future.wait([
        for (var index = 0; index < m; index++)
          () async {
            final copy = copies[index];
            var received = 0;
            while (true) {
              // Even copies give up after as many items as their index.
              if (index.isEven && received == index) break;
              try {
                expect(await copy.recv(), received);
              } on StreamEOFException {
                break;
              }
              received++;
            }
            if (index.isOdd) expect(received, n);
            if (index < m - 1) expect(sourceReleased, isFalse);
            await copy.close();
          }(),
      ]);

      await sending;
      await pumpEventQueue();
      expect(sourceReleased, isTrue);
    });

    test('copies that are never closed leave the source open', () async {
      final (reader, writer) = pipe<int>(capacity: 20);
      const n = 1000;
      final sending = produce(writer, List.generate(n, (i) => i));

      var sourceReleased = false;
      unawaited(reader.done.then((_) => sourceReleased = true));
      final copies = reader.copy(4);

      await Future.wait([
        for (final copy in copies)
          () async {
            copy.setAutomaticClose();
            final (values, errors) = await drain(copy);
            expect(errors, isEmpty);
            expect(values, List.generate(n, (i) => i));
          }(),
      ]);

      expect(await sending, n);
      await pumpEventQueue();
      expect(sourceReleased, isFalse);
    });
  });

  // TestCopy
  test('copies of copies of copies, for every capacity and count', () async {
    Future<void> check(StreamReader<int> reader) async {
      for (var i = 0; i < 10; i++) {
        expect(await reader.recv(), i);
      }
      await expectLater(reader.recv(), throwsA(isA<StreamEOFException>()));
      await reader.close();
    }

    for (var capacity = 0; capacity < 10; capacity++) {
      for (var n = 2; n < 10; n++) {
        final (reader, writer) = pipe<int>(capacity: capacity);
        final sending = produce(writer, List.generate(10, (i) => i));

        var copies = reader.copy(n);
        await check(copies[0]);
        copies = copies[1].copy(n);
        await check(copies[0]);
        copies = copies[1].copy(n);
        await check(copies[0]);

        expect(await sending, 10, reason: 'capacity $capacity, $n copies');
      }
    }
  });

  // TestCopy5
  test('a copy reports the end of the stream again and again', () async {
    final (reader, writer) = pipe<int>();
    final sending = produce(writer, List.generate(10, (i) => i));

    final copies = reader.copy(5);
    await pumpEventQueue();

    for (var i = 0; i < 10; i++) {
      expect(await copies[0].recv(), i);
    }
    await expectLater(copies[0].recv(), throwsA(isA<StreamEOFException>()));
    await expectLater(copies[0].recv(), throwsA(isA<StreamEOFException>()));

    expect(await sending, 10);
    for (final copy in copies) {
      await copy.close();
    }
  });

  // TestStreamReaderWithConvert
  test('an error of the converter is delivered and the stream goes on',
      () async {
    final (reader, writer) = pipe<int>(capacity: 2);

    final converted = reader.convert<int>((value) {
      if (value == 1) throw Exception('mock err');
      return value;
    })
      ..setAutomaticClose();

    writer
      ..send(1)
      ..send(2);
    await writer.close();

    final (values, errors) = await drain(converted);

    expect(errors, hasLength(1));
    expect(errors.single.toString(), contains('mock err'));
    expect(values.fold<int>(0, (sum, value) => sum + value), 2);
  });

  // TestStreamReaderWithConvert_ErrWrapperContinue
  group('errWrapper returning null', () {
    test('skips the errors of the source', () async {
      final (reader, writer) = pipe<int>(capacity: 5);
      writer
        ..send(1)
        ..sendError(Exception('transient error 1'))
        ..send(2)
        ..sendError(Exception('transient error 2'))
        ..send(3);
      await writer.close();

      var wrapperCalls = 0;
      final converted = reader.convert<int>(
        (value) => value,
        errWrapper: (error) {
          wrapperCalls++;
          return null;
        },
      );

      final (values, errors) = await drain(converted);

      expect(errors, isEmpty);
      expect(values, [1, 2, 3]);
      expect(wrapperCalls, 2);
    });

    test('skips an error in front of the first item', () async {
      final (reader, writer) = pipe<int>(capacity: 3);
      writer
        ..sendError(Exception('skip me'))
        ..send(42);
      await writer.close();

      final converted =
          reader.convert<int>((value) => value, errWrapper: (error) => null);

      expect(await converted.recv(), 42);
      await converted.close();
    });
  });

  // TestArrayStreamCombined
  test('an array and a pipe merge into one stream of all their items',
      () async {
    final array = StreamReader.fromIterable([0, 1, 2]);
    final (reader, writer) = pipe<int>(capacity: 3);
    for (var i = 3; i < 6; i++) {
      writer.send(i);
    }
    await writer.close();

    final merged = mergeStreamReaders([array, reader])..setAutomaticClose();

    final seen = <int>{};
    for (var i = 0; i < 6; i++) {
      final item = await merged.recv();
      expect(seen.add(item), isTrue, reason: 'item $item came twice');
    }
    await expectLater(merged.recv(), throwsA(isA<StreamEOFException>()));
    expect(seen, {0, 1, 2, 3, 4, 5});
  });

  // TestMultiStream
  test('a merge of ten pipes keeps the order within each of them', () async {
    final random = Random(20261105);
    final readers = <StreamReader<int>>[];
    var total = 0;
    for (var source = 0; source < 10; source++) {
      final size = random.nextInt(10) + 1;
      total += size;
      final (reader, writer) = pipe<int>(capacity: size);
      for (var j = 1; j <= size; j++) {
        writer.send((j & 0xffff) + (source << 16));
      }
      await writer.close();
      readers.add(reader);
    }

    final merged = mergeStreamReaders(readers);
    final last = List.filled(10, 0);
    for (var i = 0; i < total; i++) {
      final item = await merged.recv();
      expect(item & 0xffff, greaterThan(last[item >> 16]));
      last[item >> 16] = item & 0xffff;
    }
    await expectLater(merged.recv(), throwsA(isA<StreamEOFException>()));
    await merged.close();
  });

  // TestMergeNamedStreamReaders
  group('mergeNamedStreamReaders', () {
    /// Reads a named merge to its end.
    Future<({List<String> data, List<String> ended, List<Object> errors})>
        drainNamed(StreamReader<String> merged) async {
      final data = <String>[];
      final ended = <String>[];
      final errors = <Object>[];
      while (true) {
        try {
          data.add(await merged.recv());
        } on SourceEOFException catch (e) {
          ended.add(e.sourceName);
        } on StreamEOFException {
          return (data: data, ended: ended, errors: errors);
        } catch (error) {
          errors.add(error);
        }
      }
    }

    test('reports the end of every source by name (BasicSourceEOF)', () async {
      final (reader1, writer1) = pipe<String>(capacity: 2);
      final (reader2, writer2) = pipe<String>(capacity: 2);
      final merged = mergeNamedStreamReaders({
        'stream1': reader1,
        'stream2': reader2,
      })
        ..setAutomaticClose();

      final sending = [
        produce(writer1, ['data1-1', 'data1-2']),
        produce(writer2, ['data2-1', 'data2-2', 'data2-3']),
      ];

      final result = await drainNamed(merged);
      await Future.wait(sending);

      expect(result.errors, isEmpty);
      expect(result.ended, unorderedEquals(['stream1', 'stream2']));
      expect(
        result.data.where((item) => item.startsWith('data1')),
        ['data1-1', 'data1-2'],
      );
      expect(
        result.data.where((item) => item.startsWith('data2')),
        ['data2-1', 'data2-2', 'data2-3'],
      );
    });

    test('reports a source that ends without an item (EmptyStream)', () async {
      final (reader1, writer1) = pipe<String>(capacity: 2);
      final (reader2, writer2) = pipe<String>(capacity: 2);
      await writer1.close();

      final merged = mergeNamedStreamReaders({'empty': reader1, 'data': reader2})
        ..setAutomaticClose();
      final sending = produce(writer2, ['test-data']);

      final result = await drainNamed(merged);
      await sending;

      expect(result.ended, unorderedEquals(['empty', 'data']));
      expect(result.data, ['test-data']);
    });

    test('takes arrays as sources too (ArraySource)', () async {
      final (reader1, writer1) = pipe<String>(capacity: 2);
      final (reader2, writer2) = pipe<String>(capacity: 2);
      final reader3 =
          StreamReader.fromIterable(['data3-1', 'data3-2', 'data3-3']);

      final merged = mergeNamedStreamReaders({
        'stream1': reader1,
        'stream2': reader2,
        'stream3': reader3,
      })
        ..setAutomaticClose();

      final sending = () async {
        await writer1.sendAsync('data1');
        await writer1.close();
        await writer2.sendAsync('data2-1');
        await writer2.sendAsync('data2-2');
        await writer2.close();
      }();

      final result = await drainNamed(merged);
      await sending;

      expect(result.ended, hasLength(3));
      expect(result.ended.toSet(), {'stream1', 'stream2', 'stream3'});
      expect(result.data, hasLength(6));
    });

    test('passes the errors of its sources on (ErrorPropagation)', () async {
      final (reader1, writer1) = pipe<String>(capacity: 2);
      final (reader2, writer2) = pipe<String>(capacity: 2);
      final merged = mergeNamedStreamReaders({
        'normal': reader1,
        'error': reader2,
      });

      final testError = Exception('test error');
      writer1.send('normal-data');
      await writer1.close();
      writer2.sendError(testError);
      await writer2.close();

      final result = await drainNamed(merged);
      await merged.close();

      expect(result.errors, [same(testError)]);
      expect(result.data, ['normal-data']);
      expect(result.ended, unorderedEquals(['normal', 'error']));
    });

    test('reports the end of a single source as well', () async {
      final merged = mergeNamedStreamReaders({
        'only': StreamReader.fromIterable(['a']),
      });

      final result = await drainNamed(merged);

      expect(result.data, ['a']);
      expect(result.ended, ['only']);
    });
  });
}
