// ignore_for_file: avoid_print

/// Example of the OpenRouter chat model.
///
/// OpenRouter (https://openrouter.ai) serves models of many providers
/// (Gemini, Claude, GPT, Llama, Mistral, ...) through one OpenAI-compatible
/// API. The example shows:
/// 1. Text generation with several models, picked per call with
///    `ChatModelOptions.model`
/// 2. Image generation with Gemini 2.5 Flash Image (the image arrives in
///    `assistantGenMultiContent`)
/// 3. Streaming a response chunk by chunk
///
/// eino-ext has an OpenRouter chat model too (`components/model/openrouter`);
/// threepio's `OpenRouterChatModel` keeps its own parser.
///
/// To run this example (get a key at https://openrouter.ai/keys):
///
/// ```bash
/// OPENROUTER_API_KEY=... dart run example/openrouter_example.dart
/// ```
library;

import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

Future<void> main() async {
  final apiKey = Platform.environment['OPENROUTER_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('Set OPENROUTER_API_KEY to run this example.');
    return;
  }

  // One model for every example; each call picks the model it wants.
  // siteName and siteUrl are OpenRouter's optional attribution headers.
  final model = OpenRouterChatModel(
    config: OpenRouterConfig(
      apiKey: apiKey,
      siteName: 'Threepio Example',
      siteUrl: 'https://github.com/your-org/threepio',
    ),
  );

  print('=== Threepio OpenRouter Examples ===\n');
  try {
    // Example 1: Text generation with different models
    await textGenerationExample(model);

    // Example 2: Image generation
    await imageGenerationExample(model);

    // Example 3: Streaming responses
    await streamingExample(model);
  } finally {
    model.dispose();
  }
}

/// Example 1: Generate text with different LLM models
Future<void> textGenerationExample(OpenRouterChatModel model) async {
  print('--- Example 1: Text Generation ---');

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

  // Try Claude Haiku 4.5 (fast Anthropic model)
  print('\n🟣 Claude Haiku 4.5:');
  response = await model.generate(
    [prompt],
    options: const ChatModelOptions(
      model: 'anthropic/claude-haiku-4.5',
      maxTokens: 100,
    ),
  );
  print(response.content);
  print('Tokens used: ${response.responseMeta?.usage?.totalTokens ?? 'N/A'}');

  // Try Llama 3.1 70B (open-weight model)
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
Future<void> imageGenerationExample(OpenRouterChatModel model) async {
  print('--- Example 2: Image Generation ---');

  final messages = [
    Message.user(
      'Generate a minimalist icon of a robot made of geometric shapes',
    ),
  ];

  print('🎨 Generating image with Gemini 2.5 Flash Image...');
  // An image model answers with an image only when the request asks for the
  // image modality (OpenRouter `modalities: ["image", "text"]`).
  final response = await model.generate(
    messages,
    options: const OpenRouterRequestOptions(
      modalities: [OutputModality.image, OutputModality.text],
    ).toOptions(model: 'google/gemini-2.5-flash-image', maxTokens: 4096),
  );

  // Text response (if any)
  if (response.content.isNotEmpty) {
    print('Text: ${response.content}');
  }

  // Extract generated image
  final imagePart = response.assistantGenMultiContent
      ?.where((part) => part.type == ChatMessagePartType.imageUrl)
      .firstOrNull;
  final imageUrl = imagePart?.image?.url;
  if (imageUrl != null) {
    // Data URL format: data:image/png;base64,iVBORw0KGgo...
    print('✅ Image generated successfully!');
    print('Format: ${imagePart!.image!.mimeType ?? 'image/png'}');
    print('Size: ${imageUrl.length} characters');
    final preview =
        imageUrl.length > 50 ? '${imageUrl.substring(0, 50)}...' : imageUrl;
    print('Preview: $preview');

    // In Flutter, display with:
    // import 'dart:convert';
    // import 'package:flutter/widgets.dart';
    //
    // final base64Data = imageUrl.split(',')[1];
    // final imageBytes = base64Decode(base64Data);
    // Image.memory(imageBytes)
  } else {
    print('⚠️ No image content in response');
  }

  print('Tokens used: ${response.responseMeta?.usage?.totalTokens ?? 'N/A'}');
  print('');
}

/// Example 3: Stream responses in real-time
Future<void> streamingExample(OpenRouterChatModel model) async {
  print('--- Example 3: Streaming ---');

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
        stdout.write(chunk.content);
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
