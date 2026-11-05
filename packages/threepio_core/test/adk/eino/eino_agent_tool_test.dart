// Ports eino v0.9.22 `adk/agent_tool_test.go`:
//   TestAgentTool_Info, TestAgentTool_Info_EmptyName,
//   TestAgentTool_Info_EmptyDescription, TestAgentTool_InvokableRun,
//   TestAgentTool_InvokableRun_StreamingVariant,
//   TestAgentTool_InvokableRun_FinalOnly,
//   TestAgentTool_SharedParentSessionValues,
//   TestAgentTool_InterruptWithoutCheckpoint,
//   TestNestedAgentTool_NoInternalEventsWhenDisabled,
//   TestNestedAgentTool_InnerToolResultNotEmittedToOuter.
// None of these tests asserts on RunPath (run paths are not ported).
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/agent_context.dart'
    show RunSession, adkRunContextOf, initAdkRunContext;
import 'package:threepio_core/src/adk/eino/interrupt.dart'
    show BridgeStore, bridgeCheckpointId;

/// Go's `assert.AnError`.
final _anError = Exception('assert.AnError general error for testing');

/// Port of Go `mockAgentForTool`: replays [responses]. (Go stops after an
/// `Exit` action; `Exit` is not ported.)
class _MockAgentForTool implements Agent {
  _MockAgentForTool(this.name, this.description, this.responses);

  @override
  final String name;

  @override
  final String description;

  final List<AgentEvent>? responses;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      StreamReader<AgentEvent>.fromIterable(responses ?? const []);
}

/// Port of Go `sessionValuesAgent`.
class _SessionValuesAgent implements Agent {
  _SessionValuesAgent(this.name);

  @override
  final String name;

  @override
  String get description => 'test';

  Object? seenParentValue;
  RunSession? capturedSession;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final rc = adkRunContextOf(ctx);
    if (rc != null) capturedSession = rc.session;
    seenParentValue = ctx.sessionValue('parent_key');
    ctx.addSessionValue('child_key', 'child_val');
    return StreamReader<AgentEvent>.fromIterable([
      AgentEvent(
        agentName: name,
        output: AgentOutput(
          messageOutput: MessageVariant.message(
            Message.assistant('ok'),
            role: RoleType.assistant,
          ),
        ),
      ),
    ]);
  }
}

/// Port of Go `streamingAgent`.
class _StreamingAgent implements Agent {
  @override
  String get name => 'stream';

  @override
  String get description => 'test';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      StreamReader<AgentEvent>.fromIterable([
        AgentEvent(
          agentName: 'stream',
          output: AgentOutput(
            messageOutput: MessageVariant.stream(
              StreamReader<Message>.fromIterable([
                Message.assistant('1'),
                Message.assistant('2'),
              ]),
            ),
          ),
        ),
        AgentEvent(
          agentName: 'stream',
          output: AgentOutput(
            messageOutput: MessageVariant.stream(
              StreamReader<Message>.fromIterable([
                Message.assistant('a'),
                Message.assistant('b'),
              ]),
            ),
          ),
        ),
      ]);
}

/// Port of Go `fakeTCM`: always calls the first tool it is told about.
class _FakeTcm extends ToolCallingChatModel {
  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final tools = options?.tools;
    return Message.assistant(
      '',
      toolCalls: [
        ToolCall(
          id: 'id-1',
          function: FunctionCall(
            name: tools != null && tools.isNotEmpty ? tools.first.name : '',
            arguments: '{"request":"hello"}',
          ),
        ),
      ],
    );
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader<Message>.fromIterable([
        await generate(input, options: options),
      ]);

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

/// Port of Go `emitOnceModel`: always answers "inner2".
class _EmitOnceModel extends ToolCallingChatModel {
  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      Message.assistant('inner2');

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader<Message>.fromIterable([await generate(input)]);

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

/// Port of Go `simpleTool`.
class _SimpleTool extends InvokableTool {
  _SimpleTool(this.name, this.result);

  final String name;
  final String result;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.function(name: name, description: 'simple tool');

  @override
  Future<String> run(String argumentsJson) async => result;
}

/// Port of the Go test helper `compositeInterruptFromLast`; Go returns the
/// error, this returns it too (the interrupt signal on success).
Future<Object?> _compositeInterruptFromLast(
  RunContext ctx,
  BridgeStore ms,
  AgentEvent? lastEvent,
) async {
  final action = lastEvent?.action;
  if (action == null || action.interrupted == null) return null;
  final Uint8List? data;
  try {
    data = await ms.get(bridgeCheckpointId);
  } on Object catch (error) {
    return ThreepioException('failed to get interrupt info: $error', cause: error);
  }
  if (data == null) {
    return const ThreepioException(
      'interrupt occurred but checkpoint data is missing',
    );
  }
  // The interrupt state of an agent tool is the Base64 of its checkpoint
  // (Go: the bytes).
  return compositeInterrupt(
    ctx,
    'agent tool interrupt',
    base64Encode(data),
    [action.interruptSignal!],
  );
}

Matcher _errorContaining(String text) =>
    throwsA(predicate((Object? e) => '$e'.contains(text), 'contains "$text"'));

void main() {
  test('TestAgentTool_Info', () async {
    final mockAgent = _MockAgentForTool('TestAgent', 'Test agent description', null);
    final agentTool = AgentTool(mockAgent);

    final info = await agentTool.info();

    expect(info, isNotNull);
    expect(info.name, 'TestAgent');
    expect(info.desc, 'Test agent description');
    expect(info.paramsOneOf, isNotNull);
  });

  test('TestAgentTool_Info_EmptyName', () async {
    final agentTool = AgentTool(_MockAgentForTool('', 'desc', null));
    await expectLater(agentTool.info(), _errorContaining('non-empty Name'));
  });

  test('TestAgentTool_Info_EmptyDescription', () async {
    final agentTool = AgentTool(_MockAgentForTool('name', '', null));
    await expectLater(agentTool.info(), _errorContaining('non-empty Description'));
  });

  test('TestAgentTool_SharedParentSessionValues', () async {
    var ctx = RunContext.background();

    final inner = _SessionValuesAgent('inner');
    final innerTool = AgentTool(inner);

    final input = AgentInput(messages: [Message.user('q')]);
    (ctx, _) = initAdkRunContext(ctx, 'outer', input);
    ctx.addSessionValue('parent_key', 'parent_val');
    final parentSession = adkRunContextOf(ctx)!.session;

    await innerTool.invokableRun(ctx, '{"request":"hello"}');

    expect(inner.seenParentValue, 'parent_val');
    expect(inner.capturedSession, isNotNull);
    final captured = inner.capturedSession!;
    // Go asserts NotSame(parentSession, captured) and Same(valuesMtx): its
    // child gets a runSession of its own (for its own event history) that
    // shares the parent's values map and mutex. Session event history is not
    // ported and Dart needs no mutex, so the child shares the parent's
    // RunSession; what both Go assertions pin is the shared values map.
    expect(identical(parentSession.values, captured.values), isTrue);

    captured.values['direct_child_key'] = 'direct_child_val';
    expect(parentSession.values.containsKey('direct_child_key'), isTrue);
    expect(parentSession.values['direct_child_key'], 'direct_child_val');

    parentSession.values['direct_parent_key'] = 'direct_parent_val';
    expect(captured.values.containsKey('direct_parent_key'), isTrue);
    expect(captured.values['direct_parent_key'], 'direct_parent_val');

    expect(ctx.hasSessionValue('child_key'), isTrue);
    expect(ctx.sessionValue('child_key'), 'child_val');
  });

  group('TestAgentTool_InvokableRun', () {
    final cases = <({
      String name,
      List<AgentEvent>? agentResponses,
      String request,
      String expectedOutput,
      bool expectError,
    })>[
      (
        name: 'successful model response',
        agentResponses: [
          AgentEvent(
            agentName: 'TestAgent',
            output: AgentOutput(
              messageOutput: MessageVariant.message(
                Message.assistant('Test response'),
                role: RoleType.assistant,
              ),
            ),
          ),
        ],
        request: '{"request":"Test request"}',
        expectedOutput: 'Test response',
        expectError: false,
      ),
      (
        name: 'successful tool call response',
        agentResponses: [
          AgentEvent(
            agentName: 'TestAgent',
            output: AgentOutput(
              messageOutput: MessageVariant.message(
                Message.tool(content: 'Tool response', toolCallId: 'test-id'),
                role: RoleType.tool,
              ),
            ),
          ),
        ],
        request: '{"request":"Test tool request"}',
        expectedOutput: 'Tool response',
        expectError: false,
      ),
      (
        name: 'invalid request JSON',
        agentResponses: null,
        request: 'invalid json',
        expectedOutput: '',
        expectError: true,
      ),
      (
        name: 'no events returned',
        agentResponses: <AgentEvent>[],
        request: '{"request":"Test request"}',
        expectedOutput: '',
        expectError: true,
      ),
      (
        name: 'error in event',
        agentResponses: [AgentEvent(agentName: 'TestAgent', error: _anError)],
        request: '{"request":"Test request"}',
        expectedOutput: '',
        expectError: true,
      ),
    ];

    for (final tt in cases) {
      test(tt.name, () async {
        final mockAgent = _MockAgentForTool(
          'TestAgent',
          'Test agent description',
          tt.agentResponses,
        );
        final agentTool = AgentTool(mockAgent);

        final output =
            agentTool.invokableRun(RunContext.background(), tt.request);

        if (tt.expectError) {
          await expectLater(output, throwsA(anything));
        } else {
          expect(await output, tt.expectedOutput);
        }
      });
    }
  });

  test('TestNestedAgentTool_NoInternalEventsWhenDisabled', () async {
    final ctx = RunContext.background();

    final inner2 = ChatModelAgent(ChatModelAgentConfig(
      name: 'inner2',
      description: 'leaf',
      model: _EmitOnceModel(),
      toolsConfig: const ToolsConfig(emitInternalEvents: false),
    ));
    final inner2Tool = AgentTool(inner2);

    final inner = ChatModelAgent(ChatModelAgentConfig(
      name: 'inner',
      description: 'mid',
      model: _FakeTcm(),
      toolsConfig: ToolsConfig(
        emitInternalEvents: false,
        toolsNode: ToolsNodeConfig(tools: [inner2Tool]),
      ),
    ));
    final innerTool = AgentTool(inner);

    final outer = ChatModelAgent(ChatModelAgentConfig(
      name: 'outer',
      description: 'top',
      model: _FakeTcm(),
      toolsConfig: ToolsConfig(
        emitInternalEvents: false,
        toolsNode: ToolsNodeConfig(tools: [innerTool]),
      ),
    ));

    final r = Runner(agent: outer, checkpointStore: BridgeStore());
    final events = r.run(ctx, [Message.user('q')]);

    for (var ev = await events.nextOrNull(); ev != null; ev = await events.nextOrNull()) {
      expect(
        ev.agentName,
        isNot('inner2'),
        reason: 'inner2 internal event should not be emitted when disabled',
      );
    }
  });

  test('TestNestedAgentTool_InnerToolResultNotEmittedToOuter', () async {
    final ctx = RunContext.background();

    final innerTool = _SimpleTool('inner_tool', 'inner_tool_result');
    final inner = ChatModelAgent(ChatModelAgentConfig(
      name: 'inner',
      description: 'inner agent with tool',
      model: _FakeTcm(),
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [innerTool])),
    ));
    final innerAgentTool = AgentTool(inner);

    final outer = ChatModelAgent(ChatModelAgentConfig(
      name: 'outer',
      description: 'outer agent',
      model: _FakeTcm(),
      toolsConfig:
          ToolsConfig(toolsNode: ToolsNodeConfig(tools: [innerAgentTool])),
    ));

    final r = Runner(agent: outer, checkpointStore: BridgeStore());
    final allEvents = await r.run(ctx, [Message.user('q')]).collectAll();

    for (final ev in allEvents) {
      final message = ev.output?.messageOutput?.message;
      final leaked = message != null &&
          message.role == RoleType.tool &&
          ev.agentName == 'outer' &&
          message.content == 'inner_tool_result';
      expect(
        leaked,
        isFalse,
        reason: "inner agent's tool result (inner_tool_result) should not be "
            "emitted as outer agent's event, but got event with "
            'AgentName=${ev.agentName}, Content=${message?.content}',
      );
    }
  });

  test('TestAgentTool_InterruptWithoutCheckpoint', () async {
    var ctx = RunContext.background();
    (ctx, _) = initAdkRunContext(ctx, 'TestAgent', AgentInput());

    final interrupted = AgentEvent(
      agentName: 'TestAgent',
      action: statefulInterruptEvent(ctx, 'info', 'state').action,
    );

    final err = await _compositeInterruptFromLast(ctx, BridgeStore(), interrupted);
    expect(err, isNotNull, reason: 'expected error for interrupt without checkpoint');
    expect(
      '$err',
      contains('interrupt occurred but checkpoint data is missing'),
      reason: 'unexpected error: $err',
    );
  });

  test('TestAgentTool_InvokableRun_FinalOnly', () async {
    final inner2 = ChatModelAgent(ChatModelAgentConfig(
      name: 'inner2',
      description: 'leaf',
      model: _EmitOnceModel(),
      toolsConfig: const ToolsConfig(emitInternalEvents: true),
    ));
    final invTool = AgentTool(inner2);
    final out = await invTool.invokableRun(RunContext.background(), '{"request":"q"}');
    expect(out, 'inner2');
  });

  test('TestAgentTool_InvokableRun_StreamingVariant', () async {
    final agent = _StreamingAgent();
    final it = AgentTool(agent);
    final out = await it.invokableRun(RunContext.background(), '{"request":"q"}');
    expect(out, 'ab');
  });
}
