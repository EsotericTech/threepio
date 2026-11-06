// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 3, "Checkpoint History and Management".
// ignore_for_file: avoid_print

import 'package:threepio_core/legacy_graph.dart' as legacy;

import 'checkpoint_state_30.dart';

Future<void> history(
  legacy.CheckpointStore<WorkflowState> store,
  String oldCheckpointId,
) async {
  // List all checkpoints for a thread
  final checkpoints = await store.list(threadId: 'user-123');
  for (final metadata in checkpoints) {
    print('${metadata.id}: ${metadata.currentNode} at ${metadata.timestamp}');
  }

  // Get checkpoint history (newest first)
  final history = await store.getHistory(
    threadId: 'user-123',
    limit: 10,
    after: DateTime.now().subtract(const Duration(hours: 1)),
  );
  for (final checkpoint in history) {
    print('${checkpoint.currentNode} (step ${checkpoint.iteration})');
  }

  // Delete old checkpoints
  await store.delete(oldCheckpointId, threadId: 'user-123');

  // Clear all checkpoints for a thread
  await store.clear(threadId: 'user-123');

  // Count checkpoints
  final count = await store.count(threadId: 'user-123');
  print('Checkpoints left: $count');
}
