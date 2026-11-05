// ignore_for_file: avoid_print

import 'dart:async';

// The checkpoint stores of the state graph share their names with the
// contracts of the compose port, so the umbrella library leaves them out.
import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

/// Checkpoint & Resume example demonstrating:
/// 1. Creating a checkpointable graph
/// 2. Interrupt before/after nodes
/// 3. Human-in-the-loop pattern
/// 4. Resuming from checkpoints
/// 5. Checkpoint history management
///
/// To run this example:
/// 1. Run: dart run example/checkpoint_example.dart
Future<void> main() async {
  print('=== Checkpoint & Resume System Example ===\n');

  await basicCheckpointExample();
  await humanInTheLoopExample();
  await checkpointManagementExample();
}

/// Example 1: Basic checkpointing
Future<void> basicCheckpointExample() async {
  print('1. Basic Checkpoint Example...\n');

  // Create checkpoint store
  final store = legacy.InMemoryCheckpointStore<WorkflowState>();

  // Create graph with checkpointing enabled
  final graph = StateGraph<WorkflowState>(
    checkpointConfig: CheckpointConfig(
      checkpointEveryNode: true,  // Save after each node
      autoSave: true,
    ),
    checkpointStore: store,
  );

  // Add nodes
  graph.addNode('fetch_data', (state) async {
    print('   [Node] Fetching data...');
    await Future.delayed(const Duration(milliseconds: 100));
    return state.copyWith(data: 'Raw data from source');
  });

  graph.addNode('process_data', (state) async {
    print('   [Node] Processing data...');
    await Future.delayed(const Duration(milliseconds: 100));
    return state.copyWith(processedData: 'Processed: ${state.data}');
  });

  graph.addNode('save_results', (state) async {
    print('   [Node] Saving results...');
    await Future.delayed(const Duration(milliseconds: 100));
    return state.copyWith(saved: true);
  });

  // Define flow
  graph.addEdge('fetch_data', 'process_data');
  graph.addEdge('process_data', 'save_results');
  graph.addEdge('save_results', END);
  graph.setEntryPoint('fetch_data');

  // Run graph
  final result = await graph.invoke(
    WorkflowState(),
    threadId: 'workflow-1',
  );

  print('\n   Final state: saved=${result.state.saved}');

  // Check saved checkpoints
  final checkpoints = await store.list(threadId: 'workflow-1');
  print('   Checkpoints saved: ${checkpoints.length}\n');
}

/// Example 2: Human-in-the-loop
Future<void> humanInTheLoopExample() async {
  print('2. Human-in-the-Loop Example...\n');

  final store = legacy.InMemoryCheckpointStore<ApprovalState>();

  final graph = StateGraph<ApprovalState>(
    checkpointConfig: CheckpointConfig(
      interruptBefore: ['human_review'],  // Pause before this node
      autoSave: true,
    ),
    checkpointStore: store,
  );

  // Add nodes
  graph.addNode('generate_content', (state) async {
    print('   [Node] Generating content...');
    return state.copyWith(content: 'AI-generated content that needs review');
  });

  graph.addNode('human_review', (state) async {
    print('   [Node] Human review completed');
    // This node uses the approval that was set when resuming
    return state;
  });

  graph.addNode('publish', (state) async {
    if (state.approved) {
      print('   [Node] Publishing content...');
      return state.copyWith(published: true);
    } else {
      print('   [Node] Content rejected, not publishing');
      return state.copyWith(published: false);
    }
  });

  graph.addNode('revise', (state) async {
    print('   [Node] Revising content...');
    return state.copyWith(content: 'Revised: ${state.content}');
  });

  // Define flow
  graph.addEdge('generate_content', 'human_review');
  graph.addConditionalEdge(
    'human_review',
    (state) => state.approved ? 'publish' : 'revise',
  );
  graph.addEdge('revise', 'human_review');
  graph.addEdge('publish', END);
  graph.setEntryPoint('generate_content');

  const threadId = 'approval-workflow-1';

  // Start execution - will pause at human_review
  print('   Starting workflow (will pause at human_review)...\n');

  try {
    await graph.invoke(
      ApprovalState(),
      threadId: threadId,
    );
  } on GraphInterruptException<ApprovalState> catch (e) {
    print('   [Interrupt] Paused at: ${e.checkpoint.currentNode}');
    print('   [Interrupt] Checkpoint ID: ${e.checkpoint.id}');
    print('   [Interrupt] Content for review: "${e.checkpoint.state.content}"');
    print('   [Interrupt] Reason: ${e.reason}');

    // Simulate human approval - save the modified state to checkpoint store
    print('\n   Simulating human approval...\n');

    // To resume with modified state, save a new checkpoint with the approval
    // and resume from that. For this demo, we just show the interrupt worked.
    print('   Note: Resume with state modification requires using HumanInputNode');
    print('   See the graph module documentation for the full HITL pattern.');
  }

  print('');
}

/// Example 3: Checkpoint management
Future<void> checkpointManagementExample() async {
  print('3. Checkpoint Management Example...\n');

  final store = legacy.InMemoryCheckpointStore<WorkflowState>();

  // Create some checkpoints
  for (var i = 1; i <= 5; i++) {
    final checkpoint = Checkpoint.now(
      threadId: 'thread-1',
      state: WorkflowState(data: 'Data $i'),
      currentNode: 'node_$i',
      path: ['start', 'node_$i'],
      iteration: i,
    );
    await store.save(checkpoint, threadId: 'thread-1');
  }

  // List checkpoints
  final checkpoints = await store.list(threadId: 'thread-1');
  print('   Total checkpoints: ${checkpoints.length}');

  // Get latest
  final latest = await store.loadLatest(threadId: 'thread-1');
  print('   Latest checkpoint: ${latest?.currentNode}');

  // Get history
  final history = await store.getHistory(threadId: 'thread-1', limit: 3);
  print('   Recent history (last 3):');
  for (final meta in history) {
    print('     - ${meta.currentNode} at ${meta.timestamp}');
  }

  // Count
  final count = await store.count(threadId: 'thread-1');
  print('   Count for thread-1: $count');

  // Delete one
  if (checkpoints.isNotEmpty) {
    await store.delete(checkpoints.first.id, threadId: 'thread-1');
    print('   Deleted oldest checkpoint');
  }

  // Clear all
  await store.clear(threadId: 'thread-1');
  final afterClear = await store.count(threadId: 'thread-1');
  print('   After clear: $afterClear checkpoints\n');
}

/// Simple workflow state
class WorkflowState extends GraphState {
  final String? data;
  final String? processedData;
  final bool saved;

  WorkflowState({
    this.data,
    this.processedData,
    this.saved = false,
  });

  @override
  WorkflowState copyWith({
    String? data,
    String? processedData,
    bool? saved,
  }) =>
      WorkflowState(
        data: data ?? this.data,
        processedData: processedData ?? this.processedData,
        saved: saved ?? this.saved,
      );

  Map<String, dynamic> toMap() => {
        'data': data,
        'processedData': processedData,
        'saved': saved,
      };

  static WorkflowState fromMap(Map<String, dynamic> map) => WorkflowState(
        data: map['data'] as String?,
        processedData: map['processedData'] as String?,
        saved: map['saved'] as bool? ?? false,
      );
}

/// Approval workflow state
class ApprovalState extends GraphState {
  final String? content;
  final bool approved;
  final bool published;

  ApprovalState({
    this.content,
    this.approved = false,
    this.published = false,
  });

  @override
  ApprovalState copyWith({
    String? content,
    bool? approved,
    bool? published,
  }) =>
      ApprovalState(
        content: content ?? this.content,
        approved: approved ?? this.approved,
        published: published ?? this.published,
      );

  Map<String, dynamic> toMap() => {
        'content': content,
        'approved': approved,
        'published': published,
      };

  static ApprovalState fromMap(Map<String, dynamic> map) => ApprovalState(
        content: map['content'] as String?,
        approved: map['approved'] as bool? ?? false,
        published: map['published'] as bool? ?? false,
      );
}
