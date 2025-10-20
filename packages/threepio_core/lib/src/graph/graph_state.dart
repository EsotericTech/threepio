/// Base interface for graph state
///
/// Graph state flows through nodes and gets updated at each step.
/// Implementations should be immutable and use copyWith patterns.
///
/// Example:
/// ```dart
/// class MyState implements GraphState {
///   const MyState({
///     required this.query,
///     this.results = const [],
///     this.confidence = 0.0,
///   });
///
///   final String query;
///   final List<String> results;
///   final double confidence;
///
///   @override
///   MyState copyWith({
///     String? query,
///     List<String>? results,
///     double? confidence,
///   }) {
///     return MyState(
///       query: query ?? this.query,
///       results: results ?? this.results,
///       confidence: confidence ?? this.confidence,
///     );
///   }
/// }
/// ```
abstract class GraphState {
  /// Create a copy of the state with updated fields
  GraphState copyWith();
}

/// Simple map-based state for quick prototyping
///
/// Use this when you don't need type safety or complex state.
///
/// Example:
/// ```dart
/// final state = MapState({'count': 0, 'items': []});
/// final updated = state.set('count', 1);
/// ```
class MapState implements GraphState {
  MapState([Map<String, dynamic>? data]) : _data = Map.from(data ?? {});

  final Map<String, dynamic> _data;

  /// Get a value from the state
  T? get<T>(String key) => _data[key] as T?;

  /// Set a value in the state (returns new state)
  MapState set(String key, dynamic value) {
    return MapState({..._data, key: value});
  }

  /// Set multiple values at once
  MapState setAll(Map<String, dynamic> updates) {
    return MapState({..._data, ...updates});
  }

  /// Remove a key from the state
  MapState remove(String key) {
    final newData = Map<String, dynamic>.from(_data);
    newData.remove(key);
    return MapState(newData);
  }

  /// Get all data as a map
  Map<String, dynamic> toMap() => Map.from(_data);

  /// Check if a key exists
  bool containsKey(String key) => _data.containsKey(key);

  @override
  MapState copyWith() => MapState(_data);

  @override
  String toString() => 'MapState($_data)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MapState &&
          runtimeType == other.runtimeType &&
          _mapsEqual(_data, other._data);

  @override
  int get hashCode => _data.hashCode;

  bool _mapsEqual(Map a, Map b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || a[key] != b[key]) return false;
    }
    return true;
  }
}

/// Result of a graph execution
class GraphResult<S extends GraphState> {
  const GraphResult({
    required this.state,
    required this.path,
    this.metadata = const {},
  });

  /// Final state after graph execution
  final S state;

  /// Path taken through the graph (list of node names)
  final List<String> path;

  /// Additional metadata from execution
  final Map<String, dynamic> metadata;

  @override
  String toString() => 'GraphResult(path: $path, state: $state)';
}
