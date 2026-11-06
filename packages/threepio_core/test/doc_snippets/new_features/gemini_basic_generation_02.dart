// Mirror of doc/NEW_FEATURES.md, section 1, "### Basic Text Generation".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

Future<void> basicTextGeneration(GeminiConfig config) async {
  final model = GeminiChatModel(config: config);

  // Simple generation
  final messages = [
    Message.user('What is the capital of France?'),
  ];

  final response = await model.generate(messages);
  print(response.content); // "The capital of France is Paris."

  // With system message
  final messagesWithSystem = [
    Message.system('You are a helpful geography expert. Be concise.'),
    Message.user('What is the capital of France?'),
  ];

  final response2 = await model.generate(messagesWithSystem);
  print(response2.content); // "Paris"
  model.dispose();
}
