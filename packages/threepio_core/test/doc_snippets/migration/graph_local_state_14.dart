// Mirror of doc/MIGRATION.md, legacy: Graph with local state (after).
// ignore_for_file: avoid_print
import 'package:threepio_core/compose.dart';

/// The state of one run (Go `compose.WithGenLocalState`).
final class Rounds {
  int count = 0;
}

Future<String> reviseWithGraph(String draft) async {
  final graph = Graph<String, String>(
    localState: LocalState.of<Rounds>((ctx) => Rounds()),
  )
    ..addLambdaNode(
      'write',
      Lambda.invokable((RunContext ctx, String text) => '$text, revised'),
      options: NodeOptions(
        statePreHandler: StateHandler.pre<String, Rounds>((ctx, input, state) {
          state.count++;
          return input;
        }),
      ),
    )
    ..addEdge(Graph.start, 'write')
    ..addBranch(
      'write',
      GraphBranch.single<String>((ctx, text) async {
        var rounds = 0;
        await processState<Rounds>(ctx, (ctx, state) {
          rounds = state.count;
        });
        return rounds >= 3 ? Graph.end : 'write';
      }, {'write', Graph.end}),
    );

  final ctx = RunContext.background();
  final runnable = await graph.compile(
    ctx,
    options: const GraphCompileOptions(maxRunSteps: 10),
  );
  return runnable.invoke(ctx, draft);
}
