// Mirrors "Branches" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

void branches(
  Graph<String, String> graph,
  Graph<String, Message> streamingGraph,
) {
  // #docregion multi
  // Go: compose.NewGraphMultiBranch. Every node in the returned set runs.
  graph.addBranch(
    'classify',
    GraphBranch.multi<String>(
      (ctx, text) => {
        if (text.contains('?')) 'answer',
        if (text.length > 200) 'summarize',
        if (text.length <= 200 && !text.contains('?')) Graph.end,
      },
      {'answer', 'summarize', Graph.end},
    ),
  );
  // #enddocregion multi

  // #docregion stream
  // Go: compose.NewStreamGraphBranch. In a streaming run the condition gets
  // the model's chunks and may decide on the first one; it closes the stream.
  streamingGraph.addBranch(
    'model',
    GraphBranch.stream<Message>(
      (ctx, chunks) async {
        try {
          final first = await chunks.nextOrNull();
          return (first?.toolCalls?.isNotEmpty ?? false) ? 'tools' : Graph.end;
        } finally {
          await chunks.close();
        }
      },
      {'tools', Graph.end},
    ),
  );
  // #enddocregion stream
}
