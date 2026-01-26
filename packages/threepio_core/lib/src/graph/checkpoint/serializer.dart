import 'dart:convert';

import '../graph_state.dart';
import 'checkpoint.dart';
import 'execution_address.dart';

/// Interface for serializing/deserializing checkpoint state.
///
/// Implement this interface to support different serialization formats
/// (JSON, binary, protobuf, etc.) for checkpoint persistence.
///
/// Example:
/// ```dart
/// class MyStateSerializer implements CheckpointSerializer<MyState> {
///   @override
///   Future<List<int>> serialize(Checkpoint<MyState> checkpoint) async {
///     // Serialize to bytes
///   }
///
///   @override
///   Future<Checkpoint<MyState>> deserialize(List<int> data) async {
///     // Deserialize from bytes
///   }
///
///   @override
///   String get contentType => 'application/json';
/// }
/// ```
abstract class CheckpointSerializer<S extends GraphState> {
  /// Serialize checkpoint to bytes.
  Future<List<int>> serialize(Checkpoint<S> checkpoint);

  /// Deserialize bytes to checkpoint.
  Future<Checkpoint<S>> deserialize(List<int> data);

  /// Content type identifier for this serializer.
  ///
  /// Examples: 'application/json', 'application/octet-stream'
  String get contentType;
}

/// JSON-based serializer for states with toJson/fromJson support.
///
/// This serializer uses JSON encoding for human-readable checkpoint files.
/// States must be serializable to/from JSON maps.
///
/// Example:
/// ```dart
/// final serializer = JsonCheckpointSerializer<MyState>(
///   stateToJson: (state) => state.toJson(),
///   stateFromJson: (json) => MyState.fromJson(json),
/// );
///
/// // Serialize
/// final bytes = await serializer.serialize(checkpoint);
///
/// // Deserialize
/// final restored = await serializer.deserialize(bytes);
/// ```
class JsonCheckpointSerializer<S extends GraphState>
    implements CheckpointSerializer<S> {
  /// Creates a JSON checkpoint serializer.
  ///
  /// [stateFromJson] - Function to create state from JSON map
  /// [stateToJson] - Function to convert state to JSON map
  JsonCheckpointSerializer({
    required this.stateFromJson,
    required this.stateToJson,
  });

  /// Function to create state from JSON.
  final S Function(Map<String, dynamic> json) stateFromJson;

  /// Function to convert state to JSON.
  final Map<String, dynamic> Function(S state) stateToJson;

  @override
  String get contentType => 'application/json';

  @override
  Future<List<int>> serialize(Checkpoint<S> checkpoint) async {
    final json = _checkpointToJson(checkpoint);
    return utf8.encode(jsonEncode(json));
  }

  @override
  Future<Checkpoint<S>> deserialize(List<int> data) async {
    final jsonString = utf8.decode(data);
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    return _checkpointFromJson(json);
  }

  /// Converts checkpoint to JSON map.
  Map<String, dynamic> _checkpointToJson(Checkpoint<S> checkpoint) {
    return {
      'id': checkpoint.id,
      'thread_id': checkpoint.threadId,
      'state': stateToJson(checkpoint.state),
      'current_node': checkpoint.currentNode,
      'path': checkpoint.path,
      'iteration': checkpoint.iteration,
      'timestamp': checkpoint.timestamp?.toIso8601String(),
      'metadata': checkpoint.metadata,
      if (checkpoint.address != null) 'address': checkpoint.address!.toJson(),
      if (checkpoint.interruptType != null)
        'interrupt_type': checkpoint.interruptType!.name,
      if (checkpoint.interruptReason != null)
        'interrupt_reason': checkpoint.interruptReason,
      // Note: pendingInput is intentionally not serialized as it may be
      // provided fresh when resuming
    };
  }

  /// Creates checkpoint from JSON map.
  Checkpoint<S> _checkpointFromJson(Map<String, dynamic> json) {
    return Checkpoint<S>(
      id: json['id'] as String?,
      threadId: json['thread_id'] as String?,
      state: stateFromJson(json['state'] as Map<String, dynamic>),
      currentNode: json['current_node'] as String,
      path: List<String>.from(json['path'] as List),
      iteration: json['iteration'] as int,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : null,
      metadata: (json['metadata'] as Map<String, dynamic>?) ?? const {},
      address: json['address'] != null
          ? ExecutionAddress.fromJson(json['address'] as Map<String, dynamic>)
          : null,
      interruptType: json['interrupt_type'] != null
          ? InterruptType.values.byName(json['interrupt_type'] as String)
          : null,
      interruptReason: json['interrupt_reason'] as String?,
    );
  }
}

/// Serializer for MapState checkpoints.
///
/// Convenience serializer when using the built-in MapState.
class MapStateCheckpointSerializer
    implements CheckpointSerializer<MapState> {
  /// Creates a MapState checkpoint serializer.
  const MapStateCheckpointSerializer();

  @override
  String get contentType => 'application/json';

  @override
  Future<List<int>> serialize(Checkpoint<MapState> checkpoint) async {
    final json = {
      'id': checkpoint.id,
      'thread_id': checkpoint.threadId,
      'state': checkpoint.state.toMap(),
      'current_node': checkpoint.currentNode,
      'path': checkpoint.path,
      'iteration': checkpoint.iteration,
      'timestamp': checkpoint.timestamp?.toIso8601String(),
      'metadata': checkpoint.metadata,
      if (checkpoint.address != null) 'address': checkpoint.address!.toJson(),
      if (checkpoint.interruptType != null)
        'interrupt_type': checkpoint.interruptType!.name,
      if (checkpoint.interruptReason != null)
        'interrupt_reason': checkpoint.interruptReason,
    };
    return utf8.encode(jsonEncode(json));
  }

  @override
  Future<Checkpoint<MapState>> deserialize(List<int> data) async {
    final jsonString = utf8.decode(data);
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    return Checkpoint<MapState>(
      id: json['id'] as String?,
      threadId: json['thread_id'] as String?,
      state: MapState(json['state'] as Map<String, dynamic>),
      currentNode: json['current_node'] as String,
      path: List<String>.from(json['path'] as List),
      iteration: json['iteration'] as int,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : null,
      metadata: (json['metadata'] as Map<String, dynamic>?) ?? const {},
      address: json['address'] != null
          ? ExecutionAddress.fromJson(json['address'] as Map<String, dynamic>)
          : null,
      interruptType: json['interrupt_type'] != null
          ? InterruptType.values.byName(json['interrupt_type'] as String)
          : null,
      interruptReason: json['interrupt_reason'] as String?,
    );
  }
}
