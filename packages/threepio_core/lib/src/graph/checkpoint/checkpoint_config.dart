import 'checkpoint.dart';

/// Configuration for checkpoint behavior in StateGraph.
///
/// Controls when and how checkpoints are created during graph execution.
///
/// Example:
/// ```dart
/// final config = CheckpointConfig(
///   interruptBefore: ['human_review', 'approval'],
///   interruptAfter: ['process_payment'],
///   checkpointEveryNode: false,
///   autoSave: true,
/// );
///
/// final graph = StateGraph<MyState>(
///   checkpointConfig: config,
///   checkpointStore: myStore,
/// );
/// ```
class CheckpointConfig {
  /// Creates a checkpoint configuration.
  const CheckpointConfig({
    this.interruptBefore = const [],
    this.interruptAfter = const [],
    this.checkpointEveryNode = false,
    this.checkpointOnError = true,
    this.autoSave = false,
    this.threadIdProvider,
    this.graphId,
  });

  /// Node names to interrupt BEFORE executing.
  ///
  /// When execution reaches one of these nodes, a checkpoint is created
  /// and [GraphInterruptException] is thrown with [InterruptType.beforeNode].
  /// The node has NOT been executed yet.
  final List<String> interruptBefore;

  /// Node names to interrupt AFTER executing.
  ///
  /// When execution completes one of these nodes, a checkpoint is created
  /// and [GraphInterruptException] is thrown with [InterruptType.afterNode].
  /// The node HAS been executed and its state changes are included.
  final List<String> interruptAfter;

  /// Create checkpoint after every node execution.
  ///
  /// Useful for debugging and detailed audit trails.
  /// May impact performance for large graphs.
  final bool checkpointEveryNode;

  /// Create checkpoint on error for recovery.
  ///
  /// If enabled, when an error occurs during execution, a checkpoint
  /// is created before the error is propagated.
  final bool checkpointOnError;

  /// Automatically save checkpoints to store.
  ///
  /// If false, checkpoints are only returned in exceptions
  /// and not persisted to the store.
  final bool autoSave;

  /// Function to provide thread ID for checkpoint isolation.
  ///
  /// If not provided, a default thread ID is used.
  final String Function()? threadIdProvider;

  /// Custom graph ID.
  ///
  /// If not provided, a UUID is generated.
  final String? graphId;

  /// Creates a copy with modified fields.
  CheckpointConfig copyWith({
    List<String>? interruptBefore,
    List<String>? interruptAfter,
    bool? checkpointEveryNode,
    bool? checkpointOnError,
    bool? autoSave,
    String Function()? threadIdProvider,
    String? graphId,
  }) {
    return CheckpointConfig(
      interruptBefore: interruptBefore ?? this.interruptBefore,
      interruptAfter: interruptAfter ?? this.interruptAfter,
      checkpointEveryNode: checkpointEveryNode ?? this.checkpointEveryNode,
      checkpointOnError: checkpointOnError ?? this.checkpointOnError,
      autoSave: autoSave ?? this.autoSave,
      threadIdProvider: threadIdProvider ?? this.threadIdProvider,
      graphId: graphId ?? this.graphId,
    );
  }

  /// Whether any interrupt points are configured.
  bool get hasInterrupts =>
      interruptBefore.isNotEmpty || interruptAfter.isNotEmpty;

  /// Checks if a node should interrupt before execution.
  bool shouldInterruptBefore(String nodeName) =>
      interruptBefore.contains(nodeName);

  /// Checks if a node should interrupt after execution.
  bool shouldInterruptAfter(String nodeName) =>
      interruptAfter.contains(nodeName);

  @override
  String toString() {
    return 'CheckpointConfig('
        'interruptBefore: $interruptBefore, '
        'interruptAfter: $interruptAfter, '
        'everyNode: $checkpointEveryNode, '
        'autoSave: $autoSave)';
  }
}

/// Options for resuming from a checkpoint.
class ResumeOptions {
  /// Creates resume options.
  const ResumeOptions({
    this.skipToNode,
    this.modifyState,
    this.additionalMetadata,
  });

  /// Skip execution to a specific node.
  ///
  /// If provided, execution starts at this node instead of
  /// the checkpoint's current node.
  final String? skipToNode;

  /// Modify state before resuming.
  ///
  /// If provided, this function is called to modify the state
  /// before execution continues.
  final dynamic Function(dynamic state)? modifyState;

  /// Additional metadata to include in the resumed execution.
  final Map<String, dynamic>? additionalMetadata;
}
