// Port of eino `compose/graph_manager_test.go` (v0.9.22).
//
// The Go tests call unexported parts of the task manager directly:
// `settleCanceledSubgraphs`, `receiveWithListening`, the fields of
// `taskManager`. The Dart `TaskManager` keeps their ports private
// (`_settleCanceledSubGraphs`, `_receive`), so every test reaches them the way
// a run does: through `submit` and `wait`, with a `GraphCancelSignal` that was
// triggered beforehand. Go's results of `receiveWithListening` map to what
// `wait` returns:
//
// * `canceled`          -> `wait().canceled`
// * `immediateCanceled` -> the task is among `wait().canceledTasks`
// * the returned task   -> `wait().tasks`
// * `deadline != nil`   -> `GraphCancelSignal.hasTimeout`
//
// `wait` has two paths (a step at a time, and eager); the tests of
// `receiveWithListening` run on both.
//
// Go sleeps on the wall clock. Here a task is held by a `Completer`, and the
// grace period of an interrupt runs on a fake clock.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/src/compose/checkpoint.dart';
import 'package:threepio_core/src/compose/composable_runnable.dart';
import 'package:threepio_core/src/compose/graph_interrupt.dart';
import 'package:threepio_core/src/compose/graph_runner.dart';
import 'package:threepio_core/src/compose/interrupt.dart';
import 'package:threepio_core/src/compose/stream_conversion.dart';
import 'package:threepio_core/src/compose/task_manager.dart';

typedef _Waited = ({
  List<GraphTask> tasks,
  bool canceled,
  List<GraphTask> canceledTasks,
});

/// Go `triggeredGraphCancel`.
///
/// The time an interrupt gives is counted from the trigger on a clock. Under
/// `fakeAsync` that has to be the fake one, or the real time the test takes
/// would shorten it.
GraphCancelSignal _triggeredGraphCancel(Duration? timeout, [FakeAsync? async]) =>
    GraphCancelSignal(now: async == null ? null : () => async.elapsed)
      ..trigger(timeout);

/// A runnable that gives what [run] completes with. Go: `&composableRunnable{}`.
ComposableRunnable _runnable([Future<Object?> Function()? run]) =>
    ComposableRunnable(
      invoke: (ctx, input, options) async => run?.call(),
      transform: (ctx, input, options) async =>
          throw UnsupportedError('the tests run on values'),
    );

/// Go `&task{nodeKey: key, …}`: the task of a node that runs [action].
GraphTask _task(
  String key,
  ComposableRunnable action, {
  ComposableRunnable? preProcessor,
  Completer<SubGraphInterrupt>? subGraphCheckpointReady,
}) =>
    GraphTask(
      ctx: RunContext.background(),
      nodeKey: key,
      call: ChanCall(
        writeTo: const [],
        controls: const [],
        writeToBranches: const [],
        action: action,
        preProcessor: preProcessor,
      ),
      input: null,
      subGraphCheckpointReady: subGraphCheckpointReady,
    );

TaskManager _manager(
  GraphCancelSignal cancel, {
  required bool needAll,
  RunnableCall runWrapper = runnableInvoke,
}) =>
    TaskManager(
      runWrapper: runWrapper,
      options: const [],
      needAll: needAll,
      cancel: cancel,
    );

/// Go `&subGraphInterruptError{CheckPoint: &checkpoint{}}`.
SubGraphInterrupt _subGraphInterrupt() => SubGraphInterrupt(
      info: GraphInterruptInfo(),
      checkpoint: GraphCheckpoint(),
      signal: AddressedInterruptSignal(id: '', address: const Address.empty()),
    );

/// [error] and the causes behind it. Go's `errors.Is` looks through them.
Iterable<Object> _chain(Object? error) sync* {
  var current = error;
  while (current != null) {
    yield current;
    current = current is ThreepioException ? current.cause : null;
  }
}

void main() {
  test('TestGraphCancelBroadcast', () {
    fakeAsync((async) {
      const timeout = Duration(milliseconds: 100);
      final cancel = _triggeredGraphCancel(timeout, async);

      // Go: three listeners in a row find `cancel.done` closed.
      final observed = <({bool triggered, bool hasTimeout})>[];
      for (var i = 0; i < 3; i++) {
        cancel.triggered.then(
          (_) => observed.add(
            (triggered: cancel.isTriggered, hasTimeout: cancel.hasTimeout),
          ),
        );
      }
      async.flushMicrotasks();
      expect(
        observed,
        List.filled(3, (triggered: true, hasTimeout: true)),
        reason: 'every listener observes the graph cancellation',
      );

      // Go reads the timeout and the deadline back with `request()`. The Dart
      // signal does not hand them out: they show in the moment the grace
      // period ends for a run that listens.
      cancel.attach();
      async.elapse(timeout - const Duration(milliseconds: 1));
      expect(cancel.isExpired, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(cancel.isExpired, isTrue);
      cancel.detach();
    });
  });

  test('TestTaskManagerSettleCanceledSubgraphUsesPublishedCheckpoint',
      () async {
    final ready = Completer<SubGraphInterrupt>();
    final published = _subGraphInterrupt();
    ready.complete(published);

    // Go: `finished` is an open channel. The task itself has not ended.
    final hold = Completer<void>();
    addTearDown(() {
      if (!hold.isCompleted) hold.complete();
    });
    final subGraphTask = _task(
      'subgraph',
      _runnable(() => hold.future),
      subGraphCheckpointReady: ready,
    );
    // Go calls `settleCanceledSubgraphs` on a manager whose `runningTasks`
    // holds the task. Here the task is submitted and the wait is cut short by
    // an interrupt without grace, which is what leads a run there.
    final manager =
        _manager(_triggeredGraphCancel(Duration.zero), needAll: true);
    await manager.submit([subGraphTask]);

    final waited = await manager.wait();

    expect(waited.tasks, hasLength(1));
    expect(waited.tasks.single.error, same(published));
    expect(waited.canceledTasks, isEmpty);

    hold.complete();
    await pumpEventQueue();
  });

  test('TestAttack_SubGraphCheckpointPublisherIsOneHop', () async {
    // Go `withSubGraphCheckpointPublisher(nil)`: the option a graph adds to
    // the options of a nested graph, and the channel the checkpoint arrives
    // in (see `GraphRunner._newTask`).
    final ready = Completer<SubGraphInterrupt>();
    final rawOptions = <Object?>[
      CallOption.subGraphCheckpointPublisher(ready.complete),
    ];
    final options = convertOptions<CallOption>(rawOptions);

    // Go `getSubGraphCheckpointPublisher(opts...)`.
    void Function(SubGraphInterrupt interrupt)? publish;
    for (final option in options) {
      publish ??= option.subGraphCheckpointPublisher;
    }
    expect(publish, isNotNull);
    final want = _subGraphInterrupt();
    publish!(want);
    expect(await ready.future, same(want));

    // A nested graph: its option type is `null`.
    final nodes = {
      'nested': ChanCall(
        writeTo: const [],
        controls: const [],
        writeToBranches: const [],
        action: _runnable(),
      ),
    };
    expect(nodes['nested']!.action!.optionType, isNull);
    final forwarded = extractOptions(nodes, options);
    expect(
      forwarded,
      isEmpty,
      reason: 'the parent publisher must not propagate into a grandchild '
          'graph',
    );
  });

  test('TestTaskManagerPreHandlerFailureClosesFinished', () async {
    final wantErr = Exception('pre-handler failed');
    final preProcessor = _runnable();
    final failedTask = _task(
      'subgraph',
      _runnable(),
      preProcessor: preProcessor,
      // Go: an unbuffered channel nobody sends to.
      subGraphCheckpointReady: Completer<SubGraphInterrupt>(),
    );
    final manager = _manager(
      // Needed to reach `settleCanceledSubgraphs` below; Go calls it directly.
      _triggeredGraphCancel(Duration.zero),
      needAll: true,
      runWrapper: (ctx, runnable, input, options) async {
        if (identical(runnable, preProcessor)) throw wantErr;
        return null;
      },
    );

    await manager.submit([failedTask]);
    expect(
      failedTask.finished.isCompleted,
      isTrue,
      reason: 'pre-handler failure did not mark task as finished',
    );

    final waited = await manager.wait();
    expect(waited.tasks, hasLength(1));
    expect(_chain(waited.tasks.single.error), contains(same(wantErr)));
    expect(waited.canceledTasks, isEmpty);
  });

  // The four tests of Go's `receiveWithListening`, on both paths of `wait`.
  for (final needAll in [true, false]) {
    final mode = needAll ? 'a step at a time' : 'eager';

    // Covers https://github.com/cloudwego/eino/issues/1148: an interrupt
    // without grace must win against a task that ends a moment later (its end
    // may be an effect of the interrupt), so that the task is run again on
    // resume instead of being taken for a normal completion.
    test(
        'TestReceiveWithListening_ZeroTimeout_WinsAgainstDelayedTaskCompletion '
        '($mode)', () async {
      for (var i = 0; i < 200; i++) {
        final recvReleased = Completer<void>();
        final task = _task('n', _runnable(() => recvReleased.future));
        final manager =
            _manager(_triggeredGraphCancel(Duration.zero), needAll: needAll);
        await manager.submit([task]);

        // Go: the receive is released a microsecond later.
        Timer(const Duration(microseconds: 1), recvReleased.complete);

        final waited = await manager.wait();

        expect(waited.canceled, isTrue, reason: 'iteration $i');
        expect(
          waited.canceledTasks,
          [same(task)],
          reason: 'iteration $i: zero-timeout cancel must win against a '
              'slightly-delayed task completion',
        );
        expect(
          waited.tasks,
          isEmpty,
          reason: 'iteration $i: task result must be discarded (rerun on '
              'resume), not treated as a normal completion',
        );
        await task.finished.future;
      }
    });

    // The same with a task that had ended before the manager looked: Go
    // re-checks the cancel signal after it received a task
    // (`receiveWithListening`, the inner `select`), and a pending interrupt
    // without grace still wins.
    test(
        'TestReceiveWithListening_ZeroTimeout_WinsAgainstDelayedTaskCompletion '
        '($mode, the task ended first)', () async {
      final task = _task('n', _runnable());
      final manager =
          _manager(_triggeredGraphCancel(Duration.zero), needAll: needAll);
      await manager.submit([task]);
      await task.finished.future;

      final waited = await manager.wait();

      expect(waited.canceled, isTrue);
      expect(waited.canceledTasks, [same(task)]);
      expect(waited.tasks, isEmpty);
    });

    // An interrupt without a timeout (unlimited grace) waits for the task and
    // returns its real result.
    test('TestReceiveWithListening_UnlimitedGrace_UsesRealTaskResult ($mode)',
        () async {
      final recvReleased = Completer<void>();
      final want = _task('n', _runnable(() => recvReleased.future));
      final cancel = _triggeredGraphCancel(null);
      final manager = _manager(cancel, needAll: needAll);
      await manager.submit([want]);

      // Go: released after 20 ms. Here: after the manager has started to wait
      // and has seen the interrupt.
      var returned = false;
      final waiting = manager.wait().whenComplete(() => returned = true);
      await pumpEventQueue();
      expect(returned, isFalse, reason: 'the wait goes on until the task ends');
      recvReleased.complete();
      final waited = await waiting;

      expect(waited.canceled, isTrue);
      expect(waited.canceledTasks, isEmpty);
      expect(waited.tasks, [same(want)]);
      expect(cancel.hasTimeout, isFalse);
      expect(cancel.isExpired, isFalse);
    });

    // An interrupt with a grace period still uses the real result of a task
    // that ends within it.
    test(
        'TestReceiveWithListening_PositiveTimeout_TaskFinishesWithinGrace '
        '($mode)', () {
      fakeAsync((async) {
        final recvReleased = Completer<void>();
        final want = _task('n', _runnable(() => recvReleased.future));
        const timeout = Duration(milliseconds: 200);
        // `attach`: the grace period runs while a run listens to the signal.
        final cancel = _triggeredGraphCancel(timeout, async)..attach();
        final manager = _manager(cancel, needAll: needAll);

        _Waited? waited;
        manager
            .submit([want])
            .then((_) => manager.wait())
            .then((result) => waited = result);
        Timer(const Duration(milliseconds: 20), recvReleased.complete);

        async.elapse(const Duration(milliseconds: 19));
        expect(waited, isNull);
        async.elapse(const Duration(milliseconds: 1));

        expect(waited, isNotNull);
        expect(waited!.canceled, isTrue);
        expect(waited!.canceledTasks, isEmpty);
        expect(waited!.tasks, [same(want)]);
        expect(cancel.hasTimeout, isTrue);
        expect(cancel.isExpired, isFalse);
        cancel.detach();
      });
    });

    // An interrupt with a grace period turns into an immediate one (the task
    // is given up) when the period ends before the task does.
    test(
        'TestReceiveWithListening_PositiveTimeout_DeadlineExpiresFirst '
        '($mode)', () {
      fakeAsync((async) {
        final recvReleased = Completer<void>();
        final task = _task('n', _runnable(() => recvReleased.future));
        const timeout = Duration(milliseconds: 20);
        final cancel = _triggeredGraphCancel(timeout, async)..attach();
        final manager = _manager(cancel, needAll: needAll);

        _Waited? waited;
        manager
            .submit([task])
            .then((_) => manager.wait())
            .then((result) => waited = result);

        async.elapse(const Duration(milliseconds: 19));
        expect(waited, isNull);
        async.elapse(const Duration(milliseconds: 1));

        expect(waited, isNotNull);
        expect(waited!.canceled, isTrue);
        expect(waited!.canceledTasks, [same(task)]);
        expect(waited!.tasks, isEmpty);
        expect(cancel.hasTimeout, isTrue);

        // Go: `defer close(recvReleased)`.
        recvReleased.complete();
        async.flushMicrotasks();
        cancel.detach();
      });
    });
  }
}
