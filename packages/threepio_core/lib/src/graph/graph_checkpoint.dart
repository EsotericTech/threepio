import 'dart:convert';

import 'graph_state.dart';

/// A checkpoint in graph execution
///
/// Checkpoints allow you to save and resume graph execution state.
/// Useful for long-running workflows, debugging, and error recovery.
class Checkpoint<S extends GraphState> {
  const Checkpoint({
    required this.state,
    required this.currentNode,
    required this.path,
    required this.iteration,
    this.timestamp,
    this.metadata = const {},
  });

  /// Current state at this checkpoint
  final S state;

  /// Current node being executed
  final String currentNode;

  /// Path taken so far
  final List<String> path;

  /// Current iteration number
  final int iteration;

  /// When this checkpoint was created
  final DateTime? timestamp;

  /// Additional metadata
  final Map<String, dynamic> metadata;

  /// Create a checkpoint with timestamp
  factory Checkpoint.now({
    required S state,
    required String currentNode,
    required List<String> path,
    required int iteration,
    Map<String, dynamic>? metadata,
  }) {
    return Checkpoint(
      state: state,
      currentNode: currentNode,
      path: path,
      iteration: iteration,
      timestamp: DateTime.now(),
      metadata: metadata ?? {},
    );
  }

  @override
  String toString() =>
      'Checkpoint(node: $currentNode, iteration: $iteration, path: ${path.length} steps)';
}

/// Interface for checkpoint storage
///
/// Implement this to persist checkpoints to different backends
/// (memory, file system, database, etc.)
abstract class CheckpointStore<S extends GraphState> {
  /// Save a checkpoint
  Future<void> save(String id, Checkpoint<S> checkpoint);

  /// Load a checkpoint
  Future<Checkpoint<S>?> load(String id);

  /// Delete a checkpoint
  Future<void> delete(String id);

  /// List all checkpoint IDs
  Future<List<String>> list();

  /// Clear all checkpoints
  Future<void> clear();
}

/// In-memory checkpoint store for testing/development
class InMemoryCheckpointStore<S extends GraphState>
    implements CheckpointStore<S> {
  final Map<String, Checkpoint<S>> _checkpoints = {};

  @override
  Future<void> save(String id, Checkpoint<S> checkpoint) async {
    _checkpoints[id] = checkpoint;
  }

  @override
  Future<Checkpoint<S>?> load(String id) async {
    return _checkpoints[id];
  }

  @override
  Future<void> delete(String id) async {
    _checkpoints.remove(id);
  }

  @override
  Future<List<String>> list() async {
    return _checkpoints.keys.toList();
  }

  @override
  Future<void> clear() async {
    _checkpoints.clear();
  }

  /// Get the number of checkpoints stored
  int get count => _checkpoints.length;
}

/// JSON-serializable checkpoint for MapState
///
/// Allows saving and loading checkpoints as JSON.
class JsonCheckpoint {
  const JsonCheckpoint({
    required this.state,
    required this.currentNode,
    required this.path,
    required this.iteration,
    this.timestamp,
    this.metadata = const {},
  });

  final Map<String, dynamic> state;
  final String currentNode;
  final List<String> path;
  final int iteration;
  final String? timestamp;
  final Map<String, dynamic> metadata;

  /// Convert checkpoint to JSON
  Map<String, dynamic> toJson() {
    return {
      'state': state,
      'current_node': currentNode,
      'path': path,
      'iteration': iteration,
      if (timestamp != null) 'timestamp': timestamp,
      'metadata': metadata,
    };
  }

  /// Create checkpoint from JSON
  factory JsonCheckpoint.fromJson(Map<String, dynamic> json) {
    return JsonCheckpoint(
      state: Map<String, dynamic>.from(json['state'] as Map),
      currentNode: json['current_node'] as String,
      path: List<String>.from(json['path'] as List),
      iteration: json['iteration'] as int,
      timestamp: json['timestamp'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>? ?? {},
    );
  }

  /// Convert to Checkpoint<MapState>
  Checkpoint<MapState> toCheckpoint() {
    return Checkpoint<MapState>(
      state: MapState(state),
      currentNode: currentNode,
      path: path,
      iteration: iteration,
      timestamp: timestamp != null ? DateTime.parse(timestamp!) : null,
      metadata: metadata,
    );
  }

  /// Create from Checkpoint<MapState>
  factory JsonCheckpoint.fromCheckpoint(Checkpoint<MapState> checkpoint) {
    return JsonCheckpoint(
      state: checkpoint.state.toMap(),
      currentNode: checkpoint.currentNode,
      path: checkpoint.path,
      iteration: checkpoint.iteration,
      timestamp: checkpoint.timestamp?.toIso8601String(),
      metadata: checkpoint.metadata,
    );
  }

  /// Serialize to JSON string
  String serialize() => jsonEncode(toJson());

  /// Deserialize from JSON string
  factory JsonCheckpoint.deserialize(String json) {
    return JsonCheckpoint.fromJson(jsonDecode(json) as Map<String, dynamic>);
  }
}

/// File-based checkpoint store (example implementation)
///
/// Note: This is a simple example. Production code should handle
/// errors, file locking, and cleanup more robustly.
class FileCheckpointStore implements CheckpointStore<MapState> {
  FileCheckpointStore(this.directory);

  final String directory;

  @override
  Future<void> save(String id, Checkpoint<MapState> checkpoint) async {
    // This is a placeholder - implement file I/O
    // In real implementation, write JsonCheckpoint to file
    throw UnimplementedError('File I/O not implemented');
  }

  @override
  Future<Checkpoint<MapState>?> load(String id) async {
    // This is a placeholder - implement file I/O
    throw UnimplementedError('File I/O not implemented');
  }

  @override
  Future<void> delete(String id) async {
    throw UnimplementedError('File I/O not implemented');
  }

  @override
  Future<List<String>> list() async {
    throw UnimplementedError('File I/O not implemented');
  }

  @override
  Future<void> clear() async {
    throw UnimplementedError('File I/O not implemented');
  }
}
