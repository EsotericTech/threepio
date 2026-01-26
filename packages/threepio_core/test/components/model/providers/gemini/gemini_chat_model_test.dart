import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/chat_model_options.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_config.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/schema/tool_info.dart';

void main() {
  group('GeminiChatModel', () {
    late GeminiConfig config;

    setUp(() {
      config = const GeminiConfig(apiKey: 'test-api-key');
    });

    group('generate', () {
      test('sends correct request and parses response', () async {
        final mockClient = MockClient((request) async {
          // Verify request
          expect(request.method, equals('POST'));
          expect(
            request.url.toString(),
            contains('/models/gemini-2.5-flash:generateContent'),
          );
          expect(
            request.headers['x-goog-api-key'],
            equals('test-api-key'),
          );
          expect(
            request.headers['Content-Type'],
            startsWith('application/json'),
          );

          // Verify request body
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['contents'], isA<List>());
          expect(body['contents'][0]['role'], equals('user'));

          // Return mock response
          return http.Response(
            jsonEncode({
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
                'promptTokenCount': 5,
                'candidatesTokenCount': 10,
                'totalTokenCount': 15,
              },
            }),
            200,
          );
        });

        final model = GeminiChatModel(
          config: config,
          httpClient: mockClient,
        );

        final messages = [Message.user('Hello!')];
        final response = await model.generate(messages);

        expect(response.content, equals('Hello from Gemini!'));
        expect(response.responseMeta?.finishReason, equals('stop'));
        expect(response.responseMeta?.usage?.promptTokens, equals(5));
      });

      test('sends system instruction separately', () async {
        final mockClient = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;

          // Verify system instruction is extracted
          expect(body['systemInstruction'], isNotNull);
          expect(
            body['systemInstruction']['parts'][0]['text'],
            equals('You are helpful.'),
          );

          // Verify contents don't include system message
          expect(body['contents'].length, equals(1));
          expect(body['contents'][0]['role'], equals('user'));

          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Response'}
                    ],
                  },
                }
              ],
            }),
            200,
          );
        });

        final model = GeminiChatModel(
          config: config,
          httpClient: mockClient,
        );

        final messages = [
          Message.system('You are helpful.'),
          Message.user('Hello!'),
        ];
        await model.generate(messages);
      });

      test('includes generation config options', () async {
        final mockClient = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;

          expect(body['generationConfig'], isNotNull);
          expect(body['generationConfig']['temperature'], equals(0.7));
          expect(body['generationConfig']['maxOutputTokens'], equals(1000));
          expect(body['generationConfig']['topP'], equals(0.9));

          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Response'}
                    ],
                  },
                }
              ],
            }),
            200,
          );
        });

        final model = GeminiChatModel(
          config: config,
          httpClient: mockClient,
        );

        await model.generate(
          [Message.user('Hello!')],
          options: const ChatModelOptions(
            temperature: 0.7,
            maxTokens: 1000,
            topP: 0.9,
          ),
        );
      });

      test('includes tools in request', () async {
        final mockClient = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;

          expect(body['tools'], isNotNull);
          expect(body['tools'][0]['functionDeclarations'], isA<List>());
          expect(
            body['tools'][0]['functionDeclarations'][0]['name'],
            equals('get_weather'),
          );

          return http.Response(
            jsonEncode({
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
            }),
            200,
          );
        });

        final model = GeminiChatModel(
          config: config,
          httpClient: mockClient,
        );

        final response = await model.generate(
          [Message.user('What is the weather in Tokyo?')],
          options: ChatModelOptions(
            tools: [
              ToolInfo(
                function: FunctionInfo(
                  name: 'get_weather',
                  description: 'Get weather',
                  parameters: JSONSchema(
                    type: 'object',
                    properties: {
                      'location': JSONSchemaProperty(type: 'string'),
                    },
                  ),
                ),
              ),
            ],
          ),
        );

        expect(response.toolCalls, isNotNull);
        expect(response.toolCalls![0].function.name, equals('get_weather'));
      });

      test('throws GeminiException on error response', () async {
        final mockClient = MockClient((request) async {
          return http.Response(
            jsonEncode({
              'error': {
                'code': 400,
                'message': 'Invalid request',
                'status': 'INVALID_ARGUMENT',
              },
            }),
            400,
          );
        });

        final model = GeminiChatModel(
          config: config,
          httpClient: mockClient,
        );

        expect(
          () => model.generate([Message.user('Hello!')]),
          throwsA(isA<GeminiException>()),
        );
      });

      test('uses custom model from options', () async {
        final mockClient = MockClient((request) async {
          expect(
            request.url.toString(),
            contains('/models/gemini-2.5-pro:generateContent'),
          );

          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Response'}
                    ],
                  },
                }
              ],
            }),
            200,
          );
        });

        final model = GeminiChatModel(
          config: config,
          httpClient: mockClient,
        );

        await model.generate(
          [Message.user('Hello!')],
          options: const ChatModelOptions(model: 'gemini-2.5-pro'),
        );
      });
    });

    group('withTools', () {
      test('returns new model with bound tools', () async {
        final mockClient = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;

          expect(body['tools'], isNotNull);
          expect(
            body['tools'][0]['functionDeclarations'][0]['name'],
            equals('search'),
          );

          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Response'}
                    ],
                  },
                }
              ],
            }),
            200,
          );
        });

        final baseModel = GeminiChatModel(
          config: config,
          httpClient: mockClient,
        );

        final toolModel = baseModel.withTools([
          ToolInfo(
            function: FunctionInfo(
              name: 'search',
              description: 'Search the web',
            ),
          ),
        ]);

        expect(toolModel, isNot(same(baseModel)));
        await toolModel.generate([Message.user('Search for cats')]);
      });
    });

    group('stream', () {
      test('handles SSE streaming response', () async {
        // Create a stream controller to simulate SSE
        final controller = StreamController<List<int>>();

        final mockClient = MockClient.streaming((request, bodyStream) async {
          expect(
            request.url.toString(),
            contains(':streamGenerateContent?alt=sse'),
          );

          // Schedule the SSE data to be sent
          scheduleMicrotask(() async {
            controller.add(utf8.encode('data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}\n\n'));
            await Future.delayed(Duration.zero);
            controller.add(utf8.encode('data: {"candidates":[{"content":{"parts":[{"text":" World"}]}}]}\n\n'));
            await Future.delayed(Duration.zero);
            controller.add(utf8.encode('data: {"candidates":[{"content":{"parts":[{"text":"!"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2}}\n\n'));
            await Future.delayed(Duration.zero);
            await controller.close();
          });

          return http.StreamedResponse(
            controller.stream,
            200,
          );
        });

        final model = GeminiChatModel(
          config: config,
          httpClient: mockClient,
        );

        final stream = await model.stream([Message.user('Hello!')]);
        final messages = await stream.asStream().toList();

        expect(messages.length, equals(3));
        expect(messages[0].content, equals('Hello'));
        expect(messages[1].content, equals(' World'));
        expect(messages[2].content, equals('!'));
      });
    });

    group('safety settings', () {
      test('includes safety settings in request', () async {
        final mockClient = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;

          expect(body['safetySettings'], isNotNull);
          expect(body['safetySettings'][0]['category'], equals('HARM_CATEGORY_HARASSMENT'));

          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'Response'}
                    ],
                  },
                }
              ],
            }),
            200,
          );
        });

        final model = GeminiChatModel(
          config: config,
          httpClient: mockClient,
        );

        await model.generate(
          [Message.user('Hello!')],
          options: ChatModelOptions(
            extra: {
              'safetySettings': [
                {
                  'category': 'HARM_CATEGORY_HARASSMENT',
                  'threshold': 'BLOCK_MEDIUM_AND_ABOVE',
                },
              ],
            },
          ),
        );
      });
    });
  });

  group('GeminiException', () {
    test('fromResponse creates exception with error details', () {
      final exception = GeminiException.fromResponse(400, {
        'error': {
          'code': 400,
          'message': 'Bad request',
          'status': 'INVALID_ARGUMENT',
        },
      });

      expect(exception.message, equals('Bad request'));
      expect(exception.statusCode, equals(400));
      expect(exception.code, equals(400));
      expect(exception.status, equals('INVALID_ARGUMENT'));
    });

    test('fromResponse handles missing error details', () {
      final exception = GeminiException.fromResponse(500, {});

      expect(exception.message, contains('500'));
      expect(exception.statusCode, equals(500));
    });

    test('toString includes all details', () {
      final exception = GeminiException(
        'Test error',
        statusCode: 400,
        code: 400,
        status: 'INVALID_ARGUMENT',
      );

      final str = exception.toString();

      expect(str, contains('Test error'));
      expect(str, contains('400'));
      expect(str, contains('INVALID_ARGUMENT'));
    });
  });
}
