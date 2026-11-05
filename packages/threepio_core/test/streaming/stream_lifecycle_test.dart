import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';
import 'package:threepio_core/src/streaming/stream_utils.dart';

/// Lets every already scheduled microtask and zero-delay timer run.
Future<void> pumpEventQueue() => Future<void>.delayed(Duration.zero);

void main() {
  group('close', () {
    test('completes a waiting recv with StreamClosedException', () async {
      final (reader, _) = pipe<int>();

      final pending = expectLater(
        reader.recv(),
        throwsA(isA<StreamClosedException>()),
      );
      await reader.close();

      await pending;
    });

    test('completes every waiting recv', () async {
      final reader = StreamReader.fromStream(StreamController<int>().stream);

      final pending = [
        expectLater(reader.recv(), throwsA(isA<StreamClosedException>())),
        expectLater(reader.recv(), throwsA(isA<StreamClosedException>())),
      ];
      await reader.close();

      await Future.wait(pending);
    });

    test('cancels the subscription of a reader built from a stream', () async {
      var cancelled = false;
      final controller = StreamController<int>(
        onCancel: () => cancelled = true,
      );
      final reader = StreamReader.fromStream(controller.stream);
      expect(controller.hasListener, isTrue);

      await reader.close();

      expect(cancelled, isTrue);
      expect(controller.hasListener, isFalse);
    });

    test('completes done', () async {
      final reader = StreamReader.fromIterable([1]);

      await reader.close();

      await expectLater(reader.done, completes);
    });
  });

  group('recv', () {
    test('reports EOF right after the last item of an iterable', () async {
      final reader = StreamReader.fromIterable([1]);
      expect(await reader.recv(), 1);

      // The call is made before close() and must not be turned into a
      // StreamClosedException by it.
      final afterLast = expectLater(
        reader.recv(),
        throwsA(isA<StreamEOFException>()),
      );
      await reader.close();

      await afterLast;
    });

    test('keeps reporting EOF', () async {
      final reader = StreamReader.fromIterable(<int>[]);

      await expectLater(reader.recv(), throwsA(isA<StreamEOFException>()));
      await expectLater(reader.recv(), throwsA(isA<StreamEOFException>()));
    });

    test('serves waiting calls in the order they were made', () async {
      final (reader, writer) = pipe<int>();

      final first = reader.recv();
      final second = reader.recv();
      writer
        ..send(1)
        ..send(2);

      expect(await first, 1);
      expect(await second, 2);
    });

    test('returns null items of a nullable stream', () async {
      final reader = StreamReader<int?>.fromIterable([null, 1]);

      expect(await reader.recv(), isNull);
      expect(await reader.recv(), 1);
    });

    test('buffers items a stream emitted before the first recv', () async {
      final controller = StreamController<int>();
      final reader = StreamReader.fromStream(controller.stream);

      controller
        ..add(1)
        ..add(2);
      await controller.close();
      await pumpEventQueue();

      expect(await reader.collectAll(), [1, 2]);
    });
  });

  group('copy', () {
    test('every copy sees every item, whenever it starts reading', () async {
      final (reader, writer) = pipe<int>();
      final copies = reader.copy(3);

      writer.send(1);
      expect(await copies[0].recv(), 1);

      writer.send(2);
      await pumpEventQueue();
      expect(await copies[1].recv(), 1);

      writer.send(3);
      await writer.close();
      await pumpEventQueue();

      expect(await copies[0].collectAll(), [2, 3]);
      expect(await copies[1].collectAll(), [2, 3]);
      expect(await copies[2].collectAll(), [1, 2, 3]);
    });

    test('copies of an iterable reader all start at the first item', () async {
      final copies = StreamReader.fromIterable([1, 2, 3]).copy(2);

      expect(await copies[0].collectAll(), [1, 2, 3]);
      expect(await copies[1].collectAll(), [1, 2, 3]);
    });

    test('closing one copy does not disturb the others', () async {
      final (reader, writer) = pipe<int>();
      final copies = reader.copy(2);

      await copies[0].close();
      expect(writer.send(1), isFalse);
      await writer.close();

      expect(await copies[1].collectAll(), [1]);
      await expectLater(
        copies[0].recv(),
        throwsA(isA<StreamClosedException>()),
      );
    });

    test('releases the source when the last copy is closed', () async {
      final controller = StreamController<int>();
      final copies = StreamReader.fromStream(controller.stream).copy(2);

      await copies[0].close();
      expect(controller.hasListener, isTrue);

      await copies[1].close();
      expect(controller.hasListener, isFalse);
    });

    test('errors reach every copy', () async {
      final (reader, writer) = pipe<int>();
      final copies = reader.copy(2);

      writer.sendError(const FormatException('broken'));

      await expectLater(copies[0].recv(), throwsFormatException);
      await expectLater(copies[1].recv(), throwsFormatException);
    });
  });

  group('transform', () {
    test('buffers items sent before the first recv', () async {
      final (reader, writer) = pipe<int>();
      final doubled = reader.transform((x) => x * 2);

      writer
        ..send(1)
        ..send(2);
      await writer.close();
      await pumpEventQueue();

      expect(await doubled.collectAll(), [2, 4]);
    });

    test('closing the transformed reader releases the source', () async {
      final controller = StreamController<int>();
      final transformed =
          StreamReader.fromStream(controller.stream).transform((x) => '$x');

      await transformed.close();

      expect(controller.hasListener, isFalse);
    });

    test('makes the original reader unusable', () async {
      final reader = StreamReader.fromIterable([1, 2]);
      final transformed = reader.transform((x) => x + 1);

      await expectLater(reader.recv(), throwsA(isA<StreamClosedException>()));
      expect(() => reader.transform((x) => x), throwsStateError);
      expect(await transformed.collectAll(), [2, 3]);
    });
  });

  group('merge and concat', () {
    test('a merged reader buffers items sent before the first recv', () async {
      final (reader1, writer1) = pipe<int>();
      final (reader2, writer2) = pipe<int>();
      final merged = mergeStreamReaders([reader1, reader2]);

      writer1.send(1);
      writer2.send(2);
      writer1.send(3);
      await writer1.close();
      await writer2.close();
      await pumpEventQueue();

      expect(await merged.collectAll(), [1, 2, 3]);
    });

    test('a named merge reports each source that ends, then EOF', () async {
      final merged = mergeNamedStreamReaders({
        'a': StreamReader.fromIterable([1]),
        'b': StreamReader.fromIterable([2]),
      });

      final seen = <Object>[];
      while (true) {
        try {
          seen.add(await merged.recv());
        } on SourceEOFException catch (e) {
          seen.add('eof:${e.sourceName}');
        } on StreamEOFException {
          break;
        }
      }

      expect(seen, [1, 'eof:a', 2, 'eof:b']);
    });

    test('collectAll and asStream skip the end-of-source markers', () async {
      StreamReader<int> named() => mergeNamedStreamReaders({
            'a': StreamReader.fromIterable([1]),
            'b': StreamReader.fromIterable([2]),
          });

      expect(await named().collectAll(), [1, 2]);
      expect(await named().asStream().toList(), [1, 2]);
    });

    test('closing a merged reader releases every source', () async {
      final controller1 = StreamController<int>();
      final controller2 = StreamController<int>();
      final merged = mergeStreamReaders([
        StreamReader.fromStream(controller1.stream),
        StreamReader.fromStream(controller2.stream),
      ]);

      final pending = expectLater(
        merged.recv(),
        throwsA(isA<StreamClosedException>()),
      );
      await merged.close();

      await pending;
      expect(controller1.hasListener, isFalse);
      expect(controller2.hasListener, isFalse);
    });

    test('a concatenated reader buffers and keeps the order', () async {
      final (reader1, writer1) = pipe<int>();
      final (reader2, writer2) = pipe<int>();
      final concatenated = concatStreamReaders([reader1, reader2]);

      // The second source is filled first, but is read second.
      writer2
        ..send(3)
        ..send(4);
      await writer2.close();
      writer1
        ..send(1)
        ..send(2);
      await writer1.close();
      await pumpEventQueue();

      expect(await concatenated.collectAll(), [1, 2, 3, 4]);
    });

    test('a concatenated reader passes errors on in place', () async {
      final (reader1, writer1) = pipe<int>();
      final concatenated = concatStreamReaders([
        reader1,
        StreamReader.fromIterable([3]),
      ]);

      writer1
        ..send(1)
        ..sendError(const FormatException('broken'))
        ..send(2);
      await writer1.close();

      expect(await concatenated.recv(), 1);
      await expectLater(concatenated.recv(), throwsFormatException);
      expect(await concatenated.collectAll(), [2, 3]);
    });
  });

  group('pipe', () {
    test('send after the reader closed returns true and does not throw',
        () async {
      final (reader, writer) = pipe<int>();
      expect(writer.send(1), isFalse);

      await reader.close();

      expect(writer.isClosed, isTrue);
      expect(writer.send(2), isTrue);
      expect(writer.sendError(Exception('late')), isTrue);
      expect(writer.sendWithError(3), isTrue);
      await expectLater(writer.close(), completes);
    });

    test('the writer learns that a derived reader was closed', () async {
      final (reader, writer) = pipe<int>();
      final transformed = reader.transform((x) => x * 2);
      expect(writer.send(1), isFalse);

      await transformed.close();

      expect(writer.send(2), isTrue);
    });

    test('closing the writer ends a waiting recv with EOF', () async {
      final (reader, writer) = pipe<int>();

      final pending = expectLater(
        reader.recv(),
        throwsA(isA<StreamEOFException>()),
      );
      await writer.close();

      await pending;
    });
  });
}
