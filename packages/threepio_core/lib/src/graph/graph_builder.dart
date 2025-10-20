import 'graph_node.dart';
import 'graph_state.dart';
import 'state_graph.dart';

/// Fluent builder for creating graphs with a more expressive API
///
/// Example:
/// ```dart
/// final graph = GraphBuilder<MyState>()
///   .withNode('start', startNode)
///   .withNode('process', processNode)
///   .withNode('end', endNode)
///   .connect('start', 'process')
///   .routeIf(
///     from: 'process',
///     condition: (state) => state.isComplete,
///     then: 'end',
///     otherwise: 'start',
///   )
///   .startFrom('start')
///   .build();
/// ```
class GraphBuilder<S extends GraphState> {
  GraphBuilder({int maxIterations = 100})
      : _graph = StateGraph<S>(maxIterations: maxIterations);

  final StateGraph<S> _graph;

  /// Add a node to the graph
  GraphBuilder<S> withNode(
    String name,
    NodeFunction<S> function, {
    String? description,
  }) {
    _graph.addNode(name, function, description: description);
    return this;
  }

  /// Connect two nodes with a direct edge
  GraphBuilder<S> connect(String from, String to) {
    _graph.addEdge(from, to);
    return this;
  }

  /// Add conditional routing with if/then/else logic
  GraphBuilder<S> routeIf({
    required String from,
    required bool Function(S state) condition,
    required String then,
    required String otherwise,
  }) {
    _graph.addConditionalRouter(from, {
      then: condition,
      otherwise: (state) => !condition(state),
    });
    return this;
  }

  /// Add conditional routing with multiple conditions
  GraphBuilder<S> routeWhen({
    required String from,
    required Map<String, bool Function(S state)> routes,
    String? defaultRoute,
  }) {
    _graph.addConditionalRouter(
      from,
      routes,
      defaultRoute: defaultRoute ?? END,
    );
    return this;
  }

  /// Add parallel execution
  GraphBuilder<S> parallel({
    required String from,
    required List<String> to,
    S Function(S originalState, List<S> results)? merger,
  }) {
    _graph.addParallelEdge(from, to, merger: merger);
    return this;
  }

  /// Set the entry point
  GraphBuilder<S> startFrom(String nodeName) {
    _graph.setEntryPoint(nodeName);
    return this;
  }

  /// Build and return the graph
  StateGraph<S> build() {
    return _graph;
  }
}

/// Helper functions for common graph patterns
class GraphPatterns {
  /// Create a simple linear graph: A -> B -> C -> END
  static StateGraph<S> linear<S extends GraphState>(
    List<MapEntry<String, NodeFunction<S>>> nodes,
  ) {
    final graph = StateGraph<S>();

    // Add all nodes
    for (final entry in nodes) {
      graph.addNode(entry.key, entry.value);
    }

    // Connect them linearly
    for (var i = 0; i < nodes.length - 1; i++) {
      graph.addEdge(nodes[i].key, nodes[i + 1].key);
    }

    // Last node goes to END
    graph.addEdge(nodes.last.key, END);

    // Set entry point
    graph.setEntryPoint(nodes.first.key);

    return graph;
  }

  /// Create a loop graph: A -> B -> C -?-> A or END
  static StateGraph<S> loop<S extends GraphState>({
    required String entryNode,
    required List<MapEntry<String, NodeFunction<S>>> nodes,
    required bool Function(S state) shouldContinue,
  }) {
    final graph = StateGraph<S>();

    // Add all nodes
    for (final entry in nodes) {
      graph.addNode(entry.key, entry.value);
    }

    // Connect nodes linearly
    for (var i = 0; i < nodes.length - 1; i++) {
      graph.addEdge(nodes[i].key, nodes[i + 1].key);
    }

    // Last node: loop back or end
    graph.addConditionalRouter(
      nodes.last.key,
      {
        entryNode: shouldContinue,
        END: (state) => !shouldContinue(state),
      },
    );

    graph.setEntryPoint(entryNode);

    return graph;
  }

  /// Create a retry graph: try -> check -> retry or END
  static StateGraph<S> retry<S extends GraphState>({
    required String tryNode,
    required NodeFunction<S> tryFunction,
    required bool Function(S state) isSuccess,
    int maxRetries = 3,
  }) {
    final graph = StateGraph<S>();

    // Add retry counter to state if it doesn't exist
    graph.addNode(tryNode, tryFunction);

    graph.addNode('check_retry', (state) {
      // This is a simple pattern - in real use, you'd track retries in state
      return state;
    });

    graph.addEdge(tryNode, 'check_retry');

    graph.addConditionalRouter(
      'check_retry',
      {
        END: isSuccess,
        tryNode: (state) =>
            !isSuccess(state), // Simplified - should check retry count
      },
    );

    graph.setEntryPoint(tryNode);

    return graph;
  }

  /// Create a map-reduce graph: split -> parallel process -> merge
  static StateGraph<S> mapReduce<S extends GraphState>({
    required String splitNode,
    required NodeFunction<S> splitFunction,
    required List<MapEntry<String, NodeFunction<S>>> mappers,
    required String mergeNode,
    required NodeFunction<S> mergeFunction,
  }) {
    final graph = StateGraph<S>();

    // Add split node
    graph.addNode(splitNode, splitFunction);

    // Add all mapper nodes
    for (final mapper in mappers) {
      graph.addNode(mapper.key, mapper.value);
    }

    // Add merge node
    graph.addNode(mergeNode, mergeFunction);

    // Connect split to all mappers in parallel
    graph.addParallelEdge(
      splitNode,
      mappers.map((m) => m.key).toList(),
    );

    // Connect all mappers to merge
    for (final mapper in mappers) {
      graph.addEdge(mapper.key, mergeNode);
    }

    graph.addEdge(mergeNode, END);

    graph.setEntryPoint(splitNode);

    return graph;
  }
}
