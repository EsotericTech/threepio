import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_converters.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/schema/tool_info.dart';

void main() {
  group('OpenAIConverters - Message Conversion', () {
    test('converts simple user message to OpenAI format', () {
      final message = Message(
        role: RoleType.user,
        content: 'Hello, world!',
      );

      final result = OpenAIConverters.messageToOpenAI(message);

      expect(result['role'], equals('user'));
      expect(result['content'], equals('Hello, world!'));
      expect(result.containsKey('name'), isFalse);
      expect(result.containsKey('tool_calls'), isFalse);
    });

    test('converts assistant message with name to OpenAI format', () {
      final message = Message(
        role: RoleType.assistant,
        content: 'Hello there!',
        name: 'assistant_1',
      );

      final result = OpenAIConverters.messageToOpenAI(message);

      expect(result['role'], equals('assistant'));
      expect(result['content'], equals('Hello there!'));
      expect(result['name'], equals('assistant_1'));
    });

    test('converts assistant message with tool calls to OpenAI format', () {
      final message = Message(
        role: RoleType.assistant,
        content: '',
        toolCalls: [
          ToolCall(
            id: 'call_123',
            type: 'function',
            function: FunctionCall(
              name: 'get_weather',
              arguments: '{"location": "NYC"}',
            ),
          ),
        ],
      );

      final result = OpenAIConverters.messageToOpenAI(message);

      expect(result['role'], equals('assistant'));
      expect(result['tool_calls'], isA<List>());
      expect(result['tool_calls'].length, equals(1));
      expect(result['tool_calls'][0]['id'], equals('call_123'));
      expect(result['tool_calls'][0]['type'], equals('function'));
      expect(
          result['tool_calls'][0]['function']['name'], equals('get_weather'));
      expect(
        result['tool_calls'][0]['function']['arguments'],
        equals('{"location": "NYC"}'),
      );
    });

    test('converts tool message to OpenAI format', () {
      final message = Message(
        role: RoleType.tool,
        content: '{"temp": 72, "condition": "sunny"}',
        toolCallId: 'call_123',
      );

      final result = OpenAIConverters.messageToOpenAI(message);

      expect(result['role'], equals('tool'));
      expect(
        result['content'],
        equals('{"temp": 72, "condition": "sunny"}'),
      );
      expect(result['tool_call_id'], equals('call_123'));
    });

    test('converts multi-modal message with image to OpenAI format', () {
      final message = Message(
        role: RoleType.user,
        content: '',
        userInputMultiContent: [
          MessageInputPart.text('What is in this image?'),
          MessageInputPart.imageUrl(
            'https://example.com/image.png',
            detail: ImageURLDetail.high,
          ),
        ],
      );

      final result = OpenAIConverters.messageToOpenAI(message);

      expect(result['role'], equals('user'));
      expect(result['content'], isA<List>());
      expect(result['content'].length, equals(2));
      expect(result['content'][0]['type'], equals('text'));
      expect(result['content'][0]['text'], equals('What is in this image?'));
      expect(result['content'][1]['type'], equals('image_url'));
      expect(
        result['content'][1]['image_url']['url'],
        equals('https://example.com/image.png'),
      );
      expect(result['content'][1]['image_url']['detail'], equals('high'));
    });

    test('converts OpenAI message to Threepio Message', () {
      final openAIMessage = {
        'role': 'assistant',
        'content': 'Hello from OpenAI!',
      };

      final result = OpenAIConverters.openAIToMessage(openAIMessage);

      expect(result.role, equals(RoleType.assistant));
      expect(result.content, equals('Hello from OpenAI!'));
      expect(result.responseMeta, isNull);
    });

    test('converts OpenAI message with metadata to Threepio Message', () {
      final openAIMessage = {
        'role': 'assistant',
        'content': 'Response with metadata',
      };

      final usage = {
        'prompt_tokens': 10,
        'completion_tokens': 20,
        'total_tokens': 30,
      };

      final result = OpenAIConverters.openAIToMessage(
        openAIMessage,
        finishReason: 'stop',
        usage: usage,
      );

      expect(result.role, equals(RoleType.assistant));
      expect(result.content, equals('Response with metadata'));
      expect(result.responseMeta, isNotNull);
      expect(result.responseMeta!.finishReason, equals('stop'));
      expect(result.responseMeta!.usage, isNotNull);
      expect(result.responseMeta!.usage!.promptTokens, equals(10));
      expect(result.responseMeta!.usage!.completionTokens, equals(20));
      expect(result.responseMeta!.usage!.totalTokens, equals(30));
    });

    test('converts OpenAI message with tool calls to Threepio Message', () {
      final openAIMessage = {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call_456',
            'type': 'function',
            'function': {
              'name': 'search',
              'arguments': '{"query": "test"}',
            },
          },
        ],
      };

      final result = OpenAIConverters.openAIToMessage(openAIMessage);

      expect(result.role, equals(RoleType.assistant));
      expect(result.toolCalls, isNotNull);
      expect(result.toolCalls!.length, equals(1));
      expect(result.toolCalls![0].id, equals('call_456'));
      expect(result.toolCalls![0].type, equals('function'));
      expect(result.toolCalls![0].function.name, equals('search'));
      expect(
          result.toolCalls![0].function.arguments, equals('{"query": "test"}'));
    });

    test('converts OpenAI delta to Threepio Message', () {
      final delta = {
        'role': 'assistant',
        'content': 'Hello',
      };

      final result = OpenAIConverters.openAIDeltaToMessage(delta);

      expect(result.role, equals(RoleType.assistant));
      expect(result.content, equals('Hello'));
    });

    test('converts OpenAI delta with tool calls to Threepio Message', () {
      final delta = {
        'tool_calls': [
          {
            'id': 'call_789',
            'type': 'function',
            'function': {
              'name': 'calculate',
              'arguments': '{"x": 5}',
            },
            'index': 0,
          },
        ],
      };

      final result = OpenAIConverters.openAIDeltaToMessage(delta);

      expect(result.role, equals(RoleType.assistant));
      expect(result.toolCalls, isNotNull);
      expect(result.toolCalls!.length, equals(1));
      expect(result.toolCalls![0].id, equals('call_789'));
      expect(result.toolCalls![0].index, equals(0));
    });
  });

  group('OpenAIConverters - Tool Conversion', () {
    test('converts ToolInfo to OpenAI format', () {
      final tool = ToolInfo(
        function: FunctionInfo(
          name: 'get_weather',
          description: 'Get the current weather',
          parameters: JSONSchema(
            type: 'object',
            properties: {
              'location': JSONSchemaProperty(
                type: 'string',
                description: 'The city name',
              ),
              'units': JSONSchemaProperty(
                type: 'string',
                enumValues: ['celsius', 'fahrenheit'],
                description: 'Temperature units',
              ),
            },
            required: ['location'],
            additionalProperties: false,
          ),
          strict: true,
        ),
      );

      final result = OpenAIConverters.toolInfoToOpenAI(tool);

      expect(result['type'], equals('function'));
      expect(result['function']['name'], equals('get_weather'));
      expect(
          result['function']['description'], equals('Get the current weather'));
      expect(result['function']['strict'], isTrue);

      final params = result['function']['parameters'] as Map<String, dynamic>;
      expect(params['type'], equals('object'));
      expect(params['required'], equals(['location']));
      expect(params['additionalProperties'], isFalse);
      expect(params['properties']['location']['type'], equals('string'));
      expect(
        params['properties']['location']['description'],
        equals('The city name'),
      );
      expect(params['properties']['units']['type'], equals('string'));
      expect(
        params['properties']['units']['enum'],
        equals(['celsius', 'fahrenheit']),
      );
    });

    test('converts ToolChoice to OpenAI format', () {
      expect(
        OpenAIConverters.toolChoiceToOpenAI(ToolChoice.forbidden),
        equals('none'),
      );
      expect(
        OpenAIConverters.toolChoiceToOpenAI(ToolChoice.allowed),
        equals('auto'),
      );
      expect(
        OpenAIConverters.toolChoiceToOpenAI(ToolChoice.forced),
        equals('required'),
      );
    });
  });

  group('OpenAIConverters - Role Conversion', () {
    test('throws on unknown OpenAI role', () {
      expect(
        () => OpenAIConverters.openAIToMessage({'role': 'unknown'}),
        throwsArgumentError,
      );
    });
  });
}
