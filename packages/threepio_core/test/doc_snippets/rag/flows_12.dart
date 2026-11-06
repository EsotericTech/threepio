// Mirrors "Retrieval flows" of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/flow.dart';

Future<List<Object>> multiQuery(
  RunContext ctx,
  Retriever retriever,
  BaseChatModel chatModel,
) async {
  final multiQuery = await MultiQueryRetriever.fromConfig(
    ctx,
    MultiQueryRetrieverConfig(
      origRetriever: retriever,
      rewriteModel: chatModel,
      maxQueries: 4,
    ),
  );
  final docs = await multiQuery.retrieve(
    'how do I build an agent with eino',
    // Passed on to every inner retrieval (Go passes none).
    options: RetrieverOptions(topK: 3, runContext: ctx),
  );

  final expanded = await MultiQueryRetriever.fromConfig(
    ctx,
    MultiQueryRetrieverConfig(
      origRetriever: retriever,
      rewriteHandler: (ctx, query) => [query, '$query tutorial'],
      fusion: (ctx, results) => results.expand((found) => found).toList(),
    ),
  );
  return [docs, expanded];
}

Future<List<Document>> parentDocuments(
  RunContext ctx,
  Embedder embedder,
  VectorStore store,
  List<Document> documents,
) async {
  final originals = {for (final doc in documents) doc.id!: doc};

  final parentIndexer = ParentIndexer(
    indexer: VectorStoreIndexer(vectorStore: store, embedder: embedder),
    transformer: RecursiveCharacterTextSplitter.fromConfig(
      const RecursiveSplitterConfig(chunkSize: 300),
    ),
    parentIdKey: 'parent_id',
    subIdGenerator: (ctx, parentId, count) => [
      for (var i = 0; i < count; i++) '${parentId}_chunk_$i',
    ],
  );
  await parentIndexer.store(ctx, documents);

  final parentRetriever = ParentRetriever.fromConfig(
    retriever: VectorRetriever(embedder: embedder, vectorStore: store),
    parentIdKey: 'parent_id',
    origDocGetter: (ctx, ids) => ids.map((id) => originals[id]).nonNulls.toList(),
  );
  final whole = await parentRetriever.retrieve(
    'refund policy',
    options: RetrieverOptions(runContext: ctx),
  );
  return whole;
}

Future<List<Document>> router(
  RunContext ctx,
  Retriever docsRetriever,
  Retriever faqRetriever,
) async {
  final routed = RouterRetriever.fromConfig(
    retrievers: {'docs': docsRetriever, 'faq': faqRetriever},
    router: (ctx, query) => query.endsWith('?') ? ['faq', 'docs'] : ['docs'],
  );
  final answers = await routed.retrieve(
    'How do I reset my password?',
    options: RetrieverOptions(runContext: ctx),
  );
  return answers;
}

Future<void> concurrent(
  RunContext ctx,
  Retriever docsRetriever,
  Retriever faqRetriever,
) async {
  final tasks = [
    RetrieveTask(name: 'docs', retriever: docsRetriever, query: 'pricing'),
    RetrieveTask(
      name: 'faq',
      retriever: faqRetriever,
      query: 'pricing',
      options: const RetrieverOptions(topK: 2),
    ),
  ];
  await concurrentRetrieve(ctx, tasks); // never throws
  for (final task in tasks) {
    if (task.failed) {
      print('${task.name} failed: ${task.error}');
    } else {
      print('${task.name}: ${task.result!.length} documents');
    }
  }
}
