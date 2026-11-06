// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 3, "Creating a Checkpointable Graph".

import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

import 'checkpoint_state_30.dart';

/// Stands in for the application's document generator.
Future<String> generateDocument() async => 'A draft';

/// Stands in for the application's analysis.
Future<String> analyzeDocument(String document) async => 'Analysis of $document';

StateGraph<WorkflowState> buildReviewGraph(
  legacy.CheckpointStore<WorkflowState> store,
) {
  final graph = StateGraph<WorkflowState>(
    checkpointConfig: const CheckpointConfig(
      interruptAfter: ['analyze'], // pause once the analysis is ready
      autoSave: true,
    ),
    checkpointStore: store,
  );

  graph.addNode('generate', (state) async {
    final doc = await generateDocument();
    return state.copyWith(document: doc);
  });

  graph.addNode('analyze', (state) async {
    final analysis = await analyzeDocument(state.document!);
    return state.copyWith(analysis: analysis);
  });

  // Stops the run until someone approves or rejects (see below)
  graph.addHumanInputNode(
    HumanInputNode<WorkflowState, bool>(
      name: 'human_review',
      prompt: (state) => 'Approve this analysis? ${state.analysis}',
      processInput: (state, approved) => state.copyWith(approved: approved),
    ),
  );

  graph.addNode('finalize', (state) async {
    return state.copyWith(review: 'Approved and finalized');
  });

  graph.addEdge('generate', 'analyze');
  graph.addEdge('analyze', 'human_review');
  graph.addConditionalEdge(
    'human_review',
    (state) => state.approved ? 'finalize' : 'generate',
  );
  graph.addEdge('finalize', END); // Use END constant

  graph.setEntryPoint('generate');
  return graph;
}
