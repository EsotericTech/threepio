// Tests the P11 builder wrote for its own changes to shared files: the
// `outputExtra` hook of `ModelCallCallbacks` (Ollama reports its metrics in
// `ModelCallbackOutput.extra`, as eino-ext's `model.CallbackOutput.Extra`) and
// the request body of `OpenAIEmbedder` under the older callback API.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_converters.dart';
import 'package:threepio_core/src/internal/provider_http.dart';
import 'package:threepio_core/threepio_core.dart';

final class _Recorder extends ComponentCallbackHandler {
  final outputs = <Object?>[];

  @override
  Future<RunContext> onEnd(RunContext ctx, RunInfo info, Object? output) async {
    outputs.add(output);
    return ctx;
  }

  @override
  Future<RunContext> onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) async {
    outputs.addAll(await output.collectAll());
    return ctx;
  }
}

const _metrics = {
  'total_duration': 5000,
  'load_duration': 1000,
  'prompt_eval_count': 7,
  'prompt_eval_duration': 2000,
  'eval_count': 3,
  'eval_duration': 1500,
};

void main() {
  reviewFixes();
  group('CallWatch', () {
    test('fires with the caller\'s reason before release', () async {
      final token = CancelToken();
      final watch = CallWatch(token);
      var fired = 0;
      watch.onCancel(() => fired++);
      final cancelled = expectLater(
        watch.cancelled,
        throwsA(isA<CancelledException>().having((e) => e.reason, 'reason', 'stop')),
      );
      token.cancel('stop');
      await cancelled;
      await pumpEventQueue();
      expect(fired, 1);
    });

    test('is inert after release, and the token keeps working', () async {
      final token = CancelToken();
      var fired = 0;
      for (var i = 0; i < 50; i++) {
        final watch = CallWatch(token)..onCancel(() => fired++);
        watch.release();
      }
      await pumpEventQueue();
      expect(token.isCancelled, isFalse);
      token.cancel('late');
      await pumpEventQueue();
      expect(fired, 0);
    });

    test('sendRequest leaves nothing on a long-lived token', () async {
      final token = CancelToken();
      final client = MockClient((request) async => http.Response('{}', 200));
      for (var i = 0; i < 20; i++) {
        final response = await sendRequest(
          client,
          Uri.parse('http://localhost/x'),
          headers: const {},
          body: '{}',
          timeout: const Duration(seconds: 5),
          cancelToken: token,
        );
        expect(response.statusCode, 200);
      }
      // Cancelling afterwards must not reach a finished call.
      token.cancel('after');
      await pumpEventQueue();
    });
  });

  group('Ollama metrics in the callback output', () {
    test('generate reports them under ollama_metrics', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'model': 'llama3',
            'message': {'role': 'assistant', 'content': 'hi'},
            'done': true,
            'done_reason': 'stop',
            ..._metrics,
          }),
          200,
        ),
      );
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: const OllamaConfig(model: 'llama3'),
        httpClient: client,
      );
      final message = await model.generate(
        [Message.user('x')],
        options: ChatModelOptions(
          runContext: RunContext.background().withHandlers([recorder]),
        ),
      );
      final output = recorder.outputs.single! as ModelCallbackOutput;
      final metrics = output.extra![ollamaMetricsExtraKey]! as Map;
      expect(metrics, isNotEmpty);
      expect(metrics, message.extra![ollamaMetricsExtraKey]);
      expect(message.ollamaMetrics?.evalCount, 3);
    });

    test('a stream reports them on the done chunk only', () async {
      final lines = [
        {
          'model': 'llama3',
          'message': {'role': 'assistant', 'content': 'h'},
          'done': false,
        },
        {
          'model': 'llama3',
          'message': {'role': 'assistant', 'content': 'i'},
          'done': true,
          'done_reason': 'stop',
          ..._metrics,
        },
      ].map(jsonEncode).join('\n');
      final client = MockClient((request) async => http.Response(lines, 200));
      final recorder = _Recorder();
      final model = OllamaChatModel(
        config: const OllamaConfig(model: 'llama3'),
        httpClient: client,
      );
      final reader = await model.stream(
        [Message.user('x')],
        options: ChatModelOptions(
          runContext: RunContext.background().withHandlers([recorder]),
        ),
      );
      await reader.collectAll();
      await pumpEventQueue();
      final outputs = recorder.outputs.cast<ModelCallbackOutput>();
      expect(outputs, hasLength(2));
      expect(outputs.first.extra, isNull);
      expect(outputs.last.extra?[ollamaMetricsExtraKey], isNotNull);
    });
  });

  test('OpenAIEmbedder keeps withCallbacks entries out of the request', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
        jsonEncode({
          'data': [
            {
              'index': 0,
              'embedding': [0.5, 0.25],
            },
          ],
          'usage': {'prompt_tokens': 2, 'total_tokens': 2},
        }),
        200,
      );
    });
    final embedder = OpenAIEmbedder(
      config: const OpenAIConfig(apiKey: 'test-key'),
      httpClient: client,
    );
    final starts = <Object?>[];
    final manager = CallbackManager([_LegacyRecorder(starts)]);
    final vectors = await embedder.embedStrings(
      ['a'],
      options: const EmbedderOptions(extra: {'dimensions': 2})
          .withCallbacks(callbackManager: manager, context: {'k': 'v'}),
    );
    expect(vectors, [
      [0.5, 0.25],
    ]);
    expect(bodies.single.containsKey('callbackManager'), isFalse);
    expect(bodies.single.containsKey('context'), isFalse);
    expect(starts, isNotEmpty);
  });
}

void reviewFixes() {
  String sse(List<Map<String, Object?>> chunks) =>
      [for (final c in chunks) 'data: ${jsonEncode(c)}', 'data: [DONE]', '']
          .join('\n\n');

  Map<String, Object?> delta(Map<String, Object?> d, {String? finish}) => {
        'id': 'x',
        'choices': [
          {'index': 0, 'delta': d, 'finish_reason': finish},
        ],
      };

  group('review fixes (OpenAI-compatible stack)', () {
    test('a call assembled without a type is sent back as a function call',
        () {
      final wire = OpenAIConverters.messageToOpenAI(
        const Message(
          role: RoleType.assistant,
          toolCalls: [
            ToolCall(
              id: 'c1',
              type: '',
              function: FunctionCall(name: 'f', arguments: '{}'),
            ),
          ],
        ),
        goCompatible: true,
      );
      expect(((wire['tool_calls']! as List).single as Map)['type'], 'function');
    });

    test('in-stream error codes are classified by code', () async {
      Future<OpenAIException> failure(Map<String, Object?> error) async {
        final model = OpenAIChatModel(
          config: const OpenAIConfig(apiKey: 'test-key'),
          httpClient: MockClient(
            (request) async => http.Response(sse([{'error': error}]), 200),
          ),
        );
        final reader = await model.stream([Message.user('x')]);
        try {
          await reader.collectAll();
        } on OpenAIException catch (e) {
          return e;
        }
        fail('no error');
      }

      final limited = await failure({
        'message': 'Rate limit reached',
        'type': 'tokens',
        'code': 'rate_limit_exceeded',
      });
      expect(limited.isRetryable, isTrue);
      final missing = await failure({
        'message': 'The model x does not exist',
        'type': 'invalid_request_error',
        'code': 'model_not_found',
      });
      expect(missing.isModelUnavailable, isTrue);
      expect(missing.isRetryable, isFalse);
    });

    test('"does not exist" means an unknown model only next to "model"', () {
      expect(
        looksLikeModelUnavailable(400, "tool_call_id 'c9' does not exist"),
        isFalse,
      );
      expect(
        looksLikeModelUnavailable(400, 'The model `gpt-x` does not exist'),
        isTrue,
      );
    });

    test('extra fields override stream_options', () async {
      final bodies = <Map<String, dynamic>>[];
      final model = OpenAIChatModel(
        config: const OpenAIConfig(apiKey: 'test-key'),
        httpClient: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(sse([delta({'content': 'a'}, finish: 'stop')]), 200);
        }),
      );
      final reader = await model.stream(
        [Message.user('x')],
        options: const OpenAIRequestOptions(
          extraFields: {
            'stream_options': {'include_usage': false},
          },
        ).toOptions(),
      );
      await reader.collectAll();
      expect(bodies.single['stream_options'], {'include_usage': false});
    });

    test('the audio id is on the first audio part only, so that chunks '
        'concatenate to one id (Go repeats it and dedups in a concat function)',
        () async {
      final model = OpenAIChatModel(
        config: const OpenAIConfig(
          apiKey: 'test-key',
          modalities: [OpenAIModality.text, OpenAIModality.audio],
          audio: OpenAIAudioConfig(format: 'wav', voice: 'alloy'),
        ),
        httpClient: MockClient(
          (request) async => http.Response(
            sse([
              delta({
                'content': 'a',
                'audio': {'id': 'aud_1', 'data': 'AAAA'},
              }),
              delta({
                'content': 'b',
                'audio': {'data': 'BBBB'},
              }, finish: 'stop'),
            ]),
            200,
          ),
        ),
      );
      final chunks = await (await model.stream([Message.user('x')])).collectAll();
      final merged = concatMessages(chunks);
      final audio = merged.assistantGenMultiContent!
          .where((p) => p.type == ChatMessagePartType.audioUrl)
          .toList();
      expect(audio.first.extra?[openAIGeneratedAudioIdKey], 'aud_1');
    });

    test('the callback config carries the config defaults', () async {
      final inputs = <Object?>[];
      final model = OpenAIChatModel(
        config: const OpenAIConfig(apiKey: 'test-key', temperature: 0.3),
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'index': 0,
                  'message': {'role': 'assistant', 'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          ),
        ),
      );
      await model.generate(
        [Message.user('x')],
        options: ChatModelOptions(
          runContext:
              RunContext.background().withHandlers([_StartRecorder(inputs)]),
        ),
      );
      final input = inputs.single! as ModelCallbackInput;
      expect(input.config?.temperature, 0.3);
    });

    test('withCallbacks keeps the run context and extensions', () {
      final ctx = RunContext.background();
      final options = EmbedderOptions(runContext: ctx, extensions: const ['x'])
          .withCallbacks(callbackManager: CallbackManager(const []));
      expect(options.runContext, same(ctx));
      expect(options.extensions, ['x']);
    });

    test('Qwen: a finish chunk\'s tool call without index gets the last one',
        () async {
      final model = OpenAICompatibleChatModel(
        config: OpenAICompatibleConfig.qwen(apiKey: 'test-key', model: 'qwen-plus'),
        httpClient: MockClient(
          (request) async => http.Response(
            sse([
              delta({
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'c1',
                    'type': 'function',
                    'function': {'name': 'f', 'arguments': '{"a":'},
                  },
                ],
              }),
              delta({
                'tool_calls': [
                  {
                    'function': {'arguments': '1}'},
                  },
                ],
              }, finish: 'tool_calls'),
            ]),
            200,
          ),
        ),
      );
      final chunks = await (await model.stream([Message.user('x')])).collectAll();
      final merged = concatMessages(chunks);
      expect(merged.toolCalls, hasLength(1));
      expect(merged.toolCalls!.single.function.arguments, '{"a":1}');
    });
  });
}

final class _StartRecorder extends ComponentCallbackHandler {
  _StartRecorder(this.inputs);

  final List<Object?> inputs;

  @override
  Future<RunContext> onStart(RunContext ctx, RunInfo info, Object? input) async {
    inputs.add(input);
    return ctx;
  }
}

final class _LegacyRecorder extends BaseCallbackHandler {
  _LegacyRecorder(this.starts);

  final List<Object?> starts;

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    starts.add(input);
    return context;
  }
}
