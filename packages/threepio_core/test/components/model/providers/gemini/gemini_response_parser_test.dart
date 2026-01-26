import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_response_parser.dart';
import 'package:threepio_core/src/schema/message.dart';

void main() {
  group('GeminiResponseParser', () {
    late GeminiResponseParser parser;

    setUp(() {
      parser = const GeminiResponseParser();
    });

    group('parseCompletionResponse', () {
      test('parses successful response', () {
        final response = {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Hello from Gemini!'}
                ],
                'role': 'model',
              },
              'finishReason': 'STOP',
            }
          ],
          'usageMetadata': {
            'promptTokenCount': 10,
            'candidatesTokenCount': 25,
            'totalTokenCount': 35,
          },
        };

        final result = parser.parseCompletionResponse(response);

        expect(result.role, equals(RoleType.assistant));
        expect(result.content, equals('Hello from Gemini!'));
        expect(result.responseMeta?.finishReason, equals('stop'));
        expect(result.responseMeta?.usage?.promptTokens, equals(10));
        expect(result.responseMeta?.usage?.completionTokens, equals(25));
      });

      test('throws on empty candidates', () {
        final response = {
          'candidates': <Map<String, dynamic>>[],
        };

        expect(
          () => parser.parseCompletionResponse(response),
          throwsA(isA<GeminiParseException>()),
        );
      });

      test('throws on blocked content with reason', () {
        final response = {
          'candidates': null,
          'promptFeedback': {
            'blockReason': 'SAFETY',
          },
        };

        expect(
          () => parser.parseCompletionResponse(response),
          throwsA(
            isA<GeminiParseException>().having(
              (e) => e.blockReason,
              'blockReason',
              equals('SAFETY'),
            ),
          ),
        );
      });

      test('parses response with function calls', () {
        final response = {
          'candidates': [
            {
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
            }
          ],
        };

        final result = parser.parseCompletionResponse(response);

        expect(result.toolCalls, isNotNull);
        expect(result.toolCalls!.length, equals(1));
        expect(result.toolCalls![0].function.name, equals('get_weather'));
      });

      test('parses response with multimodal output', () {
        final response = {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Here is an image:'},
                  {
                    'inline_data': {
                      'mime_type': 'image/png',
                      'data': 'base64data',
                    }
                  }
                ],
              },
            }
          ],
        };

        final result = parser.parseCompletionResponse(response);

        expect(result.content, equals('Here is an image:'));
        expect(result.assistantGenMultiContent, isNotNull);
        expect(result.assistantGenMultiContent!.length, equals(1));
      });
    });

    group('parseStreamChunk', () {
      test('parses streaming chunk', () {
        final chunk = {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Streaming...'}
                ],
              },
            }
          ],
        };

        final result = parser.parseStreamChunk(chunk);

        expect(result, isNotNull);
        expect(result!.content, equals('Streaming...'));
      });

      test('returns null for empty candidates', () {
        final chunk = {
          'candidates': <Map<String, dynamic>>[],
        };

        final result = parser.parseStreamChunk(chunk);

        expect(result, isNull);
      });

      test('returns null for null candidates', () {
        final chunk = <String, dynamic>{};

        final result = parser.parseStreamChunk(chunk);

        expect(result, isNull);
      });

      test('parses chunk with usage metadata', () {
        final chunk = {
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Final chunk'}
                ],
              },
              'finishReason': 'STOP',
            }
          ],
          'usageMetadata': {
            'promptTokenCount': 5,
            'candidatesTokenCount': 10,
            'totalTokenCount': 15,
          },
        };

        final result = parser.parseStreamChunk(chunk);

        expect(result, isNotNull);
        expect(result!.responseMeta?.usage?.promptTokens, equals(5));
        expect(result.responseMeta?.usage?.completionTokens, equals(10));
      });
    });

    group('parseError', () {
      test('parses error response', () {
        final response = {
          'error': {
            'code': 400,
            'message': 'Invalid request',
            'status': 'INVALID_ARGUMENT',
          },
        };

        final error = GeminiResponseParser.parseError(response);

        expect(error.message, equals('Invalid request'));
        expect(error.code, equals(400));
        expect(error.status, equals('INVALID_ARGUMENT'));
      });

      test('handles missing error details', () {
        final response = <String, dynamic>{};

        final error = GeminiResponseParser.parseError(response);

        expect(error.message, equals('Unknown error response'));
      });
    });
  });

  group('GeminiParseException', () {
    test('toString includes all fields', () {
      final exception = GeminiParseException(
        'Test error',
        code: 400,
        status: 'INVALID_ARGUMENT',
        blockReason: 'SAFETY',
      );

      final str = exception.toString();

      expect(str, contains('Test error'));
      expect(str, contains('400'));
      expect(str, contains('INVALID_ARGUMENT'));
      expect(str, contains('SAFETY'));
    });

    test('toString handles missing fields', () {
      final exception = GeminiParseException('Simple error');

      final str = exception.toString();

      expect(str, equals('GeminiParseException: Simple error'));
    });
  });
}
