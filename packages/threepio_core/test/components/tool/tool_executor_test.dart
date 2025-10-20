import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/examples/calculator_tool.dart';
import 'package:threepio_core/src/components/tool/examples/weather_tool.dart';
import 'package:threepio_core/src/components/tool/tool_executor.dart';
import 'package:threepio_core/src/components/tool/tool_registry.dart';
import 'package:threepio_core/src/schema/message.dart';

void main() {
  group('ToolExecutor', () {
    late ToolRegistry registry;
    late ToolExecutor executor;

    setUp(() async {
      registry = ToolRegistry();
      registry.register(CalculatorTool());
      registry.register(WeatherTool());

      // Wait for async registration
      await Future<void>.delayed(const Duration(milliseconds: 10));

      executor = ToolExecutor(registry: registry);
    });

    test('executes a simple tool call', () async {
      final toolCall = ToolCall(
        id: 'call_123',
        type: 'function',
        function: FunctionCall(
          name: 'calculator',
          arguments: jsonEncode({'operation': 'add', 'a': 5, 'b': 3}),
        ),
      );

      final result = await executor.executeToolCall(toolCall);

      expect(result.isSuccess, isTrue);
      expect(result.toolCallId, equals('call_123'));
      expect(result.toolName, equals('calculator'));
      expect(result.error, isNull);

      final output = jsonDecode(result.output) as Map<String, dynamic>;
      expect(output['result'], equals(8));
    });

    test('handles tool not found', () async {
      final toolCall = ToolCall(
        id: 'call_456',
        type: 'function',
        function: FunctionCall(
          name: 'unknown_tool',
          arguments: '{}',
        ),
      );

      final result = await executor.executeToolCall(toolCall);

      expect(result.isSuccess, isFalse);
      expect(result.error, contains('Tool not found'));
    });

    test('handles invalid JSON arguments', () async {
      final toolCall = ToolCall(
        id: 'call_789',
        type: 'function',
        function: FunctionCall(
          name: 'calculator',
          arguments: 'not valid json',
        ),
      );

      final result = await executor.executeToolCall(toolCall);

      expect(result.isSuccess, isFalse);
      expect(result.error, contains('Invalid JSON arguments'));
    });

    test('handles tool execution errors', () async {
      final toolCall = ToolCall(
        id: 'call_error',
        type: 'function',
        function: FunctionCall(
          name: 'calculator',
          arguments: jsonEncode({'operation': 'divide', 'a': 10, 'b': 0}),
        ),
      );

      final result = await executor.executeToolCall(toolCall);

      expect(result.isSuccess, isFalse);
      expect(result.error, contains('Execution failed'));
    });

    test('executes multiple tool calls', () async {
      final toolCalls = [
        ToolCall(
          id: 'call_1',
          type: 'function',
          function: FunctionCall(
            name: 'calculator',
            arguments: jsonEncode({'operation': 'add', 'a': 1, 'b': 2}),
          ),
        ),
        ToolCall(
          id: 'call_2',
          type: 'function',
          function: FunctionCall(
            name: 'calculator',
            arguments: jsonEncode({'operation': 'multiply', 'a': 3, 'b': 4}),
          ),
        ),
      ];

      final results = await executor.executeToolCalls(toolCalls);

      expect(results, hasLength(2));
      expect(results[0].isSuccess, isTrue);
      expect(results[1].isSuccess, isTrue);

      final output1 = jsonDecode(results[0].output) as Map<String, dynamic>;
      final output2 = jsonDecode(results[1].output) as Map<String, dynamic>;
      expect(output1['result'], equals(3));
      expect(output2['result'], equals(12));
    });

    test('executes multiple tool calls in parallel', () async {
      final toolCalls = [
        ToolCall(
          id: 'call_1',
          type: 'function',
          function: FunctionCall(
            name: 'get_weather',
            arguments: jsonEncode({'location': 'New York'}),
          ),
        ),
        ToolCall(
          id: 'call_2',
          type: 'function',
          function: FunctionCall(
            name: 'get_weather',
            arguments: jsonEncode({'location': 'London'}),
          ),
        ),
      ];

      final results = await executor.executeToolCallsParallel(toolCalls);

      expect(results, hasLength(2));
      expect(results[0].isSuccess, isTrue);
      expect(results[1].isSuccess, isTrue);
    });

    test('converts result to message', () async {
      final toolCall = ToolCall(
        id: 'call_msg',
        type: 'function',
        function: FunctionCall(
          name: 'calculator',
          arguments: jsonEncode({'operation': 'subtract', 'a': 10, 'b': 3}),
        ),
      );

      final result = await executor.executeToolCall(toolCall);
      final message = result.toMessage();

      expect(message.role, equals(RoleType.tool));
      expect(message.toolCallId, equals('call_msg'));
      expect(message.name, equals('calculator'));
      expect(message.content, contains('result'));
    });

    test('converts error result to message', () async {
      final toolCall = ToolCall(
        id: 'call_error',
        type: 'function',
        function: FunctionCall(
          name: 'unknown_tool',
          arguments: '{}',
        ),
      );

      final result = await executor.executeToolCall(toolCall);
      final message = result.toMessage();

      expect(message.role, equals(RoleType.tool));
      expect(message.toolCallId, equals('call_error'));
      expect(message.content, contains('Error'));
    });

    test('executeFromMessage extracts and executes tool calls', () async {
      final message = Message(
        role: RoleType.assistant,
        content: '',
        toolCalls: [
          ToolCall(
            id: 'call_1',
            type: 'function',
            function: FunctionCall(
              name: 'calculator',
              arguments: jsonEncode({'operation': 'add', 'a': 5, 'b': 5}),
            ),
          ),
        ],
      );

      final messages = await executor.executeFromMessage(message);

      expect(messages, isNotNull);
      expect(messages, hasLength(1));
      expect(messages![0].role, equals(RoleType.tool));
      expect(messages[0].toolCallId, equals('call_1'));
    });

    test('executeFromMessage returns null when no tool calls', () async {
      final message = Message(
        role: RoleType.assistant,
        content: 'Hello, I am an assistant.',
      );

      final messages = await executor.executeFromMessage(message);

      expect(messages, isNull);
    });
  });
}
