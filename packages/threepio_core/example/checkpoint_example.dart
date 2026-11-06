// ignore_for_file: avoid_print

/// Checkpoints of the legacy `StateGraph`.
///
/// **Legacy API (before 0.9).** `StateGraph` and its checkpoint stores
/// predate the port of Eino's `compose` package; they stay for the code that
/// uses them. New code uses the checkpoints of
/// `package:threepio_core/compose.dart`: a `CheckpointStore` in
/// `GraphCompileOptions(checkpointStore: …)`, interrupts with
/// `GraphCompileOptions(interruptBeforeNodes: …)` or
/// `throw interrupt(ctx, info)` in a node, and resume by running the graph
/// again with `CallOption.checkpointId(…)` (Go: `compose.WithCheckPointStore`,
/// `WithInterruptBeforeNodes`, `compose.Interrupt`, `WithCheckPointID`); see
/// doc/GRAPHS.md.
///
/// The example shows:
/// 1. A graph that saves a checkpoint after every node
/// 2. Human in the loop: a `HumanInputNode` pauses the run, and
///    `resumeWithHumanInput` continues it from the saved checkpoint with the
///    human's answer
/// 3. Managing the checkpoints of a thread: list, latest, history, count,
///    delete, clear
///
/// To run this example (no API key needed):
///
/// ```bash
/// dart run example/checkpoint_example.dart
/// ```
library;

import 'dart:async';

// The checkpoint stores of the state graph share their names with the
// contracts of the compose port, so the umbrella library leaves them out.
import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

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

  // Create graph with checkpointing enabled, then add the nodes and edges
  final graph = StateGraph<WorkflowState>(
    checkpointConfig: const CheckpointConfig(
      checkpointEveryNode: true, // Save after each node
      autoSave: true,
    ),
    checkpointStore: store,
  )
    ..addNode('fetch_data', (state) async {
      print('   [Node] Fetching data...');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return state.copyWith(data: 'Raw data from source');
    })
    ..addNode('process_data', (state) async {
      print('   [Node] Processing data...');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return state.copyWith(processedData: 'Processed: ${state.data}');
    })
    ..addNode('save_results', (state) async {
      print('   [Node] Saving results...');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return state.copyWith(saved: true);
    })
    // Define flow
    ..addEdge('fetch_data', 'process_data')
    ..addEdge('process_data', 'save_results')
    ..addEdge('save_results', END)
    ..setEntryPoint('fetch_data');

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

  // The review step: the run stops here until a human answers. The answer
  // (a bool) is turned into state by processInput when the run resumes.
  final review = HumanInputNode<ApprovalState, bool>(
    name: 'human_review',
    prompt: (state) => 'Approve "${state.content}"?',
    processInput: (state, approved) => state.copyWith(approved: approved),
  );

  final graph = StateGraph<ApprovalState>(
    // autoSave stores the checkpoint the human input resumes from.
    checkpointConfig: const CheckpointConfig(autoSave: true),
    checkpointStore: store,
  )
    ..addNode('generate_content', (state) async {
      print('   [Node] Generating content...');
      return state.copyWith(content: 'AI-generated content that needs review');
    })
    ..addHumanInputNode(review)
    ..addNode('publish', (state) async {
      print('   [Node] Publishing content...');
      return state.copyWith(published: true);
    })
    ..addNode('revise', (state) async {
      print('   [Node] Revising content...');
      return state.copyWith(content: 'Revised: ${state.content}');
    })
    // Define flow
    ..addEdge('generate_content', 'human_review')
    ..addConditionalEdge(
      'human_review',
      (state) => state.approved ? 'publish' : 'revise',
    )
    ..addEdge('revise', 'human_review')
    ..addEdge('publish', END)
    ..setEntryPoint('generate_content');

  const threadId = 'approval-workflow-1';

  // Start execution - will pause at human_review
  print('   Starting workflow (will pause at human_review)...\n');

  try {
    await graph.invoke(ApprovalState(), threadId: threadId);
    print('   The workflow finished without asking for review.');
  } on HumanInputRequired<ApprovalState, dynamic> catch (e) {
    // The graph rethrows the request with a dynamic input type, so catch it
    // as HumanInputRequired<ApprovalState, dynamic>.
    print('   [Interrupt] Paused at: ${e.nodeName}');
    print('   [Interrupt] Checkpoint ID: ${e.checkpoint.id}');
    print('   [Interrupt] Question: ${e.prompt}');

    // A real app shows the question and waits for the answer; here the
    // human approves.
    print('\n   Simulating human approval...\n');
    final result = await graph.resumeWithHumanInput<bool>(
      e.checkpoint.id!,
      input: true,
      threadId: threadId,
    );
    print('\n   Final state: approved=${result.state.approved}, '
        'published=${result.state.published}');
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

  // Delete the oldest one (list() returns the newest first)
  if (checkpoints.isNotEmpty) {
    await store.delete(checkpoints.last.id, threadId: 'thread-1');
    print('   Deleted oldest checkpoint');
  }

  // Clear all
  await store.clear(threadId: 'thread-1');
  final afterClear = await store.count(threadId: 'thread-1');
  print('   After clear: $afterClear checkpoints\n');
}

/// Simple workflow state
class WorkflowState extends GraphState {
  WorkflowState({
    this.data,
    this.processedData,
    this.saved = false,
  });

  factory WorkflowState.fromMap(Map<String, dynamic> map) => WorkflowState(
        data: map['data'] as String?,
        processedData: map['processedData'] as String?,
        saved: map['saved'] as bool? ?? false,
      );

  final String? data;
  final String? processedData;
  final bool saved;

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
}

/// Approval workflow state
class ApprovalState extends GraphState {
  ApprovalState({
    this.content,
    this.approved = false,
    this.published = false,
  });

  factory ApprovalState.fromMap(Map<String, dynamic> map) => ApprovalState(
        content: map['content'] as String?,
        approved: map['approved'] as bool? ?? false,
        published: map['published'] as bool? ?? false,
      );

  final String? content;
  final bool approved;
  final bool published;

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
}
