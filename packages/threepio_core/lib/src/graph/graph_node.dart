import 'dart:async';

import 'graph_state.dart';

/// A node function that processes state
///
/// Takes current state and returns updated state.
/// Can be async for I/O operations.
typedef NodeFunction<S extends GraphState> = FutureOr<S> Function(S state);

/// A node in the graph that processes state
///
/// Nodes are the processing units of a graph. Each node:
/// - Receives the current state
/// - Performs some operation
/// - Returns updated state
///
/// Example:
/// ```dart
/// // Simple sync node
/// Node<MyState> processNode(MyState state) {
///   return state.copyWith(processed: true);
/// }
///
/// // Async node with I/O
/// Future<MyState> fetchNode(MyState state) async {
///   final data = await fetchData(state.query);
///   return state.copyWith(data: data);
/// }
/// ```
class GraphNode<S extends GraphState> {
  GraphNode({
    required this.name,
    required this.function,
    this.description,
  });

  /// Unique name for this node
  final String name;

  /// Function to execute
  final NodeFunction<S> function;

  /// Optional description for debugging/visualization
  final String? description;

  /// Execute this node with the given state
  Future<S> execute(S state) async {
    return await function(state);
  }

  @override
  String toString() =>
      'Node($name${description != null ? ': $description' : ''})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphNode<S> &&
          runtimeType == other.runtimeType &&
          name == other.name;

  @override
  int get hashCode => name.hashCode;
}

/// Special node name indicating the end of graph execution
const String END = '__end__';

/// Special node name indicating the start of graph execution
const String START = '__start__';
