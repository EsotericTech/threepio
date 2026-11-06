// Port of eino-ext components/model/qwen/chatmodel_test.go (TestChatModel,
// TestValidateToolOptions) and components/model/deepseek: extra_test.go
// (TestPrefix, TestReasoningContent → `Message.reasoningContent`) and
// deepseek_test.go (TestThinkingConfig, TestPopulateToolChoice and the
// OpenAI-compatible parts of TestChatModelGenerate, TestChatModelStream and
// TestToDeepSeekMessage), against `OpenAICompatibleChatModel` with the
// `OpenAICompatibleConfig.qwen` / `.deepSeek` presets, through a fake HTTP
// server instead of mockey on the vendor SDKs. Plus tests written for the
// port: the presets (type names, URLs, defaults, `.ark`), the DeepSeek prefix
// on the wire, callbacks, cancellation, `withTools` and `dispose`.
//
// Not ported: TestNewChatModel and the nil-config cases (Dart configs are
// non-nullable and `model` has a default), TestPanicErr, TestWithTools /
// TestBindToolsError (Go SDK binding), TestLogProbs / TestExtractLogProbs /
// TestTokenUsageConversions / TestToToolParam / TestToMessageRole /
// TestToMessageToolCalls / TestResolveStreamResponse (deepseek-go SDK
// conversions; the OpenAI-compatible equivalents are in
// eino_acl_openai_test.dart), TestConcatTextParts and the DeepSeek-only
// parts of TestToDeepSeekMessage (joining text parts with "\n\n", the
// unknown-role and deprecated MultiContent errors, the zero tool-call index,
// the `reasoning_content` fallback from `extra`: the preset speaks the
// OpenAI wire format and keeps the reasoning in `reasoningContent` only),
// option_test.go (deepseek-go request options).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/openai_compatible/presets.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_options.dart';
import 'package:threepio_core/threepio_core.dart';

typedef _Sent = ({Uri url, Map<String, String> headers, Map<String, Object?> body});

final class _FakeApi {
  final sent = <_Sent>[];

  Map<String, Object?> get body => sent.last.body;

  http.Client json(Object response, {int status = 200}) =>
      MockClient((request) async {
        sent.add((
          url: request.url,
          headers: request.headers,
          body: jsonDecode(request.body) as Map<String, Object?>,
        ));
        return http.Response(
          response is String ? response : jsonEncode(response),
          status,
          headers: const {'content-type': 'application/json'},
        );
      });

  http.Client sse(List<String> chunks, {int status = 200}) =>
      MockClient.streaming((request, bytes) async {
        sent.add((
          url: request.url,
          headers: request.headers,
          body: jsonDecode(await bytes.bytesToString()) as Map<String, Object?>,
        ));
        return http.StreamedResponse(
          Stream.fromIterable([for (final c in chunks) utf8.encode(c)]),
          status,
        );
      });
}

String _data(Object chunk) => 'data: ${jsonEncode(chunk)}\n\n';

const _done = 'data: [DONE]\n\n';

Map<String, Object?> _completion(Map<String, Object?> message, {Map<String, Object?>? usage}) => {
      'id': 'cmpl-1',
      'object': 'chat.completion',
      'choices': [
        {'index': 0, 'message': message, 'finish_reason': 'stop'},
      ],
      if (usage != null) 'usage': usage,
    };

final _hello = _completion({'role': 'assistant', 'content': 'hello'});

OpenAICompatibleConfig _deepSeek({DeepSeekThinking? thinking, String model = 'deepseek-chat'}) =>
    OpenAICompatibleConfig.deepSeek(apiKey: 'test-key', model: model, thinking: thinking);

final _qwen = OpenAICompatibleConfig.qwen(
  apiKey: 'qwe',
  model: 'zxc',
  baseUrl: 'https://qwen.example.com/v1',
);

ToolInfo _tool(String name) => ToolInfo.fromJsonSchema(
      name: name,
      schema: const JSONSchema(
        properties: {'field1': JSONSchemaProperty(type: 'string')},
      ),
    );

/// Records the start and end of a call.
final class _Recorder extends ComponentCallbackHandler {
  final infos = <RunInfo>[];
  final timings = <String>[];

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    infos.add(info);
    timings.add('start');
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    timings.add('end');
    return ctx;
  }
}

void main() {
  group('presets', () {
    test('each preset reports its Go type name', () {
      expect(
        {for (final p in OpenAICompatiblePreset.values) p: p.typeName},
        {
          OpenAICompatiblePreset.generic: 'OpenAICompatible',
          OpenAICompatiblePreset.deepSeek: 'DeepSeek',
          OpenAICompatiblePreset.qwen: 'Qwen',
          OpenAICompatiblePreset.ark: 'Ark',
        },
      );
      for (final (config, name) in [
        (_deepSeek(), 'DeepSeek'),
        (_qwen, 'Qwen'),
        (OpenAICompatibleConfig.ark(apiKey: 'k', model: 'ep-1'), 'Ark'),
        (
          const OpenAICompatibleConfig(apiKey: 'k', baseUrl: 'http://h', model: 'm'),
          'OpenAICompatible',
        ),
      ]) {
        final model = OpenAICompatibleChatModel(config: config);
        expect(model.componentTypeName, name);
        expect(model.isCallbacksEnabled, isTrue);
      }
    });

    test('DeepSeek defaults', () async {
      final config = OpenAICompatibleConfig.deepSeek(apiKey: 'test-key');
      expect(config.baseUrl, 'https://api.deepseek.com');
      expect(config.model, 'deepseek-chat');
      expect(config.path, '/chat/completions');
      expect(config.preset, OpenAICompatiblePreset.deepSeek);

      final api = _FakeApi();
      await OpenAICompatibleChatModel(config: config, httpClient: api.json(_hello))
          .generate([Message.user('hi')]);
      expect(api.sent.single.url.toString(), 'https://api.deepseek.com/chat/completions');
      expect(api.sent.single.headers['Authorization'], 'Bearer test-key');
      expect(api.body['model'], 'deepseek-chat');
    });

    test('Qwen defaults', () {
      final config = OpenAICompatibleConfig.qwen(apiKey: 'k', model: 'qwen-plus');
      expect(config.baseUrl, 'https://dashscope.aliyuncs.com/compatible-mode/v1');
      expect(config.preset, OpenAICompatiblePreset.qwen);
      expect(config.extraFields, isEmpty);
    });

    test('Ark defaults and its reasoning effort', () async {
      final config = OpenAICompatibleConfig.ark(
        apiKey: 'k',
        model: 'ep-20250101',
        reasoningEffort: ReasoningEffort.minimal,
      );
      expect(config.baseUrl, 'https://ark.cn-beijing.volces.com/api/v3');
      final api = _FakeApi();
      await OpenAICompatibleChatModel(config: config, httpClient: api.json(_hello))
          .generate([Message.user('hi')]);
      expect(
        api.sent.single.url.toString(),
        'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
      );
      expect(api.body['reasoning_effort'], 'minimal');
      expect(api.body['model'], 'ep-20250101');
    });

    test('base URL and path are joined with one slash', () async {
      final api = _FakeApi();
      await OpenAICompatibleChatModel(
        config: const OpenAICompatibleConfig(
          apiKey: 'k',
          baseUrl: 'https://custom.api.com/',
          model: 'm',
          path: 'v1/chat',
        ),
        httpClient: api.json(_hello),
      ).generate([Message.user('hi')]);
      expect(api.sent.single.url.toString(), 'https://custom.api.com/v1/chat');
    });

    test('the config settings are sent; per-call headers replace the config '
        'headers', () async {
      final api = _FakeApi();
      final model = OpenAICompatibleChatModel(
        config: OpenAICompatibleConfig.qwen(
          apiKey: 'k',
          model: 'qwen-plus',
          temperature: 0.2,
          topP: 0.9,
          stop: ['END'],
          maxCompletionTokens: 64,
          presencePenalty: 0.1,
          frequencyPenalty: 0.2,
          seed: 7,
          logitBias: {'1': 1},
          user: 'u',
          responseFormat: const ResponseFormat.jsonObject(),
          customHeaders: {'X-DashScope-SSE': 'disable'},
        ),
        httpClient: api.json(_hello),
      );
      await model.generate([Message.user('hi')]);
      expect(api.body, containsPair('temperature', 0.2));
      expect(api.body, containsPair('top_p', 0.9));
      expect(api.body, containsPair('stop', ['END']));
      expect(api.body, containsPair('max_completion_tokens', 64));
      expect(api.body, containsPair('presence_penalty', 0.1));
      expect(api.body, containsPair('frequency_penalty', 0.2));
      expect(api.body, containsPair('seed', 7));
      expect(api.body, containsPair('logit_bias', {'1': 1}));
      expect(api.body, containsPair('user', 'u'));
      expect(api.body, containsPair('response_format', {'type': 'json_object'}));
      expect(api.sent.last.headers['X-DashScope-SSE'], 'disable');

      await model.generate(
        [Message.user('hi')],
        options: const OpenAIRequestOptions(extraHeaders: {'X-Call': '1'}).toOptions(),
      );
      expect(api.sent.last.headers['X-Call'], '1');
      expect(api.sent.last.headers.containsKey('X-DashScope-SSE'), isFalse);
    });
  });

  group('Qwen thinking', () {
    test('enableThinking is sent in both forms', () async {
      final api = _FakeApi();
      await OpenAICompatibleChatModel(
        config: OpenAICompatibleConfig.qwen(apiKey: 'k', model: 'qwen3', enableThinking: true),
        httpClient: api.json(_hello),
      ).generate([Message.user('hi')]);
      expect(api.body['chat_template_kwargs'], {'enable_thinking': true});
      expect(api.body['enable_thinking'], isTrue);
    });

    test('qwenThinkingFields switch it for one call (Go WithEnableThinking)',
        () async {
      expect(OpenAICompatibleConfig.qwenThinkingFields(false), {
        'chat_template_kwargs': {'enable_thinking': false},
        'enable_thinking': false,
      });
      final api = _FakeApi();
      await OpenAICompatibleChatModel(
        config: OpenAICompatibleConfig.qwen(apiKey: 'k', model: 'qwen3', enableThinking: true),
        httpClient: api.json(_hello),
      ).generate(
        [Message.user('hi')],
        options: OpenAIRequestOptions(
          extraFields: OpenAICompatibleConfig.qwenThinkingFields(false),
        ).toOptions(),
      );
      expect(api.body['enable_thinking'], isFalse);
      expect(api.body['chat_template_kwargs'], {'enable_thinking': false});
    });

    test('Qwen-Omni audio output settings are sent', () async {
      final api = _FakeApi();
      await OpenAICompatibleChatModel(
        config: OpenAICompatibleConfig.qwen(
          apiKey: 'k',
          model: 'qwen-omni-turbo',
          modalities: const [OpenAIModality.text, OpenAIModality.audio],
          audio: const OpenAIAudioConfig(format: 'wav', voice: 'Cherry'),
        ),
        httpClient: api.json(_hello),
      ).generate([Message.user('hi')]);
      expect(api.body['modalities'], ['text', 'audio']);
      expect(api.body['audio'], {'format': 'wav', 'voice': 'Cherry'});
    });
  });

  group('TestChatModel (qwen)', () {
    test('test Generate', () async {
      final model = OpenAICompatibleChatModel(
        config: _qwen,
        httpClient: _FakeApi().json('{"error":{"message":"mock err"}}', status: 500),
      );
      await expectLater(
        model.generate([Message.user('hello')]),
        throwsA(isA<OpenAIException>().having((e) => e.isRetryable, 'isRetryable', isTrue)),
      );
    });

    test('test Stream', () async {
      final model = OpenAICompatibleChatModel(
        config: _qwen,
        httpClient: _FakeApi().sse(['{"error":{"message":"mock err"}}'], status: 500),
      );
      await expectLater(
        model.stream([Message.user('hello')]),
        throwsA(isA<OpenAIException>()),
      );
    });
  });

  group('TestValidateToolOptions (qwen)', () {
    Future<Map<String, Object?>> send(ChatModelOptions options) async {
      final api = _FakeApi();
      await OpenAICompatibleChatModel(config: _qwen, httpClient: api.json(_hello))
          .generate([Message.user('x')], options: options);
      return api.body;
    }

    test('no options', () async {
      expect((await send(const ChatModelOptions())).containsKey('tool_choice'), isFalse);
    });

    test("tool_choice 'allowed' with allowed_tools", () async {
      await expectLater(
        send(ChatModelOptions(
          tools: [_tool('tool1')],
          toolChoice: ToolChoice.allowed,
          allowedToolNames: const ['tool1'],
        )),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
            "tool_choice 'allowed' is not supported when allowed tool names are present")),
      );
    });

    test("tool_choice 'allowed' without allowed_tools", () async {
      final body = await send(ChatModelOptions(
        tools: [_tool('tool1')],
        toolChoice: ToolChoice.allowed,
      ));
      expect(body['tool_choice'], 'auto');
    });

    test("tool_choice 'forced' with more than one allowed_tool", () async {
      await expectLater(
        send(ChatModelOptions(
          tools: [_tool('tool1'), _tool('tool2')],
          toolChoice: ToolChoice.forced,
          allowedToolNames: const ['tool1', 'tool2'],
        )),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
            "only one allowed tool name can be configured for tool_choice 'forced'")),
      );
    });

    test("tool_choice 'forced' with one allowed_tool", () async {
      final body = await send(ChatModelOptions(
        tools: [_tool('tool1')],
        toolChoice: ToolChoice.forced,
      ));
      expect(body['tool_choice'], {
        'type': 'function',
        'function': {'name': 'tool1'},
      });
    });

    test("tool_choice 'forced' without allowed_tools", () async {
      // Go's validation passes; the request then fails in the acl client
      // because no tool is given, as in Go's Generate.
      await expectLater(
        send(const ChatModelOptions(toolChoice: ToolChoice.forced)),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'tool_choice is forced but no tools are provided')),
      );
    });

    test('tool_choice not set', () async {
      final body = await send(ChatModelOptions(tools: [_tool('tool1')]));
      expect(body.containsKey('tool_choice'), isFalse);
      expect(body['tools'] as List, hasLength(1));
    });
  });

  group('TestThinkingConfig (deepseek)', () {
    test('with thinking config', () async {
      final api = _FakeApi();
      await OpenAICompatibleChatModel(
        config: _deepSeek(thinking: DeepSeekThinking.enabled, model: 'deepseek-reasoner'),
        httpClient: api.json(_hello),
      ).generate([Message.user('hello')]);
      expect(api.body['thinking'], {'type': 'enabled'});
    });

    test('without thinking config', () async {
      final api = _FakeApi();
      await OpenAICompatibleChatModel(config: _deepSeek(), httpClient: api.json(_hello))
          .generate([Message.user('hello')]);
      expect(api.body.containsKey('thinking'), isFalse);
    });

    test('DeepSeekThinking wire form', () {
      expect(DeepSeekThinking.disabled.toJson(), {'type': 'disabled'});
    });
  });

  group('TestPopulateToolChoice (deepseek)', () {
    Future<Map<String, Object?>> send(ChatModelOptions options) async {
      final api = _FakeApi();
      await OpenAICompatibleChatModel(config: _deepSeek(), httpClient: api.json(_hello))
          .generate([Message.user('x')], options: options);
      return api.body;
    }

    final tools = [_tool('tool1'), _tool('tool2')];

    test('nil tool choice', () async {
      expect((await send(ChatModelOptions(tools: tools))).containsKey('tool_choice'),
          isFalse);
    });

    test('tool choice forbidden', () async {
      expect(
        (await send(const ChatModelOptions(toolChoice: ToolChoice.forbidden)))['tool_choice'],
        'none',
      );
    });

    test('tool choice allowed', () async {
      expect(
        (await send(const ChatModelOptions(toolChoice: ToolChoice.allowed)))['tool_choice'],
        'auto',
      );
    });

    test('tool choice forced with no tools', () async {
      await expectLater(
        send(const ChatModelOptions(toolChoice: ToolChoice.forced)),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
            'tool choice is forced but tool is not provided')),
      );
    });

    test('tool choice forced with multiple allowed tool names', () async {
      await expectLater(
        send(ChatModelOptions(
          tools: tools,
          toolChoice: ToolChoice.forced,
          allowedToolNames: const ['tool1', 'tool2'],
        )),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
            contains('only one allowed tool name can be configured'))),
      );
    });

    test('tool choice forced with allowed tool name not in tools list',
        () async {
      await expectLater(
        send(ChatModelOptions(
          tools: tools,
          toolChoice: ToolChoice.forced,
          allowedToolNames: const ['tool3'],
        )),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message',
            "allowed tool name 'tool3' not found in tools list")),
      );
    });

    test('tool choice allowed ignores allowed tool names (Go sends auto)',
        () async {
      expect(
        (await send(ChatModelOptions(
          tools: tools,
          toolChoice: ToolChoice.allowed,
          allowedToolNames: const ['tool3'],
        )))['tool_choice'],
        'auto',
      );
    });

    test('tool choice forced with one allowed tool name', () async {
      final body = await send(ChatModelOptions(
        tools: tools,
        toolChoice: ToolChoice.forced,
        allowedToolNames: const ['tool1'],
      ));
      expect(body['tool_choice'], {
        'type': 'function',
        'function': {'name': 'tool1'},
      });
      expect(body['tools'] as List, hasLength(2));
    });

    test('tool choice forced with one tool', () async {
      final body = await send(ChatModelOptions(
        tools: [_tool('tool1')],
        toolChoice: ToolChoice.forced,
      ));
      expect(body['tool_choice'], {
        'type': 'function',
        'function': {'name': 'tool1'},
      });
    });

    test('tool choice forced with multiple tools and no allowed tool names',
        () async {
      final body = await send(ChatModelOptions(tools: tools, toolChoice: ToolChoice.forced));
      expect(body['tool_choice'], 'required');
    });
  });

  group('TestChatModelGenerate (deepseek)', () {
    test('parses content, reasoning, tool calls and usage', () async {
      final api = _FakeApi();
      final model = OpenAICompatibleChatModel(
        config: _deepSeek(),
        httpClient: api.json({
          'object': 'chat.completion',
          'choices': [
            {
              'index': 0,
              'message': {
                'role': 'assistant',
                'content': 'hello world',
                'reasoning_content': 'reasoning content',
                'tool_calls': [
                  {
                    'index': 1,
                    'id': 'id',
                    'type': 'type',
                    'function': {'name': 'name', 'arguments': 'arguments'},
                  },
                ],
              },
              'logprobs': null,
            },
          ],
          'usage': {'prompt_tokens': 1, 'completion_tokens': 2, 'total_tokens': 3},
        }),
      ).withTools([_tool('deepseek-tool')]);

      final result = await model.generate(
        [
          Message.system('system'),
          Message.user('hello'),
          Message.assistant('assistant'),
          Message.user('hello'),
        ],
        // Go binds with BindForcedTools.
        options: const ChatModelOptions(toolChoice: ToolChoice.forced),
      );

      expect(result.role, RoleType.assistant);
      expect(result.content, 'hello world');
      expect(result.reasoningContent, 'reasoning content');
      expect(result.toolCalls, [
        const ToolCall(
          index: 1,
          id: 'id',
          type: 'type',
          function: FunctionCall(name: 'name', arguments: 'arguments'),
        ),
      ]);
      expect(result.responseMeta!.usage!.promptTokens, 1);
      expect(result.responseMeta!.usage!.completionTokens, 2);
      expect(result.responseMeta!.usage!.totalTokens, 3);
      expect(result.responseMeta!.logProbs, isNull);

      expect(api.body['tool_choice'], {
        'type': 'function',
        'function': {'name': 'deepseek-tool'},
      });
      expect(api.body['messages'], [
        {'role': 'system', 'content': 'system'},
        {'role': 'user', 'content': 'hello'},
        {'role': 'assistant', 'content': 'assistant'},
        {'role': 'user', 'content': 'hello'},
      ]);
    });
  });

  group('TestChatModelStream (deepseek)', () {
    test('streams content, a tool call and the usage', () async {
      final api = _FakeApi();
      final model = OpenAICompatibleChatModel(
        config: OpenAICompatibleConfig.deepSeek(
          apiKey: 'my-api-key',
          responseFormat: const ResponseFormat.jsonObject(),
        ),
        httpClient: api.sse([
          _data({
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': 'Hello'},
              },
            ],
          }),
          _data({
            'choices': [
              {
                'index': 0,
                'delta': {
                  'role': 'assistant',
                  'content': ' World',
                  'tool_calls': [
                    {
                      'index': 1,
                      'id': 'id',
                      'type': 'type',
                      'function': {'name': 'name', 'arguments': 'arguments'},
                    },
                  ],
                },
              },
            ],
          }),
          _data({
            'choices': <Object?>[],
            'usage': {'prompt_tokens': 1, 'completion_tokens': 2, 'total_tokens': 3},
          }),
          _done,
        ]),
      ).withTools([_tool('deepseek-tool')]);

      final reader = await model.stream([Message.user('hello')]);
      final message = concatMessages(await reader.collectAll());

      expect(message.role, RoleType.assistant);
      expect(message.content, 'Hello World');
      expect(message.toolCalls, [
        const ToolCall(
          index: 1,
          id: 'id',
          type: 'type',
          function: FunctionCall(name: 'name', arguments: 'arguments'),
        ),
      ]);
      expect(message.responseMeta!.usage!.promptTokens, 1);
      expect(message.responseMeta!.usage!.completionTokens, 2);
      expect(message.responseMeta!.usage!.totalTokens, 3);
      expect(message.responseMeta!.logProbs, isNull);
      expect(api.body['response_format'], {'type': 'json_object'});
      expect(api.body['stream_options'], {'include_usage': true});
    });

    test('thinking-mode reasoning arrives in reasoningContent', () async {
      final model = OpenAICompatibleChatModel(
        config: _deepSeek(thinking: DeepSeekThinking.enabled),
        httpClient: _FakeApi().sse([
          _data({
            'choices': [
              {'index': 0, 'delta': {'role': 'assistant', 'reasoning_content': 'Let me '}},
            ],
          }),
          _data({
            'choices': [
              {'index': 0, 'delta': {'reasoning_content': 'think'}},
            ],
          }),
          _data({
            'choices': [
              {'index': 0, 'delta': {'content': '42'}, 'finish_reason': 'stop'},
            ],
          }),
          _done,
        ]),
      );
      final message =
          concatMessages(await (await model.stream([Message.user('?')])).collectAll());
      expect(message.reasoningContent, 'Let me think');
      expect(message.content, '42');
    });
  });

  group('TestToDeepSeekMessage (OpenAI-compatible parts)', () {
    Future<List<Object?>> wire(List<Message> input) async {
      final api = _FakeApi();
      await OpenAICompatibleChatModel(config: _deepSeek(), httpClient: api.json(_hello))
          .generate(input);
      return api.body['messages']! as List;
    }

    test('role mapping', () async {
      final messages = await wire([
        Message.system('hi'),
        Message.user('hi'),
        Message.assistant('hi'),
        Message.tool(content: 'hi', toolCallId: 'c'),
      ]);
      expect([for (final m in messages) (m! as Map)['role']],
          ['system', 'user', 'assistant', 'tool']);
    });

    test('prefix on non-assistant returns error', () async {
      final api = _FakeApi();
      await expectLater(
        OpenAICompatibleChatModel(config: _deepSeek(), httpClient: api.json(_hello))
            .generate([Message.user('hi').withDeepSeekPrefix()]),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'prefix only supported for assistant message')),
      );
      expect(api.sent, isEmpty);
    });

    test('prefix on assistant is ok', () async {
      final messages = await wire([
        Message.user('Write a poem'),
        Message.assistant('Roses are').withDeepSeekPrefix(),
      ]);
      expect(messages[1], {'role': 'assistant', 'content': 'Roses are', 'prefix': true});
      expect((messages[0]! as Map).containsKey('prefix'), isFalse);
    });

    test('reasoning content from field', () async {
      final messages = await wire([
        Message.user('q'),
        const Message(role: RoleType.assistant, content: 'hi', reasoningContent: 'think'),
      ]);
      expect((messages[1]! as Map)['reasoning_content'], 'think');
    });

    test('tool role with tool call id', () async {
      final messages = await wire([
        Message.tool(content: 'result', toolCallId: 'call-123'),
      ]);
      expect((messages.single! as Map)['tool_call_id'], 'call-123');
    });

    test('assistant with tool calls', () async {
      final messages = await wire([
        Message.assistant(
          '',
          toolCalls: const [
            ToolCall(id: 'id1', function: FunctionCall(name: 'fn', arguments: '{}')),
          ],
        ),
      ]);
      final calls = (messages.single! as Map)['tool_calls'] as List;
      expect(calls, hasLength(1));
      expect((calls.single as Map)['id'], 'id1');
    });
  });

  group('TestPrefix (deepseek)', () {
    test('SetPrefix and HasPrefix', () {
      const message = Message(role: RoleType.assistant);
      expect(message.hasDeepSeekPrefix, isFalse);
      final marked = message.withDeepSeekPrefix();
      expect(marked.hasDeepSeekPrefix, isTrue);
      expect(message.hasDeepSeekPrefix, isFalse, reason: 'a copy is marked');
      expect(marked.extra, {deepSeekPrefixKey: true});
      expect(deepSeekPrefixKey, '_eino_deepseek_prefix');
    });

    test('the marker survives a JSON round trip and keeps other extras', () {
      final marked = const Message(
        role: RoleType.assistant,
        content: 'x',
        extra: {'a': 1},
      ).withDeepSeekPrefix();
      final copy = Message.fromJson(
        jsonDecode(jsonEncode(marked.toJson())) as Map<String, dynamic>,
      );
      expect(copy.hasDeepSeekPrefix, isTrue);
      expect(copy.extra!['a'], 1);
    });
  });

  group('TestReasoningContent (deepseek)', () {
    test('the reasoning is a field of the message, concatenated in streams',
        () {
      const message = Message(role: RoleType.assistant);
      expect(message.reasoningContent, isNull);
      final withReasoning = message.copyWith(reasoningContent: 'reasoning content');
      expect(withReasoning.reasoningContent, 'reasoning content');

      final result = concatMessages([
        Message.user('').copyWith(reasoningContent: 'reasoning '),
        Message.user('').copyWith(reasoningContent: 'content'),
        Message.user('hello'),
      ]);
      expect(result.reasoningContent, 'reasoning content');
      expect(result.content, 'hello');
    });
  });

  group('OpenAICompatibleChatModel', () {
    test('callbacks carry the preset type name', () async {
      final recorder = _Recorder();
      await OpenAICompatibleChatModel(
        config: _deepSeek(),
        httpClient: _FakeApi().json(_hello),
      ).generate(
        [Message.user('hi')],
        options: ChatModelOptions(
          runContext: RunContext.background().withHandlers([recorder]),
        ),
      );
      expect(recorder.timings, ['start', 'end']);
      expect(
        recorder.infos.single,
        const RunInfo(name: '', type: 'DeepSeek', componentType: ComponentType.chatModel),
      );
    });

    test('a cancelled call sends nothing', () async {
      final api = _FakeApi();
      final model = OpenAICompatibleChatModel(config: _qwen, httpClient: api.json(_hello));
      await expectLater(
        model.generate(
          [Message.user('hi')],
          options: ChatModelOptions(cancelToken: CancelToken()..cancel()),
        ),
        throwsA(isA<CancelledException>()),
      );
      await expectLater(
        model.stream(
          [Message.user('hi')],
          options: ChatModelOptions(cancelToken: CancelToken()..cancel()),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(api.sent, isEmpty);
    });

    test('the request id is kept and the modifiers apply', () async {
      final api = _FakeApi();
      final model = OpenAICompatibleChatModel(config: _qwen, httpClient: api.json(_hello));
      final message = await model.generate(
        [Message.user('hi')],
        options: OpenAIRequestOptions(
          requestPayloadModifier: (ctx, input, body) => {...body, 'x': 1},
          responseMessageModifier: (ctx, message, raw) =>
              message.copyWith(content: '${message.content}!'),
        ).toOptions(),
      );
      expect(api.body['x'], 1);
      expect(message.content, 'hello!');
      expect(message.extra!['openai-request-id'], 'cmpl-1');
    });

    test('withTools shares the HTTP client; dispose closes it for both',
        () async {
      final api = _FakeApi();
      final model = OpenAICompatibleChatModel(config: _qwen, httpClient: api.json(_hello));
      final bound = model.withTools([_tool('t')]) as OpenAICompatibleChatModel;
      await bound.generate([Message.user('x')]);
      expect(identical(bound.httpClient, model.httpClient), isTrue);
      expect(identical(bound.config, model.config), isTrue);
      expect(api.body['tools'] as List, hasLength(1));

      final own = OpenAICompatibleChatModel(config: _qwen);
      final ownBound = own.withTools([_tool('t')]);
      own.dispose();
      await expectLater(own.generate([Message.user('x')]), throwsStateError);
      await expectLater(ownBound.generate([Message.user('x')]), throwsStateError);
    });

    test('failures are classified OpenAIExceptions', () async {
      final model = OpenAICompatibleChatModel(
        config: _deepSeek(),
        httpClient: _FakeApi().json(
          '{"error":{"message":"Model Not Exist","type":"invalid_request_error"}}',
          status: 400,
        ),
      );
      await expectLater(
        model.generate([Message.user('x')]),
        throwsA(isA<OpenAIException>()
            .having((e) => e.isRetryable, 'isRetryable', isFalse)
            .having((e) => e.statusCode, 'statusCode', 400)),
      );
    });
  });
}
