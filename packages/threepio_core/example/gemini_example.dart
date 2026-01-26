// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

/// Comprehensive example showing how to use Threepio Core with Google Gemini
///
/// This example demonstrates:
/// 1. Basic text generation
/// 2. Streaming responses
/// 3. Multimodal input (images)
/// 4. Image generation
/// 5. Tool calling
/// 6. Agent with ReAct pattern
///
/// To run this example:
/// 1. Set GEMINI_API_KEY environment variable
/// 2. Run: dart run example/gemini_example.dart
Future<void> main() async {
  // Get API key from environment
  final apiKey = Platform.environment['GEMINI_API_KEY'];
  if (apiKey == null) {
    print('Error: GEMINI_API_KEY environment variable not set');
    exit(1);
  }

  // Configure Gemini
  final config = GeminiConfig(
    apiKey: apiKey,
    defaultModel: 'gemini-2.5-flash',
    timeout: const Duration(seconds: 120),
  );

  // Create chat model
  final model = GeminiChatModel(config: config);

  // Run examples
  await basicGeneration(model);
  await streamingExample(model);
  await toolCallingExample(model);
  await agentExample(model);
}

/// Example 1: Basic text generation
Future<void> basicGeneration(GeminiChatModel model) async {
  print('\n=== Basic Generation ===\n');

  // Simple question
  final messages = [
    Message.system('You are a helpful assistant. Be concise.'),
    Message.user('What is the capital of Japan?'),
  ];

  final response = await model.generate(messages);

  print('Question: What is the capital of Japan?');
  print('Answer: ${response.content}');
  print('\nToken usage:');
  print('  Prompt tokens: ${response.responseMeta?.usage?.promptTokens}');
  print('  Completion tokens: ${response.responseMeta?.usage?.completionTokens}');
  print('  Total tokens: ${response.responseMeta?.usage?.totalTokens}');
}

/// Example 2: Streaming responses
Future<void> streamingExample(GeminiChatModel model) async {
  print('\n=== Streaming Example ===\n');

  final messages = [
    Message.user('Count from 1 to 10, one number per line.'),
  ];

  print('Streaming response:');

  final reader = await model.stream(messages);

  try {
    while (true) {
      final chunk = await reader.recv();
      stdout.write(chunk.content);
    }
  } on StreamEOFException {
    // Stream complete
  }
  await reader.close();

  print('\n--- Stream complete ---');
}

/// Example 3: Tool calling
Future<void> toolCallingExample(GeminiChatModel model) async {
  print('\n=== Tool Calling Example ===\n');

  // Define a weather tool
  final weatherTool = ToolInfo.simple(
    name: 'get_weather',
    description: 'Get the current weather for a location',
    properties: {
      'location': JSONSchemaProperty.string(
        description: 'City name, e.g., "San Francisco"',
      ),
      'unit': JSONSchemaProperty.string(
        description: 'Temperature unit',
        enumValues: ['celsius', 'fahrenheit'],
      ),
    },
    required: ['location'],
  );

  // Bind tools to model
  final modelWithTools = model.withTools([weatherTool]);

  // Ask about weather
  final messages = [
    Message.user('What is the weather in Paris?'),
  ];

  print('User: What is the weather in Paris?');
  print('\nModel requesting tool call...');

  final response = await modelWithTools.generate(messages);

  if (response.toolCalls != null && response.toolCalls!.isNotEmpty) {
    final toolCall = response.toolCalls!.first;
    print('Tool: ${toolCall.function.name}');
    print('Arguments: ${toolCall.function.arguments}');

    // Simulate tool execution
    final weatherResult = {
      'location': 'Paris',
      'temperature': 18,
      'unit': 'celsius',
      'condition': 'Partly cloudy',
    };

    print('\nExecuting tool and continuing conversation...');

    // Continue with tool result
    final finalResponse = await modelWithTools.generate([
      ...messages,
      response,
      Message(
        role: RoleType.tool,
        content: jsonEncode(weatherResult),
        toolCallId: toolCall.id,
        toolName: toolCall.function.name,
      ),
    ]);

    print('\nFinal response: ${finalResponse.content}');
  } else {
    print('Response: ${response.content}');
  }
}

/// Example 4: Agent with ReAct pattern
Future<void> agentExample(GeminiChatModel model) async {
  print('\n=== Agent Example (ReAct Pattern) ===\n');

  // Create a calculator tool
  final calculatorTool = _CalculatorTool();

  // Create tool registry
  final registry = ToolRegistry();
  registry.register(calculatorTool);

  // Create agent
  final agent = Agent(
    model: model,
    toolRegistry: registry,
    config: const AgentConfig(
      maxIterations: 5,
      maxToolCalls: 10,
    ),
  );

  // Run agent
  final messages = [
    Message.system('You are a helpful assistant with a calculator.'),
    Message.user('What is 123 * 456?'),
  ];

  print('User: What is 123 * 456?');
  print('\nAgent thinking...');

  final response = await agent.run(messages);

  print('\nAgent response: ${response.content}');
}

/// Calculator tool implementation
class _CalculatorTool extends InvokableTool {
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

    // Simple expression parser
    final parts = expr.replaceAll(' ', '').split(RegExp(r'(?=[+\-*/])|(?<=[+\-*/])'));
    if (parts.length >= 3) {
      final a = double.tryParse(parts[0]) ?? 0;
      final op = parts[1];
      final b = double.tryParse(parts[2]) ?? 0;

      double result;
      switch (op) {
        case '+':
          result = a + b;
        case '-':
          result = a - b;
        case '*':
          result = a * b;
        case '/':
          result = b != 0 ? a / b : double.nan;
        default:
          return 'Unknown operator: $op';
      }

      // Return clean integer if possible
      if (result == result.roundToDouble()) {
        return result.toInt().toString();
      }
      return result.toString();
    }

    return 'Could not parse expression: $expr';
  }
}
