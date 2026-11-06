// Port of eino `components/model/agentic_callback_extra_test.go`
// (TestConvAgenticModel) and of the agentic case of
// `components/model/option_test.go` ("test agentic tool choice option"),
// v0.9.22.
//
// The other groups are not Go tests: they pin `ChatModelOptions
// .agenticToolChoice` (copyWith and merge, the counterpart of Go's
// functional option) and `AgenticModelCallCallbacks`, the helper agentic
// providers fire their callbacks with (the port of what eino-ext's agentic
// providers do around `Generate` and `Stream`).
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart'
    show CallbackContext, CallbackHandlerBuilder, GlobalCallbacks;
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/src/internal/agentic_model_call_callbacks.dart';

AgenticMessage _answer(String text, {TokenUsage? usage}) => AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [ContentBlock(AssistantGenText(text: text))],
      responseMeta: usage == null ? null : AgenticResponseMeta(tokenUsage: usage),
    );

/// Records every callback with its component type and payload.
final class _Recorder {
  final List<(String, RunInfo, Object?)> events = [];

  ComponentCallbackHandler get handler => CallbackHandlerBuilder()
      .onStart((ctx, info, input) {
        events.add(('start', info, input));
        return ctx;
      })
      .onEnd((ctx, info, output) {
        events.add(('end', info, output));
        return ctx;
      })
      .onError((ctx, info, error, stackTrace) {
        events.add(('error', info, error));
        return ctx;
      })
      .onEndWithStreamOutput((ctx, info, stream) async {
        final items = <Object?>[];
        while (true) {
          try {
            items.add(await stream.recv());
          } on StreamEOFException {
            break;
          }
        }
        await stream.close();
        events.add(('stream', info, items));
        return ctx;
      })
      .build();
}

/// An agentic provider that fires its own callbacks, like the providers of
/// eino-ext do.
final class _Provider implements AgenticModel, TypedComponent,
    CallbackAwareComponent {
  _Provider(this.answer);

  final AgenticMessage answer;

  @override
  String get componentTypeName => 'Fake';

  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) =>
      AgenticModelCallCallbacks.generate(
        options ?? const ChatModelOptions(),
        typeName: componentTypeName,
        input: input,
        defaultModel: 'fake-1',
        generate: () async => answer,
      );

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) =>
      AgenticModelCallCallbacks.stream(
        options ?? const ChatModelOptions(),
        typeName: componentTypeName,
        input: input,
        defaultModel: 'fake-1',
        stream: () async => StreamReader.fromIterable([answer]),
      );
}

void main() {
  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  test('TestConvAgenticModel', () {
    expect(
      AgenticModelCallbackInput.from(
        const AgenticModelCallbackInput(messages: []),
      ),
      isNotNull,
    );
    expect(AgenticModelCallbackInput.from(<AgenticMessage>[]), isNotNull);
    expect(AgenticModelCallbackInput.from('asd'), isNull);

    expect(
      AgenticModelCallbackOutput.from(const AgenticModelCallbackOutput()),
      isNotNull,
    );
    expect(
      AgenticModelCallbackOutput.from(
        AgenticMessage(role: AgenticRoleType.assistant),
      ),
      isNotNull,
    );
    expect(AgenticModelCallbackOutput.from('asd'), isNull);
  });

  group('agentic model payload conversion: beyond Go', () {
    test('a list holding only agentic messages is an input', () {
      final input =
          AgenticModelCallbackInput.from(<Object?>[AgenticMessage.user('x')]);
      expect(input!.messages, hasLength(1));
      expect(input.tools, isNull);
      expect(AgenticModelCallbackInput.from(<Object?>[1]), isNull);
      expect(AgenticModelCallbackInput.from([Message.user('x')]), isNull);
    });

    test('a message as output carries its token usage', () {
      const usage = TokenUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3);
      final output = AgenticModelCallbackOutput.from(
        _answer('x', usage: usage),
      );
      expect(output!.tokenUsage, usage);
      expect(output.message!.contentBlocks.single.assistantGenText!.text, 'x');
      expect(output.config, isNull);
    });

    test('a typed payload is returned as it is', () {
      const input = AgenticModelCallbackInput(messages: []);
      expect(identical(AgenticModelCallbackInput.from(input), input), isTrue);
      const output = AgenticModelCallbackOutput();
      expect(identical(AgenticModelCallbackOutput.from(output), output), isTrue);
    });

    test('the config of a call comes from its options', () {
      final config = AgenticModelCallbackConfig.fromOptions(
        const ChatModelOptions(maxTokens: 7, temperature: 0.2, topP: 0.9),
        defaultModel: 'base',
      );
      expect(config.model, 'base');
      expect(config.maxTokens, 7);
      expect(config.temperature, 0.2);
      expect(config.topP, 0.9);
      expect(
        AgenticModelCallbackConfig.fromOptions(
          const ChatModelOptions(model: 'chosen'),
          defaultModel: 'base',
        ).model,
        'chosen',
      );
      expect(AgenticModelCallbackConfig.fromOptions(null).model, isNull);
    });
  });

  group('ChatModelOptions.agenticToolChoice', () {
    test('test agentic tool choice option', () {
      const toolChoice = ToolChoice.forced;
      final allowedTools = [const AllowedFunctionTool('agentic_tool')];
      final opts = const ChatModelOptions().merge(
        ChatModelOptions(
          agenticToolChoice: AgenticToolChoice(
            type: toolChoice,
            forced: AgenticForcedToolChoice(tools: allowedTools),
          ),
        ),
      );

      expect(opts.agenticToolChoice, isNotNull);
      expect(opts.agenticToolChoice!.type, toolChoice);
      expect(opts.agenticToolChoice!.forced, isNotNull);
      expect(opts.agenticToolChoice!.forced!.tools, allowedTools);
    });

    test('merge keeps a choice the other options leave out', () {
      const choice = AgenticToolChoice(type: ToolChoice.forbidden);
      const base = ChatModelOptions(agenticToolChoice: choice);
      expect(
        base.merge(const ChatModelOptions(temperature: 1)).agenticToolChoice,
        choice,
      );
      const other = AgenticToolChoice(type: ToolChoice.allowed);
      expect(
        base
            .merge(const ChatModelOptions(agenticToolChoice: other))
            .agenticToolChoice,
        other,
      );
      expect(base.merge(null).agenticToolChoice, choice);
    });

    test('copyWith replaces or keeps it', () {
      const choice = AgenticToolChoice(type: ToolChoice.forbidden);
      const base = ChatModelOptions(agenticToolChoice: choice);
      expect(base.copyWith(maxTokens: 3).agenticToolChoice, choice);
      const other = AgenticToolChoice(type: ToolChoice.forced);
      expect(base.copyWith(agenticToolChoice: other).agenticToolChoice, other);
      expect(const ChatModelOptions().agenticToolChoice, isNull);
    });
  });

  group('AgenticModelCallCallbacks', () {
    final input = [AgenticMessage.user('hi')];

    test('generate reports the start and the end', () async {
      final recorder = _Recorder();
      final tools = [ToolInfo.function(name: 'search')];
      final ctx = RunContext.background().withHandlers([recorder.handler]);
      const usage = TokenUsage(promptTokens: 2, completionTokens: 3, totalTokens: 5);

      final message = await AgenticModelCallCallbacks.generate(
        ChatModelOptions(runContext: ctx, tools: tools, temperature: 0.3),
        typeName: 'Fake',
        input: input,
        defaultModel: 'fake-1',
        outputExtra: (message) => {'seen': true},
        generate: () async => _answer('hello', usage: usage),
      );
      expect(message.contentBlocks.single.assistantGenText!.text, 'hello');

      expect(recorder.events.map((e) => e.$1), ['start', 'end']);
      final info = recorder.events.first.$2;
      expect(info.componentType, ComponentType.agenticModel);
      expect(info.type, 'Fake');

      final start = recorder.events.first.$3! as AgenticModelCallbackInput;
      expect(start.messages, same(input));
      expect(start.tools, same(tools));
      expect(start.config!.model, 'fake-1');
      expect(start.config!.temperature, 0.3);

      final end = recorder.events.last.$3! as AgenticModelCallbackOutput;
      expect(end.message, same(message));
      expect(end.tokenUsage, usage);
      expect(end.config!.model, 'fake-1');
      expect(end.extra, {'seen': true});
    });

    test('generate reports an error and rethrows it', () async {
      final recorder = _Recorder();
      final ctx = RunContext.background().withHandlers([recorder.handler]);
      final failure = StateError('down');

      await expectLater(
        AgenticModelCallCallbacks.generate(
          ChatModelOptions(runContext: ctx),
          typeName: 'Fake',
          input: input,
          generate: () async => throw failure,
        ),
        throwsA(same(failure)),
      );
      expect(recorder.events.map((e) => e.$1), ['start', 'error']);
      expect(recorder.events.last.$3, same(failure));
    });

    test('without handlers the call just runs', () async {
      var calls = 0;
      final message = await AgenticModelCallCallbacks.generate(
        const ChatModelOptions(),
        typeName: 'Fake',
        input: input,
        generate: () async {
          calls++;
          return _answer('plain');
        },
      );
      expect(calls, 1);
      expect(message.contentBlocks.single.assistantGenText!.text, 'plain');

      final reader = await AgenticModelCallCallbacks.stream(
        ChatModelOptions(runContext: RunContext.background()),
        typeName: 'Fake',
        input: input,
        stream: () async => StreamReader.fromIterable([_answer('s')]),
      );
      expect(await reader.collectAll(), hasLength(1));
    });

    test('global handlers hear a call without a run context', () async {
      final recorder = _Recorder();
      GlobalCallbacks.append([recorder.handler]);
      await AgenticModelCallCallbacks.generate(
        const ChatModelOptions(),
        typeName: 'Fake',
        input: input,
        generate: () async => _answer('global'),
      );
      expect(recorder.events.map((e) => e.$1), ['start', 'end']);
      expect(recorder.events.first.$2.componentType, ComponentType.agenticModel);
    });

    test('stream hands every chunk to the handlers and the caller', () async {
      final recorder = _Recorder();
      final ctx = RunContext.background().withHandlers([recorder.handler]);
      final chunks = [
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [
            ContentBlock(
              const AssistantGenText(text: 'a'),
              streamingMeta: const StreamingMeta(index: 0),
            ),
          ],
        ),
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [
            ContentBlock(
              const AssistantGenText(text: 'b'),
              streamingMeta: const StreamingMeta(index: 0),
            ),
          ],
          responseMeta: const AgenticResponseMeta(
            tokenUsage: TokenUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3),
          ),
        ),
      ];

      final reader = await AgenticModelCallCallbacks.stream(
        ChatModelOptions(runContext: ctx),
        typeName: 'Fake',
        input: input,
        stream: () async => StreamReader.fromIterable(chunks),
      );
      final received = await reader.collectAll();
      expect(received, chunks);

      // The handler reads its copy in the background.
      await pumpEventQueue();
      expect(recorder.events.map((e) => e.$1), ['start', 'stream']);
      final items = recorder.events.last.$3! as List<Object?>;
      expect(items, hasLength(2));
      final last = items.last! as AgenticModelCallbackOutput;
      expect(last.message, chunks.last);
      expect(last.tokenUsage, const TokenUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3));
    });

    test('a stream that fails to start is reported as an error', () async {
      final recorder = _Recorder();
      final ctx = RunContext.background().withHandlers([recorder.handler]);
      final failure = StateError('no stream');
      await expectLater(
        AgenticModelCallCallbacks.stream(
          ChatModelOptions(runContext: ctx),
          typeName: 'Fake',
          input: input,
          stream: () async => throw failure,
        ),
        throwsA(same(failure)),
      );
      expect(recorder.events.map((e) => e.$1), ['start', 'error']);
    });

    test('a provider that fires its callbacks is reported once in a graph',
        () async {
      final recorder = _Recorder();
      final graph = Graph<List<AgenticMessage>, AgenticMessage>()
        ..addAgenticModelNode('model', _Provider(_answer('from provider')))
        ..addEdge(Graph.start, 'model')
        ..addEdge('model', Graph.end);
      final runnable = await graph.compile(RunContext.background());
      await runnable.invoke(
        RunContext.background(),
        input,
        options: [
          CallOption.callbacks([recorder.handler]),
        ],
      );
      final model = recorder.events
          .where((e) => e.$2.componentType == ComponentType.agenticModel)
          .toList();
      expect(model.map((e) => e.$1), ['start', 'end']);
      expect(model.first.$2.type, 'Fake');
      expect(model.first.$3, isA<AgenticModelCallbackInput>());
      expect(
        (model.last.$3! as AgenticModelCallbackOutput).config!.model,
        'fake-1',
      );
    });
  });
}
