/// Graphs: nodes connected by edges and branches, compiled into a runnable.
///
/// Port of eino `compose/graph.go` and `compose/generic_graph.go`.
library;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../callbacks/run_info.dart';
import '../components/document/loader.dart';
import '../components/document/transformer.dart';
import '../components/embedding/embedder.dart';
import '../components/indexer/indexer.dart';
import '../components/model/base_chat_model.dart';
import '../components/prompt/chat_template.dart';
import '../components/retriever/retriever.dart';
import '../core/run_context.dart';
import '../streaming/stream_reader.dart';
import 'address.dart';
import 'call_options.dart';
import 'channel_manager.dart';
import 'checkpoint.dart';
import 'checkpoint_serializer.dart';
import 'composable_runnable.dart';
import 'dag.dart';
import 'errors.dart';
import 'field_mapping.dart';
import 'graph_branch.dart';
import 'graph_node.dart';
import 'graph_options.dart';
import 'graph_runner.dart';
import 'introspect.dart';
import 'lambda.dart';
import 'local_state.dart';
import 'pregel.dart';
import 'resume.dart';
import 'runnable.dart';
import 'stream_conversion.dart';
import 'task_manager.dart';
import 'tools_node.dart';
import 'type_ref.dart';

final _log = Logger('threepio.compose');

/// A graph, a chain or a workflow: anything that can be a node of a graph.
///
/// Port of eino `compose.AnyGraph`. The implementations are the classes of
/// this package; the interface is not meant to be implemented elsewhere.
abstract interface class AnyGraph {
  /// The engine side of the graph. Not part of the public API.
  @internal
  GraphEngine get engine;
}

/// What the engine needs from an [AnyGraph].
@internal
abstract interface class GraphEngine {
  /// The type-dependent operations for input and output.
  GenericHelper get helper;

  /// The input type.
  TypeRef<Object?> get inputType;

  /// The output type.
  TypeRef<Object?> get outputType;

  /// Whether this is a graph, a chain or a workflow.
  ComponentType get component;

  /// Compiles the graph into what a node, or a caller, runs.
  Future<ComposableRunnable> compile(
    RunContext ctx,
    GraphCompileOptions? options,
  );

  /// The structure of the graph as it is now.
  GraphInfo describe();
}

final class _PendingEdge {
  const _PendingEdge(this.endNode, [this.mappings = const []]);
  final String endNode;
  final List<FieldMapping> mappings;
}

/// The untyped graph underneath [Graph], `Chain` and `Workflow`.
///
/// Port of eino `graph`.
@internal
final class GraphCore implements GraphEngine {
  /// An empty graph from [helper]'s input type to its output type.
  GraphCore({
    required this.helper,
    required this.component,
    this.localState,
  });

  @override
  final GenericHelper helper;

  @override
  final ComponentType component;

  /// The state the graph keeps per run.
  final LocalState? localState;

  /// The nodes by key, in the order they were added.
  final Map<String, GraphNode> nodes = {};

  /// For each node, the nodes that wait for it.
  final Map<String, List<String>> controlEdges = {};

  /// For each node, the nodes that get its output.
  final Map<String, List<String>> dataEdges = {};

  /// The branches by start node.
  final Map<String, List<GraphBranch>> branches = {};

  /// The nodes the start leads to.
  final List<String> startNodes = [];

  /// The nodes that lead to the end.
  final List<String> endNodes = [];

  /// The edges whose types could not be checked yet, because both ends are
  /// passthrough nodes that have no type of their own.
  final Map<String, List<_PendingEdge>> _toValidate = {};

  /// The conversions on edges that lead from a wider type to a narrower one.
  final Map<String, Map<String, List<HandlerPair>>> handlerOnEdges = {};

  /// The conversions in front of nodes.
  final Map<String, List<HandlerPair>> handlerPreNode = {};

  /// The conversions in front of branches.
  final Map<String, List<List<HandlerPair>>> handlerPreBranch = {};

  /// The field mappings that lead to each node, in the order they were
  /// added. A node that has some gets its input assembled from fields.
  final Map<String, List<FieldMapping>> fieldMappingRecords = {};

  /// The first error of building this graph. It is thrown again by every
  /// later change and by [compile].
  GraphBuildException? buildError;

  /// Whether the graph was compiled; it cannot be changed afterwards.
  bool compiled = false;

  GraphCompileOptions? _compiledWith;

  @override
  TypeRef<Object?> get inputType => helper.input;

  @override
  TypeRef<Object?> get outputType => helper.output;

  bool get _isChain => component == ComponentType.chain;
  bool get _isWorkflow => component == ComponentType.workflow;

  T _change<T>(T Function() body) {
    final failed = buildError;
    if (failed != null) throw failed;
    if (compiled) throw const GraphCompiledException();
    try {
      return body();
    } on GraphBuildException catch (error) {
      buildError = error;
      rethrow;
    }
  }

  /// Adds [node] under [key].
  ///
  /// Port of eino `graph.addNode`.
  void addNode(String key, GraphNode node) => _change(() {
        if (key == Graph.end || key == Graph.start) {
          throw GraphBuildException(
            "node '$key' is reserved, cannot add manually",
          );
        }
        if (nodes.containsKey(key)) {
          throw GraphBuildException("node '$key' already present");
        }
        final state = localState;
        if (node.needState && state == null) {
          throw GraphBuildException(
            "node '$key' needs state but graph state is not enabled",
          );
        }
        if ((node.options.key ?? '').isNotEmpty && !_isChain) {
          throw const GraphBuildException('only chain support node key option');
        }

        final pre = node.preHandler;
        if (pre != null) {
          _checkHandler(key, pre, state!, node.inputType, 'pre', 'input');
        }
        final post = node.postHandler;
        if (post != null) {
          _checkHandler(key, post, state!, node.outputType, 'post', 'output');
        }

        nodes[key] = node;
      });

  static void _checkHandler(
    String key,
    StateHandler handler,
    LocalState state,
    TypeRef<Object?>? nodeType,
    String side,
    String direction,
  ) {
    if (!state.stateType.isSubtypeOf(handler.stateType)) {
      throw GraphBuildException(
        "node[$key]'s $side handler state type[${handler.stateType.name}] is "
        'different from graph[${state.stateType.name}]',
      );
    }
    if (nodeType == null) {
      if (!handler.valueType.isTop) {
        throw GraphBuildException(
          "passthrough node[$key]'s $side handler type isn't any",
        );
      }
    } else if (!nodeType.isSameAs(handler.valueType)) {
      throw GraphBuildException(
        "node[$key]'s $side handler type[${handler.valueType.name}] is "
        'different from its $direction type[${nodeType.name}]',
      );
    }
  }

  /// Adds an edge from [startNode] to [endNode]. Without [noControl] the end
  /// node waits for the start node; without [noData] it gets its output.
  ///
  /// With [mappings] (workflows) the end node gets the mapped fields instead
  /// of the whole output.
  ///
  /// Port of eino `graph.addEdgeWithMappings`.
  void addEdge(
    String startNode,
    String endNode, {
    bool noControl = false,
    bool noData = false,
    List<FieldMapping> mappings = const [],
  }) =>
      _change(() {
        if (noControl && noData) {
          throw GraphBuildException(
            'edge[$startNode]-[$endNode] cannot be both noDirectDependency '
            'and noDataFlow',
          );
        }
        if (startNode == Graph.end) {
          throw const GraphBuildException('END cannot be a start node');
        }
        if (endNode == Graph.start) {
          throw const GraphBuildException('START cannot be an end node');
        }
        if (!nodes.containsKey(startNode) && startNode != Graph.start) {
          throw GraphBuildException(
            "edge start node '$startNode' needs to be added to graph first",
          );
        }
        if (!nodes.containsKey(endNode) && endNode != Graph.end) {
          throw GraphBuildException(
            "edge end node '$endNode' needs to be added to graph first",
          );
        }

        if (!noControl) {
          final ends = controlEdges[startNode] ??= [];
          if (ends.contains(endNode)) {
            throw GraphBuildException(
              'control edge[$startNode]-[$endNode] have been added yet',
            );
          }
          ends.add(endNode);
          if (startNode == Graph.start) startNodes.add(endNode);
          if (endNode == Graph.end) endNodes.add(startNode);
        }
        if (!noData) {
          if (dataEdges[startNode]?.contains(endNode) ?? false) {
            throw GraphBuildException(
              'data edge[$startNode]-[$endNode] have been added yet',
            );
          }
          (_toValidate[startNode] ??= [])
              .add(_PendingEdge(endNode, List.unmodifiable(mappings)));
          _updateToValidate();
          (dataEdges[startNode] ??= []).add(endNode);
        }
      });

  /// Adds [branch] behind [startNode]. With [skipData] the branch only
  /// decides what runs and carries no data.
  ///
  /// Port of eino `graph.addBranch`.
  void addBranch(
    String startNode,
    GraphBranch branch, {
    bool skipData = false,
  }) =>
      _change(() {
        if (startNode == Graph.end) {
          throw const GraphBuildException('END cannot be a start node');
        }
        final start = nodes[startNode];
        if (start == null && startNode != Graph.start) {
          throw GraphBuildException(
            "branch start node '$startNode' needs to be added to graph first",
          );
        }

        final handlers = handlerPreBranch[startNode] ??= [];
        final placed = branch.copyWith(
          index: handlers.length,
          noDataFlow: skipData,
        );

        // A passthrough node takes the type of the condition behind it.
        final cr = start?.cr;
        if (start != null && cr != null && start.executorMeta.isPassthrough) {
          cr
            ..inputType = branch.inputType
            ..outputType = branch.inputType
            ..helper = branch.helper.forPredecessorPassthrough();
        }

        final outputType = _outputTypeOf(startNode);
        switch (checkAssignable(outputType, branch.inputType)) {
          case Assignable.mustNot:
            throw GraphBuildException(
              "condition's input type[${branch.inputType.name}] and start "
              "node[$startNode]'s output type[${outputType?.name}] are "
              'mismatched',
            );
          case Assignable.may:
            handlers.add([branch.helper.inputConverter]);
          case Assignable.must:
            handlers.add([]);
        }

        for (final endNode in branch.endNodes) {
          if (!skipData) {
            if (!nodes.containsKey(endNode) && endNode != Graph.end) {
              throw GraphBuildException(
                "branch end node '$endNode' needs to be added to graph first",
              );
            }
            (_toValidate[startNode] ??= []).add(_PendingEdge(endNode));
            _updateToValidate();
          }
          if (startNode == Graph.start) startNodes.add(endNode);
          if (endNode == Graph.end) endNodes.add(startNode);
        }

        (branches[startNode] ??= []).add(placed);
      });

  /// Checks the types of the edges that are waiting for it, and gives
  /// passthrough nodes the types of their neighbours.
  ///
  /// Port of eino `graph.updateToValidateMap`.
  void _updateToValidate() {
    var changed = true;
    while (changed) {
      changed = false;
      for (final startNode in _toValidate.keys.toList()) {
        final pending = _toValidate[startNode]!;
        for (var i = 0; i < pending.length; i++) {
          final endNode = pending[i].endNode;
          final mappings = pending[i].mappings;
          final startType = _outputTypeOf(startNode);
          final endType = _inputTypeOf(endNode);
          if (startType == null && endType == null) continue;

          pending.removeAt(i);
          i--;
          changed = true;

          if (startType != null && endType == null) {
            nodes[endNode]!.cr!
              ..inputType = startType
              ..outputType = startType
              ..helper = _helperOf(startNode)!.forSuccessorPassthrough();
          } else if (startType == null) {
            nodes[startNode]!.cr!
              ..inputType = endType
              ..outputType = endType
              ..helper = _helperOf(endNode)!.forPredecessorPassthrough();
          } else if (mappings.isEmpty) {
            switch (checkAssignable(startType, endType)) {
              case Assignable.mustNot:
                throw GraphBuildException(
                  "graph edge[$startNode]-[$endNode]: start node's output "
                  "type[${startType.name}] and end node's input "
                  'type[${endType!.name}] mismatch',
                );
              case Assignable.may:
                ((handlerOnEdges[startNode] ??= {})[endNode] ??= [])
                    .add(_helperOf(endNode)!.inputConverter);
              case Assignable.must:
                break;
            }
            continue;
          }

          if (mappings.isNotEmpty) {
            (fieldMappingRecords[endNode] ??= []).addAll(mappings);
            validateFieldMappings(
              _outputTypeOf(startNode)!,
              _inputTypeOf(endNode)!,
              mappings,
            );
            // The edge delivers the mapped fields; the node assembles its
            // input from the fields of all its edges.
            ((handlerOnEdges[startNode] ??= {})[endNode] ??= [])
                .add(fieldMappingHandler(mappings));
          }
        }
      }
    }
  }

  GenericHelper? _helperOf(String name) {
    if (name == Graph.start) return helper.forPredecessorPassthrough();
    if (name == Graph.end) return helper.forSuccessorPassthrough();
    return nodes[name]!.helper;
  }

  TypeRef<Object?>? _inputTypeOf(String name) {
    if (name == Graph.start) return inputType;
    if (name == Graph.end) return outputType;
    return nodes[name]!.inputType;
  }

  TypeRef<Object?>? _outputTypeOf(String name) {
    if (name == Graph.start) return inputType;
    if (name == Graph.end) return outputType;
    return nodes[name]!.outputType;
  }

  /// Port of eino `graph.compile`.
  @override
  Future<ComposableRunnable> compile(
    RunContext ctx,
    GraphCompileOptions? options,
  ) async {
    final failed = buildError;
    if (failed != null) throw failed;

    final triggerMode = options?.nodeTriggerMode;
    if ((_isChain || _isWorkflow) && triggerMode != null) {
      throw GraphBuildException(
        "${component.einoName} doesn't support node trigger mode option",
      );
    }
    final dag = triggerMode == NodeTriggerMode.allPredecessor || _isWorkflow;
    final eager = dag && !(options?.eagerExecutionDisabled ?? false);

    if (startNodes.isEmpty) {
      throw const GraphBuildException('start node not set');
    }
    if (endNodes.isEmpty) throw const GraphBuildException('end node not set');

    final untyped = {
      for (final MapEntry(key: start, value: pending) in _toValidate.entries)
        if (pending.isNotEmpty)
          start: [for (final edge in pending) edge.endNode],
    };
    if (untyped.isNotEmpty) {
      throw GraphBuildException(
        "some node's input or output types cannot be inferred: $untyped",
      );
    }

    final preNodeHandlers = <String, List<HandlerPair>>{
      for (final MapEntry(:key, :value) in handlerPreNode.entries)
        key: List.of(value),
    };
    for (final MapEntry(key: nodeKey, value: mappings)
        in fieldMappingRecords.entries) {
      // Two mappings must not write the same field.
      final targets = <String>{};
      for (final mapping in mappings) {
        if (!targets.add(mapping.targetKey)) {
          throw GraphBuildException(
            'duplicate mapping target field: ${mapping.toPath.join('.')} of '
            'node[$nodeKey]',
          );
        }
      }
      // Into a list of this compile: a graph can be compiled more than once
      // (a batch node compiles its inner task on every call), and the
      // conversion must be there once.
      (preNodeHandlers[nodeKey] ??= []).add(
        fieldMappingConverter(_helperOf(nodeKey)!.input, List.of(mappings)),
      );
    }

    final state = localState;
    if (options?.checkpointStore != null &&
        state != null &&
        !state.canBeCheckpointed) {
      throw GraphBuildException(
        'the graph has a checkpoint store, but its state type '
        '${state.stateType.name} cannot be written to a checkpoint: it is '
        'neither JSON nor registered. Register it with '
        'TypeRegistry.registerName<${state.stateType.name}>',
      );
    }
    ensureComposeTypesRegistered();

    final subGraphs = options == null || options.compileCallbacks.isEmpty
        ? null
        : <String, GraphInfo>{};

    final chanSubscribeTo = <String, ChanCall>{};
    for (final MapEntry(key: name, value: node) in nodes.entries) {
      var nodeCompileOptions =
          node.nodeInfo.compileOptions ?? const GraphCompileOptions();
      if (node.graph != null && subGraphs != null) {
        // The structure of a nested graph is collected through a compile
        // callback of its own.
        nodeCompileOptions = nodeCompileOptions.copyWith(
          compileCallbacks: [
            ...nodeCompileOptions.compileCallbacks,
            _SubGraphCallback((info) => subGraphs[name] = info),
          ],
        );
      }
      final runnable = await node.compileIfNeeded(ctx, nodeCompileOptions);
      chanSubscribeTo[name] = ChanCall(
        action: runnable,
        writeTo: List.of(dataEdges[name] ?? const []),
        controls: List.of(controlEdges[name] ?? const []),
        writeToBranches: List.of(branches[name] ?? const []),
        preProcessor: node.nodeInfo.preProcessor,
        postProcessor: node.nodeInfo.postProcessor,
        preProcessorTakesStream: node.preHandler?.isStream ?? false,
      );
    }

    final dataPredecessors = <String, List<String>>{};
    final controlPredecessors = <String, List<String>>{};
    for (final MapEntry(key: start, value: ends) in controlEdges.entries) {
      for (final end in ends) {
        (controlPredecessors[end] ??= []).add(start);
      }
    }
    for (final MapEntry(key: start, value: ends) in dataEdges.entries) {
      for (final end in ends) {
        (dataPredecessors[end] ??= []).add(start);
      }
    }
    for (final MapEntry(key: start, value: ofStart) in branches.entries) {
      for (final branch in ofStart) {
        for (final end in branch.endNodes) {
          (controlPredecessors[end] ??= []).add(start);
          if (!branch.noDataFlow) (dataPredecessors[end] ??= []).add(start);
        }
      }
    }

    if (dag) validateDag(chanSubscribeTo, controlPredecessors);

    var maxRunSteps = options?.maxRunSteps ?? 0;
    if (dag && maxRunSteps > 0) {
      throw const GraphBuildException('cannot set max run steps in dag mode');
    } else if (!dag && maxRunSteps == 0) {
      maxRunSteps = chanSubscribeTo.length + 10;
    }

    final runner = GraphRunner(
      chanSubscribeTo: chanSubscribeTo,
      successors: {
        for (final MapEntry(key: name, value: call) in chanSubscribeTo.entries)
          name: _successorsOf(call),
      },
      dataPredecessors: dataPredecessors,
      controlPredecessors: controlPredecessors,
      inputChannels: ChanCall(
        writeTo: List.of(dataEdges[Graph.start] ?? const []),
        controls: List.of(controlEdges[Graph.start] ?? const []),
        writeToBranches: List.of(branches[Graph.start] ?? const []),
      ),
      channelBuilder: dag ? dagChannelBuilder : pregelChannelBuilder,
      eager: eager,
      dag: dag,
      helper: helper,
      edgeHandlers: EdgeHandlerManager(handlerOnEdges),
      preNodeHandlers: PreNodeHandlerManager(preNodeHandlers),
      preBranchHandlers: PreBranchHandlerManager(handlerPreBranch),
      mergeConfigs: options?.fanInMergeConfig ?? const {},
      maxRunSteps: maxRunSteps,
      checkPointer: CheckPointer(
        inputTypes: {
          for (final MapEntry(key: name, value: call)
              in chanSubscribeTo.entries)
            name: call.action!.inputType,
          Graph.end: outputType,
        },
        outputTypes: {
          for (final MapEntry(key: name, value: call)
              in chanSubscribeTo.entries)
            name: call.action!.outputType,
          Graph.start: inputType,
        },
        store: options?.checkpointStore,
        serializer: options?.serializer,
      ),
      interruptBeforeNodes: List.unmodifiable(
        options?.interruptBeforeNodes ?? const <String>[],
      ),
      interruptAfterNodes: List.unmodifiable(
        options?.interruptAfterNodes ?? const <String>[],
      ),
      fieldMappedNodes: fieldMappingRecords.keys.toSet(),
      runContext: state == null
          ? null
          : (ctx) => withInternalState(ctx, state.create(ctx)),
    );

    compiled = true;
    // The callback a graph around this one collects the structure with is
    // not one of the options this graph was compiled with.
    final reported = options == null ||
            !options.compileCallbacks.any((c) => c is _SubGraphCallback)
        ? options
        : options.copyWith(
            compileCallbacks: [
              for (final callback in options.compileCallbacks)
                if (callback is! _SubGraphCallback) callback,
            ],
          );
    _compiledWith = reported;

    if (options != null && options.compileCallbacks.isNotEmpty) {
      final info = _describe(reported, subGraphs ?? const {});
      for (final callback in options.compileCallbacks) {
        try {
          await callback.onFinish(ctx, info);
          // A callback observes the compile. Whatever goes wrong in it, the
          // graph is compiled.
          // ignore: avoid_catches_without_on_clauses
        } catch (error, stackTrace) {
          _log.warning(
            'Graph compile callback ${callback.runtimeType} failed',
            error,
            stackTrace,
          );
        }
      }
    }

    return runner.toComposableRunnable();
  }

  @override
  GraphInfo describe() => _describe(_compiledWith, {
        for (final MapEntry(key: name, value: node) in nodes.entries)
          if (node.graph != null) name: node.graph!.engine.describe(),
      });

  /// Port of eino `graph.toGraphInfo`.
  GraphInfo _describe(
    GraphCompileOptions? options,
    Map<String, GraphInfo> subGraphs,
  ) =>
      GraphInfo(
        compileOptions: options,
        nodes: Map.unmodifiable({
          for (final MapEntry(key: name, value: node) in nodes.entries)
            name: node.describe(
              graphInfo: subGraphs[name],
              mappings: fieldMappingRecords[name] ?? const [],
            ),
        }),
        edges: _copyEdges(controlEdges),
        dataEdges: _copyEdges(dataEdges),
        branches: Map.unmodifiable({
          for (final MapEntry(key: start, value: ofStart) in branches.entries)
            start: List<GraphBranch>.unmodifiable(ofStart),
        }),
        inputType: inputType.type,
        outputType: outputType.type,
        component: component,
        name: options?.graphName ?? '',
        localState: localState,
      );

  static Map<String, List<String>> _copyEdges(Map<String, List<String>> edges) =>
      Map.unmodifiable({
        for (final MapEntry(:key, :value) in edges.entries)
          key: List<String>.unmodifiable(value),
      });

  static List<String> _successorsOf(ChanCall call) => <String>{
        ...call.writeTo,
        ...call.controls,
        for (final branch in call.writeToBranches) ...branch.endNodes,
      }.toList();
}

final class _SubGraphCallback implements GraphCompileCallback {
  const _SubGraphCallback(this._closure);

  final void Function(GraphInfo info) _closure;

  @override
  void onFinish(RunContext ctx, GraphInfo info) => _closure(info);
}

/// Checks that the control flow of a graph that runs as a DAG has no cycle.
///
/// Port of eino `validateDAG`. Throws [DagLoopException] with the cycles.
@internal
void validateDag(
  Map<String, ChanCall> chanSubscribeTo,
  Map<String, List<String>> controlPredecessors,
) {
  final waitingFor = <String, int>{
    for (final node in chanSubscribeTo.keys)
      node: (controlPredecessors[node] ?? const [])
          .where((predecessor) => predecessor != Graph.start)
          .length,
  };

  var changed = true;
  while (changed) {
    changed = false;
    for (final node in waitingFor.keys.toList()) {
      if (waitingFor[node] != 0) continue;
      changed = true;
      final call = chanSubscribeTo[node]!;
      final next = [
        ...call.controls,
        for (final branch in call.writeToBranches) ...branch.endNodes,
      ];
      for (final successor in next) {
        if (successor == Graph.end) continue;
        waitingFor[successor] = waitingFor[successor]! - 1;
      }
      waitingFor[node] = -1;
    }
  }

  final loopStarts = [
    for (final MapEntry(:key, :value) in waitingFor.entries)
      if (value > 0) key,
  ];
  if (loopStarts.isNotEmpty) {
    throw DagLoopException(findLoops(loopStarts, chanSubscribeTo));
  }
}

/// The cycles that can be reached from [startNodes].
///
/// Port of eino `findLoops`. Each cycle lists its nodes in order and ends
/// with the node it started from.
@internal
List<List<String>> findLoops(
  List<String> startNodes,
  Map<String, ChanCall> chanCalls,
) {
  final controlSuccessors = <String, List<String>>{
    for (final MapEntry(key: node, value: call) in chanCalls.entries)
      node: [
        ...call.controls,
        for (final branch in call.writeToBranches) ...branch.endNodes,
      ],
  };

  final visited = <String>{};
  List<List<String>> search(List<String> path) {
    final loops = <List<String>>[];
    final successors = controlSuccessors[path.last];
    if (successors == null) return loops;
    for (final successor in successors) {
      visited.add(successor);
      if (successor == Graph.end) continue;

      final seenAt = path.indexOf(successor);
      if (seenAt >= 0) {
        loops.add([...path.skip(seenAt), successor]);
        continue;
      }
      loops.addAll(search([...path, successor]));
    }
    return loops;
  }

  return [
    for (final node in startNodes)
      if (!visited.contains(node)) ...search([node]),
  ];
}

/// Compiles [graph] into the typed runnable its caller gets.
///
/// Port of eino `compileAnyGraph` and `toGenericRunnable`.
@internal
Future<Runnable<I, O>> compileAnyGraph<I, O>(
  RunContext ctx,
  GraphEngine graph,
  GraphCompileOptions? options,
) async {
  var compileOptions = options ?? const GraphCompileOptions();
  final global = GraphCompileCallbacks.global;
  if (global.isNotEmpty) {
    compileOptions = compileOptions.copyWith(
      compileCallbacks: [...global, ...compileOptions.compileCallbacks],
    );
  }

  final runnable = await graph.compile(ctx, compileOptions);
  final meta = ExecutorMeta(
    component: graph.component,
    isComponentCallbackEnabled: true,
  );
  final info = NodeInfo(name: compileOptions.graphName);
  runnable
    ..meta = meta
    ..nodeInfo = info;

  final outputType = TypeRef<O>();
  final packer = RunnablePacker<I, O, CallOption>(
    invoke: (ctx, input, callOptions) async {
      final output = await runnable.invoke(ctx, input, callOptions);
      if (output is O) return output;
      throw ComposeTypeException(
        'unexpected output type. expected: $O, got: ${output.runtimeType}',
      );
    },
    transform: (ctx, input, callOptions) async =>
        outputType.stream(await runnable.transform(ctx, input, callOptions)),
  ).withContext(
    // A compiled graph that is run on its own is a place of its own in the
    // run: its interrupts are addressed below it.
    (ctx, callOptions) => initGraphCallbacks(
      appendAddressSegmentTo(
        ctx,
        AddressSegmentType.runnable,
        compileOptions.graphName,
      ),
      info,
      meta,
      callOptions,
    ),
  );
  return _CompiledRunnable<I, O>(packer);
}

final class _CompiledRunnable<I, O> implements Runnable<I, O> {
  const _CompiledRunnable(this._packer);

  final RunnablePacker<I, O, CallOption> _packer;

  @override
  Future<O> invoke(
    RunContext ctx,
    I input, {
    List<CallOption> options = const [],
  }) =>
      _packer.invoke(ctx, input, options);

  @override
  Future<StreamReader<O>> stream(
    RunContext ctx,
    I input, {
    List<CallOption> options = const [],
  }) =>
      _packer.stream(ctx, input, options);

  @override
  Future<O> collect(
    RunContext ctx,
    StreamReader<I> input, {
    List<CallOption> options = const [],
  }) =>
      _packer.collect(ctx, input, options);

  @override
  Future<StreamReader<O>> transform(
    RunContext ctx,
    StreamReader<I> input, {
    List<CallOption> options = const [],
  }) =>
      _packer.transform(ctx, input, options);
}

/// A directed graph of nodes that takes an [I] and gives an [O].
///
/// Port of eino `compose.Graph`. Nodes are components (chat models,
/// templates, retrievers, tools nodes), lambdas, other graphs, or
/// passthroughs. Edges say whose output is whose input; [start] and [end]
/// stand for the input and the output of the graph. A branch chooses the next
/// node when the graph runs.
///
/// ```dart
/// final graph = Graph<Map<String, dynamic>, Message>()
///   ..addChatTemplateNode('prompt', template)
///   ..addChatModelNode('model', model)
///   ..addEdge(Graph.start, 'prompt')
///   ..addEdge('prompt', 'model')
///   ..addEdge('model', Graph.end);
/// final runnable = await graph.compile(ctx);
/// final answer = await runnable.invoke(ctx, {'question': 'Why?'});
/// ```
///
/// The types along every edge are checked when the edge is added. A mistake
/// in building the graph throws a [GraphBuildException] at the call that
/// makes it, and again at every later call and at [compile].
///
/// By default a graph runs in steps (Pregel): the nodes that are ready run
/// side by side, then the nodes their outputs lead to. Cycles are allowed and
/// a step limit ends a run that does not reach the end
/// ([GraphCompileOptions.maxRunSteps]). With
/// [NodeTriggerMode.allPredecessor] the graph must be acyclic and a node runs
/// once all its predecessors have.
///
/// When several nodes lead to the same node, their outputs are merged; see
/// `ValuesMerge`.
final class Graph<I, O> implements AnyGraph {
  /// An empty graph. With [localState] it keeps a state object per run, which
  /// the state handlers of its nodes and `processState` reach. Port of eino
  /// `compose.NewGraph`.
  Graph({LocalState? localState})
      : _core = GraphCore(
          helper: GenericHelper.of<I, O>(),
          component: ComponentType.graph,
          localState: localState,
        );

  /// The key that stands for the input of a graph. Port of eino
  /// `compose.START`.
  static const String start = 'start';

  /// The key that stands for the output of a graph. Port of eino
  /// `compose.END`.
  static const String end = 'end';

  final GraphCore _core;

  @internal
  @override
  GraphEngine get engine => _core;

  /// Adds a chat model as the node [key]: it takes a `List<Message>` and
  /// gives a `Message`. Port of eino `Graph.AddChatModelNode`.
  void addChatModelNode(
    String key,
    BaseChatModel model, {
    NodeOptions? options,
  }) =>
      _core.addNode(key, toChatModelNode(model, options));

  /// Adds a chat template as the node [key]: it takes the variables as a
  /// `Map<String, dynamic>` and gives a `List<Message>`. Port of eino
  /// `Graph.AddChatTemplateNode`.
  void addChatTemplateNode(
    String key,
    ChatTemplate template, {
    NodeOptions? options,
  }) =>
      _core.addNode(key, toChatTemplateNode(template, options));

  /// Adds a tools node as the node [key]: it takes the assistant `Message`
  /// with tool calls and gives the tool messages as a `List<Message>`. Port
  /// of eino `Graph.AddToolsNode`.
  void addToolsNode(String key, ToolsNode node, {NodeOptions? options}) =>
      _core.addNode(key, toToolsNode(node, options));

  /// Adds a retriever as the node [key]: it takes the query as a `String` and
  /// gives a `List<Document>`. Port of eino `Graph.AddRetrieverNode`.
  void addRetrieverNode(
    String key,
    Retriever retriever, {
    NodeOptions? options,
  }) =>
      _core.addNode(key, toRetrieverNode(retriever, options));

  /// Adds an embedder as the node [key]: it takes a `List<String>` and gives
  /// a `List<List<double>>`. Port of eino `Graph.AddEmbeddingNode`.
  void addEmbeddingNode(
    String key,
    Embedder embedder, {
    NodeOptions? options,
  }) =>
      _core.addNode(key, toEmbeddingNode(embedder, options));

  /// Adds an indexer as the node [key]: it takes a `List<Document>` and gives
  /// the ids as a `List<String>`. Port of eino `Graph.AddIndexerNode`.
  void addIndexerNode(String key, Indexer indexer, {NodeOptions? options}) =>
      _core.addNode(key, toIndexerNode(indexer, options));

  /// Adds a loader as the node [key]: it takes a `DocumentSource` and gives a
  /// `List<Document>`. Port of eino `Graph.AddLoaderNode`.
  void addLoaderNode(String key, Loader loader, {NodeOptions? options}) =>
      _core.addNode(key, toLoaderNode(loader, options));

  /// Adds a document transformer as the node [key]: it takes and gives a
  /// `List<Document>`. Port of eino `Graph.AddDocumentTransformerNode`.
  void addDocumentTransformerNode(
    String key,
    DocumentTransformer transformer, {
    NodeOptions? options,
  }) =>
      _core.addNode(key, toDocumentTransformerNode(transformer, options));

  /// Adds a lambda as the node [key]. Port of eino `Graph.AddLambdaNode`.
  ///
  /// The type arguments are those of the lambda. They are there so that a
  /// lambda written inline gets its types from its function:
  /// `addLambdaNode('n', Lambda.invokable((ctx, String s) => s.length))`.
  void addLambdaNode<A, B>(
    String key,
    Lambda<A, B> lambda, {
    NodeOptions? options,
  }) =>
      _core.addNode(key, toLambdaNode(lambda, options));

  /// Adds a graph, chain or workflow as the node [key]. It is compiled with
  /// this graph, with [NodeOptions.compileOptions]. Port of eino
  /// `Graph.AddGraphNode`.
  void addGraphNode(String key, AnyGraph graph, {NodeOptions? options}) =>
      _core.addNode(key, toAnyGraphNode(graph, options));

  /// Adds a node that hands its input on unchanged. Its type is that of its
  /// neighbours. Port of eino `Graph.AddPassthroughNode`.
  void addPassthroughNode(String key, {NodeOptions? options}) =>
      _core.addNode(key, toPassthroughNode(options));

  /// Adds an edge: the node [to] runs after the node [from] and gets its
  /// output. Port of eino `Graph.AddEdge`.
  void addEdge(String from, String to) => _core.addEdge(from, to);

  /// Adds a branch behind the node [from]. Port of eino `Graph.AddBranch`.
  void addBranch(String from, GraphBranch branch) =>
      _core.addBranch(from, branch);

  /// Compiles the graph. Port of eino `Graph.Compile`.
  ///
  /// The graph cannot be changed afterwards. Throws [GraphBuildException]
  /// when the graph is incomplete or inconsistent.
  Future<Runnable<I, O>> compile(
    RunContext ctx, {
    GraphCompileOptions? options,
  }) =>
      compileAnyGraph<I, O>(ctx, _core, options);

  /// The structure of the graph as it is now: nodes, edges, branches. A
  /// `GraphCompileCallback` gets the same when the graph is compiled.
  GraphInfo get info => _core.describe();

  /// The graph as a Mermaid flowchart; see [GraphInfo.toMermaid].
  String toMermaid() => info.toMermaid();
}
