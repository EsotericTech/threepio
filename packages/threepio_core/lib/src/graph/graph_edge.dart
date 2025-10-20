import 'dart:async';

import 'graph_node.dart';
import 'graph_state.dart';

/// Base class for edges connecting nodes
abstract class GraphEdge<S extends GraphState> {
  const GraphEdge({required this.from});

  /// Source node name
  final String from;

  /// Get the next node(s) to execute given the current state
  FutureOr<List<String>> getNext(S state);
}

/// A direct edge to a single target node
///
/// Always routes to the same target node.
///
/// Example:
/// ```dart
/// DirectEdge(from: 'fetch', to: 'process')
/// ```
class DirectEdge<S extends GraphState> extends GraphEdge<S> {
  const DirectEdge({
    required super.from,
    required this.to,
  });

  /// Target node name
  final String to;

  @override
  List<String> getNext(S state) => [to];

  @override
  String toString() => 'DirectEdge($from -> $to)';
}

/// A conditional edge that routes based on state
///
/// Uses a router function to decide which node to visit next.
///
/// Example:
/// ```dart
/// ConditionalEdge<MyState>(
///   from: 'analyze',
///   router: (state) {
///     if (state.confidence > 0.8) return 'respond';
///     if (state.confidence > 0.5) return 'verify';
///     return 'retry';
///   },
/// )
/// ```
class ConditionalEdge<S extends GraphState> extends GraphEdge<S> {
  ConditionalEdge({
    required super.from,
    required this.router,
    this.description,
  });

  /// Function that determines the next node based on state
  final FutureOr<String> Function(S state) router;

  /// Optional description for debugging
  final String? description;

  @override
  Future<List<String>> getNext(S state) async {
    final next = await router(state);
    return [next];
  }

  @override
  String toString() =>
      'ConditionalEdge($from -> ?)${description != null ? ': $description' : ''}';
}

/// A multi-edge that routes to multiple nodes in parallel
///
/// Executes multiple branches in parallel and merges results.
///
/// Example:
/// ```dart
/// ParallelEdge<MyState>(
///   from: 'fetch',
///   to: ['process_text', 'extract_entities', 'analyze_sentiment'],
///   merger: (state, results) {
///     // Merge results from all parallel branches
///     return state.copyWith(
///       processed: results[0].processed,
///       entities: results[1].entities,
///       sentiment: results[2].sentiment,
///     );
///   },
/// )
/// ```
class ParallelEdge<S extends GraphState> extends GraphEdge<S> {
  ParallelEdge({
    required super.from,
    required this.to,
    this.merger,
  });

  /// List of target nodes to execute in parallel
  final List<String> to;

  /// Optional function to merge results from parallel branches
  /// If not provided, uses the last result
  final S Function(S originalState, List<S> results)? merger;

  @override
  List<String> getNext(S state) => to;

  @override
  String toString() => 'ParallelEdge($from -> ${to.join(', ')})';
}

/// A conditional router that maps conditions to target nodes
///
/// Provides a cleaner API for complex routing logic.
///
/// Example:
/// ```dart
/// ConditionalRouter<MyState>(
///   from: 'classify',
///   routes: {
///     'question': (state) => state.type == QueryType.question,
///     'command': (state) => state.type == QueryType.command,
///     'statement': (state) => state.type == QueryType.statement,
///   },
///   defaultRoute: 'unknown',
/// )
/// ```
class ConditionalRouter<S extends GraphState> extends ConditionalEdge<S> {
  ConditionalRouter({
    required super.from,
    required this.routes,
    this.defaultRoute = END,
  }) : super(
          router: (state) => _route(state, routes, defaultRoute),
          description: 'Routes to: ${routes.keys.join(', ')}',
        );

  /// Map of route names to conditions
  final Map<String, bool Function(S state)> routes;

  /// Default route if no conditions match
  final String defaultRoute;

  static FutureOr<String> _route<S extends GraphState>(
    S state,
    Map<String, bool Function(S state)> routes,
    String defaultRoute,
  ) {
    for (final entry in routes.entries) {
      if (entry.value(state)) {
        return entry.key;
      }
    }
    return defaultRoute;
  }

  @override
  String toString() =>
      'ConditionalRouter($from -> {${routes.keys.join(', ')}})';
}
