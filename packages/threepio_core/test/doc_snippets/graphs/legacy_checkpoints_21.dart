// Mirrors the legacy checkpoints of doc/GRAPHS.md.
// #docregion checkpoints
import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/threepio_core.dart';

class ReviewState implements GraphState {
  const ReviewState({this.text = '', this.published = false});

  final String text;
  final bool published;

  @override
  ReviewState copyWith({String? text, bool? published}) => ReviewState(
        text: text ?? this.text,
        published: published ?? this.published,
      );
}

Future<ReviewState> draftThenPublish() async {
  // The five checkpoint names of the state graph come from
  // legacy_graph.dart; the umbrella's CheckpointStore is the compose one.
  final store = legacy.InMemoryCheckpointStore<ReviewState>();
  final graph = StateGraph<ReviewState>(
    checkpointStore: store,
    checkpointConfig: const CheckpointConfig(
      interruptAfter: ['draft'],
      autoSave: true,
    ),
  )
    ..addNode('draft', (state) => state.copyWith(text: 'Draft'))
    ..addNode('publish', (state) => state.copyWith(published: true))
    ..addEdge('draft', 'publish')
    ..addEdge('publish', END)
    ..setEntryPoint('draft');

  try {
    return (await graph.invoke(const ReviewState(), threadId: 'doc-1')).state;
  } on GraphInterruptException<ReviewState> catch (interrupted) {
    // Saved because of autoSave; resumes behind 'draft'.
    final resumed = await graph.invoke(
      const ReviewState(),
      checkpointId: interrupted.checkpoint.id,
      threadId: 'doc-1',
    );
    return resumed.state;
  }
}
// #enddocregion checkpoints
