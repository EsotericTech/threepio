import 'dart:io';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/chat_model_options.dart';
import 'package:threepio_core/src/components/model/providers/openrouter/openrouter_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/openrouter/openrouter_config.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

void main() {
  // Skip these tests if OPENROUTER_API_KEY is not set
  final apiKey = Platform.environment['OPENROUTER_API_KEY'];

  if (apiKey == null || apiKey.isEmpty) {
    test('OPENROUTER_API_KEY not set - skipping integration tests', () {
      print('Skipping OpenRouter integration tests: OPENROUTER_API_KEY not set');
    });
    return;
  }

  group('OpenRouter Integration Tests', () {
    late OpenRouterChatModel model;

    setUp(() {
      final config = OpenRouterConfig(
        apiKey: apiKey,
        siteName: 'Threepio Test Suite',
        siteUrl: 'https://github.com/your-org/threepio',
      );
      model = OpenRouterChatModel(config: config);
    });

    test('generates text response from Gemini', () async {
      final messages = [
        Message.user('Say "Hello from Gemini" and nothing else.'),
      ];

      final response = await model.generate(
        messages,
        options: const ChatModelOptions(
          model: 'google/gemini-2.5-flash',
          maxTokens: 50,
        ),
      );

      print('Response: ${response.content}');

      expect(response.role, equals(RoleType.assistant));
      expect(response.content, isNotEmpty);
      expect(response.content.toLowerCase(), contains('hello'));
      expect(response.responseMeta?.finishReason, isNotNull);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('generates text response from OpenAI via OpenRouter', () async {
      final messages = [
        Message.user('What is 2 + 2? Answer with just the number.'),
      ];

      final response = await model.generate(
        messages,
        options: const ChatModelOptions(
          model: 'openai/gpt-4o-mini',
          maxTokens: 10,
        ),
      );

      print('Response: ${response.content}');

      expect(response.role, equals(RoleType.assistant));
      expect(response.content, isNotEmpty);
      expect(response.content.toLowerCase(), contains('4'));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('streams text response', () async {
      final messages = [
        Message.user('Count from 1 to 5, one number per line.'),
      ];

      final reader = await model.stream(
        messages,
        options: const ChatModelOptions(
          model: 'google/gemini-2.5-flash',
          maxTokens: 100,
        ),
      );

      final chunks = <Message>[];
      try {
        while (true) {
          final chunk = await reader.recv();
          chunks.add(chunk);
          print('Chunk: ${chunk.content}');
        }
      } on StreamEOFException {
        // Stream complete
      } finally {
        await reader.close();
      }

      expect(chunks, isNotEmpty);
      final fullContent = chunks.map((c) => c.content).join();
      expect(fullContent, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('generates image with Gemini image model', () async {
      final messages = [
        Message.user('Generate a simple image of a red circle on a white background.'),
      ];

      final response = await model.generate(
        messages,
        options: const ChatModelOptions(
          model: 'google/gemini-2.5-flash-image',
          maxTokens: 4096,
        ),
      );

      print('Response role: ${response.role}');
      print('Content length: ${response.content.length}');
      if (response.content.isNotEmpty) {
        print('Content preview (first 200 chars): ${response.content.substring(0, response.content.length > 200 ? 200 : response.content.length)}');
      }
      print('Has assistantGenMultiContent: ${response.assistantGenMultiContent != null}');

      if (response.assistantGenMultiContent != null) {
        print('Number of multi-content parts: ${response.assistantGenMultiContent!.length}');
        for (var i = 0; i < response.assistantGenMultiContent!.length; i++) {
          final part = response.assistantGenMultiContent![i];
          print('Part $i type: ${part.type}');
          if (part.image != null) {
            print('Part $i has image URL: ${part.image!.url != null}');
            print('Part $i has base64: ${part.image!.base64Data != null}');
            if (part.image!.url != null) {
              print('Part $i URL preview: ${part.image!.url!.substring(0, 100)}...');
            }
            if (part.image!.base64Data != null) {
              print('Part $i base64 length: ${part.image!.base64Data!.length}');
            }
          }
        }
      }

      print('Finish reason: ${response.responseMeta?.finishReason}');
      if (response.responseMeta?.usage != null) {
        print('Tokens used: ${response.responseMeta!.usage!.totalTokens}');
      }

      expect(response.role, equals(RoleType.assistant));

      // Image models should populate assistantGenMultiContent
      expect(response.assistantGenMultiContent, isNotNull,
          reason: 'Image response should have assistantGenMultiContent');
      expect(response.assistantGenMultiContent!.length, greaterThan(0),
          reason: 'Should have at least one content part');

      // Should have an image part
      final imagePart = response.assistantGenMultiContent!.firstWhere(
        (part) => part.type == ChatMessagePartType.imageUrl,
        orElse: () => throw Exception('No image part found in response'),
      );

      expect(imagePart.image, isNotNull);

      // Should have either URL or base64 data
      final hasImageData = imagePart.image!.url != null ||
                          imagePart.image!.base64Data != null;
      expect(hasImageData, isTrue,
          reason: 'Image part should have either URL or base64 data');

      if (imagePart.image!.url != null) {
        print('Image URL length: ${imagePart.image!.url!.length}');
        // Data URLs should start with data:image/
        if (imagePart.image!.url!.startsWith('data:')) {
          expect(imagePart.image!.url!.startsWith('data:image/'), isTrue);
        }
      }

      if (imagePart.image!.base64Data != null) {
        print('Base64 data length: ${imagePart.image!.base64Data!.length}');
        expect(imagePart.image!.base64Data!.length, greaterThan(100),
            reason: 'Base64 image data should be substantial');
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('streams image generation', () async {
      final messages = [
        Message.user('Generate a simple smiley face emoji image.'),
      ];

      final reader = await model.stream(
        messages,
        options: const ChatModelOptions(
          model: 'google/gemini-2.5-flash-image',
          maxTokens: 4096,
        ),
      );

      final chunks = <Message>[];
      Message? lastChunk;

      try {
        while (true) {
          final chunk = await reader.recv();
          chunks.add(chunk);
          lastChunk = chunk;

          if (chunk.assistantGenMultiContent != null) {
            print('Chunk has assistantGenMultiContent with ${chunk.assistantGenMultiContent!.length} parts');
          }
          if (chunk.content.isNotEmpty) {
            print('Chunk content length: ${chunk.content.length}');
          }
        }
      } on StreamEOFException {
        // Stream complete
      } finally {
        await reader.close();
      }

      print('Total chunks received: ${chunks.length}');

      expect(chunks, isNotEmpty, reason: 'Should receive at least one chunk');

      // Check if any chunk has image data
      final hasImageContent = chunks.any(
        (chunk) => chunk.assistantGenMultiContent != null &&
                   chunk.assistantGenMultiContent!.any(
                     (part) => part.type == ChatMessagePartType.imageUrl
                   )
      );

      expect(hasImageContent, isTrue,
          reason: 'At least one chunk should contain image content');

      // Last chunk should have finish reason
      if (lastChunk != null && lastChunk.responseMeta != null) {
        print('Final finish reason: ${lastChunk.responseMeta!.finishReason}');
        expect(lastChunk.responseMeta!.finishReason, isNotNull);
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
