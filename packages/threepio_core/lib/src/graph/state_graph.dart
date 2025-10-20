import 'dart:async';

import '../callbacks/callback_handler.dart';
import '../callbacks/callback_manager.dart';
import '../callbacks/run_info.dart';
import 'graph_edge.dart';
import 'graph_node.dart';
import 'graph_state.dart';

/// Builder and executor for state-based graphs
///
/// StateGraph provides a declarative API for building complex workflows
/// with branching, loops, and parallel execution.
///
/// Example:
/// ```dart
/// final graph = StateGraph<MyState>()
///   ..addNode('fetch', fetchNode)
///   ..addNode('process', processNode)
///   ..addNode('respond', respondNode)
///   ..addEdge('fetch', 'process')
///   ..addConditionalEdge('process', (state) {
///     return state.needsMoreData ? 'fetch' : 'respond';
///   })
///   ..setEntryPoint('fetch');
///
/// final result = await graph.invoke(MyState(query: 'hello'));
/// ```
class StateGraph<S extends GraphState> {
  StateGraph({
    this.maxIterations = 100,
  });

  /// Maximum iterations to prevent infinite loops
  final int maxIterations;

  /// All nodes in the graph
  final Map<String, GraphNode<S>> _nodes = {};

  /// All edges in the graph
  final List<GraphEdge<S>> _edges = [];

  /// Entry point node name
  String? _entryPoint;

  /// Add a node to the graph
  ///
  /// [name] - Unique identifier for this node
  /// [function] - Function to execute when node is visited
  /// [description] - Optional description for debugging
  StateGraph<S> addNode(
    String name,
    NodeFunction<S> function, {
    String? description,
  }) {
    if (_nodes.containsKey(name)) {
      throw ArgumentError('Node "$name" already exists');
    }

    _nodes[name] = GraphNode<S>(
      name: name,
      function: function,
      description: description,
    );

    return this;
  }

  /// Add a direct edge between two nodes
  ///
  /// [from] - Source node name
  /// [to] - Target node name
  StateGraph<S> addEdge(String from, String to) {
    _validateNode(from);
    _validateNode(to, allowEnd: true);

    _edges.add(DirectEdge<S>(from: from, to: to));

    return this;
  }

  /// Add a conditional edge that routes based on state
  ///
  /// [from] - Source node name
  /// [router] - Function that returns the next node name based on state
  /// [description] - Optional description for debugging
  StateGraph<S> addConditionalEdge(
    String from,
    FutureOr<String> Function(S state) router, {
    String? description,
  }) {
    _validateNode(from);

    _edges.add(ConditionalEdge<S>(
      from: from,
      router: router,
      description: description,
    ));

    return this;
  }

  /// Add a conditional router with named routes
  ///
  /// [from] - Source node name
  /// [routes] - Map of route names to condition functions
  /// [defaultRoute] - Default route if no conditions match (defaults to END)
  StateGraph<S> addConditionalRouter(
    String from,
    Map<String, bool Function(S state)> routes, {
    String defaultRoute = END,
  }) {
    _validateNode(from);

    _edges.add(ConditionalRouter<S>(
      from: from,
      routes: routes,
      defaultRoute: defaultRoute,
    ));

    return this;
  }

  /// Add a parallel edge that executes multiple nodes concurrently
  ///
  /// [from] - Source node name
  /// [to] - List of target node names to execute in parallel
  /// [merger] - Optional function to merge results from parallel branches
  StateGraph<S> addParallelEdge(
    String from,
    List<String> to, {
    S Function(S originalState, List<S> results)? merger,
  }) {
    _validateNode(from);
    for (final target in to) {
      _validateNode(target);
    }

    _edges.add(ParallelEdge<S>(
      from: from,
      to: to,
      merger: merger,
    ));

    return this;
  }

  /// Set the entry point of the graph
  ///
  /// This is the first node to execute.
  StateGraph<S> setEntryPoint(String nodeName) {
    _validateNode(nodeName);
    _entryPoint = nodeName;
    return this;
  }

  /// Execute the graph with the given initial state
  ///
  /// [initialState] - Starting state
  /// [callbackManager] - Optional callback manager for observability
  Future<GraphResult<S>> invoke(
    S initialState, {
    CallbackManager? callbackManager,
  }) async {
    if (_entryPoint == null) {
      throw StateError('Entry point not set. Call setEntryPoint() first.');
    }

    if (callbackManager != null) {
      final runInfo = RunInfo(
        name: 'StateGraph',
        type: 'StateGraph<$S>',
        componentType: ComponentType.custom,
        metadata: {
          'entry_point': _entryPoint,
          'node_count': _nodes.length,
          'edge_count': _edges.length,
        },
      );

      return await callbackManager.runWithCallbacks(
        {},
        runInfo,
        initialState,
        () => _executeGraph(initialState),
      );
    } else {
      return _executeGraph(initialState);
    }
  }

  /// Internal graph execution
  Future<GraphResult<S>> _executeGraph(S initialState) async {
    var currentState = initialState;
    var currentNode = _entryPoint!;
    final path = <String>[];
    var iterations = 0;

    while (currentNode != END && iterations < maxIterations) {
      iterations++;
      path.add(currentNode);

      // Execute current node
      final node = _nodes[currentNode]!;
      currentState = await node.execute(currentState);

      // Find next node(s)
      final nextNodes = await _getNextNodes(currentNode, currentState);

      if (nextNodes.isEmpty || nextNodes.first == END) {
        break;
      }

      // Handle parallel execution
      if (nextNodes.length > 1) {
        currentState = await _executeParallel(
          nextNodes,
          currentState,
          currentNode,
        );
        // After parallel, check for edges from any of the parallel nodes
        currentNode = await _findNextAfterParallel(nextNodes, currentState);
      } else {
        currentNode = nextNodes.first;
      }
    }

    if (iterations >= maxIterations) {
      throw StateError(
        'Graph exceeded maximum iterations ($maxIterations). Possible infinite loop.',
      );
    }

    return GraphResult<S>(
      state: currentState,
      path: path,
      metadata: {'iterations': iterations},
    );
  }

  /// Get next node(s) from current node
  Future<List<String>> _getNextNodes(String from, S state) async {
    final matchingEdges = _edges.where((e) => e.from == from).toList();

    if (matchingEdges.isEmpty) {
      return [END];
    }

    // For parallel edges, return all targets
    if (matchingEdges.first is ParallelEdge<S>) {
      return await matchingEdges.first.getNext(state);
    }

    // For regular/conditional edges, return first match
    return await matchingEdges.first.getNext(state);
  }

  /// Execute multiple nodes in parallel
  Future<S> _executeParallel(
    List<String> nodeNames,
    S currentState,
    String fromNode,
  ) async {
    // Find the parallel edge to get merger function
    final parallelEdge = _edges
        .whereType<ParallelEdge<S>>()
        .firstWhere((e) => e.from == fromNode);

    // Execute all nodes in parallel
    final futures = nodeNames.map((name) async {
      final node = _nodes[name]!;
      return await node.execute(currentState);
    });

    final results = await Future.wait(futures);

    // Merge results if merger is provided, otherwise use last result
    if (parallelEdge.merger != null) {
      return parallelEdge.merger!(currentState, results);
    } else {
      return results.last;
    }
  }

  /// Find next node after parallel execution
  Future<String> _findNextAfterParallel(
    List<String> parallelNodes,
    S state,
  ) async {
    // Check if any of the parallel nodes have outgoing edges
    for (final node in parallelNodes) {
      final nextNodes = await _getNextNodes(node, state);
      if (nextNodes.isNotEmpty && nextNodes.first != END) {
        return nextNodes.first;
      }
    }

    return END;
  }

  /// Validate that a node exists
  void _validateNode(String name, {bool allowEnd = false}) {
    if (name == END && allowEnd) return;
    if (!_nodes.containsKey(name)) {
      throw ArgumentError('Node "$name" does not exist');
    }
  }

  /// Get a visual representation of the graph
  String toMermaid() {
    final buffer = StringBuffer();
    buffer.writeln('graph TD');

    // Add entry point
    if (_entryPoint != null) {
      buffer.writeln('    START(( ))');
      buffer.writeln('    START --> $_entryPoint');
    }

    // Add nodes
    for (final node in _nodes.values) {
      final desc = node.description ?? '';
      buffer.writeln(
          '    ${node.name}[${node.name}${desc.isNotEmpty ? '<br/>$desc' : ''}]');
    }

    // Add edges
    for (final edge in _edges) {
      if (edge is DirectEdge<S>) {
        buffer.writeln('    ${edge.from} --> ${edge.to}');
      } else if (edge is ConditionalEdge<S>) {
        final desc = edge.description ?? '?';
        buffer.writeln('    ${edge.from} -->|$desc| ?');
      } else if (edge is ParallelEdge<S>) {
        for (final to in edge.to) {
          buffer.writeln('    ${edge.from} -.-> $to');
        }
      }
    }

    // Add END node
    buffer.writeln('    END(( ))');

    return buffer.toString();
  }

  /// Get summary of the graph
  @override
  String toString() {
    return 'StateGraph<$S>(nodes: ${_nodes.length}, edges: ${_edges.length}, entry: $_entryPoint)';
  }
}

/// Exception thrown during graph execution
class GraphExecutionException implements Exception {
  GraphExecutionException(this.message, {this.nodeName, this.cause});

  final String message;
  final String? nodeName;
  final dynamic cause;

  @override
  String toString() {
    final buffer = StringBuffer('GraphExecutionException: $message');
    if (nodeName != null) {
      buffer.write(' (node: $nodeName)');
    }
    if (cause != null) {
      buffer.write('\nCaused by: $cause');
    }
    return buffer.toString();
  }
}
