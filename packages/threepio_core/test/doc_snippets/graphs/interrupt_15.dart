// Mirrors "Interrupt from inside a node" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

// #docregion review
/// Asks for approval before a draft goes out.
final review = Lambda<String, String>.invokable((ctx, draft) {
  final previous = getInterruptState<String>(ctx);
  if (!previous.wasInterrupted) {
    // First run: stop here, and keep the draft in the checkpoint.
    throw statefulInterrupt(ctx, 'Send this draft?', draft);
  }
  // Resumed. The input is now '' (see "The input of a node that runs
  // again"); the draft comes back from the saved state.
  final answer = getResumeContext<String>(ctx).data;
  return answer == 'yes' ? previous.state! : 'not sent';
});

Future<String> sendWithApproval(
  RunContext ctx,
  String draft,
  Future<String> Function(Object? question) ask,
) async {
  final graph = Graph<String, String>()
    ..addLambdaNode('review', review)
    ..addEdge(Graph.start, 'review')
    ..addEdge('review', Graph.end);
  final runnable = await graph.compile(
    ctx,
    options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
  );

  final options = [CallOption.checkpointId('draft-42')];
  try {
    return await runnable.invoke(ctx, draft, options: options);
  } on GraphInterruptedException catch (interrupted) {
    final point = interrupted.interruptContexts.single;
    final answer = await ask(point.info); // 'Send this draft?'
    // The same checkpoint id; the context names the point to resume and
    // the data it gets. The input of a resumed call is not read.
    return runnable.invoke(
      ctx.resumeWithData(point.id, answer),
      '',
      options: options,
    );
  }
}
// #enddocregion review

void plainInterrupt() {
  // #docregion plain
  final confirm = Lambda<String, String>.invokable((ctx, input) {
    final resumed = getResumeContext<bool>(ctx);
    if (!resumed.isResumeTarget) throw interrupt(ctx, 'Continue?');
    return (resumed.data ?? false) ? 'confirmed' : 'cancelled';
  });
  // #enddocregion plain
  confirm.toString();
}
