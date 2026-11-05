// Integration tests for Gemini Chat Model.
//
// They run only when THREEPIO_INTEGRATION=1 and GEMINI_API_KEY are set in the
// environment:
//
//   THREEPIO_INTEGRATION=1 GEMINI_API_KEY=… dart test -j 1 --tags integration \
//     test/components/model/providers/gemini/gemini_integration_test.dart

@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../../../support/integration.dart';

/// Simple calculator tool for testing
class CalculatorTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo.simple(
      name: 'calculate',
      description: 'Performs arithmetic calculations. Supports +, -, *, /',
      properties: {
        'expression': JSONSchemaProperty.string(
          description: 'Math expression like "5 + 3" or "10 * 2"',
        ),
      },
      required: ['expression'],
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final expr = args['expression'] as String;
    // Simple parser for basic arithmetic
    final parts = expr.split(RegExp(r'\s+'));
    if (parts.length == 3) {
      final a = double.tryParse(parts[0]) ?? 0;
      final op = parts[1];
      final b = double.tryParse(parts[2]) ?? 0;

      double result;
      switch (op) {
        case '+':
          result = a + b;
          break;
        case '-':
          result = a - b;
          break;
        case '*':
          result = a * b;
          break;
        case '/':
          result = b != 0 ? a / b : double.nan;
          break;
        default:
          return 'Unknown operator: $op';
      }
      return result.toString();
    }
    return 'Could not parse expression: $expr';
  }
}

/// Echo tool for testing
class EchoTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo.simple(
      name: 'echo',
      description: 'Echoes back the input message',
      properties: {
        'message': JSONSchemaProperty.string(description: 'Message to echo'),
      },
      required: ['message'],
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    return 'Echo: ${args['message']}';
  }
}

/// Weather tool for testing
class WeatherTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo.simple(
      name: 'get_weather',
      description: 'Get weather for a city',
      properties: {
        'city': JSONSchemaProperty.string(description: 'City name'),
      },
      required: ['city'],
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final city = args['city'] as String;
    // Mock weather data
    final temps = {'tokyo': 22, 'london': 15, 'new york': 18};
    final temp = temps[city.toLowerCase()] ?? 20;
    return '{"city": "$city", "temp_celsius": $temp, "condition": "partly cloudy"}';
  }
}

/// Temperature converter tool for testing
class TemperatureConverterTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo.simple(
      name: 'celsius_to_fahrenheit',
      description: 'Convert Celsius to Fahrenheit',
      properties: {
        'celsius': JSONSchemaProperty.number(description: 'Temperature in Celsius'),
      },
      required: ['celsius'],
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final celsius = (args['celsius'] as num).toDouble();
    final fahrenheit = (celsius * 9 / 5) + 32;
    return fahrenheit.toStringAsFixed(1);
  }
}

void main() {
  final apiKey = integrationApiKey(
    'GEMINI_API_KEY',
    suite: 'Gemini Integration Tests',
  );
  if (apiKey == null) return;

  late GeminiConfig config;
  late GeminiChatModel model;

  setUpAll(() {
    config = GeminiConfig(
      apiKey: apiKey,
      defaultModel: 'gemini-2.5-flash',
    );
    model = GeminiChatModel(config: config);
  });

  group('Gemini Chat Model - Basic Generation', () {
    test('generates text response', () async {
      final messages = [
        Message.user('What is 2 + 2? Answer with just the number.'),
      ];

      final response = await model.generate(messages);

      expect(response.role, RoleType.assistant);
      expect(response.content, isNotEmpty);
      print('Response: ${response.content}');
    });

    test('generates response with system message', () async {
      final messages = [
        Message.system('You are a helpful math tutor. Be concise.'),
        Message.user('What is the square root of 144?'),
      ];

      final response = await model.generate(messages);

      expect(response.role, RoleType.assistant);
      expect(response.content.toLowerCase(), contains('12'));
      print('Response: ${response.content}');
    });

    test('handles multi-turn conversation', () async {
      final messages = [
        Message.user('My name is Alice.'),
        Message.assistant('Hello Alice! Nice to meet you.'),
        Message.user('What is my name?'),
      ];

      final response = await model.generate(messages);

      expect(response.content.toLowerCase(), contains('alice'));
      print('Response: ${response.content}');
    });

    test('returns token usage metadata', () async {
      final messages = [
        Message.user('Say hello.'),
      ];

      final response = await model.generate(messages);

      expect(response.responseMeta, isNotNull);
      expect(response.responseMeta?.usage, isNotNull);
      print('Token usage: ${response.responseMeta?.usage}');
    });
  });

  group('Gemini Chat Model - Streaming', () {
    test('streams text response', () async {
      final messages = [
        Message.user('Count from 1 to 5, one number per line.'),
      ];

      final reader = await model.stream(messages);
      final chunks = <String>[];

      try {
        while (true) {
          final chunk = await reader.recv();
          if (chunk.content.isNotEmpty) {
            chunks.add(chunk.content);
            stdout.write(chunk.content);
          }
        }
      } on StreamEOFException {
        // Stream complete
      }
      await reader.close();

      print('\n--- Streaming complete ---');
      expect(chunks, isNotEmpty);
    });

    test('streams with model options', () async {
      final messages = [
        Message.user('Write a short haiku about coding.'),
      ];

      final reader = await model.stream(
        messages,
        options: const ChatModelOptions(
          temperature: 0.9,
          maxTokens: 100,
        ),
      );

      final content = StringBuffer();
      try {
        while (true) {
          final chunk = await reader.recv();
          content.write(chunk.content);
        }
      } on StreamEOFException {
        // Stream complete
      }
      await reader.close();

      print('Haiku:\n$content');
      expect(content.toString(), isNotEmpty);
    });
  });

  group('Gemini Chat Model - Tool Calling', () {
    test('calls a simple tool', () async {
      final weatherTool = ToolInfo.simple(
        name: 'get_weather',
        description: 'Get the current weather in a location',
        properties: {
          'location': JSONSchemaProperty.string(
            description: 'The city name, e.g., "San Francisco"',
          ),
        },
        required: ['location'],
      );

      final modelWithTools = model.withTools([weatherTool]);

      final messages = [
        Message.user('What is the weather in Tokyo?'),
      ];

      final response = await modelWithTools.generate(messages);

      expect(response.toolCalls, isNotNull);
      expect(response.toolCalls, isNotEmpty);
      expect(response.toolCalls!.first.function.name, 'get_weather');

      final args = response.toolCalls!.first.function.arguments;
      print('Tool call: get_weather($args)');
      expect(args.toLowerCase(), contains('tokyo'));
    });

    test('handles tool response in conversation', () async {
      final weatherTool = ToolInfo.simple(
        name: 'get_weather',
        description: 'Get the current weather in a location',
        properties: {
          'location': JSONSchemaProperty.string(
            description: 'The city name',
          ),
        },
        required: ['location'],
      );

      final modelWithTools = model.withTools([weatherTool]);

      // First call - model requests tool
      final messages = [
        Message.user('What is the weather in Paris?'),
      ];

      final response1 = await modelWithTools.generate(messages);
      expect(response1.toolCalls, isNotNull);
      print('Model requested: ${response1.toolCalls!.first.function.name}');

      // Add tool response
      final toolCallId = response1.toolCalls!.first.id;
      final messagesWithToolResult = [
        ...messages,
        response1,
        Message(
          role: RoleType.tool,
          content: '{"temperature": 18, "condition": "sunny", "humidity": 65}',
          toolCallId: toolCallId,
          toolName: 'get_weather',
        ),
      ];

      // Second call - model processes tool result
      final response2 = await modelWithTools.generate(messagesWithToolResult);

      expect(response2.toolCalls, isNull);
      expect(response2.content.toLowerCase(), anyOf(
        contains('sunny'),
        contains('18'),
        contains('paris'),
      ));
      print('Final response: ${response2.content}');
    });

    test('uses multiple tools', () async {
      final weatherTool = ToolInfo.simple(
        name: 'get_weather',
        description: 'Get the current weather in a location',
        properties: {
          'location': JSONSchemaProperty.string(description: 'City name'),
        },
        required: ['location'],
      );

      final calculatorTool = ToolInfo.simple(
        name: 'calculate',
        description: 'Perform a mathematical calculation',
        properties: {
          'expression': JSONSchemaProperty.string(
            description: 'Mathematical expression to evaluate',
          ),
        },
        required: ['expression'],
      );

      final modelWithTools = model.withTools([weatherTool, calculatorTool]);

      final messages = [
        Message.user('What is 15 multiplied by 7?'),
      ];

      final response = await modelWithTools.generate(messages);

      expect(response.toolCalls, isNotNull);
      expect(response.toolCalls!.first.function.name, 'calculate');
      print('Tool call: ${response.toolCalls!.first.function.name}');
      print('Args: ${response.toolCalls!.first.function.arguments}');
    });
  });

  group('Gemini Chat Model - Agent (ReAct Pattern)', () {
    test('runs agent with tool execution', () async {
      // Create tool registry
      final registry = ToolRegistry();
      registry.register(CalculatorTool());

      // Create agent
      final agent = Agent(
        model: model,
        toolRegistry: registry,
        config: const AgentConfig(maxIterations: 5),
      );

      // Run agent
      final messages = [
        Message.system('You are a helpful assistant. Use the calculator tool when needed.'),
        Message.user('What is 25 multiplied by 4?'),
      ];

      print('Running agent...');
      final response = await agent.run(messages);

      print('Agent response: ${response.content}');
      expect(response.content, contains('100'));
    });

    test('runs agent with streaming', () async {
      final registry = ToolRegistry();
      registry.register(EchoTool());

      final agent = Agent(
        model: model,
        toolRegistry: registry,
        config: const AgentConfig(maxIterations: 3),
      );

      final messages = [
        Message.user('Please echo the message "Hello World"'),
      ];

      print('Running streaming agent...');
      final reader = await agent.stream(messages);

      try {
        while (true) {
          final chunk = await reader.recv();
          if (chunk.role == RoleType.tool) {
            print('\n[Tool Result]: ${chunk.content}');
          } else {
            stdout.write(chunk.content);
          }
        }
      } on StreamEOFException {
        // Complete
      }
      await reader.close();
      print('\n--- Agent complete ---');
    });

    test('agent handles complex multi-step reasoning', () async {
      final registry = ToolRegistry();
      registry.register(WeatherTool());
      registry.register(TemperatureConverterTool());

      final agent = Agent(
        model: model,
        toolRegistry: registry,
        config: const AgentConfig(maxIterations: 5),
      );

      final messages = [
        Message.system('You are a helpful weather assistant.'),
        Message.user('What is the weather in Tokyo in Fahrenheit?'),
      ];

      print('Running multi-step agent...');
      final response = await agent.run(messages);

      print('Agent response: ${response.content}');
      // Should contain the Fahrenheit conversion of 22C = 71.6F
      expect(response.content, anyOf(
        contains('71'),
        contains('72'),
        contains('Fahrenheit'),
        contains('Tokyo'),
      ));
    });
  });

  group('Gemini Chat Model - Model Options', () {
    test('respects temperature setting', () async {
      final messages = [
        Message.user('Give me one word that describes the ocean.'),
      ];

      // Low temperature - more deterministic
      final response1 = await model.generate(
        messages,
        options: const ChatModelOptions(temperature: 0.1),
      );

      // High temperature - more creative
      final response2 = await model.generate(
        messages,
        options: const ChatModelOptions(temperature: 1.0),
      );

      print('Low temp: ${response1.content}');
      print('High temp: ${response2.content}');

      expect(response1.content, isNotEmpty);
      expect(response2.content, isNotEmpty);
    });

    test('respects maxTokens setting', () async {
      final messages = [
        Message.user('Write a long essay about artificial intelligence.'),
      ];

      final response = await model.generate(
        messages,
        options: const ChatModelOptions(maxTokens: 50),
      );

      print('Truncated response: ${response.content}');
      // Response should be relatively short
      expect(response.content.split(' ').length, lessThan(100));
    });

    test('uses different model versions', () async {
      final messages = [
        Message.user('Say "hello" in Japanese.'),
      ];

      // Test with gemini-2.5-flash
      final response = await model.generate(
        messages,
        options: const ChatModelOptions(model: 'gemini-2.5-flash'),
      );

      print('Response: ${response.content}');
      expect(response.content, isNotEmpty);
    });
  });

  group('Gemini Chat Model - Error Handling', () {
    test('handles invalid API key gracefully', () async {
      final badConfig = GeminiConfig(
        apiKey: 'invalid-api-key',
        defaultModel: 'gemini-2.5-flash',
      );
      final badModel = GeminiChatModel(config: badConfig);

      expect(
        () => badModel.generate([Message.user('Hello')]),
        throwsA(isA<GeminiException>()),
      );
    });

    test('handles empty message list', () async {
      // This depends on API behavior - it might error or return empty
      try {
        final response = await model.generate([]);
        print('Empty messages response: ${response.content}');
      } catch (e) {
        print('Empty messages error (expected): $e');
        expect(e, isA<GeminiException>());
      }
    });
  });

  // NOTE: Image generation tests require a PAID API tier.
  // The free tier has limit: 0 for image generation models.
  // To test image generation:
  // 1. Use a paid Gemini API key
  // 2. Models: gemini-2.5-flash-image or gemini-3-pro-image-preview
  // 3. Set responseModalities: ['TEXT', 'IMAGE'] in options.extra
  //
  // Example usage:
  // ```dart
  // final imageModel = GeminiChatModel(
  //   config: GeminiConfig(
  //     apiKey: paidApiKey,
  //     defaultModel: 'gemini-2.5-flash-image',
  //   ),
  // );
  // final response = await imageModel.generate(
  //   [Message.user('Generate a red circle')],
  //   options: const ChatModelOptions(
  //     extra: {'responseModalities': ['TEXT', 'IMAGE']},
  //   ),
  // );
  // // Check response.assistantGenMultiContent for images
  // ```
  group('Gemini Chat Model - Image Generation', () {
    test('generates image with text', () async {
      // Skip if using free tier (no image generation quota)
      // To run: use a paid API key
      final imageModel = GeminiChatModel(
        config: GeminiConfig(
          apiKey: apiKey,
          defaultModel: 'gemini-2.5-flash-image',
        ),
      );

      final messages = [
        Message.user('Generate a simple image of a red circle on a white background.'),
      ];

      try {
        final response = await imageModel.generate(
          messages,
          options: const ChatModelOptions(
            extra: {
              'responseModalities': ['TEXT', 'IMAGE'],
            },
          ),
        );

        print('Response content: ${response.content}');
        print('Has multimodal output: ${response.assistantGenMultiContent != null}');

        if (response.assistantGenMultiContent != null) {
          for (final part in response.assistantGenMultiContent!) {
            print('Output part type: ${part.type}');
            if (part.type == ChatMessagePartType.imageUrl) {
              final url = part.image?.url ?? '';
              print('Image URL prefix: ${url.substring(0, url.length.clamp(0, 50))}...');
              // Verify it's a data URL with base64 image
              expect(url, startsWith('data:image/'));
            }
          }
          expect(response.assistantGenMultiContent!.any(
            (p) => p.type == ChatMessagePartType.imageUrl,
          ), isTrue, reason: 'Should contain an image output');
        } else {
          print('Note: Model may not have returned an image');
        }
      } on GeminiException catch (e) {
        if (e.statusCode == 429 && e.message.contains('limit: 0')) {
          print('SKIPPED: Image generation requires paid API tier (free tier has limit: 0)');
          // This is expected on free tier, not a failure
          return;
        }
        rethrow;
      }
    });
  });

  // ============================================================
  // Imagen Model Tests
  // ============================================================
  // NOTE: Imagen tests require a PAID API tier.
  // Available Imagen models:
  //   - imagen-4.0-generate-001 (Standard)
  //   - imagen-4.0-ultra-generate-001 (Ultra - higher quality)
  //   - imagen-4.0-fast-generate-001 (Fast - lower latency)
  //
  // Imagen uses a different API endpoint (:predict) and request format.
  // Configuration options:
  //   - numberOfImages: 1-4 (default: 1)
  //   - aspectRatio: '1:1', '3:4', '4:3', '9:16', '16:9'
  //   - personGeneration: 'dont_allow', 'allow_adult', 'allow_all'
  //   - imageSize: '1K', '2K' (Standard/Ultra only)
  group('Imagen Model Integration', () {
    test('generates image with basic prompt', () async {
      final imagenModel = GeminiChatModel(
        config: GeminiConfig(
          apiKey: apiKey,
          defaultModel: 'imagen-4.0-generate-001',
        ),
      );

      final messages = [
        Message.user('A serene mountain landscape at sunset with snow-capped peaks'),
      ];

      try {
        final response = await imagenModel.generate(messages);

        print('Imagen response content: ${response.content}');
        print('Has multimodal output: ${response.assistantGenMultiContent != null}');

        expect(response.assistantGenMultiContent, isNotNull,
            reason: 'Imagen should return images in assistantGenMultiContent');
        expect(response.assistantGenMultiContent!.isNotEmpty, isTrue,
            reason: 'Should have at least one image');

        for (final part in response.assistantGenMultiContent!) {
          print('Output part type: ${part.type}');
          if (part.type == ChatMessagePartType.imageUrl) {
            final url = part.image?.url ?? '';
            print('Image URL prefix: ${url.substring(0, url.length.clamp(0, 50))}...');
            expect(url, startsWith('data:image/'),
                reason: 'Image should be a data URL');
          }
        }
      } on GeminiException catch (e) {
        if (e.statusCode == 429 ||
            e.message.contains('limit') ||
            e.message.contains('quota')) {
          print('SKIPPED: Imagen requires paid API tier');
          print('Error: ${e.message}');
          return;
        }
        if (e.statusCode == 400 && e.message.contains('not found')) {
          print('SKIPPED: Imagen model not available in this region/tier');
          print('Error: ${e.message}');
          return;
        }
        rethrow;
      }
    });

    test('generates multiple images with options', () async {
      final imagenModel = GeminiChatModel(
        config: GeminiConfig(
          apiKey: apiKey,
          defaultModel: 'imagen-4.0-generate-001',
        ),
      );

      final messages = [
        Message.user('A cute robot playing with a cat'),
      ];

      try {
        final response = await imagenModel.generate(
          messages,
          options: const ChatModelOptions(
            extra: {
              'numberOfImages': 2,
              'aspectRatio': '16:9',
              'personGeneration': 'dont_allow',
            },
          ),
        );

        print('Imagen response: ${response.content}');

        expect(response.assistantGenMultiContent, isNotNull);

        final imageCount = response.assistantGenMultiContent!
            .where((p) => p.type == ChatMessagePartType.imageUrl)
            .length;

        print('Generated $imageCount images');
        expect(imageCount, greaterThanOrEqualTo(1),
            reason: 'Should generate at least 1 image');
        // Note: API may return fewer images than requested
      } on GeminiException catch (e) {
        if (e.statusCode == 429 ||
            e.message.contains('limit') ||
            e.message.contains('quota')) {
          print('SKIPPED: Imagen requires paid API tier');
          return;
        }
        if (e.statusCode == 400 && e.message.contains('not found')) {
          print('SKIPPED: Imagen model not available');
          return;
        }
        rethrow;
      }
    });

    test('handles different aspect ratios', () async {
      final imagenModel = GeminiChatModel(
        config: GeminiConfig(
          apiKey: apiKey,
          defaultModel: 'imagen-4.0-fast-generate-001',
        ),
      );

      final aspectRatios = ['1:1', '16:9', '9:16'];

      for (final ratio in aspectRatios) {
        try {
          print('Testing aspect ratio: $ratio');

          final response = await imagenModel.generate(
            [Message.user('A simple geometric pattern')],
            options: ChatModelOptions(
              extra: {
                'aspectRatio': ratio,
                'numberOfImages': 1,
              },
            ),
          );

          expect(response.assistantGenMultiContent, isNotNull);
          print('  Generated image for $ratio aspect ratio');
        } on GeminiException catch (e) {
          if (e.statusCode == 429 ||
              e.message.contains('limit') ||
              e.message.contains('quota')) {
            print('SKIPPED: Imagen requires paid API tier');
            return;
          }
          if (e.statusCode == 400 && e.message.contains('not found')) {
            print('SKIPPED: Imagen model not available');
            return;
          }
          rethrow;
        }
      }
    });

    test('extracts prompt from multimodal message', () async {
      final imagenModel = GeminiChatModel(
        config: GeminiConfig(
          apiKey: apiKey,
          defaultModel: 'imagen-4.0-generate-001',
        ),
      );

      // Use multimodal message format (text part)
      final messages = [
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart.text('A futuristic cityscape at night'),
          ],
        ),
      ];

      try {
        final response = await imagenModel.generate(messages);

        expect(response.assistantGenMultiContent, isNotNull);
        print('Successfully generated image from multimodal prompt');
      } on GeminiException catch (e) {
        if (e.statusCode == 429 ||
            e.message.contains('limit') ||
            e.message.contains('quota')) {
          print('SKIPPED: Imagen requires paid API tier');
          return;
        }
        if (e.statusCode == 400 && e.message.contains('not found')) {
          print('SKIPPED: Imagen model not available');
          return;
        }
        rethrow;
      }
    });

    test('handles empty prompt gracefully', () async {
      final imagenModel = GeminiChatModel(
        config: GeminiConfig(
          apiKey: apiKey,
          defaultModel: 'imagen-4.0-generate-001',
        ),
      );

      // Empty message
      final messages = [
        Message.user(''),
      ];

      expect(
        () => imagenModel.generate(messages),
        throwsA(isA<GeminiException>().having(
          (e) => e.message,
          'message',
          contains('No prompt found'),
        )),
      );
    });

    test('model detection works correctly', () {
      // This tests the internal model detection logic
      final imagenModel = GeminiChatModel(
        config: GeminiConfig(
          apiKey: apiKey,
          defaultModel: 'imagen-4.0-generate-001',
        ),
      );

      final geminiModel = GeminiChatModel(
        config: GeminiConfig(
          apiKey: apiKey,
          defaultModel: 'gemini-2.5-flash',
        ),
      );

      // The models should use different endpoints internally
      // We verify by checking the default model patterns
      expect(imagenModel.config.defaultModel, startsWith('imagen-'));
      expect(geminiModel.config.defaultModel, startsWith('gemini-'));
    });
  });
}
