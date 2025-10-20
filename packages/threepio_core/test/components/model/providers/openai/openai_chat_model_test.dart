import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_config.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/schema/tool_info.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

import 'openai_chat_model_test.mocks.dart';

@GenerateMocks([http.Client])
void main() {
  group('OpenAIChatModel', () {
    late MockClient mockClient;
    late OpenAIConfig config;
    late OpenAIChatModel model;

    setUp(() {
      mockClient = MockClient();
      config = OpenAIConfig(apiKey: 'test-key');
      model = OpenAIChatModel(config: config, httpClient: mockClient);
    });

    group('generate', () {
      test('successfully generates response', () async {
        final mockResponse = {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': 'Hello! How can I help you?',
              },
              'finish_reason': 'stop',
            },
          ],
          'usage': {
            'prompt_tokens': 10,
            'completion_tokens': 8,
            'total_tokens': 18,
          },
        };

        when(
          mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          ),
        ).thenAnswer(
          (_) async => http.Response(
            jsonEncode(mockResponse),
            200,
          ),
        );

        final messages = [Message.user('Hello!')];
        final response = await model.generate(messages);

        expect(response.role, equals(RoleType.assistant));
        expect(response.content, equals('Hello! How can I help you?'));
        expect(response.responseMeta, isNotNull);
        expect(response.responseMeta!.finishReason, equals('stop'));
        expect(response.responseMeta!.usage, isNotNull);
        expect(response.responseMeta!.usage!.totalTokens, equals(18));

        // Verify request was made correctly
        final captured = verify(mockClient.post(captureAny,
                headers: captureAnyNamed('headers'),
                body: captureAnyNamed('body')))
            .captured;
        final uri = captured[0] as Uri;
        final headers = captured[1] as Map<String, String>;
        final body = captured[2] as String;

        expect(uri.toString(),
            equals('https://api.openai.com/v1/chat/completions'));
        expect(headers['Authorization'], equals('Bearer test-key'));
        expect(headers['Content-Type'], equals('application/json'));

        final requestBody = jsonDecode(body) as Map<String, dynamic>;
        expect(requestBody['model'], equals('gpt-4o-mini'));
        expect(requestBody['stream'], isFalse);
        expect(requestBody['messages'], hasLength(1));
      });

      test('handles tool calls in response', () async {
        final mockResponse = {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'id': 'call_123',
                    'type': 'function',
                    'function': {
                      'name': 'get_weather',
                      'arguments': '{"location": "NYC"}',
                    },
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        };

        when(
          mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          ),
        ).thenAnswer(
          (_) async => http.Response(
            jsonEncode(mockResponse),
            200,
          ),
        );

        final messages = [Message.user('What is the weather in NYC?')];
        final response = await model.generate(messages);

        expect(response.toolCalls, isNotNull);
        expect(response.toolCalls!.length, equals(1));
        expect(response.toolCalls![0].function.name, equals('get_weather'));
        expect(response.responseMeta!.finishReason, equals('tool_calls'));
      });

      test('throws OpenAIException on API error', () async {
        when(
          mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          ),
        ).thenAnswer(
          (_) async => http.Response(
            jsonEncode({
              'error': {'message': 'Invalid API key'}
            }),
            401,
          ),
        );

        final messages = [Message.user('Hello')];

        expect(
          () => model.generate(messages),
          throwsA(isA<OpenAIException>()),
        );
      });

      test('throws OpenAIException on timeout', () async {
        // Create a model with a very short timeout
        final shortTimeoutConfig = OpenAIConfig(
          apiKey: 'test-key',
          timeout: const Duration(milliseconds: 500),
        );
        final modelWithTimeout = OpenAIChatModel(
          config: shortTimeoutConfig,
          httpClient: mockClient,
        );

        when(
          mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          ),
        ).thenAnswer(
          (_) async => Future.delayed(
            const Duration(seconds: 2),
            () => http.Response('', 200),
          ),
        );

        final messages = [Message.user('Hello')];

        expect(
          () => modelWithTimeout.generate(messages),
          throwsA(isA<OpenAIException>()),
        );
      });

      test('includes tools in request when bound', () async {
        final tool = ToolInfo(
          function: FunctionInfo(
            name: 'get_weather',
            description: 'Get weather',
            parameters: JSONSchema(
              type: 'object',
              properties: {
                'location': JSONSchemaProperty(type: 'string'),
              },
              required: ['location'],
              additionalProperties: false,
            ),
          ),
        );

        final modelWithTools = model.withTools([tool]);

        final mockResponse = {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': 'Sure, I can help with weather.',
              },
              'finish_reason': 'stop',
            },
          ],
        };

        when(
          mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          ),
        ).thenAnswer(
          (_) async => http.Response(
            jsonEncode(mockResponse),
            200,
          ),
        );

        final messages = [Message.user('What is the weather?')];
        await modelWithTools.generate(messages);

        final captured = verify(
          mockClient.post(
            captureAny,
            headers: captureAnyNamed('headers'),
            body: captureAnyNamed('body'),
          ),
        ).captured;

        final body = captured[2] as String;
        final requestBody = jsonDecode(body) as Map<String, dynamic>;

        expect(requestBody.containsKey('tools'), isTrue);
        expect(requestBody['tools'], hasLength(1));
        expect(requestBody['tools'][0]['type'], equals('function'));
        expect(
          requestBody['tools'][0]['function']['name'],
          equals('get_weather'),
        );
      });

      test('includes organization header when configured', () async {
        final configWithOrg = OpenAIConfig(
          apiKey: 'test-key',
          organization: 'org-123',
        );
        final modelWithOrg = OpenAIChatModel(
          config: configWithOrg,
          httpClient: mockClient,
        );

        final mockResponse = {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': 'Response',
              },
              'finish_reason': 'stop',
            },
          ],
        };

        when(
          mockClient.post(
            any,
            headers: anyNamed('headers'),
            body: anyNamed('body'),
          ),
        ).thenAnswer(
          (_) async => http.Response(
            jsonEncode(mockResponse),
            200,
          ),
        );

        await modelWithOrg.generate([Message.user('Test')]);

        final captured = verify(
          mockClient.post(
            captureAny,
            headers: captureAnyNamed('headers'),
            body: captureAnyNamed('body'),
          ),
        ).captured;

        final headers = captured[1] as Map<String, String>;
        expect(headers['OpenAI-Organization'], equals('org-123'));
      });
    });

    group('stream', () {
      test('successfully streams response chunks', () async {
        final chunk1 = {
          'choices': [
            {
              'delta': {'role': 'assistant', 'content': 'Hello'},
              'finish_reason': null,
            },
          ],
        };

        final chunk2 = {
          'choices': [
            {
              'delta': {'content': ' there!'},
              'finish_reason': null,
            },
          ],
        };

        final chunk3 = {
          'choices': [
            {
              'delta': {},
              'finish_reason': 'stop',
            },
          ],
        };

        final sseData = [
          'data: ${jsonEncode(chunk1)}\n',
          'data: ${jsonEncode(chunk2)}\n',
          'data: ${jsonEncode(chunk3)}\n',
          'data: [DONE]\n',
        ].join();

        final mockStreamResponse = http.StreamedResponse(
          Stream.value(utf8.encode(sseData)),
          200,
        );

        when(mockClient.send(any)).thenAnswer((_) async => mockStreamResponse);

        final messages = [Message.user('Hello')];
        final reader = await model.stream(messages);

        final chunks = <String>[];
        try {
          while (true) {
            final message = await reader.recv();
            if (message.content.isNotEmpty) {
              chunks.add(message.content);
            }
          }
        } on StreamEOFException {
          // Expected end
        }

        expect(chunks, hasLength(2));
        expect(chunks[0], equals('Hello'));
        expect(chunks[1], equals(' there!'));

        await reader.close();
      });

      test('handles streaming tool calls', () async {
        final chunk1 = {
          'choices': [
            {
              'delta': {
                'role': 'assistant',
                'tool_calls': [
                  {
                    'id': 'call_123',
                    'index': 0,
                    'type': 'function',
                    'function': {
                      'name': 'get_weather',
                      'arguments': '{"location"',
                    },
                  },
                ],
              },
              'finish_reason': null,
            },
          ],
        };

        final chunk2 = {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {
                      'arguments': ': "NYC"}',
                    },
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        };

        final sseData = [
          'data: ${jsonEncode(chunk1)}\n',
          'data: ${jsonEncode(chunk2)}\n',
          'data: [DONE]\n',
        ].join();

        final mockStreamResponse = http.StreamedResponse(
          Stream.value(utf8.encode(sseData)),
          200,
        );

        when(mockClient.send(any)).thenAnswer((_) async => mockStreamResponse);

        final messages = [Message.user('What is the weather?')];
        final reader = await model.stream(messages);

        final toolCalls = <ToolCall>[];
        try {
          while (true) {
            final message = await reader.recv();
            if (message.toolCalls != null) {
              toolCalls.addAll(message.toolCalls!);
            }
          }
        } on StreamEOFException {
          // Expected end
        }

        expect(toolCalls.isNotEmpty, isTrue);
        await reader.close();
      });

      test('throws OpenAIException on streaming error', () async {
        when(mockClient.send(any)).thenAnswer(
          (_) async => http.StreamedResponse(
            Stream.value(utf8.encode('')),
            500,
          ),
        );

        final messages = [Message.user('Hello')];

        expect(
          () => model.stream(messages),
          throwsA(isA<OpenAIException>()),
        );
      });
    });

    group('withTools', () {
      test('creates new instance with tools bound', () {
        final tool = ToolInfo(
          function: FunctionInfo(
            name: 'test_tool',
            parameters: JSONSchema(
              type: 'object',
              properties: {},
              required: [],
              additionalProperties: false,
            ),
          ),
        );

        final modelWithTools = model.withTools([tool]);

        expect(modelWithTools, isA<OpenAIChatModel>());
        expect(modelWithTools, isNot(same(model)));
        expect((modelWithTools as OpenAIChatModel).tools, hasLength(1));
      });
    });
  });
}
