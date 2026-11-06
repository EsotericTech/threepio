// Mirrors "Retrievers" of doc/RAG.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';

Future<void> vectorRetriever(
  RunContext ctx,
  Embedder embedder,
  VectorStore store,
) async {
  final retriever = VectorRetriever(embedder: embedder, vectorStore: store);
  final found = await retriever.retrieve(
    'What is threepio?',
    options: RetrieverOptions(topK: 2, scoreThreshold: 0.3, runContext: ctx),
  );
  for (final doc in found) {
    print('${doc.score?.toStringAsFixed(2)}  ${doc.content}');
  }
}

Future<List<Document>> qdrantRetriever(
  RunContext ctx,
  Embedder embedder,
  QdrantClient qdrant,
) async {
  final qdrantRetriever = QdrantRetriever(
    QdrantRetrieverConfig(
      client: qdrant,
      collection: 'docs',
      embedding: embedder,
      topK: 5,
    ),
  );
  final inFrance = await qdrantRetriever.retrieve(
    'tourist attraction',
    options: RetrieverOptions(
      runContext: ctx,
      scoreThreshold: 0.5,
      extensions: const [
        QdrantRetrieverOptions(filter: {
          'must': [
            {'key': 'metadata.country', 'match': {'value': 'France'}},
          ],
        }),
      ],
    ),
  );
  return inFrance;
}
