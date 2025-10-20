import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

void main() {
  group('StreamReader', () {
    group('fromIterable', () {
      test('reads items from iterable', () async {
        final reader = StreamReader.fromIterable([1, 2, 3]);

        expect(await reader.recv(), 1);
        expect(await reader.recv(), 2);
        expect(await reader.recv(), 3);

        expect(
          () => reader.recv(),
          throwsA(isA<StreamEOFException>()),
        );

        await reader.close();
      });

      test('handles empty iterable', () async {
        final reader = StreamReader.fromIterable(<int>[]);

        expect(
          () => reader.recv(),
          throwsA(isA<StreamEOFException>()),
        );

        await reader.close();
      });
    });

    group('fromStream', () {
      test('reads items from stream', () async {
        final controller = StreamController<String>();
        final reader = StreamReader.fromStream(controller.stream);

        controller.add('a');
        controller.add('b');
        controller.add('c');
        await controller.close();

        expect(await reader.recv(), 'a');
        expect(await reader.recv(), 'b');
        expect(await reader.recv(), 'c');

        expect(
          () => reader.recv(),
          throwsA(isA<StreamEOFException>()),
        );

        await reader.close();
      });

      test('propagates errors from stream', () async {
        final controller = StreamController<String>();
        final reader = StreamReader.fromStream(controller.stream);

        controller.add('a');
        controller.addError(Exception('test error'));
        await controller.close();

        expect(await reader.recv(), 'a');
        expect(
          () => reader.recv(),
          throwsException,
        );

        await reader.close();
      });
    });

    group('collectAll', () {
      test('collects all items', () async {
        final reader = StreamReader.fromIterable([1, 2, 3]);

        final result = await reader.collectAll();
        expect(result, [1, 2, 3]);

        await reader.close();
      });

      test('returns empty list for empty stream', () async {
        final reader = StreamReader.fromIterable(<int>[]);

        final result = await reader.collectAll();
        expect(result, isEmpty);

        await reader.close();
      });
    });

    group('asStream', () {
      test('converts to dart stream', () async {
        final reader = StreamReader.fromIterable([1, 2, 3]);

        final items = await reader.asStream().toList();
        expect(items, [1, 2, 3]);

        await reader.close();
      });

      test('can be used with await for', () async {
        final reader = StreamReader.fromIterable(['a', 'b', 'c']);

        final items = <String>[];
        await for (final item in reader.asStream()) {
          items.add(item);
        }

        expect(items, ['a', 'b', 'c']);
        await reader.close();
      });
    });

    group('copy', () {
      test('creates multiple independent readers', () async {
        final reader = StreamReader.fromIterable([1, 2, 3]);
        final copies = reader.copy(2);

        expect(copies.length, 2);

        // Both copies should be able to read independently
        final first1 = await copies[0].recv();
        final first2 = await copies[1].recv();

        expect(first1, 1);
        expect(first2, 1);

        await copies[0].close();
        await copies[1].close();
      });

      test('returns single reader when n=1', () async {
        final reader = StreamReader.fromIterable([1, 2, 3]);
        final copies = reader.copy(1);

        expect(copies.length, 1);
        expect(copies[0], same(reader));

        await reader.close();
      });

      test('returns empty list when n=0', () {
        final reader = StreamReader.fromIterable([1, 2, 3]);
        final copies = reader.copy(0);

        expect(copies, isEmpty);
      });

      test('original reader becomes unusable after copy', () async {
        final reader = StreamReader.fromIterable([1, 2, 3]);
        final copies = reader.copy(2);

        // Original reader is now closed
        expect(
          () => reader.recv(),
          throwsA(isA<StreamClosedException>()),
        );

        await copies[0].close();
        await copies[1].close();
      });
    });

    group('transform', () {
      test('transforms elements', () async {
        final reader = StreamReader.fromIterable([1, 2]);
        final transformed = reader.transform<String>((n) => 'num_$n');

        expect(await transformed.recv(), 'num_1');
        expect(await transformed.recv(), 'num_2');

        await transformed.close();
      });

      test('filters elements with NoValueException', () async {
        final reader = StreamReader.fromIterable([1, 2, 3]);
        final filtered = reader.transform<int>((n) {
          if (n % 2 == 0) throw const NoValueException();
          return n * 2;
        });

        expect(await filtered.recv(), 2); // 1 * 2
        expect(await filtered.recv(), 6); // 3 * 2

        await filtered.close();
      });

      test('propagates transformation errors', () async {
        final reader = StreamReader.fromIterable([1, 2]);
        final transformed = reader.transform<int>((n) {
          if (n == 2) throw Exception('error at 2');
          return n * 2;
        });

        expect(await transformed.recv(), 2);
        expect(
          () => transformed.recv(),
          throwsException,
        );

        await transformed.close();
      });
    });

    group('close', () {
      test('throws when receiving after close', () async {
        final reader = StreamReader.fromIterable([1, 2, 3]);
        await reader.close();

        expect(
          () => reader.recv(),
          throwsA(isA<StreamClosedException>()),
        );
      });

      test('close is idempotent', () async {
        final reader = StreamReader.fromIterable([1, 2, 3]);

        await reader.close();
        await reader.close(); // Should not throw
      });

      test('done future completes after close', () async {
        final reader = StreamReader.fromIterable([1, 2, 3]);

        final doneFuture = reader.done;
        expect(doneFuture, isA<Future<void>>());

        await reader.close();
        await doneFuture; // Should complete
      });
    });

    group('exceptions', () {
      test('StreamEOFException has correct message', () {
        const exception = StreamEOFException();
        expect(exception.toString(), 'End of stream reached');
      });

      test('StreamClosedException has correct message', () {
        const exception = StreamClosedException();
        expect(exception.toString(), 'Attempted to receive from closed stream');
      });

      test('NoValueException has correct message', () {
        const exception = NoValueException();
        expect(exception.toString(), 'No value to emit');
      });

      test('SourceEOFException has correct message', () {
        final exception = SourceEOFException('stream1');
        expect(exception.toString(), 'EOF from source stream: stream1');
        expect(exception.sourceName, 'stream1');
      });
    });
  });
}
