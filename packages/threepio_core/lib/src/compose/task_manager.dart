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
  /// A manager that runs nodes with [runWrapper].
  TaskManager({
    required this.runWrapper,
    required this.options,
    required this.needAll,
  });

  /// Runs a node on a value or on a stream.
  final RunnableCall runWrapper;

  /// The call options of the run.
  final List<CallOption> options;

  /// Whether [wait] returns all running tasks at once (a step at a time) or
  /// each task as it finishes (eager).
  final bool needAll;

  int _running = 0;
  final Queue<GraphTask> _done = Queue();
  Completer<void>? _waiter;

  void _finished(GraphTask task) {
    _done.add(task);
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
      try {
        await _runPreHandler(task);
        ready.add(task);
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
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
  /// next one.
  ///
  /// Port of eino `taskManager.wait`.
  Future<List<GraphTask>> wait() async {
    if (needAll) return waitAll();
    final task = await _waitOne();
    return [if (task != null) task];
  }

  /// Every running task, once all have finished.
  ///
  /// Port of eino `taskManager.waitAll`.
  Future<List<GraphTask>> waitAll() async {
    final result = <GraphTask>[];
    for (var task = await _waitOne(); task != null; task = await _waitOne()) {
      result.add(task);
    }
    return result;
  }

  Future<GraphTask?> _waitOne() async {
    if (_running == 0) return null;
    while (_done.isEmpty) {
      final waiter = _waiter = Completer<void>();
      await waiter.future;
    }
    _waiter = null;
    final task = _done.removeFirst();
    _running--;
    if (task.error == null) await _runPostHandler(task);
    return task;
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
