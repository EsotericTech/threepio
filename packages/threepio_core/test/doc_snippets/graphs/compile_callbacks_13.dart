// Mirrors "Compile callbacks" of doc/GRAPHS.md.
import 'package:logging/logging.dart';
import 'package:threepio_core/compose.dart';

// #docregion callbacks
final _log = Logger('app.graphs');

/// Logs the nodes of every graph that is compiled.
final class GraphLogger implements GraphCompileCallback {
  @override
  void onFinish(RunContext ctx, GraphInfo info) {
    _log.info('compiled ${info.name}: ${info.nodes.keys.join(', ')}');
  }
}

void registerCompileCallbacks() {
  // Replaces every global compile callback, as Go's
  // compose.InitGraphCompileCallbacks does.
  GraphCompileCallbacks.setGlobal([GraphLogger()]);

  // Adds to them instead; for a library that must not remove the
  // application's callbacks. Not in Eino.
  GraphCompileCallbacks.appendGlobal([GraphLogger()]);
}
// #enddocregion callbacks

Future<void> perGraph(RunContext ctx, Graph<String, String> graph) async {
  // #docregion per-graph
  await graph.compile(
    ctx,
    options: GraphCompileOptions(
      graphName: 'support',
      compileCallbacks: [GraphLogger()],
    ),
  );
  // #enddocregion per-graph
}
