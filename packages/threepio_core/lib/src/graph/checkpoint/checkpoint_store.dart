import '../graph_state.dart';
import 'checkpoint.dart';

/// Configuration for checkpoint storage behavior.
class CheckpointStoreConfig {
  /// Creates store configuration.
  const CheckpointStoreConfig({
    this.maxCheckpointsPerThread = 100,
    this.ttl,
    this.compressData = false,
  });

  /// Maximum checkpoints to retain per thread.
  ///
  /// Older checkpoints are automatically removed when this limit is exceeded.
  /// Set to null for unlimited.
  final int? maxCheckpointsPerThread;

  /// Time-to-live for checkpoints.
  ///
  /// Checkpoints older than this duration may be automatically removed.
  /// Set to null for no expiration.
  final Duration? ttl;

  /// Whether to compress checkpoint data.
  ///
  /// Useful for reducing storage size with large states.
  final bool compressData;
}

/// Interface for persisting and retrieving checkpoints.
///
/// Implement this interface to support different storage backends:
/// - In-memory (for testing/development)
/// - File system (for local persistence)
/// - Database (for distributed systems)
/// - Cloud storage (for scalable deployments)
///
/// All operations support optional thread IDs for isolation.
///
/// Example:
/// ```dart
/// class MyCheckpointStore implements CheckpointStore<MyState> {
///   @override
///   Future<String> save(Checkpoint<MyState> checkpoint, {String? threadId}) {
///     // Persist checkpoint and return ID
///   }
///
///   @override
///   Future<Checkpoint<MyState>?> load(String checkpointId, {String? threadId}) {
///     // Load checkpoint by ID
///   }
///
///   // ... other methods
/// }
/// ```
abstract class CheckpointStore<S extends GraphState> {
  /// Saves a checkpoint and returns its ID.
  ///
  /// [checkpoint] - The checkpoint to save
  /// [threadId] - Optional thread ID for isolation
  /// [checkpointId] - Optional custom ID (auto-generated if not provided)
  ///
  /// Returns the checkpoint ID (either provided or generated).
  Future<String> save(
    Checkpoint<S> checkpoint, {
    String? threadId,
    String? checkpointId,
  });

  /// Loads a checkpoint by ID.
  ///
  /// [checkpointId] - The ID of the checkpoint to load
  /// [threadId] - Optional thread ID for isolation
  ///
  /// Returns null if checkpoint not found.
  Future<Checkpoint<S>?> load(String checkpointId, {String? threadId});

  /// Loads the most recent checkpoint for a thread.
  ///
  /// [threadId] - The thread ID to get the latest checkpoint for
  ///
  /// Returns null if no checkpoints exist for the thread.
  Future<Checkpoint<S>?> loadLatest({required String threadId});

  /// Deletes a checkpoint.
  ///
  /// [checkpointId] - The ID of the checkpoint to delete
  /// [threadId] - Optional thread ID for isolation
  Future<void> delete(String checkpointId, {String? threadId});

  /// Lists metadata for all checkpoints.
  ///
  /// [threadId] - If provided, only returns checkpoints for this thread
  ///
  /// Returns list of checkpoint metadata (without full state).
  Future<List<CheckpointMetadata>> list({String? threadId});

  /// Clears checkpoints.
  ///
  /// [threadId] - If provided, only clears checkpoints for this thread.
  ///              If null, clears all checkpoints.
  Future<void> clear({String? threadId});

  /// Gets checkpoint history for a thread.
  ///
  /// [threadId] - The thread ID to get history for
  /// [limit] - Maximum number of checkpoints to return
  /// [before] - Only return checkpoints before this time
  /// [after] - Only return checkpoints after this time
  ///
  /// Returns checkpoints in reverse chronological order (newest first).
  Future<List<Checkpoint<S>>> getHistory({
    required String threadId,
    int? limit,
    DateTime? before,
    DateTime? after,
  });

  /// Checks if a checkpoint exists.
  ///
  /// [checkpointId] - The ID to check
  /// [threadId] - Optional thread ID for isolation
  Future<bool> exists(String checkpointId, {String? threadId});

  /// Gets the count of checkpoints.
  ///
  /// [threadId] - If provided, counts only checkpoints for this thread
  Future<int> count({String? threadId});
}
