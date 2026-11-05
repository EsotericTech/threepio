/// What one run of the Kortney runtime keeps while it runs on the
/// Eino-shaped engine: the legacy handler state, the tool calls and results,
/// and the signals the facade's middlewares send to its event mapper.
library;

import 'package:meta/meta.dart';

import '../../core/run_context.dart';
import '../../schema/message.dart';
import '../eino/message_id.dart';
import 'agent_handler.dart';
import 'chat_model_agent.dart';
import 'tool_call_context.dart';

/// The state of one facade run, reached by the facade's middlewares, its
/// tool adapter and `ContextualTool` through the [RunContext].
@internal
final class LegacyRun {
  /// The run of [config] in [scope].
  LegacyRun({required this.scope, required this.config, required this.state});

  /// The legacy scope: ids, cancel token, approval channel, metadata.
  final AgentRunScope scope;

  /// The legacy configuration.
  final ChatModelAgentConfig config;

  /// The state the legacy handlers share for the whole run.
  final ChatModelAgentState state;

  /// Model calls so far; the legacy `state.iteration` of the next one.
  int modelCalls = 0;

  /// The model's message of the turn in progress, as the legacy runtime
  /// assembled it.
  Message? assembled;

  final Map<String, ToolCall> _calls = {};
  final Map<String, ToolOutput> _outputs = {};
  final Map<String, ToolCallContext> _contexts = {};
  final Map<String, Message> _toolMessages = {};

  /// Notes the tool calls of [response], the model's message of a turn.
  void noteToolCalls(Message response) {
    for (final call in response.toolCalls ?? const <ToolCall>[]) {
      _calls[call.id] = call;
    }
  }

  /// The tool call [callId] as the model sent it, or one made from [name]
  /// and [arguments].
  ToolCall toolCallFor(String callId, String name, String arguments) =>
      _calls[callId] ??
      ToolCall(
        id: callId,
        function: FunctionCall(name: name, arguments: arguments),
      );

  /// The context the handlers and the tool of [call] get; a handler may hand
  /// a different one on with [setContext].
  ToolCallContext contextFor(ToolCall call) => _contexts[call.id] ??=
      ToolCallContext(
        runId: scope.runId,
        sessionId: scope.sessionId,
        toolCall: call,
        cancelToken: scope.cancelToken,
        metadata: scope.metadata,
      );

  /// Hands [context] on to the inner layers of the call [callId].
  void setContext(String callId, ToolCallContext context) =>
      _contexts[callId] = context;

  /// Notes what a layer of the call [callId] produced.
  void setOutput(String callId, ToolOutput output) => _outputs[callId] = output;

  /// The output behind [content], the text an inner layer of the call
  /// [callId] returned.
  ToolOutput outputFor(String callId, String content) {
    final output = _outputs[callId];
    if (output != null && legacyToolContent(output) == content) return output;
    return ToolOutput(content: content);
  }

  /// Notes the tool message the legacy runtime keeps for [call].
  void noteToolMessage(ToolCall call, ToolOutput output) =>
      _toolMessages[call.id] = legacyToolMessage(call, output);

  /// [message] as the legacy runtime has it in its history: a tool result of
  /// this run as the legacy runtime built it, any other message without the
  /// engine's message id.
  Message legacyShaped(Message message) {
    if (message.role == RoleType.tool) {
      final kept = _toolMessages[message.toolCallId];
      if (kept != null) return kept;
    }
    return withoutMessageId(message);
  }
}

final _runKey = ContextKey<LegacyRun>('adk.runtime.legacyRun');

/// The facade run [ctx] belongs to.
@internal
LegacyRun? legacyRunOf(RunContext ctx) => ctx.value(_runKey);

/// [ctx] in the facade run [run].
@internal
RunContext withLegacyRun(RunContext ctx, LegacyRun run) =>
    ctx.withValue(_runKey, run);

/// The text the model sees for [output]. Port of the legacy runtime's tool
/// message content.
@internal
String legacyToolContent(ToolOutput output) =>
    output.isError ? 'Error: ${output.content}' : output.content;

/// The tool message the legacy runtime appends for [call].
@internal
Message legacyToolMessage(ToolCall call, ToolOutput output) => Message(
      role: RoleType.tool,
      content: legacyToolContent(output),
      toolCallId: call.id,
      toolName: call.function.name,
      extra: {
        if (output.isError) 'is_error': true,
        if (output.data != null) 'data': output.data,
        if (output.artifacts.isNotEmpty)
          'artifacts': output.artifacts.map((a) => a.toJson()).toList(),
      },
    );

/// The tool message of a call that was still running when the run was
/// cancelled.
@internal
Message legacyCancelledToolMessage(ToolCall call) => Message.tool(
      content: 'Error: cancelled by the user before it finished.',
      toolCallId: call.id,
      toolName: call.function.name,
    );

/// [message] without the engine's message id. When the id was all its extra
/// held, the extra goes away, as the legacy runtime had none.
@internal
Message withoutMessageId(Message message) {
  final extra = message.extra;
  if (extra == null || !extra.containsKey(einoMessageIdKey)) return message;
  final rest = Map<String, dynamic>.of(extra)..remove(einoMessageIdKey);
  return message.copyWith(extra: rest.isEmpty ? null : rest);
}

/// Joins the streamed deltas of the model into one assistant message, as the
/// legacy runtime did: the lenient concat, every chunk as an assistant
/// chunk, tool calls without a name dropped, and an empty assistant message
/// for no chunks.
@internal
Message legacyAssemble(List<Message> chunks) {
  if (chunks.isEmpty) return Message.assistant('');
  final merged = MessageConcatenator.concat(
    chunks.map((c) => c.copyWith(role: RoleType.assistant)).toList(),
  );
  final calls =
      merged.toolCalls?.where((c) => c.function.name.isNotEmpty).toList();
  return merged.copyWith(
    toolCalls: calls == null || calls.isEmpty ? null : calls,
  );
}

/// What the facade's middlewares tell its event mapper, through the
/// engine's event stream (so in order with the model and tool events).
@internal
sealed class FacadeSignal {
  const FacadeSignal();
}

/// The model turn is done: the legacy `afterModel` handlers have run.
@internal
final class FacadeTurnDone extends FacadeSignal {
  const FacadeTurnDone(this.response);

  final Message response;
}

/// A tool call waits for the user's approval.
@internal
final class FacadeApprovalRequested extends FacadeSignal {
  const FacadeApprovalRequested(this.call, this.reason);

  final ToolCall call;
  final String reason;
}

/// A tool call did not start: the run was cancelled before its turn came
/// (sequential execution only, as in the legacy runtime).
@internal
final class FacadeToolSkipped extends FacadeSignal {
  const FacadeToolSkipped(this.call);

  final ToolCall call;
}

/// A tool call has its result.
@internal
final class FacadeToolResult extends FacadeSignal {
  const FacadeToolResult(this.call, this.output, this.durationMs);

  final ToolCall call;
  final ToolOutput output;
  final int durationMs;
}
