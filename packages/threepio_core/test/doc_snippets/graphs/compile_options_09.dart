// Mirrors "Compiling: options and trigger modes" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

Future<int> stepLimit(RunContext ctx) async {
  // #docregion steps
  // A loop: 'inc' runs again until the branch leads to the end.
  final graph = Graph<int, int>()
    ..addLambdaNode('inc', Lambda<int, int>.invokable((ctx, i) => i + 1))
    ..addEdge(Graph.start, 'inc')
    ..addBranch(
      'inc',
      GraphBranch.single<int>(
        (ctx, i) => i < 3 ? 'inc' : Graph.end,
        {'inc', Graph.end},
      ),
    );
  final runnable = await graph.compile(
    ctx,
    options: const GraphCompileOptions(maxRunSteps: 5),
  );
  try {
    return await runnable.invoke(ctx, 0); // 3
  } on GraphRunException catch (error) {
    // A run that needs more steps fails; the cause says why.
    if (ThreepioException.findCause<ExceedMaxStepsException>(error) != null) {
      return -1;
    }
    rethrow;
  }
  // #enddocregion steps
}
