// Mirror of doc/MIGRATION.md, "Messages and streams": MessageConcatException.
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

Message joinChunks(List<Message> chunks) {
try {
  return concatMessages(chunks);
} on MessageConcatException catch (e) {
  print('the provider streamed chunks that do not fit together: $e');
  return MessageConcatenator.concat(chunks);
}
}
