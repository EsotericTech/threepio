// Ports eino-ext components/model/ollama/chatmodel_test.go: Test_toOllamaMessage
// (14 of its 17 cases). Not ported, because Dart has no deprecated
// `MultiContent`: "test MultiContent compatibility", "test error on http URL in
// MultiContent", "test error on nil ImageURL in MultiContent".
//
// Plus tests written for the port: tool call arguments, thinking and tool names
// in requests, tool definitions (Go: toOllamaTools/schemaToToolProperty),
// response conversion (Go: toEinoMessage) on recorded-shape Ollama responses,
// the `keep_alive` encoding (Go: api.Duration) and endpoint resolution.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/ollama/ollama_config.dart';
import 'package:threepio_core/src/components/model/providers/ollama/ollama_converters.dart';
import 'package:threepio_core/threepio_core.dart';

const _base64Data =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

Matcher _formatError(Object message) => throwsA(
      isA<ThreepioFormatException>().having((e) => e.message, 'message', message),
    );

MessageInputPart _inputImage(MessagePartCommon? common) => MessageInputPart(
      type: ChatMessagePartType.imageUrl,
      image: common == null ? null : MessageInputImage(common: common),
    );

MessageOutputPart _outputImage(MessagePartCommon? common) =>
    MessageOutputPart(type: ChatMessagePartType.imageUrl, image: common);

void main() {
  group('Test_toOllamaMessage', () {
    test('test simple message', () {
      final ollama = OllamaConverters.messageToOllama(
        const Message(role: RoleType.user, content: 'test content'),
      );
      expect(ollama['role'], 'user');
      expect(ollama['content'], 'test content');
      expect(ollama.containsKey('images'), isFalse);
    });

    test('test UserInputMultiContent', () {
      final ollama = OllamaConverters.messageToOllama(
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            const MessageInputPart(type: ChatMessagePartType.text, text: 'hello'),
            _inputImage(const MessagePartCommon(base64Data: _base64Data)),
          ],
        ),
      );
      expect(ollama['role'], 'user');
      expect(ollama['content'], 'hello');
      expect(ollama['images'], [_base64Data]);
    });

    test('test AssistantGenMultiContent', () {
      final ollama = OllamaConverters.messageToOllama(
        Message(
          role: RoleType.assistant,
          assistantGenMultiContent: [
            const MessageOutputPart(type: ChatMessagePartType.text, text: 'hello'),
            _outputImage(const MessagePartCommon(base64Data: _base64Data)),
          ],
        ),
      );
      expect(ollama['role'], 'assistant');
      expect(ollama['content'], 'hello');
      expect(ollama['images'], [_base64Data]);
    });

    test('test AssistantGenMultiContent with correct role', () {
      final ollama = OllamaConverters.messageToOllama(
        const Message(
          role: RoleType.assistant,
          assistantGenMultiContent: [
            MessageOutputPart(type: ChatMessagePartType.text, text: 'world'),
          ],
        ),
      );
      expect(ollama['role'], 'assistant');
      expect(ollama['content'], 'world');
    });

    test('test AssistantGenMultiContent with incorrect role', () {
      expect(
        () => OllamaConverters.messageToOllama(
          const Message(
            role: RoleType.user,
            assistantGenMultiContent: [
              MessageOutputPart(type: ChatMessagePartType.text, text: 'world'),
            ],
          ),
        ),
        _formatError(
          contains('assistant gen multi content only support assistant role'),
        ),
      );
    });

    test('test error on nil image in UserInputMultiContent', () {
      expect(
        () => OllamaConverters.messageToOllama(
          Message(role: RoleType.user, userInputMultiContent: [_inputImage(null)]),
        ),
        _formatError('image is required in UserInputMultiContent, but got nil'),
      );
    });

    test('test error on nil image in AssistantGenMultiContent', () {
      expect(
        () => OllamaConverters.messageToOllama(
          Message(
            role: RoleType.assistant,
            assistantGenMultiContent: [_outputImage(null)],
          ),
        ),
        _formatError(
          'image is required in AssistantGenMultiContent, but got nil',
        ),
      );
    });

    test('test error on URL in UserInputMultiContent', () {
      expect(
        () => OllamaConverters.messageToOllama(
          Message(
            role: RoleType.user,
            userInputMultiContent: [
              _inputImage(
                const MessagePartCommon(url: 'http://example.com/image.png'),
              ),
            ],
          ),
        ),
        _formatError(
          contains('ollama model only supports base64-encoded strings'),
        ),
      );
    });

    test('test error on nil Base64Data in UserInputMultiContent', () {
      expect(
        () => OllamaConverters.messageToOllama(
          Message(
            role: RoleType.user,
            userInputMultiContent: [_inputImage(const MessagePartCommon())],
          ),
        ),
        _formatError(
          'image is required in UserInputMultiContent, but got nil Base64Data',
        ),
      );
    });

    test('test error on URL in AssistantGenMultiContent', () {
      expect(
        () => OllamaConverters.messageToOllama(
          Message(
            role: RoleType.assistant,
            assistantGenMultiContent: [
              _outputImage(
                const MessagePartCommon(url: 'http://example.com/image.png'),
              ),
            ],
          ),
        ),
        _formatError(
          contains('ollama model only supports base64-encoded strings'),
        ),
      );
    });

    test('test error on nil Base64Data in AssistantGenMultiContent', () {
      expect(
        () => OllamaConverters.messageToOllama(
          Message(
            role: RoleType.assistant,
            assistantGenMultiContent: [_outputImage(const MessagePartCommon())],
          ),
        ),
        _formatError(
          'image is required in AssistantGenMultiContent, but got nil '
          'Base64Data',
        ),
      );
    });

    test('test UserInputMultiContent with tool role', () {
      final ollama = OllamaConverters.messageToOllama(
        Message(
          role: RoleType.tool,
          userInputMultiContent: [
            const MessageInputPart(
              type: ChatMessagePartType.text,
              text: 'tool result',
            ),
            _inputImage(const MessagePartCommon(base64Data: _base64Data)),
          ],
        ),
      );
      expect(ollama['role'], 'tool');
      expect(ollama['content'], 'tool result');
      expect(ollama['images'], [_base64Data]);
    });

    test('test UserInputMultiContent with unsupported role', () {
      expect(
        () => OllamaConverters.messageToOllama(
          const Message(
            role: RoleType.system,
            userInputMultiContent: [
              MessageInputPart(type: ChatMessagePartType.text, text: 'hello'),
            ],
          ),
        ),
        _formatError(
          contains('user input multi content only support user&tool role'),
        ),
      );
    });

    test('test error on both UserInputMultiContent and AssistantGenMultiContent',
        () {
      expect(
        () => OllamaConverters.messageToOllama(
          const Message(
            role: RoleType.user,
            userInputMultiContent: [
              MessageInputPart(type: ChatMessagePartType.text, text: 'user'),
            ],
            assistantGenMultiContent: [
              MessageOutputPart(
                type: ChatMessagePartType.text,
                text: 'assistant',
              ),
            ],
          ),
        ),
        _formatError(
          contains(
            'a message cannot contain both UserInputMultiContent and '
            'AssistantGenMultiContent',
          ),
        ),
      );
    });
  });

  group('messageToOllama (port)', () {
    test('a whole message on the wire: thinking, tool calls, no extras', () {
      final ollama = OllamaConverters.messageToOllama(
        const Message(
          role: RoleType.assistant,
          content: 'Let me check.',
          reasoningContent: 'The user wants the weather.',
          toolCalls: [
            ToolCall(
              id: 'call_1',
              index: 0,
              function: FunctionCall(
                name: 'get_current_weather',
                arguments: '{"location":"Paris, FR","days":[1,2]}',
              ),
            ),
          ],
        ),
      );
      expect(ollama, {
        'role': 'assistant',
        'content': 'Let me check.',
        'thinking': 'The user wants the weather.',
        'tool_calls': [
          {
            'function': {
              'name': 'get_current_weather',
              'arguments': {
                'location': 'Paris, FR',
                'days': [1, 2],
              },
            },
          },
        ],
      });
    });

    test('a tool result carries its tool name', () {
      final ollama = OllamaConverters.messageToOllama(
        Message.tool(content: '22 degrees', toolCallId: '', toolName: 'weather'),
      );
      expect(ollama, {
        'role': 'tool',
        'content': '22 degrees',
        'tool_name': 'weather',
      });
    });

    test('the multimodal parts replace the content, as in Go', () {
      final ollama = OllamaConverters.messageToOllama(
        const Message(
          role: RoleType.user,
          content: 'ignored',
          userInputMultiContent: [
            MessageInputPart(type: ChatMessagePartType.text, text: 'a'),
            MessageInputPart(type: ChatMessagePartType.text, text: 'b'),
          ],
        ),
      );
      expect(ollama['content'], 'ab');
    });

    test('a part type Ollama cannot take is named by its wire value', () {
      expect(
        () => OllamaConverters.messageToOllama(
          Message(
            role: RoleType.user,
            userInputMultiContent: [
              MessageInputPart.audio(base64Data: 'AAAA', mimeType: 'audio/wav'),
            ],
          ),
        ),
        _formatError(
          'unsupported content type in UserInputMultiContent: audio_url',
        ),
      );
    });

    test('tool call arguments that are not JSON fail', () {
      expect(
        () => OllamaConverters.messageToOllama(
          const Message(
            role: RoleType.assistant,
            toolCalls: [
              ToolCall(
                id: '',
                function: FunctionCall(name: 'f', arguments: '{oops'),
              ),
            ],
          ),
        ),
        _formatError(startsWith('error parsing JSON to object')),
      );
    });

    test('tool call arguments that are not an object fail', () {
      expect(
        () => OllamaConverters.messageToOllama(
          const Message(
            role: RoleType.assistant,
            toolCalls: [
              ToolCall(id: '', function: FunctionCall(name: 'f', arguments: '[1]')),
            ],
          ),
        ),
        _formatError(startsWith('error parsing JSON to object')),
      );
    });

    test('null arguments are sent as null, as Go sends a nil map', () {
      final ollama = OllamaConverters.messageToOllama(
        const Message(
          role: RoleType.assistant,
          toolCalls: [
            ToolCall(id: '', function: FunctionCall(name: 'f', arguments: 'null')),
          ],
        ),
      );
      expect(ollama['tool_calls'], [
        {
          'function': {'name': 'f', 'arguments': null},
        },
      ]);
    });

    test('messagesToOllama keeps the order', () {
      final wire = OllamaConverters.messagesToOllama([
        Message.system('be brief'),
        Message.user('hi'),
      ]);
      expect([for (final m in wire) m['role']], ['system', 'user']);
    });
  });

  group('toolsToOllama', () {
    test('parameters become an object of tool properties', () {
      final tool = ToolInfo.fromParams(
        name: 'get_current_weather',
        desc: 'Get the current weather in a given location',
        params: const {
          'location': ParameterInfo(
            type: DataType.string,
            desc: 'The city and state, e.g. San Francisco, CA',
            required: true,
          ),
          'unit': ParameterInfo(
            type: DataType.string,
            enumValues: ['celsius', 'fahrenheit'],
            required: true,
          ),
          'days': ParameterInfo(
            type: DataType.array,
            elemInfo: ParameterInfo(type: DataType.integer, desc: 'a day'),
          ),
        },
      );
      expect(OllamaConverters.toolsToOllama([tool]), [
        {
          'type': 'function',
          'function': {
            'name': 'get_current_weather',
            'description': 'Get the current weather in a given location',
            'parameters': {
              'type': 'object',
              'required': ['location', 'unit'],
              'properties': {
                'days': {
                  'type': 'array',
                  'items': {'type': 'integer', 'description': 'a day'},
                  'description': '',
                },
                'location': {
                  'type': 'string',
                  'description': 'The city and state, e.g. San Francisco, CA',
                },
                'unit': {
                  'type': 'string',
                  'description': '',
                  'enum': ['celsius', 'fahrenheit'],
                },
              },
            },
          },
        },
      ]);
    });

    test('the fields of a nested object are not sent, as in Go', () {
      final tool = ToolInfo.fromParams(
        name: 'create',
        params: const {
          'item': ParameterInfo(
            type: DataType.object,
            desc: 'the item',
            subParams: {'name': ParameterInfo(type: DataType.string)},
          ),
        },
      );
      final parameters = (OllamaConverters.toolToOllama(tool)['function']!
          as Map)['parameters'] as Map;
      expect(parameters['properties'], {
        'item': {'type': 'object', 'description': 'the item'},
      });
      // No required parameter: Go sends its nil slice as null.
      expect(parameters.containsKey('required'), isTrue);
      expect(parameters['required'], isNull);
    });

    test('a tool without parameters gets an empty object, required null as in Go',
        () {
      final tool = ToolInfo.function(name: 'now');
      expect(OllamaConverters.toolToOllama(tool), {
        'type': 'function',
        'function': {
          'name': 'now',
          'description': '',
          'parameters': {
            'type': 'object',
            'required': null,
            'properties': <String, Object?>{},
          },
        },
      });
    });

    test('a property without a type sends null, as Go does', () {
      expect(
        OllamaConverters.toolPropertyOf(const JSONSchemaProperty(type: '')),
        {'type': null, 'description': ''},
      );
    });
  });

  group('responseToMessage', () {
    // Recorded shape of a non-streaming `/api/chat` answer.
    final answer = <String, Object?>{
      'model': 'llama3.2',
      'created_at': '2024-07-22T20:33:28.123648Z',
      'message': {'role': 'assistant', 'content': 'Hello! How are you today?'},
      'done_reason': 'stop',
      'done': true,
      'total_duration': 5191566416,
      'load_duration': 2154458,
      'prompt_eval_count': 26,
      'prompt_eval_duration': 383809000,
      'eval_count': 298,
      'eval_duration': 4799921000,
    };

    test('content, finish reason, usage and metrics', () {
      final message = OllamaConverters.responseToMessage(answer);
      expect(message.role, RoleType.assistant);
      expect(message.content, 'Hello! How are you today?');
      expect(message.reasoningContent, isNull);
      expect(message.toolCalls, isNull);
      expect(message.responseMeta!.finishReason, 'stop');
      expect(
        message.responseMeta!.usage,
        const TokenUsage(promptTokens: 26, completionTokens: 298, totalTokens: 324),
      );
      expect(
        message.ollamaMetrics,
        const OllamaMetrics(
          totalDurationNanos: 5191566416,
          loadDurationNanos: 2154458,
          promptEvalCount: 26,
          promptEvalDurationNanos: 383809000,
          evalCount: 298,
          evalDurationNanos: 4799921000,
        ),
      );
      // The numbers Ollama sent, unchanged (Go passes `resp.Metrics` as is).
      expect(message.extra, {
        ollamaMetricsExtraKey: {
          'total_duration': 5191566416,
          'load_duration': 2154458,
          'prompt_eval_count': 26,
          'prompt_eval_duration': 383809000,
          'eval_count': 298,
          'eval_duration': 4799921000,
        },
      });
    });

    test('a chunk that is not the last has zero usage and no metrics', () {
      final message = OllamaConverters.responseToMessage({
        'model': 'llama3.2',
        'created_at': '2023-08-04T08:52:19.385406455-07:00',
        'message': {'role': 'assistant', 'content': 'The'},
        'done': false,
      });
      expect(message.content, 'The');
      expect(message.responseMeta!.finishReason, isNull);
      expect(
        message.responseMeta!.usage,
        const TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0),
      );
      expect(message.extra, isNull);
    });

    test('thinking is the reasoning content', () {
      final message = OllamaConverters.responseToMessage({
        'model': 'qwen3',
        'message': {'role': 'assistant', 'content': '', 'thinking': 'Okay, '},
        'done': false,
      });
      expect(message.reasoningContent, 'Okay, ');
    });

    test('tool calls carry their arguments as a JSON string', () {
      final message = OllamaConverters.responseToMessage({
        'model': 'llama3.2',
        'created_at': '2024-07-22T20:33:28.123648Z',
        'message': {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'function': {
                'name': 'get_current_weather',
                'arguments': {'format': 'celsius', 'location': 'Paris, FR'},
              },
            },
            {
              'function': {'name': 'now', 'arguments': <String, Object?>{}},
            },
          ],
        },
        'done_reason': 'stop',
        'done': true,
      });
      final calls = message.toolCalls!;
      expect(calls, hasLength(2));
      expect(calls[0].id, '');
      expect(calls[0].index, isNull);
      expect(calls[0].type, 'function');
      expect(calls[0].function.name, 'get_current_weather');
      expect(
        jsonDecode(calls[0].function.arguments),
        {'format': 'celsius', 'location': 'Paris, FR'},
      );
      expect(calls[1].function.arguments, '{}');
    });

    test('a tool call id sent by a newer Ollama is kept', () {
      final message = OllamaConverters.responseToMessage({
        'message': {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_k3j',
              'function': {'index': 0, 'name': 'now', 'arguments': {}},
            },
          ],
        },
        'done': false,
      });
      expect(message.toolCalls!.single.id, 'call_k3j');
    });

    test('the role is lower-cased; a missing message is an empty answer', () {
      expect(
        OllamaConverters.responseToMessage({
          'message': {'role': 'TOOL', 'content': 'x'},
        }).role,
        RoleType.tool,
      );
      expect(
        OllamaConverters.responseToMessage({
          'message': {'role': 'User', 'content': 'x'},
        }).role,
        RoleType.user,
      );
      final empty = OllamaConverters.responseToMessage({'done': false});
      expect(empty.role, RoleType.assistant);
      expect(empty.content, '');
    });
  });

  group('errorOf', () {
    test('reads the error of a line', () {
      expect(OllamaConverters.errorOf({'error': 'boom'}), 'boom');
      expect(OllamaConverters.errorOf({'error': ''}), isNull);
      expect(OllamaConverters.errorOf({'done': true}), isNull);
      expect(
        OllamaConverters.errorOf({
          'error': {'message': 'from a proxy'},
        }),
        'from a proxy',
      );
    });
  });

  group('goDurationString', () {
    final micro = String.fromCharCode(0xB5);
    final cases = <Duration, String>{
      Duration.zero: '0s',
      const Duration(microseconds: 1): '1${micro}s',
      const Duration(microseconds: 999): '999${micro}s',
      const Duration(milliseconds: 1): '1ms',
      const Duration(microseconds: 1500): '1.5ms',
      const Duration(milliseconds: 250): '250ms',
      const Duration(seconds: 1): '1s',
      const Duration(milliseconds: 1500): '1.5s',
      const Duration(microseconds: 1000001): '1.000001s',
      const Duration(seconds: 90): '1m30s',
      const Duration(minutes: 5): '5m0s',
      const Duration(hours: 1): '1h0m0s',
      const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500):
          '1h2m3.5s',
      const Duration(hours: 26): '26h0m0s',
      const Duration(seconds: -90): '-1m30s',
    };
    for (final MapEntry(key: duration, value: text) in cases.entries) {
      test('$duration is $text', () {
        expect(OllamaConverters.goDurationString(duration), text);
      });
    }
  });

  group('keepAliveToJson', () {
    test('a negative duration is -1, as in Go', () {
      expect(OllamaConverters.keepAliveToJson(const Duration(seconds: -1)), -1);
    });

    test('other durations are Go duration strings', () {
      expect(OllamaConverters.keepAliveToJson(const Duration(minutes: 10)), '10m0s');
      expect(OllamaConverters.keepAliveToJson(Duration.zero), '0s');
    });
  });

  group('endpoint', () {
    test('joins the API path to the base URL, keeping its path', () {
      expect(
        OllamaConverters.endpoint('http://localhost:11434', '/api/chat'),
        Uri.parse('http://localhost:11434/api/chat'),
      );
      expect(
        OllamaConverters.endpoint('https://gpu.example.com/ollama/', '/api/embed'),
        Uri.parse('https://gpu.example.com/ollama/api/embed'),
      );
    });

    test('an empty base URL is the local server', () {
      expect(
        OllamaConverters.endpoint('', '/api/chat'),
        Uri.parse('http://localhost:11434/api/chat'),
      );
    });

    test('an invalid base URL is an argument error', () {
      expect(
        () => OllamaConverters.endpoint('http://example.com:port', '/api/chat'),
        throwsArgumentError,
      );
      expect(
        () => OllamaConverters.endpoint('localhost', '/api/chat'),
        throwsArgumentError,
      );
    });
  });
}
