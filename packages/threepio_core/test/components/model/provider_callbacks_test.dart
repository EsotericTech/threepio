// The chat model providers report their calls to the callback handlers of the
// run context (and to the global ones), in addition to the `CallbackManager`
// of the older API.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../support/log_capture.dart';

Map<String, Object?> _completion(String content) => {
      'id': 'gen-1',
      'model': 'served-model',
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': content},
          'finish_reason': 'stop',
        },
      ],
      'usage': {'prompt_tokens': 7, 'completion_tokens': 3, 'total_tokens': 10},
    };

String _sse(Map<String, Object?> delta, {String? finish}) => 'data: ${jsonEncode({
      'id': 'gen-1',
      'choices': [
        {
          'index': 0,
          'delta': delta,
          if (finish != null) 'finish_reason': finish,
        },
      ],
    })}\n\n';

http.Client _completing(String content) => MockClient(
      (request) async => http.Response(
        jsonEncode(_completion(content)),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

http.Client _streaming(List<String> lines) => MockClient.streaming(
      (request, body) async => http.StreamedResponse(
        Stream.fromIterable([for (final line in lines) utf8.encode(line)]),
        200,
      ),
    );

http.Client _failing(int status) =>
    MockClient((request) async => http.Response('{"error": {"message": "no"}}', status));

const _openRouter = OpenRouterConfig(apiKey: 'k', defaultModel: 'z-ai/glm-5.3');

/// Records every callback with its payload.
final class _Recorder extends ComponentCallbackHandler {
  final List<String> timings = [];
  final List<RunInfo> infos = [];
  ModelCallbackInput? input;
  ModelCallbackOutput? output;
  Object? error;
  final List<ModelCallbackOutput?> chunks = [];
  final Completer<void> streamDone = Completer<void>();

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    timings.add('start');
    infos.add(info);
    this.input = ModelCallbackInput.from(input);
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    timings.add('end');
    this.output = ModelCallbackOutput.from(output);
    return ctx;
  }

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    timings.add('error');
    this.error = error;
    return ctx;
  }

  @override
  RunContext onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) {
    timings.add('endStream');
    unawaited(() async {
      try {
        for (final chunk in await output.collectAll()) {
          chunks.add(ModelCallbackOutput.from(chunk));
        }
      } on Object catch (error) {
        this.error = error;
      } finally {
        await output.close();
        streamDone.complete();
      }
    }());
    return ctx;
  }
}

class _LegacyRecorder extends BaseCallbackHandler {
  final List<String> timings = [];

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    timings.add('start ${info.name}');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    timings.add('end ${(output.data as Message).content}');
    return context;
  }
}

ChatModelOptions _with(ComponentCallbackHandler handler) => ChatModelOptions(
      runContext: RunContext.background().withHandlers([handler]),
    );

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('OpenRouterChatModel.generate', () {
    test('reports the call with its configuration and token usage', () async {
      final recorder = _Recorder();
      final tool = ToolInfo.fromJsonSchema(
        name: 'search',
        desc: 'Searches',
        schema: JSONSchema(type: 'object', properties: const {}),
      );
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _completing('hello'),
      ).withTools([tool]);
      final messages = [Message.user('hi')];

      final answer = await model.generate(
        messages,
        options: _with(recorder).copyWith(
          temperature: 0.2,
          maxTokens: 64,
          toolChoice: ToolChoice.allowed,
        ),
      );

      expect(answer.content, 'hello');
      expect(recorder.timings, ['start', 'end']);
      expect(
        recorder.infos.single,
        const RunInfo(
          name: '',
          type: 'OpenRouter',
          componentType: ComponentType.chatModel,
        ),
      );

      final input = recorder.input!;
      expect(input.messages, same(messages));
      expect(input.tools!.single.name, 'search');
      expect(input.toolChoice, ToolChoice.allowed);
      expect(input.config!.model, 'z-ai/glm-5.3');
      expect(input.config!.temperature, 0.2);
      expect(input.config!.maxTokens, 64);

      final output = recorder.output!;
      expect(output.message, same(answer));
      expect(output.config!.model, 'z-ai/glm-5.3');
      expect(output.tokenUsage!.promptTokens, 7);
      expect(output.tokenUsage!.completionTokens, 3);
    });

    test('the model named in the options is the one reported', () async {
      final recorder = _Recorder();
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _completing('x'),
      );

      await model.generate(
        [Message.user('hi')],
        options: _with(recorder).copyWith(model: 'other/model'),
      );
      expect(recorder.input!.config!.model, 'other/model');
    });

    test('a failed call is reported to the error callback and rethrown',
        () async {
      final recorder = _Recorder();
      final model =
          OpenRouterChatModel(config: _openRouter, httpClient: _failing(500));

      await expectLater(
        model.generate([Message.user('hi')], options: _with(recorder)),
        throwsA(isA<OpenRouterException>()),
      );
      expect(recorder.timings, ['start', 'error']);
      expect(recorder.error, isA<OpenRouterException>());
    });

    test('a cancelled call is reported as the cancellation it is', () async {
      final recorder = _Recorder();
      final token = CancelToken()..cancel('stop');
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _completing('never'),
      );

      await expectLater(
        model.generate(
          [Message.user('hi')],
          options: _with(recorder).copyWith(cancelToken: token),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(recorder.timings, ['start', 'error']);
      expect(recorder.error, isA<CancelledException>());
    });

    test('inside a node the run info of the node is kept', () async {
      final recorder = _Recorder();
      const node = RunInfo(
        name: 'summarise',
        type: 'OpenRouter',
        componentType: ComponentType.chatModel,
      );
      final ctx = reuseHandlers(
        RunContext.background().withHandlers([recorder]),
        node,
      );
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _completing('x'),
      );

      await model.generate(
        [Message.user('hi')],
        options: ChatModelOptions(runContext: ctx),
      );
      expect(recorder.infos.single.name, 'summarise');
    });

    test('without a run context and without global handlers nothing is fired',
        () async {
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _completing('plain'),
      );
      expect((await model.generate([Message.user('hi')])).content, 'plain');
      expect(
        (await model.generate(
          [Message.user('hi')],
          options: ChatModelOptions(runContext: RunContext.background()),
        ))
            .content,
        'plain',
      );
    });

    test('global handlers hear a call that has no run context', () async {
      final recorder = _Recorder();
      GlobalCallbacks.append([recorder]);
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _completing('x'),
      );

      await model.generate([Message.user('hi')]);
      expect(recorder.timings, ['start', 'end']);
      expect(recorder.infos.single.type, 'OpenRouter');
    });

    test('the CallbackManager of the older API is still called', () async {
      final recorder = _Recorder();
      final legacy = _LegacyRecorder();
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _completing('both'),
      );

      await model.generate(
        [Message.user('hi')],
        // ignore: deprecated_member_use
        options: _with(recorder).copyWith(callbackManager: CallbackManager([legacy])),
      );

      expect(legacy.timings, ['start OpenRouterChatModel', 'end both']);
      expect(recorder.timings, ['start', 'end']);
    });
  });

  group('OpenRouterChatModel.stream', () {
    test('every handler gets the chunks; the caller gets the messages',
        () async {
      final recorder = _Recorder();
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _streaming([
          _sse({'role': 'assistant', 'content': 'Hel'}),
          _sse({'content': 'lo'}, finish: 'stop'),
          'data: [DONE]\n\n',
        ]),
      );

      final reader =
          await model.stream([Message.user('hi')], options: _with(recorder));
      final chunks = await reader.collectAll();
      await reader.close();
      await recorder.streamDone.future;

      expect(concatMessages(chunks).content, 'Hello');
      expect(recorder.timings, ['start', 'endStream']);
      expect(recorder.input!.messages.single.content, 'hi');
      expect(
        concatMessages([for (final c in recorder.chunks) c!.message!]).content,
        'Hello',
      );
      expect(recorder.chunks.first!.config!.model, 'z-ai/glm-5.3');
      expect(recorder.error, isNull);
    });

    test('a handler without a stream hook costs the caller nothing', () async {
      final seen = <String>[];
      final startOnly = CallbackHandlerBuilder().onStart((ctx, info, input) {
        seen.add(info.type);
        return ctx;
      }).build();
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _streaming([
          _sse({'content': 'a'}, finish: 'stop'),
          'data: [DONE]\n\n',
        ]),
      );

      final reader =
          await model.stream([Message.user('hi')], options: _with(startOnly));
      expect((await reader.collectAll()).single.content, 'a');
      await reader.close();
      expect(seen, ['OpenRouter']);
    });

    test('a request that fails is reported to the error callback', () async {
      final recorder = _Recorder();
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: MockClient.streaming(
          (request, body) async => http.StreamedResponse(
            Stream.value(utf8.encode('{"error": {"message": "down"}}')),
            503,
          ),
        ),
      );

      await expectLater(
        model.stream([Message.user('hi')], options: _with(recorder)),
        throwsA(isA<OpenRouterException>()),
      );
      expect(recorder.timings, ['start', 'error']);
    });

    test('an error inside the stream reaches the handler through its copy',
        () async {
      final recorder = _Recorder();
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _streaming([
          _sse({'content': 'a'}),
          'data: ${jsonEncode({
                'error': {'message': 'provider gave up', 'code': 502},
              })}\n\n',
        ]),
      );

      final reader =
          await model.stream([Message.user('hi')], options: _with(recorder));
      expect((await reader.recv()).content, 'a');
      await expectLater(reader.recv(), throwsA(isA<OpenRouterException>()));
      await reader.close();
      await recorder.streamDone.future;

      expect(recorder.timings, ['start', 'endStream']);
      expect(recorder.error, isA<OpenRouterException>());
    });

    test('without callbacks the stream is the provider\'s own', () async {
      final model = OpenRouterChatModel(
        config: _openRouter,
        httpClient: _streaming([
          _sse({'content': 'a'}, finish: 'stop'),
          'data: [DONE]\n\n',
        ]),
      );
      final reader = await model.stream([Message.user('hi')]);
      expect((await reader.collectAll()).single.content, 'a');
    });
  });

  group('OpenAIChatModel', () {
    const config = OpenAIConfig(apiKey: 'k', defaultModel: 'gpt-test');

    test('generate reports start and end', () async {
      final recorder = _Recorder();
      final model = OpenAIChatModel(config: config, httpClient: _completing('hi'));

      final answer =
          await model.generate([Message.user('q')], options: _with(recorder));

      expect(recorder.timings, ['start', 'end']);
      expect(recorder.infos.single.type, 'OpenAI');
      expect(recorder.input!.config!.model, 'gpt-test');
      expect(recorder.output!.message, same(answer));
      expect(recorder.output!.tokenUsage!.totalTokens, 10);
    });

    test('generate reports a failure', () async {
      final recorder = _Recorder();
      final model = OpenAIChatModel(config: config, httpClient: _failing(401));

      await expectLater(
        model.generate([Message.user('q')], options: _with(recorder)),
        throwsA(isA<OpenAIException>()),
      );
      expect(recorder.timings, ['start', 'error']);
    });

    test('stream gives the handler a copy', () async {
      final recorder = _Recorder();
      final model = OpenAIChatModel(
        config: config,
        httpClient: _streaming([
          _sse({'role': 'assistant', 'content': 'a'}),
          _sse({'content': 'b'}, finish: 'stop'),
          'data: [DONE]\n\n',
        ]),
      );

      final reader =
          await model.stream([Message.user('q')], options: _with(recorder));
      final text = (await reader.collectAll()).map((m) => m.content).join();
      await reader.close();
      await recorder.streamDone.future;

      expect(text, 'ab');
      expect(recorder.timings, ['start', 'endStream']);
      expect(
        recorder.chunks.map((c) => c!.message!.content).join(),
        'ab',
      );
    });
  });

  group('GeminiChatModel', () {
    const config = GeminiConfig(apiKey: 'k');
    final completion = jsonEncode({
      'candidates': [
        {
          'content': {
            'parts': [
              {'text': 'Hello from Gemini!'},
            ],
            'role': 'model',
          },
          'finishReason': 'STOP',
        },
      ],
      'usageMetadata': {
        'promptTokenCount': 5,
        'candidatesTokenCount': 10,
        'totalTokenCount': 15,
      },
    });

    test('generate reports start and end', () async {
      final recorder = _Recorder();
      final model = GeminiChatModel(
        config: config,
        httpClient: MockClient((request) async => http.Response(completion, 200)),
      );

      final answer =
          await model.generate([Message.user('q')], options: _with(recorder));

      expect(answer.content, 'Hello from Gemini!');
      expect(recorder.timings, ['start', 'end']);
      expect(recorder.infos.single.type, 'Gemini');
      expect(recorder.input!.config!.model, config.defaultModel);
      expect(recorder.output!.tokenUsage!.promptTokens, 5);
    });

    test('stream gives the handler a copy', () async {
      final recorder = _Recorder();
      final model = GeminiChatModel(
        config: config,
        httpClient: _streaming([
          'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}\n\n',
          'data: {"candidates":[{"content":{"parts":[{"text":"!"}]},'
              '"finishReason":"STOP"}]}\n\n',
        ]),
      );

      final reader =
          await model.stream([Message.user('q')], options: _with(recorder));
      final text = (await reader.collectAll()).map((m) => m.content).join();
      await reader.close();
      await recorder.streamDone.future;

      expect(text, 'Hello!');
      expect(recorder.timings, ['start', 'endStream']);
      expect(recorder.chunks.map((c) => c!.message!.content).join(), 'Hello!');
    });
  });

  test('the providers say what they are and that they fire their callbacks',
      () {
    final models = <Object, String>{
      OpenRouterChatModel(config: _openRouter): 'OpenRouter',
      OpenAIChatModel(config: const OpenAIConfig(apiKey: 'k')): 'OpenAI',
      GeminiChatModel(config: const GeminiConfig(apiKey: 'k')): 'Gemini',
    };
    for (final MapEntry(key: model, value: name) in models.entries) {
      expect(componentTypeNameOf(model), name);
      expect(isCallbacksEnabled(model), isTrue);
    }
    final bound = OpenRouterChatModel(config: _openRouter).withTools(const []);
    expect(componentTypeNameOf(bound), 'OpenRouter');
  });

  group('DefaultChatTemplate', () {
    final template = ChatTemplate.fromMessages(FormatType.fString, [
      Message.system('You are {role}.'),
      Message.user('{question}'),
    ]);

    test('fires its own callbacks with typed payloads', () async {
      final infos = <RunInfo>[];
      PromptCallbackInput? input;
      PromptCallbackOutput? output;
      final handler = CallbackHandlerBuilder()
          .onStart((ctx, info, payload) {
            infos.add(info);
            input = PromptCallbackInput.from(payload);
            return ctx;
          })
          .onEnd((ctx, info, payload) {
            output = PromptCallbackOutput.from(payload);
            return ctx;
          })
          .build();
      final variables = {'role': 'a poet', 'question': 'Why?'};

      final messages = await template.format(
        variables,
        options: ChatTemplateOptions(
          runContext: RunContext.background().withHandlers([handler]),
        ),
      );

      expect(isCallbacksEnabled(template), isTrue);
      expect(
        infos.single,
        const RunInfo(
          name: '',
          type: 'Default',
          componentType: ComponentType.promptTemplate,
        ),
      );
      expect(input!.variables, same(variables));
      expect(input!.templates, hasLength(2));
      expect(output!.result, messages);
      expect(output!.result.first.content, 'You are a poet.');
      expect(output!.templates, hasLength(2));
    });

    test('a template that cannot be rendered is reported and rethrown',
        () async {
      Object? reported;
      var ended = false;
      final handler = CallbackHandlerBuilder()
          .onError((ctx, info, error, stackTrace) {
            reported = error;
            return ctx;
          })
          .onEnd((ctx, info, output) {
            ended = true;
            return ctx;
          })
          .build();

      await expectLater(
        template.format(
          {'role': 'x'},
          options: ChatTemplateOptions(
            runContext: RunContext.background().withHandlers([handler]),
          ),
        ),
        throwsFormatException,
      );
      expect(reported, isFormatException);
      expect(ended, isFalse);
    });

    test('global handlers hear a template formatted without a context',
        () async {
      var starts = 0;
      GlobalCallbacks.append([
        CallbackHandlerBuilder().onStart((ctx, info, input) {
          starts++;
          return ctx;
        }).build(),
      ]);

      await template.format({'role': 'r', 'question': 'q'});
      expect(starts, 1);
    });
  });
}
