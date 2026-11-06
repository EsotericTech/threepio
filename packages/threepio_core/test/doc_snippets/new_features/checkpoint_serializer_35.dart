// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 3, "Custom State Serialization".
// ignore_for_file: avoid_print

import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

import 'checkpoint_state_30.dart';

Future<void> serialization(Checkpoint<WorkflowState> checkpoint) async {
  final serializer = legacy.JsonCheckpointSerializer<WorkflowState>(
    stateToJson: (state) => state.toMap(),
    stateFromJson: WorkflowState.fromMap,
  );

  final bytes = await serializer.serialize(checkpoint);
  final restored = await serializer.deserialize(bytes);
  print(restored.state.document);
}
