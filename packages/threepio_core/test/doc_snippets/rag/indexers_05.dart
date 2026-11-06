// Mirrors "Indexers" of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

Future<VectorStore> vectorStoreIndexer(
  RunContext ctx,
  Embedder embedder,
) async {
  final store = InMemoryVectorStore(); // cosine similarity by default
  final indexer = VectorStoreIndexer(vectorStore: store, embedder: embedder);

  final ids = await indexer.store(
    ctx,
    [
      Document(id: 'eino', content: 'Eino is an LLM framework written in Go.'),
      Document(content: 'threepio is the Dart port of Eino.'), // gets a UUID
    ],
    options: const IndexerOptions(subIndexes: ['intro']),
  );
  print(ids); // [eino, 0b6f…]
  return store;
}

Future<QdrantClient> qdrantIndexer(
  RunContext ctx,
  Embedder embedder,
  String? qdrantKey,
  List<Document> documents,
) async {
  final qdrant = QdrantClient(
    apiKey: qdrantKey, // sent as the api-key header when set
  ); // http://localhost:6333 unless baseUrl says otherwise
  final qdrantIndexer = await QdrantIndexer.create(
    ctx,
    QdrantIndexerConfig(
      client: qdrant,
      collection: 'docs',
      vectorDim: 1536, // only used to create the collection
      distance: QdrantDistance.cosine,
      embedding: embedder,
    ),
  );
  await qdrantIndexer.store(ctx, documents);
  return qdrant;
}
