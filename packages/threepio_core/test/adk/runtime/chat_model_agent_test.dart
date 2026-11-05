import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../support/scripted_chat_model.dart';

void main() {
  const usage = TokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15, cost: 0.001);

  Future<List<AgentEvent>> collect(StreamReader<AgentEvent> reader) => reader.collectAll();

  group('ChatModelAgent', () {
    test('streams text, appends the assistant turn and ends the run', () async {
      final model = ScriptedChatModel([
        [text('Hel'), text('lo'), finish('stop', usage: usage)],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model, instruction: 'Be brief'));
      final events = await collect(await agent.run([Message.user('hi')]));

      expect(events.map((e) => e.eventType).toList(),
          ['run_start', 'output', 'output', 'usage', 'message', 'output', 'run_end']);
      final partials = events.whereType<AgentOutputEvent>().where((e) => e.isPartial).map((e) => e.message.content);
      expect(partials, ['Hel', 'lo']);
      final finalOutput = events.whereType<AgentOutputEvent>().last;
      expect(finalOutput.isPartial, isFalse);
      expect(finalOutput.message.content, 'Hello');
      expect(events.whereType<AgentUsageEvent>().single.usage.cost, 0.001);
      // The instruction went first in the prompt.
      expect(model.calls.single.messages.first.role, RoleType.system);
      expect(model.calls.single.messages.first.content, 'Be brief');
    });

    test('runs parallel tool calls, returns results in call order, then answers', () async {
      final order = <String>[];
      final slow = ScriptedTool('slow', (ctx, args) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        order.add('slow');
        return ToolOutput.json({'v': args['value']});
      });
      final fast = ScriptedTool('fast', (ctx, args) async {
        order.add('fast');
        return ToolOutput(content: 'fast:${args['value']}');
      });
      final model = ScriptedChatModel([
        [
          toolCallDelta(0, id: 'c1', name: 'slow', args: '{"value":'),
          toolCallDelta(0, args: ' "a"}'),
          toolCallDelta(1, id: 'c2', name: 'fast', args: '{"value": "b"}'),
          finish('tool_calls'),
        ],
        [text('done'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model, tools: [slow, fast]));
      final events = await collect(await agent.run([Message.user('go')]));

      expect(order, ['fast', 'slow'], reason: 'executed concurrently');
      final toolMessages = events.whereType<AgentMessageEvent>().map((e) => e.message).where((m) => m.role == RoleType.tool).toList();
      expect(toolMessages.map((m) => m.toolCallId), ['c1', 'c2'], reason: 'results keep the model\'s order');
      expect(toolMessages.first.content, '{"v":"a"}');
      expect(slow.invocations.single, {'value': 'a'});
      // Second model call saw assistant tool calls + both results.
      final second = model.allCalls[1];
      expect(second.last.role, RoleType.tool);
      expect(second[second.length - 3].toolCalls!.map((c) => c.id), ['c1', 'c2']);
      expect(second[second.length - 3].toolCalls!.first.function.arguments, '{"value": "a"}');
      expect(events.whereType<AgentActionEvent>().length, 2);
      expect(events.whereType<ToolResultEvent>().map((e) => e.toolName).toSet(), {'slow', 'fast'});
      expect(events.last, isA<AgentRunEndEvent>());
      expect((events.last as AgentRunEndEvent).toolCallCount, 2);
    });

    test('unknown tools and throwing tools become error results, not exceptions', () async {
      final boom = ScriptedTool('boom', (ctx, args) async => throw StateError('kaput'));
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'nope', args: '{}'), toolCallDelta(1, id: 'c2', name: 'boom', args: '{}'), finish('tool_calls')],
        [text('ok'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model, tools: [boom]));
      final events = await collect(await agent.run([Message.user('go')]));
      final results = events.whereType<ToolResultEvent>().toList();
      expect(results.every((r) => r.isError), isTrue);
      expect(results.first.result, contains('Unknown tool'));
      expect(results.last.result, contains('kaput'));
      expect(events.whereType<AgentErrorEvent>(), isEmpty);
    });

    test('approval: denied calls do not run; allowed calls do', () async {
      final tool = ScriptedTool('delete', (ctx, args) async => const ToolOutput(content: 'deleted'));
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'delete', args: '{}'), finish('tool_calls')],
        [toolCallDelta(0, id: 'c2', name: 'delete', args: '{}'), finish('tool_calls')],
        [text('ok'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'k',
        model: model,
        tools: [tool],
        approvalPolicy: const ApprovalPolicy(toolsRequiringApproval: {'delete'}),
      ));
      var asked = 0;
      final events = await collect(await agent.run(
        [Message.user('go')],
        context: RunContext(requestApproval: (call, reason) async {
          asked++;
          expect(reason, contains('delete'));
          return call.id == 'c2';
        }),
      ));
      expect(asked, 2);
      expect(events.whereType<AgentApprovalRequestEvent>().length, 2);
      final results = events.whereType<ToolResultEvent>().toList();
      expect(results[0].isError, isTrue);
      expect(results[0].result, contains('declined'));
      expect(results[1].result, 'deleted');
      expect(tool.invocations.length, 1);
    });

    test('cancel while tools run: synthetic results, cancelled event, no further model call', () async {
      final token = CancelToken();
      final hang = ScriptedTool('hang', (ctx, args) async {
        // Never completes: the run is cancelled while this call is pending.
        await Completer<void>().future;
        return const ToolOutput(content: 'late');
      });
      final quick = ScriptedTool('quick', (ctx, args) async => const ToolOutput(content: 'q'));
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'hang', args: '{}'), toolCallDelta(1, id: 'c2', name: 'quick', args: '{}'), finish('tool_calls')],
        [text('never'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model, tools: [hang, quick]));
      final reader = await agent.run([Message.user('go')], context: RunContext(cancelToken: token));
      Future<void>.delayed(const Duration(milliseconds: 50), () => token.cancel('user'));
      final events = await collect(reader);

      final cancelled = events.whereType<AgentCancelledEvent>().single;
      expect(cancelled.cancelledToolCallIds, ['c1']);
      expect(cancelled.reason, 'user');
      final toolMessages = events.whereType<AgentMessageEvent>().map((e) => e.message).where((m) => m.role == RoleType.tool).toList();
      expect(toolMessages.map((m) => m.toolCallId), ['c1', 'c2']);
      expect(toolMessages.first.content, contains('cancelled'));
      expect(toolMessages.last.content, 'q');
      expect(model.allCalls.length, 1, reason: 'no second model call after cancel');
      expect(events.whereType<AgentRunEndEvent>(), isEmpty);
    });

    test('cancel during the model stream ends the run cleanly', () async {
      final token = CancelToken();
      final model = ScriptedChatModel([
        [text('a'), text('b'), text('c'), finish('stop')],
      ], delayPerChunk: const Duration(milliseconds: 30));
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model));
      final reader = await agent.run([Message.user('go')], context: RunContext(cancelToken: token));
      Future<void>.delayed(const Duration(milliseconds: 45), () => token.cancel());
      final events = await collect(reader);
      expect(events.whereType<AgentCancelledEvent>().length, 1);
      expect(events.whereType<AgentMessageEvent>(), isEmpty);
      expect(events.whereType<AgentErrorEvent>(), isEmpty);
    });

    test('stops with a recoverable error after maxIterations', () async {
      final tool = ScriptedTool('t', (ctx, args) async => const ToolOutput(content: 'again'));
      final model = ScriptedChatModel([
        for (var i = 0; i < 3; i++) [toolCallDelta(0, id: 'c$i', name: 't', args: '{}'), finish('tool_calls')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model, tools: [tool], maxIterations: 2));
      final events = await collect(await agent.run([Message.user('go')]));
      expect(tool.invocations.length, 2);
      final error = events.whereType<AgentErrorEvent>().single;
      expect(error.isRecoverable, isTrue);
      expect(error.error, contains('2 iterations'));
      expect(events.last, isA<AgentRunEndEvent>());
    });

    test('reasoning deltas are surfaced and reasoning_details echoed back', () async {
      final model = ScriptedChatModel([
        [
          reasoning('think').copyWith(extra: {'reasoning_details': [{'type': 'reasoning.text', 'text': 'think', 'index': 0}]}),
          toolCallDelta(0, id: 'c1', name: 't', args: '{}'),
          finish('tool_calls'),
        ],
        [text('ok'), finish('stop')],
      ]);
      final tool = ScriptedTool('t', (ctx, args) async => const ToolOutput(content: 'r'));
      final agent = ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model, tools: [tool]));
      final events = await collect(await agent.run([Message.user('go')]));
      expect(events.whereType<AgentReasoningEvent>().single.delta, 'think');
      final assistantTurn = model.allCalls[1].firstWhere((m) => m.role == RoleType.assistant);
      expect(assistantTurn.extra?['reasoning_details'], isA<List<dynamic>>());
      expect(assistantTurn.reasoningContent, 'think');
    });

    test('handlers run before/after the model and wrap tool calls in order', () async {
      final log = <String>[];
      final tool = ScriptedTool('t', (ctx, args) async {
        log.add('tool');
        return const ToolOutput(content: 'r');
      });
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 't', args: '{}'), finish('tool_calls')],
        [text('ok'), finish('stop')],
      ]);
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'k',
        model: model,
        tools: [tool],
        handlers: [_LogHandler('A', log), _LogHandler('B', log)],
      ));
      await collect(await agent.run([Message.user('go')]));
      expect(log, [
        'A.before', 'B.before', 'A.after', 'B.after',
        'A.wrap>', 'B.wrap>', 'tool', 'B.wrap<', 'A.wrap<',
        'A.before', 'B.before', 'A.after', 'B.after',
      ]);
    });
  });

  group('HistoryBudgetHandler', () {
    test('drops oldest turns and orphaned tool results, keeps system + tail', () {
      final messages = [
        Message.system('sys'),
        Message.user('x' * 100),
        Message.assistant('', toolCalls: [ToolCall(id: 'c1', function: const FunctionCall(name: 't', arguments: '{}'))]),
        Message.tool(content: 'y' * 100, toolCallId: 'c1'),
        Message.assistant('z' * 100),
        Message.user('latest'),
      ];
      final trimmed = const HistoryBudgetHandler(maxChars: 150, keepLastTurns: 1).trim(messages);
      expect(trimmed.first.role, RoleType.system);
      expect(trimmed.any((m) => m.toolCallId == 'c1'), isFalse, reason: 'orphan tool result removed with its call');
      expect(trimmed.last.content, 'latest');
      expect(trimmed.length, lessThan(messages.length));
    });
  });

  group('Runner', () {
    test('assembles a RunResult and tracks one run per session', () async {
      final model = ScriptedChatModel([
        [text('hi'), finish('stop', usage: usage)],
      ]);
      final runner = Runner(agent: ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model)));
      final handle = await runner.run([Message.user('x')], sessionId: 's1');
      expect(runner.activeRun('s1'), same(handle));
      expect(() => runner.run([Message.user('y')], sessionId: 's1'), throwsA(isA<RunInProgressException>()));
      final seen = await handle.events.toList();
      final result = await handle.result;
      expect(seen.whereType<AgentRunEndEvent>().length, 1);
      expect(result.finalMessage?.content, 'hi');
      expect(result.messages.single.content, 'hi');
      expect(result.usage.cost, 0.001);
      expect(result.succeeded, isTrue);
      expect(runner.activeRun('s1'), isNull);
    });

    test('approve() answers pending approvals; timeout applies the default', () async {
      final tool = ScriptedTool('delete', (ctx, args) async => const ToolOutput(content: 'gone'));
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'delete', args: '{}'), finish('tool_calls')],
        [toolCallDelta(0, id: 'c2', name: 'delete', args: '{}'), finish('tool_calls')],
        [text('ok'), finish('stop')],
      ]);
      final runner = Runner(
        agent: ChatModelAgent(ChatModelAgentConfig(
          name: 'k', model: model, tools: [tool],
          approvalPolicy: const ApprovalPolicy(toolsRequiringApproval: {'delete'}),
        )),
        approvalTimeout: const Duration(milliseconds: 20),
        defaultApproval: false,
      );
      final handle = await runner.run([Message.user('x')]);
      final events = <AgentEvent>[];
      final sub = handle.events.listen((e) {
        events.add(e);
        if (e is AgentApprovalRequestEvent && e.toolCall.id == 'c1') {
          expect(handle.pendingApprovalIds, contains('c1'));
          expect(handle.approve('c1', allow: true), isTrue);
        }
        // c2: nobody answers → default deny after the timeout
      });
      final result = await handle.result;
      await sub.cancel();
      final results = events.whereType<ToolResultEvent>().toList();
      expect(results[0].result, 'gone');
      expect(results[1].isError, isTrue);
      expect(result.succeeded, isTrue);
      expect(handle.approve('c2', allow: true), isFalse, reason: 'already resolved');
    });

    test('cancel() marks the result cancelled', () async {
      final model = ScriptedChatModel([
        [text('a'), text('b'), finish('stop')],
      ], delayPerChunk: const Duration(milliseconds: 40));
      final runner = Runner(agent: ChatModelAgent(ChatModelAgentConfig(name: 'k', model: model)));
      final handle = await runner.run([Message.user('x')], sessionId: 's');
      Future<void>.delayed(const Duration(milliseconds: 20), () => handle.cancel('stop'));
      await handle.events.drain<void>();
      final result = await handle.result;
      expect(result.cancelled, isTrue);
      expect(runner.activeRun('s'), isNull);
    });
  });
}

class _LogHandler extends AgentHandler {
  const _LogHandler(this.id, this.log);

  final String id;
  final List<String> log;

  @override
  Future<void> beforeModel(ChatModelAgentState state) async => log.add('$id.before');

  @override
  Future<void> afterModel(ChatModelAgentState state, Message response) async => log.add('$id.after');

  @override
  Future<ToolOutput> wrapToolCall(ToolCallContext context, String argumentsJson, ToolCallNext next) async {
    log.add('$id.wrap>');
    final out = await next(context, argumentsJson);
    log.add('$id.wrap<');
    return out;
  }
}
