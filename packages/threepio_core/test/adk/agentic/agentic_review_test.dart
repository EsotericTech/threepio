// Tests added by the review of the agentic ADK (P13, group A): eino
// behaviours of `adk/chatmodel.go`, `adk/react.go`, `adk/wrappers.go` and
// `adk/agent_tool.go` that the ported Go tests do not reach on the agentic
// path.
//   * The return-directly event kept in the agentic state is sent after a
//     resume (agentic twin of eino `TestReturnDirectlyEventSentAfterResume`,
//     `adk/interrupt_test.go`), also when it is a recorded stream.
//   * A run cancelled at the `afterChatModel` safe point resumes from the
//     model message the `CancelCheck` node saved (`newAgenticReact`).
//   * Model outputs and tool results share their message ids with the
//     agent's state, also when streaming (`typedStateModelWrapper`,
//     `typedEventSenderToolWrapper`, the `AfterToolCalls` node).
//   * `AfterModelRewriteState` decides what the graph goes on with, not what
//     the event shows; `BeforeModelRewriteState` tool infos are kept.
//   * A classic `AgentTool` inside an agentic agent (eino's typed tool event
//     generator does not reach an agent of the other message type).
//   * The callbacks of a model that does not report them itself
//     (`typedCallbackInjectedModel`: raw input and output).
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

import 'agentic_fakes.dart';

/// The first call asks for a `returnDirectly` tool and an interrupting tool
/// at once; later calls answer.
class _TwoToolModel implements AgenticModel {
  int calls = 0;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    if (++calls == 1) {
      return AgenticMessage(
        role: AgenticRoleType.assistant,
        contentBlocks: [
          ContentBlock(
            const FunctionToolCall(
              name: 'direct',
              callId: 'call_direct',
              arguments: '{}',
            ),
          ),
          ContentBlock(
            const FunctionToolCall(
              name: 'approval',
              callId: 'call_approval',
              arguments: '{}',
            ),
          ),
        ],
      );
    }
    return agenticMsg('final response');
  }

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

/// A tool that streams `a`, `b`, `c`, one at a time.
class _StreamingTool extends StreamableTool {
  _StreamingTool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.fromParams(name: name, desc: 'streams', params: const {});

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final (reader, writer) = pipe<String>();
    unawaited(() async {
      for (final part in ['a', 'b', 'c']) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        writer.send(part);
      }
      await writer.close();
    }());
    return reader;
  }
}

class _Middleware extends AgenticChatModelAgentMiddleware {
  _Middleware({this.before, this.after, this.onAfterAgent});

  final void Function(AgenticChatModelAgentState state)? before;
  final void Function(AgenticChatModelAgentState state)? after;
  final void Function(AgenticChatModelAgentState state)? onAfterAgent;

  @override
  FutureOr<(RunContext, AgenticChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    AgenticChatModelAgentState state,
    AgenticModelContext model,
  ) {
    before?.call(state);
    return (ctx, state);
  }

  @override
  FutureOr<(RunContext, AgenticChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    AgenticChatModelAgentState state,
    AgenticModelContext model,
  ) {
    after?.call(state);
    return (ctx, state);
  }

  @override
  FutureOr<RunContext> afterAgent(
    RunContext ctx,
    AgenticChatModelAgentState state,
  ) {
    onAfterAgent?.call(state);
    return ctx;
  }
}

class _ClassicModel extends BaseChatModel {
  _ClassicModel(this.answer);

  final Message Function(List<Message> input) answer;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      answer(input);

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([answer(input)]);
}

/// The text parts of the function tool result [message] carries, as
/// `name:text`, or `null` when it carries none.
String? _toolResultOf(AgenticMessage message) {
  final result = message.contentBlocks.firstOrNull?.functionToolResult;
  if (result == null) return null;
  final text = [
    for (final part in result.content)
      if (part.content case final UserInputText t) t.text,
  ].join();
  return '${result.name}:$text';
}

AgenticChatModelAgent _returnDirectlyAgent(AgenticModel model, BaseTool direct) =>
    AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'rd',
      description: 'return directly + interrupt',
      model: model,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(
          tools: [direct, AgenticInterruptTool('approval')],
        ),
        returnDirectly: const {'direct'},
      ),
    ));

/// Runs [runner] until it interrupts, resumes the interrupt with `ok`, and
/// returns the events of the resumed run.
Future<List<AgenticAgentEvent>> _interruptAndResume(
  AgenticRunner runner,
  RunContext ctx,
) async {
  final events = await drainAgenticEvents(
    runner.query(ctx, 'go', options: [AgentRunOption.checkpointId('cp')]),
  );
  expect(firstAgenticEventError(events), isNull);
  final interrupted = findInterruptEvent(events)!.action!.interrupted!;
  expect(
    interrupted.interruptContexts.single.address.segments.last.id,
    'approval',
  );
  final resumed = await drainAgenticEvents(
    await runner.resumeWithParams(
      ctx,
      'cp',
      ResumeParams(targets: {interrupted.interruptContexts.single.id: 'ok'}),
    ),
  );
  expect(firstAgenticEventError(resumed), isNull);
  return resumed;
}

void main() {
  final ctx = RunContext.background();

  group('TestReturnDirectlyEventSentAfterResume (agentic)', () {
    for (final streaming in [false, true]) {
      test('streaming: $streaming', () async {
        final model = _TwoToolModel();
        final runner = AgenticRunner(
          agent: _returnDirectlyAgent(model, AgenticEchoTool('direct')),
          checkpointStore: InMemoryCheckpointStore(),
          enableStreaming: streaming,
        );
        final resumed = await _interruptAndResume(runner, ctx);
        final results = [
          for (final event in resumed)
            _toolResultOf(await event.output!.messageOutput!.getMessage()),
        ];
        // The resumed tool's event, then the return-directly event kept in
        // the state since the first run; the model is not asked again.
        expect(results, ['approval:approved:ok', 'direct:echo:{}']);
        expect(resumed.last.agentName, 'rd');
        expect(model.calls, 1);
      });
    }

    test('a streamed return-directly event survives the checkpoint', () async {
      final model = _TwoToolModel();
      final runner = AgenticRunner(
        agent: _returnDirectlyAgent(model, _StreamingTool('direct')),
        checkpointStore: InMemoryCheckpointStore(),
        enableStreaming: true,
      );
      final resumed = await _interruptAndResume(runner, ctx);
      final last = resumed.last.output!.messageOutput!;
      // Written as its joined message, it comes back as a stream of it (eino
      // `gobDecodeAgenticMessageVariant`).
      expect(last.isStreaming, isTrue);
      expect(last.agenticRole, AgenticRoleType.user);
      expect(_toolResultOf(await last.getMessage()), 'direct:abc');
      expect(model.calls, 1);
    });
  });

  test('a run cancelled at afterChatModel resumes from the saved model '
      'message', () async {
    final (cancelOption, cancel) = withCancel();
    var modelCalls = 0;
    final toolArgs = <String>[];
    final model = MockAgenticModel(
      onGenerate: (_, __) async {
        switch (++modelCalls) {
          case 1:
            return agenticToolCallMsg('capture', 'c1', '"first"');
          case 2:
            // The cancel takes effect at the safe point after this call.
            cancel(safePoints: {CancelSafePoint.afterChatModel});
            return agenticToolCallMsg('capture', 'c2', '"second"');
          default:
            return agenticMsg('done');
        }
      },
    );
    final store = InMemoryCheckpointStore();
    final runner = AgenticRunner(
      agent: AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'cc',
        description: 'cancel then resume',
        model: model,
        toolsConfig: ToolsConfig(
          toolsNode: ToolsNodeConfig(
            tools: [
              AgenticArgCaptureTool('capture', (args) {
                toolArgs.add(args);
                return 'got $args';
              }),
            ],
          ),
        ),
      )),
      checkpointStore: store,
    );

    final events = await drainAgenticEvents(
      runner.query(
        ctx,
        'go',
        options: [AgentRunOption.checkpointId('cc-cp'), cancelOption],
      ),
    );
    final cancelled = ThreepioException.findCause<AgentRunCancelledException>(
      firstAgenticEventError(events),
    );
    expect(cancelled, isNotNull);
    expect(cancelled!.interruptContexts.single.info, 'CancelAfterChatModel');
    expect(modelCalls, 2);
    expect(toolArgs, ['"first"']);

    final resumed =
        await drainAgenticEvents(await runner.resume(ctx, 'cc-cp'));
    expect(firstAgenticEventError(resumed), isNull);
    // The second tool call came from the checkpoint, not from a new model
    // call: one more call answers.
    expect(modelCalls, 3);
    expect(toolArgs, ['"first"', '"second"']);
    expect(
      [
        for (final event in resumed)
          _toolResultOf(event.output!.messageOutput!.message!) ??
              agenticTextContent(event.output!.messageOutput!.message),
      ],
      ['capture:got "second"', 'done'],
    );
  });

  test('streamed model outputs and tool results share their ids with the '
      'state', () async {
    var call = 0;
    final model = MockAgenticModel(
      onStream: (_, __) async => ++call == 1
          ? StreamReader.fromIterable([agenticToolCallMsg('echo', 'c1', '"x"')])
          : StreamReader.fromIterable([agenticMsg('a'), agenticMsg('b')]),
    );
    List<AgenticMessage>? state;
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'ids',
      model: model,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [AgenticEchoTool('echo')]),
      ),
      handlers: [_Middleware(onAfterAgent: (s) => state = s.messages)],
    ));
    final events = await drainAgenticEvents(
      AgenticRunner(agent: agent, enableStreaming: true).query(ctx, 'hi'),
    );
    expect(events, hasLength(3));
    final eventIds = [
      for (final event in events)
        agenticMessageIdOf(await event.output!.messageOutput!.getMessage()),
    ];
    expect(eventIds.toSet(), hasLength(3));
    expect(eventIds, everyElement(isNotEmpty));
    // user, model (tool call), tool result, model (answer).
    expect(
      [for (final message in state!.skip(1)) agenticMessageIdOf(message)],
      eventIds,
    );
  });

  test('afterModelRewriteState decides what the graph goes on with, not what '
      'the event shows', () async {
    final model = SequentialAgenticModel([
      agenticToolCallMsg('echo', 'c1', '"x"'),
    ]);
    final echo = SlowTool('echo', 'unused');
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'rewrite',
      model: model,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [echo])),
      handlers: [
        _Middleware(
          after: (state) => state.messages = [
            ...state.messages.take(state.messages.length - 1),
            agenticMsg('rewritten'),
          ],
        ),
      ],
    ));
    final events = await drainAgenticEvents(
      AgenticRunner(agent: agent).query(ctx, 'hi'),
    );
    // The event is the model's own message; the rewritten answer has no tool
    // calls, so the run ends there.
    expect(firstAgenticEventError(events), isNull);
    expect(events, hasLength(1));
    expect(
      events.single.output!.messageOutput!.message!.contentBlocks.single
          .functionToolCall!.callId,
      'c1',
    );
    expect(echo.callCount, 0);
    expect(model.callCount, 1);
  });

  test('tool infos a beforeModelRewriteState hook leaves are kept for later '
      'calls', () async {
    final seen = <List<String>>[];
    var call = 0;
    final model = MockAgenticModel(
      onGenerate: (_, options) async {
        seen.add([for (final tool in options?.tools ?? const <ToolInfo>[]) tool.name]);
        return ++call == 1
            ? agenticToolCallMsg('echo', 'c1', '"x"')
            : agenticMsg('done');
      },
    );
    var first = true;
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'tools',
      model: model,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(
          tools: [AgenticEchoTool('echo'), AgenticEchoTool('other')],
        ),
      ),
      handlers: [
        _Middleware(
          before: (state) {
            if (!first) return;
            first = false;
            state.toolInfos = [
              for (final info in state.toolInfos)
                if (info.name == 'echo') info,
            ];
          },
        ),
      ],
    ));
    final events = await drainAgenticEvents(
      AgenticRunner(agent: agent).query(ctx, 'hi'),
    );
    expect(firstAgenticEventError(events), isNull);
    expect(seen, [
      ['echo'],
      ['echo'],
    ]);
  });

  test('the afterToolCallsHook runs after every tool turn, before the next '
      'model call, and its failure fails the run', () async {
    final log = <String>[];
    final model = MockAgenticModel(
      onGenerate: (input, _) async {
        log.add('model(${input.length})');
        return switch (log.where((e) => e.startsWith('model')).length) {
          1 => agenticToolCallMsg('echo', 'c1', '"1"'),
          2 => agenticToolCallMsg('echo', 'c2', '"2"'),
          _ => agenticMsg('done'),
        };
      },
    );
    AgenticChatModelAgent agent() => AgenticChatModelAgent(
          AgenticChatModelAgentConfig(
            name: 'hook',
            model: model,
            toolsConfig: ToolsConfig(
              toolsNode: ToolsNodeConfig(tools: [AgenticEchoTool('echo')]),
            ),
          ),
        );
    final events = await drainAgenticEvents(
      AgenticRunner(agent: agent()).query(
        ctx,
        'hi',
        options: [AgentRunOption.afterToolCallsHook((ctx) => log.add('hook'))],
      ),
    );
    expect(firstAgenticEventError(events), isNull);
    // The model sees the tool result the hook ran after: user, call, result.
    expect(log, ['model(1)', 'hook', 'model(3)', 'hook', 'model(5)']);

    log.clear();
    final failed = await drainAgenticEvents(
      AgenticRunner(agent: agent()).query(
        ctx,
        'hi',
        options: [
          AgentRunOption.afterToolCallsHook(
            (ctx) => throw const ThreepioException('hook failed'),
          ),
        ],
      ),
    );
    expect('${firstAgenticEventError(failed)}', contains('hook failed'));
    expect(log, ['model(1)']);
  });

  group('a classic AgentTool inside an agentic agent', () {
    for (final streaming in [false, true]) {
      test('streaming: $streaming', () async {
        final classic = ChatModelAgent(ChatModelAgentConfig(
          name: 'classic',
          description: 'classic helper',
          model: _ClassicModel(
            (input) => Message.assistant('classic says ${input.last.content}'),
          ),
        ));
        final outer = AgenticChatModelAgent(AgenticChatModelAgentConfig(
          name: 'outer',
          description: 'agentic caller',
          model: SequentialAgenticModel([
            agenticToolCallMsg('classic', 'c1', '{"request":"hey"}'),
            agenticMsg('outer done'),
          ]),
          toolsConfig: ToolsConfig(
            toolsNode: ToolsNodeConfig(tools: [AgentTool(classic)]),
            emitInternalEvents: true,
          ),
        ));
        final events = await drainAgenticEvents(
          AgenticRunner(agent: outer, enableStreaming: streaming)
              .query(ctx, 'go'),
        );
        final seen = <String>[];
        for (final event in events) {
          expect(event.error, isNull);
          final message = await event.output!.messageOutput!.getMessage();
          seen.add(
            _toolResultOf(message) ??
                '${event.agentName}:${agenticTextContent(message)}',
          );
        }
        // The classic agent's own events are not passed on: eino's tool
        // event generator is typed by the caller's message type.
        expect(seen, ['outer:', 'classic:classic says hey', 'outer:outer done']);
      });
    }
  });

  test('a model without its own callbacks reports its raw input and output',
      () async {
    final starts = <(RunInfo, Object?)>[];
    final ends = <(RunInfo, Object?)>[];
    final handler = CallbackHandlerBuilder()
        .onStart((ctx, info, input) {
          if (info.componentType == ComponentType.agenticModel) {
            starts.add((info, input));
          }
          return ctx;
        })
        .onEnd((ctx, info, output) {
          if (info.componentType == ComponentType.agenticModel) {
            ends.add((info, output));
          }
          return ctx;
        })
        .build();
    final answer = agenticMsg('hi');
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'cb',
      instruction: 'be brief',
      model: MockAgenticModel(onGenerate: (_, __) async => answer),
    ));
    await drainAgenticEvents(
      AgenticRunner(agent: agent).query(
        ctx,
        'hello',
        options: [AgentRunOption.callbacks([handler])],
      ),
    );
    expect(starts, hasLength(1));
    final (startInfo, input) = starts.single;
    expect(startInfo.type, 'MockAgenticModel');
    expect(input, isA<List<AgenticMessage>>());
    expect(
      [for (final m in input! as List<AgenticMessage>) m.role],
      [AgenticRoleType.system, AgenticRoleType.user],
    );
    expect(ends, hasLength(1));
    // The callbacks see the model's answer, before the agent gives it an id.
    expect(ends.single.$2, same(answer));
  });
}
