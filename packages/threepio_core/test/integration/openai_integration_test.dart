import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/chat_model_options.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_config.dart';
import 'package:threepio_core/src/components/tool/agent.dart';
import 'package:threepio_core/src/components/tool/examples/calculator_tool.dart';
import 'package:threepio_core/src/components/tool/examples/weather_tool.dart';
import 'package:threepio_core/src/components/tool/tool_registry.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/schema/tool_info.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

/// Integration tests for OpenAI chat model with real API calls
///
/// These tests make actual API calls to OpenAI and require a valid API key
/// in the .env file at the project root.
///
/// Run with: flutter test test/integration/openai_integration_test.dart
void main() {
  late String apiKey;
  late OpenAIConfig config;
  late OpenAIChatModel model;

  setUpAll(() {
    // Load environment variables from project root
    final envPath = '/Users/gp/FlutterProjects/threepio/.env';
    final envFile = File(envPath);

    if (!envFile.existsSync()) {
      throw StateError(
        'Environment file not found at $envPath. Please create it with OPENAI_API_KEY.',
      );
    }

    final env = DotEnv()..load([envPath]);
    apiKey = env['OPENAI_API_KEY'] ?? '';

    if (apiKey.isEmpty) {
      throw StateError(
        'OPENAI_API_KEY not found in .env file. Please add your API key.',
      );
    }

    // Create config with the API key
    config = OpenAIConfig(
      apiKey: apiKey,
      defaultModel: 'gpt-4o-mini', // Use mini for faster/cheaper tests
    );

    model = OpenAIChatModel(config: config);

    print('✓ API key loaded successfully');
    print('✓ Using model: ${config.defaultModel}');
  });

  group('OpenAI Integration Tests', () {
    test('basic chat completion works', () async {
      print('\n--- Testing basic chat completion ---');

      final messages = [
        Message.user('Say "Hello, Threepio!" and nothing else.'),
      ];

      final response = await model.generate(messages);

      print('User: ${messages[0].content}');
      print('Assistant: ${response.content}');

      expect(response.role, equals(RoleType.assistant));
      expect(response.content, isNotEmpty);
      expect(response.content.toLowerCase(), contains('hello'));
      expect(response.responseMeta, isNotNull);
      expect(response.responseMeta!.usage, isNotNull);
      expect(response.responseMeta!.usage!.totalTokens, greaterThan(0));

      print(
          '✓ Total tokens used: ${response.responseMeta!.usage!.totalTokens}');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('streaming chat completion works', () async {
      print('\n--- Testing streaming chat completion ---');

      final messages = [
        Message.user('Count from 1 to 5, one number per line.'),
      ];

      final reader = await model.stream(messages);

      print('User: ${messages[0].content}');
      print('Assistant (streaming): ');

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
        // Expected end of stream
      }

      await reader.close();
      print('\n');

      expect(chunks, isNotEmpty);
      final fullContent = chunks.join();
      expect(fullContent, isNotEmpty);

      print('✓ Received ${chunks.length} chunks');
      print('✓ Full content length: ${fullContent.length} chars');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('tool calling works with single tool', () async {
      print('\n--- Testing tool calling with calculator ---');

      // Define a simple calculator tool
      final toolInfo = ToolInfo(
        function: FunctionInfo(
          name: 'calculator',
          description: 'Performs basic arithmetic operations',
          parameters: JSONSchema(
            type: 'object',
            properties: {
              'operation': JSONSchemaProperty(
                type: 'string',
                enumValues: ['add', 'subtract', 'multiply', 'divide'],
              ),
              'a': JSONSchemaProperty(type: 'number'),
              'b': JSONSchemaProperty(type: 'number'),
            },
            required: ['operation', 'a', 'b'],
            additionalProperties: false,
          ),
        ),
      );

      final modelWithTools = model.withTools([toolInfo]);

      final messages = [
        Message.user('What is 15 + 27? Use the calculator tool.'),
      ];

      final response = await modelWithTools.generate(messages);

      print('User: ${messages[0].content}');
      print('Assistant requested tool calls:');

      expect(response.role, equals(RoleType.assistant));
      expect(response.toolCalls, isNotNull);
      expect(response.toolCalls, isNotEmpty);

      final toolCall = response.toolCalls!.first;
      print('  - Tool: ${toolCall.function.name}');
      print('  - Arguments: ${toolCall.function.arguments}');

      expect(toolCall.function.name, equals('calculator'));

      final args =
          jsonDecode(toolCall.function.arguments) as Map<String, dynamic>;
      expect(args['operation'], equals('add'));
      expect(args['a'], equals(15));
      expect(args['b'], equals(27));

      print('✓ Tool call correctly requested');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('tool calling works with multiple tools', () async {
      print('\n--- Testing tool calling with multiple tools ---');

      final calculatorTool = ToolInfo(
        function: FunctionInfo(
          name: 'calculator',
          description: 'Performs arithmetic operations',
          parameters: JSONSchema(
            type: 'object',
            properties: {
              'operation': JSONSchemaProperty(
                type: 'string',
                enumValues: ['add', 'subtract', 'multiply', 'divide'],
              ),
              'a': JSONSchemaProperty(type: 'number'),
              'b': JSONSchemaProperty(type: 'number'),
            },
            required: ['operation', 'a', 'b'],
            additionalProperties: false,
          ),
        ),
      );

      final weatherTool = ToolInfo(
        function: FunctionInfo(
          name: 'get_weather',
          description: 'Get current weather for a location',
          parameters: JSONSchema(
            type: 'object',
            properties: {
              'location': JSONSchemaProperty(
                type: 'string',
                description: 'City name',
              ),
              'units': JSONSchemaProperty(
                type: 'string',
                enumValues: ['celsius', 'fahrenheit'],
              ),
            },
            required: ['location'],
            additionalProperties: false,
          ),
        ),
      );

      final modelWithTools = model.withTools([calculatorTool, weatherTool]);

      final messages = [
        Message.user(
          'What is the weather in New York? Use get_weather tool.',
        ),
      ];

      final response = await modelWithTools.generate(messages);

      print('User: ${messages[0].content}');
      print('Assistant requested tool calls:');

      expect(response.toolCalls, isNotNull);
      expect(response.toolCalls, isNotEmpty);

      final toolCall = response.toolCalls!.first;
      print('  - Tool: ${toolCall.function.name}');
      print('  - Arguments: ${toolCall.function.arguments}');

      expect(toolCall.function.name, equals('get_weather'));

      final args =
          jsonDecode(toolCall.function.arguments) as Map<String, dynamic>;
      expect(args['location'], isNotNull);
      expect(args['location'].toString().toLowerCase(), contains('new'));

      print('✓ Correct tool selected from multiple options');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('full agent loop with real tools', () async {
      print('\n--- Testing full Agent loop with real tool execution ---');

      // Create registry with actual tools
      final registry = ToolRegistry();
      registry.register(CalculatorTool());
      registry.register(WeatherTool());

      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Create agent
      final agent = Agent(
        model: model,
        toolRegistry: registry,
        config: const AgentConfig(maxIterations: 5),
      );

      final messages = [
        Message.user(
          'Calculate 23 + 19, then tell me the result.',
        ),
      ];

      print('User: ${messages[0].content}');

      final response = await agent.run(messages);

      print('Agent final response: ${response.content}');

      expect(response.role, equals(RoleType.assistant));
      expect(response.content, isNotEmpty);

      // The response should contain the calculation result (42)
      expect(
        response.content.contains('42') ||
            response.content.contains('forty') ||
            response.content.contains('forty-two'),
        isTrue,
        reason: 'Response should contain the calculation result (42)',
      );

      print('✓ Agent successfully completed ReAct loop');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('agent handles multiple tool calls', () async {
      print('\n--- Testing Agent with multiple tool calls ---');

      final registry = ToolRegistry();
      registry.register(CalculatorTool());
      registry.register(WeatherTool());

      await Future<void>.delayed(const Duration(milliseconds: 20));

      final agent = Agent(
        model: model,
        toolRegistry: registry,
        config: const AgentConfig(maxIterations: 5),
      );

      final messages = [
        Message.user(
          'Calculate 10 * 5, then get the weather in London. Give me both results.',
        ),
      ];

      print('User: ${messages[0].content}');

      final response = await agent.run(messages);

      print('Agent final response: ${response.content}');

      expect(response.role, equals(RoleType.assistant));
      expect(response.content, isNotEmpty);

      // Response should mention both results
      expect(
        response.content.contains('50') || response.content.contains('fifty'),
        isTrue,
        reason: 'Response should contain calculation result (50)',
      );

      expect(
        response.content.toLowerCase().contains('weather') ||
            response.content.toLowerCase().contains('temperature') ||
            response.content.toLowerCase().contains('london'),
        isTrue,
        reason: 'Response should mention weather information',
      );

      print('✓ Agent handled multiple tool calls successfully');
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('agent streaming works', () async {
      print('\n--- Testing Agent streaming ---');

      final registry = ToolRegistry();
      registry.register(CalculatorTool());

      await Future<void>.delayed(const Duration(milliseconds: 20));

      final agent = Agent(
        model: model,
        toolRegistry: registry,
        config: const AgentConfig(maxIterations: 3),
      );

      final messages = [
        Message.user('What is 7 times 8? Calculate it and tell me.'),
      ];

      print('User: ${messages[0].content}');
      print('Agent (streaming):');

      final reader = await agent.stream(messages);

      var messageCount = 0;
      try {
        while (true) {
          final message = await reader.recv();
          messageCount++;

          if (message.role == RoleType.assistant &&
              message.content.isNotEmpty) {
            stdout.write(message.content);
          } else if (message.role == RoleType.tool) {
            print('\n[Tool executed: ${message.name}]');
          }
        }
      } on StreamEOFException {
        // Expected end
      }

      await reader.close();
      print('\n');

      expect(messageCount, greaterThan(0));
      print('✓ Received $messageCount messages in stream');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
