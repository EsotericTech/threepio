/// Running the nodes of one step of a graph side by side.
///
/// Port of the task half of eino `compose/graph_manager.go`.
@internal
library;

import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import '../callbacks/callback_context.dart';
import '../callbacks/component_callback_handler.dart';
import '../callbacks/run_info.dart';
import '../core/interrupt_signal.dart';
import '../core/run_context.dart';
import '../errors.dart';
import '../streaming/stream_reader.dart';
import 'call_options.dart';
import 'composable_runnable.dart';
import 'graph_branch.dart';
import 'graph_interrupt.dart';
import 'interrupt.dart';

/// A node as the runner sees it: what to run and where its output goes.
///
/// Port of eino `chanCall`.
final class ChanCall {
  /// The call of a node. [action] is `null` only for the start of the graph.
  ChanCall({
    required this.writeTo,
    required this.controls,
    required this.writeToBranches,
    this.action,
    this.preProcessor,
    this.postProcessor,
  });

  /// What the node runs.
  final ComposableRunnable? action;

  /// The nodes that get the output.
  final List<String> writeTo;

  /// The branches that start at the node.
  final List<GraphBranch> writeToBranches;

  /// The nodes that wait for this node.
  final List<String> controls;

  /// The state handler in front of the node.
  final ComposableRunnable? preProcessor;

  /// The state handler behind the node.
  final ComposableRunnable? postProcessor;

  /// Whether the node is a nested graph, chain or workflow.
  ///
  /// Port of eino `isSubGraphCall`.
  bool get isSubGraph {
    final component = action?.meta?.component;
    return component == ComponentType.graph ||
        component == ComponentType.chain ||
        component == ComponentType.workflow;
  }

  /// Whether a run that goes on from a checkpoint can start the node without
  /// the input it had: the input type has an empty value (see
  /// `TypeRef.zeroValue`).
  bool get hasEmptyInput => action?.helper?.input.hasZeroValue ?? true;
}

/// One run of one node.
///
/// Port of eino `task`.
final class GraphTask {
  /// The task of running [call] as the node [nodeKey] on [input].
  GraphTask({
    required this.ctx,
    required this.nodeKey,
    required this.call,
    required this.input,
    this.options = const [],
    this.skipPreHandler = false,
    this.syntheticRerunInput = false,
    this.subGraphCheckpointReady,
    this.output,
  });

  /// The context of the node.
  final RunContext ctx;

  /// The key of the node.
  final String nodeKey;

  /// What to run.
  final ChanCall call;

  /// The input, replaced by what the state handler in front of the node
  /// returns.
  Object? input;

  /// The input as the node was handed it, before its state handler, kept for
  /// the case that the node has to run again from a checkpoint. A copy when
  /// the input is a stream.
  Object? originalInput;

  /// The output, once the task has finished without an error.
  Object? output;

  /// The call options of the node.
  final List<Object?> options;

  /// What the node, or one of its state handlers, threw.
  Object? error;

  /// Where [error] was thrown.
  StackTrace? stackTrace;

  /// Whether the state handler in front of the node has run already (on a
  /// resumed run).
  final bool skipPreHandler;

  /// Whether [input] is the empty value a resumed run made up because the
  /// checkpoint had no input for the node.
  final bool syntheticRerunInput;

  /// For a nested graph: completes with the interrupt of that graph as soon
  /// as it has its checkpoint ready, which may be before its task has
  /// finished.
  final Completer<SubGraphInterrupt>? subGraphCheckpointReady;

  /// Completes when the task has ended, with or without an error.
  final Completer<void> finished = Completer<void>();

  /// Records that the task failed.
  void fail(Object error, StackTrace stackTrace) {
    output = null;
    this.error = error;
    this.stackTrace = stackTrace;
  }
}

/// Runs [runnable] on a value or on a stream, depending on the run.
///
/// Port of eino `runnableCallWrapper`.
typedef RunnableCall = Future<Object?> Function(
  RunContext ctx,
  ComposableRunnable runnable,
  Object? input,
  List<Object?> options,
);

/// Port of eino `runnableInvoke`.
Future<Object?> runnableInvoke(
  RunContext ctx,
  ComposableRunnable runnable,
  Object? input,
  List<Object?> options,
) =>
    runnable.invoke(ctx, input, options);

/// Port of eino `runnableTransform`.
Future<Object?> runnableTransform(
  RunContext ctx,
  ComposableRunnable runnable,
  Object? input,
  List<Object?> options,
) =>
    runnable.transform(ctx, input! as StreamReader<Object?>, options);

/// The context a node runs its callbacks with: the handlers of the run, the
/// handlers aimed at this node, and the node's run info.
///
/// Port of eino `initNodeCallbacks`.
RunContext initNodeCallbacks(
  RunContext ctx,
  String key,
  NodeInfo? info,
  ExecutorMeta? meta,
  List<CallOption> options,
) {
  final runInfo = RunInfo(
    name: info?.name ?? '',
    type: meta?.componentImplType ?? '',
    componentType: meta?.component ?? ComponentType.custom,
  );
  final handlers = <ComponentCallbackHandler>[
    for (final option in options)
      if (option.handlers.isNotEmpty &&
          option.paths
              .any((path) => path.path.length == 1 && path.path.first == key))
        ...option.handlers,
  ];
  return handlers.isEmpty
      ? reuseHandlers(ctx, runInfo)
      : appendHandlers(ctx, runInfo, handlers);
}

/// The context a graph runs its callbacks with: the handlers of the context
/// plus the handlers of the call that are aimed at no node.
///
/// Port of eino `initGraphCallbacks`.
RunContext initGraphCallbacks(
  RunContext ctx,
  NodeInfo? info,
  ExecutorMeta? meta,
  List<CallOption> options,
) {
  final runInfo = RunInfo(
    name: info?.name ?? '',
    type: meta?.componentImplType ?? '',
    componentType: meta?.component ?? ComponentType.custom,
  );
  final handlers = <ComponentCallbackHandler>[
    for (final option in options)
      if (option.handlers.isNotEmpty && option.paths.isEmpty)
        ...option.handlers,
  ];
  return handlers.isEmpty
      ? reuseHandlers(ctx, runInfo)
      : appendHandlers(ctx, runInfo, handlers);
}

/// Starts tasks and hands them back as they finish.
///
/// Port of eino `taskManager`. Go runs every task on a goroutine; here a task
/// is a future, and tasks interleave wherever they wait.
final class TaskManager {
  /// A manager that runs nodes with [runWrapper]. With [cancel], the run can
  /// be interrupted from outside while tasks are running.
  TaskManager({
    required this.runWrapper,
    required this.options,
    required this.needAll,
    this.cancel,
  }) {
    // The signal may live longer than this run: it calls back until
    // [dispose].
    cancel?.addWaker(_wake);
  }

  /// Lets go of the interrupt signal. Called when the run has ended.
  void dispose() => cancel?.removeWaker(_wake);

  /// Runs a node on a value or on a stream.
  final RunnableCall runWrapper;

  /// The call options of the run.
  final List<CallOption> options;

  /// Whether [wait] returns all running tasks at once (a step at a time) or
  /// each task as it finishes (eager).
  final bool needAll;

  /// The request to interrupt the run from outside, when the run listens to
  /// one.
  final GraphCancelSignal? cancel;

  int _running = 0;
  final Queue<GraphTask> _done = Queue();
  final Map<String, GraphTask> _runningTasks = {};
  Completer<void>? _waiter;

  /// Whether a wait has seen the request to interrupt.
  bool _canceled = false;

  void _finished(GraphTask task) {
    if (!task.finished.isCompleted) task.finished.complete();
    _done.add(task);
    _wake();
  }

  /// Makes a wait look again: a task finished, or the interrupt changed.
  void _wake() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<void> _execute(GraphTask task) async {
    final action = task.call.action!;
    try {
      // The run checks for cancellation between steps; a node that only
      // starts later (after a state handler, or in an eager run) checks
      // again.
      task.ctx.cancelToken.throwIfCancelled();
      final ctx = initNodeCallbacks(
        task.ctx,
        task.nodeKey,
        action.nodeInfo,
        action.meta,
        options,
      );
      task.output = await runWrapper(ctx, action, task.input, task.options);
      // Whatever a node throws is the result of its task.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      task.fail(error, stackTrace);
    }
    _finished(task);
  }

  /// Runs the state handlers in front of [tasks] and starts the tasks.
  ///
  /// Port of eino `taskManager.submit`.
  Future<void> submit(List<GraphTask> tasks) async {
    final ready = <GraphTask>[];
    for (final task in tasks) {
      // A run that can be interrupted from outside keeps every input, because
      // any node may be cut off. Otherwise an input is kept only where a node
      // could not be started again without it: Go starts such a node with the
      // zero value of its input type, and Dart has none for most classes.
      // (A nested graph goes on from its own checkpoint and needs none.)
      final needsInput = cancel != null ||
          (!task.call.hasEmptyInput && !task.call.isSubGraph);
      if (needsInput && !task.syntheticRerunInput) {
        final input = task.input;
        if (input is StreamReader<Object?>) {
          final copies = input.copy(2);
          // The copy that is kept is read only when the node has to run
          // again. Where nobody closes it (a run that fails for another
          // reason, a task that was given up), it is let go with the task.
          copies[0].setAutomaticClose();
          task
            ..originalInput = copies[0]
            ..input = copies[1];
        } else {
          task.originalInput = input;
        }
      }

      _runningTasks[task.nodeKey] = task;
      try {
        await _runPreHandler(task);
        ready.add(task);
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        // A failed state handler is the failure of its node.
        task.fail(error, stackTrace);
        _running++;
        _finished(task);
      }
    }
    for (final task in ready) {
      _running++;
      unawaited(_execute(task));
    }
  }

  /// The tasks that finished: all running ones when [needAll], otherwise the
  /// next one. `canceled` says that the run was asked to interrupt;
  /// `canceledTasks` are the tasks that were still running when the time they
  /// were given ended.
  ///
  /// Port of eino `taskManager.wait`.
  Future<({List<GraphTask> tasks, bool canceled, List<GraphTask> canceledTasks})>
      wait() async {
    if (needAll) {
      final all = await waitAll();
      return (
        tasks: all.tasks,
        canceled: _canceled,
        canceledTasks: all.canceledTasks,
      );
    }

    final one = await _waitOne();
    if (one.canceled) {
      // A nested graph hears the same request and makes a checkpoint of its
      // own. That is waited for before this graph takes stock.
      final settled = await _settleCanceledSubGraphs();
      return (
        tasks: settled.tasks,
        canceled: true,
        canceledTasks: settled.canceledTasks,
      );
    }
    final task = one.task;
    if (_canceled) {
      // Asked to interrupt, with time left: the other tasks are waited for.
      final all = await waitAll();
      return (
        tasks: [...all.tasks, if (task != null) task],
        canceled: true,
        canceledTasks: all.canceledTasks,
      );
    }
    return (
      tasks: [if (task != null) task],
      canceled: false,
      canceledTasks: const <GraphTask>[],
    );
  }

  /// Every running task, once all have finished or the time an interrupt
  /// gave them has ended.
  ///
  /// Port of eino `taskManager.waitAll`.
  Future<({List<GraphTask> tasks, List<GraphTask> canceledTasks})>
      waitAll() async {
    final result = <GraphTask>[];
    while (true) {
      final one = await _waitOne();
      if (one.canceled) {
        final settled = await _settleCanceledSubGraphs();
        return (
          tasks: [...result, ...settled.tasks],
          canceledTasks: settled.canceledTasks,
        );
      }
      final task = one.task;
      if (task == null) {
        return (tasks: result, canceledTasks: const <GraphTask>[]);
      }
      result.add(task);
    }
  }

  /// The next finished task, or `canceled` when the wait was cut short by an
  /// interrupt. Neither when nothing is running.
  Future<({GraphTask? task, bool canceled})> _waitOne() async {
    if (_running == 0) return (task: null, canceled: false);
    final task = await _receive();
    if (task == null) return (task: null, canceled: true);
    _running--;
    _runningTasks.remove(task.nodeKey);
    await _finishTask(task);
    return (task: task, canceled: false);
  }

  /// Waits for the next finished task. Returns `null` when an interrupt from
  /// outside ends the wait.
  ///
  /// Port of eino `taskManager.receive`, `receiveWithListening` and
  /// `receiveWithDeadline`.
  Future<GraphTask?> _receive() async {
    final cancel = this.cancel;
    while (true) {
      if (cancel != null && cancel.isTriggered) {
        _canceled = true;
        // No time left: the interrupt wins, also over a task that finished
        // in the same moment (its end may be an effect of the interrupt).
        if (cancel.isExpired) return null;
      }
      if (_done.isNotEmpty) return _done.removeFirst();

      final waiter = _waiter = Completer<void>();
      await waiter.future;
      _waiter = null;
    }
  }

  /// Port of eino `taskManager.finishTask`.
  Future<void> _finishTask(GraphTask task) async {
    final error = task.error;
    if (task.originalInput != null && (error == null || !isInterrupt(error))) {
      final original = task.originalInput;
      if (original is StreamReader<Object?>) await original.close();
      task.originalInput = null;
    }
    if (error == null) await _runPostHandler(task);
  }

  /// After an interrupt that did not wait: what became of the running tasks.
  /// A nested graph is waited for until it hands over its checkpoint or
  /// ends; every other task is given up.
  ///
  /// Port of eino `taskManager.settleCanceledSubgraphs`.
  Future<({List<GraphTask> tasks, List<GraphTask> canceledTasks})>
      _settleCanceledSubGraphs() async {
    final completed = <GraphTask>[];
    final canceled = <GraphTask>[];
    for (final running in _runningTasks.values.toList()) {
      final ready = running.subGraphCheckpointReady;
      if (ready == null) {
        canceled.add(running);
        continue;
      }
      await Future.any<void>([ready.future, running.finished.future]);
      // Its result was taken here, not from the queue of finished tasks.
      _done.remove(running);
      var task = running;
      if (ready.isCompleted && !running.finished.isCompleted) {
        task = GraphTask(
          ctx: running.ctx,
          nodeKey: running.nodeKey,
          call: running.call,
          input: running.input,
          options: running.options,
          skipPreHandler: running.skipPreHandler,
          syntheticRerunInput: running.syntheticRerunInput,
          subGraphCheckpointReady: ready,
        )
          ..originalInput = running.originalInput
          ..error = await ready.future;
      }
      await _finishTask(task);
      completed.add(task);
    }
    _runningTasks.clear();
    _running = 0;
    return (tasks: completed, canceledTasks: canceled);
  }

  Future<void> _runPreHandler(GraphTask task) async {
    final preProcessor = task.call.preProcessor;
    if (preProcessor == null || task.skipPreHandler) return;
    try {
      task.input =
          await runWrapper(task.ctx, preProcessor, task.input, task.options);
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      if (isInterrupt(error)) rethrow;
      Error.throwWithStackTrace(
        _HandlerFailure(
          'run node[${task.nodeKey}] pre processor fail: ${_text(error)}',
          error,
        ),
        stackTrace,
      );
    }
  }

  Future<void> _runPostHandler(GraphTask task) async {
    final postProcessor = task.call.postProcessor;
    if (postProcessor == null) return;
    try {
      task.output =
          await runWrapper(task.ctx, postProcessor, task.output, task.options);
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      if (isInterrupt(error)) {
        task.fail(error, stackTrace);
        return;
      }
      task.fail(
        _HandlerFailure(
          'run node[${task.nodeKey}] post processor fail: ${_text(error)}',
          error,
        ),
        stackTrace,
      );
    }
  }
}

String _text(Object error) =>
    error is ThreepioException ? error.message : error.toString();

/// A state handler failed. The cause is what it threw.
final class _HandlerFailure extends ThreepioException {
  const _HandlerFailure(super.message, Object cause) : super(cause: cause);

  @override
  String toString() => message;
}
