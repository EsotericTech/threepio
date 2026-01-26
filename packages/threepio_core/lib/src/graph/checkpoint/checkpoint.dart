import 'package:uuid/uuid.dart';

import '../graph_state.dart';
import 'execution_address.dart';

/// Types of interrupts that can occur during graph execution.
enum InterruptType {
  /// Interrupt before node execution.
  ///
  /// The checkpoint captures state before the node runs.
  beforeNode,

  /// Interrupt after node execution.
  ///
  /// The checkpoint captures state after the node completes.
  afterNode,

  /// Human-in-the-loop interrupt requiring input.
  ///
  /// Execution pauses waiting for external input before continuing.
  humanInput,

  /// Conditional interrupt based on state.
  ///
  /// A condition in the graph triggered an interrupt.
  conditional,

  /// Manual interrupt via API call.
  ///
  /// External code explicitly requested an interrupt.
  manual,

  /// Error-triggered interrupt.
  ///
  /// An error occurred and the checkpoint was saved for recovery.
  error,
}

/// A checkpoint in graph execution with enhanced interrupt support.
///
/// Checkpoints allow you to save and resume graph execution state.
/// They are useful for:
/// - Long-running workflows that need persistence
/// - Human-in-the-loop patterns where execution pauses for input
/// - Error recovery and debugging
/// - Distributed execution across multiple processes
///
/// Example:
/// ```dart
/// // Create a checkpoint at current execution point
/// final checkpoint = Checkpoint<MyState>.now(
///   state: currentState,
///   currentNode: 'review',
///   path: ['fetch', 'process'],
///   iteration: 2,
///   interruptType: InterruptType.humanInput,
///   interruptReason: 'Awaiting user approval',
/// );
///
/// // Save to store
/// await store.save(checkpoint, threadId: 'user-123');
///
/// // Later, resume execution
/// final loaded = await store.loadLatest(threadId: 'user-123');
/// ```
class Checkpoint<S extends GraphState> {
  /// Creates a checkpoint.
  const Checkpoint({
    required this.state,
    required this.currentNode,
    required this.path,
    required this.iteration,
    this.id,
    this.threadId,
    this.timestamp,
    this.metadata = const {},
    this.address,
    this.interruptType,
    this.interruptReason,
    this.pendingInput,
  });

  /// Unique identifier for this checkpoint.
  ///
  /// Auto-generated if not provided when saving.
  final String? id;

  /// Thread ID for isolation.
  ///
  /// Checkpoints with different thread IDs are isolated from each other.
  /// Useful for multi-tenant scenarios or user-specific workflows.
  final String? threadId;

  /// Current state at this checkpoint.
  final S state;

  /// Current node being executed.
  ///
  /// For beforeNode interrupts, this is the node about to execute.
  /// For afterNode interrupts, this is the node that just completed.
  final String currentNode;

  /// Path taken so far (list of executed node names).
  final List<String> path;

  /// Current iteration number.
  ///
  /// Tracks how many nodes have been executed to prevent infinite loops.
  final int iteration;

  /// When this checkpoint was created.
  final DateTime? timestamp;

  /// Additional metadata.
  ///
  /// Store arbitrary data like user IDs, request IDs, or debug info.
  final Map<String, dynamic> metadata;

  /// Precise execution address (for nested graphs).
  ///
  /// Provides complete context about where in the graph hierarchy
  /// execution was interrupted.
  final ExecutionAddress? address;

  /// Type of interrupt that caused this checkpoint.
  ///
  /// Null if checkpoint was created for other reasons (e.g., periodic save).
  final InterruptType? interruptType;

  /// Reason for interrupt (human-readable).
  ///
  /// Useful for displaying to users or logging.
  final String? interruptReason;

  /// Pending input for human-in-the-loop patterns.
  ///
  /// When resuming from a humanInput interrupt, this field can contain
  /// the input provided by the user/external system.
  final dynamic pendingInput;

  /// Whether this checkpoint was created due to an interrupt.
  bool get isInterrupt => interruptType != null;

  /// Whether this checkpoint is awaiting human input.
  bool get isAwaitingInput => interruptType == InterruptType.humanInput;

  /// Creates a checkpoint with the current timestamp.
  factory Checkpoint.now({
    required S state,
    required String currentNode,
    required List<String> path,
    required int iteration,
    String? id,
    String? threadId,
    Map<String, dynamic>? metadata,
    ExecutionAddress? address,
    InterruptType? interruptType,
    String? interruptReason,
    dynamic pendingInput,
  }) {
    return Checkpoint<S>(
      id: id ?? const Uuid().v4(),
      threadId: threadId,
      state: state,
      currentNode: currentNode,
      path: List.unmodifiable(path),
      iteration: iteration,
      timestamp: DateTime.now(),
      metadata: metadata ?? const {},
      address: address,
      interruptType: interruptType,
      interruptReason: interruptReason,
      pendingInput: pendingInput,
    );
  }

  /// Creates a copy with pending input for resumption.
  Checkpoint<S> withPendingInput(dynamic input) {
    return Checkpoint<S>(
      id: id,
      threadId: threadId,
      state: state,
      currentNode: currentNode,
      path: path,
      iteration: iteration,
      timestamp: timestamp,
      metadata: metadata,
      address: address,
      interruptType: interruptType,
      interruptReason: interruptReason,
      pendingInput: input,
    );
  }

  /// Creates a copy with updated metadata.
  Checkpoint<S> withMetadata(Map<String, dynamic> newMetadata) {
    return Checkpoint<S>(
      id: id,
      threadId: threadId,
      state: state,
      currentNode: currentNode,
      path: path,
      iteration: iteration,
      timestamp: timestamp,
      metadata: {...metadata, ...newMetadata},
      address: address,
      interruptType: interruptType,
      interruptReason: interruptReason,
      pendingInput: pendingInput,
    );
  }

  /// Creates a copy with a new ID.
  Checkpoint<S> withId(String newId) {
    return Checkpoint<S>(
      id: newId,
      threadId: threadId,
      state: state,
      currentNode: currentNode,
      path: path,
      iteration: iteration,
      timestamp: timestamp,
      metadata: metadata,
      address: address,
      interruptType: interruptType,
      interruptReason: interruptReason,
      pendingInput: pendingInput,
    );
  }

  /// Creates a copy with a new thread ID.
  Checkpoint<S> withThreadId(String newThreadId) {
    return Checkpoint<S>(
      id: id,
      threadId: newThreadId,
      state: state,
      currentNode: currentNode,
      path: path,
      iteration: iteration,
      timestamp: timestamp,
      metadata: metadata,
      address: address,
      interruptType: interruptType,
      interruptReason: interruptReason,
      pendingInput: pendingInput,
    );
  }

  @override
  String toString() {
    final interrupt =
        isInterrupt ? ', interrupt: ${interruptType?.name}' : '';
    final thread = threadId != null ? ', thread: $threadId' : '';
    return 'Checkpoint(id: $id, node: $currentNode, '
        'iteration: $iteration, path: ${path.length} steps$interrupt$thread)';
  }
}

/// Metadata about a stored checkpoint (without full state).
///
/// Used for listing checkpoints without loading the full state.
class CheckpointMetadata {
  /// Creates checkpoint metadata.
  const CheckpointMetadata({
    required this.id,
    required this.threadId,
    required this.currentNode,
    required this.iteration,
    required this.timestamp,
    this.interruptType,
    this.interruptReason,
    this.metadata = const {},
  });

  /// Unique identifier.
  final String id;

  /// Thread ID.
  final String threadId;

  /// Current node at checkpoint time.
  final String currentNode;

  /// Iteration count at checkpoint time.
  final int iteration;

  /// When the checkpoint was created.
  final DateTime timestamp;

  /// Type of interrupt (if any).
  final InterruptType? interruptType;

  /// Reason for interrupt (if any).
  final String? interruptReason;

  /// Additional metadata.
  final Map<String, dynamic> metadata;

  /// Whether this checkpoint is an interrupt.
  bool get isInterrupt => interruptType != null;

  @override
  String toString() {
    return 'CheckpointMetadata(id: $id, node: $currentNode, '
        'thread: $threadId, timestamp: $timestamp)';
  }
}
