import 'package:test/test.dart';
import 'package:threepio_core/src/streaming/stream_utils.dart';

void main() {
  group('StreamWriter', () {
    test('sends data to stream', () async {
      final (reader, writer) = pipe<String>(capacity: 10);

      writer.send('hello');
      writer.send('world');
      await writer.close();

      expect(await reader.recv(), 'hello');
      expect(await reader.recv(), 'world');

      await reader.close();
    });

    test('sendError sends errors', () async {
      final (reader, writer) = pipe<String>(capacity: 10);

      writer.send('data');
      writer.sendError(Exception('test error'));
      await writer.close();

      expect(await reader.recv(), 'data');
      expect(
        () => reader.recv(),
        throwsException,
      );

      await reader.close();
    });

    test('sendWithError sends data with optional error', () async {
      final (reader, writer) = pipe<String>(capacity: 10);

      writer.sendWithError('data1');
      writer.sendWithError('data2', Exception('error'));
      await writer.close();

      expect(await reader.recv(), 'data1');
      expect(
        () => reader.recv(),
        throwsException,
      );

      await reader.close();
    });

    test('send returns true when closed', () async {
      final (reader, writer) = pipe<String>(capacity: 10);

      expect(writer.send('data'), isFalse);
      await writer.close();

      // After close, send should return true
      expect(writer.send('more data'), isTrue);

      await reader.close();
    });

    test('close is idempotent', () async {
      final (reader, writer) = pipe<String>(capacity: 10);

      await writer.close();
      await writer.close(); // Should not throw

      await reader.close();
    });

    test('isClosed returns correct state', () async {
      final (reader, writer) = pipe<String>(capacity: 10);

      expect(writer.isClosed, isFalse);

      await writer.close();

      expect(writer.isClosed, isTrue);

      await reader.close();
    });

    test('multiple sends and receives', () async {
      final (reader, writer) = pipe<int>(capacity: 10);

      // Send in background
      Future.delayed(Duration.zero, () async {
        for (var i = 0; i < 5; i++) {
          writer.send(i);
        }
        await writer.close();
      });

      final results = await reader.collectAll();
      expect(results, [0, 1, 2, 3, 4]);

      await reader.close();
    });

    test('closes properly with no data', () async {
      final (reader, writer) = pipe<String>(capacity: 10);

      await writer.close();

      expect(
        () => reader.recv(),
        throwsA(anything), // Should throw EOF
      );

      await reader.close();
    });
  });
}
