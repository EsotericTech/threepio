import 'package:uuid/uuid.dart';

import '../../graph_state.dart';
import '../checkpoint.dart';
import '../checkpoint_store.dart';

/// Thread-aware in-memory checkpoint store.
///
/// Useful for testing, development, and short-lived workflows.
/// Data is lost when the store is garbage collected.
///
/// Features:
/// - Thread-based isolation
/// - Configurable max checkpoints per thread
/// - Automatic cleanup of old checkpoints
///
/// Example:
/// ```dart
/// final store = InMemoryCheckpointStore<MyState>(
///   config: CheckpointStoreConfig(
///     maxCheckpointsPerThread: 50,
///   ),
/// );
///
/// // Save checkpoint
/// final id = await store.save(checkpoint, threadId: 'user-123');
///
/// // Load latest
/// final latest = await store.loadLatest(threadId: 'user-123');
/// ```
class InMemoryCheckpointStore<S extends GraphState>
    implements CheckpointStore<S> {
  /// Creates an in-memory checkpoint store.
  InMemoryCheckpointStore({
    this.config = const CheckpointStoreConfig(),
  });

  /// Store configuration.
  final CheckpointStoreConfig config;

  /// Checkpoints organized by thread ID.
  /// Key: threadId, Value: Map of checkpointId -> Checkpoint
  final Map<String, Map<String, Checkpoint<S>>> _checkpoints = {};

  /// Default thread ID for checkpoints without explicit thread.
  static const String _defaultThreadId = '__default__';

  final _uuid = const Uuid();

  @override
  Future<String> save(
    Checkpoint<S> checkpoint, {
    String? threadId,
    String? checkpointId,
  }) async {
    final thread = threadId ?? checkpoint.threadId ?? _defaultThreadId;
    final id = checkpointId ?? checkpoint.id ?? _uuid.v4();

    // Ensure checkpoint has ID and threadId
    final checkpointToSave = checkpoint.id == id && checkpoint.threadId == thread
        ? checkpoint
        : Checkpoint<S>(
            id: id,
            threadId: thread,
            state: checkpoint.state,
            currentNode: checkpoint.currentNode,
            path: checkpoint.path,
            iteration: checkpoint.iteration,
            timestamp: checkpoint.timestamp ?? DateTime.now(),
            metadata: checkpoint.metadata,
            address: checkpoint.address,
            interruptType: checkpoint.interruptType,
            interruptReason: checkpoint.interruptReason,
            pendingInput: checkpoint.pendingInput,
          );

    // Initialize thread bucket if needed
    _checkpoints.putIfAbsent(thread, () => {});

    // Save checkpoint
    _checkpoints[thread]![id] = checkpointToSave;

    // Enforce max checkpoints per thread
    await _enforceLimit(thread);

    return id;
  }

  @override
  Future<Checkpoint<S>?> load(String checkpointId, {String? threadId}) async {
    if (threadId != null) {
      return _checkpoints[threadId]?[checkpointId];
    }

    // Search all threads if no threadId provided
    for (final threadCheckpoints in _checkpoints.values) {
      final checkpoint = threadCheckpoints[checkpointId];
      if (checkpoint != null) {
        return checkpoint;
      }
    }

    return null;
  }

  @override
  Future<Checkpoint<S>?> loadLatest({required String threadId}) async {
    final threadCheckpoints = _checkpoints[threadId];
    if (threadCheckpoints == null || threadCheckpoints.isEmpty) {
      return null;
    }

    // Find checkpoint with latest timestamp
    Checkpoint<S>? latest;
    DateTime? latestTime;

    for (final checkpoint in threadCheckpoints.values) {
      final time = checkpoint.timestamp;
      if (time != null && (latestTime == null || time.isAfter(latestTime))) {
        latest = checkpoint;
        latestTime = time;
      }
    }

    // If no timestamps, return any checkpoint
    return latest ?? threadCheckpoints.values.first;
  }

  @override
  Future<void> delete(String checkpointId, {String? threadId}) async {
    if (threadId != null) {
      _checkpoints[threadId]?.remove(checkpointId);
    } else {
      // Remove from all threads
      for (final threadCheckpoints in _checkpoints.values) {
        threadCheckpoints.remove(checkpointId);
      }
    }
  }

  @override
  Future<List<CheckpointMetadata>> list({String? threadId}) async {
    final results = <CheckpointMetadata>[];

    if (threadId != null) {
      final threadCheckpoints = _checkpoints[threadId];
      if (threadCheckpoints != null) {
        results.addAll(threadCheckpoints.values.map(_toMetadata));
      }
    } else {
      for (final threadCheckpoints in _checkpoints.values) {
        results.addAll(threadCheckpoints.values.map(_toMetadata));
      }
    }

    // Sort by timestamp descending
    results.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return results;
  }

  @override
  Future<void> clear({String? threadId}) async {
    if (threadId != null) {
      _checkpoints.remove(threadId);
    } else {
      _checkpoints.clear();
    }
  }

  @override
  Future<List<Checkpoint<S>>> getHistory({
    required String threadId,
    int? limit,
    DateTime? before,
    DateTime? after,
  }) async {
    final threadCheckpoints = _checkpoints[threadId];
    if (threadCheckpoints == null || threadCheckpoints.isEmpty) {
      return [];
    }

    var results = threadCheckpoints.values.toList();

    // Filter by time range
    if (before != null) {
      results = results.where((c) {
        final time = c.timestamp;
        return time != null && time.isBefore(before);
      }).toList();
    }

    if (after != null) {
      results = results.where((c) {
        final time = c.timestamp;
        return time != null && time.isAfter(after);
      }).toList();
    }

    // Sort by timestamp descending (newest first)
    results.sort((a, b) {
      final timeA = a.timestamp ?? DateTime(0);
      final timeB = b.timestamp ?? DateTime(0);
      return timeB.compareTo(timeA);
    });

    // Apply limit
    if (limit != null && results.length > limit) {
      results = results.sublist(0, limit);
    }

    return results;
  }

  @override
  Future<bool> exists(String checkpointId, {String? threadId}) async {
    if (threadId != null) {
      return _checkpoints[threadId]?.containsKey(checkpointId) ?? false;
    }

    for (final threadCheckpoints in _checkpoints.values) {
      if (threadCheckpoints.containsKey(checkpointId)) {
        return true;
      }
    }

    return false;
  }

  @override
  Future<int> count({String? threadId}) async {
    if (threadId != null) {
      return _checkpoints[threadId]?.length ?? 0;
    }

    var total = 0;
    for (final threadCheckpoints in _checkpoints.values) {
      total += threadCheckpoints.length;
    }
    return total;
  }

  /// Converts a checkpoint to metadata.
  CheckpointMetadata _toMetadata(Checkpoint<S> checkpoint) {
    return CheckpointMetadata(
      id: checkpoint.id ?? '',
      threadId: checkpoint.threadId ?? _defaultThreadId,
      currentNode: checkpoint.currentNode,
      iteration: checkpoint.iteration,
      timestamp: checkpoint.timestamp ?? DateTime.now(),
      interruptType: checkpoint.interruptType,
      interruptReason: checkpoint.interruptReason,
      metadata: checkpoint.metadata,
    );
  }

  /// Enforces the max checkpoints per thread limit.
  Future<void> _enforceLimit(String threadId) async {
    final maxPerThread = config.maxCheckpointsPerThread;
    if (maxPerThread == null) return;

    final threadCheckpoints = _checkpoints[threadId];
    if (threadCheckpoints == null) return;

    while (threadCheckpoints.length > maxPerThread) {
      // Find and remove oldest checkpoint
      String? oldestId;
      DateTime? oldestTime;

      for (final entry in threadCheckpoints.entries) {
        final time = entry.value.timestamp;
        if (time != null && (oldestTime == null || time.isBefore(oldestTime))) {
          oldestId = entry.key;
          oldestTime = time;
        }
      }

      if (oldestId != null) {
        threadCheckpoints.remove(oldestId);
      } else {
        // No timestamps, just remove first entry
        threadCheckpoints.remove(threadCheckpoints.keys.first);
      }
    }
  }

  /// Gets the total number of checkpoints across all threads.
  int get totalCount {
    var total = 0;
    for (final threadCheckpoints in _checkpoints.values) {
      total += threadCheckpoints.length;
    }
    return total;
  }

  /// Gets the number of threads with checkpoints.
  int get threadCount => _checkpoints.length;

  /// Gets all thread IDs with checkpoints.
  List<String> get threadIds => _checkpoints.keys.toList();
}
