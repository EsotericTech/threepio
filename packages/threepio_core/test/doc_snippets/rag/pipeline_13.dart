// Mirrors "An end-to-end pipeline" of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/io.dart';

Future<List<String>> indexFile(
  RunContext ctx,
  Indexer indexer,
  String path,
) async {
  final indexing = Chain<DocumentSource, List<String>>()
    ..appendLoader(FileLoader())
    ..appendDocumentTransformer(
      RecursiveCharacterTextSplitter.fromConfig(
        const RecursiveSplitterConfig(chunkSize: 800, overlapSize: 80),
      ),
    )
    ..appendIndexer(indexer);
  final runnable = await indexing.compile(ctx);
  return runnable.invoke(ctx, DocumentSource(uri: path));
}

Future<Runnable<String, Message>> buildRag(
  RunContext ctx,
  Retriever retriever,
  BaseChatModel model,
) {
  final template = ChatTemplate.fromMessages(FormatType.fString, [
    Message.system(
      'Answer from the context below. Say so when it does not help.\n\n'
      '{context}',
    ),
    Message.user('{question}'),
  ]);

  final graph = Graph<String, Message>()
    ..addRetrieverNode('retrieve', retriever)
    ..addLambdaNode(
      'context',
      Lambda<List<Document>, String>.invokable(
        (ctx, docs) => docs.map((doc) => doc.content).join('\n\n'),
      ),
      options: const NodeOptions(outputKey: 'context'),
    )
    ..addLambdaNode(
      'question',
      Lambda<String, String>.invokable((ctx, question) => question),
      options: const NodeOptions(outputKey: 'question'),
    )
    ..addChatTemplateNode('prompt', template)
    ..addChatModelNode('model', model)
    ..addEdge(Graph.start, 'retrieve')
    ..addEdge('retrieve', 'context')
    ..addEdge(Graph.start, 'question')
    ..addEdge('context', 'prompt')
    ..addEdge('question', 'prompt')
    ..addEdge('prompt', 'model')
    ..addEdge('model', Graph.end);

  return graph.compile(
    ctx,
    options: const GraphCompileOptions(
      graphName: 'rag',
      nodeTriggerMode: NodeTriggerMode.allPredecessor,
    ),
  );
}

Future<void> runRag(
  RunContext ctx,
  Retriever retriever,
  BaseChatModel chatModel,
) async {
  final rag = await buildRag(ctx, retriever, chatModel);

  final trace = HandlerHelper()
      .retriever(RetrieverCallbackHandler(
        onEnd: (ctx, info, output) {
          print('retrieved ${output?.docs.length} documents');
          return ctx;
        },
      ))
      .chatModel(ModelCallbackHandler(
        onEnd: (ctx, info, output) {
          print('tokens: ${output?.tokenUsage?.totalTokens}');
          return ctx;
        },
      ))
      .handler();

  final answer = await rag.invoke(
    ctx,
    'What is threepio?',
    options: [
      CallOption.callbacks([trace]),
      CallOption.retriever(const RetrieverOptions(topK: 3)),
    ],
  );
  print(answer.content);

  // The same graph streams the answer.
  final reader = await rag.stream(ctx, 'And what is Eino?');
  await for (final chunk in reader.asStream()) {
    print(chunk.content);
  }
}
