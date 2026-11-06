// Mirror of doc/NEW_FEATURES.md, "4. Advanced Retrieval Patterns > HybridRetriever".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> hybridRetriever(Embedder openAIEmbedder, VectorStore vectorStore, List<Document> documents) async {
  // Vector side: `vectorStore` already holds `documents` with their embeddings
  final vectorRetriever = VectorRetriever(
    embedder: openAIEmbedder,
    vectorStore: vectorStore,
  );

  // Keyword side: BM25 over the same documents
  final keywordSearcher = InMemoryBM25Searcher(
    k1: 1.5,  // Term frequency saturation
    b: 0.75,  // Length normalization
  );
  await keywordSearcher.addDocuments(documents);

  // Create hybrid retriever
  final hybridRetriever = HybridRetriever(
    vectorRetriever: vectorRetriever,
    keywordSearcher: keywordSearcher,
    vectorWeight: 0.7,    // 70% semantic
    keywordWeight: 0.3,   // 30% keyword
    normalizeScores: true,
    deduplicationStrategy: const IdDeduplication(),
  );

  // Retrieve
  final results = await hybridRetriever.retrieve(
    'machine learning algorithms',
    options: const RetrieverOptions(topK: 10),
  );
  print('${results.length} documents');

  // With the fused scores
  final scoredResults = await hybridRetriever.retrieveWithScores(
    'machine learning algorithms',
  );

  for (final result in scoredResults) {
    print(result.document.content);
    print('  Found by: ${result.metadata['sources']}'); // e.g. [vector, keyword]
    print('  Combined score: ${result.score}');
  }
}
