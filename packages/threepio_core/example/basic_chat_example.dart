// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

/// Basic example showing how to use Threepio Core with OpenAI
///
/// To run this example:
/// 1. Create a .env file with OPENAI_API_KEY=your-key
/// 2. Run: dart run basic_chat_example.dart
Future<void> main() async {
  // Configure OpenAI
  final config = OpenAIConfig(
    apiKey: 'your-api-key-here', // Replace with your actual API key
    defaultModel: 'gpt-4o-mini',
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
    print('  Prompt tokens: ${response.tokenUsage?.promptTokens}');
    print('  Completion tokens: ${response.tokenUsage?.completionTokens}');
    print('  Total tokens: ${response.tokenUsage?.totalTokens}');
  } catch (e) {
    print('Error: $e');
  }
}
