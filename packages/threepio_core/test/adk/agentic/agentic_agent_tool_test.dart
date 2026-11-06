// Ports eino v0.9.22 TestCoverage_NewTypedAgentTool_Agentic
// (`adk/agentic_test.go`) and TestAgenticIntegration_AgentTool
// (`adk/agentic_integration_test.go`); plus, written for the port: an
// interrupt inside the agent behind the tool and its resume through the
// outer runner, emitInternalEvents, and a classic agent calling an agentic
// agent tool.
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

import 'agentic_fakes.dart';

void main() {
  final ctx = RunContext.background();

  test('TestCoverage_NewTypedAgentTool_Agentic', () async {
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'tool-agent',
      description: 'agent wrapped as tool',
      model: MockAgenticModel(onGenerate: (_, __) async => agenticMsg('tool response')),
    ));
    final tool = AgenticAgentTool(agent);
    final info = await tool.info();
    expect(info.name, 'tool-agent');
    final result = await tool.invokableRun(ctx, '{"request":"test"}');
    expect(result, contains('tool response'));
  });

  test('TestAgenticIntegration_AgentTool', () async {
    final inner = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'InnerAgent',
      description: 'An agent used as a tool',
      model: MockAgenticModel(
        onGenerate: (_, __) async => agenticMsg('inner tool result'),
      ),
    ));
    final agentTool = AgenticAgentTool(inner);
    final info = await agentTool.info();
    expect(info.name, 'InnerAgent');
    expect(info.desc, 'An agent used as a tool');

    // Go's outer model answers at once; here it calls the inner agent first,
    // so that the tool really runs.
    final outerModel = SequentialAgenticModel([
      agenticToolCallMsg('InnerAgent', 'c1', '{"request":"delegate"}'),
      agenticMsg('outer response after inner tool'),
    ]);
    final outer = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'OuterAgent',
      description: 'Outer agent with agent tool',
      model: outerModel,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [agentTool])),
    ));
    final events = await drainAgenticEvents(
      AgenticRunner(agent: outer).query(ctx, 'delegate to inner'),
    );
    expect(events, isNotEmpty);
    expect(agenticEventRoleProblems(events), isEmpty);
    final last = events.last;
    expect(last.error, isNull);
    expect(last.output, isNotNull);
    final toolResult = events[1].output!.messageOutput!.message!.contentBlocks
        .single.functionToolResult!;
    expect(
      (toolResult.content.single.content as UserInputText).text,
      'inner tool result',
    );
  });

  test('an interrupt inside the agent tool interrupts the caller and resumes '
      'through it', () async {
    final innerModel = SequentialAgenticModel([
      agenticToolCallMsg('approval', 'ic1', '{}'),
      agenticMsg('inner done'),
    ]);
    final inner = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'inner',
      description: 'needs approval',
      model: innerModel,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [AgenticInterruptTool('approval')]),
      ),
    ));
    final outerModel = SequentialAgenticModel([
      agenticToolCallMsg('inner', 'oc1', '{"request":"go"}'),
      agenticMsg('outer done'),
    ]);
    final outer = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'outer',
      description: 'calls inner',
      model: outerModel,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [AgenticAgentTool(inner)]),
      ),
    ));
    final runner =
        AgenticRunner(agent: outer, checkpointStore: InMemoryCheckpointStore());
    final events1 = await drainAgenticEvents(
      runner.query(ctx, 'start', options: [AgentRunOption.checkpointId('nested')]),
    );
    expect(firstAgenticEventError(events1), isNull);
    final interrupted = findInterruptEvent(events1)!.action!.interrupted!;
    final rootCause = interrupted.interruptContexts.firstWhere((c) => c.isRootCause);
    expect(
      [
        for (final s in rootCause.address.segments)
          s.subId.isEmpty ? s.id : '${s.id}#${s.subId}',
      ],
      ['outer', 'inner#oc1', 'inner', 'approval#ic1'],
    );

    final events2 = await drainAgenticEvents(
      await runner.resumeWithParams(
        ctx,
        'nested',
        ResumeParams(targets: {rootCause.id: 'yes'}),
      ),
    );
    expect(firstAgenticEventError(events2), isNull);
    expect(
      agenticTextContent(events2.last.output!.messageOutput!.message),
      'outer done',
    );
    final innerResult = [
      for (final e in events2)
        if (e.output?.messageOutput?.message?.contentBlocks.firstOrNull
                ?.functionToolResult
            case final r?)
          (r.content.single.content as UserInputText).text,
    ];
    expect(innerResult, ['inner done']);
  });

  test('emitInternalEvents passes the inner agent events on', () async {
    final inner = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'inner',
      description: 'inner agent',
      model: MockAgenticModel(onGenerate: (_, __) async => agenticMsg('from inner')),
    ));
    final outer = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'outer',
      description: 'outer agent',
      model: SequentialAgenticModel([
        agenticToolCallMsg('inner', 'c1', '{"request":"x"}'),
        agenticMsg('from outer'),
      ]),
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [AgenticAgentTool(inner)]),
        emitInternalEvents: true,
      ),
    ));
    final events = await drainAgenticEvents(
      AgenticRunner(agent: outer).query(ctx, 'go'),
    );
    expect(
      [
        for (final e in events)
          (e.agentName, agenticTextContent(e.output?.messageOutput?.message)),
      ],
      [
        ('outer', ''),
        ('inner', 'from inner'),
        ('outer', ''),
        ('outer', 'from outer'),
      ],
    );
  });

  test('a classic agent can call an agentic agent tool', () async {
    final inner = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'agentic',
      description: 'agentic helper',
      model: MockAgenticModel(onGenerate: (_, __) async => agenticMsg('agentic says hi')),
    ));
    var call = 0;
    final classicModel = _ClassicModel((input) => ++call == 1
        ? Message.assistant(
            '',
            toolCalls: [
              const ToolCall(
                id: 'k1',
                function: FunctionCall(
                  name: 'agentic',
                  arguments: '{"request":"hello"}',
                ),
              ),
            ],
          )
        : Message.assistant('classic done: ${input.last.content}'));
    final classic = ChatModelAgent(ChatModelAgentConfig(
      name: 'classic',
      description: 'classic agent',
      model: classicModel,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [AgenticAgentTool(inner)]),
      ),
    ));
    final events = <AgentEvent>[];
    final reader = Runner(agent: classic).query(ctx, 'go');
    for (var e = await reader.nextOrNull(); e != null; e = await reader.nextOrNull()) {
      events.add(e);
    }
    expect(events.last.error, isNull);
    expect(
      events.last.output!.messageOutput!.message!.content,
      'classic done: agentic says hi',
    );
  });
}

class _ClassicModel extends BaseChatModel {
  _ClassicModel(this.answer);

  final Message Function(List<Message> input) answer;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async =>
      answer(input);

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([answer(input)]);
}
