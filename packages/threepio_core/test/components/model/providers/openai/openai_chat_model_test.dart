import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_config.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/schema/tool_info.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

void main() {
  group('OpenAIChatModel', () {
    /// Requests the fake client received, in order.
    late List<http.Request> requests;

    /// What the fake client answers with; set by each test.
    late Future<http.Response> Function(http.Request request) respond;

    late MockClient mockClient;
    late OpenAIConfig config;
    late OpenAIChatModel model;

    /// Answers every request with [body] as JSON.
    void respondWith(Object body, {int statusCode = 200}) {
      respond = (_) async => http.Response(jsonEncode(body), statusCode);
    }

    /// Answers every request with [sseData] as an event stream.
    void respondWithStream(String sseData, {int statusCode = 200}) {
      respond = (_) async => http.Response(sseData, statusCode);
    }

    setUp(() {
      requests = [];
      mockClient = MockClient((request) {
        requests.add(request);
        return respond(request);
      });
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

        respondWith(mockResponse);

        final messages = [Message.user('Hello!')];
        final response = await model.generate(messages);

        expect(response.role, equals(RoleType.assistant));
        expect(response.content, equals('Hello! How can I help you?'));
        expect(response.responseMeta, isNotNull);
        expect(response.responseMeta!.finishReason, equals('stop'));
        expect(response.responseMeta!.usage, isNotNull);
        expect(response.responseMeta!.usage!.totalTokens, equals(18));

        // Verify request was made correctly
        final request = requests.single;
        final headers = request.headers;
        final body = request.body;

        expect(
          request.url.toString(),
          equals('https://api.openai.com/v1/chat/completions'),
        );
        expect(headers['Authorization'], equals('Bearer test-key'));
        expect(headers['Content-Type'], startsWith('application/json'));

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

        respondWith(mockResponse);

        final messages = [Message.user('What is the weather in NYC?')];
        final response = await model.generate(messages);

        expect(response.toolCalls, isNotNull);
        expect(response.toolCalls!.length, equals(1));
        expect(response.toolCalls![0].function.name, equals('get_weather'));
        expect(response.responseMeta!.finishReason, equals('tool_calls'));
      });

      test('throws OpenAIException on API error', () async {
        respondWith(
          {
            'error': {'message': 'Invalid API key'},
          },
          statusCode: 401,
        );

        final messages = [Message.user('Hello')];

        expect(
          () => model.generate(messages),
          throwsA(isA<OpenAIException>()),
        );
      });

      test('throws OpenAIException on timeout', () async {
        final shortTimeoutConfig = OpenAIConfig(
          apiKey: 'test-key',
          timeout: const Duration(milliseconds: 20),
        );
        final modelWithTimeout = OpenAIChatModel(
          config: shortTimeoutConfig,
          httpClient: mockClient,
        );

        // The response never arrives.
        respond = (_) => Completer<http.Response>().future;

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

        respondWith(mockResponse);

        final messages = [Message.user('What is the weather?')];
        await modelWithTools.generate(messages);

        final requestBody =
            jsonDecode(requests.single.body) as Map<String, dynamic>;

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

        respondWith(mockResponse);

        await modelWithOrg.generate([Message.user('Test')]);

        expect(
          requests.single.headers['OpenAI-Organization'],
          equals('org-123'),
        );
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

        respondWithStream(sseData);

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

        respondWithStream(sseData);

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
        respondWithStream('', statusCode: 500);

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
