// ignore_for_file: avoid_print

/// Basic example: one request to an OpenAI chat model.
///
/// Builds an `OpenAIChatModel`, sends a system and a user message with
/// `generate`, and prints the answer and its token usage. Eino counterpart:
/// eino-ext `components/model/openai` (`openai.NewChatModel`, `Generate`).
///
/// To run this example:
///
/// ```bash
/// OPENAI_API_KEY=... dart run example/basic_chat_example.dart
/// # Optional: OPENAI_MODEL (default gpt-4o-mini), OPENAI_BASE_URL.
/// ```
library;

import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

Future<void> main() async {
  final env = Platform.environment;
  final apiKey = env['OPENAI_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('Set OPENAI_API_KEY to run this example.');
    return;
  }

  // Configure OpenAI
  final config = OpenAIConfig(
    apiKey: apiKey,
    baseUrl: env['OPENAI_BASE_URL'] ?? 'https://api.openai.com/v1',
    defaultModel: env['OPENAI_MODEL'] ?? 'gpt-4o-mini',
  );

  // Create chat model
  final model = OpenAIChatModel(config: config);

  // Create messages
  final messages = [
    Message.system('You are a helpful assistant.'),
    Message.user('What is the capital of France?'),
  ];

  try {
    // Generate response
    print('Sending request to OpenAI...\n');
    final response = await model.generate(messages);

    print('Response: ${response.content}');
    print('\nToken usage:');
    print('  Prompt tokens: ${response.responseMeta?.usage?.promptTokens}');
    print(
      '  Completion tokens: ${response.responseMeta?.usage?.completionTokens}',
    );
    print('  Total tokens: ${response.responseMeta?.usage?.totalTokens}');
  } catch (e) {
    print('Error: $e');
  } finally {
    model.dispose();
  }
}
