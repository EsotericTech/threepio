// ignore_for_file: avoid_print

/// Example demonstrating how to use OpenRouter with Threepio
///
/// OpenRouter (https://openrouter.ai) provides access to 100+ LLM models
/// through a single API, including:
/// - Text models: Gemini, Claude, GPT-4, Llama, Mistral, and more
/// - Image generation: DALL-E, Stable Diffusion, Gemini 2.5 Flash Image
///
/// Get your API key at: https://openrouter.ai/keys
library;

import 'package:threepio_core/threepio_core.dart';

void main() async {
  // Replace with your OpenRouter API key
  const apiKey = 'your-openrouter-api-key';

  print('=== Threepio OpenRouter Examples ===\n');

  // Example 1: Text generation with different models
  await textGenerationExample(apiKey);

  // Example 2: Image generation
  await imageGenerationExample(apiKey);

  // Example 3: Streaming responses
  await streamingExample(apiKey);
}

/// Example 1: Generate text with different LLM models
Future<void> textGenerationExample(String apiKey) async {
  print('--- Example 1: Text Generation ---');

  final config = OpenRouterConfig(
    apiKey: apiKey,
    siteName: 'Threepio Example',
    siteUrl: 'https://github.com/your-org/threepio',
  );

  final model = OpenRouterChatModel(config: config);

  final prompt = Message.user(
    'Explain quantum computing in exactly one sentence.',
  );

  // Try Gemini 2.5 Flash (fast, cost-effective)
  print('\n🟢 Gemini 2.5 Flash:');
  var response = await model.generate(
    [prompt],
    options: const ChatModelOptions(
      model: 'google/gemini-2.5-flash',
      maxTokens: 100,
    ),
  );
  print(response.content);
  print('Tokens used: ${response.responseMeta?.usage?.totalTokens ?? 'N/A'}');

  // Try Claude 3.5 Sonnet (excellent reasoning)
  print('\n🟣 Claude 3.5 Sonnet:');
  response = await model.generate(
    [prompt],
    options: const ChatModelOptions(
      model: 'anthropic/claude-3.5-sonnet',
      maxTokens: 100,
    ),
  );
  print(response.content);
  print('Tokens used: ${response.responseMeta?.usage?.totalTokens ?? 'N/A'}');

  // Try Llama 3.1 70B (open-source powerhouse)
  print('\n🦙 Llama 3.1 70B:');
  response = await model.generate(
    [prompt],
    options: const ChatModelOptions(
      model: 'meta-llama/llama-3.1-70b-instruct',
      maxTokens: 100,
    ),
  );
  print(response.content);
  print('Tokens used: ${response.responseMeta?.usage?.totalTokens ?? 'N/A'}');

  print('');
}

/// Example 2: Generate images with Gemini 2.5 Flash Image
Future<void> imageGenerationExample(String apiKey) async {
  print('--- Example 2: Image Generation ---');

  final config = OpenRouterConfig(apiKey: apiKey);
  final model = OpenRouterChatModel(config: config);

  final messages = [
    Message.user('Generate a minimalist icon of a robot made of geometric shapes'),
  ];

  print('🎨 Generating image with Gemini 2.5 Flash Image...');
  final response = await model.generate(
    messages,
    options: const ChatModelOptions(
      model: 'google/gemini-2.5-flash-image',
      maxTokens: 4096,
    ),
  );

  // Text response (if any)
  if (response.content.isNotEmpty) {
    print('Text: ${response.content}');
  }

  // Extract generated image
  if (response.assistantGenMultiContent != null &&
      response.assistantGenMultiContent!.isNotEmpty) {
    final imagePart = response.assistantGenMultiContent!.firstWhere(
      (part) => part.type == ChatMessagePartType.imageUrl,
      orElse: () => throw Exception('No image in response'),
    );

    if (imagePart.image?.url != null) {
      final imageUrl = imagePart.image!.url!;

      // Data URL format: data:image/png;base64,iVBORw0KGgo...
      print('✅ Image generated successfully!');
      print('Format: ${imagePart.image!.mimeType ?? 'image/png'}');
      print('Size: ${imageUrl.length} characters');
      print('Preview: ${imageUrl.substring(0, 50)}...');

      // In Flutter, display with:
      // import 'dart:convert';
      // import 'package:flutter/widgets.dart';
      //
      // final base64Data = imageUrl.split(',')[1];
      // final imageBytes = base64Decode(base64Data);
      // Image.memory(imageBytes)
    }
  } else {
    print('⚠️ No image content in response');
  }

  print('Tokens used: ${response.responseMeta?.usage?.totalTokens ?? 'N/A'}');
  print('');
}

/// Example 3: Stream responses in real-time
Future<void> streamingExample(String apiKey) async {
  print('--- Example 3: Streaming ---');

  final config = OpenRouterConfig(apiKey: apiKey);
  final model = OpenRouterChatModel(config: config);

  final messages = [
    Message.user('Write a haiku about programming'),
  ];

  print('📡 Streaming from Gemini 2.5 Flash:\n');

  final reader = await model.stream(
    messages,
    options: const ChatModelOptions(
      model: 'google/gemini-2.5-flash',
      maxTokens: 100,
    ),
  );

  try {
    while (true) {
      final chunk = await reader.recv();

      // Print each chunk as it arrives
      if (chunk.content.isNotEmpty) {
        print(chunk.content);
      }

      // Check for completion
      if (chunk.responseMeta?.finishReason != null) {
        print('\n\n✅ Stream complete: ${chunk.responseMeta!.finishReason}');
      }
    }
  } on StreamEOFException {
    // Stream finished
    print('');
  } finally {
    await reader.close();
  }
}
