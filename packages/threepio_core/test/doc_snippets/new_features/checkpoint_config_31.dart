// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 3, "Basic Checkpoint Configuration".
// ignore_for_file: avoid_print

import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

import 'checkpoint_state_30.dart';

void checkpointConfiguration() {
  // Configure checkpointing
  const checkpointConfig = CheckpointConfig(
    interruptAfter: ['analyze'], // Pause after these nodes
    checkpointEveryNode: true,   // Save after each step
    autoSave: true,              // Save interrupt checkpoints to the store
    // checkpointOnError (save when a node throws) is on by default
  );

  // Create checkpoint store
  final store = legacy.InMemoryCheckpointStore<WorkflowState>();

  // Or use file-based persistence
  final fileStore = legacy.FileCheckpointStore<WorkflowState>(
    directory: '/path/to/checkpoints',
    serializer: legacy.JsonCheckpointSerializer<WorkflowState>(
      stateToJson: (state) => state.toMap(),
      stateFromJson: WorkflowState.fromMap,
    ),
    config: const CheckpointStoreConfig(
      maxCheckpointsPerThread: 50, // oldest are dropped; default 100
      compressData: true, // gzip; FileCheckpointStore only
    ),
  );
  print([checkpointConfig, store, fileStore.directory]);
}
