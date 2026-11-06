// Mirrors "Fan-in" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

// #docregion merge
/// What two analysers report about a text.
final class Findings {
  const Findings(this.items);
  final List<String> items;
}

Future<Findings> analyse(RunContext ctx, String text) async {
  // Go: compose.RegisterValuesMergeFunc. Without it a fan-in of Findings
  // fails at run time; maps are the only type merged by default.
  ValuesMerge.register<Findings>(
    (values) => Findings([for (final v in values) ...v.items]),
  );

  final graph = Graph<String, Findings>()
    ..addLambdaNode(
      'spelling',
      Lambda<String, Findings>.invokable(
        (ctx, text) => const Findings(['spelling: ok']),
      ),
    )
    ..addLambdaNode(
      'style',
      Lambda<String, Findings>.invokable(
        (ctx, text) => Findings(['style: ${text.length} characters']),
      ),
    )
    ..addEdge(Graph.start, 'spelling')
    ..addEdge(Graph.start, 'style')
    ..addEdge('spelling', Graph.end)
    ..addEdge('style', Graph.end);
  final runnable = await graph.compile(ctx);
  return runnable.invoke(ctx, text);
}
// #enddocregion merge

void narrowMaps() {
  // #docregion narrow
  // The default merge gives a Map<String, Object?>. A node that takes a
  // narrower map behind a fan-in needs a function for that type.
  ValuesMerge.register<Map<String, int>>(
    (maps) => {for (final map in maps) ...map},
  );
  // #enddocregion narrow
}
