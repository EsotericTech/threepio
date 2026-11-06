// Mirrors "Build errors" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

String buildErrors() {
  // #docregion errors
  final graph = Graph<String, int>()
    ..addLambdaNode('a', Lambda<String, String>.invokable((ctx, s) => s));
  try {
    // 'a' gives a String; the graph must give an int.
    graph.addEdge('a', Graph.end);
  } on GraphBuildException catch (error) {
    // The first mistake sticks: every later change, and compile, throw it
    // again.
    return error.message;
  }
  // #enddocregion errors
  return '';
}
