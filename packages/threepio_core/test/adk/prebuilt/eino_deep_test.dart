// Port of eino v0.9.22 `adk/prebuilt/deep/deep_test.go` and
// `adk/prebuilt/deep/task_tool_test.go`.
//
// Ported:
// * TestGenModelInput (WithInstruction, WithoutInstruction)
// * TestWriteTodos
// * TestDeepSubAgentSharesSessionValues
// * TestDeepSubAgentFollowsStreamingMode
// * TestDeepAgentWithPlanExecuteSubAgent_InternalEventsEmitted
// * TestTaskTool
// plus a group 'DeepAgent (Dart)' with behaviours Go covers only implicitly
// (the general-purpose sub-agent, the without* switches, the description
// generator, the shell/backend check, the task tool's errors, the todo
// session value, retry vs failover of the general-purpose sub-agent).
//
// Not ported:
// * TestAgenticDeepAgentEmitInternalEventsFromSubAgent: agentic messages
//   (`*schema.AgenticMessage`, `NewTyped`) are phase P13.
// * TestDeepAgentOutputKey (all three sub-tests): `Config.OutputKey` is not
//   ported (agent transfer, NOT RECOMMENDED by eino).
// * checkpoint_compat_resume_test.go: gob checkpoints of older eino versions
//   (the `testdata/*.bin` files); Dart checkpoints are JSON.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/prebuilt/deep/deep_agent.dart'
    show AppendPromptToolMiddleware, buildBuiltinMiddlewares, deepGenModelInput;
import 'package:threepio_core/src/adk/prebuilt/deep/task_tool.dart'
    show TaskTool, generalAgentName, newTaskTool, taskToolName;

import '../../support/scripted_chat_model.dart';

final _ctx = RunContext.background();

/// An assistant message calling [name] with [args] (Go's
/// `schema.AssistantMessage("", []schema.ToolCall{c})`).
Message _call(String id, String name, String args) => Message.assistant(
      '',
      toolCalls: [
        ToolCall(id: id, function: FunctionCall(name: name, arguments: args)),
      ],
    );

/// The names of the tools the model was told about in [call].
List<String> _toolNames(ScriptedCall call) =>
    [for (final tool in call.options?.tools ?? const <ToolInfo>[]) tool.name];

/// The task tool among the handlers of the deep agent [agent], if any.
TaskTool? _taskToolOf(ChatModelAgent agent) {
  for (final handler in agent.config.handlers) {
    if (handler is AppendPromptToolMiddleware) {
      final tool = handler.tool;
      if (tool is TaskTool) return tool;
    }
  }
  return null;
}

/// Drains [events], failing on an error event.
Future<List<AgentEvent>> _drain(StreamReader<AgentEvent> events) async {
  final all = await events.collectAll();
  expect(all.map((e) => e.error), everyElement(isNull), reason: '$all');
  return all;
}

/// Go's `spySubAgent`: records the session value `parent_key` it sees.
final class _SpySubAgent implements Agent {
  Object? seenParentValue;

  @override
  String get name => 'spy-subagent';

  @override
  String get description => 'spy';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    seenParentValue = ctx.sessionValue('parent_key');
    return StreamReader.fromIterable([
      AgentEvent.fromMessage(Message.assistant('ok'), role: RoleType.assistant),
    ]);
  }
}

/// Go's `spyStreamingSubAgent`: records the streaming flag of its input.
final class _SpyStreamingSubAgent implements Agent {
  bool seenEnableStreaming = false;

  @override
  String get name => 'spy-streaming-subagent';

  @override
  String get description => 'spy';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    seenEnableStreaming = input.enableStreaming;
    return StreamReader.fromIterable([
      AgentEvent.fromMessage(Message.assistant('ok'), role: RoleType.assistant),
    ]);
  }
}

/// Go's `namedPlanExecuteAgent`: the plan-execute agent under another name
/// and description.
final class _NamedPlanExecuteAgent implements ResumableAgent {
  _NamedPlanExecuteAgent(this.inner, this.name, this.description);

  final ResumableAgent inner;

  @override
  final String name;

  @override
  final String description;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      inner.run(ctx, input, options: options);

  @override
  StreamReader<AgentEvent> resume(
    RunContext ctx,
    ResumeInfo info, {
    List<AgentRunOption> options = const [],
  }) =>
      inner.resume(ctx, info, options: options);
}

/// Go's `myAgent` of task_tool_test.go: answers its description as a user
/// message.
final class _MyAgent implements Agent {
  _MyAgent(this.name, this.description);

  @override
  final String name;

  @override
  final String description;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      StreamReader.fromIterable([
        AgentEvent.fromMessage(Message.user(description), role: RoleType.user),
      ]);
}

/// A handler that records, per agent run, the tools the agent starts with
/// (after the handlers before it) and the todo list at the end of the run.
final class _RecordingHandler extends ChatModelAgentMiddleware {
  final List<List<String>> toolsAtStart = [];
  final List<Object?> todosAtEnd = [];

  @override
  Future<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) async {
    toolsAtStart.add([for (final tool in agent.tools) (await tool.info()).name]);
    return (ctx, agent);
  }

  @override
  FutureOr<RunContext> afterAgent(RunContext ctx, ChatModelAgentState state) {
    todosAtEnd.add(ctx.sessionValue(DeepAgent.sessionKeyTodos));
    return ctx;
  }
}

final class _FakeShell implements Shell {
  @override
  Future<ExecuteResponse> execute(RunContext ctx, ExecuteRequest request) async =>
      const ExecuteResponse(output: 'ok', exitCode: 0);
}

final class _FakeStreamingShell implements StreamingShell {
  @override
  Future<StreamReader<ExecuteResponse>> executeStreaming(
    RunContext ctx,
    ExecuteRequest request,
  ) async =>
      StreamReader.fromIterable(const [ExecuteResponse(output: 'ok', exitCode: 0)]);
}

void main() {
  group('TestGenModelInput', () {
    test('WithInstruction', () {
      final msgs = deepGenModelInput(
        _ctx,
        'You are a helpful assistant',
        AgentInput(messages: [Message.user('hello')]),
      );
      expect(msgs, hasLength(2));
      expect(msgs[0].role, RoleType.system);
      expect(msgs[0].content, 'You are a helpful assistant');
      expect(msgs[1].role, RoleType.user);
      expect(msgs[1].content, 'hello');
    });

    test('WithoutInstruction', () {
      final msgs = deepGenModelInput(
        _ctx,
        '',
        AgentInput(messages: [Message.user('hello')]),
      );
      expect(msgs, hasLength(1));
      expect(msgs[0].role, RoleType.user);
      expect(msgs[0].content, 'hello');
    });
  });

  test('TestWriteTodos', () async {
    // Go passes `&Config{WithoutWriteTodos: false}`; the Dart config needs a
    // chat model, which the built-in middlewares do not use.
    final m = buildBuiltinMiddlewares(
      DeepAgentConfig(chatModel: ScriptedChatModel(const [])),
    );
    final wt = (m[0] as AppendPromptToolMiddleware).tool! as InvokableTool;

    const todos = '[{"content":"content1","activeForm":"","status":"pending"},'
        '{"content":"content2","activeForm":"","status":"pending"}]';
    const args = '{"todos": $todos}';

    final result = await wt.invokableRun(_ctx, args);
    expect(result, 'Updated todo list to $todos');
  });

  test('TestDeepSubAgentSharesSessionValues', () async {
    final spy = _SpySubAgent();
    final cm = ScriptedChatModel([
      [
        _call(
          'id-1',
          taskToolName,
          '{"subagent_type":"${spy.name}","description":"from_parent"}',
        ),
      ],
      [Message.assistant('done')],
    ]);

    final agent = await DeepAgent.create(
      _ctx,
      DeepAgentConfig(
        name: 'deep',
        description: 'deep agent',
        chatModel: cm,
        instruction: 'you are deep agent',
        subAgents: [spy],
        maxIteration: 2,
        withoutWriteTodos: true,
        withoutGeneralSubAgent: true,
      ),
    );

    final r = Runner(agent: agent);
    await r.run(
      _ctx,
      [Message.user('hi')],
      options: [
        AgentRunOption.sessionValues(const {'parent_key': 'parent_val'}),
      ],
    ).collectAll();

    expect(spy.seenParentValue, 'parent_val');
  });

  test('TestDeepSubAgentFollowsStreamingMode', () async {
    final spy = _SpyStreamingSubAgent();
    final subName = spy.name;
    final cm = ScriptedChatModel([
      [
        _call(
          'id-1',
          taskToolName,
          '{"subagent_type":"$subName","description":"from_parent"}',
        ),
      ],
      [Message.assistant('done')],
    ]);

    final agent = await DeepAgent.create(
      _ctx,
      DeepAgentConfig(
        name: 'deep',
        description: 'deep agent',
        chatModel: cm,
        instruction: 'you are deep agent',
        subAgents: [spy],
        maxIteration: 2,
        withoutWriteTodos: true,
        withoutGeneralSubAgent: true,
      ),
    );

    final r = Runner(agent: agent, enableStreaming: true);
    await r.run(_ctx, [Message.user('hi')]).collectAll();

    expect(spy.seenEnableStreaming, isTrue);
    // Go: each of the two `Stream` expectations `.Times(1)`.
    expect(cm.calls, hasLength(2));
  });

  test('TestDeepAgentWithPlanExecuteSubAgent_InternalEventsEmitted', () async {
    final plannerModel = ScriptedChatModel([
      [_call('plan_call_1', 'plan', '{"steps":["step1"]}')],
    ]);
    final executorModel = ScriptedChatModel([
      [Message.assistant('executed step1')],
    ]);
    final replannerModel = ScriptedChatModel([
      [_call('respond_call_1', 'respond', '{"response":"final response"}')],
    ]);

    final planner = await PlanExecute.planner(
      _ctx,
      PlannerConfig(toolCallingChatModel: plannerModel),
    );
    final executor = await PlanExecute.executor(
      _ctx,
      ExecutorConfig(model: executorModel),
    );
    final replanner = await PlanExecute.replanner(
      _ctx,
      ReplannerConfig(chatModel: replannerModel),
    );
    final planExecuteAgent = await PlanExecute.create(
      _ctx,
      PlanExecuteLoopConfig(
        planner: planner,
        executor: executor,
        replanner: replanner,
      ),
    );

    final namedPlanExecuteAgent = _NamedPlanExecuteAgent(
      planExecuteAgent,
      'plan_execute_subagent',
      'a plan execute subagent',
    );

    final deepModel = ScriptedChatModel([
      [
        _call(
          'id-1',
          taskToolName,
          '{"subagent_type":"${namedPlanExecuteAgent.name}",'
              '"description":"execute the plan"}',
        ),
      ],
      [Message.assistant('done')],
    ]);

    final deepAgent = await DeepAgent.create(
      _ctx,
      DeepAgentConfig(
        name: 'deep',
        description: 'deep agent',
        chatModel: deepModel,
        instruction: 'you are deep agent',
        subAgents: [namedPlanExecuteAgent],
        toolsConfig: const ToolsConfig(emitInternalEvents: true),
        maxIteration: 5,
        withoutWriteTodos: true,
        withoutGeneralSubAgent: true,
      ),
    );

    final r = Runner(agent: deepAgent);
    final events = await r.run(_ctx, [Message.user('hi')]).collectAll();

    expect(events, isNotEmpty, reason: 'should have at least one event');
    expect(events.map((e) => e.error), everyElement(isNull), reason: '$events');

    final deepAgentEvents = events.where((e) => e.agentName == 'deep');
    final plannerEvents = events.where((e) => e.agentName == 'planner');
    final executorEvents = events.where((e) => e.agentName == 'executor');
    final replannerEvents = events.where((e) => e.agentName == 'replanner');

    expect(deepAgentEvents, isNotEmpty, reason: 'should have events from deep agent');
    expect(
      plannerEvents,
      isNotEmpty,
      reason: 'planner internal events should be emitted when EmitInternalEvents is true',
    );
    expect(
      executorEvents,
      isNotEmpty,
      reason: 'executor internal events should be emitted when EmitInternalEvents is true',
    );
    expect(
      replannerEvents,
      isNotEmpty,
      reason: 'replanner internal events should be emitted when EmitInternalEvents is true',
    );

    // Beyond Go: the order of the message events and what they say.
    final messages = <(String, RoleType?, String)>[];
    for (final event in events) {
      final output = event.output?.messageOutput;
      if (output == null) continue;
      final message = await output.getMessage();
      messages.add((event.agentName, message.role, message.content));
    }
    expect(
      [for (final m in messages) m.$1],
      ['deep', 'planner', 'executor', 'replanner', 'deep', 'deep'],
      reason: '$messages',
    );
    expect(messages[1].$3, '{"steps":["step1"]}');
    expect(messages[2].$3, 'executed step1');
    expect(messages[3].$3, '{"response":"final response"}');
    expect(messages[4].$2, RoleType.tool);
    expect(messages[5].$3, 'done');
    // The loop's break action is stripped (intended deviation), so the
    // replanner's answer is the sub-agent's last event and the task result;
    // in Go the last event is the forwarded break action and the result ''.
    expect(messages[4].$3, '{"response":"final response"}');
    expect(deepModel.calls, hasLength(2));
    expect(plannerModel.calls, hasLength(1));
    expect(executorModel.calls, hasLength(1));
    expect(replannerModel.calls, hasLength(1));
  });

  test('TestTaskTool', () async {
    final a1 = _MyAgent('1', 'desc of my agent 1');
    final a2 = _MyAgent('2', 'desc of my agent 2');
    final tt = newTaskTool(
      subAgents: [a1, a2],
      withoutGeneralSubAgent: true,
      maxIteration: 10,
    );

    final info = await tt.infoWithContext(_ctx);
    expect(info.desc, contains('desc of my agent 1'));

    var result = await tt.invokableRun(_ctx, '{"subagent_type":"1"}');
    expect(result, 'desc of my agent 1');
    result = await tt.invokableRun(_ctx, '{"subagent_type":"2"}');
    expect(result, 'desc of my agent 2');
  });

  group('DeepAgent (Dart)', () {
    test(
        'the general-purpose sub-agent exists by default, with the deep '
        "agent's handlers but not the task tool", () async {
      final recorder = _RecordingHandler();
      final model = ScriptedChatModel([
        [
          _call(
            't1',
            taskToolName,
            '{"subagent_type":"general-purpose","description":"do the sub task"}',
          ),
        ],
        [Message.assistant('sub done')],
        [Message.assistant('all done')],
      ]);
      final agent = await DeepAgent.create(
        _ctx,
        DeepAgentConfig(
          name: 'deep',
          description: 'deep agent',
          chatModel: model,
          instruction: 'you are deep agent',
          handlers: [recorder],
        ),
      ) as ChatModelAgent;

      // Structure: the task tool starts only the general-purpose agent, a
      // ChatModelAgent with the built-in handlers and the user's, without a
      // task tool of its own.
      final taskTool = _taskToolOf(agent)!;
      expect(taskTool.subAgentTools.keys, [generalAgentName]);
      expect(taskTool.subAgents.map((a) => a.name), [generalAgentName]);
      final general =
          (taskTool.subAgentTools[generalAgentName]! as AgentTool).agent as ChatModelAgent;
      expect(general.name, generalAgentName);
      expect(general.config.instruction, 'you are deep agent');
      expect(general.config.handlers, contains(same(recorder)));
      expect(general.config.handlers.whereType<AppendPromptToolMiddleware>(), hasLength(1));
      expect(_taskToolOf(general), isNull);
      expect(
        (await taskTool.infoWithContext(_ctx)).desc,
        contains('- $generalAgentName: ${general.description}\n'),
      );

      // Behaviour: the sub-agent shares the model; it gets write_todos and
      // the user's handler, not the task tool.
      final events = await _drain(Runner(agent: agent).query(_ctx, 'hi'));
      expect((await getMessageFromEvent(events.last))!.content, 'all done');
      expect(model.calls, hasLength(3));
      expect(_toolNames(model.calls[0]), ['write_todos', taskToolName]);
      expect(_toolNames(model.calls[1]), ['write_todos']);
      expect(_toolNames(model.calls[2]), ['write_todos', taskToolName]);
      expect(model.calls[1].messages.map((m) => (m.role, m.content)), [
        (RoleType.system, 'you are deep agent'),
        (RoleType.user, 'do the sub task'),
      ]);
      expect(model.calls[0].messages.first.content, startsWith('you are deep agent'));
      expect(model.calls[0].messages.first.content, isNot('you are deep agent'),
          reason: 'the deep agent gets the task prompt appended');
      final toolResult = model.calls[2].messages.last;
      expect(toolResult.role, RoleType.tool);
      expect(toolResult.toolCallId, 't1');
      expect(toolResult.content, 'sub done');
      // The handler ran in both agents: the deep one, then the sub-agent.
      expect(recorder.toolsAtStart, [
        ['write_todos', taskToolName],
        ['write_todos'],
      ]);
    });

    test('withoutGeneralSubAgent without sub-agents: no task tool', () async {
      final model = ScriptedChatModel([
        [Message.assistant('hello')],
      ]);
      final agent = await DeepAgent.create(
        _ctx,
        DeepAgentConfig(
          name: 'deep',
          chatModel: model,
          instruction: 'you are deep agent',
          withoutGeneralSubAgent: true,
        ),
      ) as ChatModelAgent;
      expect(_taskToolOf(agent), isNull);

      await _drain(Runner(agent: agent).query(_ctx, 'hi'));
      expect(_toolNames(model.calls.single), ['write_todos']);
      expect(model.calls.single.messages.first.content, 'you are deep agent',
          reason: 'no task prompt without a task tool');
    });

    test('withoutWriteTodos: no write_todos tool', () async {
      final model = ScriptedChatModel([
        [Message.assistant('hello')],
      ]);
      final agent = await DeepAgent.create(
        _ctx,
        DeepAgentConfig(
          name: 'deep',
          chatModel: model,
          withoutWriteTodos: true,
        ),
      );
      await _drain(Runner(agent: agent).query(_ctx, 'hi'));
      expect(_toolNames(model.calls.single), [taskToolName]);
    });

    /// Runs a deep agent whose task tool description comes from a generator
    /// that reads the session value `who`; returns the model and what the
    /// generator saw on each call.
    Future<(ScriptedChatModel, List<Object?>, List<List<String>>)>
        runWithGenerator() async {
      final seenValues = <Object?>[];
      final seenAgents = <List<String>>[];
      final model = ScriptedChatModel([
        [Message.assistant('hello')],
      ]);
      final agent = await DeepAgent.create(
        _ctx,
        DeepAgentConfig(
          name: 'deep',
          chatModel: model,
          subAgents: [_MyAgent('researcher', 'Finds facts')],
          taskToolDescriptionGenerator: (ctx, agents) {
            seenValues.add(ctx.sessionValue('who'));
            seenAgents.add([for (final a in agents) a.name]);
            return 'custom task description for ${ctx.sessionValue('who')}';
          },
        ),
      );
      await _drain(
        Runner(agent: agent).query(_ctx, 'hi', options: [
          AgentRunOption.sessionValues(const {'who': 'gp'}),
        ]),
      );
      return (model, seenValues, seenAgents);
    }

    test(
        'a custom taskToolDescriptionGenerator gets the run context and '
        'describes the task tool', () async {
      final (model, seenValues, seenAgents) = await runWithGenerator();
      final tools = model.calls.single.options?.tools ?? const <ToolInfo>[];
      expect(
        tools.singleWhere((t) => t.name == taskToolName).desc,
        'custom task description for gp',
      );
      expect(seenValues, contains('gp'));
      expect(seenAgents, isNotEmpty);
      expect(seenAgents, everyElement(['researcher', generalAgentName]));
    });

    test(
      'every call of the taskToolDescriptionGenerator gets the run context',
      () async {
        // Go passes the run's context to every `Info`, also the tools node's
        // (`compose.NewToolNode(ctx)` → `convTools` → `bt.Info(ctx)`, built
        // per run when a handler adds tools).
        final (_, seenValues, _) = await runWithGenerator();
        expect(seenValues, isNotEmpty);
        expect(seenValues, everyElement('gp'));
      },
    );

    test("a shell without a backend throws 'backend should not be nil'", () async {
      final model = ScriptedChatModel(const []);
      final isMissingBackend = isA<ArgumentError>()
          .having((e) => e.message, 'message', 'backend should not be nil');
      await expectLater(
        DeepAgent.create(_ctx, DeepAgentConfig(chatModel: model, shell: _FakeShell())),
        throwsA(isMissingBackend),
      );
      await expectLater(
        DeepAgent.create(
          _ctx,
          DeepAgentConfig(chatModel: model, streamingShell: _FakeStreamingShell()),
        ),
        throwsA(isMissingBackend),
      );
    });

    test('the task tool fails on bad JSON and on an unknown sub-agent', () async {
      final tt = newTaskTool(
        subAgents: [_MyAgent('1', 'desc of my agent 1')],
        withoutGeneralSubAgent: true,
      );
      await expectLater(
        tt.invokableRun(_ctx, '{not json'),
        throwsA(predicate(
          (e) => '$e'.contains('failed to unmarshal task tool input json: '),
          'a task tool input json error',
        )),
      );
      await expectLater(
        tt.invokableRun(_ctx, '{"subagent_type":"x","description":"d"}'),
        throwsA(predicate(
          (e) => '$e'.contains('subagent type x not found'),
          'an unknown sub-agent error',
        )),
      );
    });

    test('write_todos keeps a List<Todo> in the session', () async {
      final recorder = _RecordingHandler();
      const todosJson = '[{"content":"c1","activeForm":"doing c1","status":"in_progress"},'
          '{"content":"c2","activeForm":"doing c2","status":"pending"}]';
      final model = ScriptedChatModel([
        [_call('t1', 'write_todos', '{"todos":$todosJson}')],
        [Message.assistant('done')],
      ]);
      final agent = await DeepAgent.create(
        _ctx,
        DeepAgentConfig(
          name: 'deep',
          chatModel: model,
          withoutGeneralSubAgent: true,
          handlers: [recorder],
        ),
      );
      await _drain(Runner(agent: agent).query(_ctx, 'plan it'));

      final todos = recorder.todosAtEnd.single;
      expect(todos, isA<List<Todo>>());
      expect(todos, const [
        Todo(content: 'c1', activeForm: 'doing c1', status: 'in_progress'),
        Todo(content: 'c2', activeForm: 'doing c2', status: 'pending'),
      ]);
      final toolResult = model.calls[1].messages.last;
      expect(toolResult.role, RoleType.tool);
      expect(toolResult.content, 'Updated todo list to $todosJson');
    });

    test(
        'the general-purpose sub-agent gets the failover config but not the '
        'retry config', () async {
      final model = ScriptedChatModel(const []);
      final retry = ModelRetryConfig(
        maxRetries: 2,
        backoff: (_, __) => Duration.zero,
      );
      final failover = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, ___) => false,
        getFailoverModel: (_, __) => (model, null),
      );
      final agent = await DeepAgent.create(
        _ctx,
        DeepAgentConfig(
          chatModel: model,
          modelRetryConfig: retry,
          modelFailoverConfig: failover,
        ),
      ) as ChatModelAgent;
      expect(agent.config.modelRetryConfig, same(retry));
      expect(agent.config.modelFailoverConfig, same(failover));

      final general = (_taskToolOf(agent)!.subAgentTools[generalAgentName]! as AgentTool)
          .agent as ChatModelAgent;
      expect(general.config.modelRetryConfig, isNull);
      expect(general.config.modelFailoverConfig, same(failover));
    });
  });
}
