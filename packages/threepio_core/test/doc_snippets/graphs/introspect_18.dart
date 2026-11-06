// Mirrors "Looking at a graph" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

String mermaid() {
  // #docregion mermaid
  final graph = Graph<String, String>()
    ..addLambdaNode('a', Lambda<String, String>.invokable((ctx, s) => '$s-a'))
    ..addLambdaNode('b', Lambda<String, String>.invokable((ctx, s) => '$s-b'))
    ..addEdge(Graph.start, 'a')
    ..addEdge('a', 'b')
    ..addEdge('b', Graph.end);

  // Nodes, edges and branches as they are now.
  final info = graph.info;
  final keys = info.nodes.keys; // ('a', 'b')

  // A Mermaid flowchart ('graph TD ...') for a Markdown viewer.
  final chart = graph.toMermaid();
  // #enddocregion mermaid
  return '$keys\n$chart';
}
