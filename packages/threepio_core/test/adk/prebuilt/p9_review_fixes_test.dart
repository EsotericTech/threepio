// Regression tests for the findings of the independent P9 review.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/prebuilt/deep/task_tool.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/loop_runner.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/plan.dart';

import '../../support/scripted_chat_model.dart';

final ctx = RunContext.background();

/// A model whose first call waits for [unblock]; it answers [responses] in
/// order.
final class _GatedModel extends BaseChatModel {
  _GatedModel(this.responses);

  final List<Message> responses;
  final Completer<void> started = Completer<void>();
  final Completer<void> unblock = Completer<void>();
  int calls = 0;

  Future<Message> _next() async {
    final index = calls++;
    if (index == 0) {
      started.complete();
      await unblock.future;
    }
    return responses[index];
  }

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) => _next();

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async =>
      StreamReader.fromIterable([await _next()]);
}

final class _CountingTool extends InvokableTool {
  int runs = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: 'lookup', desc: 'looks up', params: const {});

  @override
  Future<String> run(String argumentsJson) async {
    runs++;
    return 'looked up';
  }
}

final class _Planner implements Agent {
  int runs = 0;

  @override
  String get name => 'planner';

  @override
  String get description => 'a planner agent';

  @override
  StreamReader<AgentEvent> run(RunContext ctx, AgentInput input, {List<AgentRunOption> options = const []}) {
    runs++;
    ctx
      ..addSessionValue(PlanExecute.planSessionKey, DefaultPlan(['Step 1']))
      ..addSessionValue(PlanExecute.userInputSessionKey, input.messages);
    return StreamReader.fromIterable([AgentEvent.fromMessage(Message.assistant('{"steps":["Step 1"]}'))]);
  }
}

final class _Replanner implements Agent {
  int runs = 0;

  @override
  String get name => 'replanner';

  @override
  String get description => 'a replanner agent';

  @override
  StreamReader<AgentEvent> run(RunContext ctx, AgentInput input, {List<AgentRunOption> options = const []}) {
    runs++;
    return StreamReader.fromIterable([
      AgentEvent.fromMessage(Message.assistant('{"response":"done"}')),
      AgentEvent(action: const AgentAction(customizedAction: LoopBreak('replanner'))),
    ]);
  }
}

void main() {
  // Review finding 1 (a documented deviation): after a cancel of the whole
  // run, Go re-runs the interrupted sub-agent of a workflow from the start
  // (the cancel checkpoint drops the deprecated WorkflowInterruptInfo); the
  // Dart runners resume it from its own checkpoint, as Go does when the
  // plan-execute agent sits behind an AgentTool.
  test('resume after a CancelAfterChatModel resumes the executor from its checkpoint', () async {
    final model = _GatedModel([
      Message(role: RoleType.assistant, content: '', toolCalls: [
        ToolCall(id: 'c1', function: FunctionCall(name: 'lookup', arguments: '{}')),
      ]),
      Message.assistant('step result'),
    ]);
    final tool = _CountingTool();
    final planner = _Planner();
    final replanner = _Replanner();
    final agent = await PlanExecute.create(
      ctx,
      PlanExecuteLoopConfig(
        planner: planner,
        executor: await PlanExecute.executor(
          ctx,
          ExecutorConfig(model: model, toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool]))),
        ),
        replanner: replanner,
      ),
    );
    final runner = Runner(agent: agent, checkpointStore: InMemoryCheckpointStore());
    final (cancelOption, cancel) = withCancel();
    final eventsFuture =
        runner.query(ctx, 'go', options: [cancelOption, AgentRunOption.checkpointId('cp')]).collectAll();
    await model.started.future;
    final handle = cancel(safePoints: {CancelSafePoint.afterChatModel}, recursive: true);
    model.unblock.complete();
    expect(await handle.wait(), CancelOutcome.cancelled);
    final events = await eventsFuture;
    final cancelled = ThreepioException.findCause<AgentRunCancelledException>(events.last.error)!;
    expect(cancelled.info.safePoints, {CancelSafePoint.afterChatModel});
    expect(tool.runs, 0, reason: 'cancelled after the model call, before the tool');

    final resumed = await (await runner.resume(ctx, 'cp')).collectAll();
    expect(resumed.map((e) => e.error), everyElement(isNull));
    expect(tool.runs, 1);
    expect(model.calls, 2, reason: 'the first model call is not made again');
    expect((planner.runs, replanner.runs), (1, 1));
    final last = await getMessageFromEvent(resumed.last);
    expect(last!.content, '{"response":"done"}');
  });

  test('"unmarshal plan error" carries the decoder\'s message only (Go %w)', () async {
    final planner = await PlanExecute.planner(
      ctx,
      PlannerConfig(chatModelWithFormattedOutput: ScriptedChatModel([
        [text('{"steps":"x"}')],
      ])),
    );
    final events = await Runner(agent: planner).query(ctx, 'go').collectAll();
    final message = '${events.last.error}';
    expect(message, contains('unmarshal plan error: mismatched type with value'));
    expect(message, isNot(contains('unmarshal plan error: FormatException')));
    expect(message, isNot(contains('unmarshal plan error: ThreepioFormatException')));
  });

  test('a null step is the empty string, as sonic decodes it', () {
    expect(DefaultPlan.decode(ctx, '{"steps":["a",null]}').steps, ['a', '']);
  });

  test('the task tool reads null arguments as an empty struct, as Go', () async {
    final tool = newTaskTool(subAgents: const [], withoutGeneralSubAgent: true);
    await expectLater(
      tool.invokableRun(ctx, 'null'),
      throwsA(isA<ThreepioException>().having((e) => e.message, 'message', 'subagent type  not found')),
    );
  });
}
