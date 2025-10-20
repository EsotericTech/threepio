import 'package:test/test.dart';
import 'package:threepio_core/src/streaming/stream_item.dart';

void main() {
  group('StreamItem', () {
    test('creates data item', () {
      final item = StreamItem.data('hello');
      expect(item.chunk, 'hello');
      expect(item.error, isNull);
      expect(item.stackTrace, isNull);
      expect(item.hasError, isFalse);
    });

    test('creates error item', () {
      final error = Exception('test error');
      final stackTrace = StackTrace.current;
      final item = StreamItem<String>.error(error, stackTrace);

      expect(item.error, error);
      expect(item.stackTrace, stackTrace);
      expect(item.hasError, isTrue);
    });

    test('creates error item without stack trace', () {
      final error = Exception('test error');
      final item = StreamItem<String>.error(error);

      expect(item.error, error);
      expect(item.stackTrace, isNull);
      expect(item.hasError, isTrue);
    });

    test('creates item with both data and error', () {
      final error = Exception('test error');
      final item = StreamItem(
        chunk: 'data',
        error: error,
      );

      expect(item.chunk, 'data');
      expect(item.error, error);
      expect(item.hasError, isTrue);
    });

    test('hasError returns false when error is null', () {
      final item = StreamItem(chunk: 'test');
      expect(item.hasError, isFalse);
    });
  });
}
