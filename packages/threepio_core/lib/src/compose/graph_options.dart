/// The options a node is added with and the options a graph is compiled with.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../core/run_context.dart';
import 'checkpoint_store.dart';
import 'introspect.dart';
import 'local_state.dart';

/// When a node of a graph runs.
///
/// Port of eino `compose.NodeTriggerMode`.
enum NodeTriggerMode {
  /// A node runs when any of its predecessors has finished. The graph runs in
  /// steps (Pregel) and may have cycles. This is the default of a graph.
  anyPredecessor,

  /// A node runs when all of its predecessors have finished. The graph is a
  /// directed acyclic graph and has no step limit.
  allPredecessor,
}

/// How the streams that arrive at a node with several predecessors are
/// merged.
///
/// Port of eino `compose.FanInMergeConfig`.
@immutable
final class FanInMergeConfig {
  /// The merge settings of one node.
  const FanInMergeConfig({this.streamMergeWithSourceEof = false});

  /// Whether the merged stream reports the end of each incoming stream with a
  /// `SourceEOFException` that carries the key of the node it came from.
  final bool streamMergeWithSourceEof;
}

/// Hears about a graph that has been compiled.
///
/// Port of eino `compose.GraphCompileCallback`.
// One member is the whole contract, as in Eino.
// ignore: one_member_abstracts
abstract interface class GraphCompileCallback {
  /// Called once when `compile` has succeeded, with the structure of the
  /// graph.
  FutureOr<void> onFinish(RunContext ctx, GraphInfo info);
}

/// The compile callbacks every graph reports to.
///
/// Port of eino `compose.InitGraphCompileCallbacks`. This is process-wide
/// state; tests that use it call [clearGlobal] when they are done.
abstract final class GraphCompileCallbacks {
  static final List<GraphCompileCallback> _global = [];

  /// The callbacks registered with [appendGlobal].
  static List<GraphCompileCallback> get global => List.unmodifiable(_global);

  /// Makes every graph that is compiled from now on report to [callbacks], in
  /// front of the callbacks of its own compile options.
  static void appendGlobal(Iterable<GraphCompileCallback> callbacks) =>
      _global.addAll(callbacks);

  /// Forgets the global callbacks.
  static void clearGlobal() => _global.clear();
}

/// The options a graph, chain or workflow is compiled with.
///
/// Port of eino `compose.GraphCompileOption`.
@immutable
final class GraphCompileOptions {
  /// The compile options.
  const GraphCompileOptions({
    this.maxRunSteps,
    this.graphName = '',
    this.nodeTriggerMode,
    this.compileCallbacks = const [],
    this.fanInMergeConfig = const {},
    this.eagerExecutionDisabled = false,
    this.checkpointStore,
    this.serializer,
    this.interruptBeforeNodes = const [],
    this.interruptAfterNodes = const [],
  });

  /// The most steps a run may take before it fails. Port of eino
  /// `compose.WithMaxRunSteps`.
  ///
  /// Only for a graph that runs in Pregel mode, where cycles are allowed.
  /// Defaults to the number of nodes plus ten.
  final int? maxRunSteps;

  /// The name of the graph, which its callbacks report. Port of eino
  /// `compose.WithGraphName`.
  final String graphName;

  /// When nodes run. Port of eino `compose.WithNodeTriggerMode`. A chain does
  /// not take this option.
  final NodeTriggerMode? nodeTriggerMode;

  /// Told about the compiled graph. Port of eino
  /// `compose.WithGraphCompileCallbacks`.
  final List<GraphCompileCallback> compileCallbacks;

  /// By node key, how the streams arriving at a node with several
  /// predecessors are merged. Port of eino `compose.WithFanInMergeConfig`.
  final Map<String, FanInMergeConfig> fanInMergeConfig;

  /// Makes a graph in [NodeTriggerMode.allPredecessor] mode wait for all the
  /// nodes that run side by side before it starts their successors, instead
  /// of starting each successor as soon as it can run. Port of eino
  /// `compose.WithEagerExecutionDisabled`.
  final bool eagerExecutionDisabled;

  /// Where checkpoints of interrupted runs are stored. Port of eino
  /// `compose.WithCheckPointStore`.
  final CheckpointStore? checkpointStore;

  /// How checkpoints become bytes. Port of eino `compose.WithSerializer`.
  final CheckpointSerializer? serializer;

  /// The nodes a run is interrupted in front of. Port of eino
  /// `compose.WithInterruptBeforeNodes`.
  final List<String> interruptBeforeNodes;

  /// The nodes a run is interrupted behind. Port of eino
  /// `compose.WithInterruptAfterNodes`.
  final List<String> interruptAfterNodes;

  /// These options with the given fields replaced.
  GraphCompileOptions copyWith({
    int? maxRunSteps,
    String? graphName,
    NodeTriggerMode? nodeTriggerMode,
    List<GraphCompileCallback>? compileCallbacks,
    Map<String, FanInMergeConfig>? fanInMergeConfig,
    bool? eagerExecutionDisabled,
    CheckpointStore? checkpointStore,
    CheckpointSerializer? serializer,
    List<String>? interruptBeforeNodes,
    List<String>? interruptAfterNodes,
  }) =>
      GraphCompileOptions(
        maxRunSteps: maxRunSteps ?? this.maxRunSteps,
        graphName: graphName ?? this.graphName,
        nodeTriggerMode: nodeTriggerMode ?? this.nodeTriggerMode,
        compileCallbacks: compileCallbacks ?? this.compileCallbacks,
        fanInMergeConfig: fanInMergeConfig ?? this.fanInMergeConfig,
        eagerExecutionDisabled:
            eagerExecutionDisabled ?? this.eagerExecutionDisabled,
        checkpointStore: checkpointStore ?? this.checkpointStore,
        serializer: serializer ?? this.serializer,
        interruptBeforeNodes: interruptBeforeNodes ?? this.interruptBeforeNodes,
        interruptAfterNodes: interruptAfterNodes ?? this.interruptAfterNodes,
      );
}

/// The options a node is added to a graph with.
///
/// Port of eino `compose.GraphAddNodeOpt`.
@immutable
final class NodeOptions {
  /// The options of a node.
  const NodeOptions({
    this.name,
    this.key,
    this.inputKey,
    this.outputKey,
    this.statePreHandler,
    this.statePostHandler,
    this.streamStatePreHandler,
    this.streamStatePostHandler,
    this.compileOptions,
  });

  /// The display name of the node, which its callbacks report. Port of eino
  /// `compose.WithNodeName`.
  final String? name;

  /// The key of the node. Only a chain takes it, where nodes otherwise get
  /// keys by their position; a graph is given the key with the node. Port of
  /// eino `compose.WithNodeKey`.
  final String? key;

  /// Makes the node take the value under this key of the map its predecessor
  /// gives. Port of eino `compose.WithInputKey`.
  final String? inputKey;

  /// Makes the node give a map with its output under this key. Port of eino
  /// `compose.WithOutputKey`.
  final String? outputKey;

  /// Runs before the node with the state of the graph; made with
  /// [StateHandler.pre]. Port of eino `compose.WithStatePreHandler`.
  final StateHandler? statePreHandler;

  /// Runs after the node with the state of the graph; made with
  /// [StateHandler.post]. Port of eino `compose.WithStatePostHandler`.
  final StateHandler? statePostHandler;

  /// Like [statePreHandler] for a handler that takes a stream; made with
  /// [StateHandler.streamPre]. A node has one handler in front of it: give
  /// this or [statePreHandler]. Port of eino
  /// `compose.WithStreamStatePreHandler`.
  final StateHandler? streamStatePreHandler;

  /// Like [statePostHandler] for a handler that takes a stream; made with
  /// [StateHandler.streamPost]. Give this or [statePostHandler]. Port of eino
  /// `compose.WithStreamStatePostHandler`.
  final StateHandler? streamStatePostHandler;

  /// For a node that is itself a graph, the options it is compiled with. Port
  /// of eino `compose.WithGraphCompileOptions`.
  final GraphCompileOptions? compileOptions;

  /// These options with the given fields replaced.
  NodeOptions copyWith({
    String? name,
    String? key,
    String? inputKey,
    String? outputKey,
    StateHandler? statePreHandler,
    StateHandler? statePostHandler,
    StateHandler? streamStatePreHandler,
    StateHandler? streamStatePostHandler,
    GraphCompileOptions? compileOptions,
  }) =>
      NodeOptions(
        name: name ?? this.name,
        key: key ?? this.key,
        inputKey: inputKey ?? this.inputKey,
        outputKey: outputKey ?? this.outputKey,
        statePreHandler: statePreHandler ?? this.statePreHandler,
        statePostHandler: statePostHandler ?? this.statePostHandler,
        streamStatePreHandler:
            streamStatePreHandler ?? this.streamStatePreHandler,
        streamStatePostHandler:
            streamStatePostHandler ?? this.streamStatePostHandler,
        compileOptions: compileOptions ?? this.compileOptions,
      );
}
