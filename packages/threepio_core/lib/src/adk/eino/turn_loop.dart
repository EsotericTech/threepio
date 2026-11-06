/// A push-based loop that runs an agent turn by turn over items pushed to it.
///
/// Port of eino `adk/turn_loop.go`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:meta/meta.dart';

import '../../components/model/cancel_token.dart';
import '../../compose/checkpoint_serializer.dart';
import '../../compose/checkpoint_store.dart';
import '../../compose/interrupt.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/type_registry.dart';
import '../../streaming/stream_reader.dart';
import 'agent.dart';
import 'agent_event.dart';
import 'cancel.dart';
import 'interrupt.dart';
import 'run_options.dart';
import 'runner.dart';
import 'turn_buffer.dart';

/// The arguments of one call of an [AgentCancelFunc].
@internal
typedef CancelArgs = ({
  Set<CancelSafePoint> safePoints,
  Duration? timeout,
  bool recursive,
});

/// Calls [cancel] with [args].
CancelHandle _submit(AgentCancelFunc cancel, CancelArgs args) => cancel(
      safePoints: args.safePoints,
      timeout: args.timeout,
      recursive: args.recursive,
    );

/// The cancel a preempt or a stop asks for, merged over several requests.
///
/// Port of eino's unexported `cancelRequestState`: an immediate request wins,
/// safe points are joined, the earliest deadline counts, `recursive` stays.
@internal
final class CancelRequestState {
  /// The state of one request [args] made at [now].
  CancelRequestState(CancelArgs args, DateTime now)
      : safePoints = Set.of(args.safePoints),
        recursive = args.recursive,
        deadline = args.timeout != null &&
                args.timeout! > Duration.zero &&
                args.safePoints.isNotEmpty
            ? now.add(args.timeout!)
            : null;

  /// The safe points asked for; empty for an immediate cancel.
  Set<CancelSafePoint> safePoints;

  /// Whether the cancel propagates into nested agents.
  bool recursive;

  /// When a safe-point cancel escalates to an immediate one.
  DateTime? deadline;

  /// Merges a further request [args] made at [now]; `null` changes nothing
  /// (eino: nil options), empty safe points mean an explicit immediate
  /// request. Port of `cancelRequestState.merge`.
  void merge(CancelArgs? args, DateTime now) {
    if (args == null) return;
    final next = CancelRequestState(args, now);
    if (safePoints.isEmpty || next.safePoints.isEmpty) {
      safePoints = {};
      deadline = null;
    } else {
      safePoints.addAll(next.safePoints);
      final nextDeadline = next.deadline;
      if (nextDeadline != null &&
          (deadline == null || nextDeadline.isBefore(deadline!))) {
        deadline = nextDeadline;
      }
    }
    if (next.recursive) recursive = true;
  }

  /// The arguments to cancel with at [now]: the time left until the
  /// deadline, or an immediate cancel once it has passed. Port of
  /// `cancelRequestState.cancelOptions`.
  CancelArgs cancelArgs(DateTime now) {
    var points = Set<CancelSafePoint>.of(safePoints);
    Duration? timeout;
    final end = deadline;
    if (points.isNotEmpty && end != null) {
      final remaining = end.difference(now);
      if (remaining <= Duration.zero) {
        points = {};
      } else {
        timeout = remaining;
      }
    }
    return (safePoints: points, timeout: timeout, recursive: recursive);
  }
}

/// A preempt request with the futures it has to complete. Port of eino
/// `preemptRequest`.
@internal
final class PreemptRequest {
  PreemptRequest._(CancelArgs args, DateTime now, Completer<void>? ack)
      : cancel = CancelRequestState(args, now) {
    if (ack != null) acks.add(ack);
  }

  /// The cancel the request asks for.
  final CancelRequestState cancel;

  /// What the pushes behind the request wait on.
  final List<Completer<void>> acks = [];

  /// Resolves every push behind the request. Port of `preemptRequest.ack`.
  void ack() {
    for (final ack in acks) {
      if (!ack.isCompleted) ack.complete();
    }
    acks.clear();
  }

  /// Merges a further preempt. Port of `preemptRequest.merge`.
  void merge(Completer<void>? ack, CancelArgs args, DateTime now) {
    if (ack != null) acks.add(ack);
    cancel.merge(args, now);
  }

  /// The arguments to cancel with at [now].
  CancelArgs cancelArgs(DateTime now) => cancel.cancelArgs(now);
}

extension on PreemptRequest? {
  void ack() => this?.ack();
}

/// Where a turn is in its life. Port of eino `preemptTurnPhase`.
@internal
enum PreemptTurnPhase { idle, planning, active }

/// What a push saw of the turn it may preempt. Port of eino
/// `preemptTurnSnapshot`.
@internal
final class PreemptTurnSnapshot {
  const PreemptTurnSnapshot._({
    required this.hasTargetTurn,
    required this.turnId,
    this.ctx,
    this.turnContext,
  });

  /// Whether a turn was being planned or running.
  final bool hasTargetTurn;

  /// That turn's number.
  final int turnId;

  /// Its context, while it was running.
  final RunContext? ctx;

  /// Its turn context, while it was running.
  final Object? turnContext;
}

/// A signal for the one watcher of the running turn. Port of eino's
/// buffered `notify` channel: a notification waits for the watcher.
final class _Notifier {
  bool _pending = false;
  void Function()? _listener;

  void notify() {
    _pending = true;
    _dispatch();
  }

  void attach(void Function() listener) {
    _listener = listener;
    _dispatch();
  }

  void detach() => _listener = null;

  void clear() => _pending = false;

  void _dispatch() {
    if (!_pending || _listener == null) return;
    scheduleMicrotask(() {
      final listener = _listener;
      if (!_pending || listener == null) return;
      _pending = false;
      listener();
    });
  }
}

/// The preempt requests of a [TurnLoop], bound to the turn a push saw.
///
/// Port of eino `preemptController`. A turn goes idle → planning → active →
/// idle (or planning → idle when it is abandoned). A push takes a snapshot
/// of the turn; its preempt request applies only while that turn lasts and is
/// handed to the turn's watcher once it runs.
@internal
final class PreemptController {
  PreemptTurnPhase _phase = PreemptTurnPhase.idle;
  int _turnId = 0;
  Object? _currentTurnContext;
  RunContext? _currentCtx;
  int _pushInFlight = 0;
  PreemptRequest? _pending;
  bool _closed = false;
  final _Notifier _notifier = _Notifier();
  final List<Completer<void>> _pushWaiters = [];

  /// The current phase.
  PreemptTurnPhase get phase => _phase;

  /// The number of the current (or last) turn.
  int get turnId => _turnId;

  /// The preempt request no watcher has taken yet.
  PreemptRequest? get pending => _pending;

  /// Starts planning a new turn. Port of `beginPlanningTurn`.
  void beginPlanningTurn() {
    _requirePhase(PreemptTurnPhase.idle, 'beginPlanningTurn');
    if (_pending != null) {
      throw StateError(
        'adk: preemptController.beginPlanningTurn called with stale pending '
        'preempt request',
      );
    }
    _turnId++;
    _phase = PreemptTurnPhase.planning;
    _currentCtx = null;
    _currentTurnContext = null;
  }

  /// Abandons the turn being planned; returns its unconsumed request. Port of
  /// `abortPlanningTurn`.
  PreemptRequest? abortPlanningTurn() {
    _requirePhase(PreemptTurnPhase.planning, 'abortPlanningTurn');
    return _toIdle();
  }

  /// The planned turn starts running. Port of `beginActiveTurn`.
  void beginActiveTurn(RunContext ctx, Object turnContext) {
    _requirePhase(PreemptTurnPhase.planning, 'beginActiveTurn');
    _phase = PreemptTurnPhase.active;
    _currentCtx = ctx;
    _currentTurnContext = turnContext;
    if (_pending != null) _notifier.notify();
  }

  /// The running turn ended; returns its unconsumed request. Port of
  /// `endActiveTurn`.
  PreemptRequest? endActiveTurn() {
    _requirePhase(PreemptTurnPhase.active, 'endActiveTurn');
    return _toIdle();
  }

  PreemptRequest? _toIdle() {
    _phase = PreemptTurnPhase.idle;
    _currentCtx = null;
    _currentTurnContext = null;
    final request = _pending;
    _pending = null;
    return request;
  }

  void _requirePhase(PreemptTurnPhase expected, String operation) {
    if (_phase != expected) {
      throw StateError(
        'adk: preemptController.$operation called while turn phase is '
        '${_phase.name}; expected ${expected.name}',
      );
    }
  }

  /// A push begins; returns what it sees of the turn. Port of `beginPush`.
  PreemptTurnSnapshot beginPush() {
    _pushInFlight++;
    return PreemptTurnSnapshot._(
      hasTargetTurn: _phase == PreemptTurnPhase.planning ||
          _phase == PreemptTurnPhase.active,
      turnId: _turnId,
      ctx: _currentCtx,
      turnContext: _currentTurnContext,
    );
  }

  /// A push ends. Port of `endPush`.
  void endPush() {
    _pushInFlight--;
    if (_pushInFlight < 0) {
      _pushInFlight = 0;
      throw StateError(
        'adk: preemptController.endPush called without matching beginPush',
      );
    }
    if (_pushInFlight == 0) {
      for (final waiter in _pushWaiters) {
        waiter.complete();
      }
      _pushWaiters.clear();
    }
  }

  /// Completes when no push is in progress. Port of `waitForPushes`.
  Future<void> waitForPushes() {
    if (_pushInFlight == 0) return Future.value();
    final waiter = Completer<void>();
    _pushWaiters.add(waiter);
    return waiter.future;
  }

  /// Asks to cancel the turn [target] saw, with [args]; [ack] completes once
  /// the cancel was submitted, or at once when that turn is gone. Port of
  /// `requestPreempt`.
  void requestPreempt(
    PreemptTurnSnapshot target,
    Completer<void>? ack,
    CancelArgs args,
  ) {
    if (_closed ||
        !target.hasTargetTurn ||
        _phase == PreemptTurnPhase.idle ||
        _turnId != target.turnId) {
      if (ack != null && !ack.isCompleted) ack.complete();
      return;
    }
    final now = clock.now();
    final pending = _pending;
    if (pending == null) {
      _pending = PreemptRequest._(args, now, ack);
    } else {
      pending.merge(ack, args, now);
    }
    if (_phase == PreemptTurnPhase.active) _notifier.notify();
  }

  /// The request for the running turn, taken by its watcher. Port of
  /// `receivePreempt`.
  PreemptRequest? receivePreempt() {
    if (_phase != PreemptTurnPhase.active || _pending == null) return null;
    final request = _pending;
    _pending = null;
    return request;
  }

  /// Calls [listener] when a request for the running turn arrives.
  void attachWatcher(void Function() listener) => _notifier.attach(listener);

  /// Stops calling the watcher.
  void detachWatcher() => _notifier.detach();

  /// Closes the controller when the loop exits, resolving what is pending.
  /// Port of `closeForLoopExit`.
  void closeForLoopExit() {
    _closed = true;
    _phase = PreemptTurnPhase.idle;
    _currentCtx = null;
    _currentTurnContext = null;
    final request = _pending;
    _pending = null;
    _notifier
      ..clear()
      ..detach();
    request.ack();
  }
}

/// What a stop request decided. Port of eino `stopDecision`.
@internal
typedef StopDecision = ({bool commit, bool wakeIdle});

/// What one stop call asks for. Port of eino `stopConfig`.
@internal
final class StopConfig {
  /// The cancel of the running turn, if any.
  CancelArgs? cancel;

  /// Whether no checkpoint is written.
  bool skipCheckpoint = false;

  /// The reason given.
  String cause = '';

  /// How long the loop must be idle before it stops; zero for at once.
  Duration idleFor = Duration.zero;
}

/// The global stop state of a [TurnLoop], and the cancel a stop asks of the
/// running turn.
///
/// Port of eino `stopController`. A committed stop ends the loop; a stop with
/// cancel options also leaves a request for the running turn's watcher.
@internal
final class StopController {
  _StopPhase _phase = _StopPhase.open;
  bool _hasActiveCancelTarget = false;
  CancelRequestState? _pending;
  Duration _idleFor = Duration.zero;
  bool _skipCheckpoint = false;
  String _cause = '';
  bool _closed = false;
  final _Notifier _notifier = _Notifier();

  /// The cancel request no watcher has taken yet.
  CancelRequestState? get pending => _pending;

  /// Records [config]. Port of `requestStop`.
  StopDecision requestStop(StopConfig config) {
    if (_closed) return (commit: false, wakeIdle: false);
    if (config.skipCheckpoint) _skipCheckpoint = true;
    if (config.cause.isNotEmpty && _cause.isEmpty) _cause = config.cause;
    if (config.idleFor > Duration.zero) {
      if (_phase != _StopPhase.committed && _idleFor == Duration.zero) {
        _phase = _StopPhase.idleWaiting;
        _idleFor = config.idleFor;
      }
      return (commit: false, wakeIdle: _phase == _StopPhase.idleWaiting);
    }
    final committed = _commit();
    final cancel = config.cancel;
    if (cancel != null) {
      final now = clock.now();
      final pending = _pending;
      if (pending == null) {
        _pending = CancelRequestState(cancel, now);
      } else {
        pending.merge(cancel, now);
      }
      if (_hasActiveCancelTarget) _notifier.notify();
    }
    return (commit: committed, wakeIdle: false);
  }

  /// Commits the stop; `false` when it was committed already. Port of
  /// `commit`.
  bool commit() => _commit();

  bool _commit() {
    if (_closed || _phase == _StopPhase.committed) return false;
    _phase = _StopPhase.committed;
    _idleFor = Duration.zero;
    return true;
  }

  /// Whether the stop is committed.
  bool get isCommitted => _phase == _StopPhase.committed;

  /// How long the loop must be idle before it stops; zero when no idle stop
  /// is waiting. Port of `idleDuration`.
  Duration get idleDuration =>
      _phase == _StopPhase.idleWaiting ? _idleFor : Duration.zero;

  /// Whether a stop asked for no checkpoint.
  bool get skipCheckpoint => _skipCheckpoint;

  /// The first non-empty reason given.
  String get cause => _cause;

  /// A turn starts running. Port of `beginActiveTurn`.
  void beginActiveTurn() {
    if (_closed) return;
    _hasActiveCancelTarget = true;
    if (_pending != null) _notifier.notify();
  }

  /// The running turn ended; drops the request it did not take. Port of
  /// `endActiveTurn`.
  CancelRequestState? endActiveTurn() {
    _hasActiveCancelTarget = false;
    final request = _pending;
    _pending = null;
    return request;
  }

  /// The cancel request for the running turn, taken by its watcher. Port of
  /// `receiveCancel`.
  CancelRequestState? receiveCancel() {
    if (!_hasActiveCancelTarget || _pending == null) return null;
    final request = _pending;
    _pending = null;
    return request;
  }

  /// Calls [listener] when a cancel request for the running turn arrives.
  void attachWatcher(void Function() listener) => _notifier.attach(listener);

  /// Stops calling the watcher.
  void detachWatcher() => _notifier.detach();

  /// Closes the controller when the loop exits. Port of `closeForLoopExit`.
  void closeForLoopExit() {
    _closed = true;
    _hasActiveCancelTarget = false;
    _pending = null;
    _notifier
      ..clear()
      ..detach();
  }
}

enum _StopPhase { open, idleWaiting, committed }

/// An option of [TurnLoop.stop].
///
/// Port of eino's `StopOption` constructors. Without options a stop lets the
/// running turn finish and ends the loop before the next one.
sealed class StopOption {
  const StopOption._();

  /// Stops at the running agent's next safe point (after its model call or
  /// after its tool calls), also inside nested agents, with no time limit.
  /// Port of eino `WithGraceful`.
  const factory StopOption.graceful() = _GracefulStop;

  /// Cancels the running agent at once, nested agents included. Port of eino
  /// `WithImmediate`.
  const factory StopOption.immediate() = _ImmediateStop;

  /// Like [StopOption.graceful], but cancels at once when no safe point is
  /// reached within [gracePeriod] (which must be positive). Port of eino
  /// `WithGracefulTimeout`.
  factory StopOption.gracefulTimeout(Duration gracePeriod) {
    if (gracePeriod <= Duration.zero) {
      throw ArgumentError.value(
        gracePeriod,
        'gracePeriod',
        'adk: WithGracefulTimeout: gracePeriod must be positive',
      );
    }
    return _GracefulTimeoutStop(gracePeriod);
  }

  /// Writes no checkpoint (for a loop that will not be resumed); once given,
  /// it stays. Port of eino `WithSkipCheckpoint`.
  const factory StopOption.skipCheckpoint() = _SkipCheckpointStop;

  /// A reason, reported in [TurnLoopExitState.stopCause] and
  /// [TurnContext.stopCause]; the first non-empty one counts. Port of eino
  /// `WithStopCause`.
  const factory StopOption.cause(String cause) = _CauseStop;

  /// Stops once the loop has been idle (between turns, nothing buffered) for
  /// [duration] (which must be positive); a new item restarts the clock. It
  /// does not affect a running turn, and cancel options in the same call are
  /// ignored. Only the first idle stop counts; a later stop without it stops
  /// at once. Port of eino `UntilIdleFor`.
  factory StopOption.untilIdleFor(Duration duration) {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(
        duration,
        'duration',
        'adk: UntilIdleFor: duration must be positive',
      );
    }
    return _UntilIdleForStop(duration);
  }

  void _apply(StopConfig config);
}

const Set<CancelSafePoint> _anySafePoint = {
  CancelSafePoint.afterChatModel,
  CancelSafePoint.afterToolCalls,
};

final class _GracefulStop extends StopOption {
  const _GracefulStop() : super._();

  @override
  void _apply(StopConfig config) => config.cancel =
      (safePoints: _anySafePoint, timeout: null, recursive: true);
}

final class _ImmediateStop extends StopOption {
  const _ImmediateStop() : super._();

  @override
  void _apply(StopConfig config) =>
      config.cancel = (safePoints: const {}, timeout: null, recursive: true);
}

final class _GracefulTimeoutStop extends StopOption {
  const _GracefulTimeoutStop(this.gracePeriod) : super._();

  final Duration gracePeriod;

  @override
  void _apply(StopConfig config) => config.cancel =
      (safePoints: _anySafePoint, timeout: gracePeriod, recursive: true);
}

final class _SkipCheckpointStop extends StopOption {
  const _SkipCheckpointStop() : super._();

  @override
  void _apply(StopConfig config) => config.skipCheckpoint = true;
}

final class _CauseStop extends StopOption {
  const _CauseStop(this.cause) : super._();

  final String cause;

  @override
  void _apply(StopConfig config) => config.cause = cause;
}

final class _UntilIdleForStop extends StopOption {
  const _UntilIdleForStop(this.duration) : super._();

  final Duration duration;

  @override
  void _apply(StopConfig config) => config.idleFor = duration;
}

/// What one push asks for. Port of eino `pushConfig`.
final class _PushConfig<T> {
  bool preempt = false;
  Duration preemptDelay = Duration.zero;
  CancelArgs? cancel;
  List<PushOption<T>> Function(RunContext ctx, TurnContext<T>? turn)? strategy;
}

/// An option of [TurnLoop.push].
///
/// Port of eino's `PushOption` constructors.
sealed class PushOption<T> {
  const PushOption._();

  /// Cancels the running turn at [safePoints] (not empty) once the item is
  /// buffered; the next turn's `genInput` sees it with the other buffered
  /// items. No escalation, so not recursive. Port of eino `WithPreempt`.
  factory PushOption.preempt(Set<CancelSafePoint> safePoints) {
    _checkSafePoints(safePoints);
    return _PreemptPush<T>(Set.unmodifiable(safePoints), null);
  }

  /// Like [PushOption.preempt], but cancels at once (and recursively) when
  /// the safe point is not reached within [timeout]. Port of eino
  /// `WithPreemptTimeout`.
  factory PushOption.preemptTimeout(
    Set<CancelSafePoint> safePoints,
    Duration timeout,
  ) {
    _checkSafePoints(safePoints);
    return _PreemptPush<T>(Set.unmodifiable(safePoints), timeout);
  }

  /// Resolves the preempt of the same push only after [delay], against the
  /// turn the push saw: a turn that ended meanwhile is not cancelled, nor is
  /// a later one. Port of eino `WithPreemptDelay`.
  factory PushOption.preemptDelay(Duration delay) = _PreemptDelayPush<T>;

  /// Decides the options when the push happens, from the running turn
  /// (`null` between turns); the other options of the same push are ignored,
  /// and a strategy among the returned options is dropped. Port of eino
  /// `WithPushStrategy`.
  factory PushOption.strategy(
    List<PushOption<T>> Function(RunContext ctx, TurnContext<T>? turn) strategy,
  ) = _StrategyPush<T>;

  static void _checkSafePoints(Set<CancelSafePoint> safePoints) {
    if (safePoints.isEmpty) {
      throw ArgumentError.value(
        safePoints,
        'safePoints',
        'adk: SafePoint must not be zero; use afterToolCalls, afterChatModel, '
            'or both',
      );
    }
  }

  void _apply(_PushConfig<T> config);
}

final class _PreemptPush<T> extends PushOption<T> {
  const _PreemptPush(this.safePoints, this.timeout) : super._();

  final Set<CancelSafePoint> safePoints;
  final Duration? timeout;

  @override
  void _apply(_PushConfig<T> config) {
    config
      ..preempt = true
      ..cancel = (
        safePoints: safePoints,
        timeout: timeout,
        recursive: timeout != null,
      );
  }
}

final class _PreemptDelayPush<T> extends PushOption<T> {
  const _PreemptDelayPush(this.delay) : super._();

  final Duration delay;

  @override
  void _apply(_PushConfig<T> config) => config.preemptDelay = delay;
}

final class _StrategyPush<T> extends PushOption<T> {
  const _StrategyPush(this.strategy) : super._();

  final List<PushOption<T>> Function(RunContext ctx, TurnContext<T>? turn)
      strategy;

  @override
  void _apply(_PushConfig<T> config) => config.strategy = strategy;
}

/// What `genInput` decided for a turn. Port of eino `GenInputResult`.
final class GenInputResult<T> {
  /// Run the agent on [input] for the items [consumed]; keep [remaining].
  const GenInputResult({
    required this.input,
    this.runContext,
    this.runOptions = const [],
    this.consumed = const [],
    this.remaining = const [],
  });

  /// The context of this turn (`prepareAgent`, the agent's run,
  /// `onAgentEvents`); derive it from the context `genInput` got. `null`
  /// keeps the loop's.
  final RunContext? runContext;

  /// The agent's input.
  final AgentInput input;

  /// The options of the agent's run. Do not pass
  /// `AgentRunOption.checkpointId`: the loop sets it.
  final List<AgentRunOption> runOptions;

  /// The items this turn handles; `prepareAgent` gets them.
  final List<T> consumed;

  /// The items kept for a later turn. Items in neither list are dropped.
  final List<T> remaining;
}

/// What `genResume` decided for the turn that continues an interrupted one.
/// Port of eino `GenResumeResult`.
final class GenResumeResult<T> {
  /// Resume the interrupted agent for the items [consumed]; keep
  /// [remaining].
  const GenResumeResult({
    this.runContext,
    this.runOptions = const [],
    this.resumeParams,
    this.consumed = const [],
    this.remaining = const [],
  });

  /// The context of the resumed turn; `null` keeps the loop's.
  final RunContext? runContext;

  /// The options of the resumed run (no `checkpointId`: the loop sets it).
  final List<AgentRunOption> runOptions;

  /// Data for the interrupt points, for a targeted resume.
  final ResumeParams? resumeParams;

  /// The items this turn handles.
  final List<T> consumed;

  /// The items kept for a later turn. Items in neither list are dropped.
  final List<T> remaining;
}

/// What `onAgentEvents` knows about the running turn. Port of eino
/// `TurnContext`.
final class TurnContext<T> {
  TurnContext._({
    required this.loop,
    required this.consumed,
    required Completer<void> preempted,
    required Completer<void> stopped,
    required String Function() stopCause,
  })  : _preempted = preempted,
        _stopped = stopped,
        _stopCause = stopCause;

  /// The loop, to push items or stop from inside the callbacks.
  final TurnLoop<T> loop;

  /// The items this turn handles.
  final List<T> consumed;

  final Completer<void> _preempted;
  final Completer<void> _stopped;
  final String Function() _stopCause;

  /// Completes when a preempting push took part in cancelling this turn.
  /// Port of eino `TurnContext.Preempted` (a channel that closes).
  Future<void> get preempted => _preempted.future;

  /// Whether [preempted] has completed.
  bool get isPreempted => _preempted.isCompleted;

  /// Completes when a [TurnLoop.stop] took part in cancelling this turn. Port
  /// of eino `TurnContext.Stopped`.
  Future<void> get stopped => _stopped.future;

  /// Whether [stopped] has completed.
  bool get isStopped => _stopped.isCompleted;

  /// The stop's reason; meaningful once [stopped] has completed. Port of eino
  /// `TurnContext.StopCause`.
  String get stopCause => _stopCause();
}

/// The loop exited because the agent interrupted (an `interruptEvent`, or a
/// tool's `interrupt`), as opposed to being cancelled.
///
/// Port of eino `adk.InterruptError`. The loop writes a checkpoint (with a
/// store and a checkpoint id); a new loop with the same id continues it
/// through `genResume`, whose [ResumeParams] use the ids of
/// [interruptContexts].
class TurnLoopInterruptedException extends ThreepioException {
  /// The interrupt with the points [interruptContexts].
  TurnLoopInterruptedException(List<InterruptCtx> interruptContexts)
      : interruptContexts = List.unmodifiable(interruptContexts),
        super('agent interrupted: ${interruptContexts.length} context(s)');

  /// The interrupt points, for a targeted resume.
  final List<InterruptCtx> interruptContexts;

  @override
  String toString() => 'TurnLoopInterruptedException: $message';
}

/// How a [TurnLoop] ended. Port of eino `TurnLoopExitState`.
final class TurnLoopExitState<T> {
  TurnLoopExitState._({
    required this.exitReason,
    required this.exitStackTrace,
    required this.unhandledItems,
    required this.interruptedItems,
    required this.stopCause,
    required this.checkpointAttempted,
    required this.checkpointError,
    required List<T> Function() takeLateItems,
  }) : _takeLateItems = takeLateItems;

  /// Why the loop ended: `null` for a clean exit (a stop without cancel, or
  /// the agent finished before the stop took effect); an
  /// [AgentRunCancelledException] when a stop or a preempt cancelled the
  /// agent; a [TurnLoopInterruptedException]; the error of a callback; a
  /// `CancelledException` when the loop's context was cancelled. Never a
  /// checkpoint error (see [checkpointError]).
  final Object? exitReason;

  /// Where [exitReason] was thrown, when known.
  final StackTrace? exitStackTrace;

  /// Items that were accepted but never handled by a turn.
  final List<T> unhandledItems;

  /// The items of the turn that was cancelled or interrupted; a resumed loop
  /// passes them to `genResume`.
  final List<T> interruptedItems;

  /// The reason given with [StopOption.cause]; empty without one.
  final String stopCause;

  /// Whether the loop tried to write a checkpoint: with a store and an id,
  /// not idle, without [StopOption.skipCheckpoint], after a stop (clean or
  /// cancelling) or an interrupt.
  final bool checkpointAttempted;

  /// The error of writing the checkpoint, if any.
  final Object? checkpointError;

  final List<T> Function() _takeLateItems;

  /// The items pushed after the loop stopped (their push returned `false`),
  /// not in the checkpoint. The same list every time; afterwards a push that
  /// would add one throws [StateError] instead of losing it. Port of eino
  /// `TakeLateItems`.
  List<T> takeLateItems() => _takeLateItems();
}

/// The configuration of a [TurnLoop]. Port of eino `TurnLoopConfig`.
final class TurnLoopConfig<T> {
  /// A loop that plans turns with [genInput] and runs the agent of
  /// [prepareAgent].
  const TurnLoopConfig({
    required this.genInput,
    required this.prepareAgent,
    this.genResume,
    this.onAgentEvents,
    this.store,
    this.checkpointId = '',
  });

  /// Gets every buffered item and decides what this turn handles
  /// ([GenInputResult.consumed]) and what waits ([GenInputResult.remaining]).
  /// May push or stop through `loop`.
  final Future<GenInputResult<T>> Function(
    RunContext ctx,
    TurnLoop<T> loop,
    List<T> items,
  ) genInput;

  /// Plans the turn that continues an interrupted or cancelled run found in
  /// the checkpoint; called at most once per [TurnLoop.run], and required for
  /// such a checkpoint. It gets the items of the interrupted turn, the items
  /// left unhandled, and the items pushed before `run`.
  final Future<GenResumeResult<T>> Function(
    RunContext ctx,
    TurnLoop<T> loop,
    List<T> interruptedItems,
    List<T> unhandledItems,
    List<T> newItems,
  )? genResume;

  /// The agent for one turn, set up for the items it handles.
  final Future<Agent> Function(
    RunContext ctx,
    TurnLoop<T> loop,
    List<T> consumed,
  ) prepareAgent;

  /// Handles the events of a turn's agent. Throw only to end the loop with
  /// that error; do not rethrow an [AgentRunCancelledException] (the loop
  /// handles cancels itself: a stop's cancel becomes the exit reason, a
  /// preempt's starts the next turn). By default the events are read and the
  /// first error event ends the loop with its error.
  final Future<void> Function(
    RunContext ctx,
    TurnContext<T> turn,
    StreamReader<AgentEvent> events,
  )? onAgentEvents;

  /// Where checkpoints are written and read. Items must be JSON or of types
  /// registered with `TypeRegistry.registerName` when a store is used.
  final CheckpointStore? store;

  /// With [store]: the checkpoint [TurnLoop.run] continues from (a cancelled
  /// or interrupted run is resumed through [genResume]; between-turns state
  /// buffers the unhandled items), and the id the loop writes its checkpoint
  /// under when it exits. A clean exit deletes it (with a
  /// `CheckpointDeleter` store).
  final String checkpointId;
}

/// The turn the loop is about to run. Port of eino `turnRunSpec`.
final class _TurnRunSpec<T> {
  _TurnRunSpec({
    required this.consumed,
    this.input,
    this.runOptions = const [],
    this.resumeParams,
    this.isResume = false,
    this.resumeBytes,
  });

  final AgentInput? input;
  final List<AgentRunOption> runOptions;
  final ResumeParams? resumeParams;
  final bool isResume;
  final List<T> consumed;
  final Uint8List? resumeBytes;
}

/// The planned turn. Port of eino `turnPlan`.
final class _TurnPlan<T> {
  _TurnPlan(this.turnContext, this.remaining, this.spec);

  final RunContext turnContext;
  final List<T> remaining;
  final _TurnRunSpec<T> spec;
}

/// The run found in a checkpoint. Port of eino `turnLoopPendingResume`.
final class _PendingResume<T> {
  _PendingResume({
    required this.interrupted,
    required this.unhandled,
    required this.newItems,
    required this.resumeBytes,
  });

  final List<T> interrupted;
  final List<T> unhandled;
  final List<T> newItems;
  final Uint8List resumeBytes;
}

/// Runs an agent over the items pushed to it, one turn at a time: each turn
/// plans what to handle (`genInput`), prepares an agent for it
/// (`prepareAgent`), runs it and hands its events to `onAgentEvents`.
///
/// Port of eino `adk.TurnLoop` (`NewTurnLoop`), with classic messages. For
/// example, new clipboard items arriving while the agent works:
///
/// ```dart
/// final loop = TurnLoop<Clip>(TurnLoopConfig(
///   genInput: (ctx, loop, items) async => GenInputResult(
///     input: AgentInput(messages: [for (final c in items) Message.user(c.text)]),
///     consumed: items,
///   ),
///   prepareAgent: (ctx, loop, consumed) async => agent,
/// ));
/// loop.run(ctx);
/// loop.push(clip);                                    // handled by a turn
/// loop.push(urgent, options: [
///   PushOption.preempt({CancelSafePoint.afterToolCalls}),
/// ]);                                                  // cancels the turn
/// loop.stop();
/// final exit = await loop.wait();
/// ```
///
/// Every method works before [run]: pushed items wait, a stop makes the
/// later `run` exit at once, and [wait] completes after `run` was called and
/// the loop ended. With [TurnLoopConfig.store] and
/// [TurnLoopConfig.checkpointId] a stopped, cancelled or interrupted loop
/// writes a checkpoint that a new loop continues.
final class TurnLoop<T> {
  /// A loop that has not started yet.
  TurnLoop(this.config);

  /// The configuration.
  final TurnLoopConfig<T> config;

  final TurnBuffer<T> _buffer = TurnBuffer<T>();
  final StopController _stopCtrl = StopController();
  final PreemptController _preemptCtrl = PreemptController();
  final Completer<TurnLoopExitState<T>> _done =
      Completer<TurnLoopExitState<T>>();

  bool _stopped = false;
  bool _started = false;

  Object? _runError;
  StackTrace? _runStackTrace;
  List<T> _interruptedItems = [];
  Uint8List? _runnerCheckpoint;
  List<InterruptCtx>? _interruptContexts;
  AgentRunCancelledException? _capturedCancelError;
  _PendingResume<T>? _pendingResume;
  String _loadCheckpointId = '';

  final List<T> _lateItems = [];
  bool _lateSealed = false;
  final Set<Timer> _delayedPreempts = {};
  final Map<Timer, Completer<void>> _delayedAcks = {};

  /// Starts the loop in the background; later calls do nothing. Results come
  /// from [wait]. With a checkpoint id and a matching checkpoint the loop
  /// continues it. Port of eino `TurnLoop.Run`.
  void run(RunContext ctx) {
    if (_started) return;
    _started = true;
    unawaited(_run(ctx));
  }

  /// Buffers [item] for the next turn; `accepted` is `false` once the loop
  /// has stopped (the item then goes to [TurnLoopExitState.takeLateItems]).
  /// Port of eino `TurnLoop.Push`.
  ///
  /// With [PushOption.preempt] or [PushOption.preemptTimeout] the push also
  /// cancels the turn it sees; `resolved` completes once that cancel was
  /// submitted, or at once when there is no such turn (also before [run]).
  /// For any other push, and for a push that is not accepted, `resolved` is
  /// `null`, as eino returns a nil channel there.
  ({bool accepted, Future<void>? resolved}) push(
    T item, {
    List<PushOption<T>> options = const [],
  }) {
    final config = _PushConfig<T>();
    for (final option in options) {
      option._apply(config);
    }
    if (config.strategy != null) return _pushWithStrategy(item, config);
    return _pushWithConfig(item, config);
  }

  ({bool accepted, Future<void>? resolved}) _rejected(T item) {
    _appendLate(item);
    return (accepted: false, resolved: null);
  }

  ({bool accepted, Future<void>? resolved}) _pushWithStrategy(
    T item,
    _PushConfig<T> strategyConfig,
  ) {
    final snapshot = _preemptCtrl.beginPush();
    try {
      final turn = snapshot.turnContext as TurnContext<T>?;
      final options = strategyConfig.strategy!(
        snapshot.ctx ?? RunContext.background(),
        turn,
      );
      final config = _PushConfig<T>();
      for (final option in options) {
        option._apply(config);
      }
      config.strategy = null;

      if (!config.preempt) {
        if (!_buffer.trySend(item)) return _rejected(item);
        return (accepted: true, resolved: null);
      }
      if (_stopped) return _rejected(item);
      if (!_buffer.trySend(item)) return _rejected(item);
      return (accepted: true, resolved: _preempt(snapshot, config));
    } finally {
      _preemptCtrl.endPush();
    }
  }

  ({bool accepted, Future<void>? resolved}) _pushWithConfig(
    T item,
    _PushConfig<T> config,
  ) {
    if (_stopped) return _rejected(item);
    if (!config.preempt) {
      if (!_buffer.trySend(item)) return _rejected(item);
      return (accepted: true, resolved: null);
    }
    final snapshot = _preemptCtrl.beginPush();
    try {
      if (!_buffer.trySend(item)) return _rejected(item);
      return (accepted: true, resolved: _preempt(snapshot, config));
    } finally {
      _preemptCtrl.endPush();
    }
  }

  Future<void> _preempt(PreemptTurnSnapshot snapshot, _PushConfig<T> config) {
    final ack = Completer<void>();
    if (!_started) {
      ack.complete();
      return ack.future;
    }
    final cancel = config.cancel!;
    if (config.preemptDelay > Duration.zero) {
      late final Timer timer;
      timer = Timer(config.preemptDelay, () {
        _delayedPreempts.remove(timer);
        _delayedAcks.remove(timer);
        _preemptCtrl.requestPreempt(snapshot, ack, cancel);
      });
      _delayedPreempts.add(timer);
      _delayedAcks[timer] = ack;
    } else {
      _preemptCtrl.requestPreempt(snapshot, ack, cancel);
    }
    return ack.future;
  }

  void _appendLate(T item) {
    if (_lateSealed) {
      throw StateError('TurnLoop: Push called after TakeLateItems');
    }
    _lateItems.add(item);
  }

  /// Asks the loop to stop and returns at once. Port of eino `TurnLoop.Stop`.
  ///
  /// Without options the running turn finishes and the loop ends before the
  /// next one ([TurnLoopExitState.exitReason] `null`).
  /// [StopOption.immediate], [StopOption.graceful] and
  /// [StopOption.gracefulTimeout] cancel the running agent;
  /// [StopOption.untilIdleFor] waits for an idle loop. May be called several
  /// times (cancel options are merged, never weakened) and before [run]. An
  /// agent that does not support cancel finishes its turn.
  void stop({List<StopOption> options = const []}) {
    final config = StopConfig();
    for (final option in options) {
      option._apply(config);
    }
    // An idle stop must not affect a running agent: its cancel options go.
    if (config.idleFor > Duration.zero) config.cancel = null;
    final decision = _stopCtrl.requestStop(config);
    if (decision.wakeIdle) _buffer.wakeup();
    if (decision.commit) _finishStopCommit();
  }

  void _commitStop() {
    if (!_stopCtrl.commit()) return;
    _finishStopCommit();
  }

  void _finishStopCommit() {
    _stopped = true;
    _buffer.close();
  }

  /// Completes when the loop has ended, with how it ended; every caller gets
  /// the same state. It completes only after [run] was called. Port of eino
  /// `TurnLoop.Wait`.
  Future<TurnLoopExitState<T>> wait() => _done.future;

  Future<void> _run(RunContext ctx) async {
    void Function()? stopWatchingContext;
    try {
      try {
        await _tryLoadCheckpoint(ctx);
        // A checkpoint that cannot be read ends the loop.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        _setRunError(error, stackTrace);
        return;
      }
      // A cancelled context closes the buffer, so that a waiting receive
      // returns and the loop sees the cancel. The watch is a token of its
      // own, released at the end: the context's token may outlive the loop.
      var watching = true;
      final watch = CancelToken.any([ctx.cancelToken, CancelToken()])!;
      stopWatchingContext = () {
        watching = false;
        watch.cancel();
      };
      unawaited(
        watch.whenCancelled.then((_) {
          if (watching) _buffer.close();
        }),
      );

      while (true) {
        if (_stopCtrl.isCommitted) return;

        var isResume = false;
        _PendingResume<T>? pending;
        var items = <T>[];
        var pushBack = <T>[];

        if (_pendingResume != null) {
          isResume = true;
          pending = _pendingResume;
          _pendingResume = null;
          await _preemptCtrl.waitForPushes();
          pending!.newItems.addAll(_buffer.takeAll());
          pushBack = [
            ...pending.interrupted,
            ...pending.unhandled,
            ...pending.newItems,
          ];
        } else {
          bool ok;
          T? first;
          final idleFor = _stopCtrl.idleDuration;
          if (idleFor > Duration.zero) {
            _buffer.clearWakeup();
            // When the idle time is over the stop is committed, which closes
            // the buffer and ends the receive below.
            final idleTimer = Timer(idleFor, _commitStop);
            (ok, first) = await _buffer.receive();
            idleTimer.cancel();
            // Woken by a stop that arrived between clearWakeup and receive:
            // start the idle time again.
            if (!ok && !_buffer.isClosed) continue;
          } else {
            (ok, first) = await _buffer.receive();
            // Woken by an idle stop: start its timer.
            if (!ok && _stopCtrl.idleDuration > Duration.zero) continue;
          }

          if (!ok) {
            if (ctx.cancelToken.isCancelled) {
              _setRunError(CancelledException(ctx.cancelToken.reason));
            }
            return;
          }
          final item = first as T;
          if (ctx.cancelToken.isCancelled) {
            _buffer.pushFront([item]);
            _setRunError(CancelledException(ctx.cancelToken.reason));
            return;
          }
          if (_stopCtrl.isCommitted) {
            _buffer.pushFront([item]);
            return;
          }
          await _preemptCtrl.waitForPushes();
          items = [item, ..._buffer.takeAll()];
          pushBack = items;
        }

        _preemptCtrl.beginPlanningTurn();
        void abortPlanning() => _preemptCtrl.abortPlanningTurn().ack();

        final _TurnPlan<T> plan;
        try {
          plan = await _planTurn(ctx, isResume, items, pending);
          // A failure of genInput or genResume ends the loop.
          // ignore: avoid_catches_without_on_clauses
        } catch (error, stackTrace) {
          abortPlanning();
          _buffer.pushFront(pushBack);
          _setRunError(error, stackTrace);
          return;
        }
        if (_stopCtrl.isCommitted) {
          abortPlanning();
          _buffer.pushFront(pushBack);
          return;
        }

        final Agent agent;
        try {
          agent = await config.prepareAgent(
            plan.turnContext,
            this,
            plan.spec.consumed,
          );
          // A failure of prepareAgent ends the loop.
          // ignore: avoid_catches_without_on_clauses
        } catch (error, stackTrace) {
          abortPlanning();
          _buffer.pushFront(pushBack);
          _setRunError(error, stackTrace);
          return;
        }
        if (_stopCtrl.isCommitted) {
          abortPlanning();
          _buffer.pushFront(pushBack);
          return;
        }

        _buffer.pushFront(plan.remaining);

        final (turnError, turnStackTrace) =
            await _runAgentAndHandleEvents(plan.turnContext, agent, plan.spec);
        if (turnError != null) {
          // The items were in flight when a cancel or an interrupt came,
          // whatever the callback returned.
          if (_capturedCancelError != null || _interruptContexts != null) {
            _interruptedItems = List.of(plan.spec.consumed);
          }
          _setRunError(turnError, turnStackTrace);
          return;
        }
        final interruptContexts = _interruptContexts;
        if (interruptContexts != null) {
          // The agent interrupted: exit to write the checkpoint.
          _interruptedItems = List.of(plan.spec.consumed);
          _setRunError(TurnLoopInterruptedException(interruptContexts));
          return;
        }
      }
    } finally {
      stopWatchingContext?.call();
      await _cleanup();
    }
  }

  void _setRunError(Object error, [StackTrace? stackTrace]) {
    _runError = error;
    _runStackTrace = stackTrace;
  }

  /// Port of eino `planTurn`.
  Future<_TurnPlan<T>> _planTurn(
    RunContext ctx,
    bool isResume,
    List<T> items,
    _PendingResume<T>? pending,
  ) async {
    if (!isResume) {
      final result = await config.genInput(ctx, this, items);
      return _TurnPlan(
        result.runContext ?? ctx,
        result.remaining,
        _TurnRunSpec(
          input: result.input,
          runOptions: result.runOptions,
          consumed: result.consumed,
        ),
      );
    }
    if (pending == null) {
      throw const ThreepioException('resume payload is nil');
    }
    final genResume = config.genResume;
    if (genResume == null) {
      throw const ThreepioException('GenResume is required for resume');
    }
    final result = await genResume(
      ctx,
      this,
      pending.interrupted,
      pending.unhandled,
      pending.newItems,
    );
    return _TurnPlan(
      result.runContext ?? ctx,
      result.remaining,
      _TurnRunSpec(
        runOptions: result.runOptions,
        resumeParams: result.resumeParams,
        isResume: true,
        consumed: result.consumed,
        resumeBytes: pending.resumeBytes,
      ),
    );
  }

  /// Port of eino `setupBridgeStore`.
  (List<AgentRunOption>, BridgeStore?) _setupBridgeStore(_TurnRunSpec<T> spec) {
    final store = config.store;
    if (store == null && spec.isResume) {
      throw const ThreepioException(
        'failed to resume agent: checkpoint store is nil',
      );
    }
    if (store == null) return (spec.runOptions, null);
    final options = [
      ...spec.runOptions,
      AgentRunOption.checkpointId(bridgeCheckpointId),
    ];
    if (spec.isResume) {
      final bytes = spec.resumeBytes;
      if (bytes == null || bytes.isEmpty) {
        throw const ThreepioException('resume checkpoint is empty');
      }
      return (options, BridgeStore.resume(bridgeCheckpointId, bytes));
    }
    return (options, BridgeStore());
  }

  /// Runs one turn's agent and hands its events to `onAgentEvents`; returns
  /// the error the loop ends with, if any. Port of eino
  /// `runAgentAndHandleEvents`.
  Future<(Object?, StackTrace?)> _runAgentAndHandleEvents(
    RunContext ctx,
    Agent agent,
    _TurnRunSpec<T> spec,
  ) async {
    _interruptContexts = null;
    _capturedCancelError = null;
    _runnerCheckpoint = null;

    List<AgentRunOption> runOptions;
    final BridgeStore? bridge;
    try {
      (runOptions, bridge) = _setupBridgeStore(spec);
      // A missing store or checkpoint for a resume ends the loop.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      _preemptCtrl.abortPlanningTurn().ack();
      return (error, stackTrace);
    }
    final (cancelOption, cancel) = withCancel();
    runOptions = [...runOptions, cancelOption];

    // A resumed run streams as the saved run did; the flag only matters for
    // a new run.
    final runner = Runner(
      agent: agent,
      enableStreaming: spec.input?.enableStreaming ?? false,
      checkpointStore: bridge,
    );

    final preempted = Completer<void>();
    final stopped = Completer<void>();
    final turn = TurnContext<T>._(
      loop: this,
      consumed: spec.consumed,
      preempted: preempted,
      stopped: stopped,
      stopCause: () => _stopCtrl.cause,
    );
    _preemptCtrl.beginActiveTurn(ctx, turn);
    _stopCtrl.beginActiveTurn();
    try {
      StreamReader<AgentEvent> events;
      if (spec.isResume) {
        try {
          final params = spec.resumeParams;
          events = params != null
              ? await runner.resumeWithParams(
                  ctx,
                  bridgeCheckpointId,
                  params,
                  options: runOptions,
                )
              : await runner.resume(
                  ctx,
                  bridgeCheckpointId,
                  options: runOptions,
                );
          // The runner's failure to load the checkpoint.
          // ignore: avoid_catches_without_on_clauses
        } catch (error, stackTrace) {
          return (
            ThreepioException('failed to resume agent: $error', cause: error),
            stackTrace,
          );
        }
      } else {
        events = runner.run(ctx, spec.input!.messages, options: runOptions);
      }

      // The loop sees cancels and interrupts whatever the callback does with
      // the events.
      final proxied = _captured(events);

      // Which signal of the turn came first, before the callback was done.
      String? firstSignal;
      unawaited(preempted.future.then((_) => firstSignal ??= 'preempted'));
      unawaited(stopped.future.then((_) => firstSignal ??= 'stopped'));

      void watchPreempt() {
        final request = _preemptCtrl.receivePreempt();
        if (request == null) return;
        // The handle is not awaited: the cancel is registered at once, and
        // waiting would wait for the end of the turn.
        final handle = _submit(cancel, request.cancelArgs(clock.now()));
        if (handle.contributed && !preempted.isCompleted) preempted.complete();
        request.ack();
      }

      void watchStop() {
        for (var request = _stopCtrl.receiveCancel();
            request != null;
            request = _stopCtrl.receiveCancel()) {
          final handle = _submit(cancel, request.cancelArgs(clock.now()));
          if (handle.contributed && !stopped.isCompleted) stopped.complete();
        }
      }

      _preemptCtrl.attachWatcher(watchPreempt);
      _stopCtrl.attachWatcher(watchStop);
      watchStop();

      Object? handleError;
      StackTrace? handleStackTrace;
      try {
        await (config.onAgentEvents ?? _defaultOnAgentEvents)(
          ctx,
          turn,
          proxied,
        );
        // A callback's failure ends the loop.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        handleError = error;
        handleStackTrace = stackTrace;
      } finally {
        _preemptCtrl.detachWatcher();
        _stopCtrl.detachWatcher();
      }
      // Signals that completed in the same instant as the callback.
      await Future<void>.value();

      if (firstSignal == 'preempted' ||
          (firstSignal == null && preempted.isCompleted)) {
        // A preempt cancelled the turn: the loop goes on with the next one.
        return (null, null);
      }
      if (bridge != null) {
        final data = bridge.lastCheckpoint;
        if (data != null) _runnerCheckpoint = Uint8List.fromList(data);
      }
      if (handleError != null) return (handleError, handleStackTrace);
      return (_capturedCancelError, null);
    } finally {
      _stopCtrl.endActiveTurn();
      _preemptCtrl.endActiveTurn().ack();
    }
  }

  /// [events], passed on as they come, with the loop noting cancels and
  /// interrupts. Port of the proxy goroutine of eino
  /// `runAgentAndHandleEvents`.
  StreamReader<AgentEvent> _captured(StreamReader<AgentEvent> events) {
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(() async {
      try {
        for (var event = await events.nextOrNull();
            event != null;
            event = await events.nextOrNull()) {
          final cancelled =
              ThreepioException.findCause<AgentRunCancelledException>(
            event.error,
          );
          if (cancelled != null) _capturedCancelError = cancelled;
          final interrupted = event.action?.interrupted;
          if (interrupted != null) {
            _interruptContexts = interrupted.interruptContexts;
          }
          writer.send(event);
        }
        // The runner turns failures into events; this is a failure of the
        // reader itself.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        writer.send(AgentEvent(error: error, stackTrace: stackTrace));
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }

  static Future<void> _defaultOnAgentEvents<T>(
    RunContext ctx,
    TurnContext<T> turn,
    StreamReader<AgentEvent> events,
  ) async {
    for (var event = await events.nextOrNull();
        event != null;
        event = await events.nextOrNull()) {
      final error = event.error;
      if (error != null) {
        Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
      }
    }
  }

  /// Port of eino `tryLoadCheckpoint`.
  Future<void> _tryLoadCheckpoint(RunContext ctx) async {
    final id = config.checkpointId;
    final store = config.store;
    if (id.isEmpty || store == null) return;
    _loadCheckpointId = id;

    final Uint8List? data;
    try {
      data = await store.get(id);
      // Whatever the store throws.
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      throw ThreepioException(
        'failed to load checkpoint[$id]: $error',
        cause: error,
      );
    }
    if (data == null || data.isEmpty) return;

    final _TurnLoopCheckpoint<T> checkpoint;
    try {
      checkpoint = _TurnLoopCheckpoint.decode<T>(data);
      // Bad JSON, or items that are not of the loop's type.
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      throw ThreepioException(
        'failed to unmarshal checkpoint[$id]: $error',
        cause: error,
      );
    }

    final newItems = _buffer.takeAll();
    if (checkpoint.hasRunnerState) {
      final runner = checkpoint.runnerCheckpoint;
      if (runner == null || runner.isEmpty) {
        _buffer.pushFront(newItems);
        throw ThreepioException(
          'checkpoint[$id] has runner state but bytes are empty',
        );
      }
      _pendingResume = _PendingResume(
        interrupted: List.of(checkpoint.interruptedItems),
        unhandled: List.of(checkpoint.unhandledItems),
        newItems: List.of(newItems),
        resumeBytes: Uint8List.fromList(runner),
      );
    } else {
      _buffer.pushFront([...checkpoint.unhandledItems, ...newItems]);
    }
  }

  /// Port of eino `cleanup`.
  Future<void> _cleanup() async {
    _stopped = true;
    for (final timer in _delayedPreempts) {
      timer.cancel();
      final ack = _delayedAcks[timer];
      if (ack != null && !ack.isCompleted) ack.complete();
    }
    _delayedPreempts.clear();
    _delayedAcks.clear();

    final unhandled = _buffer.takeAll();
    // From here on a push is late, also while the checkpoint is written.
    _buffer.close();
    final id = config.checkpointId;
    final store = config.store;
    final runnerCheckpoint = _runnerCheckpoint;
    final isIdle = (runnerCheckpoint == null || runnerCheckpoint.isEmpty) &&
        unhandled.isEmpty &&
        _interruptedItems.isEmpty;

    // A checkpoint only after a stop (clean or cancelling) or an interrupt;
    // also when a cancel or interrupt was seen in the events but the
    // callback failed with an error of its own (the items were in flight).
    final error = _runError;
    final exitCausedByStop = error == null ||
        ThreepioException.findCause<AgentRunCancelledException>(error) !=
            null ||
        _capturedCancelError != null;
    final businessInterrupt =
        ThreepioException.findCause<TurnLoopInterruptedException>(error) !=
                null ||
            _interruptContexts != null;
    final shouldSave = store != null &&
        id.isNotEmpty &&
        ((_stopCtrl.isCommitted && exitCausedByStop) || businessInterrupt) &&
        !isIdle &&
        !_stopCtrl.skipCheckpoint;

    var attempted = false;
    Object? checkpointError;
    if (shouldSave) {
      attempted = true;
      try {
        await store.set(
          id,
          _TurnLoopCheckpoint<T>(
            runnerCheckpoint: runnerCheckpoint,
            hasRunnerState:
                runnerCheckpoint != null && runnerCheckpoint.isNotEmpty,
            unhandledItems: unhandled,
            interruptedItems: _interruptedItems,
          ).encode(),
        );
        // Whatever the store or the encoder throws.
        // ignore: avoid_catches_without_on_clauses
      } catch (saveError) {
        checkpointError = saveError;
      }
    } else if (_loadCheckpointId.isNotEmpty && store is CheckpointDeleter) {
      try {
        await (store as CheckpointDeleter).delete(_loadCheckpointId);
        // A stale checkpoint that cannot be deleted is ignored, as in eino.
        // ignore: avoid_catches_without_on_clauses
      } catch (_) {}
    }

    List<T>? lateItems;
    final result = TurnLoopExitState<T>._(
      exitReason: _runError,
      exitStackTrace: _runStackTrace,
      unhandledItems: unhandled,
      interruptedItems: _interruptedItems,
      stopCause: _stopCtrl.cause,
      checkpointAttempted: attempted,
      checkpointError: checkpointError,
      takeLateItems: () {
        if (lateItems == null) {
          lateItems = List.unmodifiable(_lateItems);
          _lateSealed = true;
        }
        return lateItems!;
      },
    );
    _stopCtrl.closeForLoopExit();
    _preemptCtrl.closeForLoopExit();
    _buffer.close();
    _done.complete(result);
  }
}

/// What a [TurnLoop] writes to its store. Port of eino `turnLoopCheckpoint`,
/// as JSON: items through `TypeRegistry`, the runner's checkpoint as Base64.
final class _TurnLoopCheckpoint<T> {
  _TurnLoopCheckpoint({
    required this.runnerCheckpoint,
    required this.hasRunnerState,
    required this.unhandledItems,
    required this.interruptedItems,
  });

  static _TurnLoopCheckpoint<T> decode<T>(Uint8List data) {
    final json = jsonDecode(utf8.decode(data));
    if (json is! Map<String, Object?> || json['kind'] != _kind) {
      throw const FormatException('not a TurnLoop checkpoint');
    }
    List<T> items(Object? list) => [
          for (final item in (list as List<Object?>?) ?? const [])
            reviveFor<T>(TypeRegistry.decode(item)) as T,
        ];
    final runner = json['runner_checkpoint'];
    return _TurnLoopCheckpoint<T>(
      runnerCheckpoint: runner is String ? base64Decode(runner) : null,
      hasRunnerState: json['has_runner_state'] == true,
      unhandledItems: items(json['unhandled_items']),
      // Eino keeps the name `CanceledItems` for compatibility.
      interruptedItems: items(json['canceled_items']),
    );
  }

  static const _kind = '_eino_adk_turn_loop_checkpoint';

  final Uint8List? runnerCheckpoint;
  final bool hasRunnerState;
  final List<T> unhandledItems;
  final List<T> interruptedItems;

  Uint8List encode() => Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'kind': _kind,
            if (runnerCheckpoint != null)
              'runner_checkpoint': base64Encode(runnerCheckpoint!),
            'has_runner_state': hasRunnerState,
            'unhandled_items': [
              for (final item in unhandledItems) TypeRegistry.encode(item),
            ],
            'canceled_items': [
              for (final item in interruptedItems) TypeRegistry.encode(item),
            ],
          }),
        ),
      );
}
