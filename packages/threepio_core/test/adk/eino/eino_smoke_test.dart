import 'package:test/test.dart';
import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

import '../../support/scripted_chat_model.dart';

Future<List<adk.AgentEvent>> _drain(StreamReader<adk.AgentEvent> events) =>
    events.collectAll();

class _Echo extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'echo',
        desc: 'echoes',
        params: const {'text': ParameterInfo(type: DataType.string)},
      );

  @override
  Future<String> run(String argumentsJson) async => 'echo:$argumentsJson';
}

void main() {
  for (final streaming in [false, true]) {
    test('model, tool, model (streaming: $streaming)', () async {
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'echo', args: '{"text":"hi"}'), finish('tool_calls')],
        [text('Hel'), text('lo'), finish('stop')],
      ]);
      final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
        name: 'a',
        description: 'd',
        instruction: 'be nice',
        model: model,
        toolsConfig: adk.ToolsConfig(toolsNode: ToolsNodeConfig(tools: [_Echo()])),
      ));
      final events = await _drain(
        adk.Runner(agent: agent, enableStreaming: streaming)
            .query(RunContext.background(), 'go'),
      );
      expect(events.map((e) => e.error), everyElement(isNull));
      expect(events, hasLength(3));
      final messages = [for (final e in events) await adk.getMessageFromEvent(e)];
      expect(messages[0]!.toolCalls!.single.id, 'c1');
      expect(messages[1]!.content, 'echo:{"text":"hi"}');
      expect(messages[1]!.role, RoleType.tool);
      expect(messages[2]!.content, 'Hello');
      expect(events.every((e) => e.agentName == 'a'), isTrue);
      expect(model.calls, hasLength(2));
      expect(model.calls.first.tools!.single.function.name, 'echo');
      expect(model.calls.first.messages.first.content, 'be nice');
      expect(model.calls[1].messages.last.role, RoleType.tool);
      expect(adk.messageIdOf(messages[2]!), isNotEmpty);
    });
  }

  test('no tools', () async {
    final model = ScriptedChatModel([
      [text('Hi'), finish('stop')],
    ]);
    final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(name: 'a', model: model));
    final events = await _drain(adk.Runner(agent: agent).query(RunContext.background(), 'go'));
    expect(events.single.error, isNull);
    expect((await adk.getMessageFromEvent(events.single))!.content, 'Hi');
  });

  test('max iterations', () async {
    final model = ScriptedChatModel([
      for (var i = 0; i < 3; i++)
        [toolCallDelta(0, id: 'c$i', name: 'echo', args: '{}'), finish('tool_calls')],
    ]);
    final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
      name: 'a',
      model: model,
      maxIterations: 2,
      toolsConfig: adk.ToolsConfig(toolsNode: ToolsNodeConfig(tools: [_Echo()])),
    ));
    final events = await _drain(adk.Runner(agent: agent).query(RunContext.background(), 'go'));
    final error = events.last.error;
    expect(ThreepioException.findCause<adk.ExceedMaxIterationsException>(error!), isNotNull, reason: '$error');
    expect(model.calls, hasLength(2));
  });
}
