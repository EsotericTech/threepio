// Mirrors "Graph" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

Future<Message> ragGraph(
  RunContext ctx,
  Retriever retriever,
  BaseChatModel model,
) async {
  // #docregion rag
  final template = ChatTemplate.fromMessages(FormatType.fString, [
    Message.system('Answer from these notes:\n{documents}'),
    Message.user('{question}'),
  ]);

  final graph = Graph<String, Message>()
    // String -> List<Document>.
    ..addRetrieverNode('retrieve', retriever)
    // List<Document> -> String, given on as {'documents': text}.
    ..addLambdaNode(
      'notes',
      Lambda<List<Document>, String>.invokable(
        (ctx, documents) => documents.map((d) => d.content).join('\n'),
      ),
      options: const NodeOptions(outputKey: 'documents'),
    )
    // String -> Map<String, Object?>.
    ..addLambdaNode(
      'question',
      Lambda<String, Map<String, Object?>>.invokable(
        (ctx, question) => {'question': question},
      ),
    )
    // Map<String, dynamic> -> List<Message>. It has two predecessors and
    // gets their maps merged into one.
    ..addChatTemplateNode('prompt', template)
    // List<Message> -> Message.
    ..addChatModelNode('model', model)
    ..addEdge(Graph.start, 'retrieve')
    ..addEdge('retrieve', 'notes')
    ..addEdge(Graph.start, 'question')
    ..addEdge('notes', 'prompt')
    ..addEdge('question', 'prompt')
    ..addEdge('prompt', 'model')
    ..addEdge('model', Graph.end);

  final runnable = await graph.compile(
    ctx,
    options: const GraphCompileOptions(
      graphName: 'rag',
      nodeTriggerMode: NodeTriggerMode.allPredecessor,
    ),
  );
  final answer = await runnable.invoke(ctx, 'What is a passthrough node?');
  // #enddocregion rag
  return answer;
}

Future<String> subGraph(RunContext ctx) async {
  // #docregion subgraph
  final inner = Chain<String, String>()
    ..appendLambda(
      Lambda<String, String>.invokable((ctx, s) => s.trim()),
    );

  final outer = Graph<String, String>()
    // A graph, chain or workflow as one node. It is compiled with the
    // outer graph. Go: AddGraphNode.
    ..addGraphNode('clean', inner, options: const NodeOptions(name: 'Clean'))
    // Hands its input on; it takes the type of its neighbours.
    ..addPassthroughNode('keep')
    ..addEdge(Graph.start, 'clean')
    ..addEdge('clean', 'keep')
    ..addEdge('keep', Graph.end);
  final runnable = await outer.compile(ctx);
  // #enddocregion subgraph
  return runnable.invoke(ctx, '  text  ');
}
