import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openrouter/openrouter_response_parser.dart';
import 'package:threepio_core/src/schema/message.dart';

void main() {
  group('OpenRouterResponseParser', () {
    late OpenRouterResponseParser parser;

    setUp(() {
      parser = const OpenRouterResponseParser();
    });

    group('parseCompletionResponse', () {
      test('parses standard text response', () {
        final response = {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': 'Hello, how can I help you?',
              },
              'finish_reason': 'stop',
            },
          ],
          'usage': {
            'prompt_tokens': 10,
            'completion_tokens': 20,
            'total_tokens': 30,
          },
        };

        final message = parser.parseCompletionResponse(response);

        expect(message.role, equals(RoleType.assistant));
        expect(message.content, equals('Hello, how can I help you?'));
        expect(message.responseMeta?.finishReason, equals('stop'));
        expect(message.responseMeta?.usage?.promptTokens, equals(10));
        expect(message.responseMeta?.usage?.completionTokens, equals(20));
      });

      test('parses response with base64 image content', () {
        // Simulate an image generation response with base64 data
        final base64Image = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

        final response = {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': base64Image,
              },
              'finish_reason': 'stop',
            },
          ],
        };

        final message = parser.parseCompletionResponse(response);

        expect(message.role, equals(RoleType.assistant));
        expect(message.assistantGenMultiContent, isNotNull);
        expect(message.assistantGenMultiContent!.length, equals(1));
        expect(message.assistantGenMultiContent![0].type, equals(ChatMessagePartType.imageUrl));
        expect(message.assistantGenMultiContent![0].image?.base64Data, equals(base64Image));
      });

      test('parses response with data URL image', () {
        final dataUrl = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

        final response = {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': dataUrl,
              },
              'finish_reason': 'stop',
            },
          ],
        };

        final message = parser.parseCompletionResponse(response);

        expect(message.assistantGenMultiContent, isNotNull);
        expect(message.assistantGenMultiContent![0].type, equals(ChatMessagePartType.imageUrl));
        expect(message.assistantGenMultiContent![0].image?.url, equals(dataUrl));
        expect(message.assistantGenMultiContent![0].image?.mimeType, equals('image/png'));
      });

      test('throws on empty choices', () {
        final response = {
          'choices': <dynamic>[],
        };

        expect(
          () => parser.parseCompletionResponse(response),
          throwsA(isA<OpenRouterParseException>()),
        );
      });
    });

    group('parseStreamChunk', () {
      test('parses text delta', () {
        final chunk = {
          'choices': [
            {
              'delta': {
                'content': 'Hello',
              },
              'finish_reason': null,
            },
          ],
        };

        final message = parser.parseStreamChunk(chunk);

        expect(message, isNotNull);
        expect(message!.role, equals(RoleType.assistant));
        expect(message.content, equals('Hello'));
      });

      test('parses base64 image delta', () {
        final base64Image = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

        final chunk = {
          'choices': [
            {
              'delta': {
                'content': base64Image,
              },
            },
          ],
        };

        final message = parser.parseStreamChunk(chunk);

        expect(message, isNotNull);
        expect(message!.assistantGenMultiContent, isNotNull);
        expect(message.assistantGenMultiContent![0].type, equals(ChatMessagePartType.imageUrl));
      });

      test('parses tool call delta', () {
        final chunk = {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'id': 'call_123',
                    'type': 'function',
                    'function': {
                      'name': 'search',
                      'arguments': '{"query": "test"}',
                    },
                    'index': 0,
                  },
                ],
              },
            },
          ],
        };

        final message = parser.parseStreamChunk(chunk);

        expect(message, isNotNull);
        expect(message!.toolCalls, isNotNull);
        expect(message.toolCalls!.length, equals(1));
        expect(message.toolCalls![0].id, equals('call_123'));
      });

      test('returns null for empty delta', () {
        final chunk = {
          'choices': [
            {
              'delta': <String, dynamic>{},
            },
          ],
        };

        final message = parser.parseStreamChunk(chunk);

        expect(message, isNull);
      });

      test('returns null for empty choices', () {
        final chunk = {
          'choices': <dynamic>[],
        };

        final message = parser.parseStreamChunk(chunk);

        expect(message, isNull);
      });
    });

    group('parseDelta', () {
      test('parses delta with role and content', () {
        final delta = {
          'role': 'assistant',
          'content': 'Hello world',
        };

        final message = parser.parseDelta(delta);

        expect(message, isNotNull);
        expect(message!.role, equals(RoleType.assistant));
        expect(message.content, equals('Hello world'));
      });

      test('handles delta without role', () {
        final delta = {
          'content': 'continuation',
        };

        final message = parser.parseDelta(delta);

        expect(message, isNotNull);
        expect(message!.role, equals(RoleType.assistant)); // Default role
        expect(message.content, equals('continuation'));
      });

      test('returns null for empty delta', () {
        final delta = <String, dynamic>{};

        final message = parser.parseDelta(delta);

        expect(message, isNull);
      });

      test('includes finish reason when provided', () {
        final delta = {
          'content': 'final content',
        };

        final message = parser.parseDelta(delta, finishReason: 'stop');

        expect(message, isNotNull);
        expect(message!.responseMeta?.finishReason, equals('stop'));
      });
    });

    group('image content detection', () {
      test('detects data URL as image', () {
        final delta = {
          'content': 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDA...',
        };

        final message = parser.parseDelta(delta);

        expect(message, isNotNull);
        expect(message!.assistantGenMultiContent, isNotNull);
        expect(message.content, isEmpty); // Content is empty when image detected
      });

      test('detects long base64 string as image', () {
        // Create a string that looks like base64 and is long enough
        final longBase64 = 'A' * 150; // 150 chars of valid base64 characters

        final delta = {
          'content': longBase64,
        };

        final message = parser.parseDelta(delta);

        expect(message, isNotNull);
        expect(message!.assistantGenMultiContent, isNotNull);
      });

      test('does not detect short string as image', () {
        final delta = {
          'content': 'Short text',
        };

        final message = parser.parseDelta(delta);

        expect(message, isNotNull);
        expect(message!.assistantGenMultiContent, isNull);
        expect(message.content, equals('Short text'));
      });

      test('does not detect regular text as image', () {
        final delta = {
          'content': 'This is a regular response with more than 100 characters but it contains spaces and special characters so it should not be detected as base64 image data.',
        };

        final message = parser.parseDelta(delta);

        expect(message, isNotNull);
        expect(message!.assistantGenMultiContent, isNull);
      });
    });
  });
}
