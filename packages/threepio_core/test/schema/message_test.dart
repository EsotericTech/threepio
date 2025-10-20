import 'package:test/test.dart';
import 'package:threepio_core/src/schema/message.dart';

void main() {
  group('RoleType', () {
    test('enum values are correct', () {
      expect(RoleType.values.length, 4);
      expect(
          RoleType.values,
          containsAll([
            RoleType.user,
            RoleType.assistant,
            RoleType.system,
            RoleType.tool,
          ]));
    });
  });

  group('Message', () {
    test('creates user message', () {
      final message = Message.user('Hello');
      expect(message.role, RoleType.user);
      expect(message.content, 'Hello');
    });

    test('creates assistant message', () {
      final message = Message.assistant('Hi there');
      expect(message.role, RoleType.assistant);
      expect(message.content, 'Hi there');
    });

    test('creates system message', () {
      final message = Message.system('You are helpful');
      expect(message.role, RoleType.system);
      expect(message.content, 'You are helpful');
    });

    test('creates tool message', () {
      final message = Message.tool(
        content: '{"result": "success"}',
        toolCallId: 'call_123',
        toolName: 'get_weather',
      );
      expect(message.role, RoleType.tool);
      expect(message.content, '{"result": "success"}');
      expect(message.toolCallId, 'call_123');
      expect(message.toolName, 'get_weather');
    });

    test('creates message with tool calls', () {
      final toolCall = ToolCall(
        id: 'call_123',
        function: FunctionCall(name: 'get_weather', arguments: '{}'),
      );
      final message = Message.assistant('', toolCalls: [toolCall]);
      expect(message.toolCalls?.length, 1);
      expect(message.toolCalls?.first.id, 'call_123');
    });

    test('toDisplayString includes role and content', () {
      final message = Message.user('Hello');
      final display = message.toDisplayString();
      expect(display, contains('user'));
      expect(display, contains('Hello'));
    });

    test('toDisplayString includes tool calls', () {
      final toolCall = ToolCall(
        id: 'call_123',
        function: FunctionCall(name: 'test', arguments: '{}'),
      );
      final message = Message.assistant('', toolCalls: [toolCall]);
      final display = message.toDisplayString();
      expect(display, contains('tool_calls'));
      expect(display, contains('call_123'));
    });

    test('serializes and deserializes correctly', () {
      final original = Message(
        role: RoleType.user,
        content: 'Test message',
        name: 'User1',
      );
      final json = original.toJson();
      final deserialized = Message.fromJson(json);

      expect(deserialized.role, original.role);
      expect(deserialized.content, original.content);
      expect(deserialized.name, original.name);
    });
  });

  group('ToolCall', () {
    test('creates tool call', () {
      final toolCall = ToolCall(
        id: 'call_123',
        function: FunctionCall(
          name: 'get_weather',
          arguments: '{"city": "SF"}',
        ),
      );
      expect(toolCall.id, 'call_123');
      expect(toolCall.type, 'function');
      expect(toolCall.function.name, 'get_weather');
    });

    test('serializes and deserializes correctly', () {
      final original = ToolCall(
        id: 'call_123',
        type: 'function',
        function: FunctionCall(name: 'test', arguments: '{}'),
      );
      final json = original.toJson();
      final deserialized = ToolCall.fromJson(json);

      expect(deserialized.id, original.id);
      expect(deserialized.type, original.type);
      expect(deserialized.function.name, original.function.name);
    });
  });

  group('MessageConcatenator', () {
    test('concatenates simple messages', () {
      final messages = [
        Message.user('Hello'),
        Message.user(' world'),
        Message.user('!'),
      ];
      final result = MessageConcatenator.concat(messages);
      expect(result.content, 'Hello world!');
    });

    test('concatenates messages with tool calls', () {
      final toolCall1 = ToolCall(
        id: 'call_1',
        function: FunctionCall(name: 'func1', arguments: '{}'),
      );
      final toolCall2 = ToolCall(
        id: 'call_2',
        function: FunctionCall(name: 'func2', arguments: '{}'),
      );
      final messages = [
        Message.assistant('Part1', toolCalls: [toolCall1]),
        Message.assistant('Part2', toolCalls: [toolCall2]),
      ];
      final result = MessageConcatenator.concat(messages);
      expect(result.content, 'Part1Part2');
      expect(result.toolCalls?.length, 2);
    });

    test('throws on different roles', () {
      final messages = [
        Message.user('Hello'),
        Message.assistant('Hi'),
      ];
      expect(
        () => MessageConcatenator.concat(messages),
        throwsArgumentError,
      );
    });

    test('throws on empty list', () {
      expect(
        () => MessageConcatenator.concat([]),
        throwsArgumentError,
      );
    });

    test('handles single message', () {
      final message = Message.user('Hello');
      final result = MessageConcatenator.concat([message]);
      expect(result.content, 'Hello');
    });
  });

  group('TokenUsage', () {
    test('creates token usage', () {
      final usage = TokenUsage(
        promptTokens: 10,
        completionTokens: 20,
        totalTokens: 30,
      );
      expect(usage.promptTokens, 10);
      expect(usage.completionTokens, 20);
      expect(usage.totalTokens, 30);
    });

    test('serializes and deserializes correctly', () {
      final original = TokenUsage(
        promptTokens: 10,
        completionTokens: 20,
        totalTokens: 30,
        promptTokenDetails: PromptTokenDetails(cachedTokens: 5),
      );
      final json = original.toJson();
      final deserialized = TokenUsage.fromJson(json);

      expect(deserialized.promptTokens, original.promptTokens);
      expect(deserialized.completionTokens, original.completionTokens);
      expect(deserialized.totalTokens, original.totalTokens);
      expect(
        deserialized.promptTokenDetails?.cachedTokens,
        original.promptTokenDetails?.cachedTokens,
      );
    });
  });

  group('MessageInputPart', () {
    test('creates text part', () {
      final part = MessageInputPart.text('Hello');
      expect(part.type, ChatMessagePartType.text);
      expect(part.text, 'Hello');
    });

    test('creates image URL part', () {
      final part = MessageInputPart.imageUrl('https://example.com/image.jpg');
      expect(part.type, ChatMessagePartType.imageUrl);
      expect(part.image?.common.url, 'https://example.com/image.jpg');
    });

    test('creates image URL with detail', () {
      final part = MessageInputPart.imageUrl(
        'https://example.com/image.jpg',
        detail: ImageURLDetail.high,
      );
      expect(part.image?.detail, ImageURLDetail.high);
    });
  });
}
