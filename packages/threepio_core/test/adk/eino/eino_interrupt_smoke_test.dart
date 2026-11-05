import 'package:test/test.dart';
import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

import '../../support/scripted_chat_model.dart';

class _Approve extends InvokableTool {
  int calls = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'approve',
        desc: 'needs approval',
        params: const {'x': ParameterInfo(type: DataType.string)},
      );

  @override
  Future<String> invokableRun(RunContext ctx, String argumentsJson, {ToolOptions? options}) async {
    calls++;
    final state = getInterruptState<String>(ctx);
    if (!state.wasInterrupted) throw statefulInterrupt(ctx, 'please approve', argumentsJson);
    final resume = getResumeContext<String>(ctx);
    if (!resume.isResumeTarget) throw statefulInterrupt(ctx, 'please approve', state.state);
    return 'approved:${resume.data}:${state.state}';
  }

  @override
  Future<String> run(String argumentsJson) => throw UnimplementedError();
}

void main() {
  for (final streaming in [false, true]) {
    test('tool interrupt then resume (streaming: $streaming)', () async {
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'approve', args: '{"x":"1"}'), finish('tool_calls')],
        [text('done'), finish('stop')],
      ]);
      final tool = _Approve();
      final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
        name: 'a',
        description: 'd',
        model: model,
        toolsConfig: adk.ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
      ));
      final store = InMemoryCheckpointStore();
      final runner = adk.Runner(agent: agent, enableStreaming: streaming, checkpointStore: store);
      final events = await runner
          .query(RunContext.background(), 'go', options: [adk.AgentRunOption.checkpointId('cp')])
          .collectAll();
      expect(events.map((e) => e.error), everyElement(isNull), reason: '${events.map((e) => e.error)}');
      final interrupt = events.last.action!.interrupted!;
      expect(interrupt.data, isA<adk.ChatModelAgentInterruptInfo>());
      final point = interrupt.interruptContexts.single;
      expect(point.info, 'please approve');
      expect(point.address.toString(), 'agent:a;tool:approve:c1');
      expect(store.keys, ['cp']);

      final resumed = await (await runner.resumeWithParams(
        RunContext.background(),
        'cp',
        adk.ResumeParams(targets: {point.id: 'yes'}),
      ))
          .collectAll();
      expect(resumed.map((e) => e.error), everyElement(isNull), reason: '${resumed.map((e) => e.error)}');
      final messages = [for (final e in resumed) await adk.getMessageFromEvent(e)];
      expect(messages.first!.content, 'approved:yes:{"x":"1"}');
      expect(messages.last!.content, 'done');
      expect(model.calls, hasLength(2));
      expect(model.calls[1].messages.map((m) => m.role),
          [RoleType.user, RoleType.assistant, RoleType.tool]);
    });
  }
}
