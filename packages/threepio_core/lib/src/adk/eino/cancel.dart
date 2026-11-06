/// Cancelling an agent run: at once, or at the next safe point.
///
/// Port of eino `adk/cancel.go`.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:meta/meta.dart';

import '../../components/model/base_chat_model.dart';
import '../../components/model/cancel_token.dart';
import '../../components/model/chat_model_options.dart';
import '../../compose/errors.dart';
import '../../compose/graph_interrupt.dart';
import '../../compose/interrupt.dart';
import '../../compose/tool_middleware.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../schema/tool_result.dart';
import '../../streaming/stream_reader.dart';
import 'agent_context.dart';
import 'agent_event.dart';
import 'run_options.dart';

/// A point of an agent run at which a cancel can take effect without cutting
/// work off.
///
/// Port of the safe-point values of eino `adk.CancelMode`. An empty set of
/// safe points means "cancel at once" (eino `CancelImmediate`); a set with
/// both cancels at whichever comes first.
enum CancelSafePoint {
  /// After the agent's next model call has finished (eino
  /// `CancelAfterChatModel`), before its tools run.
  afterChatModel,

  /// After the agent's next round of tool calls has finished (eino
  /// `CancelAfterToolCalls`), before its next model call.
  afterToolCalls,
}

/// How a cancel request ended, as [CancelHandle.wait] reports it.
///
/// Port of the results of eino `CancelHandle.Wait`: `nil`,
/// `ErrCancelTimeout`, `ErrExecutionEnded`.
enum CancelOutcome {
  /// The run was cancelled (also when an interrupt of the agent's own was
  /// absorbed into the cancel).
  cancelled,

  /// The safe point was not reached in time; the cancel escalated to an
  /// immediate one, which took effect. Eino `ErrCancelTimeout`.
  timedOut,

  /// The run ended (finished or failed) before the cancel took effect. Eino
  /// `ErrExecutionEnded`.
  executionEnded,
}

/// A cancel request that has been made. Port of eino `adk.CancelHandle`.
final class CancelHandle {
  CancelHandle._(this.contributed, this._wait);

  /// Whether this request was part of the cancel of the run: `false` when
  /// the cancel had already been decided, or the run had ended, before it
  /// came (eino's second return value of `AgentCancelFunc`).
  final bool contributed;

  final Future<CancelOutcome> Function() _wait;

  /// Completes when the cancel has reached its outcome. Port of eino
  /// `CancelHandle.Wait`; it reports the cancel, not the run's own result.
  Future<CancelOutcome> wait() => _wait();
}

/// Asks the run that was given the matching option to stop. Port of eino
/// `adk.AgentCancelFunc`.
///
/// * [safePoints]: where the run stops; empty (the default) means at once
///   (eino `WithAgentCancelMode`). An immediate cancel interrupts the agent's
///   graph, abandons the running model or tool call, and ends model and tool
///   streams with a `StreamCanceledException`.
/// * [timeout]: for a safe-point cancel, how long to wait for the safe point
///   before cancelling at once (eino `WithAgentCancelTimeout`); ignored for
///   an immediate cancel.
/// * [recursive]: also cancel the agents that run behind `AgentTool`s of the
///   agent (eino `WithRecursive`). Without it only the run's own agent obeys.
///
/// The function may be called several times: safe points are joined, an
/// immediate request wins, the earliest deadline counts and [recursive],
/// once given, stays. It returns once the request is registered; await
/// [CancelHandle.wait] for the outcome.
typedef AgentCancelFunc = CancelHandle Function({
  Set<CancelSafePoint> safePoints,
  Duration? timeout,
  bool recursive,
});

/// What a cancel did. Port of eino `adk.AgentCancelInfo`.
@immutable
final class AgentCancelInfo {
  /// The description of a cancel.
  const AgentCancelInfo({
    this.safePoints = const {},
    this.escalated = false,
    this.timeout = false,
  });

  /// A description from its JSON form.
  factory AgentCancelInfo.fromJson(Map<String, Object?> json) =>
      AgentCancelInfo(
        safePoints: {
          for (final name in (json['safe_points'] as List<Object?>?) ?? const [])
            CancelSafePoint.values.byName(name! as String),
        },
        escalated: json['escalated'] == true,
        timeout: json['timeout'] == true,
      );

  /// The safe points the cancel waited for; empty for an immediate cancel
  /// (eino's `Mode`).
  final Set<CancelSafePoint> safePoints;

  /// Whether it became an immediate cancel (by a timeout, by a later request,
  /// or because the agent around this one was cancelled at once).
  final bool escalated;

  /// Whether that escalation was caused by the timeout.
  final bool timeout;

  /// Whether the cancel took effect at once.
  bool get isImmediate => safePoints.isEmpty;

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'safe_points': [for (final point in safePoints) point.name],
        'escalated': escalated,
        'timeout': timeout,
      };

  @override
  bool operator ==(Object other) =>
      other is AgentCancelInfo &&
      other.escalated == escalated &&
      other.timeout == timeout &&
      other.safePoints.length == safePoints.length &&
      other.safePoints.containsAll(safePoints);

  @override
  int get hashCode => Object.hash(
        escalated,
        timeout,
        Object.hashAllUnordered(safePoints),
      );

  @override
  String toString() =>
      'AgentCancelInfo(mode: ${describeCancelMode(safePoints)}, '
      'escalated: $escalated, timeout: $timeout)';
}

/// The error event of a run that was cancelled.
///
/// Port of eino `adk.CancelError` (the name `AgentCancelledException` is taken
/// by the older agents). A runner with a checkpoint store and a checkpoint id
/// saves a checkpoint of the cancelled run; [interruptContexts] then name the
/// points to resume with `Runner.resumeWithParams`, as after an interrupt.
///
/// While a cancel is pending, any interrupt of the agent (also one a tool
/// raises for its own reasons) becomes this error: the two cannot be told
/// apart when they arrive together. The agent's interrupt is not lost: it is
/// in the checkpoint and is raised again when the run is resumed.
class AgentRunCancelledException extends ThreepioException {
  /// The cancel described by [info].
  AgentRunCancelledException(
    this.info, {
    List<InterruptCtx> interruptContexts = const [],
    AddressedInterruptSignal? interruptSignal,
  })  : interruptContexts = List.unmodifiable(interruptContexts),
        _interruptSignal = interruptSignal,
        super(
          'agent canceled: mode=${describeCancelMode(info.safePoints)}, '
          'escalated=${info.escalated}',
        );

  /// A cancel from its JSON form (the interrupt signal is not kept).
  factory AgentRunCancelledException.fromJson(Map<String, Object?> json) =>
      AgentRunCancelledException(
        AgentCancelInfo.fromJson(
          (json['info'] as Map<String, Object?>?) ?? const {},
        ),
        interruptContexts: [
          for (final context
              in (json['interrupt_contexts'] as List<Object?>?) ?? const [])
            InterruptCtx.fromJson(context! as Map<String, Object?>),
        ],
      );

  /// What the cancel did.
  final AgentCancelInfo info;

  /// The interrupt points of the cancelled run, for a targeted resume: use
  /// their ids as the keys of `ResumeParams.targets`. Empty when the runner
  /// saved no checkpoint.
  final List<InterruptCtx> interruptContexts;

  final AddressedInterruptSignal? _interruptSignal;

  /// The interrupt the cancel absorbed; the runner writes the checkpoint
  /// from it. Port of eino's unexported `interruptSignal`.
  @internal
  AddressedInterruptSignal? get interruptSignal => _interruptSignal;

  /// This cancel with the [contexts] the runner derived for its checkpoint.
  @internal
  AgentRunCancelledException withInterruptContexts(List<InterruptCtx> contexts) =>
      AgentRunCancelledException(
        info,
        interruptContexts: contexts,
        interruptSignal: _interruptSignal,
      );

  /// The JSON form.
  Map<String, Object?> toJson() => {
        'info': info.toJson(),
        'interrupt_contexts': [
          for (final context in interruptContexts) context.toJson(),
        ],
      };

  @override
  String toString() => 'AgentRunCancelledException: $message';
}

/// [safePoints] as eino names the mode: `immediate`, or the safe points
/// joined with `|`.
@internal
String describeCancelMode(Set<CancelSafePoint> safePoints) {
  if (safePoints.isEmpty) return 'immediate';
  return [
    for (final point in CancelSafePoint.values)
      if (safePoints.contains(point)) point.name,
  ].join('|');
}

/// An option that makes a run cancellable, and the function that cancels it.
///
/// Port of eino `adk.WithCancel`. Pass the option to `Runner.run`,
/// `Runner.resume` (or an agent's `run`); call the function to cancel:
///
/// ```dart
/// final (cancelOption, cancel) = withCancel();
/// final events = runner.run(ctx, messages, options: [cancelOption]);
/// // later, from anywhere:
/// final handle = cancel(safePoints: {CancelSafePoint.afterToolCalls},
///     timeout: const Duration(seconds: 5));
/// await handle.wait();
/// ```
///
/// The run ends with an event whose error is an
/// [AgentRunCancelledException]. With a checkpoint store and
/// `AgentRunOption.checkpointId` the runner saves a checkpoint of the
/// cancelled run, which `Runner.resume` continues.
(AgentRunOption, AgentCancelFunc) withCancel() {
  final cancelContext = CancelContext.root();
  return (cancelContextOption(cancelContext), cancelContext.cancel);
}

/// How long a recursive immediate cancel waits for the agents behind
/// `AgentTool`s to report their interrupts before it interrupts the agent's
/// own graph. Port of eino `defaultCancelImmediateGracePeriod` (1 s); tests
/// shorten it.
@visibleForTesting
Duration cancelImmediateGracePeriod = const Duration(seconds: 1);

enum _CancelState { running, cancelling, done, cancelHandled }

/// A one-shot signal with listeners that can be taken back. Port of a Go
/// channel that is closed once.
final class _Signal {
  bool _fired = false;
  final Set<void Function()> _listeners = {};
  Completer<void>? _completer;

  bool get isFired => _fired;

  Future<void> get future {
    if (_fired) return Future.value();
    return (_completer ??= Completer<void>()).future;
  }

  void fire() {
    if (_fired) return;
    _fired = true;
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
    _completer?.complete();
  }

  /// Calls [listener] when the signal fires (at once when it has); returns
  /// the function that takes the listener back.
  void Function() listen(void Function() listener) {
    if (_fired) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

/// The cancel state of one agent run, shared by everything the run does.
///
/// Port of eino's unexported `cancelContext`. The root context is created by
/// [withCancel]; an `AgentTool` derives a checkpoint-aware context for the
/// agent it runs; an agent started directly from inside another agent (from
/// a middleware) gets an abort-only one that only obeys recursive immediate
/// cancels.
@internal
final class CancelContext {
  CancelContext._({required this.isRoot, this.abortOnly = false, this.parent});

  /// The context of a run started with [withCancel].
  factory CancelContext.root() => CancelContext._(isRoot: true);

  /// Whether this is the context [withCancel] created.
  final bool isRoot;

  /// Whether this context only receives immediate teardown and contributes
  /// no checkpoint (eino `abortOnly`).
  final bool abortOnly;

  /// The context this one was derived from.
  final CancelContext? parent;

  Set<CancelSafePoint> _mode = const {};
  Set<CancelSafePoint> _startedMode = const {};
  _CancelState _state = _CancelState.running;
  bool _interruptSent = false;
  bool _escalated = false;
  bool _timeoutEscalated = false;
  DateTime? _deadline;
  bool _recursive = false;
  bool _checkpointAwareDescendant = false;

  final _Signal _cancelled = _Signal();
  final _Signal _immediate = _Signal();
  final _Signal _done = _Signal();
  final _Signal _recursiveSet = _Signal();

  final List<GraphInterrupter> _interrupters = [];
  bool _graceInProgress = false;
  Timer? _timeoutTimer;
  Timer? _graceTimer;

  /// The safe points of the cancel; empty for an immediate cancel.
  Set<CancelSafePoint> get mode => _mode;

  /// Whether the cancel propagates into the agents behind `AgentTool`s.
  bool get isRecursive => _recursive;

  /// Whether a cancel has been asked for. Port of `shouldCancel`.
  bool get shouldCancel => _cancelled.isFired;

  /// Whether the run is being torn down at once: its graph was interrupted
  /// with no wait and its streams are being ended. Stronger than
  /// [shouldCancel]. Port of `isImmediateCancelled`.
  bool get isImmediateCancelled => _immediate.isFired;

  /// Whether the run has finished, by any path.
  bool get isDone => _done.isFired;

  /// Whether a checkpoint-aware sub-agent runs under this context.
  bool get hasCheckpointAwareDescendant => _checkpointAwareDescendant;

  /// Whether the cancel escalated to an immediate one.
  bool get isEscalated => _escalated;

  /// Calls [listener] when a cancel is asked for (at once or at a safe
  /// point); returns the function that takes it back.
  void Function() onCancel(void Function() listener) =>
      _cancelled.listen(listener);

  /// Calls [listener] when the run is torn down at once; returns the function
  /// that takes it back.
  void Function() onImmediate(void Function() listener) =>
      _immediate.listen(listener);

  /// Calls [listener] when the run has finished; returns the function that
  /// takes it back.
  void Function() onDone(void Function() listener) => _done.listen(listener);

  /// Completes when the run has finished.
  Future<void> get done => _done.future;

  /// Makes the cancel recursive; it cannot be made non-recursive again. Port
  /// of `setRecursive`.
  void setRecursive(bool recursive) {
    if (!recursive || _recursive) return;
    _recursive = true;
    _recursiveSet.fire();
  }

  /// A context for an `AgentTool`'s agent that obeys this one's recursive
  /// cancels and contributes its checkpoint. Port of
  /// `deriveCheckpointAwareCancelContext`; the child must be marked done when
  /// its run ends.
  CancelContext deriveCheckpointAware(RunContext ctx) {
    final child = CancelContext._(isRoot: false, parent: this);
    _propagate(ctx, child, _cancelled, () => child.triggerCancel(mode));
    _propagate(ctx, child, _immediate, child.triggerImmediateCancel);
    return child;
  }

  /// A context for an agent started directly inside this run (from a
  /// middleware), which only obeys recursive immediate cancels. Port of
  /// `deriveAbortOnlyCancelContext`.
  CancelContext deriveAbortOnly(RunContext ctx) {
    final child = CancelContext._(isRoot: false, abortOnly: true, parent: this);
    _propagate(ctx, child, _immediate, child.triggerImmediateCancel);
    return child;
  }

  /// Passes [signal] on to [child] with [trigger] once the cancel is
  /// recursive, unless the child or [ctx] ended first. Port of the two-phase
  /// select of eino's propagation goroutines.
  void _propagate(
    RunContext ctx,
    CancelContext child,
    _Signal signal,
    void Function() trigger,
  ) {
    void Function()? removeSignal;
    void Function()? removeRecursive;
    void Function()? removeChildDone;
    void stop() {
      removeSignal?.call();
      removeRecursive?.call();
      removeChildDone?.call();
    }

    void deliver() {
      stop();
      if (child.isDone || ctx.cancelToken.isCancelled) return;
      child.setRecursive(true);
      trigger();
    }

    removeChildDone = child._done.listen(stop);
    if (child.isDone) return;
    removeSignal = signal.listen(() {
      // Eino's goroutines run later than the close they wait for.
      scheduleMicrotask(() {
        if (child.isDone || ctx.cancelToken.isCancelled) {
          stop();
          return;
        }
        if (isRecursive) {
          deliver();
        } else {
          removeRecursive = _recursiveSet.listen(
            () => scheduleMicrotask(deliver),
          );
        }
      });
    });
  }

  /// Asks for a cancel at [safePoints] (none: at once). Port of
  /// `triggerCancel`.
  void triggerCancel(Set<CancelSafePoint> safePoints) {
    _mode = Set.unmodifiable(safePoints);
    if (_state == _CancelState.running) {
      _state = _CancelState.cancelling;
      _cancelled.fire();
    }
  }

  /// Cancels at once, as an escalation. Port of `triggerImmediateCancel`.
  void triggerImmediateCancel() {
    _escalated = true;
    _mode = const {};
    if (_state == _CancelState.running) {
      _state = _CancelState.cancelling;
      _cancelled.fire();
    }
    sendImmediateInterrupt();
  }

  /// Interrupts the run's graphs with no wait and ends its streams. Port of
  /// `sendImmediateInterrupt`; returns whether an interrupt was sent.
  ///
  /// The graphs are interrupted before the streams are ended, so that a node
  /// whose stream fails is seen as part of the interrupt (eino #1148). With a
  /// recursive cancel and a checkpoint-aware descendant, the streams end
  /// first and the graphs are interrupted after a grace period, which gives
  /// the descendants time to report their interrupts; the grace period ends
  /// early when the run finishes.
  bool sendImmediateInterrupt() {
    if (_interruptSent) return false;
    _interruptSent = true;
    _cancelTimeoutTimer();

    if (!abortOnly && isRecursive && hasCheckpointAwareDescendant) {
      _immediate.fire();
      if (_done.isFired) return true;
      _graceInProgress = true;
      _graceTimer = Timer(cancelImmediateGracePeriod, _endGrace);
      return true;
    }

    final sent = _fireInterrupters();
    _immediate.fire();
    return sent;
  }

  void _endGrace() {
    if (!_graceInProgress) return;
    _graceInProgress = false;
    _graceTimer?.cancel();
    _graceTimer = null;
    if (_done.isFired) return;
    _fireInterrupters();
  }

  bool _fireInterrupters() {
    for (final interrupter in List.of(_interrupters)) {
      if (!interrupter.isInterrupted) {
        interrupter.interrupt(timeout: Duration.zero);
      }
    }
    return _interrupters.isNotEmpty;
  }

  /// Registers the interrupter of one of the run's graphs; it is called at
  /// once when an immediate cancel was already sent. Port of
  /// `setGraphInterruptFunc`.
  void addGraphInterrupter(GraphInterrupter interrupter) {
    _interrupters.add(interrupter);
    if (_interruptSent && !_graceInProgress && !interrupter.isInterrupted) {
      interrupter.interrupt(timeout: Duration.zero);
    }
  }

  /// Notes that the run finished by a path other than the cancel. Port of
  /// `markDone`.
  void markDone() {
    if (_state == _CancelState.running || _state == _CancelState.cancelling) {
      _state = _CancelState.done;
      _finish();
    }
  }

  /// Notes that a checkpoint-aware sub-agent runs under this context, and
  /// under every context it was derived from, up to an abort-only one. Port
  /// of `markCheckpointAwareDescendant`.
  void markCheckpointAwareDescendant() {
    for (CancelContext? current = this;
        current != null;
        current = current.parent) {
      if (current.abortOnly) break;
      current._checkpointAwareDescendant = true;
    }
  }

  /// Notes that the cancel was turned into an [AgentRunCancelledException];
  /// `false` when that had happened already. Port of `markCancelHandled`.
  bool markCancelHandled() {
    if (_state != _CancelState.cancelling) return false;
    _state = _CancelState.cancelHandled;
    _finish();
    return true;
  }

  void _finish() {
    _cancelTimeoutTimer();
    _done.fire();
    if (_graceInProgress) _endGrace();
  }

  /// The error of the cancel as it stands. Port of `createCancelError`.
  AgentRunCancelledException createCancelError({
    AddressedInterruptSignal? interruptSignal,
  }) =>
      AgentRunCancelledException(
        AgentCancelInfo(
          safePoints: _mode,
          escalated: _escalated,
          timeout: _escalated && _timeoutEscalated,
        ),
        interruptSignal: interruptSignal,
      );

  /// The error of the cancel, if this call is the one that handles it. Port
  /// of `createAndMarkCancelHandled`.
  AgentRunCancelledException? createAndMarkCancelHandled({
    AddressedInterruptSignal? interruptSignal,
  }) {
    final error = createCancelError(interruptSignal: interruptSignal);
    return markCancelHandled() ? error : null;
  }

  /// The [AgentCancelFunc] of this context. Port of `buildCancelFunc`.
  CancelHandle cancel({
    Set<CancelSafePoint> safePoints = const {},
    Duration? timeout,
    bool recursive = false,
  }) {
    switch (_state) {
      case _CancelState.cancelHandled:
        return CancelHandle._(false, () async => CancelOutcome.cancelled);
      case _CancelState.done:
        return CancelHandle._(false, () async => CancelOutcome.executionEnded);
      case _CancelState.running || _CancelState.cancelling:
        break;
    }

    final Set<CancelSafePoint> current;
    if (_state == _CancelState.running) {
      _state = _CancelState.cancelling;
      current = Set.unmodifiable(safePoints);
      _mode = current;
      _startedMode = current;
      setRecursive(recursive);
      _cancelled.fire();
    } else {
      current = _mode.isEmpty || safePoints.isEmpty
          ? const <CancelSafePoint>{}
          : Set.unmodifiable({..._mode, ...safePoints});
      _mode = current;
      if (recursive) setRecursive(true);
    }

    var needImmediate = false;
    if (current.isEmpty) {
      _deadline = null;
      needImmediate = true;
    } else if (timeout != null && timeout > Duration.zero) {
      final proposed = clock.now().add(timeout);
      final existing = _deadline;
      if (existing == null || proposed.isBefore(existing)) {
        _deadline = proposed;
        _armTimeout();
      }
    }

    if (needImmediate) {
      if (_startedMode.isNotEmpty) _escalated = true;
      sendImmediateInterrupt();
    }
    return CancelHandle._(true, _waitForCompletion);
  }

  Future<CancelOutcome> _waitForCompletion() async {
    await _done.future;
    if (_state == _CancelState.done) return CancelOutcome.executionEnded;
    return _timeoutEscalated ? CancelOutcome.timedOut : CancelOutcome.cancelled;
  }

  /// (Re)starts the timer of the earliest deadline. Port of eino's timeout
  /// controller goroutine.
  void _armTimeout() {
    _cancelTimeoutTimer();
    if (_done.isFired || _mode.isEmpty || _interruptSent) return;
    final deadline = _deadline;
    if (deadline == null) return;
    final wait = deadline.difference(clock.now());
    if (wait <= Duration.zero) {
      _escalateOnTimeout();
    } else {
      _timeoutTimer = Timer(wait, _escalateOnTimeout);
    }
  }

  void _escalateOnTimeout() {
    _timeoutTimer = null;
    if (_done.isFired) return;
    _escalated = true;
    _timeoutEscalated = true;
    sendImmediateInterrupt();
  }

  void _cancelTimeoutTimer() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  @override
  String toString() =>
      'CancelContext(${_state.name}, mode: ${describeCancelMode(_mode)}'
      '${isRoot ? ', root' : ''}${abortOnly ? ', abort-only' : ''})';
}

final _cancelContextKey = ContextKey<CancelContext>('adk.cancelContext');

/// [ctx] with [cancelContext] (unchanged when it is `null`). Port of
/// `withCancelContext`.
@internal
RunContext withCancelContext(RunContext ctx, CancelContext? cancelContext) =>
    cancelContext == null ? ctx : ctx.withValue(_cancelContextKey, cancelContext);

/// The cancel context of the run [ctx] belongs to. Port of
/// `getCancelContext`.
@internal
CancelContext? cancelContextOf(RunContext ctx) => ctx.value(_cancelContextKey);

/// [ctx] with [cancelContext], whose cancel token is also cancelled when the
/// run is torn down at once or ends; call the returned function when the run
/// is over. Port of `withAbortOnlyCancelContext`.
@internal
(RunContext, void Function()) withAbortOnlyCancelContext(
  RunContext ctx,
  CancelContext cancelContext,
) {
  final own = CancelToken();
  final token = CancelToken.any([ctx.cancelToken, own])!;
  void abort() => own.cancel('agent canceled');
  final removeImmediate = cancelContext.onImmediate(abort);
  final removeDone = cancelContext.onDone(abort);
  return (
    withCancelContext(ctx, cancelContext).withCancelToken(token),
    () {
      removeImmediate();
      removeDone();
      abort();
    },
  );
}

/// The cancel context a run uses and whether it owns it. Port of eino
/// `resolveRunCancelContext`: the run's own option wins; a checkpoint-aware
/// scope inherited from an `AgentTool` is used as it is; any other inherited
/// scope (an agent started from inside another agent's run) gets an
/// abort-only child.
@internal
(CancelContext?, bool) resolveRunCancelContext(
  RunContext ctx,
  CancelContext? fromOptions,
) {
  final inherited = cancelContextOf(ctx);
  if (fromOptions != null) {
    return (fromOptions, !identical(fromOptions, inherited));
  }
  if (inherited != null) {
    if (inherited.parent != null &&
        !inherited.abortOnly &&
        execContextOf(ctx) == null) {
      return (inherited, false);
    }
    return (inherited.deriveAbortOnly(ctx), true);
  }
  return (null, false);
}

/// Whether [cancelContext] is an abort-only context that is being torn down.
/// Port of `isAbortOnlyCancelled`.
@internal
bool isAbortOnlyCancelled(CancelContext? cancelContext) =>
    cancelContext != null &&
    cancelContext.abortOnly &&
    cancelContext.isImmediateCancelled;

/// The cancel context a sub-agent boundary (an `AgentTool`) runs its agent
/// under, derived from the one in [options] or [ctx]; `null` when there is
/// none or it is abort-only. Port of
/// `deriveCheckpointAwareSubAgentCancelContext`.
@internal
CancelContext? deriveCheckpointAwareSubAgentCancelContext(
  RunContext ctx,
  List<AgentRunOption> options,
) {
  final parent =
      CommonAgentOptions.of(options).cancelContext ?? cancelContextOf(ctx);
  if (parent == null || parent.abortOnly) return null;
  parent.markCheckpointAwareDescendant();
  return parent.deriveCheckpointAware(ctx);
}

/// A copy of [options] with the option of [cancelContext] appended. Port of
/// `appendCancelContextOption`.
@internal
List<AgentRunOption> appendCancelContextOption(
  List<AgentRunOption> options,
  CancelContext? cancelContext,
) =>
    [
      ...options,
      if (cancelContext != null) cancelContextOption(cancelContext),
    ];

/// Ends a run that was cancelled before its graph started: `true` when the
/// run is over (an [AgentRunCancelledException] was sent for an immediate
/// cancel, or an abort-only run stopped silently). Port of
/// `checkPreExecCancel`.
@internal
bool checkPreExecCancel(
  CancelContext? cancelContext,
  void Function(AgentEvent event) send,
) {
  if (cancelContext == null) return false;
  if (cancelContext.abortOnly) {
    if (cancelContext.isImmediateCancelled) {
      cancelContext.markDone();
      return true;
    }
    return false;
  }
  if (cancelContext.shouldCancel &&
      (cancelContext.mode.isEmpty || cancelContext.isEscalated)) {
    final error = cancelContext.createAndMarkCancelHandled();
    if (error != null) send(AgentEvent(error: error));
    return true;
  }
  return false;
}

/// [events] with the cancel bookkeeping of the run: [cancelContext] is marked
/// done when they end, and for the root context an interrupt that arrives
/// while a cancel is pending becomes an [AgentRunCancelledException]. Port of
/// `wrapIterWithCancelCtx`.
@internal
StreamReader<AgentEvent> wrapEventsWithCancelContext(
  StreamReader<AgentEvent> events,
  CancelContext? cancelContext,
) {
  if (cancelContext == null) return events;
  final (reader, writer) = pipe<AgentEvent>();
  unawaited(() async {
    try {
      for (var event = await events.nextOrNull();
          event != null;
          event = await events.nextOrNull()) {
        final signal = event.action?.interruptSignal;
        if (cancelContext.isRoot && signal != null && cancelContext.shouldCancel) {
          final error =
              cancelContext.createAndMarkCancelHandled(interruptSignal: signal);
          if (error != null) writer.send(AgentEvent(error: error));
          return;
        }
        writer.send(event);
      }
      // Whatever the source throws ends the run.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      writer.send(AgentEvent(error: error, stackTrace: stackTrace));
    } finally {
      // Eino defers both; a failing close of the source (Go's cannot fail)
      // must not skip them, nor escape as an unhandled error.
      await _closeQuietly(events);
      await writer.close();
      cancelContext.markDone();
    }
  }());
  return reader;
}

Future<void> _closeQuietly(StreamReader<Object?> reader) async {
  try {
    await reader.close();
    // A reader implemented elsewhere may throw from close.
    // ignore: avoid_catches_without_on_clauses
  } catch (_) {}
}

/// [stream], ended with a [StreamCanceledException] as soon as
/// [cancelContext] is torn down at once. Port of
/// `wrapStreamWithCancelMonitoring`; the stream is unchanged without a
/// context.
@internal
StreamReader<T> wrapStreamWithCancelMonitoring<T>(
  StreamReader<T> stream,
  CancelContext? cancelContext,
) {
  if (cancelContext == null) return stream;
  if (cancelContext.isImmediateCancelled) {
    unawaited(_closeQuietly(stream));
    final (reader, writer) = pipe<T>(capacity: 1);
    writer.sendError(const StreamCanceledException());
    unawaited(writer.close());
    return reader;
  }

  final (reader, writer) = pipe<T>(capacity: 1);
  unawaited(() async {
    // One listener for the whole stream; it completes the pull in progress.
    var torn = false;
    Completer<_Pulled<T>>? current;
    final remove = cancelContext.onImmediate(() {
      torn = true;
      final pull = current;
      if (pull != null && !pull.isCompleted) {
        pull.complete(_Pulled<T>.cancelled());
      }
    });
    try {
      while (true) {
        final _Pulled<T> pulled;
        if (torn) {
          pulled = _Pulled<T>.cancelled();
        } else {
          final pull = current = Completer<_Pulled<T>>();
          // A pull that loses against the cancel completes later (with
          // StreamClosedException once the source is closed); it is ignored.
          unawaited(
            stream.recv().then(
              (item) {
                if (!pull.isCompleted) pull.complete(_Pulled<T>.item(item));
              },
              onError: (Object error, StackTrace stackTrace) {
                if (!pull.isCompleted) {
                  pull.complete(_Pulled<T>.error(error, stackTrace));
                }
              },
            ),
          );
          pulled = await pull.future;
          current = null;
        }
        if (pulled.isCancelled) {
          writer.sendError(const StreamCanceledException());
          return;
        }
        final error = pulled.error;
        if (error is StreamEOFException) return;
        if (error != null) {
          writer.sendError(error, pulled.stackTrace);
          return;
        }
        if (await writer.sendAsync(pulled.item as T)) return;
      }
    } finally {
      remove();
      // Go's Close cannot block; a source whose close hangs (what an
      // immediate cancel is for) must not keep the output open.
      unawaited(_closeQuietly(stream));
      await writer.close();
    }
  }());
  return reader;
}

final class _Pulled<T> {
  const _Pulled.item(T this.item)
      : error = null,
        stackTrace = null,
        isCancelled = false;

  const _Pulled.error(Object this.error, this.stackTrace)
      : item = null,
        isCancelled = false;

  const _Pulled.cancelled()
      : item = null,
        error = null,
        stackTrace = null,
        isCancelled = true;

  final T? item;
  final Object? error;
  final StackTrace? stackTrace;
  final bool isCancelled;
}

/// A model whose streams end with a [StreamCanceledException] when the run
/// is torn down at once; `generate` passes through (the safe point after the
/// model call is a node of the agent's graph). Port of
/// `typedCancelMonitoredModel`.
@internal
final class CancelMonitoredModel extends BaseChatModel {
  /// [inner], watched by [cancelContext].
  CancelMonitoredModel(this.inner, this.cancelContext);

  final BaseChatModel inner;
  final CancelContext cancelContext;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) =>
      inner.generate(input, options: options);

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      wrapStreamWithCancelMonitoring(
        await inner.stream(input, options: options),
        cancelContext,
      );
}

/// The tool middleware that ends the streams of streaming tools when the run
/// is torn down at once. Port of `cancelMonitoredToolHandler`; it reads the
/// cancel context from the context of the call. A `ChatModelAgent` installs
/// it as the innermost tool middleware.
@internal
const ToolMiddleware cancelMonitoredToolMiddleware = ToolMiddleware(
  streamable: _cancelMonitoredStreamable,
  enhancedStreamable: _cancelMonitoredEnhancedStreamable,
);

StreamableToolEndpoint _cancelMonitoredStreamable(StreamableToolEndpoint next) =>
    (ctx, input) async {
      final output = await next(ctx, input);
      final cancelContext = cancelContextOf(ctx);
      if (cancelContext == null) return output;
      return StreamToolCallOutput(
        wrapStreamWithCancelMonitoring(output.result, cancelContext),
      );
    };

EnhancedStreamableToolEndpoint _cancelMonitoredEnhancedStreamable(
  EnhancedStreamableToolEndpoint next,
) =>
    (ctx, input) async {
      final output = await next(ctx, input);
      final cancelContext = cancelContextOf(ctx);
      if (cancelContext == null) return output;
      return EnhancedStreamToolCallOutput(
        wrapStreamWithCancelMonitoring<ToolResult>(output.result, cancelContext),
      );
    };
