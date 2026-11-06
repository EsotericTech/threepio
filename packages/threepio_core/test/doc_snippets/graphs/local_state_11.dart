// Mirrors "Local state" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

// #docregion state
/// The state of one run.
final class Notes {
  final List<String> lines = [];
}

Future<String> withState(RunContext ctx) async {
  final graph = Graph<String, String>(
    // Go: compose.WithGenLocalState. A new state for every run.
    localState: LocalState.of<Notes>((ctx) => Notes()),
  )
    ..addLambdaNode(
      'work',
      Lambda<String, String>.invokable((ctx, input) async {
        // Go: compose.ProcessState. Calls on one state take turns.
        await processState<Notes>(ctx, (ctx, notes) => notes.lines.add('work'));
        return '$input!';
      }),
      options: NodeOptions(
        // Go: compose.WithStatePreHandler. Sees and may replace the input.
        statePreHandler: StateHandler.pre<String, Notes>((ctx, input, notes) {
          notes.lines.add('before');
          return input;
        }),
        // Go: compose.WithStatePostHandler. Sees and may replace the output.
        statePostHandler: StateHandler.post<String, Notes>(
          (ctx, output, notes) => '$output ${notes.lines.join(',')}',
        ),
      ),
    )
    ..addEdge(Graph.start, 'work')
    ..addEdge('work', Graph.end);
  final runnable = await graph.compile(ctx);
  return runnable.invoke(ctx, 'go'); // 'go! before,work'
}
// #enddocregion state

NodeOptions streamHandler() {
  // #docregion stream-pre
  // Go: compose.WithStreamStatePreHandler. Keeps the input a stream in a
  // streaming run, instead of joining the chunks for the handler.
  return NodeOptions(
    streamStatePreHandler: StateHandler.streamPre<String, Notes>(
      (ctx, input, notes) => input.convert((chunk) {
        notes.lines.add(chunk);
        return chunk;
      }),
    ),
  );
  // #enddocregion stream-pre
}
