// Mirror of the README quick start "4. A graph with state".
// ignore_for_file: avoid_print
import 'package:threepio_core/compose.dart';

/// The state of one run (Eino `compose.WithGenLocalState`).
final class DraftState {
  int round = 0;
  final List<String> drafts = [];
}

Future<void> main() async {
  final graph = Graph<String, String>(
    localState: LocalState.of<DraftState>((ctx) => DraftState()),
  )
    ..addLambdaNode(
      'write',
      Lambda.invokable((RunContext ctx, String text) => '$text, revised'),
      options: NodeOptions(
        // Before the node runs (Eino `WithStatePreHandler`).
        statePreHandler: StateHandler.pre<String, DraftState>(
          (ctx, input, state) {
            state.round++;
            return input;
          },
        ),
        // After it ran (Eino `WithStatePostHandler`).
        statePostHandler: StateHandler.post<String, DraftState>(
          (ctx, output, state) {
            state.drafts.add(output);
            return output;
          },
        ),
      ),
    )
    ..addLambdaNode(
      'review',
      Lambda.invokable((RunContext ctx, String draft) => '$draft (reviewed)'),
    )
    ..addEdge(Graph.start, 'write')
    ..addEdge('write', 'review')
    // A branch reads the state with processState (Eino `ProcessState`).
    ..addBranch(
      'review',
      GraphBranch.single<String>((ctx, draft) async {
        var round = 0;
        await processState<DraftState>(ctx, (ctx, state) {
          round = state.round;
        });
        return round >= 3 ? Graph.end : 'write';
      }, {'write', Graph.end}),
    );

  final ctx = RunContext.background();
  final runnable = await graph.compile(
    ctx,
    options: const GraphCompileOptions(maxRunSteps: 10),
  );
  print(await runnable.invoke(ctx, 'A first draft'));
  print(graph.toMermaid());
}
