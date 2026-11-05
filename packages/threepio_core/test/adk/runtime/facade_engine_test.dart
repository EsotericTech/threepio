// The Kortney runtime on the Eino-shaped engine: what the golden transcripts
// do not pin. The tool call context a tool sees, handlers that hand on a
// different context or throw, sequential tools, a cancel before the run
// starts, interrupts, the model name of usage events, the legacy assembly.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

import '../../support/scripted_chat_model.dart';

Future<List<AgentEvent>> _collect(StreamReader<AgentEvent> reader) => reader.collectAll();

class _ContextTool extends ContextualTool {
  final List<ToolCallContext> contexts = [];

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: 'ctx_tool', desc: 'records', params: const {});

  @override
  Future<ToolOutput> runWithContext(ToolCallContext context, String argumentsJson) async {
    contexts.add(context);
    return ToolOutput(content: 'ran ${context.toolCall.id}');
  }
}

class _InterruptingTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: 'stop', desc: 'interrupts', params: const {});

  @override
  Future<String> invokableRun(RunContext ctx, String argumentsJson, {ToolOptions? options}) async =>
      throw interrupt(ctx, 'need a human');

  @override
  Future<String> run(String argumentsJson) => throw UnimplementedError();
}

class _ReplacingHandler extends AgentHandler {
  @override
  Future<ToolOutput> wrapToolCall(ToolCallContext context, String argumentsJson, ToolCallNext next) =>
      next(
        ToolCallContext(
          runId: 'replaced',
          toolCall: context.toolCall,
          cancelToken: context.cancelToken,
          metadata: const {'by': 'handler'},
        ),
        argumentsJson,
      );
}

class _ThrowingHandler extends AgentHandler {
  @override
  Future<ToolOutput> wrapToolCall(ToolCallContext context, String argumentsJson, ToolCallNext next) =>
      throw StateError('handler bug');
}

void main() {
  group('ContextualTool.invokableRun', () {
    test('called directly: the ids are direct', () async {
      final tool = _ContextTool();
      expect(await tool.invokableRun(RunContext.background(), '{}'), 'ran direct');
      expect(tool.contexts.single.runId, 'direct');
      expect(tool.contexts.single.toolCall.function.name, 'direct');
    });

    test('in a tools node of the engine: the call id and the name come from the node', () async {
      final tool = _ContextTool();
      final token = CancelToken();
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'ctx_tool', args: '{}'), finish('tool_calls')],
        [text('ok'), finish('stop')],
      ]);
      final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
        name: 'a',
        model: model,
        toolsConfig: adk.ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
      ));
      final events = await adk.Runner(agent: agent)
          .query(RunContext.background(cancelToken: token), 'go')
          .collectAll();
      expect(events.map((e) => e.error), everyElement(isNull));
      final context = tool.contexts.single;
      expect(context.toolCall.id, 'c1');
      expect(context.toolCall.function.name, 'ctx_tool');
      expect(context.runId, 'direct');
      expect(identical(context.cancelToken, token), isTrue);
    });

    test('in a run of the Kortney runtime: run id, session, metadata and the model\'s call', () async {
      final tool = _ContextTool();
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'ctx_tool', args: '{}'), finish('tool_calls')],
        [text('ok'), finish('stop')],
      ]);
      final runner = Runner(agent: ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model, tools: [tool])));
      final handle = await runner.run([Message.user('go')], sessionId: 's1', metadata: const {'m': 1});
      await handle.events.drain<void>();
      final context = tool.contexts.single;
      expect(context.runId, handle.runId);
      expect(context.sessionId, 's1');
      expect(context.metadata, {'m': 1});
      expect(context.toolCall.index, 0, reason: 'the call as the model sent it');
    });
  });

  group('Kortney runtime on the engine', () {
    test('a handler can hand the tool a different context', () async {
      final tool = _ContextTool();
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'ctx_tool', args: '{}'), finish('tool_calls')],
        [text('ok'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'k',
        model: model,
        tools: [tool],
        handlers: [_ReplacingHandler()],
      ));
      await _collect(await agent.run([Message.user('go')]));
      expect(tool.contexts.single.runId, 'replaced');
      expect(tool.contexts.single.metadata, {'by': 'handler'});
    });

    test('a handler that throws turns the call into an error result', () async {
      final tool = _ContextTool();
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'ctx_tool', args: '{}'), finish('tool_calls')],
        [text('ok'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'k',
        model: model,
        tools: [tool],
        handlers: [_ThrowingHandler()],
      ));
      final events = await _collect(await agent.run([Message.user('go')]));
      final result = events.whereType<ToolResultEvent>().single;
      expect(result.isError, isTrue);
      expect(result.result, 'ctx_tool failed: Bad state: handler bug');
      expect(tool.contexts, isEmpty);
      expect(events.last, isA<AgentRunEndEvent>());
    });

    test('parallelToolExecution false runs the calls one after the other', () async {
      final log = <String>[];
      final first = Completer<void>();
      final slow = ScriptedTool('slow', (c, a) async {
        log.add('slow>');
        await Future<void>.delayed(Duration.zero);
        log.add('slow<');
        first.complete();
        return const ToolOutput(content: 's');
      });
      final fast = ScriptedTool('fast', (c, a) async {
        log.add('fast');
        return const ToolOutput(content: 'f');
      });
      final model = ScriptedChatModel([
        [
          toolCallDelta(0, id: 'c1', name: 'slow', args: '{}'),
          toolCallDelta(1, id: 'c2', name: 'fast', args: '{}'),
          finish('tool_calls'),
        ],
        [text('ok'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'k',
        model: model,
        tools: [slow, fast],
        parallelToolExecution: false,
      ));
      await _collect(await agent.run([Message.user('go')]));
      expect(log, ['slow>', 'slow<', 'fast']);
    });

    test('cancel with sequential tools: the running call finishes, the rest does not start', () async {
      final token = CancelToken();
      final ran = <String>[];
      final first = ScriptedTool('first', (c, a) async {
        ran.add('first');
        token.cancel('user');
        return const ToolOutput(content: 'first result');
      });
      final second = ScriptedTool('second', (c, a) async {
        ran.add('second');
        return const ToolOutput(content: 'second result');
      });
      final model = ScriptedChatModel([
        [
          toolCallDelta(0, id: 'c1', name: 'first', args: '{}'),
          toolCallDelta(1, id: 'c2', name: 'second', args: '{}'),
          finish('tool_calls'),
        ],
        [text('never'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'k',
        model: model,
        tools: [first, second],
        parallelToolExecution: false,
      ));
      final events = await _collect(
        await agent.run([Message.user('go')], context: AgentRunScope(cancelToken: token)),
      );
      expect(ran, ['first']);
      expect(events.whereType<ToolResultEvent>().map((e) => e.toolName), ['first']);
      final toolMessages = events
          .whereType<AgentMessageEvent>()
          .map((e) => e.message)
          .where((m) => m.role == RoleType.tool)
          .toList();
      expect(toolMessages.map((m) => m.content), ['first result', 'Error: cancelled by the user before it finished.']);
      expect(events.last, isA<AgentCancelledEvent>());
      expect((events.last as AgentCancelledEvent).cancelledToolCallIds, ['c2']);
      expect(model.calls, hasLength(1));
    });

    test('a cancel before the first model call: run start, then cancelled', () async {
      final token = CancelToken()..cancel('early');
      final model = ScriptedChatModel([
        [text('never'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model));
      final events = await _collect(
        await agent.run([Message.user('go')], context: AgentRunScope(cancelToken: token)),
      );
      expect(events.map((e) => e.eventType), ['run_start', 'cancelled']);
      expect((events.last as AgentCancelledEvent).reason, 'early');
      expect(model.calls, isEmpty);
    });

    test('a tool that interrupts ends the run with an error, as before', () async {
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'stop', args: '{}'), finish('tool_calls')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model, tools: [_InterruptingTool()]));
      final events = await _collect(await agent.run([Message.user('go')]));
      final error = events.whereType<AgentErrorEvent>().single;
      expect(error.isRecoverable, isFalse);
      expect(error.error, contains('interrupted'));
      expect(events.whereType<AgentRunEndEvent>(), isEmpty);
    });

    test('maxIterations 0: no model call, the recoverable error at once', () async {
      final model = ScriptedChatModel([]);
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model, maxIterations: 0));
      final events = await _collect(await agent.run([Message.user('go')]));
      expect(events.map((e) => e.eventType), ['run_start', 'error', 'output', 'run_end']);
      expect((events[1] as AgentErrorEvent).isRecoverable, isTrue);
      expect(model.calls, isEmpty);
    });

    test('the usage event names the model of modelOptions', () async {
      final model = ScriptedChatModel([
        [
          text('hi'),
          finish('stop', usage: const TokenUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2)),
        ],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'k',
        model: model,
        modelOptions: const ChatModelOptions(model: 'some/model', temperature: 0.5),
      ));
      final events = await _collect(await agent.run([Message.user('go')]));
      expect(events.whereType<AgentUsageEvent>().single.model, 'some/model');
      final options = model.calls.single.options!;
      expect(options.model, 'some/model');
      expect(options.temperature, 0.5);
      expect(options.cancelToken, isNotNull);
    });

    test('tool calls without a name are dropped, as the legacy assembly did', () async {
      final model = ScriptedChatModel([
        [text('plain'), toolCallDelta(0, id: 'x', args: '{}'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model));
      final events = await _collect(await agent.run([Message.user('go')]));
      final message = events.whereType<AgentMessageEvent>().single.message;
      expect(message.toolCalls, isNull);
      expect(events.last, isA<AgentRunEndEvent>());
    });

    test('a stream without chunks is an empty answer', () async {
      final model = ScriptedChatModel([<Message>[]]);
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model));
      final events = await _collect(await agent.run([Message.user('go')]));
      expect(events.map((e) => e.eventType), ['run_start', 'message', 'output', 'run_end']);
      expect((events.last as AgentRunEndEvent).outputMessage!.content, '');
    });

    test('a failing tool info() fails the run before it starts', () async {
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'k',
        model: ScriptedChatModel([]),
        tools: [_BrokenInfo()],
      ));
      final events = await _collect(await agent.run([Message.user('go')]));
      expect(events.map((e) => e.eventType), ['error']);
      expect((events.single as AgentErrorEvent).error, contains('no info'));
    });

    test('handlers see the history the legacy runtime kept, without engine ids', () async {
      final seen = <List<Message>>[];
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 't', args: '{}'), finish('tool_calls')],
        [text('ok'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'k',
        model: model,
        instruction: 'sys',
        tools: [ScriptedTool('t', (c, a) async => const ToolOutput.error('nope'))],
        handlers: [_Recording(seen)],
      ));
      await _collect(await agent.run([Message.user('go')]));
      final second = seen[1];
      expect(second.map((m) => m.role), [RoleType.system, RoleType.user, RoleType.assistant, RoleType.tool]);
      expect(second.last.content, 'Error: nope');
      expect(second.last.extra, {'is_error': true});
      for (final message in second) {
        expect(message.extra?.containsKey(adk.einoMessageIdKey) ?? false, isFalse);
      }
    });
  });
}

class _Recording extends AgentHandler {
  _Recording(this.seen);

  final List<List<Message>> seen;

  @override
  Future<void> beforeModel(ChatModelAgentState state) async => seen.add(List.of(state.messages));
}

class _BrokenInfo extends InvokableTool {
  @override
  Future<ToolInfo> info() async => throw StateError('no info');

  @override
  Future<String> run(String argumentsJson) async => '';
}
