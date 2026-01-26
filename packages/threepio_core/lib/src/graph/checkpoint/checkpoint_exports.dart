/// Checkpoint and resume system for graph execution.
///
/// This module provides fault-tolerant graph execution with:
/// - State persistence at configurable points
/// - Interrupt and resume capabilities
/// - Human-in-the-loop patterns
/// - Multiple storage backends
///
/// ## Quick Start
///
/// ```dart
/// import 'package:threepio_core/threepio_core.dart';
///
/// // Create a checkpoint store
/// final store = InMemoryCheckpointStore<MyState>();
///
/// // Configure graph with checkpoints
/// final graph = StateGraph<MyState>(
///   checkpointStore: store,
///   checkpointConfig: CheckpointConfig(
///     interruptBefore: ['human_review'],
///     autoSave: true,
///   ),
/// );
///
/// // Execute - will interrupt at configured points
/// try {
///   await graph.invoke(initialState, threadId: 'user-123');
/// } on GraphInterruptException<MyState> catch (e) {
///   // Handle interrupt, save checkpoint ID for later
///   final id = e.checkpoint.id;
///
///   // Later, resume execution
///   await graph.invoke(
///     MyState(),
///     checkpointId: id,
///     threadId: 'user-123',
///   );
/// }
/// ```
///
/// ## Human-in-the-Loop
///
/// ```dart
/// // Define a HITL node
/// final approvalNode = HumanInputNode<MyState, bool>(
///   name: 'approval',
///   prompt: (state) => 'Approve: ${state.summary}?',
///   processInput: (state, approved) => state.copyWith(approved: approved),
/// );
///
/// graph.addHumanInputNode(approvalNode);
///
/// // Handle human input required
/// try {
///   await graph.invoke(initialState);
/// } on HumanInputRequired<MyState, bool> catch (e) {
///   print(e.prompt);
///   final userInput = await getUserApproval();
///   await graph.resumeWithHumanInput<bool>(
///     e.checkpoint.id!,
///     input: userInput,
///   );
/// }
/// ```

export 'checkpoint.dart';
export 'checkpoint_config.dart';
export 'checkpoint_store.dart';
export 'exceptions.dart';
export 'execution_address.dart';
export 'hitl.dart';
export 'serializer.dart';
export 'stores/stores_exports.dart';
