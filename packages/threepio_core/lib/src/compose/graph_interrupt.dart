/// Interrupting a running graph from outside, and what a run collects about
/// an interrupt before it writes its checkpoint.
///
/// Port of `compose.WithGraphInterrupt` (eino `compose/graph_call_options.go`)
/// and of `interruptTempInfo` (`compose/graph_run.go`).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../core/run_context.dart';
import 'interrupt.dart';

/// The request to interrupt, shared by the handle that makes it and the runs
/// that obey it.
///
/// Port of eino `graphCancelSignal`.
@internal
final class GraphCancelSignal {
  /// A signal that nobody has triggered yet. [now] is the clock the time
  /// since the trigger is read from (a duration that only grows). It is real
  /// time by default; a test that runs on fake time and triggers the signal
  /// before a run listens passes the fake clock (`() => async.elapsed`).
  GraphCancelSignal({Duration Function()? now})
      : _now = now ?? (Stopwatch()..start()).elapsedGetter;

  final Duration Function() _now;
  final Completer<void> _triggered = Completer<void>();
  final Completer<void> _expired = Completer<void>();
  Duration? _timeout;
  Duration _triggeredAt = Duration.zero;
  Timer? _timer;
  int _listeners = 0;
  final Set<void Function()> _wakers = {};

  /// Whether an interrupt was asked for.
  bool isTriggered = false;

  /// Whether the time the running nodes were given is over. From then on a
  /// run does not wait for them.
  bool isExpired = false;

  /// Whether the interrupt gives running nodes a limited time. Without a
  /// limit a run waits until they have finished.
  bool get hasTimeout => _timeout != null;

  /// Has [wake] called when an interrupt is asked for and when its time is
  /// over, until [removeWaker]. A run registers the function that makes its
  /// wait look again, and takes it back when it ends: the signal may outlive
  /// many runs.
  void addWaker(void Function() wake) => _wakers.add(wake);

  /// Stops calling [wake].
  void removeWaker(void Function() wake) => _wakers.remove(wake);

  void _wakeAll() {
    for (final wake in _wakers.toList()) {
      wake();
    }
  }

  /// Completes when an interrupt is asked for.
  Future<void> get triggered => _triggered.future;

  /// Completes when the time for the running nodes is over.
  Future<void> get expired => _expired.future;

  /// Asks the runs under this signal to interrupt. With a [timeout] they wait
  /// that long for running nodes, counted from now; with zero not at all;
  /// without one until the nodes have finished.
  void trigger(Duration? timeout) {
    if (isTriggered) {
      throw StateError('compose: graph interrupt called more than once');
    }
    isTriggered = true;
    _timeout = timeout;
    _triggeredAt = _now();
    if (timeout != null && timeout <= Duration.zero) {
      _expire();
    } else {
      _startTimer(elapsed: Duration.zero);
    }
    _triggered.complete();
    _wakeAll();
  }

  /// Notes that a run listens to the signal. The timer of a timeout only runs
  /// while a run does, so that an interrupt nobody waits for holds nothing
  /// back. The time itself runs from the trigger, as in Eino: a run that
  /// attaches after it is over is interrupted at once.
  void attach() {
    _listeners++;
    _startTimer();
  }

  /// Notes that a run that listened has ended.
  void detach() {
    _listeners--;
    if (_listeners == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startTimer({Duration? elapsed}) {
    final timeout = _timeout;
    if (!isTriggered || isExpired || timeout == null) return;
    if (_listeners == 0 || _timer != null) return;
    final remaining = timeout - (elapsed ?? _now() - _triggeredAt);
    if (remaining <= Duration.zero) {
      _expire();
    } else {
      _timer = Timer(remaining, _expire);
    }
  }

  void _expire() {
    isExpired = true;
    _timer = null;
    if (!_expired.isCompleted) _expired.complete();
    _wakeAll();
  }
}

extension on Stopwatch {
  Duration Function() get elapsedGetter => () => elapsed;
}

final _cancelKey = ContextKey<GraphCancelSignal>('compose.graphInterrupt');

/// [ctx] with [signal] as the interrupt request its runs listen to.
@internal
RunContext withGraphCancelSignal(RunContext ctx, GraphCancelSignal signal) =>
    ctx.withValue(_cancelKey, signal);

/// The interrupt request the runs of [ctx] listen to, if any.
///
/// Port of eino `getGraphCancel`.
@internal
GraphCancelSignal? graphCancelOf(RunContext ctx) => ctx.value(_cancelKey);

/// Interrupts the graphs that run under the context it was created with.
///
/// Returned by `ctx.withGraphInterrupt()`. Port of the function
/// `compose.WithGraphInterrupt` returns.
final class GraphInterrupter {
  GraphInterrupter._(this._signal);

  /// The handle of [signal].
  @internal
  static GraphInterrupter of(GraphCancelSignal signal) =>
      GraphInterrupter._(signal);

  final GraphCancelSignal _signal;

  /// Whether [interrupt] was called.
  bool get isInterrupted => _signal.isTriggered;

  /// Interrupts the run: it stops at the next point it can, writes a
  /// checkpoint and fails with a `GraphInterruptedException`.
  ///
  /// Without a [timeout] the run waits for the nodes that are running and
  /// stops before it starts the next ones. With one it waits that long at
  /// most; the nodes that have not finished by then are abandoned (their
  /// results are ignored) and run again when the run is resumed. A zero
  /// timeout interrupts at once. Port of eino
  /// `compose.WithGraphInterruptTimeout`.
  ///
  /// A run that has ended is not affected. Throws [StateError] when called a
  /// second time.
  void interrupt({Duration? timeout}) => _signal.trigger(timeout);
}

/// What a run has learned about an interrupt while it winds down.
///
/// Port of eino `interruptTempInfo`.
@internal
final class InterruptTempInfo {
  /// The interrupts of nested graphs, by node key.
  final Map<String, SubGraphInterrupt> subGraphInterrupts = {};

  /// The nodes whose task ended with an interrupt signal.
  final Set<String> interruptTaskNodes = {};

  /// The nodes that run again when the run is resumed.
  final List<String> interruptRerunNodes = [];

  /// The nodes the run stops in front of.
  final List<String> interruptBeforeNodes = [];

  /// The nodes the run stops behind.
  final List<String> interruptAfterNodes = [];

  /// By node key, the info a node gave with its interrupt.
  final Map<String, Object?> interruptRerunExtra = {};

  /// The signals of the nodes and nested graphs that interrupted.
  final List<AddressedInterruptSignal> signals = [];

  /// Adds [signal] unless it is there already.
  void appendSignal(AddressedInterruptSignal? signal) {
    if (signal == null) return;
    for (final existing in signals) {
      if (identical(existing, signal) ||
          (signal.id.isNotEmpty && existing.id == signal.id)) {
        return;
      }
    }
    signals.add(signal);
  }

  /// Adds [key] to the nodes that run again, once.
  void addRerunNode(String key) {
    if (!interruptRerunNodes.contains(key)) interruptRerunNodes.add(key);
  }
}
