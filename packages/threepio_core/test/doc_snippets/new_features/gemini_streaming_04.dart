// Mirror of doc/NEW_FEATURES.md, section 1, "### Streaming Responses".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

Future<void> streaming(GeminiChatModel model) async {
  final reader = await model.stream([
    Message.user('Write a short story about a robot.'),
  ]);

  // asStream() hands the chunks to `await for` and closes the reader at the end
  await for (final chunk in reader.asStream()) {
    stdout.write(chunk.content);
  }

  // Or pull the chunks one by one, as Go's Recv loop does
  final reader2 = await model.stream([Message.user('Count to five.')]);
  try {
    for (var chunk = await reader2.nextOrNull();
        chunk != null;
        chunk = await reader2.nextOrNull()) {
      stdout.write(chunk.content);
    }
  } finally {
    await reader2.close();
  }
}
