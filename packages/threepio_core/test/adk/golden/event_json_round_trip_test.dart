// `AgentEvent.toJson()` / `AgentEvent.fromJson()` is how Kortney stores and
// replays runs. Every event and action class has to survive the round trip
// through real JSON text.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

final _timestamp = DateTime.utc(2026, 11, 5, 9, 30, 15, 123);
const _runId = 'run_42';

final _toolCall = ToolCall(
  id: 'call_1',
  function: const FunctionCall(name: 'read_clipboard', arguments: '{"n": 1}'),
  index: 0,
);

final _assistant = Message.assistant(
  'Reading the clipboard.',
  toolCalls: [_toolCall],
).copyWith(
  reasoningContent: 'The user wants the clipboard.',
  responseMeta: const ResponseMeta(
    finishReason: 'tool_calls',
    usage: TokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
  ),
  extra: {
    'reasoning_details': [
      {'type': 'reasoning.text', 'text': 'The user wants the clipboard.'},
    ],
  },
);

/// One instance of every [AgentEvent] class, with every field set.
final List<AgentEvent> _events = [
  AgentRunStartEvent(
    runId: _runId,
    timestamp: _timestamp,
    agentName: 'kortney',
    inputMessages: [Message.system('Be brief.'), Message.user('Hi')],
    parentRunId: 'run_41',
    metadata: {'surface': 'panel', 'attempt': 2},
  ),
  AgentRunEndEvent(
    runId: _runId,
    timestamp: _timestamp,
    agentName: 'kortney',
    outputMessage: _assistant,
    durationMs: 1234,
    toolCallCount: 2,
  ),
  AgentOutputEvent(
    runId: _runId,
    timestamp: _timestamp,
    message: Message.assistant('Hel'),
    isPartial: true,
  ),
  AgentOutputEvent(runId: _runId, timestamp: _timestamp, message: _assistant),
  AgentActionEvent(
    runId: _runId,
    timestamp: _timestamp,
    action: const ToolCallAction(
      toolCallId: 'call_1',
      toolName: 'read_clipboard',
      arguments: '{"n": 1}',
    ),
    stepNumber: 3,
  ),
  ToolResultEvent(
    runId: _runId,
    timestamp: _timestamp,
    toolCallId: 'call_1',
    toolName: 'read_clipboard',
    result: 'read_clipboard failed: no access',
    isError: true,
    durationMs: 17,
  ),
  AgentTransferEvent(
    runId: _runId,
    timestamp: _timestamp,
    fromAgent: 'kortney',
    toAgent: 'researcher',
    reason: 'needs the web',
    context: {'topic': 'dart'},
  ),
  AgentErrorEvent(
    runId: _runId,
    timestamp: _timestamp,
    error: 'FormatException: bad gateway',
    stackTrace: '#0 main (file.dart:1:1)',
    isRecoverable: true,
  ),
  AgentStateUpdateEvent(
    runId: _runId,
    timestamp: _timestamp,
    stateName: 'mode',
    newValue: 'tools',
    previousValue: 'chat',
  ),
  AgentReasoningEvent(runId: _runId, timestamp: _timestamp, delta: 'think'),
  AgentMessageEvent(
    runId: _runId,
    timestamp: _timestamp,
    message: Message.tool(
      content: 'hello world',
      toolCallId: 'call_1',
      toolName: 'read_clipboard',
    ),
  ),
  AgentApprovalRequestEvent(
    runId: _runId,
    timestamp: _timestamp,
    toolCall: _toolCall,
    reason: 'read_clipboard needs your confirmation',
  ),
  AgentArtifactEvent(
    runId: _runId,
    timestamp: _timestamp,
    toolCallId: 'call_1',
    artifact: const ToolArtifact(
      id: 'artifact_1',
      path: '/tmp/kortney/capture.png',
      mime: 'image/png',
      width: 1280,
      height: 720,
      bytes: 2048,
    ),
  ),
  AgentCancelledEvent(
    runId: _runId,
    timestamp: _timestamp,
    reason: 'user pressed stop',
    cancelledToolCallIds: const ['call_1', 'call_2'],
  ),
  AgentUsageEvent(
    runId: _runId,
    timestamp: _timestamp,
    usage: const TokenUsage(
      promptTokens: 10,
      completionTokens: 5,
      totalTokens: 15,
      cost: 0.001,
    ),
    model: 'z-ai/glm-5.3',
    latency: const Duration(milliseconds: 250),
  ),
];

/// One instance of every [AgentAction] class, with every field set.
const List<AgentAction> _actions = [
  ToolCallAction(
    toolCallId: 'call_1',
    toolName: 'read_clipboard',
    arguments: '{"n": 1}',
  ),
  TransferToAgentAction(
    targetAgent: 'researcher',
    reason: 'needs the web',
    context: {'topic': 'dart'},
  ),
  FinishAction(output: 'All done.', summary: 'done'),
  ThinkAction(thought: 'What next?'),
  RequestInputAction(
    prompt: 'Which file?',
    inputType: 'choice',
    options: ['a.txt', 'b.txt'],
  ),
];

/// Exhaustive on purpose: a new event class does not compile until it is
/// listed here and added to [_events].
String _eventClass(AgentEvent event) => switch (event) {
      AgentRunStartEvent() => 'AgentRunStartEvent',
      AgentRunEndEvent() => 'AgentRunEndEvent',
      AgentOutputEvent() => 'AgentOutputEvent',
      AgentActionEvent() => 'AgentActionEvent',
      ToolResultEvent() => 'ToolResultEvent',
      AgentTransferEvent() => 'AgentTransferEvent',
      AgentErrorEvent() => 'AgentErrorEvent',
      AgentStateUpdateEvent() => 'AgentStateUpdateEvent',
      AgentReasoningEvent() => 'AgentReasoningEvent',
      AgentMessageEvent() => 'AgentMessageEvent',
      AgentApprovalRequestEvent() => 'AgentApprovalRequestEvent',
      AgentArtifactEvent() => 'AgentArtifactEvent',
      AgentCancelledEvent() => 'AgentCancelledEvent',
      AgentUsageEvent() => 'AgentUsageEvent',
    };

/// Exhaustive on purpose, like [_eventClass].
String _actionClass(AgentAction action) => switch (action) {
      ToolCallAction() => 'ToolCallAction',
      TransferToAgentAction() => 'TransferToAgentAction',
      FinishAction() => 'FinishAction',
      ThinkAction() => 'ThinkAction',
      RequestInputAction() => 'RequestInputAction',
    };

/// What a consumer reads back after writing [json] to disk.
Map<String, dynamic> _throughText(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void main() {
  group('AgentEvent JSON round trip', () {
    test('covers all 14 event classes', () {
      expect(_events.map(_eventClass).toSet(), hasLength(14));
    });

    for (final event in _events) {
      final label = event is AgentOutputEvent && event.isPartial
          ? '${_eventClass(event)} (partial)'
          : _eventClass(event);

      test(label, () {
        final json = _throughText(event.toJson());

        final decoded = AgentEvent.fromJson(json);

        expect(_eventClass(decoded), _eventClass(event));
        expect(decoded.runId, _runId);
        expect(decoded.timestamp, _timestamp);
        expect(decoded.eventType, event.eventType);
        expect(_throughText(decoded.toJson()), json);
      });
    }

    test('an unknown event type is rejected', () {
      expect(
        () => AgentEvent.fromJson({'event_type': 'nope'}),
        throwsArgumentError,
      );
    });
  });

  group('AgentAction JSON round trip', () {
    test('covers all 5 action classes', () {
      expect(_actions.map(_actionClass).toSet(), hasLength(5));
    });

    for (final action in _actions) {
      test(_actionClass(action), () {
        final json = _throughText(action.toJson());

        final decoded = AgentAction.fromJson(json);

        expect(_actionClass(decoded), _actionClass(action));
        expect(decoded.description, action.description);
        expect(_throughText(decoded.toJson()), json);
      });
    }

    test('an unknown action type is rejected', () {
      expect(
        () => AgentAction.fromJson({'type': 'nope'}),
        throwsArgumentError,
      );
    });
  });
}
