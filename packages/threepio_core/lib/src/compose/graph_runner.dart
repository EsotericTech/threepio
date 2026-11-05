/// Running a compiled graph.
///
/// Port of eino `compose/graph_run.go`.
@internal
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../callbacks/component_callbacks.dart' as callbacks;
import '../components/model/cancel_token.dart';
import '../core/interrupt_signal.dart';
import '../core/run_context.dart';
import '../errors.dart';
import '../streaming/stream_reader.dart';
import 'address.dart';
import 'call_options.dart';
import 'channel_manager.dart';
import 'checkpoint.dart';
import 'checkpoint_serializer.dart';
import 'composable_runnable.dart';
import 'errors.dart';
import 'graph.dart';
import 'graph_interrupt.dart';
import 'graph_options.dart';
import 'interrupt.dart';
import 'local_state.dart';
import 'node_path.dart';
import 'resume.dart';
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
        // What only concerns the graph it was given to (the checkpoint
        // options) is not handed on.
        if (option.isRunOnly) continue;
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
    CheckPointer? checkPointer,
    this.interruptBeforeNodes = const [],
    this.interruptAfterNodes = const [],
    this.fieldMappedNodes = const {},
    this.runContext,
  }) : checkPointer = checkPointer ??
            CheckPointer(inputTypes: const {}, outputTypes: const {});

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

  /// Reads and writes the checkpoints of this graph.
  final CheckPointer checkPointer;

  /// The nodes a run is interrupted in front of.
  final List<String> interruptBeforeNodes;

  /// The nodes a run is interrupted behind.
  final List<String> interruptAfterNodes;

  /// The nodes (and possibly the end) whose input is assembled from mapped
  /// fields: what arrives in their channels are maps of fields.
  final Set<String> fieldMappedNodes;

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
    final run = _Run(this, context, input, options, isStream: isStream);
    final cancel = graphCancelOf(context);
    cancel?.attach();
    final Object? result;
    try {
      result = await run.execute(cancel);
      // Reported to the callbacks of the graph and thrown on. An interrupt is
      // reported like a failure, as in Eino.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      if (!run.started) await run.start();
      await callbacks.onError(run.ctx, error, stackTrace);
      rethrow;
    } finally {
      cancel?.detach();
    }

    if (isStream) {
      final (_, output) = await callbacks.onEndWithStreamOutput<Object?>(
        run.ctx,
        result! as StreamReader<Object?>,
      );
      return output;
    }
    await callbacks.onEnd(run.ctx, result);
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
        name: _channelOf(name, call.action!.helper?.input, call.action!.inputType),
      Graph.end: _channelOf(Graph.end, helper.output, helper.output),
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

  /// The channel in front of the node [name] (or of the end), which takes
  /// [type].
  Channel _channelOf(
    String name,
    TypeRef<Object?>? type,
    TypeRef<Object?>? inputType,
  ) {
    // What arrives at a node whose input is assembled from fields are maps of
    // fields, whatever the node takes; "nothing arrived" is the empty map.
    final mapped = fieldMappedNodes.contains(name);
    return channelBuilder(
      controlDependencies: controlPredecessors[name] ?? const [],
      dataDependencies: dataPredecessors[name] ?? const [],
      zeroValue: mapped
          ? () => <String, Object?>{}
          : type?.zeroValue ?? () => null,
      emptyStream: mapped
          ? () => StreamReader<Map<String, Object?>>.fromIterable([{}])
          : type?.zeroStream ??
              () => StreamReader<Object?>.fromIterable(const [null]),
      inputType: mapped ? mapType : inputType,
    );
  }

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
          _newTask(ctx, nodeKey, input, optionMap),
      ];

  /// The task of running the node [nodeKey] on [input]: at its own address,
  /// with the checkpoint of the node when it is a nested graph that goes on
  /// from one.
  GraphTask _newTask(
    RunContext ctx,
    String nodeKey,
    Object? input,
    Map<String, List<Object?>> optionMap, {
    bool skipPreHandler = false,
    bool syntheticRerunInput = false,
  }) {
    final call = chanSubscribeTo[nodeKey];
    if (call == null) {
      throw GraphRunException('node[$nodeKey] has not been registered');
    }
    var options = optionMap[nodeKey] ?? const <Object?>[];
    Completer<SubGraphInterrupt>? ready;
    if (call.isSubGraph) {
      // A nested graph tells this one as soon as it has a checkpoint, so that
      // an interrupt from outside can collect it without waiting for the
      // task.
      final handOver = ready = Completer<SubGraphInterrupt>();
      options = [
        ...options,
        CallOption.subGraphCheckpointPublisher((interrupt) {
          if (!handOver.isCompleted) handOver.complete(interrupt);
        }),
      ];
    }
    return GraphTask(
      ctx: appendAddressSegmentTo(
        forwardCheckpoint(ctx, nodeKey),
        AddressSegmentType.node,
        nodeKey,
      ),
      nodeKey: nodeKey,
      call: call,
      input: input,
      options: options,
      skipPreHandler: skipPreHandler,
      syntheticRerunInput: syntheticRerunInput,
      subGraphCheckpointReady: ready,
    );
  }

  /// The tasks a run that goes on from [checkpoint] starts with.
  ///
  /// Port of eino `runner.restoreTasks`.
  List<GraphTask> _restoreTasks(
    RunContext ctx,
    GraphCheckpoint checkpoint,
    Map<String, List<Object?>> optionMap, {
    required bool isStream,
  }) {
    final inputs = checkpoint.inputs;
    final synthetic = <String>{};
    for (final key in checkpoint.rerunNodes) {
      if (inputs.containsKey(key)) continue;
      final call = chanSubscribeTo[key];
      if (call == null) {
        throw GraphRunException(
          'channel[$key] from checkpoint is not registered',
        );
      }
      inputs[key] = _emptyInputOf(key, call, isStream: isStream);
      synthetic.add(key);
    }
    return [
      for (final MapEntry(:key, value: input) in inputs.entries)
        if (!chanSubscribeTo.containsKey(key))
          throw GraphRunException(
            'channel[$key] from checkpoint is not registered',
          )
        else
          _newTask(
            ctx,
            key,
            input,
            optionMap,
            skipPreHandler: checkpoint.skipPreHandler[key] ?? false,
            syntheticRerunInput: synthetic.contains(key),
          ),
    ];
  }

  /// The input of a node that runs again although the checkpoint kept none
  /// for it: the empty value of its input type.
  static Object? _emptyInputOf(
    String key,
    ChanCall call, {
    required bool isStream,
  }) {
    final type = call.action?.helper?.input;
    if (type == null) {
      return isStream ? StreamReader<Object?>.fromIterable(const [null]) : null;
    }
    if (type.hasZeroValue) return isStream ? type.zeroStream() : type.zeroValue();
    // A nested graph goes on from its own checkpoint and does not look at
    // its input.
    if (call.isSubGraph) return isStream ? type.emptyStream() : null;
    throw GraphRunException(
      'node[$key] has to run again, but the checkpoint has no input for it '
      'and its input type ${type.name} has no empty value',
    );
  }

  /// Port of eino `runner.validateCheckpointIntegrity`.
  void _validateCheckpoint(GraphCheckpoint checkpoint) {
    for (final key in checkpoint.rerunNodes) {
      final call = chanSubscribeTo[key];
      if (call == null || !call.isSubGraph) continue;
      if (checkpoint.subGraphs.containsKey(key)) continue;
      if (checkpoint.inputs.containsKey(key)) continue;
      throw GraphRunException(
        'invalid checkpoint: subgraph node "$key" is marked for rerun without '
        'a nested checkpoint or persisted input',
      );
    }
  }

  /// Which of [tasks] are for nodes listed in [keys].
  static List<String> _hitKeys(List<GraphTask> tasks, List<String> keys) => [
        for (final task in tasks)
          if (keys.contains(task.nodeKey)) task.nodeKey,
      ];

  /// The node of this graph that has to run again for an interrupt raised at
  /// [address], which the task of [task] ended with.
  ///
  /// Port of eino `runner.interruptOriginNodeKey`. A node can meet an
  /// interrupt while it reads the stream an earlier node produced: the node
  /// to run again is then the earlier one.
  String _interruptOriginNodeKey(GraphTask task, Address address) {
    final taskAddress = task.ctx.currentAddress.segments;
    if (taskAddress.isEmpty ||
        taskAddress.last.type != AddressSegmentType.node) {
      return task.nodeKey;
    }
    final graphLength = taskAddress.length - 1;
    if (address.length <= graphLength) return task.nodeKey;
    for (var i = 0; i < graphLength; i++) {
      if (address.segments[i] != taskAddress[i]) return task.nodeKey;
    }
    final segment = address.segments[graphLength];
    if (segment.type == AddressSegmentType.node &&
        chanSubscribeTo.containsKey(segment.id)) {
      return segment.id;
    }
    return task.nodeKey;
  }

  /// Sorts the errors of [completed] tasks into [info]: interrupts of nested
  /// graphs, interrupts of nodes. Any other error fails the run.
  ///
  /// Port of eino `runner.resolveInterruptCompletedTasks`.
  void _resolveInterruptCompletedTasks(
    InterruptTempInfo info,
    List<GraphTask> completed,
  ) {
    GraphTask? passedOn;
    for (final task in completed) {
      final error = task.error;
      if (error == null) {
        if (interruptAfterNodes.contains(task.nodeKey)) {
          info.interruptAfterNodes.add(task.nodeKey);
        }
        continue;
      }

      final nested = ThreepioException.findCause<SubGraphInterrupt>(error);
      if (nested != null) {
        info.subGraphInterrupts[task.nodeKey] = nested;
        info.appendSignal(nested.signal);
        continue;
      }

      final signal =
          ThreepioException.findCause<AddressedInterruptSignal>(error);
      if (signal != null) {
        info.interruptTaskNodes.add(task.nodeKey);
        final rerunKey = _interruptOriginNodeKey(task, signal.address);
        info.addRerunNode(rerunKey);
        if (signal.info != null) info.interruptRerunExtra[rerunKey] = signal.info;
        info.appendSignal(signal);
        continue;
      }

      if (isInterrupt(error)) {
        // An interrupt the engine cannot checkpoint: one of another kind, or
        // the interrupt of a graph that a node ran and did not wrap with
        // `compositeInterrupt`. It leaves the run as it is, unless a node
        // failed in the same step.
        passedOn ??= task;
        continue;
      }
      Error.throwWithStackTrace(
        wrapGraphNodeError(task.nodeKey, error),
        task.stackTrace ?? StackTrace.current,
      );
    }
    final raw = passedOn;
    if (raw != null) {
      Error.throwWithStackTrace(raw.error!, raw.stackTrace ?? StackTrace.current);
    }
  }

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

/// One run of a [GraphRunner]: the context as it grows, and the steps.
final class _Run {
  _Run(
    this.runner,
    this.ctx,
    this.graphInput,
    this.options, {
    required this.isStream,
  });

  final GraphRunner runner;
  final List<CallOption> options;
  final bool isStream;

  /// The context of the run: the caller's, then with the state of the graph
  /// and what a checkpoint adds, then as the start callback returned it.
  RunContext ctx;

  /// The input, as the start callback left it.
  Object? graphInput;

  /// Whether the start callback has fired. It fires when the state of the
  /// run exists, so that a handler can reach it.
  bool started = false;

  late final ChannelManager _channels;
  late final Map<String, List<Object?>> _optionMap;
  String? _writeToCheckpointId;
  void Function(SubGraphInterrupt interrupt)? _publisher;
  bool _isSubGraph = false;

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

  /// Starts a run that goes on from a checkpoint: nothing reads its input.
  Future<void> _startResumed() async {
    await start();
    final unread = graphInput;
    if (unread is StreamReader<Object?>) await unread.close();
  }

  Future<Object?> execute(GraphCancelSignal? cancel) async {
    final tasks = TaskManager(
      runWrapper: isStream ? runnableTransform : runnableInvoke,
      options: options,
      needAll: !runner.eager,
      cancel: cancel,
    );
    try {
      return await _execute(tasks);
    } finally {
      tasks.dispose();
    }
  }

  Future<Object?> _execute(TaskManager tasks) async {
    final channels = _channels = runner._initChannelManager(isStream);
    final maxSteps = runner._resolveMaxSteps(options);

    try {
      _optionMap = extractOptions(runner.chanSubscribeTo, options);
    } on GraphRunException catch (error) {
      throw GraphRunException(
        'graph extract option fail: ${error.message}',
        cause: error,
      );
    }

    String? checkpointId;
    StateModifier? stateModifier;
    for (final option in options) {
      checkpointId = option.checkpointId ?? checkpointId;
      _writeToCheckpointId = option.writeToCheckpointId ?? _writeToCheckpointId;
      stateModifier = option.stateModifier ?? stateModifier;
      _publisher ??= option.subGraphCheckpointPublisher;
    }
    _writeToCheckpointId ??= checkpointId;
    final forceNewRun = options.any((option) => option.forceNewRun);
    if (checkpointId != null && runner.checkPointer.store == null) {
      throw GraphRunException(
        'receive checkpoint id but have not set checkpoint store',
      );
    }

    final (path, isSubGraph) = nodePathOf(ctx);
    _isSubGraph = isSubGraph;

    // A graph goes on from the checkpoint the graph around it handed down,
    // or from the one its own store has under the checkpoint id; otherwise
    // it starts.
    var nextTasks = const <GraphTask>[];
    var initialized = false;
    final handedDown = checkpointOf(ctx);
    if (handedDown != null) {
      initialized = true;
      nextTasks = await _resume(handedDown, path, stateModifierOf(ctx));
    } else if (checkpointId != null && !forceNewRun) {
      final GraphCheckpoint? stored;
      try {
        stored = await runner.checkPointer.get(checkpointId);
        // Whatever the store or the serializer throws.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        Error.throwWithStackTrace(
          GraphRunException(
            'load checkpoint from store fail: ${_text(error)}',
            cause: error,
          ),
          stackTrace,
        );
      }
      if (stored != null) {
        initialized = true;
        ctx = withCheckpoint(withStateModifier(ctx, stateModifier), stored);
        nextTasks = await _resume(stored, NodePath(const []), stateModifier);
      }
    }

    if (!initialized) {
      final prepare = runner.runContext;
      if (prepare != null) ctx = prepare(ctx);
      await start();

      final next = await runner._calculateNextTasks(
        ctx,
        [
          GraphTask(
            ctx: ctx,
            nodeKey: Graph.start,
            call: runner.inputChannels,
            input: null,
            output: graphInput,
          ),
        ],
        channels,
        _optionMap,
        isStream: isStream,
        failure: 'calculate next tasks fail',
      );
      if (next.isEnd) return next.result;
      if (next.tasks.isEmpty) {
        throw GraphRunException('no tasks to execute after graph start');
      }
      nextTasks = next.tasks;

      final hit =
          GraphRunner._hitKeys(nextTasks, runner.interruptBeforeNodes);
      if (hit.isNotEmpty) {
        final info = InterruptTempInfo()..interruptBeforeNodes.addAll(hit);
        throw await _interrupt(info, nextTasks);
      }
    }

    var lastCompleted = const <GraphTask>[];
    for (var step = 0;; step++) {
      if (ctx.cancelToken.isCancelled) {
        await tasks.waitAll();
        throw GraphRunException(
          'context has been canceled',
          cause: CancelledException(ctx.cancelToken.reason),
        );
      }
      if (!runner.dag && step >= maxSteps) {
        throw GraphRunException(
          'exceeds max steps',
          cause: const ExceedMaxStepsException(),
        );
      }

      await tasks.submit(nextTasks);

      final waited = await tasks.wait();
      final completed = waited.tasks;
      final canceledTasks = [...waited.canceledTasks];
      final info = InterruptTempInfo();
      if (waited.canceled) {
        // Interrupted from outside. The nodes that were cut off run again;
        // when all of them had finished, the run stops behind them.
        if (waited.canceledTasks.isNotEmpty) {
          for (final task in waited.canceledTasks) {
            info.addRerunNode(task.nodeKey);
          }
        } else {
          info.interruptAfterNodes
              .addAll(completed.map((task) => task.nodeKey));
        }
      }
      runner._resolveInterruptCompletedTasks(info, completed);

      if (info.subGraphInterrupts.isNotEmpty ||
          info.interruptRerunNodes.isNotEmpty) {
        // A node or a nested graph interrupted. What else is running is
        // waited for, what finished is passed on to the channels, and the
        // interrupted nodes are kept as the tasks to start with.
        final rest = await tasks.waitAll();
        canceledTasks.addAll(rest.canceledTasks);
        for (final task in rest.canceledTasks) {
          info.addRerunNode(task.nodeKey);
        }
        runner._resolveInterruptCompletedTasks(info, rest.tasks);
        throw await _interruptWithRerun(
          info,
          [...completed, ...rest.tasks, ...canceledTasks],
        );
      }

      if (completed.isEmpty) {
        throw GraphRunException(
          'no tasks to execute, last completed nodes: '
          '[${lastCompleted.map((task) => task.nodeKey).join(', ')}]',
        );
      }
      lastCompleted = completed;

      final next = await runner._calculateNextTasks(
        ctx,
        completed,
        channels,
        _optionMap,
        isStream: isStream,
        failure: 'failed to calculate next tasks',
      );
      if (next.isEnd) return next.result;
      nextTasks = next.tasks;

      info.interruptBeforeNodes
        ..clear()
        ..addAll(GraphRunner._hitKeys(nextTasks, runner.interruptBeforeNodes));
      if (info.interruptBeforeNodes.isEmpty &&
          info.interruptAfterNodes.isEmpty) {
        continue;
      }

      final rest = await tasks.waitAll();
      canceledTasks.addAll(rest.canceledTasks);
      for (final task in rest.canceledTasks) {
        info.addRerunNode(task.nodeKey);
      }
      runner._resolveInterruptCompletedTasks(info, rest.tasks);
      if (info.subGraphInterrupts.isNotEmpty ||
          info.interruptRerunNodes.isNotEmpty) {
        // The tasks of `completed` were passed on above, and the nodes they
        // lead to are waiting in `nextTasks`. Eino passes their outputs on a
        // second time here; a stream can be handed over only once, so the
        // waiting tasks are kept as they are.
        throw await _interruptWithRerun(
          info,
          [...rest.tasks, ...canceledTasks],
          pending: nextTasks,
        );
      }

      final more = await runner._calculateNextTasks(
        ctx,
        rest.tasks,
        channels,
        _optionMap,
        isStream: isStream,
        failure: 'failed to calculate next tasks',
      );
      if (more.isEnd) return more.result;
      info.interruptBeforeNodes.addAll(
        GraphRunner._hitKeys(more.tasks, runner.interruptBeforeNodes),
      );
      throw await _interrupt(info, [...nextTasks, ...more.tasks]);
    }
  }

  /// Makes the run go on from [checkpoint] and returns the tasks it starts
  /// with.
  Future<List<GraphTask>> _resume(
    GraphCheckpoint checkpoint,
    NodePath path,
    StateModifier? stateModifier,
  ) async {
    runner._validateCheckpoint(checkpoint);
    runner.checkPointer.revive(checkpoint);
    await _restoreState(checkpoint, path, stateModifier);
    await _startResumed();
    try {
      return runner._restoreTasks(
        ctx,
        checkpoint,
        _optionMap,
        isStream: isStream,
      );
    } on GraphRunException catch (error) {
      throw GraphRunException(
        'restore tasks fail: ${error.message}',
        cause: error,
      );
    }
  }

  /// Port of eino `runner.restoreCheckPointState`.
  Future<void> _restoreState(
    GraphCheckpoint checkpoint,
    NodePath path,
    StateModifier? stateModifier,
  ) async {
    try {
      runner.checkPointer.restoreCheckpoint(checkpoint, isStream: isStream);
    } on ThreepioException catch (error) {
      throw GraphRunException(
        'restore checkpoint fail: ${error.message}',
        cause: error,
      );
    }
    _channels.loadChannels(checkpoint.channels);

    final saved = checkpoint.state;
    if (saved == null) return;
    if (stateModifier != null) {
      try {
        await stateModifier(ctx, path, saved);
        // Whatever the caller's function throws.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        if (isInterrupt(error)) rethrow;
        Error.throwWithStackTrace(
          GraphRunException(
            'state modifier fail: ${_text(error)}',
            cause: error,
          ),
          stackTrace,
        );
      }
    }
    // The caller may resume the graph itself, with a state to go on with.
    final resumed = getResumeContext<Object>(ctx);
    if (resumed.isResumeTarget && resumed.hasData) {
      checkpoint.state = resumed.data;
    }
    ctx = withInternalState(ctx, checkpoint.state!);
  }

  /// A copy of the state of this graph, when it has one.
  Future<Object?> _copyState() async {
    if (runner.runContext == null) return null;
    final holder = internalStateOf(ctx);
    if (holder == null) return null;
    return holder.mutex.protect(() => deepCopyState(holder.state));
  }

  /// The interrupt of a run that stops in front of [nextTasks].
  ///
  /// Port of eino `runner.handleInterrupt`.
  Future<InterruptSignal> _interrupt(
    InterruptTempInfo info,
    List<GraphTask> nextTasks,
  ) async {
    final checkpoint = GraphCheckpoint(
      channels: _channels.channels,
      state: await _copyState(),
    );
    for (final task in nextTasks) {
      checkpoint.inputs[task.nodeKey] = task.input;
    }
    return _finishInterrupt(info, checkpoint, const {});
  }

  /// The interrupt of a run in which nodes or nested graphs interrupted (or
  /// were cut off): what finished is passed on, and they are kept to run
  /// again.
  ///
  /// Port of eino `runner.handleInterruptWithSubGraphAndRerunNodes`.
  Future<InterruptSignal> _interruptWithRerun(
    InterruptTempInfo info,
    List<GraphTask> tasks, {
    List<GraphTask> pending = const [],
  }) async {
    final rerunTasks = <GraphTask>[];
    final subGraphTasks = <GraphTask>[];
    final otherTasks = <GraphTask>[];
    // A nested graph has run the state handler in front of it; a node that
    // runs again runs it again.
    final skipPreHandler = <String, bool>{};
    for (final task in tasks) {
      final key = task.nodeKey;
      if (info.subGraphInterrupts.containsKey(key)) {
        subGraphTasks.add(task);
        skipPreHandler[key] = true;
      } else if (info.interruptRerunNodes.contains(key)) {
        rerunTasks.add(task);
      } else if (!info.interruptTaskNodes.contains(key)) {
        otherTasks.add(task);
      }
    }

    try {
      final (values, controls) = await runner._resolveCompletedTasks(
        ctx,
        otherTasks,
        _channels,
        isStream: isStream,
      );
      await _channels.updateValues(values);
      _channels.updateDependencies(controls);
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      if (isInterrupt(error)) rethrow;
      Error.throwWithStackTrace(
        GraphRunException(
          'failed to resolve completed tasks in interrupt: ${_text(error)}',
          cause: error,
        ),
        stackTrace,
      );
    }

    final checkpoint = GraphCheckpoint(
      channels: _channels.channels,
      skipPreHandler: skipPreHandler,
      state: await _copyState(),
    );
    final subGraphs = <String, GraphInterruptInfo>{};
    for (final task in subGraphTasks) {
      final nested = info.subGraphInterrupts[task.nodeKey]!;
      checkpoint.rerunNodes.add(task.nodeKey);
      checkpoint.subGraphs[task.nodeKey] = nested.checkpoint;
      subGraphs[task.nodeKey] = nested.info;
    }
    checkpoint.rerunNodes.addAll(info.interruptRerunNodes);
    for (final task in rerunTasks) {
      if (task.originalInput != null) {
        checkpoint.inputs[task.nodeKey] = task.originalInput;
      }
    }
    // The nodes that were about to start, start when the run goes on.
    for (final task in pending) {
      checkpoint.inputs[task.nodeKey] = task.input;
    }
    // An input that was kept and is not needed is let go.
    for (final task in tasks) {
      final kept = task.originalInput;
      if (kept is StreamReader<Object?> &&
          !identical(checkpoint.inputs[task.nodeKey], kept)) {
        await kept.close();
        task.originalInput = null;
      }
    }
    runner._validateCheckpoint(checkpoint);
    return _finishInterrupt(info, checkpoint, subGraphs);
  }

  /// Completes [checkpoint] with the interrupt points, stores it or hands it
  /// to the graph around this one, and returns what the run throws.
  Future<InterruptSignal> _finishInterrupt(
    InterruptTempInfo info,
    GraphCheckpoint checkpoint,
    Map<String, GraphInterruptInfo> subGraphs,
  ) async {
    // The point of the graph itself reports its state.
    final signal = newInterruptSignal(ctx, checkpoint.state, null, info.signals);
    final (addresses, states) = signalToPersistenceMaps(signal);
    checkpoint
      ..interruptId2Address = addresses
      ..interruptId2State = states;

    try {
      await runner.checkPointer
          .convertCheckpoint(checkpoint, signal, isStream: isStream);
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        GraphRunException(
          'failed to convert checkpoint: ${_text(error)}',
          cause: error,
        ),
        stackTrace,
      );
    }

    GraphInterruptInfo describe(List<InterruptCtx> contexts) =>
        GraphInterruptInfo(
          state: checkpoint.state,
          beforeNodes: info.interruptBeforeNodes,
          afterNodes: info.interruptAfterNodes,
          rerunNodes: info.interruptRerunNodes,
          rerunNodesExtra: info.interruptRerunExtra,
          subGraphs: subGraphs,
          interruptContexts: contexts,
        );

    if (_isSubGraph) {
      final interrupt = SubGraphInterrupt(
        info: describe(const []),
        checkpoint: checkpoint,
        signal: signal,
      );
      _publisher?.call(interrupt);
      return interrupt;
    }

    final id = _writeToCheckpointId;
    if (id != null) {
      try {
        await runner.checkPointer.set(id, checkpoint);
        // Whatever the store or the serializer throws.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        Error.throwWithStackTrace(
          GraphRunException(
            'failed to set checkpoint: ${_text(error)}, checkPointID: $id',
            cause: error,
          ),
          stackTrace,
        );
      }
    }
    return GraphInterruptedException(describe(toInterruptContexts(signal)));
  }
}
