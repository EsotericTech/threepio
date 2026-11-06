// Port of eino-ext components/model/openrouter: chatmodel_test.go
// (TestChatModel_buildRequestModifier,
// TestChatModel_buildRequestModifier_CacheControl,
// TestChatModel_buildOptions_CacheControlFallback, TestChatModel_Tools,
// TestChatModel_WithTools_PreservesFields) and message_extra_test.go
// (TestEnableMessageInputPartCacheControl,
// TestEnableMessageOutputPartCacheControl,
// TestEnableMessageContentCacheControl), plus tests written for the port of
// the new OpenRouter options (`models`, `metadata`, `reasoningEnabled`,
// `reasoningSummary`, `cacheControl`, `logprobs`, `topLogprobs`), the
// cache-control extensions, log probabilities in responses and the
// `allowed_tools` form of `allowedToolNames`.
//
// Go tests the payload modifier on hand-written raw bodies; here the request
// body the model sends through `MockClient` is checked, so the parts whose Go
// fixture has no media (`{"type":"image_url"}`) get an image URL.
//
// Not ported: TestNewChatModel (Go config validation and SDK client
// fields), TestChatModel_Generate_Stream (mocks the acl client),
// TestChatModel_buildResponseMessageModifier and
// TestChatModel_buildResponseChunkMessageModifier (OpenRouter keeps its own
// response parser and its reasoning under `extra['reasoning_details']`, and
// throws `OpenRouterException` for an in-stream error instead of Go's
// `GetStreamTerminatedError`: intended, pinned in the existing OpenRouter
// tests), TestSetStreamTerminatedError / TestGetStreamTerminatedError /
// TestStreamTerminatedErrorConcat (same reason), TestSetReasoningDetails /
// TestGetReasoningDetails / TestReasoningDetailsConcat (private helpers;
// the list concatenation is pinned in the concat tests), and
// TestCacheControlConcatPreference (not in this assignment).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openrouter/openrouter_cache_control.dart';
import 'package:threepio_core/threepio_core.dart';

final class _FakeApi {
  final bodies = <Map<String, Object?>>[];

  Map<String, Object?> get body => bodies.last;

  http.Client ok(Object response) => MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response(
          jsonEncode(response),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

  http.Client sse(List<String> chunks) =>
      MockClient.streaming((request, bytes) async {
        bodies.add(jsonDecode(await bytes.bytesToString()) as Map<String, Object?>);
        return http.StreamedResponse(
          Stream.fromIterable([for (final c in chunks) utf8.encode(c)]),
          200,
        );
      });
}

Map<String, Object?> _completion({Map<String, Object?>? logprobs}) => {
      'id': 'gen-1',
      'model': 'test-model',
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': 'ok'},
          'finish_reason': 'stop',
          if (logprobs != null) 'logprobs': logprobs,
        },
      ],
    };

const _config = OpenRouterConfig(apiKey: 'test-key', defaultModel: 'test-model');

/// The body [model] sends for [input] with [options].
Future<Map<String, Object?>> _sent(
  List<Message> input, {
  OpenRouterConfig config = _config,
  ChatModelOptions? options,
}) async {
  final api = _FakeApi();
  final model = OpenRouterChatModel(config: config, httpClient: api.ok(_completion()));
  await model.generate(input, options: options);
  return api.body;
}

Map<String, Object?> _message(Map<String, Object?> body, [int index = 0]) =>
    (body['messages']! as List)[index] as Map<String, Object?>;

Map<String, Object?> _part(Map<String, Object?> body, int message, int part) =>
    (_message(body, message)['content']! as List)[part] as Map<String, Object?>;

const _ephemeral5m = {'type': 'ephemeral', 'ttl': '5m'};


void main() {
  group('TestChatModel_buildRequestModifier', () {
    test('the options of a call replace models and response_format', () async {
      final body = await _sent(
        [Message.user('hello')],
        config: _config.copyWith(
          defaultRequestOptions: const OpenRouterRequestOptions(
            models: ['mode1', 'mode2'],
            reasoningEffort: ReasoningEffort.none,
            responseFormat: ResponseFormat.jsonObject(),
          ),
        ),
        options: const ChatModelOptions(
          extensions: [
            OpenRouterRequestOptions(
              models: ['option_v1', 'option_v2'],
              responseFormat: ResponseFormat.jsonObject(),
            ),
          ],
        ),
      );
      expect(body['models'], ['option_v1', 'option_v2']);
      expect(body['response_format'], {'type': 'json_object'});
      // Go buildOptions: what the call does not set comes from the config.
      expect(body['reasoning'], {'effort': 'none'});
    });
  });

  group('TestChatModel_buildRequestModifier_CacheControl', () {
    test('UserInputMultiContent text part with cache control', () async {
      final body = await _sent([
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart.text('hello').withOpenRouterCacheControl(),
          ],
        ),
      ]);
      expect(_part(body, 0, 0)['cache_control'], _ephemeral5m);
      expect(_part(body, 0, 0)['text'], 'hello');
    });

    test('UserInputMultiContent text part without cache control skipped',
        () async {
      final body = await _sent([
        Message(
          role: RoleType.user,
          userInputMultiContent: [MessageInputPart.text('hello')],
        ),
      ]);
      expect(_part(body, 0, 0).containsKey('cache_control'), isFalse);
    });

    test('UserInputMultiContent non-text part without cache control skipped',
        () async {
      final body = await _sent([
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart.text('hello'),
            MessageInputPart.imageUrl('https://example.com/a.png'),
          ],
        ),
      ]);
      expect(_part(body, 0, 1)['type'], 'image_url');
      expect(_part(body, 0, 1).containsKey('cache_control'), isFalse);
    });

    test('UserInputMultiContent non-text part with cache control injects '
        'cache_control', () async {
      final body = await _sent([
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart.imageUrl('https://example.com/a.png')
                .withOpenRouterCacheControl(),
          ],
        ),
      ]);
      expect((_part(body, 0, 0)['cache_control']! as Map)['type'], 'ephemeral');
    });

    test('AssistantGenMultiContent text part with cache control', () async {
      final body = await _sent([
        Message.user('hi'),
        Message(
          role: RoleType.assistant,
          assistantGenMultiContent: [
            const MessageOutputPart(type: ChatMessagePartType.text, text: 'response')
                .withOpenRouterCacheControl(),
          ],
        ),
      ]);
      expect(_part(body, 1, 0)['text'], 'response');
      expect((_part(body, 1, 0)['cache_control']! as Map)['type'], 'ephemeral');
    });

    test('AssistantGenMultiContent non-text part without cache control '
        'skipped', () async {
      final body = await _sent([
        Message.user('hi'),
        const Message(
          role: RoleType.assistant,
          content: 'response',
          assistantGenMultiContent: [
            MessageOutputPart(type: ChatMessagePartType.text, text: 'response'),
            MessageOutputPart(
              type: ChatMessagePartType.imageUrl,
              image: MessagePartCommon(url: 'https://example.com/a.png'),
            ),
          ],
        ),
      ]);
      expect(_message(body, 1).containsKey('cache_control'), isFalse);
      // Without a breakpoint the plain content is sent, as before.
      expect(_message(body, 1)['content'], 'response');
    });

    test('AssistantGenMultiContent non-text part with cache control injects '
        'cache_control', () async {
      final body = await _sent([
        Message.user('hi'),
        Message(
          role: RoleType.assistant,
          assistantGenMultiContent: [
            const MessageOutputPart(
              type: ChatMessagePartType.imageUrl,
              image: MessagePartCommon(url: 'https://example.com/a.png'),
            ).withOpenRouterCacheControl(),
          ],
        ),
      ]);
      expect((_part(body, 1, 0)['cache_control']! as Map)['type'], 'ephemeral');
    });

    test('message content with cache control', () async {
      final body = await _sent([Message.user('hello').withOpenRouterCacheControl()]);
      expect((_message(body)['cache_control']! as Map)['type'], 'ephemeral');
      expect(_message(body)['content'], 'hello');
    });

    test('top-level cache_control via option', () async {
      final body = await _sent(
        [Message.user('hello')],
        options: const ChatModelOptions(
          extensions: [
            OpenRouterRequestOptions(
              cacheControl: OpenRouterCacheControl(ttl: OpenRouterCacheControlTtl.oneHour),
            ),
          ],
        ),
      );
      expect(body['cache_control'], {'type': 'ephemeral', 'ttl': '1h'});
    });

    test('top-level cache_control not set when option is nil', () async {
      final body = await _sent([Message.user('hello')]);
      expect(body.containsKey('cache_control'), isFalse);
    });

    test('a marker on an empty message is not sent', () async {
      // Go marks the message only when it has plain content.
      final body = await _sent([
        Message.user('hi'),
        Message.assistant('').withOpenRouterCacheControl(),
      ]);
      expect(_message(body, 1).containsKey('cache_control'), isFalse);
    });
  });

  group('TestChatModel_buildOptions_CacheControlFallback', () {
    final config = _config.copyWith(
      defaultRequestOptions: const OpenRouterRequestOptions(
        cacheControl: OpenRouterCacheControl(),
      ),
    );

    test('config-level cacheControl used when no option override', () async {
      final body = await _sent([Message.user('hi')], config: config);
      expect(body['cache_control'], _ephemeral5m);
    });

    test('option-level cacheControl overrides config', () async {
      final body = await _sent(
        [Message.user('hi')],
        config: config,
        options: const ChatModelOptions(
          extensions: [
            OpenRouterRequestOptions(
              cacheControl: OpenRouterCacheControl(ttl: OpenRouterCacheControlTtl.oneHour),
            ),
          ],
        ),
      );
      expect((body['cache_control']! as Map)['ttl'], '1h');
    });
  });

  group('TestChatModel_Tools', () {
    test('a tool with empty parameters can be bound and is sent', () async {
      final api = _FakeApi();
      final model = OpenRouterChatModel(
        config: _config,
        httpClient: api.ok(_completion()),
      ).withTools([
        const ToolInfo(
          function: FunctionInfo(
            name: 'test-tool',
            description: 'test tool description',
            parameters: JSONSchema(),
          ),
        ),
      ]);
      await model.generate([Message.user('x')]);
      final tool = (api.body['tools']! as List).single as Map;
      expect((tool['function'] as Map)['name'], 'test-tool');
    });
  });

  group('TestChatModel_WithTools_PreservesFields', () {
    test('the copy with tools sends what the config sets', () async {
      final api = _FakeApi();
      final model = OpenRouterChatModel(
        config: _config.copyWith(
          defaultRequestOptions: const OpenRouterRequestOptions(
            models: ['model-a', 'model-b'],
            reasoningEffort: ReasoningEffort.high,
            metadata: {'key': 'value'},
            cacheControl: OpenRouterCacheControl(ttl: OpenRouterCacheControlTtl.oneHour),
            responseFormat: ResponseFormat.jsonObject(),
          ),
        ),
        httpClient: api.ok(_completion()),
      );
      final bound =
          model.withTools([ToolInfo.function(name: 'test')]) as OpenRouterChatModel;

      expect(identical(bound.config, model.config), isTrue);
      await bound.generate([Message.user('x')]);
      expect(api.body['models'], ['model-a', 'model-b']);
      expect(api.body['reasoning'], {'effort': 'high'});
      expect(api.body['metadata'], {'key': 'value'});
      expect(api.body['cache_control'], {'type': 'ephemeral', 'ttl': '1h'});
      expect(api.body['response_format'], {'type': 'json_object'});
      expect((api.body['tools']! as List), hasLength(1));
    });
  });

  group('TestEnableMessageInputPartCacheControl', () {
    test('default ttl', () {
      final part = const MessageInputPart(type: ChatMessagePartType.text)
          .withOpenRouterCacheControl();
      final control = part.openRouterCacheControl;
      expect(control, isNotNull);
      expect(control!.toJson()['type'], 'ephemeral');
      expect(control.ttl, OpenRouterCacheControlTtl.fiveMinutes);
    });

    test('override ttl to 1h', () {
      final part = const MessageInputPart(type: ChatMessagePartType.text)
          .withOpenRouterCacheControl(
        const OpenRouterCacheControl(ttl: OpenRouterCacheControlTtl.oneHour),
      );
      expect(part.openRouterCacheControl!.ttl, OpenRouterCacheControlTtl.oneHour);
      expect(part.openRouterCacheControl!.toJson()['type'], 'ephemeral');
    });

    test('no extra present', () {
      expect(
        const MessageInputPart(type: ChatMessagePartType.text).openRouterCacheControl,
        isNull,
      );
    });
  });

  group('TestEnableMessageOutputPartCacheControl', () {
    test('default ttl', () {
      final part = const MessageOutputPart(type: ChatMessagePartType.text)
          .withOpenRouterCacheControl();
      expect(part.openRouterCacheControl!.ttl, OpenRouterCacheControlTtl.fiveMinutes);
      expect(part.openRouterCacheControl!.toJson()['type'], 'ephemeral');
    });

    test('override ttl to 1h', () {
      final part = const MessageOutputPart(type: ChatMessagePartType.text)
          .withOpenRouterCacheControl(
        const OpenRouterCacheControl(ttl: OpenRouterCacheControlTtl.oneHour),
      );
      expect(part.openRouterCacheControl!.ttl, OpenRouterCacheControlTtl.oneHour);
    });

    test('no extra present', () {
      expect(
        const MessageOutputPart(type: ChatMessagePartType.text).openRouterCacheControl,
        isNull,
      );
    });
  });

  group('TestEnableMessageContentCacheControl', () {
    test('default ttl', () {
      final message = const Message(role: RoleType.user).withOpenRouterCacheControl();
      expect(message.openRouterCacheControl!.ttl, OpenRouterCacheControlTtl.fiveMinutes);
      expect(message.openRouterCacheControl!.toJson()['type'], 'ephemeral');
    });

    test('override ttl to 1h', () {
      final message = const Message(role: RoleType.user).withOpenRouterCacheControl(
        const OpenRouterCacheControl(ttl: OpenRouterCacheControlTtl.oneHour),
      );
      expect(message.openRouterCacheControl!.ttl, OpenRouterCacheControlTtl.oneHour);
    });

    test('nil extra should not be initialized on get', () {
      const message = Message(role: RoleType.user);
      expect(message.openRouterCacheControl, isNull);
      expect(message.extra, isNull);
    });

    test('the marker keeps the other extras and leaves the original alone', () {
      const original = Message(role: RoleType.user, content: 'x', extra: {'a': 1});
      final marked = original.withOpenRouterCacheControl();
      expect(marked.extra, {
        'a': 1,
        openRouterCacheControlKey: _ephemeral5m,
      });
      expect(original.extra, {'a': 1});
      expect(openRouterCacheControlKey, 'openrouter_cache_control_key');
    });

    test('the marker survives a JSON round trip', () {
      final message = Message.user('x').withOpenRouterCacheControl(
        const OpenRouterCacheControl(ttl: OpenRouterCacheControlTtl.oneHour),
      );
      final copy = Message.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      expect(copy.openRouterCacheControl!.ttl, OpenRouterCacheControlTtl.oneHour);
    });
  });

  group('OpenRouterCacheControl', () {
    test('reads its JSON form and nothing else', () {
      expect(
        OpenRouterCacheControl.fromJson({'type': 'ephemeral', 'ttl': '1h'}),
        const OpenRouterCacheControl(ttl: OpenRouterCacheControlTtl.oneHour),
      );
      expect(
        OpenRouterCacheControl.fromJson({'type': 'ephemeral'}),
        const OpenRouterCacheControl(),
      );
      expect(OpenRouterCacheControl.fromJson({'type': 'persistent'}), isNull);
      expect(OpenRouterCacheControl.fromJson('ephemeral'), isNull);
      expect(OpenRouterCacheControl.fromJson(null), isNull);
    });

    test('equality, hashCode and wire values', () {
      expect(
        const OpenRouterCacheControl().hashCode,
        const OpenRouterCacheControl(ttl: OpenRouterCacheControlTtl.fiveMinutes).hashCode,
      );
      expect(
        const OpenRouterCacheControl() ==
            const OpenRouterCacheControl(ttl: OpenRouterCacheControlTtl.oneHour),
        isFalse,
      );
      expect(OpenRouterCacheControlTtl.values.map((t) => t.wireValue), ['5m', '1h']);
    });
  });

  group('OpenRouterRequestOptions', () {
    test('the new fields are request fields', () {
      expect(
        const OpenRouterRequestOptions(
          includeUsage: false,
          models: ['a', 'b'],
          metadata: {'user': 'u1'},
          reasoningEnabled: true,
          reasoningSummary: ReasoningSummary.concise,
          cacheControl: OpenRouterCacheControl(),
          logprobs: true,
          topLogprobs: 3,
        ).toRequestFields(),
        {
          'reasoning': {'enabled': true, 'summary': 'concise'},
          'models': ['a', 'b'],
          'metadata': {'user': 'u1'},
          'cache_control': _ephemeral5m,
          'logprobs': true,
          'top_logprobs': 3,
        },
      );
    });

    test('reasoning fields share one object', () {
      expect(
        const OpenRouterRequestOptions(
          includeUsage: false,
          reasoningEffort: ReasoningEffort.xhigh,
          reasoningMaxTokens: 100,
          excludeReasoning: true,
          reasoningEnabled: false,
          reasoningSummary: ReasoningSummary.detailed,
        ).toRequestFields(),
        {
          'reasoning': {
            'effort': 'xhigh',
            'max_tokens': 100,
            'exclude': true,
            'enabled': false,
            'summary': 'detailed',
          },
        },
      );
      expect(ReasoningSummary.values.map((s) => s.name), ['auto', 'concise', 'detailed']);
    });

    test('log probabilities are requested and parsed', () async {
      final api = _FakeApi();
      final model = OpenRouterChatModel(
        config: _config,
        httpClient: api.ok(_completion(
          logprobs: {
            'content': [
              {
                'token': 'ok',
                'logprob': -0.2,
                'bytes': [111, 107],
                'top_logprobs': [
                  {'token': 'ok', 'logprob': -0.2, 'bytes': [111, 107]},
                ],
              },
            ],
          },
        )),
      );
      final message = await model.generate(
        [Message.user('x')],
        options: const OpenRouterRequestOptions(logprobs: true, topLogprobs: 1)
            .toOptions(),
      );
      expect(api.body['logprobs'], isTrue);
      expect(api.body['top_logprobs'], 1);
      final logProb = message.responseMeta!.logProbs!.content.single;
      expect(logProb.token, 'ok');
      expect(logProb.bytes, [111, 107]);
      expect(logProb.topLogProbs.single.logProb, -0.2);
    });

    test('streamed log probabilities are kept per chunk', () async {
      String data(Object chunk) => 'data: ${jsonEncode(chunk)}\n\n';
      final model = OpenRouterChatModel(
        config: _config,
        httpClient: _FakeApi().sse([
          data({
            'id': 'gen-1',
            'choices': [
              {
                'index': 0,
                'delta': {'role': 'assistant', 'content': 'a'},
                'logprobs': {
                  'content': [
                    {'token': 'a', 'logprob': -1, 'top_logprobs': <Object?>[]},
                  ],
                },
              },
            ],
          }),
          data({
            'id': 'gen-1',
            'choices': [
              {
                'index': 0,
                'delta': {'content': 'b'},
                'finish_reason': 'stop',
                'logprobs': {
                  'content': [
                    {'token': 'b', 'logprob': -2, 'top_logprobs': <Object?>[]},
                  ],
                },
              },
            ],
          }),
          'data: [DONE]\n\n',
        ]),
      );
      final message =
          concatMessages(await (await model.stream([Message.user('x')])).collectAll());
      expect(message.content, 'ab');
      expect(message.responseMeta!.logProbs!.content.map((p) => p.token), ['a', 'b']);
      expect(message.responseMeta!.finishReason, 'stop');
    });
  });

  group('tool_choice', () {
    final tools = [ToolInfo.function(name: 'a'), ToolInfo.function(name: 'b')];

    test('without allowedToolNames OpenRouter keeps its strings', () async {
      for (final (choice, wire) in [
        (ToolChoice.allowed, 'auto'),
        (ToolChoice.forbidden, 'none'),
        (ToolChoice.forced, 'required'),
      ]) {
        final body = await _sent(
          [Message.user('x')],
          options: ChatModelOptions(tools: tools, toolChoice: choice),
        );
        expect(body['tool_choice'], wire, reason: '$choice');
      }
    });

    test('allowedToolNames give Go\'s allowed_tools and single-tool forms',
        () async {
      final allowed = await _sent(
        [Message.user('x')],
        options: ChatModelOptions(
          tools: tools,
          toolChoice: ToolChoice.allowed,
          allowedToolNames: const ['b'],
        ),
      );
      expect(allowed['tool_choice'], {
        'type': 'allowed_tools',
        'allowed_tools': {
          'mode': 'auto',
          'tools': [
            {
              'type': 'function',
              'function': {'name': 'b'},
            },
          ],
        },
      });

      final forced = await _sent(
        [Message.user('x')],
        options: ChatModelOptions(
          tools: tools,
          toolChoice: ToolChoice.forced,
          allowedToolNames: const ['a'],
        ),
      );
      expect(forced['tool_choice'], {
        'type': 'function',
        'function': {'name': 'a'},
      });
    });

    test('an allowed name that is not a tool is an ArgumentError', () async {
      final model = OpenRouterChatModel(
        config: _config,
        httpClient: _FakeApi().ok(_completion()),
      );
      await expectLater(
        model.generate(
          [Message.user('x')],
          options: ChatModelOptions(
            tools: tools,
            toolChoice: ToolChoice.allowed,
            allowedToolNames: const ['c'],
          ),
        ),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'allowed tool c not found in request tools')),
      );
    });

    test('no tool_choice without tools', () async {
      final body = await _sent(
        [Message.user('x')],
        options: const ChatModelOptions(toolChoice: ToolChoice.forced),
      );
      expect(body.containsKey('tool_choice'), isFalse);
      expect(body.containsKey('tools'), isFalse);
    });
  });
}
