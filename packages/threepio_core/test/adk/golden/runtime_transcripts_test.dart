// Golden transcripts of the Kortney-facing runtime: `Runner`, `ChatModelAgent`
// and the events they emit.
//
// Each test drives one scenario with a scripted model and compares the model
// inputs, every event and the `RunResult` with a checked-in JSON file. The
// files are the behavioural contract a later re-implementation of the runtime
// has to keep. See `test/support/transcript.dart` for how to record them.
//
// Nothing here waits on a real clock: runs are steered by completers, and the
// two timeout scenarios use timeouts of a few milliseconds.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../support/event_collector.dart';
import '../../support/scripted_chat_model.dart';
import '../../support/transcript.dart';

const _instruction = 'You are Kortney. Answer briefly.';
const _usage = TokenUsage(
  promptTokens: 10,
  completionTokens: 5,
  totalTokens: 15,
  cost: 0.001,
);

/// A future that never completes: a tool or a stream that hangs.
Future<void> _never() => Completer<void>().future;

/// Runs [model] the way Kortney does and returns the live run.
Future<(RunHandle, EventCollector)> _start(
  ScriptedChatModel model, {
  List<Message>? history,
  List<BaseTool> tools = const [],
  List<AgentHandler> handlers = const [],
  ApprovalPolicy approvalPolicy = const ApprovalPolicy(),
  int maxIterations = 20,
  Duration toolTimeout = const Duration(seconds: 120),
  bool emitPartialOutputs = true,
  Duration approvalTimeout = const Duration(seconds: 60),
  bool defaultApproval = false,
}) async {
  final runner = Runner(
    agent: ChatModelAgent(
      ChatModelAgentConfig(
        name: 'kortney',
        description: 'The assistant in the Kortney panel',
        instruction: _instruction,
        model: model,
        tools: tools,
        handlers: handlers,
        approvalPolicy: approvalPolicy,
        maxIterations: maxIterations,
        toolTimeout: toolTimeout,
        emitPartialOutputs: emitPartialOutputs,
      ),
    ),
    approvalTimeout: approvalTimeout,
    defaultApproval: defaultApproval,
  );

  final handle = await runner.run(
    history ?? [Message.user('What is on my clipboard?')],
    sessionId: 'session-1',
    metadata: const {'surface': 'panel'},
  );
  return (handle, EventCollector(handle));
}

/// Waits for the run to end and compares it with the golden file [name].
Future<RunResult> _expectTranscript(
  String name,
  ScriptedChatModel model,
  EventCollector collector,
) async {
  final (events, result) = await collector.finished();
  expect(collector.errors, isEmpty);
  expectGoldenTranscript(
    name,
    buildTranscript(events: events, result: result, modelCalls: model.calls),
  );
  return result;
}

ScriptedTool _clipboardTool() => ScriptedTool(
      'read_clipboard',
      (context, args) async => ToolOutput.json({'text': 'hello world'}),
      description: 'Reads the newest clip',
    );

List<Message> _callTurn(String id, String name, {String args = '{}'}) => [
      toolCallDelta(0, id: id, name: name, args: args),
      finish('tool_calls', usage: _usage),
    ];

void main() {
  test('a: streamed text answer', () async {
    final model = ScriptedChatModel([
      [text('Hel'), text('lo'), finish('stop', usage: _usage)],
    ]);
    final (_, collector) = await _start(model);

    final result = await _expectTranscript('a_streamed_text', model, collector);

    expect(result.succeeded, isTrue);
    expect(result.finalMessage?.content, 'Hello');
  });

  test('b: reasoning deltas and reasoning_details round-trip', () async {
    final model = ScriptedChatModel([
      [
        reasoning('The user wants ').copyWith(
          extra: {
            'reasoning_details': [
              {'type': 'reasoning.text', 'text': 'The user wants ', 'index': 0},
            ],
          },
        ),
        reasoning('the clipboard.'),
        toolCallDelta(0, id: 'call_1', name: 'read_clipboard', args: '{}'),
        finish('tool_calls', usage: _usage),
      ],
      [text('It says hello world.'), finish('stop', usage: _usage)],
    ]);
    final (_, collector) = await _start(model, tools: [_clipboardTool()]);

    await _expectTranscript('b_reasoning_round_trip', model, collector);

    final echoed = model.calls[1].messages
        .firstWhere((m) => m.role == RoleType.assistant);
    expect(echoed.reasoningContent, 'The user wants the clipboard.');
    expect(echoed.extra?['reasoning_details'], isA<List<dynamic>>());
  });

  test('c: one tool call', () async {
    final tool = ScriptedTool(
      'search_clips',
      (context, args) async => ToolOutput.json({'query': args['value']}),
    );
    final model = ScriptedChatModel([
      [
        text('Let me look.'),
        toolCallDelta(0, id: 'call_1', name: 'search_clips', args: '{"value":'),
        toolCallDelta(0, args: ' "invoice"}'),
        finish('tool_calls', usage: _usage),
      ],
      [text('Found it.'), finish('stop', usage: _usage)],
    ]);
    final (_, collector) = await _start(model, tools: [tool]);

    final result = await _expectTranscript('c_one_tool_call', model, collector);

    expect(tool.invocations.single, {'value': 'invoice'});
    expect(result.usage.totalTokens, 30);
  });

  test('d: two parallel tool calls keep the order the model asked for',
      () async {
    final fastDone = Completer<void>();
    final slow = ScriptedTool('slow', (context, args) async {
      await fastDone.future;
      // Let the fast call report its result first.
      await Future<void>.delayed(Duration.zero);
      return ToolOutput.json({'v': args['value']});
    });
    final fast = ScriptedTool('fast', (context, args) async {
      fastDone.complete();
      return ToolOutput(content: 'fast:${args['value']}');
    });
    final model = ScriptedChatModel([
      [
        toolCallDelta(0, id: 'call_1', name: 'slow', args: '{"value": "a"}'),
        toolCallDelta(1, id: 'call_2', name: 'fast', args: '{"value": "b"}'),
        finish('tool_calls', usage: _usage),
      ],
      [text('Both done.'), finish('stop', usage: _usage)],
    ]);
    final (_, collector) = await _start(model, tools: [slow, fast]);

    final result =
        await _expectTranscript('d_parallel_tool_calls', model, collector);

    expect(
      collector.events.whereType<ToolResultEvent>().map((e) => e.toolName),
      ['fast', 'slow'],
    );
    expect(
      result.messages
          .where((m) => m.role == RoleType.tool)
          .map((m) => m.toolCallId),
      ['call_1', 'call_2'],
    );
  });

  group('approval', () {
    const policy = ApprovalPolicy(toolsRequiringApproval: {'delete_clip'});

    ScriptedTool deleteTool() => ScriptedTool(
          'delete_clip',
          (context, args) async => const ToolOutput(content: 'deleted'),
        );

    ScriptedChatModel deleteScript() => ScriptedChatModel([
          _callTurn('call_1', 'delete_clip'),
          [text('Done.'), finish('stop', usage: _usage)],
        ]);

    test('e: approve(allow: true) lets the tool run', () async {
      final tool = deleteTool();
      final model = deleteScript();
      final (handle, collector) =
          await _start(model, tools: [tool], approvalPolicy: policy);

      final request = await collector.first<AgentApprovalRequestEvent>();
      expect(handle.pendingApprovalIds, ['call_1']);
      expect(handle.approve(request.toolCall.id, allow: true), isTrue);

      await _expectTranscript('e_approval_allowed', model, collector);
      expect(tool.invocations, hasLength(1));
      expect(handle.pendingApprovalIds, isEmpty);
    });

    test('f: approve(allow: false) turns the call into an error result',
        () async {
      final tool = deleteTool();
      final model = deleteScript();
      final (handle, collector) =
          await _start(model, tools: [tool], approvalPolicy: policy);

      final request = await collector.first<AgentApprovalRequestEvent>();
      expect(handle.approve(request.toolCall.id, allow: false), isTrue);

      await _expectTranscript('f_approval_denied', model, collector);
      expect(tool.invocations, isEmpty);
    });

    test('g: an unanswered request is denied when defaultApproval is false',
        () async {
      final tool = deleteTool();
      final model = deleteScript();
      final (handle, collector) = await _start(
        model,
        tools: [tool],
        approvalPolicy: policy,
        approvalTimeout: const Duration(milliseconds: 5),
      );

      await _expectTranscript('g_approval_timeout_denied', model, collector);
      expect(tool.invocations, isEmpty);
      expect(handle.approve('call_1', allow: true), isFalse);
    });

    test('g: an unanswered request is allowed when defaultApproval is true',
        () async {
      final tool = deleteTool();
      final model = deleteScript();
      final (_, collector) = await _start(
        model,
        tools: [tool],
        approvalPolicy: policy,
        approvalTimeout: const Duration(milliseconds: 5),
        defaultApproval: true,
      );

      await _expectTranscript('g_approval_timeout_allowed', model, collector);
      expect(tool.invocations, hasLength(1));
    });
  });

  test('h: a tool returning artifacts', () async {
    final tool = ScriptedTool(
      'capture_screen',
      (context, args) async => const ToolOutput(
        content: 'Captured the screen.',
        artifacts: [
          ToolArtifact(
            id: 'artifact_1',
            path: '/tmp/kortney/capture.png',
            mime: 'image/png',
            width: 1280,
            height: 720,
            bytes: 2048,
          ),
        ],
        data: {'display': 1},
      ),
    );
    final model = ScriptedChatModel([
      _callTurn('call_1', 'capture_screen'),
      [text('Here it is.'), finish('stop', usage: _usage)],
    ]);
    final (_, collector) = await _start(model, tools: [tool]);

    await _expectTranscript('h_tool_artifacts', model, collector);

    expect(collector.events.whereType<AgentArtifactEvent>(), hasLength(1));
  });

  test('i: an unknown tool and a throwing tool become error results',
      () async {
    final boom = ScriptedTool(
      'boom',
      (context, args) async => throw StateError('kaput'),
    );
    final model = ScriptedChatModel([
      [
        toolCallDelta(0, id: 'call_1', name: 'no_such_tool', args: '{}'),
        toolCallDelta(1, id: 'call_2', name: 'boom', args: '{}'),
        finish('tool_calls', usage: _usage),
      ],
      [text('Neither worked.'), finish('stop', usage: _usage)],
    ]);
    final (_, collector) = await _start(model, tools: [boom]);

    final result =
        await _expectTranscript('i_unknown_and_throwing_tool', model, collector);

    expect(result.succeeded, isTrue);
    expect(collector.events.whereType<AgentErrorEvent>(), isEmpty);
  });

  test('j: a tool that exceeds toolTimeout becomes an error result', () async {
    final hang = ScriptedTool('hang', (context, args) async {
      await _never();
      return const ToolOutput(content: 'too late');
    });
    final model = ScriptedChatModel([
      _callTurn('call_1', 'hang'),
      [text('It timed out.'), finish('stop', usage: _usage)],
    ]);
    final (_, collector) = await _start(
      model,
      tools: [hang],
      toolTimeout: const Duration(milliseconds: 5),
    );

    await _expectTranscript('j_tool_timeout', model, collector);
  });

  test('k: cancel during the model stream', () async {
    final resume = Completer<void>();
    final model = ScriptedChatModel.turns([
      ScriptedTurn(
        [text('Hel'), text('lo'), finish('stop', usage: _usage)],
        before: {1: resume.future},
      ),
    ]);
    final (handle, collector) = await _start(model);

    await collector.first<AgentOutputEvent>(where: (e) => e.isPartial);
    handle.cancel('user pressed stop');
    resume.complete();

    final result =
        await _expectTranscript('k_cancel_during_model_stream', model, collector);
    expect(result.cancelled, isTrue);
    expect(result.succeeded, isFalse);
    expect(result.messages, isEmpty);
  });

  test('l: cancel during tool execution', () async {
    final hang = ScriptedTool('hang', (context, args) async {
      await _never();
      return const ToolOutput(content: 'too late');
    });
    final quick = ScriptedTool(
      'quick',
      (context, args) async => const ToolOutput(content: 'quick result'),
    );
    final model = ScriptedChatModel([
      [
        toolCallDelta(0, id: 'call_1', name: 'hang', args: '{}'),
        toolCallDelta(1, id: 'call_2', name: 'quick', args: '{}'),
        finish('tool_calls', usage: _usage),
      ],
      [text('never reached'), finish('stop')],
    ]);
    final (handle, collector) = await _start(model, tools: [hang, quick]);

    await collector.first<ToolResultEvent>(where: (e) => e.toolName == 'quick');
    expect(hang.invocations, hasLength(1));
    handle.cancel('user pressed stop');

    final result = await _expectTranscript(
      'l_cancel_during_tool_execution',
      model,
      collector,
    );
    final cancelled = collector.events.whereType<AgentCancelledEvent>().single;
    expect(cancelled.cancelledToolCallIds, ['call_1']);
    expect(result.cancelled, isTrue);
    expect(model.calls, hasLength(1), reason: 'no model call after cancel');
  });

  test('m: max iterations reached', () async {
    final tool = ScriptedTool(
      'again',
      (context, args) async => const ToolOutput(content: 'try again'),
    );
    final model = ScriptedChatModel([
      for (var i = 1; i <= 3; i++) _callTurn('call_$i', 'again'),
    ]);
    final (_, collector) =
        await _start(model, tools: [tool], maxIterations: 2);

    final result =
        await _expectTranscript('m_max_iterations', model, collector);

    expect(tool.invocations, hasLength(2));
    expect(result.succeeded, isTrue, reason: 'the error is recoverable');
  });

  test('n: the model request fails', () async {
    final model = ScriptedChatModel.turns([
      const ScriptedTurn.failure(FormatException('bad gateway')),
    ]);
    final (_, collector) = await _start(model);

    final result =
        await _expectTranscript('n_model_error_on_request', model, collector);

    expect(result.succeeded, isFalse);
    expect(result.error, contains('bad gateway'));
  });

  test('n: the model stream fails after a partial answer', () async {
    final model = ScriptedChatModel.turns([
      ScriptedTurn(
        [text('Hel')],
        error: const FormatException('connection reset'),
      ),
    ]);
    final (_, collector) = await _start(model);

    final result =
        await _expectTranscript('n_model_error_mid_stream', model, collector);

    expect(result.succeeded, isFalse);
    expect(result.finalMessage, isNull);
  });

  test('o: emitPartialOutputs false', () async {
    final model = ScriptedChatModel([
      [
        reasoning('thinking'),
        text('Hel'),
        text('lo'),
        finish('stop', usage: _usage),
      ],
    ]);
    final (_, collector) = await _start(model, emitPartialOutputs: false);

    await _expectTranscript('o_no_partial_outputs', model, collector);

    expect(
      collector.events.whereType<AgentOutputEvent>().map((e) => e.isPartial),
      [false],
    );
  });

  test('p: HistoryBudgetHandler trims what the model is sent', () async {
    final history = [
      Message.user('Old question ${'x' * 100}'),
      Message.assistant(
        '',
        toolCalls: [
          const ToolCall(
            id: 'old_call',
            function: FunctionCall(name: 'read_clipboard', arguments: '{}'),
          ),
        ],
      ),
      Message.tool(content: 'y' * 100, toolCallId: 'old_call'),
      Message.assistant('Old answer ${'z' * 100}'),
      Message.user('Latest question'),
    ];
    final model = ScriptedChatModel([
      [text('Short answer.'), finish('stop', usage: _usage)],
    ]);
    final (_, collector) = await _start(
      model,
      history: history,
      tools: [_clipboardTool()],
      handlers: const [HistoryBudgetHandler(maxChars: 150, keepLastTurns: 1)],
    );

    await _expectTranscript('p_history_budget_trimming', model, collector);

    final sent = model.calls.single.messages;
    expect(sent.first.role, RoleType.system);
    expect(sent.last.content, 'Latest question');
    expect(sent.any((m) => m.toolCallId == 'old_call'), isFalse);
    expect(sent.length, lessThan(history.length + 1));
  });
}
