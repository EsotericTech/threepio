import 'package:test/test.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';
import 'package:threepio_core/src/streaming/stream_utils.dart';

void main() {
  group('pipe', () {
    test('creates reader and writer pair', () async {
      final (reader, writer) = pipe<String>();

      expect(reader, isA<StreamReader<String>>());
      expect(writer, isNotNull);

      writer.send('test');
      await writer.close();

      expect(await reader.recv(), 'test');
      await reader.close();
    });

    test('pipe with capacity 0', () async {
      final (reader, writer) = pipe<int>(capacity: 0);

      writer.send(1);
      writer.send(2);
      await writer.close();

      expect(await reader.recv(), 1);
      expect(await reader.recv(), 2);

      await reader.close();
    });

    test('pipe with positive capacity', () async {
      final (reader, writer) = pipe<int>(capacity: 5);

      // Send multiple items
      for (var i = 0; i < 5; i++) {
        writer.send(i);
      }
      await writer.close();

      final results = await reader.collectAll();
      expect(results, [0, 1, 2, 3, 4]);

      await reader.close();
    });
  });

  group('mergeStreamReaders', () {
    test('merges multiple readers', () async {
      final reader1 = StreamReader.fromIterable([1, 2, 3]);
      final reader2 = StreamReader.fromIterable([4, 5, 6]);

      final merged = mergeStreamReaders([reader1, reader2]);
      final results = await merged.collectAll();

      // Results should contain all items (order may vary)
      expect(results.length, 6);
      expect(results.toSet(), {1, 2, 3, 4, 5, 6});

      await merged.close();
    });

    test('returns empty reader for empty list', () async {
      final merged = mergeStreamReaders(<StreamReader<int>>[]);
      final results = await merged.collectAll();

      expect(results, isEmpty);
      await merged.close();
    });

    test('returns single reader for single item list', () async {
      final reader = StreamReader.fromIterable([1, 2, 3]);
      final merged = mergeStreamReaders([reader]);

      expect(merged, same(reader));

      final results = await merged.collectAll();
      expect(results, [1, 2, 3]);

      await merged.close();
    });

    test('handles errors from source streams', () async {
      final (reader1, writer1) = pipe<int>();
      final reader2 = StreamReader.fromIterable([4, 5, 6]);

      final merged = mergeStreamReaders([reader1, reader2]);

      writer1.send(1);
      writer1.sendError(Exception('test error'));
      await writer1.close();

      // Should receive data before error
      final first = await merged.recv();
      expect([1, 4, 5, 6].contains(first), isTrue);

      // Eventually should hit the error
      var errorThrown = false;
      try {
        while (true) {
          await merged.recv();
        }
      } catch (e) {
        errorThrown = true;
      }

      expect(errorThrown, isTrue);
      await merged.close();
    });
  });

  group('mergeNamedStreamReaders', () {
    test('merges named readers', () async {
      final streams = {
        'stream1': StreamReader.fromIterable([1, 2]),
        'stream2': StreamReader.fromIterable([3, 4]),
      };

      final merged = mergeNamedStreamReaders(streams);
      final results = await merged.collectAll();

      expect(results.length, 4);
      expect(results.toSet(), {1, 2, 3, 4});

      await merged.close();
    });

    test('emits SourceEOFException when a stream ends', () async {
      final (reader1, writer1) = pipe<int>(capacity: 10);
      final (reader2, writer2) = pipe<int>(capacity: 10);

      final streams = {
        'stream1': reader1,
        'stream2': reader2,
      };

      final merged = mergeNamedStreamReaders(streams);

      // Close stream1
      writer1.send(1);
      await writer1.close();

      // Keep stream2 open
      writer2.send(2);

      var sourceEOFCaught = false;
      String? sourceName;

      try {
        while (true) {
          await merged.recv();
        }
      } on SourceEOFException catch (e) {
        sourceEOFCaught = true;
        sourceName = e.sourceName;
      } catch (e) {
        // Other exceptions
      }

      expect(sourceEOFCaught, isTrue);
      expect(sourceName, isNotNull);

      await writer2.close();
      await merged.close();
    });

    test('returns empty reader for empty map', () async {
      final merged = mergeNamedStreamReaders(<String, StreamReader<int>>{});
      final results = await merged.collectAll();

      expect(results, isEmpty);
      await merged.close();
    });

    test('returns single reader for single entry', () async {
      final reader = StreamReader.fromIterable([1, 2, 3]);
      final merged = mergeNamedStreamReaders({'only': reader});

      final results = await merged.collectAll();
      expect(results, [1, 2, 3]);

      await merged.close();
    });
  });

  group('concatStreamReaders', () {
    test('concatenates readers sequentially', () async {
      final reader1 = StreamReader.fromIterable([1, 2, 3]);
      final reader2 = StreamReader.fromIterable([4, 5, 6]);
      final reader3 = StreamReader.fromIterable([7, 8, 9]);

      final concatenated = concatStreamReaders([reader1, reader2, reader3]);
      final results = await concatenated.collectAll();

      // Should be in order
      expect(results, [1, 2, 3, 4, 5, 6, 7, 8, 9]);

      await concatenated.close();
    });

    test('returns empty reader for empty list', () async {
      final concatenated = concatStreamReaders(<StreamReader<int>>[]);
      final results = await concatenated.collectAll();

      expect(results, isEmpty);
      await concatenated.close();
    });

    test('returns single reader for single item list', () async {
      final reader = StreamReader.fromIterable([1, 2, 3]);
      final concatenated = concatStreamReaders([reader]);

      expect(concatenated, same(reader));

      final results = await concatenated.collectAll();
      expect(results, [1, 2, 3]);

      await concatenated.close();
    });

    test('handles empty streams in sequence', () async {
      final reader1 = StreamReader.fromIterable([1, 2]);
      final reader2 = StreamReader.fromIterable(<int>[]);
      final reader3 = StreamReader.fromIterable([3, 4]);

      final concatenated = concatStreamReaders([reader1, reader2, reader3]);
      final results = await concatenated.collectAll();

      expect(results, [1, 2, 3, 4]);

      await concatenated.close();
    });
  });

  group('copyStreamReader', () {
    test('creates multiple independent copies', () async {
      final original = StreamReader.fromIterable([1, 2, 3]);
      final copies = copyStreamReader(original, 3);

      expect(copies.length, 3);

      // All copies should read the same data
      final results = await Future.wait([
        copies[0].collectAll(),
        copies[1].collectAll(),
        copies[2].collectAll(),
      ]);

      expect(results[0], [1, 2, 3]);
      expect(results[1], [1, 2, 3]);
      expect(results[2], [1, 2, 3]);

      for (final copy in copies) {
        await copy.close();
      }
    });

    test('returns single reader when n=1', () {
      final original = StreamReader.fromIterable([1, 2, 3]);
      final copies = copyStreamReader(original, 1);

      expect(copies.length, 1);
      expect(copies[0], same(original));
    });

    test('handles n=0', () {
      final original = StreamReader.fromIterable([1, 2, 3]);
      final copies = copyStreamReader(original, 0);

      expect(copies, isEmpty);
    });
  });

  group('transformStreamReader', () {
    test('transforms elements', () async {
      final reader = StreamReader.fromIterable([1, 2, 3, 4]);
      final transformed = transformStreamReader(
        reader,
        (x) => x * 2,
      );

      final results = await transformed.collectAll();
      expect(results, [2, 4, 6, 8]);

      await transformed.close();
    });

    test('filters with NoValueException', () async {
      final reader = StreamReader.fromIterable([1, 2, 3, 4, 5, 6]);
      final filtered = transformStreamReader(reader, (x) {
        if (x % 2 == 0) throw const NoValueException();
        return x;
      });

      final results = await filtered.collectAll();
      expect(results, [1, 3, 5]);

      await filtered.close();
    });

    test('propagates transformation errors', () async {
      final reader = StreamReader.fromIterable([1, 2, 3]);
      final transformed = transformStreamReader(reader, (x) {
        if (x == 2) throw Exception('error');
        return x * 2;
      });

      expect(await transformed.recv(), 2);
      expect(() => transformed.recv(), throwsException);

      await transformed.close();
    });

    test('transforms to different type', () async {
      final reader = StreamReader.fromIterable([1, 2, 3]);
      final transformed = transformStreamReader<int, String>(
        reader,
        (x) => 'item_$x',
      );

      final results = await transformed.collectAll();
      expect(results, ['item_1', 'item_2', 'item_3']);

      await transformed.close();
    });
  });

  group('integration tests', () {
    test('pipe -> transform works', () async {
      final (reader, writer) = pipe<int>(capacity: 10);

      // Transform
      final transformed = reader.transform((x) => x * 10);

      // Send data
      writer.send(1);
      writer.send(2);
      await writer.close();

      // Collect results
      expect(await transformed.recv(), 10);
      expect(await transformed.recv(), 20);

      await transformed.close();
    });

    test('fromIterable -> transform -> collect', () async {
      final reader = StreamReader.fromIterable([1, 2]);
      final transformed = reader.transform((x) => x * 2);

      final results = await transformed.collectAll();
      expect(results, [2, 4]);

      await transformed.close();
    });
  });
}
