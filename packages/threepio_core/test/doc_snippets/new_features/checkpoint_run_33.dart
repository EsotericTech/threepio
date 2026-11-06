// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 3, "Executing with Checkpoints", "Resuming from Checkpoint" and
// "Human-in-the-Loop Pattern".
// ignore_for_file: avoid_print

import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

import 'checkpoint_graph_32.dart';
import 'checkpoint_state_30.dart';

/// Stands in for the application's notification.
Future<void> notifyUserForApproval(String threadId, String checkpointId) async {}

Future<void> execute() async {
  final store = legacy.InMemoryCheckpointStore<WorkflowState>();
  final graph = buildReviewGraph(store);
  const threadId = 'user-123-workflow-1';

  try {
    await graph.invoke(WorkflowState(), threadId: threadId);
  } on GraphInterruptException<WorkflowState> catch (e) {
    // Execution paused after 'analyze'; the checkpoint is in the store
    print('Paused at: ${e.checkpoint.currentNode}');
    print('Checkpoint ID: ${e.checkpoint.id}');
    print('Reason: ${e.reason}');
  }
}

Future<void> resume(
  legacy.CheckpointStore<WorkflowState> store,
  StateGraph<WorkflowState> graph,
  String threadId,
) async {
  // Later: load the thread's latest checkpoint and go on from there
  final checkpoint = await store.loadLatest(threadId: threadId);

  if (checkpoint != null) {
    try {
      final result = await graph.invoke(
        WorkflowState(), // ignored: the state comes from the checkpoint
        threadId: threadId,
        checkpointId: checkpoint.id,
      );
      print('Workflow completed: ${result.state.review}');
    } on HumanInputRequired<WorkflowState, Object?> catch (e) {
      // The run reached 'human_review' and waits for a decision
      print(e.prompt);
      await notifyUserForApproval(threadId, e.checkpoint.id!);
    }
  }
}

Future<void> handleUserApproval(
  StateGraph<WorkflowState> graph,
  String checkpointId,
  String threadId, {
  required bool approved,
}) async {
  final result = await graph.resumeWithHumanInput<bool>(
    checkpointId,
    input: approved,
    threadId: threadId,
  );
  print('Review: ${result.state.review}');
}
