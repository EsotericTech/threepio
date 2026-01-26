import '../graph_state.dart';
import 'checkpoint.dart';

/// Exception thrown when graph execution is interrupted.
///
/// Contains the checkpoint at the point of interruption, allowing
/// execution to be resumed later.
///
/// Example handling:
/// ```dart
/// try {
///   await graph.invoke(initialState, threadId: 'user-123');
/// } on GraphInterruptException<MyState> catch (e) {
///   print('Interrupted at: ${e.checkpoint.currentNode}');
///   print('Reason: ${e.reason}');
///
///   // Save checkpoint ID for later resumption
///   final checkpointId = e.checkpoint.id;
///
///   // Later, resume execution
///   final result = await graph.invoke(
///     MyState(), // Ignored, loaded from checkpoint
///     checkpointId: checkpointId,
///     threadId: 'user-123',
///   );
/// }
/// ```
class GraphInterruptException<S extends GraphState> implements Exception {
  /// Creates a graph interrupt exception.
  GraphInterruptException({
    required this.checkpoint,
    required this.reason,
  });

  /// Checkpoint at the point of interruption.
  ///
  /// Contains all state needed to resume execution.
  final Checkpoint<S> checkpoint;

  /// Human-readable reason for the interrupt.
  final String reason;

  /// The checkpoint ID (convenience getter).
  String? get checkpointId => checkpoint.id;

  /// The node where execution was interrupted.
  String get interruptedNode => checkpoint.currentNode;

  /// The type of interrupt.
  InterruptType? get interruptType => checkpoint.interruptType;

  @override
  String toString() {
    return 'GraphInterruptException: $reason (node: ${checkpoint.currentNode})';
  }
}

/// Exception thrown when a checkpoint is not found.
class CheckpointNotFoundException implements Exception {
  /// Creates a checkpoint not found exception.
  CheckpointNotFoundException(this.checkpointId, {this.threadId});

  /// The checkpoint ID that was not found.
  final String checkpointId;

  /// The thread ID that was searched (if any).
  final String? threadId;

  @override
  String toString() {
    final thread = threadId != null ? ' in thread $threadId' : '';
    return 'CheckpointNotFoundException: Checkpoint "$checkpointId" not found$thread';
  }
}

/// Exception thrown when a checkpoint is corrupted or invalid.
class CheckpointCorruptedException implements Exception {
  /// Creates a checkpoint corrupted exception.
  CheckpointCorruptedException(this.checkpointId, {this.cause});

  /// The checkpoint ID that was corrupted.
  final String checkpointId;

  /// The underlying cause (if any).
  final dynamic cause;

  @override
  String toString() {
    final causePart = cause != null ? ': $cause' : '';
    return 'CheckpointCorruptedException: Checkpoint "$checkpointId" is corrupted$causePart';
  }
}

/// Exception thrown when checkpoint store operations fail.
class CheckpointStoreException implements Exception {
  /// Creates a checkpoint store exception.
  CheckpointStoreException(this.message, {this.operation, this.cause});

  /// Error message.
  final String message;

  /// The operation that failed (e.g., 'save', 'load', 'delete').
  final String? operation;

  /// The underlying cause (if any).
  final dynamic cause;

  @override
  String toString() {
    final opPart = operation != null ? ' during $operation' : '';
    final causePart = cause != null ? ': $cause' : '';
    return 'CheckpointStoreException$opPart: $message$causePart';
  }
}

/// Exception thrown when trying to resume from an incompatible checkpoint.
class CheckpointIncompatibleException implements Exception {
  /// Creates a checkpoint incompatible exception.
  CheckpointIncompatibleException(this.message, {this.checkpointId});

  /// Error message describing the incompatibility.
  final String message;

  /// The checkpoint ID (if known).
  final String? checkpointId;

  @override
  String toString() {
    final idPart = checkpointId != null ? ' (checkpoint: $checkpointId)' : '';
    return 'CheckpointIncompatibleException: $message$idPart';
  }
}

/// Exception thrown when max iterations is reached during checkpointed execution.
class MaxIterationsExceededException implements Exception {
  /// Creates a max iterations exceeded exception.
  MaxIterationsExceededException({
    required this.maxIterations,
    required this.currentNode,
    this.checkpoint,
  });

  /// The maximum iterations limit.
  final int maxIterations;

  /// The node where execution stopped.
  final String currentNode;

  /// The checkpoint at time of exceeding limit (if available).
  final Checkpoint? checkpoint;

  @override
  String toString() {
    return 'MaxIterationsExceededException: '
        'Exceeded $maxIterations iterations at node "$currentNode"';
  }
}
