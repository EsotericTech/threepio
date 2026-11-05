// Port of eino v0.9.22 `adk/interrupt_test.go`.
//
// Ported Go tests: TestSimpleInterrupt, TestChatModelAgentToolInterrupt,
// TestChatModelInterrupt, TestChatModelParallelToolInterruptAndResume,
// TestReturnDirectlyEventSentAfterResume,
// TestNestedChatModelAgentWithAgentTool.
//
// Plus one test of this file's own: a custom ResumableAgent that interrupts
// with statefulInterruptEvent and is resumed through the runner's checkpoint.
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

/// A custom agent made of closures. Port of the Go test's `myAgent`.
class _MyAgent implements ResumableAgent {
  _MyAgent({required this.runFn, required this.resumeFn, String? name})
      : _name = name;

  final String? _name;
  final StreamReader<AgentEvent> Function(
    RunContext ctx,
    AgentInput input,
    List<AgentRunOption> options,
  ) runFn;
  final StreamReader<AgentEvent> Function(
    RunContext ctx,
    ResumeInfo info,
    List<AgentRunOption> options,
  ) resumeFn;

  @override
  String get name => _name ?? 'myAgent';

  @override
  String get description => 'myAgent description';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      runFn(ctx, input, options);

  @override
  StreamReader<AgentEvent> resume(
    RunContext ctx,
    ResumeInfo info, {
    List<AgentRunOption> options = const [],
  }) =>
      resumeFn(ctx, info, options);
}

/// A model that answers with [messages] in turn and checks its input with
/// [validator]. Port of the Go test's `myModel` (whose `Stream` panics).
class _MyModel extends ToolCallingChatModel {
  _MyModel(this.messages, {this.validator});

  final List<Message> messages;
  final bool Function(int i, List<Message> messages)? validator;
  int times = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    if (validator != null && !validator!(times, input)) {
      throw const ThreepioException('invalid input');
    }
    if (times >= messages.length) {
      throw const ThreepioException('exceeded max number of messages');
    }
    return messages[times++];
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) =>
      throw UnimplementedError('implement me');

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

/// Port of the Go test's `myTool1`.
class _MyTool1 extends InvokableTool {
  @override
  Future<ToolInfo> info() async =>
      ToolInfo.function(name: 'tool1', description: 'desc');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    if (!getInterruptState<Object>(ctx).wasInterrupted) {
      throw interrupt(ctx, null);
    }
    final resume = getResumeContext<String>(ctx);
    if (!resume.isResumeTarget) throw interrupt(ctx, null);
    if (resume.hasData) return resume.data!;
    return 'result';
  }
}

/// Port of the Go test's `myStatefulToolState`.
class _StatefulToolState {
  const _StatefulToolState(this.interruptCount);

  factory _StatefulToolState.fromJson(Map<String, Object?> json) =>
      _StatefulToolState(json['InterruptCount']! as int);

  final int interruptCount;

  Map<String, Object?> toJson() => {'InterruptCount': interruptCount};
}

/// Port of the Go test's `myStatefulTool`. The Go tool asserts inside
/// `InvokableRun` that it has its state on a re-interrupt; this one records
/// it in [hasStateOnReInterrupt] for the test to check.
class _MyStatefulTool extends InvokableTool {
  _MyStatefulTool(this.name);

  final String name;
  final List<bool> hasStateOnReInterrupt = [];

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.function(name: name, description: 'desc');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final saved = getInterruptState<_StatefulToolState>(ctx);
    if (!saved.wasInterrupted) {
      throw statefulInterrupt(
        ctx,
        'interrupt from $name',
        const _StatefulToolState(1),
      );
    }
    final resume = getResumeContext<String>(ctx);
    if (!resume.isResumeTarget || !resume.hasData) {
      hasStateOnReInterrupt.add(saved.hasState);
      throw statefulInterrupt(
        ctx,
        'interrupt from $name',
        _StatefulToolState((saved.state?.interruptCount ?? 0) + 1),
      );
    }
    return resume.data!;
  }
}

/// Port of the Go test's `returnDirectlyTool`.
class _ReturnDirectlyTool extends InvokableTool {
  _ReturnDirectlyTool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.function(name: name, description: 'A tool that returns directly');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      'return directly result';
}

/// Port of the Go test's `interruptingTool`.
class _InterruptingTool extends InvokableTool {
  _InterruptingTool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.function(name: name, description: 'A tool that interrupts');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    if (!getInterruptState<Object>(ctx).wasInterrupted) {
      throw interrupt(ctx, 'interrupt data');
    }
    final resume = getResumeContext<String>(ctx);
    if (resume.isResumeTarget && resume.hasData) return resume.data!;
    return 'resumed without data';
  }
}

/// Port of the Go test's `dynamicTool`.
class _DynamicTool extends InvokableTool {
  _DynamicTool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.function(name: name, description: 'A dynamically added tool');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      'dynamic tool result';
}

/// Port of the Go test's `twoToolCallModel`: the first call asks for both
/// tools, later calls answer. Records the tools of the model options.
class _TwoToolCallModel extends ToolCallingChatModel {
  _TwoToolCallModel({
    required this.returnDirectlyToolName,
    required this.interruptingToolName,
  });

  final String returnDirectlyToolName;
  final String interruptingToolName;
  int callCount = 0;
  List<ToolInfo>? receivedTools;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    callCount++;
    if (options?.tools != null) receivedTools = options!.tools;
    if (callCount == 1) {
      return Message(
        role: RoleType.assistant,
        content: '',
        toolCalls: [
          ToolCall(
            id: 'call_return_directly',
            function: FunctionCall(name: returnDirectlyToolName, arguments: '{}'),
          ),
          ToolCall(
            id: 'call_interrupting',
            function: FunctionCall(name: interruptingToolName, arguments: '{}'),
          ),
        ],
      );
    }
    return Message.assistant('final response');
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) =>
      throw UnimplementedError('not implemented');

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

/// Port of the Go test's `interruptTestToolsHandler`: adds [tools] in
/// `BeforeAgent`.
class _InterruptTestToolsHandler extends ChatModelAgentMiddleware {
  _InterruptTestToolsHandler(this.tools);

  final List<BaseTool> tools;

  @override
  (RunContext, ChatModelAgentContext) beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) {
    agent.tools = [...agent.tools, ...tools];
    return (ctx, agent);
  }
}

/// The state of the custom resumable agent of this file's own test.
class _CustomAgentState {
  const _CustomAgentState({required this.step, required this.note});

  factory _CustomAgentState.fromJson(Map<String, Object?> json) =>
      _CustomAgentState(
        step: json['step']! as int,
        note: json['note']! as String,
      );

  final int step;
  final String note;

  Map<String, Object?> toJson() => {'step': step, 'note': note};
}

/// [event], an interrupt event, with `Interrupted.Data` set to [data]: what
/// the Go tests do with `intEvent.Action.Interrupted.Data = data` (events are
/// immutable here).
AgentEvent _withInterruptData(AgentEvent event, Object? data) {
  final action = event.action!;
  return event.copyWith(
    action: AgentAction.interruptedBy(
      AgentInterruptInfo(
        data: data,
        interruptContexts: action.interrupted!.interruptContexts,
      ),
      action.interruptSignal!,
    ),
  );
}

/// Port of the Go test's `consumeUntilInterrupt`.
Future<(List<AgentEvent>, AgentEvent?)> _consumeUntilInterrupt(
  StreamReader<AgentEvent> iter,
) async {
  final normal = <AgentEvent>[];
  AgentEvent? interrupted;
  for (var event = await iter.nextOrNull();
      event != null;
      event = await iter.nextOrNull()) {
    if (event.action?.interrupted != null) {
      interrupted = event;
      continue;
    }
    normal.add(event);
  }
  return (normal, interrupted);
}

AddressSegment _agent(String id) =>
    AddressSegment(type: addressSegmentAgent, id: id);

AddressSegment _tool(String id, String callId) =>
    AddressSegment(type: addressSegmentTool, id: id, subId: callId);

ToolCall _call(String id, String name, String arguments) =>
    ToolCall(id: id, function: FunctionCall(name: name, arguments: arguments));

void main() {
  setUpAll(() {
    TypeRegistry.registerName<_StatefulToolState>(
      'eino_interrupt_test.myStatefulToolState',
      fromJson: _StatefulToolState.fromJson,
      toJson: (state) => state.toJson(),
    );
    TypeRegistry.registerName<_CustomAgentState>(
      'eino_interrupt_test.customAgentState',
      fromJson: _CustomAgentState.fromJson,
      toJson: (state) => state.toJson(),
    );
  });

  test('TestSimpleInterrupt', () async {
    const data = 'hello world';
    final resumeInfos = <ResumeInfo>[];
    final agent = _MyAgent(
      runFn: (ctx, input, options) => StreamReader<AgentEvent>.fromIterable([
        AgentEvent(
          output: AgentOutput(
            messageOutput: MessageVariant.stream(
              StreamReader<Message>.fromIterable([
                Message.user('hello '),
                Message.user('world'),
              ]),
            ),
          ),
        ),
        _withInterruptData(interruptEvent(ctx, data), data),
      ]),
      resumeFn: (ctx, info, options) {
        resumeInfos.add(info);
        return StreamReader<AgentEvent>.fromIterable(const []);
      },
    );
    final store = InMemoryCheckpointStore();
    final ctx = RunContext.background();
    final runner =
        Runner(agent: agent, enableStreaming: true, checkpointStore: store);
    final iter =
        runner.query(ctx, 'hello world', options: [AgentRunOption.checkpointId('1')]);
    expect(await iter.nextOrNull(), isNotNull);
    final interrupted = await iter.nextOrNull();
    expect(interrupted, isNotNull);
    final info = interrupted!.action!.interrupted!;
    expect(info.data, data);
    expect(info.interruptContexts[0].id, isNotEmpty);
    expect(info.interruptContexts[0].isRootCause, isTrue);
    expect(info.interruptContexts[0].info, data);
    expect(info.interruptContexts[0].address, Address([_agent('myAgent')]));
    expect(await iter.nextOrNull(), isNull);

    final resumed = await runner.resumeWithParams(
      ctx,
      '1',
      ResumeParams(targets: {info.interruptContexts[0].id: null}),
    );
    expect(await resumed.nextOrNull(), isNull);

    // The Go resumeFn asserts these (run here, outside the agent).
    final resumeInfo = resumeInfos.single;
    expect(resumeInfo.wasInterrupted, isTrue);
    expect(resumeInfo.interruptState, isNull);
    expect(resumeInfo.enableStreaming, isTrue);
    // Go also checks `info.Data` (the deprecated embedded InterruptInfo),
    // which is not ported.
    expect(resumeInfo.isResumeTarget, isTrue);
  });

  test('TestChatModelAgentToolInterrupt', () async {
    final resumeInfos = <ResumeInfo>[];
    final sa = _MyAgent(
      runFn: (ctx, input, options) => StreamReader<AgentEvent>.fromIterable([
        _withInterruptData(interruptEvent(ctx, 'hello world'), 'hello world'),
      ]),
      resumeFn: (ctx, info, options) {
        resumeInfos.add(info);
        if (!info.isResumeTarget) {
          return StreamReader<AgentEvent>.fromIterable([
            _withInterruptData(
              interruptEvent(ctx, 'interrupt again'),
              'interrupt again',
            ),
          ]);
        }
        return StreamReader<AgentEvent>.fromIterable([
          AgentEvent(
            output: AgentOutput(
              messageOutput: MessageVariant.message(
                Message.user('my agent completed with data ${info.resumeData}'),
              ),
            ),
          ),
        ]);
      },
    );
    final ctx = RunContext.background();
    final a = ChatModelAgent(ChatModelAgentConfig(
      name: 'name',
      description: 'description',
      instruction: 'instruction',
      model: _MyModel([
        Message.assistant('', toolCalls: [_call('1', 'myAgent', '{"request":"123"}')]),
        Message.assistant('completed'),
      ]),
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [AgentTool(sa)])),
    ));
    final runner = Runner(agent: a, checkpointStore: InMemoryCheckpointStore());

    var iter =
        runner.query(ctx, 'hello world', options: [AgentRunOption.checkpointId('1')]);
    expect(await iter.nextOrNull(), isNotNull);
    var event = await iter.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.action?.interrupted, isNotNull);
    expect(await iter.nextOrNull(), isNull);

    iter = await runner.resume(ctx, '1');
    event = await iter.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.action?.interrupted, isNotNull);
    final contexts = event.action!.interrupted!.interruptContexts;
    expect(contexts, hasLength(1));
    for (final point in contexts) {
      if (point.isRootCause) {
        expect(
          point.address,
          Address([_agent('name'), _tool('myAgent', '1'), _agent('myAgent')]),
        );
        expect(point.info, 'interrupt again');
      }
    }
    final toolInterruptId =
        contexts.firstWhere((point) => point.isRootCause, orElse: () => contexts.first).id;
    expect(toolInterruptId, isNotEmpty);
    expect(await iter.nextOrNull(), isNull);

    iter = await runner.resumeWithParams(
      ctx,
      '1',
      ResumeParams(targets: {toolInterruptId: 'resume sa'}),
    );
    event = await iter.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.output!.messageOutput!.message!.content,
        'my agent completed with data resume sa');
    event = await iter.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.output!.messageOutput!.message!.content, 'completed');
    expect(await iter.nextOrNull(), isNull);

    // The Go resumeFn asserts these (run here, outside the agent).
    expect(resumeInfos, hasLength(2));
    for (final info in resumeInfos) {
      expect(info.enableStreaming, isFalse);
    }
    expect(resumeInfos.last.isResumeTarget, isTrue);
    expect(resumeInfos.last.resumeData, 'resume sa');
  });

  test('TestChatModelInterrupt', () async {
    final ctx = RunContext.background();
    final a = ChatModelAgent(ChatModelAgentConfig(
      name: 'name',
      description: 'description',
      instruction: 'instruction',
      model: _MyModel(
        [
          Message.assistant('', toolCalls: [_call('1', 'tool1', 'arguments')]),
          Message.assistant('completed'),
        ],
        validator: (i, messages) {
          if (i > 0 &&
              (messages.length != 4 || messages[2].content != 'new user message')) {
            return false;
          }
          return true;
        },
      ),
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [_MyTool1()])),
    ));
    final runner = Runner(agent: a, checkpointStore: InMemoryCheckpointStore());
    var iter =
        runner.query(ctx, 'hello world', options: [AgentRunOption.checkpointId('1')]);
    expect(await iter.nextOrNull(), isNotNull);
    var event = await iter.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.action?.interrupted, isNotNull);
    final contexts = event.action!.interrupted!.interruptContexts;
    expect(contexts, hasLength(1));
    expect(contexts[0].address, Address([_agent('name'), _tool('tool1', '1')]));

    String? chatModelAgentId;
    String? toolId;
    for (InterruptCtx? point = contexts[0]; point != null; point = point.parent) {
      final last = point.address.segments.last;
      if (last.type == addressSegmentTool) {
        toolId = point.id;
      } else if (last.type == addressSegmentAgent) {
        chatModelAgentId = point.id;
      }
    }
    expect(await iter.nextOrNull(), isNull);
    expect(chatModelAgentId, isNotNull);
    expect(toolId, isNotNull);

    iter = await runner.resumeWithParams(
      ctx,
      '1',
      ResumeParams(targets: {
        chatModelAgentId!: ChatModelAgentResumeData(
          // Messages are immutable: the Go modifier sets history[2].Content in
          // place, this one returns the history with a modified copy.
          historyModifier: (ctx, history) => [
            for (final (i, message) in history.indexed)
              i == 2 ? message.copyWith(content: 'new user message') : message,
          ],
        ),
        toolId!: 'tool resume result',
      }),
    );
    event = await iter.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.output!.messageOutput!.message!.content, 'tool resume result');
    event = await iter.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.output!.messageOutput!.message!.content, 'completed');
  });

  test('TestChatModelParallelToolInterruptAndResume', () async {
    final ctx = RunContext.background();
    final toolA = _MyStatefulTool('toolA');
    final toolB = _MyStatefulTool('toolB');
    final chatModel = ChatModelAgent(ChatModelAgentConfig(
      name: 'ParallelToolAgent',
      description: 'An agent that uses parallel tools',
      model: _MyModel([
        // 1. First model response: call toolA and toolB in parallel.
        Message.assistant('', toolCalls: [
          _call('1', 'toolA', '{}'),
          _call('2', 'toolB', '{}'),
        ]),
        // 2. Second model response (after the tools are resumed): call them
        // again to check the state.
        Message.assistant('', toolCalls: [
          _call('3', 'toolA', '{}'),
          _call('4', 'toolB', '{}'),
        ]),
        // 3. Final completion.
        Message.assistant('all done'),
      ]),
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [toolA, toolB])),
    ));
    final runner =
        Runner(agent: chatModel, checkpointStore: InMemoryCheckpointStore());

    // 1. Initial query -> parallel interrupt from toolA and toolB.
    var (normalEvents, interruptEvent) = await _consumeUntilInterrupt(
      runner.query(ctx, 'start',
          options: [AgentRunOption.checkpointId('parallel-tool-test-1')]),
    );
    expect(normalEvents, hasLength(1), reason: '$normalEvents');
    expect(interruptEvent, isNotNull);
    final contexts = interruptEvent!.action!.interrupted!.interruptContexts;
    expect(contexts, hasLength(2), reason: 'should have 2 interrupts');
    String? toolAInterruptId;
    String? toolBInterruptId;
    for (final info in contexts) {
      switch (info.info) {
        case 'interrupt from toolA':
          toolAInterruptId = info.id;
          expect(info.isRootCause, isTrue);
        case 'interrupt from toolB':
          toolBInterruptId = info.id;
          expect(info.isRootCause, isTrue);
      }
    }
    expect(toolAInterruptId, isNotEmpty);
    expect(toolBInterruptId, isNotEmpty);

    // 2. Resume, targeting only toolA. toolB should re-interrupt.
    (_, interruptEvent) = await _consumeUntilInterrupt(
      await runner.resumeWithParams(
        ctx,
        'parallel-tool-test-1',
        ResumeParams(targets: {toolAInterruptId!: 'toolA resumed'}),
      ),
    );
    expect(interruptEvent, isNotNull, reason: 'expected a re-interrupt from toolB');
    final remaining = interruptEvent!.action!.interrupted!.interruptContexts;
    expect(remaining, hasLength(1), reason: 'should have 1 remaining interrupts');
    final rootCause = remaining.where((info) => info.isRootCause).firstOrNull;
    expect(rootCause, isNotNull, reason: 'expected a root cause interrupt from toolB');
    expect(rootCause!.info, 'interrupt from toolB');
    final toolBReInterruptId = rootCause.id;

    // 3. Resume the re-interrupted toolB. The agent should then call the
    // tools again.
    final AgentEvent? lastInterrupt;
    (normalEvents, lastInterrupt) = await _consumeUntilInterrupt(
      await runner.resumeWithParams(
        ctx,
        'parallel-tool-test-1',
        ResumeParams(targets: {toolBReInterruptId: 'toolB resumed'}),
      ),
    );

    // 4. The results of the second tool calls, then a new interrupt (the
    // second calls are new interrupt points).
    expect(normalEvents, hasLength(2), reason: '$normalEvents');
    expect(lastInterrupt, isNotNull);
    // The assertion inside the Go tool: it has its state when it re-interrupts.
    expect(toolB.hasStateOnReInterrupt, isNotEmpty);
    expect(toolA.hasStateOnReInterrupt, everyElement(isTrue));
    expect(toolB.hasStateOnReInterrupt, everyElement(isTrue));
  });

  test('TestNestedChatModelAgentWithAgentTool', () async {
    final ctx = RunContext.background();
    // An interruptible tool for the inner agent.
    final innerTool = _MyStatefulTool('innerTool');
    // The inner ChatModelAgent that the AgentTool wraps.
    final innerAgent = ChatModelAgent(ChatModelAgentConfig(
      name: 'InnerAgent',
      description: 'Inner agent with interruptible tool',
      model: _MyModel([
        Message.assistant('', toolCalls: [_call('1', 'innerTool', '{}')]),
        Message.assistant('inner agent completed'),
      ]),
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [innerTool])),
    ));
    final agentTool = AgentTool(innerAgent);
    // The outer ChatModelAgent that uses the AgentTool.
    final outerAgent = ChatModelAgent(ChatModelAgentConfig(
      name: 'OuterAgent',
      description: 'Outer agent with AgentTool containing inner agent',
      model: _MyModel([
        Message.assistant('', toolCalls: [_call('1', 'InnerAgent', '{}')]),
        Message.assistant('outer agent completed'),
      ]),
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [agentTool])),
    ));
    final runner =
        Runner(agent: outerAgent, checkpointStore: InMemoryCheckpointStore());

    final iter = runner.query(ctx, 'start',
        options: [AgentRunOption.checkpointId('nested-agent-test-1')]);
    final allEvents = <AgentEvent>[];
    AgentEvent? interruptEvent;
    var interruptEvents = 0;
    for (var event = await iter.nextOrNull();
        event != null;
        event = await iter.nextOrNull()) {
      if (event.action?.interrupted != null) {
        interruptEvents++;
        interruptEvent = event;
      }
      allEvents.add(event);
    }
    expect(interruptEvent, isNotNull, reason: 'expected an interrupt event');
    // Exactly one interrupt event (not duplicated).
    expect(interruptEvents, 1);
    final contexts = interruptEvent!.action!.interrupted!.interruptContexts;
    expect(contexts, hasLength(1), reason: 'should have exactly one interrupt context');
    final interruptCtx = contexts[0];
    expect(interruptCtx.isRootCause, isTrue, reason: 'interrupt should be root cause');
    expect(interruptCtx.info, 'interrupt from innerTool');
    expect(
      interruptCtx.address,
      Address([
        _agent('OuterAgent'),
        _tool('InnerAgent', '1'),
        _agent('InnerAgent'),
        _tool('innerTool', '1'),
      ]),
      reason: 'interrupt address should show correct nested structure',
    );
    // Only events from the outer agent: the inner agent's events are handled
    // by the AgentTool and not duplicated.
    for (final event in allEvents) {
      if (event.agentName.isNotEmpty) {
        expect(event.agentName, 'OuterAgent',
            reason: 'all events should come from OuterAgent, not duplicated '
                'from InnerAgent');
      }
    }

    // Now resume the interrupt.
    final resumed = await runner.resumeWithParams(
      ctx,
      'nested-agent-test-1',
      ResumeParams(targets: {interruptCtx.id: 'resume inner tool'}),
    );
    final finalEvents = await resumed.collectAll();
    expect(finalEvents, isNotEmpty, reason: 'should have completion events after resume');
    var foundInnerCompletion = false;
    var foundOuterCompletion = false;
    for (final event in finalEvents) {
      switch (event.output?.messageOutput?.message?.content) {
        case 'inner agent completed':
          foundInnerCompletion = true;
        case 'outer agent completed':
          foundOuterCompletion = true;
      }
    }
    expect(foundInnerCompletion, isTrue,
        reason: 'should have inner agent completion: $finalEvents');
    expect(foundOuterCompletion, isTrue,
        reason: 'should have outer agent completion: $finalEvents');
  });

  test('TestReturnDirectlyEventSentAfterResume', () async {
    final ctx = RunContext.background();
    const returnDirectlyToolName = 'return_directly_tool';
    const interruptingToolName = 'interrupting_tool';
    const dynamicToolName = 'dynamic_tool';
    final mdl = _TwoToolCallModel(
      returnDirectlyToolName: returnDirectlyToolName,
      interruptingToolName: interruptingToolName,
    );
    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestAgent',
      description: 'Test agent for return directly + interrupt',
      model: mdl,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [
          _ReturnDirectlyTool(returnDirectlyToolName),
          _InterruptingTool(interruptingToolName),
        ]),
        returnDirectly: const {returnDirectlyToolName},
      ),
      handlers: [
        _InterruptTestToolsHandler([_DynamicTool(dynamicToolName)]),
      ],
    ));
    final store = InMemoryCheckpointStore();
    final runner = Runner(agent: agent, checkpointStore: store);

    final iter = runner.query(ctx, 'test input',
        options: [AgentRunOption.checkpointId('test_checkpoint')]);
    AgentEvent? interruptEvent;
    final events = await iter.collectAll();
    for (final event in events) {
      if (event.action?.interrupted != null) interruptEvent = event;
    }
    expect(interruptEvent, isNotNull, reason: 'Should have an interrupt event: $events');
    expect(interruptEvent!.action!.interrupted!.interruptContexts, isNotEmpty);

    expect(
      mdl.receivedTools?.map((tool) => tool.name),
      contains(dynamicToolName),
      reason: 'Dynamic tool should be in tool list before interrupt',
    );

    final interruptId = interruptEvent.action!.interrupted!.interruptContexts[0].id;
    final resumed = await runner.resumeWithParams(
      ctx,
      'test_checkpoint',
      ResumeParams(targets: {interruptId: 'resume data'}),
    );
    final resumeEvents = await resumed.collectAll();
    final hasReturnDirectlyEvent = resumeEvents.any((event) {
      final output = event.output?.messageOutput;
      return output != null &&
          output.role == RoleType.tool &&
          output.toolName == returnDirectlyToolName;
    });
    expect(hasReturnDirectlyEvent, isTrue,
        reason: 'ReturnDirectlyEvent should be sent after resume: $resumeEvents');

    expect(
      mdl.receivedTools?.map((tool) => tool.name),
      contains(dynamicToolName),
      reason: 'Dynamic tool should be in tool list after resume '
          '(bc.toolUpdated path)',
    );
  });

  // Not from the Go file: a custom ResumableAgent that interrupts with
  // statefulInterruptEvent; its state goes through the runner's JSON
  // checkpoint, and a non-targeted resume and a targeted one see the right
  // ResumeInfo.
  test('custom ResumableAgent with statefulInterruptEvent', () async {
    final ctx = RunContext.background();
    final resumeInfos = <ResumeInfo>[];
    const firstState = _CustomAgentState(step: 1, note: 'waiting');
    final agent = _MyAgent(
      name: 'custom',
      runFn: (ctx, input, options) => StreamReader<AgentEvent>.fromIterable([
        AgentEvent.fromMessage(Message.assistant('working on it')),
        statefulInterruptEvent(ctx, 'need input', firstState),
      ]),
      resumeFn: (ctx, info, options) {
        resumeInfos.add(info);
        final state = info.interruptState;
        if (!info.isResumeTarget) {
          // Not targeted: interrupt again, one step further.
          return StreamReader<AgentEvent>.fromIterable([
            statefulInterruptEvent(
              ctx,
              'need input again',
              _CustomAgentState(
                step: (state is _CustomAgentState ? state.step : 0) + 1,
                note: 'still waiting',
              ),
            ),
          ]);
        }
        return StreamReader<AgentEvent>.fromIterable([
          AgentEvent.fromMessage(Message.assistant('done: ${info.resumeData}')),
        ]);
      },
    );
    final store = InMemoryCheckpointStore();
    final runner =
        Runner(agent: agent, enableStreaming: true, checkpointStore: store);

    final events = await runner
        .query(ctx, 'go', options: [AgentRunOption.checkpointId('cp')])
        .collectAll();
    expect(events.map((e) => e.error), everyElement(isNull), reason: '$events');
    expect(events, hasLength(2));
    expect((await getMessageFromEvent(events[0]))!.content, 'working on it');
    expect(events.every((e) => e.agentName == 'custom'), isTrue);
    final first = events[1].action!.interrupted!.interruptContexts.single;
    expect(first.info, 'need input');
    expect(first.isRootCause, isTrue);
    expect(first.address, Address([_agent('custom')]));
    expect(first.id, isNotEmpty);
    expect(store.keys, ['cp']);

    // A non-targeted resume (from a new runner sharing only the store): the
    // agent was interrupted, gets its state back from JSON, and is not a
    // resume target.
    final again = await (await Runner(agent: agent, checkpointStore: store)
            .resume(ctx, 'cp'))
        .collectAll();
    expect(again.map((e) => e.error), everyElement(isNull), reason: '$again');
    expect(resumeInfos, hasLength(1));
    final untargeted = resumeInfos.single;
    expect(untargeted.wasInterrupted, isTrue);
    expect(untargeted.isResumeTarget, isFalse);
    expect(untargeted.resumeData, isNull);
    expect(untargeted.enableStreaming, isTrue,
        reason: 'the resumed run streams as the saved run did');
    final restored = untargeted.interruptState;
    expect(restored, isA<_CustomAgentState>());
    expect(restored, isNot(same(firstState)),
        reason: 'the state went through the JSON checkpoint');
    expect((restored! as _CustomAgentState).step, 1);
    expect((restored as _CustomAgentState).note, 'waiting');
    final second = again.single.action!.interrupted!.interruptContexts.single;
    expect(second.info, 'need input again');
    expect(second.address, Address([_agent('custom')]));

    // A targeted resume with data: the saved state of the second interrupt,
    // and the data.
    final done = await (await runner.resumeWithParams(
      ctx,
      'cp',
      ResumeParams(targets: {second.id: 'the answer'}),
    ))
        .collectAll();
    expect(done.map((e) => e.error), everyElement(isNull), reason: '$done');
    expect(resumeInfos, hasLength(2));
    final targeted = resumeInfos.last;
    expect(targeted.wasInterrupted, isTrue);
    expect(targeted.isResumeTarget, isTrue);
    expect(targeted.resumeData, 'the answer');
    expect(targeted.interruptState, isA<_CustomAgentState>());
    expect((targeted.interruptState! as _CustomAgentState).step, 2);
    expect((targeted.interruptState! as _CustomAgentState).note, 'still waiting');
    expect(done, hasLength(1));
    expect((await getMessageFromEvent(done.single))!.content, 'done: the answer');
    expect(done.single.agentName, 'custom');
  });
}
