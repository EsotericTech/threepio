import 'package:test/test.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

void main() {
  test('minimal test', () async {
    final reader = StreamReader.fromIterable([1, 2, 3]);
    expect(await reader.recv(), 1);
    await reader.close();
  });
}
