/// Running a compiled graph.
///
/// Port of eino `compose/graph_run.go`, without the parts that belong to
/// interrupts and checkpoints: those arrive with the checkpoint engine and
/// are marked where they attach.
@internal
library;

import 'package:meta/meta.dart';

import '../callbacks/component_callbacks.dart' as callbacks;
import '../components/model/cancel_token.dart';
import '../core/interrupt_signal.dart';
import '../core/run_context.dart';
import '../errors.dart';
import '../streaming/stream_reader.dart';
import 'call_options.dart';
import 'channel_manager.dart';
import 'composable_runnable.dart';
import 'errors.dart';
import 'graph.dart';
import 'graph_options.dart';
import 'node_path.dart';
import 'stream_conversion.dart';
import 'task_manager.dart';
import 'type_ref.dart';

/// The call options each node gets, by node key.
///
/// Port of eino `extractOption`. An option without a designation goes to
/// every node that takes options of its type, and as it is to every nested
/// graph; a designated option goes to its node, or, with the first key taken
/// off its path, to the nested graph the path leads through.
Map<String, List<Object?>> extractOptions(
  Map<String, ChanCall> nodes,
  List<CallOption> options,
) {
  final result = <String, List<Object?>>{};
  List<Object?> of(String key) => result[key] ??= [];

  for (final option in options) {
    final componentOptions = option.componentOptions;
    if (option.paths.isEmpty) {
      if (componentOptions.isEmpty) continue;
      for (final MapEntry(key: name, value: call) in nodes.entries) {
        final optionType = call.action!.optionType;
        if (optionType == null) {
          of(name).add(option);
        } else if (option.isFor(optionType)) {
          of(name).addAll(componentOptions);
        }
      }
    }

    for (final path in option.paths) {
      if (path.path.isEmpty) {
        throw GraphRunException('call option has designated an empty path');
      }
      final key = path.path.first;
      final node = nodes[key];
      if (node == null) {
        throw GraphRunException(
          'option has designated an unknown node: $path',
        );
      }
      final optionType = node.action!.optionType;

      if (path.path.length == 1) {
        if (componentOptions.isEmpty) continue;
        if (optionType == null) {
          of(key).add(option.withPaths(const []));
        } else {
          if (!option.isFor(optionType)) {
            throw GraphRunException(
              'option type[${option.optionTypeName}] is different from which '
              'the designated node$path expects[${optionType.name}]',
            );
          }
          of(key).addAll(componentOptions);
        }
      } else {
        if (optionType != null) {
          throw GraphRunException(
            'cannot designate sub path of a component, path:$path',
          );
        }
        of(key).add(option.withPaths([NodePath(path.path.skip(1))]));
      }
    }
  }
  return result;
}

/// The copies of [item] for [n] receivers: a stream is copied, a value is
/// shared.
///
/// Port of eino `copyItem`.
List<Object?> copyItem(Object? item, int n) {
  if (n < 2) return [item];
  if (item is StreamReader<Object?>) return item.copy(n);
  return List<Object?>.filled(n, item);
}

String _text(Object error) =>
    error is ThreepioException ? error.message : error.toString();

/// A compiled graph: its nodes, how they are connected, and the loop that
/// runs them.
///
/// Port of eino `runner`.
final class GraphRunner {
  /// The runner of the given nodes.
  GraphRunner({
    required this.chanSubscribeTo,
    required this.successors,
    required this.dataPredecessors,
    required this.controlPredecessors,
    required this.inputChannels,
    required this.channelBuilder,
    required this.eager,
    required this.dag,
    required this.helper,
    required this.edgeHandlers,
    required this.preNodeHandlers,
    required this.preBranchHandlers,
    required this.mergeConfigs,
    required this.maxRunSteps,
    this.runContext,
  });

  /// The nodes by key.
  final Map<String, ChanCall> chanSubscribeTo;

  /// The nodes that follow each node.
  final Map<String, List<String>> successors;

  /// For each node, the nodes whose output it gets.
  final Map<String, List<String>> dataPredecessors;

  /// For each node, the nodes it waits for.
  final Map<String, List<String>> controlPredecessors;

  /// Where the input of the graph goes.
  final ChanCall inputChannels;

  /// Builds the channel of a node: step-wise or DAG.
  final ChannelBuilder channelBuilder;

  /// Whether a node starts as soon as it can, without waiting for the other
  /// nodes of its step.
  final bool eager;

  /// Whether the graph runs as a directed acyclic graph.
  final bool dag;

  /// The type-dependent operations for the input and output of the graph.
  final GenericHelper helper;

  /// The conversions on edges.
  final EdgeHandlerManager edgeHandlers;

  /// The conversions in front of nodes.
  final PreNodeHandlerManager preNodeHandlers;

  /// The conversions in front of branches.
  final PreBranchHandlerManager preBranchHandlers;

  /// How the inputs of nodes with several predecessors are merged.
  final Map<String, FanInMergeConfig> mergeConfigs;

  /// The step limit of a step-wise run; 0 for a DAG.
  final int maxRunSteps;

  /// Prepares the context of a run: gives the graph its state.
  final RunContext Function(RunContext ctx)? runContext;

  /// This runner as something a graph, or a caller, can run.
  ///
  /// Port of eino `runner.toComposableRunnable`. The option type is `null`: a
  /// graph takes the call options as they are.
  ComposableRunnable toComposableRunnable() => ComposableRunnable(
        invoke: (ctx, input, options) async => run(
          ctx,
          input,
          convertOptions<CallOption>(options),
          isStream: false,
        ),
        transform: (ctx, input, options) async => await run(
          ctx,
          input,
          convertOptions<CallOption>(options),
          isStream: true,
        ) as StreamReader<Object?>,
        inputType: helper.input,
        outputType: helper.output,
        helper: helper,
      );

  /// Runs the graph on [input], a value or (with [isStream]) a stream.
  ///
  /// Port of eino `runner.run`.
  Future<Object?> run(
    RunContext context,
    Object? input,
    List<CallOption> options, {
    required bool isStream,
  }) async {
    var ctx = context;
    var graphInput = input;
    // The start callback fires when the state of the run exists, so that a
    // handler can reach it.
    var started = false;
    Future<void> start() async {
      started = true;
      if (isStream) {
        final (next, rest) = await callbacks.onStartWithStreamInput<Object?>(
          ctx,
          graphInput! as StreamReader<Object?>,
        );
        ctx = next;
        graphInput = rest;
      } else {
        ctx = await callbacks.onStart(ctx, graphInput);
      }
    }

    final Object? result;
    try {
      final channels = _initChannelManager(isStream);
      final tasks = TaskManager(
        runWrapper: isStream ? runnableTransform : runnableInvoke,
        options: options,
        needAll: !eager,
      );
      final maxSteps = _resolveMaxSteps(options);

      final Map<String, List<Object?>> optionMap;
      try {
        optionMap = extractOptions(chanSubscribeTo, options);
      } on GraphRunException catch (error) {
        throw GraphRunException(
          'graph extract option fail: ${error.message}',
          cause: error,
        );
      }

      // Checkpoints attach here: a checkpoint id, a checkpoint handed down by
      // the graph around this one, and the restore of channels, state and
      // tasks from it.
      if (options.any((option) => option.checkpointId != null)) {
        throw GraphRunException(
          'receive checkpoint id but have not set checkpoint store',
        );
      }

      final prepare = runContext;
      if (prepare != null) ctx = prepare(ctx);
      await start();

      var next = await _calculateNextTasks(
        ctx,
        [
          GraphTask(
            ctx: ctx,
            nodeKey: Graph.start,
            call: inputChannels,
            input: null,
            output: graphInput,
          ),
        ],
        channels,
        optionMap,
        isStream: isStream,
        failure: 'calculate next tasks fail',
      );
      if (!next.isEnd && next.tasks.isEmpty) {
        throw GraphRunException('no tasks to execute after graph start');
      }

      var lastCompleted = const <GraphTask>[];
      for (var step = 0; !next.isEnd; step++) {
        if (ctx.cancelToken.isCancelled) {
          await tasks.waitAll();
          throw GraphRunException(
            'context has been canceled',
            cause: CancelledException(ctx.cancelToken.reason),
          );
        }
        if (!dag && step >= maxSteps) {
          throw GraphRunException(
            'exceeds max steps',
            cause: const ExceedMaxStepsException(),
          );
        }

        await tasks.submit(next.tasks);
        final completed = await tasks.wait();

        // Interrupts attach here: an interrupted node or nested graph makes
        // the run wait for the other tasks and write a checkpoint. As in
        // Eino, an ordinary failure of the same step comes first.
        GraphTask? interrupted;
        for (final task in completed) {
          final error = task.error;
          if (error == null) continue;
          if (isInterrupt(error)) {
            interrupted ??= task;
            continue;
          }
          Error.throwWithStackTrace(
            wrapGraphNodeError(task.nodeKey, error),
            task.stackTrace ?? StackTrace.current,
          );
        }
        if (interrupted != null) {
          Error.throwWithStackTrace(
            interrupted.error!,
            interrupted.stackTrace ?? StackTrace.current,
          );
        }

        if (completed.isEmpty) {
          throw GraphRunException(
            'no tasks to execute, last completed nodes: '
            '[${lastCompleted.map((task) => task.nodeKey).join(', ')}]',
          );
        }
        lastCompleted = completed;

        next = await _calculateNextTasks(
          ctx,
          completed,
          channels,
          optionMap,
          isStream: isStream,
          failure: 'failed to calculate next tasks',
        );
      }
      result = next.result;
      // Reported to the callbacks of the graph and thrown on.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      if (!started) await start();
      await callbacks.onError(ctx, error, stackTrace);
      rethrow;
    }

    if (isStream) {
      final (_, output) = await callbacks.onEndWithStreamOutput<Object?>(
        ctx,
        result! as StreamReader<Object?>,
      );
      return output;
    }
    await callbacks.onEnd(ctx, result);
    return result;
  }

  int _resolveMaxSteps(List<CallOption> options) {
    if (dag) {
      if (options.any((option) => option.maxRunSteps > 0)) {
        throw GraphRunException('cannot set max run steps in dag');
      }
      return maxRunSteps;
    }
    var maxSteps = maxRunSteps;
    for (final option in options) {
      if (option.maxRunSteps > 0) maxSteps = option.maxRunSteps;
    }
    if (maxSteps < 1) {
      throw GraphRunException('max run steps limit must be at least 1');
    }
    return maxSteps;
  }

  ChannelManager _initChannelManager(bool isStream) {
    final channels = <String, Channel>{
      for (final MapEntry(key: name, value: call) in chanSubscribeTo.entries)
        name: channelBuilder(
          controlDependencies: controlPredecessors[name] ?? const [],
          dataDependencies: dataPredecessors[name] ?? const [],
          zeroValue: _zeroValueOf(call.action!),
          emptyStream: _zeroStreamOf(call.action!),
          inputType: call.action!.inputType,
        ),
      Graph.end: channelBuilder(
        controlDependencies: controlPredecessors[Graph.end] ?? const [],
        dataDependencies: dataPredecessors[Graph.end] ?? const [],
        zeroValue: helper.output.zeroValue,
        emptyStream: helper.output.zeroStream,
        inputType: helper.output,
      ),
    };
    for (final MapEntry(key: name, value: config) in mergeConfigs.entries) {
      channels[name]?.mergeConfig = config;
    }

    return ChannelManager(
      isStream: isStream,
      channels: channels,
      successors: successors,
      dataPredecessors: {
        for (final MapEntry(:key, :value) in dataPredecessors.entries)
          key: value.toSet(),
      },
      controlPredecessors: {
        for (final MapEntry(:key, :value) in controlPredecessors.entries)
          key: value.toSet(),
      },
      edgeHandlers: edgeHandlers,
      preNodeHandlers: preNodeHandlers,
    );
  }

  static Object? Function() _zeroValueOf(ComposableRunnable action) =>
      action.helper?.input.zeroValue ?? () => null;

  static StreamReader<Object?> Function() _zeroStreamOf(
    ComposableRunnable action,
  ) =>
      action.helper?.input.zeroStream ??
      () => StreamReader<Object?>.fromIterable(const [null]);

  /// Port of eino `runner.calculateNextTasks`.
  Future<({List<GraphTask> tasks, Object? result, bool isEnd})>
      _calculateNextTasks(
    RunContext ctx,
    List<GraphTask> completed,
    ChannelManager channels,
    Map<String, List<Object?>> optionMap, {
    required bool isStream,
    required String failure,
  }) async {
    try {
      final (values, dependencies) = await _resolveCompletedTasks(
        ctx,
        completed,
        channels,
        isStream: isStream,
      );
      final Map<String, Object?> ready;
      try {
        ready = await channels.updateAndGet(values, dependencies);
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        if (isInterrupt(error)) rethrow;
        Error.throwWithStackTrace(
          GraphRunException(
            'failed to update and get channels: ${_text(error)}',
            cause: error,
          ),
          stackTrace,
        );
      }

      if (ready.containsKey(Graph.end)) {
        return (
          tasks: const <GraphTask>[],
          result: ready[Graph.end],
          isEnd: true,
        );
      }
      return (
        tasks: _createTasks(ctx, ready, optionMap),
        result: null,
        isEnd: false,
      );
      // Whatever goes wrong between two steps is a failure of the run.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      if (isInterrupt(error)) rethrow;
      Error.throwWithStackTrace(
        GraphRunException('$failure: ${_text(error)}', cause: error),
        stackTrace,
      );
    }
  }

  /// Port of eino `runner.createTasks`.
  List<GraphTask> _createTasks(
    RunContext ctx,
    Map<String, Object?> ready,
    Map<String, List<Object?>> optionMap,
  ) =>
      [
        for (final MapEntry(key: nodeKey, value: input) in ready.entries)
          GraphTask(
            // The address of the node and the checkpoint of a nested graph
            // are added to the context here.
            ctx: ctx,
            nodeKey: nodeKey,
            call: chanSubscribeTo[nodeKey] ??
                (throw GraphRunException(
                  'failed to create tasks: node[$nodeKey] has not been '
                  'registered',
                )),
            input: input,
            options: optionMap[nodeKey] ?? const [],
          ),
      ];

  /// What the finished tasks give to which node, and which nodes they
  /// release.
  ///
  /// Port of eino `runner.resolveCompletedTasks`.
  Future<(Map<String, Map<String, Object?>>, Map<String, List<String>>)>
      _resolveCompletedTasks(
    RunContext ctx,
    List<GraphTask> completed,
    ChannelManager channels, {
    required bool isStream,
  }) async {
    final values = <String, Map<String, Object?>>{};
    final dependencies = <String, List<String>>{};

    for (final task in completed) {
      final call = task.call;
      for (final key in call.controls) {
        (dependencies[key] ??= []).add(task.nodeKey);
      }

      final direct = call.writeTo.length;
      final branches = call.writeToBranches.length;
      // One copy for every node the output is written to, one for the nodes
      // each branch chooses, one for each branch condition to look at.
      var copies = copyItem(task.output, direct + branches * 2);

      final List<String> chosen;
      try {
        chosen = await _calculateBranch(
          ctx,
          task.nodeKey,
          call,
          copies.sublist(direct + branches),
          channels,
          isStream: isStream,
        );
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        if (isInterrupt(error)) rethrow;
        Error.throwWithStackTrace(
          GraphRunException(
            'calculate next step fail, node: ${task.nodeKey}, '
            'error: ${_text(error)}',
            cause: error,
          ),
          stackTrace,
        );
      }

      for (final key in chosen) {
        (dependencies[key] ??= []).add(task.nodeKey);
      }
      final nextKeys = [...chosen, ...call.writeTo];
      if (nextKeys.isEmpty) {
        await _closeUnused(copies.take(direct + branches));
        continue;
      }

      // A branch that chooses several nodes needs a copy for each of them.
      final extra = nextKeys.length - direct - branches;
      copies = [
        ...copies.take(direct + branches - 1),
        ...copyItem(copies[direct + branches - 1], extra + 1),
      ];
      for (final (index, next) in nextKeys.indexed) {
        final ofNext = values[next] ??= {};
        // Two branches may choose the same node, or a branch a node that an
        // edge leads to as well: it gets the output once.
        if (ofNext.containsKey(task.nodeKey)) {
          await _closeUnused([ofNext[task.nodeKey]]);
        }
        ofNext[task.nodeKey] = copies[index];
      }
      await _closeUnused(copies.skip(nextKeys.length));
    }
    return (values, dependencies);
  }

  /// Closes the copies of an output stream that no node will read, so that
  /// they do not hold back the chunks the other copies have read.
  static Future<void> _closeUnused(Iterable<Object?> copies) async {
    for (final copy in copies) {
      if (copy is StreamReader<Object?>) await copy.close();
    }
  }

  /// The nodes the branches of [call] choose for the output of [nodeKey].
  ///
  /// Port of eino `runner.calculateBranch`.
  Future<List<String>> _calculateBranch(
    RunContext ctx,
    String nodeKey,
    ChanCall call,
    List<Object?> inputs,
    ChannelManager channels, {
    required bool isStream,
  }) async {
    final chosen = <String>[];
    final skipped = <String>{};

    for (final (index, branch) in call.writeToBranches.indexed) {
      final Object? input;
      try {
        input = preBranchHandlers.handle(
          nodeKey,
          index,
          inputs[index],
          isStream: isStream,
        );
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        if (isInterrupt(error)) rethrow;
        Error.throwWithStackTrace(
          GraphRunException(
            'branch[$nodeKey]-[${branch.index}] pre handler fail: '
            '${_text(error)}',
            cause: error,
          ),
          stackTrace,
        );
      }

      final List<String> ends;
      try {
        ends = isStream
            ? await branch.collect(ctx, input! as StreamReader<Object?>)
            : await branch.invoke(ctx, input);
        // Whatever a condition throws fails the run.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        if (isInterrupt(error)) rethrow;
        Error.throwWithStackTrace(
          GraphRunException(
            'branch ${isStream ? 'collect' : 'invoke'} run error: '
            '${_text(error)}',
            cause: error,
          ),
          stackTrace,
        );
      }

      skipped.addAll(branch.endNodes.where((node) => !ends.contains(node)));
      chosen.addAll(ends);
    }

    // A node that one branch of the node leaves out and another one chooses
    // is not skipped.
    skipped.removeAll(chosen);
    channels.reportBranch(nodeKey, skipped.toList());
    return chosen;
  }
}
