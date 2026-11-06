/// What an agentic agent run keeps in the [RunContext], and the message ids
/// of agentic messages.
///
/// Port of the `*schema.AgenticMessage` instantiations of eino's
/// `typedChatModelAgentExecCtx`, `TypedSendEvent`, `GetMessageID` and
/// `EnsureMessageID`. Session values and run-local values are shared with
/// the classic path (`AgentContext`).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../core/run_context.dart';
import '../../schema/agentic_message.dart';
import '../../streaming/stream_writer.dart';
import '../eino/cancel.dart';
import 'agent_message_codec.dart';
import 'agentic_agent.dart';

/// What an `AgenticChatModelAgent` run keeps for its wrappers and tools.
/// Port of eino `typedChatModelAgentExecCtx[*schema.AgenticMessage]` (its
/// context key is separate from the classic one, as Go's key is per message
/// type).
@internal
final class AgenticExecContext {
  /// The context of a run that sends its events to [writer].
  AgenticExecContext({
    required this.writer,
    this.runtimeReturnDirectly = const {},
    this.cancelContext,
    this.afterToolCallsHook,
  });

  /// Where the agent's events go.
  final StreamWriter<AgenticAgentEvent> writer;

  /// The `returnDirectly` tools after the middlewares' `beforeAgent`.
  final Set<String> runtimeReturnDirectly;

  /// The cancel context of the run, if it can be cancelled.
  final CancelContext? cancelContext;

  /// The hook of `AgentRunOption.afterToolCallsHook`.
  final FutureOr<void> Function(RunContext ctx)? afterToolCallsHook;

  /// Sends [event] to the agent's caller; dropped once the run is being torn
  /// down at once. Port of `typedChatModelAgentExecCtx.send`.
  void send(AgenticAgentEvent event) {
    if (cancelContext?.isImmediateCancelled ?? false) return;
    writer.send(event);
  }
}

final _agenticExecKey =
    ContextKey<AgenticExecContext>('adk.agenticExecContext');

/// The `AgenticChatModelAgent` run [ctx] belongs to.
@internal
AgenticExecContext? agenticExecContextOf(RunContext ctx) =>
    ctx.value(_agenticExecKey);

/// [ctx] inside the `AgenticChatModelAgent` run [exec].
@internal
RunContext withAgenticExecContext(RunContext ctx, AgenticExecContext exec) =>
    ctx.withValue(_agenticExecKey, exec);

/// The events of the agentic agent run a context belongs to.
///
/// Port of eino `adk.TypedSendEvent[*schema.AgenticMessage]`. Session values
/// and run-local values are read and written with the classic
/// `AgentContext` extension, which serves both paths.
extension AgenticAgentContext on RunContext {
  /// Sends [event] to the caller of the `AgenticChatModelAgent` run this
  /// context belongs to, in order with the agent's own events.
  ///
  /// Port of eino `adk.TypedSendEvent`. Throws [StateError] outside an
  /// `AgenticChatModelAgent` run. A pure transport: give a message an id
  /// with [ensureAgenticMessageId] if it should carry one like the agent's
  /// own.
  Future<void> sendAgenticEvent(AgenticAgentEvent event) async {
    final exec = agenticExecContextOf(this);
    if (exec == null) {
      throw StateError(
        'TypedSendEvent failed: must be called within a ChatModelAgent Run() '
        'or Resume() execution context',
      );
    }
    exec.send(event);
  }
}

/// The id the ADK gave [message], or `''` when it has none.
///
/// Port of eino `adk.GetMessageID[*schema.AgenticMessage]`; the agentic twin
/// of `messageIdOf`. An `AgenticChatModelAgent` gives an id to every message
/// its model produces (the first chunk of a stream carries it) and to every
/// tool result; the event and the state share the id.
String agenticMessageIdOf(AgenticMessage message) =>
    agenticMessageCodec.messageIdOf(message);

/// [message] with an id, or [message] itself when it has one.
///
/// Port of eino `adk.EnsureMessageID[*schema.AgenticMessage]`; the agentic
/// twin of `ensureMessageId`.
AgenticMessage ensureAgenticMessageId(AgenticMessage message) =>
    ensureMessageIdWith(agenticMessageCodec, message);
