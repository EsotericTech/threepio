/// What an agent run keeps in the [RunContext]: session values, the input of
/// the run, run-local values and the event sink of a `ChatModelAgent`.
///
/// Port of eino `adk/runctx.go` and of the run-local and event functions of
/// `adk/handler.go`.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../components/model/base_chat_model.dart';
import '../../compose/local_state.dart';
import '../../compose/tools_node.dart';
import '../../core/run_context.dart';
import '../../schema/type_registry.dart';
import '../../streaming/stream_writer.dart';
import 'agent.dart';
import 'agent_action.dart';
import 'agent_event.dart';
import 'cancel.dart';
import 'model_retry.dart';
import 'react_graph.dart';

/// The values one run shares between its agents. Port of eino `runSession`
/// (its values; the event history of agent transfer is not ported).
@internal
final class RunSession {
  /// A session with [values], or empty.
  RunSession([Map<String, Object?>? values]) : values = values ?? {};

  /// The session values, shared by every agent of the run.
  final Map<String, Object?> values;
}

/// The run an agent belongs to. Port of eino `runContext` (`RunPath`, which
/// belongs to agent transfer, is not ported; [depth] stands in for its
/// length).
@internal
final class AdkRunContext {
  /// The context of a run with [session].
  const AdkRunContext({required this.session, this.rootInput, this.depth = 0});

  /// The input the run was started with.
  final AgentInput? rootInput;

  /// The session values of the run.
  final RunSession session;

  /// How many agents deep the current agent is: 1 for the agent the runner
  /// started.
  final int depth;

  /// Whether the current agent is the one the runner started.
  bool get isRoot => depth == 1;
}

final class _RunSlot {
  const _RunSlot(this.run);

  final AdkRunContext? run;
}

final _runKey = ContextKey<_RunSlot>('adk.runContext');

/// The run [ctx] belongs to. Port of eino `getRunCtx`.
@internal
AdkRunContext? adkRunContextOf(RunContext ctx) => ctx.value(_runKey)?.run;

/// [ctx] in the run [run]. Port of eino `setRunCtx`.
@internal
RunContext withAdkRunContext(RunContext ctx, AdkRunContext? run) =>
    ctx.withValue(_runKey, _RunSlot(run));

/// [ctx] for the agent [agentName] entering its run. Port of eino
/// `initRunCtx`: the session is shared, and the input becomes the root input
/// when the agent is the first one.
@internal
(RunContext, AdkRunContext) initAdkRunContext(
  RunContext ctx,
  String agentName,
  AgentInput? input,
) {
  final current = adkRunContextOf(ctx);
  final depth = (current?.depth ?? 0) + 1;
  final run = AdkRunContext(
    session: current?.session ?? RunSession(),
    rootInput: depth == 1 && input != null ? input : current?.rootInput,
    depth: depth,
  );
  return (withAdkRunContext(ctx, run), run);
}

/// [ctx] for a new run with [input]. Port of eino `ctxWithNewTypedRunCtx`:
/// with [sharedParentSession] the session values of the run around are
/// shared (an `AgentTool`'s agent sees the values of its caller).
@internal
RunContext withNewAdkRunContext(
  RunContext ctx,
  AgentInput input, {
  bool sharedParentSession = false,
}) {
  final parent = sharedParentSession ? adkRunContextOf(ctx)?.session : null;
  return withAdkRunContext(
    ctx,
    AdkRunContext(session: parent ?? RunSession(), rootInput: input),
  );
}

/// What a `ChatModelAgent` run keeps for its wrappers and tools. Port of
/// eino `typedChatModelAgentExecCtx`.
@internal
final class ChatModelAgentExecContext {
  /// The context of a run that sends its events to [writer].
  ChatModelAgentExecContext({
    required this.writer,
    this.runtimeReturnDirectly = const {},
    this.cancelContext,
    this.failoverLastSuccessModel,
    this.afterToolCallsHook,
  });

  /// Where the agent's events go.
  final StreamWriter<AgentEvent> writer;

  /// The `returnDirectly` tools after the middlewares' `beforeAgent`.
  final Set<String> runtimeReturnDirectly;

  /// The cancel context of the run, if it can be cancelled.
  final CancelContext? cancelContext;

  /// The model of the last successful call, for failover.
  BaseChatModel? failoverLastSuccessModel;

  /// Set while a retry attempt runs whose output may be rejected: the event
  /// sender then sends nothing.
  bool suppressEventSend = false;

  /// The verdict channel of the stream retry that is in progress.
  RetryVerdictSignal? retryVerdictSignal;

  /// The hook of `AgentRunOption.afterToolCallsHook`.
  final FutureOr<void> Function(RunContext ctx)? afterToolCallsHook;

  /// Sends [event] to the agent's caller; dropped once the run is being torn
  /// down at once (work that was cut off may still try to report). Port of
  /// `typedChatModelAgentExecCtx.send`.
  void send(AgentEvent event) {
    if (cancelContext?.isImmediateCancelled ?? false) return;
    writer.send(event);
  }
}

final _execKey = ContextKey<ChatModelAgentExecContext>('adk.execContext');

/// The `ChatModelAgent` run [ctx] belongs to.
@internal
ChatModelAgentExecContext? execContextOf(RunContext ctx) => ctx.value(_execKey);

/// [ctx] inside the `ChatModelAgent` run [exec].
@internal
RunContext withExecContext(RunContext ctx, ChatModelAgentExecContext exec) =>
    ctx.withValue(_execKey, exec);

/// Session values, run-local values and events of the agent run a context
/// belongs to.
///
/// Port of eino `adk.GetSessionValues`, `AddSessionValue`,
/// `AddSessionValues`, `GetSessionValue`, `ClearRunCtx`, `SetRunLocalValue`,
/// `GetRunLocalValue`, `DeleteRunLocalValue` and `SendEvent`.
extension AgentContext on RunContext {
  /// A copy of the session values of the run; empty outside a run. Port of
  /// eino `adk.GetSessionValues`.
  ///
  /// Session values are shared by all agents of a run (and by the agent
  /// behind an `AgentTool`). A `ChatModelAgent` with the default
  /// `genModelInput` fills `{key}` placeholders of its instruction from them.
  Map<String, Object?> get sessionValues =>
      Map.of(adkRunContextOf(this)?.session.values ?? const {});

  /// Sets the session value [key]; does nothing outside a run. Port of eino
  /// `adk.AddSessionValue`.
  void addSessionValue(String key, Object? value) =>
      adkRunContextOf(this)?.session.values[key] = value;

  /// Sets several session values; does nothing outside a run. Port of eino
  /// `adk.AddSessionValues`.
  void addSessionValues(Map<String, Object?> values) =>
      adkRunContextOf(this)?.session.values.addAll(values);

  /// The session value [key], or `null`. Port of eino `adk.GetSessionValue`;
  /// [hasSessionValue] tells a missing key from a `null` value.
  Object? sessionValue(String key) => adkRunContextOf(this)?.session.values[key];

  /// Whether the session has a value under [key].
  bool hasSessionValue(String key) =>
      adkRunContextOf(this)?.session.values.containsKey(key) ?? false;

  /// This context without the agent run it belongs to: an agent run from
  /// here starts a run of its own. Port of eino `adk.ClearRunCtx`.
  RunContext clearRunContext() => withAdkRunContext(this, null);

  /// Sets the run-local value [key] of the `ChatModelAgent` run this context
  /// belongs to.
  ///
  /// Port of eino `adk.SetRunLocalValue`. Run-local values live in the
  /// agent's state for one run (also across an interrupt and its resume) and
  /// are what middlewares keep between their hooks. The value is written to
  /// checkpoints, so it must be JSON or of a type registered with
  /// [TypeRegistry] ([ArgumentError] otherwise). Throws [StateError] outside a
  /// `ChatModelAgent` run.
  void setRunLocalValue(String key, Object? value) {
    try {
      TypeRegistry.encode(value);
      // An unencodable value is reported by the registry as an ArgumentError.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (error) {
      throw ArgumentError.value(
        value,
        'value',
        'setRunLocalValue: the value for key "$key" cannot be written to a '
            'checkpoint, which would fail when the agent interrupts. Register '
            'its type with TypeRegistry.registerName, or keep the value in the '
            'RunContext instead (${error.message})',
      );
    }
    (_reactStateOf(this, 'setRunLocalValue').extra ??= {})[key] = value;
  }

  /// The run-local value [key], or `null`. Port of eino
  /// `adk.GetRunLocalValue`. Throws [StateError] outside a `ChatModelAgent`
  /// run.
  Object? runLocalValue(String key) =>
      _reactStateOf(this, 'runLocalValue').extra?[key];

  /// Whether the run has a run-local value under [key] (eino's `found`).
  /// Throws [StateError] outside a `ChatModelAgent` run.
  bool hasRunLocalValue(String key) =>
      _reactStateOf(this, 'hasRunLocalValue').extra?.containsKey(key) ?? false;

  /// Removes the run-local value [key]. Port of eino
  /// `adk.DeleteRunLocalValue`. Throws [StateError] outside a
  /// `ChatModelAgent` run.
  void deleteRunLocalValue(String key) =>
      _reactStateOf(this, 'deleteRunLocalValue').extra?.remove(key);

  /// Sends [event] to the caller of the `ChatModelAgent` run this context
  /// belongs to, in order with the agent's own events.
  ///
  /// Port of eino `adk.SendEvent`. Throws [StateError] outside a
  /// `ChatModelAgent` run. Give a message an id with `ensureMessageId` if it
  /// should carry one like the agent's own.
  Future<void> sendEvent(AgentEvent event) async {
    final exec = execContextOf(this);
    if (exec == null) {
      throw StateError(
        'sendEvent failed: must be called within a ChatModelAgent run() or '
        'resume() execution context',
      );
    }
    exec.send(event);
  }
}

ReactState _reactStateOf(RunContext ctx, String operation) {
  for (var holder = internalStateOf(ctx); holder != null; holder = holder.parent) {
    final state = holder.state;
    if (state is ReactState) return state;
  }
  throw StateError(
    '$operation failed: must be called within a ChatModelAgent run() or '
    'resume() execution context',
  );
}

/// Attaches [action] to the event of the tool call that is running in
/// [ctx].
///
/// Port of eino `adk.SendToolGenAction`. Call it inside a tool of a
/// `ChatModelAgent`; the action is taken off when the tool's result event is
/// sent. It is kept by tool call id, or by [toolName] when [ctx] has none.
/// Fails with [StateError] outside a `ChatModelAgent` run.
Future<void> sendToolGenAction(
  RunContext ctx,
  String toolName,
  AgentAction action,
) {
  final callId = toolCallIdOf(ctx);
  final key = callId == null || callId.isEmpty ? toolName : callId;
  return processState<ReactState>(
    ctx,
    (_, state) => state.setToolGenAction(key, action),
  );
}
