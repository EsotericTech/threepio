import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/chat_model_options.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_converters.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/schema/tool_info.dart';

void main() {
  group('GeminiConverters - Message Conversion', () {
    test('converts user message to Gemini format', () {
      final message = Message(
        role: RoleType.user,
        content: 'Hello, world!',
      );

      final result = GeminiConverters.messageToGemini(message);

      expect(result['role'], equals('user'));
      expect(result['parts'], isA<List>());
      expect(result['parts'][0]['text'], equals('Hello, world!'));
    });

    test('converts assistant message to Gemini model role', () {
      final message = Message(
        role: RoleType.assistant,
        content: 'Hello there!',
      );

      final result = GeminiConverters.messageToGemini(message);

      expect(result['role'], equals('model'));
      expect(result['parts'][0]['text'], equals('Hello there!'));
    });

    test('converts tool response message to Gemini format', () {
      final message = Message(
        role: RoleType.tool,
        content: '{"temp": 72}',
        toolCallId: 'call_123',
        toolName: 'get_weather',
      );

      final result = GeminiConverters.messageToGemini(message);

      expect(result['role'], equals('user'));
      expect(result['parts'], isA<List>());
      expect(result['parts'][0]['functionResponse'], isNotNull);
      expect(
        result['parts'][0]['functionResponse']['name'],
        equals('get_weather'),
      );
      expect(
        result['parts'][0]['functionResponse']['response']['result'],
        equals('{"temp": 72}'),
      );
    });

    test('converts assistant message with tool calls to Gemini format', () {
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

      final result = GeminiConverters.messageToGemini(message);

      expect(result['role'], equals('model'));
      expect(result['parts'], isA<List>());
      expect(result['parts'][0]['functionCall'], isNotNull);
      expect(
        result['parts'][0]['functionCall']['name'],
        equals('get_weather'),
      );
      expect(
        result['parts'][0]['functionCall']['args'],
        equals({'location': 'NYC'}),
      );
    });

    test('converts multimodal message with base64 image', () {
      final message = Message(
        role: RoleType.user,
        content: '',
        userInputMultiContent: [
          MessageInputPart.text('What is in this image?'),
          MessageInputPart.imageUrl(
            'data:image/png;base64,iVBORw0KGgo=',
          ),
        ],
      );

      final result = GeminiConverters.messageToGemini(message);

      expect(result['role'], equals('user'));
      expect(result['parts'], isA<List>());
      expect(result['parts'].length, equals(2));
      expect(result['parts'][0]['text'], equals('What is in this image?'));
      expect(result['parts'][1]['inline_data'], isNotNull);
      expect(
        result['parts'][1]['inline_data']['mime_type'],
        equals('image/png'),
      );
      expect(
        result['parts'][1]['inline_data']['data'],
        equals('iVBORw0KGgo='),
      );
    });

    test('converts multimodal message with URL image', () {
      final message = Message(
        role: RoleType.user,
        content: '',
        userInputMultiContent: [
          MessageInputPart.imageUrl('https://example.com/image.jpg'),
        ],
      );

      final result = GeminiConverters.messageToGemini(message);

      expect(result['parts'][0]['file_data'], isNotNull);
      expect(
        result['parts'][0]['file_data']['mime_type'],
        equals('image/jpeg'),
      );
      expect(
        result['parts'][0]['file_data']['file_uri'],
        equals('https://example.com/image.jpg'),
      );
    });
  });

  group('GeminiConverters - Response Conversion', () {
    test('converts Gemini response to Threepio Message', () {
      final candidate = {
        'content': {
          'parts': [
            {'text': 'Hello from Gemini!'}
          ],
          'role': 'model',
        },
        'finishReason': 'STOP',
      };

      final result = GeminiConverters.geminiToMessage(candidate);

      expect(result.role, equals(RoleType.assistant));
      expect(result.content, equals('Hello from Gemini!'));
      expect(result.responseMeta?.finishReason, equals('stop'));
    });

    test('converts Gemini response with usage metadata', () {
      final candidate = {
        'content': {
          'parts': [
            {'text': 'Response with usage'}
          ],
        },
        'finishReason': 'STOP',
      };

      final usageMetadata = {
        'promptTokenCount': 10,
        'candidatesTokenCount': 20,
        'totalTokenCount': 30,
      };

      final result = GeminiConverters.geminiToMessage(
        candidate,
        usageMetadata: usageMetadata,
      );

      expect(result.responseMeta, isNotNull);
      expect(result.responseMeta!.usage, isNotNull);
      expect(result.responseMeta!.usage!.promptTokens, equals(10));
      expect(result.responseMeta!.usage!.completionTokens, equals(20));
      expect(result.responseMeta!.usage!.totalTokens, equals(30));
    });

    test('converts Gemini response with function calls', () {
      final candidate = {
        'content': {
          'parts': [
            {
              'functionCall': {
                'name': 'get_weather',
                'args': {'location': 'Tokyo'},
              }
            }
          ],
        },
      };

      final result = GeminiConverters.geminiToMessage(candidate);

      expect(result.toolCalls, isNotNull);
      expect(result.toolCalls!.length, equals(1));
      expect(result.toolCalls![0].function.name, equals('get_weather'));
      // Arguments are stored as JSON string
      final args = jsonDecode(result.toolCalls![0].function.arguments);
      expect(args, equals({'location': 'Tokyo'}));
      // Generated UUID should be present
      expect(result.toolCalls![0].id, isNotEmpty);
    });

    test('converts Gemini response with inline data (multimodal output) - snake_case', () {
      final candidate = {
        'content': {
          'parts': [
            {
              'inline_data': {
                'mime_type': 'image/png',
                'data': 'base64encodeddata',
              }
            }
          ],
        },
      };

      final result = GeminiConverters.geminiToMessage(candidate);

      expect(result.assistantGenMultiContent, isNotNull);
      expect(result.assistantGenMultiContent!.length, equals(1));
      expect(
        result.assistantGenMultiContent![0].type,
        equals(ChatMessagePartType.imageUrl),
      );
    });

    test('converts Gemini response with inlineData (multimodal output) - camelCase', () {
      // Real Gemini API uses camelCase (inlineData, mimeType)
      final candidate = {
        'content': {
          'parts': [
            {
              'inlineData': {
                'mimeType': 'image/png',
                'data': 'iVBORw0KGgoAAAANSUhEUgAAAAE=',
              }
            }
          ],
        },
      };

      final result = GeminiConverters.geminiToMessage(candidate);

      expect(result.assistantGenMultiContent, isNotNull);
      expect(result.assistantGenMultiContent!.length, equals(1));
      expect(
        result.assistantGenMultiContent![0].type,
        equals(ChatMessagePartType.imageUrl),
      );
      expect(
        result.assistantGenMultiContent![0].image?.url,
        startsWith('data:image/png;base64,'),
      );
    });

    test('converts Gemini response with text and image', () {
      // Mixed response with text and generated image (as real API returns)
      final candidate = {
        'content': {
          'parts': [
            {'text': 'Here is your image:'},
            {
              'inlineData': {
                'mimeType': 'image/png',
                'data': 'iVBORw0KGgoAAAANSUhEUgAAAAE=',
              }
            }
          ],
        },
      };

      final result = GeminiConverters.geminiToMessage(candidate);

      expect(result.content, equals('Here is your image:'));
      expect(result.assistantGenMultiContent, isNotNull);
      expect(result.assistantGenMultiContent!.length, equals(1));
      expect(
        result.assistantGenMultiContent![0].type,
        equals(ChatMessagePartType.imageUrl),
      );
    });

    test('maps finish reasons correctly', () {
      final testCases = {
        'STOP': 'stop',
        'MAX_TOKENS': 'length',
        'SAFETY': 'content_filter',
        'RECITATION': 'content_filter',
        'OTHER': 'other',
      };

      for (final entry in testCases.entries) {
        final candidate = {
          'content': {
            'parts': [
              {'text': 'test'}
            ],
          },
          'finishReason': entry.key,
        };

        final result = GeminiConverters.geminiToMessage(candidate);
        expect(result.responseMeta?.finishReason, equals(entry.value));
      }
    });
  });

  group('GeminiConverters - Streaming Conversion', () {
    test('converts streaming delta to Message', () {
      final candidate = {
        'content': {
          'parts': [
            {'text': 'Hello'}
          ],
        },
      };

      final result = GeminiConverters.geminiDeltaToMessage(candidate);

      expect(result, isNotNull);
      expect(result!.content, equals('Hello'));
    });

    test('returns null for empty delta', () {
      final candidate = {
        'content': {
          'parts': <Map<String, dynamic>>[],
        },
      };

      final result = GeminiConverters.geminiDeltaToMessage(candidate);

      expect(result, isNull);
    });

    test('handles delta with function call', () {
      final candidate = {
        'content': {
          'parts': [
            {
              'functionCall': {
                'name': 'search',
                'args': {'query': 'test'},
              }
            }
          ],
        },
      };

      final result = GeminiConverters.geminiDeltaToMessage(candidate);

      expect(result, isNotNull);
      expect(result!.toolCalls, isNotNull);
      expect(result.toolCalls![0].function.name, equals('search'));
    });
  });

  group('GeminiConverters - Tool Conversion', () {
    test('converts ToolInfo to Gemini function declaration', () {
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
            },
            required: ['location'],
          ),
        ),
      );

      final result = GeminiConverters.toolInfoToGemini(tool);

      expect(result['name'], equals('get_weather'));
      expect(result['description'], equals('Get the current weather'));
      expect(result['parameters'], isNotNull);
      expect(result['parameters']['type'], equals('object'));
      expect(result['parameters']['required'], equals(['location']));
    });

    test('converts ToolChoice to Gemini format', () {
      expect(
        GeminiConverters.toolChoiceToGemini(ToolChoice.forbidden),
        equals('NONE'),
      );
      expect(
        GeminiConverters.toolChoiceToGemini(ToolChoice.allowed),
        equals('AUTO'),
      );
      expect(
        GeminiConverters.toolChoiceToGemini(ToolChoice.forced),
        equals('ANY'),
      );
    });
  });

  group('GeminiConverters - System Instruction Extraction', () {
    test('extracts system instruction from messages', () {
      final messages = [
        Message(role: RoleType.system, content: 'You are a helpful assistant.'),
        Message(role: RoleType.user, content: 'Hello'),
      ];

      final (systemInstruction, filtered) =
          GeminiConverters.extractSystemInstruction(messages);

      expect(systemInstruction, equals('You are a helpful assistant.'));
      expect(filtered.length, equals(1));
      expect(filtered[0].role, equals(RoleType.user));
    });

    test('concatenates multiple system messages', () {
      final messages = [
        Message(role: RoleType.system, content: 'First instruction.'),
        Message(role: RoleType.user, content: 'Hello'),
        Message(role: RoleType.system, content: 'Second instruction.'),
      ];

      final (systemInstruction, filtered) =
          GeminiConverters.extractSystemInstruction(messages);

      expect(
        systemInstruction,
        equals('First instruction.\nSecond instruction.'),
      );
      expect(filtered.length, equals(1));
    });

    test('returns null for no system messages', () {
      final messages = [
        Message(role: RoleType.user, content: 'Hello'),
      ];

      final (systemInstruction, filtered) =
          GeminiConverters.extractSystemInstruction(messages);

      expect(systemInstruction, isNull);
      expect(filtered.length, equals(1));
    });
  });
}
