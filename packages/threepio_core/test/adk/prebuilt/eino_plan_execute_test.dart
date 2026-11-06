// Port of eino v0.9.22 `adk/prebuilt/planexecute/plan_execute_test.go` (with
// its helper `utils_test.go`: `agentOutputSessionKVs`).
//
// Ported Go tests: TestNewPlannerWithFormattedOutput,
// TestNewPlannerWithToolCalling, TestPlannerRunWithFormattedOutput,
// TestPlannerRunWithToolCalling, TestNewExecutor, TestExecutorRun,
// TestNewReplanner, TestReplannerRunWithPlan, TestReplannerRunWithRespond,
// TestNewPlanExecuteAgent, TestPlanExecuteAgentWithReplan,
// TestPlanExecuteAgentInterruptResume,
// TestWithCancel_PlanExecute_DuringExecution,
// TestWithCancel_PlanExecute_BetweenTransitions,
// TestWithCancel_PlanExecute_DuringExecution_CancelAfterChatModel.
// Not ported: none.
//
// gomock mocks become small fake classes that count their calls; a
// `.Times(n)` expectation is a counter asserted at the end, a method without
// an expectation (gomock fails on an unexpected call) a counter asserted to
// be 0, `.AnyTimes()` is not asserted. Go's `t.Logf` becomes
// `printOnFailure`. Go's sleeps and slow models become Completers: the slow
// model of the cancel tests waits for a Completer the test completes when
// Go's delay would have passed (or never: an immediate cancel abandons the
// call), `time.Sleep(50ms)` is `pumpEventQueue()`, and Go's
// `elapsed < 3s` is "the events finish without unblocking the slow model"
// (no wall time is measured).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/loop_runner.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/plan.dart';

/// Port of gomock's `MockBaseChatModel`: `stream` answers [streamResponse];
/// every call is counted, a call without a response is unexpected.
final class _MockBaseChatModel extends BaseChatModel {
  _MockBaseChatModel({this.streamResponse});

  final Message? streamResponse;
  int generateCalls = 0;
  int streamCalls = 0;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    generateCalls++;
    throw StateError('unexpected call to Generate');
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    streamCalls++;
    final response = streamResponse;
    if (response == null) throw StateError('unexpected call to Stream');
    return StreamReader.fromIterable([response]);
  }
}

/// Port of gomock's `MockToolCallingChatModel`: `withTools` returns the model
/// itself, `generate` and `stream` call [onGenerate] / answer
/// [streamResponse]; every call is counted, a call without a behaviour is
/// unexpected.
final class _MockToolCallingChatModel extends ToolCallingChatModel {
  _MockToolCallingChatModel({this.onGenerate, this.streamResponse});

  final Message Function(List<Message> input)? onGenerate;
  final Message? streamResponse;
  int withToolsCalls = 0;
  int generateCalls = 0;
  int streamCalls = 0;

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) {
    withToolsCalls++;
    return this;
  }

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    generateCalls++;
    final behaviour = onGenerate;
    if (behaviour == null) throw StateError('unexpected call to Generate');
    return behaviour(input);
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    streamCalls++;
    final response = streamResponse;
    if (response == null) throw StateError('unexpected call to Stream');
    return StreamReader.fromIterable([response]);
  }
}

/// Port of gomock's `mockAdk.MockAgent`: `run` calls [onRun]; every call is
/// counted. A run without [onRun] is unexpected (gomock fails the test): it
/// is counted and answers an error event.
final class _MockAgent implements Agent {
  _MockAgent(this.name, this.description, {this.onRun});

  @override
  final String name;

  @override
  final String description;

  final StreamReader<AgentEvent> Function(RunContext ctx, AgentInput input)? onRun;
  int runCalls = 0;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    runCalls++;
    final behaviour = onRun;
    if (behaviour == null) {
      return StreamReader.fromIterable([
        AgentEvent(error: StateError('unexpected call to Run of $name')),
      ]);
    }
    return behaviour(ctx, input);
  }
}

/// Port of `utils_test.go`'s `outputSessionKVsAgent`: forwards the events of
/// [agent], then sends the session values as a customized output.
final class _OutputSessionKVsAgent implements Agent {
  _OutputSessionKVsAgent(this.agent);

  final Agent agent;

  @override
  String get name => agent.name;

  @override
  String get description => agent.description;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final (reader, writer) = pipe<AgentEvent>();
    final inner = agent.run(ctx, input, options: options);
    unawaited(() async {
      try {
        for (var event = await inner.nextOrNull();
            event != null;
            event = await inner.nextOrNull()) {
          writer.send(event);
        }
        final kvs = ctx.sessionValues;
        writer.send(AgentEvent(output: AgentOutput(customizedOutput: kvs)));
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }
}

/// Port of `agentOutputSessionKVs`.
Future<Agent> _agentOutputSessionKVs(RunContext ctx, Agent agent) async =>
    _OutputSessionKVsAgent(agent);

/// Port of the Go test's `interruptibleTool`.
final class _InterruptibleTool extends InvokableTool {
  _InterruptibleTool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: name,
        desc: 'A tool that requires human approval before execution',
        params: const {
          'action': ParameterInfo(
            type: DataType.string,
            desc: 'The action to perform',
            required: true,
          ),
        },
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    if (!getInterruptState<Object>(ctx).wasInterrupted) {
      throw interrupt(ctx, "Tool '$name' requires human approval");
    }
    final resume = getResumeContext<String>(ctx);
    if (!resume.isResumeTarget) {
      throw interrupt(ctx, "Tool '$name' requires human approval");
    }
    if (resume.hasData) {
      return 'Approved action executed with data: ${resume.data}';
    }
    return 'Approved action executed';
  }
}

/// Port of the Go test's map-backed `checkpointStore`.
final class _CheckpointStore implements CheckpointStore {
  final Map<String, Uint8List> data = {};

  @override
  Future<void> set(String key, Uint8List value) async => data[key] = value;

  @override
  Future<Uint8List?> get(String key) async => data[key];
}

/// Port of the Go test's `slowChatModel`. Its delay becomes [unblock]: the
/// test completes it when Go's delay would have passed, or never (an
/// immediate cancel abandons the call). Go's `startedChan` is [started].
final class _SlowChatModel extends ToolCallingChatModel {
  _SlowChatModel(this.response);

  final Message response;
  final Completer<void> started = Completer<void>();
  final Completer<void> unblock = Completer<void>();

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    if (!started.isCompleted) started.complete();
    await unblock.future;
    return response;
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

/// An assistant message with [toolCalls]. Port of
/// `schema.AssistantMessage("", toolCalls)`.
Message _toolCallMessage(List<ToolCall> toolCalls) =>
    Message.assistant('', toolCalls: toolCalls);

/// The planner mock of the plan-execute agent tests: stores [plan] and
/// [userInput] in the session and sends the plan's JSON.
StreamReader<AgentEvent> _plannerRun(
  RunContext ctx,
  DefaultPlan plan,
  List<Message> userInput,
) {
  ctx.addSessionValue(PlanExecute.planSessionKey, plan);
  ctx.addSessionValue(PlanExecute.userInputSessionKey, userInput);
  final planJson = jsonEncode(plan.toJson());
  return StreamReader.fromIterable([
    AgentEvent.fromMessage(Message.assistant(planJson), role: RoleType.assistant),
  ]);
}

AgentRunCancelledException? _cancelErrorOf(AgentEvent event) =>
    ThreepioException.findCause<AgentRunCancelledException>(event.error);

void main() {
  test('TestNewPlannerWithFormattedOutput', () async {
    final ctx = RunContext.background();

    final mockChatModel = _MockBaseChatModel();

    final conf = PlannerConfig(chatModelWithFormattedOutput: mockChatModel);

    final p = await PlanExecute.planner(ctx, conf);
    expect(p, isNotNull);

    expect(p.name, 'planner');
    expect(p.description, 'a planner agent');

    // gomock: no call expected.
    expect(mockChatModel.generateCalls, 0);
    expect(mockChatModel.streamCalls, 0);
  });

  test('TestNewPlannerWithToolCalling', () async {
    final ctx = RunContext.background();

    final mockToolCallingModel = _MockToolCallingChatModel();

    // Use default instruction and tool info.
    final conf = PlannerConfig(toolCallingChatModel: mockToolCallingModel);

    final p = await PlanExecute.planner(ctx, conf);
    expect(p, isNotNull);

    expect(p.name, 'planner');
    expect(p.description, 'a planner agent');

    // gomock: WithTools(...).Times(1), nothing else.
    expect(mockToolCallingModel.withToolsCalls, 1);
    expect(mockToolCallingModel.generateCalls, 0);
    expect(mockToolCallingModel.streamCalls, 0);
  });

  test('TestPlannerRunWithFormattedOutput', () async {
    final ctx = RunContext.background();

    const planJson = '{"steps":["Step 1", "Step 2", "Step 3"]}';
    final planMsg = Message.assistant(planJson);

    // gomock: Stream(...).Return(sr, nil).Times(1).
    final mockChatModel = _MockBaseChatModel(streamResponse: planMsg);

    final conf = PlannerConfig(chatModelWithFormattedOutput: mockChatModel);

    final p = await PlanExecute.planner(ctx, conf);

    final runner = Runner(agent: p);
    final iterator = runner.run(ctx, [Message.user('Plan this task')]);

    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull, reason: '${event.error}');
    final msg = await getMessageFromEvent(event);
    expect(msg, isNotNull);
    expect(msg!.content, planMsg.content);

    expect(await iterator.nextOrNull(), isNull);

    final plan = DefaultPlan.decode(ctx, msg.content);
    expect(plan.steps!.length, 3);
    expect(plan.steps![0], 'Step 1');
    expect(plan.steps![1], 'Step 2');
    expect(plan.steps![2], 'Step 3');

    expect(mockChatModel.streamCalls, 1);
    expect(mockChatModel.generateCalls, 0);
  });

  test('TestPlannerRunWithToolCalling', () async {
    final ctx = RunContext.background();

    const planArgs = '{"steps":["Step 1", "Step 2", "Step 3"]}';
    const toolCall = ToolCall(
      id: 'tool_call_id',
      function: FunctionCall(
        name: 'plan', // This should match PlanToolInfo.Name.
        arguments: planArgs,
      ),
    );
    final toolCallMsg = _toolCallMessage([toolCall]);

    // gomock: WithTools(...).Times(1), Stream(...).Return(sr, nil).Times(1).
    final mockToolCallingModel =
        _MockToolCallingChatModel(streamResponse: toolCallMsg);

    // Use default instruction and tool info.
    final conf = PlannerConfig(toolCallingChatModel: mockToolCallingModel);

    final p = await PlanExecute.planner(ctx, conf);

    final runner = Runner(agent: p);
    final iterator = runner.run(ctx, [Message.user('no input')]);

    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull, reason: '${event.error}');

    final msg = await getMessageFromEvent(event);
    expect(msg, isNotNull);
    expect(msg!.content, planArgs);

    expect(await iterator.nextOrNull(), isNull);

    final plan = DefaultPlan.decode(ctx, msg.content);
    expect(plan.steps!.length, 3);
    expect(plan.steps![0], 'Step 1');
    expect(plan.steps![1], 'Step 2');
    expect(plan.steps![2], 'Step 3');

    expect(mockToolCallingModel.withToolsCalls, 1);
    expect(mockToolCallingModel.streamCalls, 1);
    expect(mockToolCallingModel.generateCalls, 0);
  });

  test('TestNewExecutor', () async {
    final ctx = RunContext.background();

    final mockToolCallingModel = _MockToolCallingChatModel();

    final conf = ExecutorConfig(model: mockToolCallingModel, maxIterations: 3);

    final executor = await PlanExecute.executor(ctx, conf);
    expect(executor, isNotNull);

    expect(executor.name, 'executor');
    expect(executor.description, 'an executor agent');

    // gomock: no call expected.
    expect(mockToolCallingModel.withToolsCalls, 0);
    expect(mockToolCallingModel.generateCalls, 0);
    expect(mockToolCallingModel.streamCalls, 0);
  });

  test('TestExecutorRun', () async {
    final ctx = RunContext.background();

    // Store a plan in the session. As in Go, this is a no-op: `ctx` is not
    // the context of a run (the plan reaches the run through the session
    // values option below).
    final plan = DefaultPlan(const ['Step 1', 'Step 2', 'Step 3']);
    ctx.addSessionValue(PlanExecute.planSessionKey, plan);

    // The model returns the last user message as its response
    // (gomock: Generate(...).DoAndReturn(...).Times(1)).
    final mockToolCallingModel = _MockToolCallingChatModel(
      onGenerate: (messages) {
        var lastUserMessage = '';
        for (final msg in messages) {
          if (msg.role == RoleType.user) lastUserMessage = msg.content;
        }
        return Message.assistant(lastUserMessage);
      },
    );

    final conf = ExecutorConfig(model: mockToolCallingModel, maxIterations: 3);

    final executor = await PlanExecute.executor(ctx, conf);

    final runner = Runner(agent: executor);
    final iterator = runner.run(
      ctx,
      [Message.user('no input')],
      options: [
        AgentRunOption.sessionValues({
          PlanExecute.planSessionKey: plan,
          PlanExecute.userInputSessionKey: [Message.user('no input')],
        }),
      ],
    );

    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull, reason: '${event.error}');
    expect(event.output, isNotNull);
    expect(event.output!.messageOutput, isNotNull);
    final msg = await getMessageFromEvent(event);
    expect(msg, isNotNull);
    printOnFailure('executor model input msg:\n ${msg!.content}\n');

    expect(await iterator.nextOrNull(), isNull);

    expect(mockToolCallingModel.generateCalls, 1);
    // gomock: no Stream or WithTools expectation.
    expect(mockToolCallingModel.streamCalls, 0);
    expect(mockToolCallingModel.withToolsCalls, 0);
  });

  test('TestNewReplanner', () async {
    final ctx = RunContext.background();

    // gomock: WithTools(...).Times(1).
    final mockToolCallingModel = _MockToolCallingChatModel();

    final planTool = ToolInfo.function(name: 'Plan', description: 'Plan tool');
    final respondTool =
        ToolInfo.function(name: 'Respond', description: 'Respond tool');

    final conf = ReplannerConfig(
      chatModel: mockToolCallingModel,
      planTool: planTool,
      respondTool: respondTool,
    );

    final rp = await PlanExecute.replanner(ctx, conf);
    expect(rp, isNotNull);

    expect(rp.name, 'replanner');
    expect(rp.description, 'a replanner agent');

    expect(mockToolCallingModel.withToolsCalls, 1);
    expect(mockToolCallingModel.generateCalls, 0);
    expect(mockToolCallingModel.streamCalls, 0);
  });

  test('TestReplannerRunWithPlan', () async {
    final ctx = RunContext.background();

    final planTool = ToolInfo.function(name: 'Plan', description: 'Plan tool');
    final respondTool =
        ToolInfo.function(name: 'Respond', description: 'Respond tool');

    const planArgs = '{"steps":["Updated Step 1", "Updated Step 2"]}';
    final toolCall = ToolCall(
      id: 'tool_call_id',
      function: FunctionCall(name: planTool.name, arguments: planArgs),
    );
    final toolCallMsg = _toolCallMessage([toolCall]);

    // gomock: WithTools(...).Times(1), Stream(...).Return(sr, nil).Times(1).
    final mockToolCallingModel =
        _MockToolCallingChatModel(streamResponse: toolCallMsg);

    final conf = ReplannerConfig(
      chatModel: mockToolCallingModel,
      planTool: planTool,
      respondTool: respondTool,
    );

    var rp = await PlanExecute.replanner(ctx, conf);

    final plan = DefaultPlan(const ['Step 1', 'Step 2', 'Step 3']);

    rp = await _agentOutputSessionKVs(ctx, rp);

    final runner = Runner(agent: rp);
    final iterator = runner.run(
      ctx,
      [Message.user('no input')],
      options: [
        AgentRunOption.sessionValues({
          PlanExecute.planSessionKey: plan,
          PlanExecute.executedStepSessionKey: 'Execution result',
          PlanExecute.userInputSessionKey: [Message.user('User input')],
        }),
      ],
    );

    var event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull, reason: '${event.error}');

    event = await iterator.nextOrNull();
    expect(event, isNotNull);
    final kvs = event!.output!.customizedOutput! as Map<String, Object?>;
    expect(kvs.length, greaterThan(0));

    // The updated plan was stored in the session.
    expect(kvs.containsKey(PlanExecute.planSessionKey), isTrue);
    final planValue = kvs[PlanExecute.planSessionKey];
    expect(planValue, isA<DefaultPlan>());
    final updatedPlan = planValue! as DefaultPlan;
    expect(updatedPlan.steps!.length, 2);
    expect(updatedPlan.steps![0], 'Updated Step 1');
    expect(updatedPlan.steps![1], 'Updated Step 2');

    // The executed steps were updated.
    expect(kvs.containsKey(PlanExecute.executedStepsSessionKey), isTrue);
    final executeResultsValue = kvs[PlanExecute.executedStepsSessionKey];
    expect(executeResultsValue, isA<List<ExecutedStep>>());
    final executeResults = executeResultsValue! as List<ExecutedStep>;
    expect(executeResults.length, 1);
    expect(executeResults[0].step, 'Step 1');
    expect(executeResults[0].result, 'Execution result');

    expect(await iterator.nextOrNull(), isNull);

    expect(mockToolCallingModel.withToolsCalls, 1);
    expect(mockToolCallingModel.streamCalls, 1);
    expect(mockToolCallingModel.generateCalls, 0);
  });

  test('TestReplannerRunWithRespond', () async {
    final ctx = RunContext.background();

    final planTool = ToolInfo.function(name: 'Plan', description: 'Plan tool');
    final respondTool =
        ToolInfo.function(name: 'Respond', description: 'Respond tool');

    const responseArgs = '{"response":"This is the final response to the user"}';
    final toolCall = ToolCall(
      id: 'tool_call_id',
      function: FunctionCall(name: respondTool.name, arguments: responseArgs),
    );
    final toolCallMsg = _toolCallMessage([toolCall]);

    // gomock: WithTools(...).Times(1), Stream(...).Return(sr, nil).Times(1).
    final mockToolCallingModel =
        _MockToolCallingChatModel(streamResponse: toolCallMsg);

    final conf = ReplannerConfig(
      chatModel: mockToolCallingModel,
      planTool: planTool,
      respondTool: respondTool,
    );

    final rp = await PlanExecute.replanner(ctx, conf);

    final plan = DefaultPlan(const ['Step 1', 'Step 2', 'Step 3']);

    final runner = Runner(agent: rp);
    final iterator = runner.run(
      ctx,
      [Message.user('no input')],
      options: [
        AgentRunOption.sessionValues({
          PlanExecute.planSessionKey: plan,
          PlanExecute.executedStepSessionKey: 'Execution result',
          PlanExecute.userInputSessionKey: [Message.user('User input')],
        }),
      ],
    );

    var event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull, reason: '${event.error}');
    final msg = await getMessageFromEvent(event);
    expect(msg, isNotNull);
    expect(msg!.content, responseArgs);

    // The break action was generated. Go: `Action.BreakLoop != nil` and
    // `BreakLoop.Done == false`; the Dart replanner run directly (not in the
    // loop) sends its `LoopBreak`, which has no `Done` flag.
    event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.action, isNotNull);
    expect(event.action!.customizedAction, isA<LoopBreak>());
    expect(event.action!.customizedAction, const LoopBreak('replanner'));

    expect(await iterator.nextOrNull(), isNull);

    expect(mockToolCallingModel.withToolsCalls, 1);
    expect(mockToolCallingModel.streamCalls, 1);
    expect(mockToolCallingModel.generateCalls, 0);
  });

  test('TestNewPlanExecuteAgent', () async {
    final ctx = RunContext.background();

    final mockPlanner = _MockAgent('planner', 'a planner agent');
    final mockExecutor = _MockAgent('executor', 'an executor agent');
    final mockReplanner = _MockAgent('replanner', 'a replanner agent');

    final conf = PlanExecuteLoopConfig(
      planner: mockPlanner,
      executor: mockExecutor,
      replanner: mockReplanner,
    );

    final agent = await PlanExecute.create(ctx, conf);
    expect(agent, isNotNull);

    // gomock: no Run expected.
    expect(mockPlanner.runCalls, 0);
    expect(mockExecutor.runCalls, 0);
    expect(mockReplanner.runCalls, 0);
  });

  test('TestPlanExecuteAgentWithReplan', () async {
    final ctx = RunContext.background();

    final originalPlan = DefaultPlan(const ['Step 1', 'Step 2', 'Step 3']);
    // An updated plan with fewer steps (after replanning).
    final updatedPlan = DefaultPlan(const ['Updated Step 2', 'Updated Step 3']);
    const originalExecuteResult = 'Execution result for Step 1';
    const updatedExecuteResult = 'Execution result for Updated Step 2';

    final userInput = [Message.user('User task input')];

    const finalResponse = PlanExecuteResponse(
      'Final response to user after executing all steps',
    );

    // The planner sets the original plan (gomock: Times(1)).
    final mockPlanner = _MockAgent(
      'planner',
      'a planner agent',
      onRun: (ctx, input) {
        ctx.addSessionValue(PlanExecute.planSessionKey, originalPlan);
        ctx.addSessionValue(PlanExecute.userInputSessionKey, userInput);

        final planJson = jsonEncode(originalPlan.toJson());
        final msg = Message.assistant(planJson);
        return StreamReader.fromIterable([
          AgentEvent.fromMessage(msg, role: RoleType.assistant),
        ]);
      },
    );

    // The executor sets the execute result (gomock: Times(2)).
    final mockExecutor = _MockAgent(
      'executor',
      'an executor agent',
      onRun: (ctx, input) {
        final currentPlan =
            ctx.sessionValue(PlanExecute.planSessionKey)! as DefaultPlan;
        final Message msg;
        // The first round: the original plan has 3 steps.
        if (currentPlan.steps!.length == 3) {
          msg = Message.assistant(originalExecuteResult);
          ctx.addSessionValue(
            PlanExecute.executedStepSessionKey,
            originalExecuteResult,
          );
        } else {
          msg = Message.assistant(updatedExecuteResult);
          ctx.addSessionValue(
            PlanExecute.executedStepSessionKey,
            updatedExecuteResult,
          );
        }
        return StreamReader.fromIterable([
          AgentEvent.fromMessage(msg, role: RoleType.assistant),
        ]);
      },
    );

    // The replanner first updates the plan, then responds to the user
    // (gomock: Times(2)).
    final mockReplanner = _MockAgent(
      'replanner',
      'a replanner agent',
      onRun: (ctx, input) {
        final events = <AgentEvent>[];
        final currentPlan =
            ctx.sessionValue(PlanExecute.planSessionKey)! as DefaultPlan;

        // The first replanning: the original plan has 3 steps.
        if (currentPlan.steps!.length == 3) {
          final planJson = jsonEncode(updatedPlan.toJson());
          final msg = Message.assistant(planJson);
          events.add(AgentEvent.fromMessage(msg, role: RoleType.assistant));

          ctx.addSessionValue(PlanExecute.planSessionKey, updatedPlan);
          ctx.addSessionValue(PlanExecute.executedStepsSessionKey, [
            ExecutedStep(step: currentPlan.steps![0], result: originalExecuteResult),
          ]);
        } else {
          // The second call: respond to the user.
          final responseJson = jsonEncode(finalResponse.toJson());
          final msg = Message.assistant(responseJson);
          events.add(AgentEvent.fromMessage(msg, role: RoleType.assistant));

          // Go sends `adk.NewExitAction()`; agent transfer (Exit) is not
          // ported, the loop is ended with a LoopBreak instead.
          events.add(
            const AgentEvent(
              action: AgentAction(customizedAction: LoopBreak('replanner')),
            ),
          );
        }

        return StreamReader.fromIterable(events);
      },
    );

    final conf = PlanExecuteLoopConfig(
      planner: mockPlanner,
      executor: mockExecutor,
      replanner: mockReplanner,
    );

    final agent = await PlanExecute.create(ctx, conf);
    expect(agent, isNotNull);

    final runner = Runner(agent: agent);
    final iterator = runner.run(ctx, userInput);

    final events = <AgentEvent>[];
    for (var event = await iterator.nextOrNull();
        event != null;
        event = await iterator.nextOrNull()) {
      events.add(event);
    }

    for (final (i, event) in events.indexed) {
      printOnFailure('event $i:\n$event');
    }

    expect(events.length, greaterThan(0));

    // Stronger than Go's `len(events) > 0`: the agents and messages, in
    // order. The event that carried only the LoopBreak is dropped by the
    // loop (intended deviation: Go forwards it).
    final observed = <(String, String?)>[];
    for (final event in events) {
      expect(event.error, isNull, reason: '${event.error}');
      expect(event.action?.customizedAction, isNot(isA<LoopBreak>()));
      final msg = await getMessageFromEvent(event);
      observed.add((event.agentName, msg?.content));
    }
    expect(observed, [
      ('planner', '{"steps":["Step 1","Step 2","Step 3"]}'),
      ('executor', originalExecuteResult),
      ('replanner', '{"steps":["Updated Step 2","Updated Step 3"]}'),
      ('executor', updatedExecuteResult),
      ('replanner', '{"response":"Final response to user after executing all steps"}'),
    ]);

    expect(mockPlanner.runCalls, 1);
    expect(mockExecutor.runCalls, 2);
    expect(mockReplanner.runCalls, 2);
  });

  test('TestPlanExecuteAgentInterruptResume', () async {
    final ctx = RunContext.background();

    final approvalTool = _InterruptibleTool('approve_action');

    final plan =
        DefaultPlan(const ['Execute action requiring approval', 'Complete task']);
    final userInput = [Message.user('Please execute the action')];

    // gomock: Times(1) over the run and the resume.
    final mockPlanner = _MockAgent(
      'planner',
      'a planner agent',
      onRun: (ctx, input) => _plannerRun(ctx, plan, userInput),
    );

    final toolCallMsg = _toolCallMessage([
      const ToolCall(
        id: 'call_1',
        function: FunctionCall(
          name: 'approve_action',
          arguments: '{"action": "execute"}',
        ),
      ),
    ]);

    final completionMsg =
        Message.assistant('Action approved and executed successfully');

    // gomock: WithTools AnyTimes; Generate returns the tool call once, then
    // the completion AnyTimes.
    var generateCount = 0;
    final mockToolCallingModel = _MockToolCallingChatModel(
      onGenerate: (_) => generateCount++ == 0 ? toolCallMsg : completionMsg,
    );

    final executor = await PlanExecute.executor(
      ctx,
      ExecutorConfig(
        model: mockToolCallingModel,
        toolsConfig: ToolsConfig(
          toolsNode: ToolsNodeConfig(tools: [approvalTool]),
        ),
        maxIterations: 5,
      ),
    );

    // gomock: AnyTimes.
    final mockReplanner = _MockAgent(
      'replanner',
      'a replanner agent',
      onRun: (ctx, input) {
        const responseJson = '{"response":"Task completed successfully"}';
        final msg = Message.assistant(responseJson);
        return StreamReader.fromIterable([
          AgentEvent.fromMessage(msg, role: RoleType.assistant),
          const AgentEvent(
            action: AgentAction(customizedAction: LoopBreak('replanner')),
          ),
        ]);
      },
    );

    final agent = await PlanExecute.create(
      ctx,
      PlanExecuteLoopConfig(
        planner: mockPlanner,
        executor: executor,
        replanner: mockReplanner,
        maxIterations: 5,
      ),
    );

    final store = _CheckpointStore();
    final runner = Runner(agent: agent, checkpointStore: store);

    final iter = runner.run(
      ctx,
      userInput,
      options: [AgentRunOption.checkpointId('test-interrupt-1')],
    );

    final events = <AgentEvent>[];
    AgentEvent? interruptEvent;
    for (var event = await iter.nextOrNull();
        event != null;
        event = await iter.nextOrNull()) {
      if (event.action?.interrupted != null) interruptEvent = event;
      events.add(event);
    }

    printOnFailure('Total events received: ${events.length}');
    for (final (i, event) in events.indexed) {
      printOnFailure('Event $i: $event');
    }

    expect(
      interruptEvent,
      isNotNull,
      reason: 'Expected an interrupt event from the tool, but none was received',
    );

    final interrupted = interruptEvent!.action!.interrupted;
    expect(interrupted, isNotNull, reason: 'Should have interrupt info');
    expect(
      interrupted!.interruptContexts,
      isNotEmpty,
      reason: 'Should have interrupt contexts',
    );

    printOnFailure(
      'Interrupt event received with '
      '${interrupted.interruptContexts.length} contexts',
    );
    for (final (i, c) in interrupted.interruptContexts.indexed) {
      printOnFailure(
        'Interrupt context $i: ID=${c.id}, Info=${c.info}, '
        'Address=${c.address}, IsRootCause=${c.isRootCause}',
      );
    }

    var toolInterruptId = '';
    InterruptCtx? rootCause;
    for (final intCtx in interrupted.interruptContexts) {
      if (intCtx.isRootCause) {
        toolInterruptId = intCtx.id;
        rootCause = intCtx;
        break;
      }
    }
    expect(
      toolInterruptId,
      isNotEmpty,
      reason: 'Should have a root cause interrupt ID',
    );
    // Not asserted in Go (it logs the address): the root cause is the tool
    // call inside the executor inside the loop inside the sequence. Go's
    // tool segment is `tool:<name>:<call id>` (tool_node.go
    // `appendToolAddressSegment(ctx, task.name, task.callID)`).
    expect(
      rootCause!.address.toString(),
      'agent:plan_execute_replan;agent:execute_replan;agent:executor;'
      'tool:approve_action:call_1',
    );

    printOnFailure('Attempting to resume with interrupt ID: $toolInterruptId');

    final resumeIter = await runner.resumeWithParams(
      ctx,
      'test-interrupt-1',
      ResumeParams(targets: {toolInterruptId: 'approved'}),
    );

    final resumeEvents = <AgentEvent>[];
    for (var event = await resumeIter.nextOrNull();
        event != null;
        event = await resumeIter.nextOrNull()) {
      resumeEvents.add(event);
    }
    for (final (i, event) in resumeEvents.indexed) {
      printOnFailure('Resume event $i: $event');
    }

    expect(resumeEvents, isNotEmpty, reason: 'Should have resume events');

    for (final event in resumeEvents) {
      expect(
        event.error,
        isNull,
        reason: 'Resume event should not have error: ${event.error}',
      );
    }

    var hasToolResponse = false;
    var hasAssistantCompletion = false;
    var hasLoopBreak = false;
    for (final event in resumeEvents) {
      final msg = event.output?.messageOutput?.message;
      if (msg != null) {
        if (msg.role == RoleType.tool &&
            msg.content.contains('Approved action executed')) {
          hasToolResponse = true;
        }
        if (msg.role == RoleType.assistant && msg.content.contains('approved')) {
          hasAssistantCompletion = true;
        }
      }
      if (event.action?.customizedAction is LoopBreak) hasLoopBreak = true;
    }

    expect(
      hasToolResponse,
      isTrue,
      reason: 'Should have tool response with approved action',
    );
    expect(
      hasAssistantCompletion,
      isTrue,
      reason: 'Should have assistant completion message',
    );
    // Go asserts an event with `BreakLoop.Done == true` (the loop forwards
    // the break). Intended deviation: the Dart loop strips the LoopBreak; the
    // run ended after the replanner's respond event instead (no further
    // round, no LoopBreak reaches the caller).
    expect(hasLoopBreak, isFalse);
    final last = resumeEvents.last;
    expect(last.agentName, 'replanner');
    expect(
      last.output?.messageOutput?.message?.content,
      '{"response":"Task completed successfully"}',
    );
    expect(mockReplanner.runCalls, 1);

    expect(mockPlanner.runCalls, 1);
  });

  test('TestWithCancel_PlanExecute_DuringExecution', () async {
    final ctx = RunContext.background();

    final plan = DefaultPlan(const ['Step 1', 'Step 2']);
    final userInput = [Message.user('test task')];

    // The planner returns a plan at once (gomock: Times(1)).
    final mockPlanner = _MockAgent(
      'planner',
      'a planner agent',
      onRun: (ctx, input) => _plannerRun(ctx, plan, userInput),
    );

    // The executor uses a slow model that we can cancel (Go: 5 s).
    final slowModel = _SlowChatModel(Message.assistant('step result'));

    final executor = await PlanExecute.executor(
      ctx,
      ExecutorConfig(model: slowModel, maxIterations: 5),
    );

    // The replanner is not reached: the cancel comes during the executor.
    final mockReplanner = _MockAgent('replanner', 'a replanner agent');

    final agent = await PlanExecute.create(
      ctx,
      PlanExecuteLoopConfig(
        planner: mockPlanner,
        executor: executor,
        replanner: mockReplanner,
        maxIterations: 5,
      ),
    );

    final runner = Runner(agent: agent);

    final (cancelOpt, cancelFn) = withCancel();
    final iter = runner.run(ctx, userInput, options: [cancelOpt]);

    // Wait for the executor's model to start.
    await slowModel.started.future;

    // Go: time.Sleep(50 * time.Millisecond).
    await pumpEventQueue();

    final handle = cancelFn(recursive: true);
    expect(
      await handle.wait(),
      CancelOutcome.cancelled,
      reason: 'PlanExecute workflow should handle recursive cancel',
    );

    var hasCancelError = false;
    for (var event = await iter.nextOrNull();
        event != null;
        event = await iter.nextOrNull()) {
      if (event.error != null && _cancelErrorOf(event) != null) {
        hasCancelError = true;
      }
    }

    expect(
      hasCancelError,
      isTrue,
      reason: 'Should have CancelError event from PlanExecute workflow',
    );
    // Go: elapsed < 3 s. The events ended without the slow model returning.
    expect(slowModel.unblock.isCompleted, isFalse);

    expect(mockPlanner.runCalls, 1);
    expect(mockReplanner.runCalls, 0);
  });

  test('TestWithCancel_PlanExecute_BetweenTransitions', () async {
    final ctx = RunContext.background();

    final plannerDone = Completer<void>();

    final plan = DefaultPlan(const ['Step 1']);
    final userInput = [Message.user('test task')];

    // The planner signals when it is done (gomock: Times(1)); Go sends its
    // event from a goroutine.
    final mockPlanner = _MockAgent(
      'planner',
      'a planner agent',
      onRun: (ctx, input) {
        final (reader, writer) = pipe<AgentEvent>();
        unawaited(
          Future.microtask(() async {
            try {
              ctx.addSessionValue(PlanExecute.planSessionKey, plan);
              ctx.addSessionValue(PlanExecute.userInputSessionKey, userInput);
              final planJson = jsonEncode(plan.toJson());
              final msg = Message.assistant(planJson);
              writer.send(AgentEvent.fromMessage(msg, role: RoleType.assistant));
              plannerDone.complete();
            } finally {
              await writer.close();
            }
          }),
        );
        return reader;
      },
    );

    // The executor: a slow model, to observe the cancel (Go: 5 s).
    final slowExecModel = _SlowChatModel(Message.assistant('step result'));

    final executor = await PlanExecute.executor(
      ctx,
      ExecutorConfig(model: slowExecModel, maxIterations: 5),
    );

    final mockReplanner = _MockAgent('replanner', 'a replanner agent');

    final agent = await PlanExecute.create(
      ctx,
      PlanExecuteLoopConfig(
        planner: mockPlanner,
        executor: executor,
        replanner: mockReplanner,
        maxIterations: 5,
      ),
    );

    final runner = Runner(agent: agent);

    final (cancelOpt, cancelFn) = withCancel();
    final iter = runner.run(ctx, userInput, options: [cancelOpt]);

    // Wait for the planner to finish, then cancel before the executor has a
    // chance to produce output.
    await plannerDone.future;

    // Cancel after the planner, during the executor phase.
    await slowExecModel.started.future;

    final handle = cancelFn(recursive: true);
    expect(
      await handle.wait(),
      CancelOutcome.cancelled,
      reason: 'PlanExecute workflow should handle recursive cancel',
    );

    var hasCancelError = false;
    for (var event = await iter.nextOrNull();
        event != null;
        event = await iter.nextOrNull()) {
      if (event.error != null && _cancelErrorOf(event) != null) {
        hasCancelError = true;
      }
    }

    expect(
      hasCancelError,
      isTrue,
      reason: 'Should have CancelError event from PlanExecute workflow',
    );
    // Go: elapsed < 3 s. The events ended without the slow model returning.
    expect(slowExecModel.unblock.isCompleted, isFalse);

    expect(mockPlanner.runCalls, 1);
    expect(mockReplanner.runCalls, 0);
  });

  test('TestWithCancel_PlanExecute_DuringExecution_CancelAfterChatModel',
      () async {
    final ctx = RunContext.background();

    final plan = DefaultPlan(const ['Step 1']);
    final userInput = [Message.user('test task')];

    // gomock: Times(1).
    final mockPlanner = _MockAgent(
      'planner',
      'a planner agent',
      onRun: (ctx, input) => _plannerRun(ctx, plan, userInput),
    );

    // Go: the model returns after 100 ms.
    final slowModel = _SlowChatModel(Message.assistant('step result'));
    final executor = await PlanExecute.executor(
      ctx,
      ExecutorConfig(model: slowModel, maxIterations: 5),
    );

    final mockReplanner = _MockAgent('replanner', 'a replanner agent');

    final agent = await PlanExecute.create(
      ctx,
      PlanExecuteLoopConfig(
        planner: mockPlanner,
        executor: executor,
        replanner: mockReplanner,
        maxIterations: 5,
      ),
    );

    final store = _CheckpointStore();
    final runner = Runner(agent: agent, checkpointStore: store);

    final (cancelOpt, cancelFn) = withCancel();
    final iter = runner.run(
      ctx,
      userInput,
      options: [
        cancelOpt,
        AgentRunOption.checkpointId('planexecute-safe-point-cancel'),
      ],
    );

    await slowModel.started.future;

    final handle = cancelFn(
      safePoints: {CancelSafePoint.afterChatModel},
      recursive: true,
    );
    // Go's 100 ms have passed: the model answers.
    slowModel.unblock.complete();
    expect(
      await handle.wait(),
      CancelOutcome.cancelled,
      reason: 'PlanExecute workflow should handle recursive safe-point cancel',
    );

    AgentRunCancelledException? cancelErr;
    for (var event = await iter.nextOrNull();
        event != null;
        event = await iter.nextOrNull()) {
      if (event.error != null) {
        cancelErr = _cancelErrorOf(event) ?? cancelErr;
      }
    }

    expect(
      cancelErr,
      isNotNull,
      reason: 'Should have CancelError event from PlanExecute workflow safe-point',
    );
    expect(cancelErr!.info.safePoints, {CancelSafePoint.afterChatModel});
    expect(cancelErr.interruptContexts, isNotEmpty);

    expect(mockPlanner.runCalls, 1);
  });
}
