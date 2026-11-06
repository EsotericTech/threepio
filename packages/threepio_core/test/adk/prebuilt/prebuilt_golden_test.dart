// The P9 prebuilt agents against a run of eino v0.9.22 with the same fake
// models (see go_golden_data.dart): the model inputs (prompts, instruction,
// tool list and descriptions) and the events must be the same, byte for byte.
// The one intended difference: eino forwards the loop's break action
// (`BreakLoopAction{Done: true}`); the Dart loop runner strips it.
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

import '../../support/scripted_chat_model.dart';
import 'go_golden_data.dart';

final ctx = RunContext.background();

Message _call(String id, String name, String args) => Message(
      role: RoleType.assistant,
      content: '',
      toolCalls: [ToolCall(id: id, function: FunctionCall(name: name, arguments: args))],
    );

List<(String, String)> _messages(ScriptedCall call) =>
    [for (final m in call.messages) (m.role.name, m.content)];

typedef _Event = ({String agent, String role, String content, String toolName, bool breakLoop});

Future<List<_Event>> _events(StreamReader<AgentEvent> events) async {
  final result = <_Event>[];
  for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
    expect(e.error, isNull, reason: '${e.error}');
    final variant = e.output?.messageOutput;
    final message = variant == null ? null : await variant.getMessage();
    result.add((
      agent: e.agentName,
      role: message?.role.name ?? '',
      content: message?.content ?? '',
      toolName: variant?.toolName ?? '',
      breakLoop: false,
    ));
  }
  return result;
}

final class _SubAgent implements Agent {
  _SubAgent(this.name, this.description);

  @override
  final String name;

  @override
  final String description;

  @override
  StreamReader<AgentEvent> run(RunContext ctx, AgentInput input, {List<AgentRunOption> options = const []}) =>
      StreamReader.fromIterable([
        AgentEvent.fromMessage(
          Message.assistant('sub says: ${input.messages.first.content}'),
          role: RoleType.assistant,
        ),
      ]);
}

void main() {
  test('plan-execute: model inputs and events as in eino', () async {
    final plannerModel = ScriptedChatModel([
      [_call('p1', 'plan', '{"steps":["step one","step two"]}')],
    ]);
    final executorModel = ScriptedChatModel([
      [text('result one')],
      [text('result two')],
    ]);
    final replannerModel = ScriptedChatModel([
      [_call('r1', 'plan', '{"steps":["step two"]}')],
      [_call('r2', 'respond', '{"response":"all done"}')],
    ]);
    final agent = await PlanExecute.create(
      ctx,
      PlanExecuteLoopConfig(
        planner: await PlanExecute.planner(ctx, PlannerConfig(toolCallingChatModel: plannerModel)),
        executor: await PlanExecute.executor(ctx, ExecutorConfig(model: executorModel)),
        replanner: await PlanExecute.replanner(ctx, ReplannerConfig(chatModel: replannerModel)),
      ),
    );
    final events = await _events(Runner(agent: agent).query(ctx, 'Plan a trip'));

    expect(events, [
      for (final e in goPlanExecuteEvents)
        if (!e.breakLoop) e,
    ]);
    expect(plannerModel.calls.map(_messages).toList(), goPlannerCalls);
    expect(plannerModel.calls.map((c) => c.tools?.map((t) => t.name).toList() ?? const []).toList(), goPlannerCallsBound);
    expect(executorModel.calls.map(_messages).toList(), goExecutorCalls);
    expect(executorModel.calls.map((c) => c.tools?.map((t) => t.name).toList() ?? const []).toList(), goExecutorCallsBound);
    expect(replannerModel.calls.map(_messages).toList(), goReplannerCalls);
    expect(replannerModel.calls.map((c) => c.tools?.map((t) => t.name).toList() ?? const []).toList(), goReplannerCallsBound);
  });

  test('deep agent: instruction, tools, model inputs and events as in eino', () async {
    final model = ScriptedChatModel([
      [_call('t1', 'write_todos', '{"todos":[{"content":"c","activeForm":"a","status":"pending"}]}')],
      [_call('t2', 'task', '{"subagent_type":"researcher","description":"look <up> & go"}')],
      [text('done')],
    ]);
    final agent = await DeepAgent.create(
      ctx,
      DeepAgentConfig(
        name: 'deep',
        description: 'deep agent',
        chatModel: model,
        backend: InMemoryBackend(),
        subAgents: [_SubAgent('researcher', 'Finds facts')],
      ),
    );
    final events = await _events(
      Runner(agent: agent).query(ctx, 'hi', options: [
        AgentRunOption.sessionValues(const {'k': 'v'}),
      ]),
    );

    expect(events, goDeepEvents);
    expect(model.calls.first.messages.first.content, goDeepSystemPrompt);
    final tools = model.calls.first.options?.tools ?? const <ToolInfo>[];
    expect(tools.map((t) => t.name).toList(), goDeepToolNames);
    expect(tools.firstWhere((t) => t.name == 'write_todos').desc, goDeepWriteTodosDesc);
    expect(tools.firstWhere((t) => t.name == 'task').desc, goDeepTaskDesc);
    expect(model.calls.map(_messages).toList(), goDeepCalls);
  });
}
