// Mirror of doc/NEW_FEATURES.md, "6. Reranking System > MMR Reranking (Diversity)".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> mmrReranker(Embedder embedder, String query, List<Document> documents) async {
  final mmrReranker = MMRReranker(
    embedder: embedder,
    lambda: 0.7,  // 0.0 = max diversity, 1.0 = max relevance
  );

  // Picks documents that are relevant and diverse; the result is sorted by
// score, and metadata['mmr_rank'] keeps the MMR order
  final diverseResults = await mmrReranker.rerank(
    query,
    documents,
    options: const RerankerOptions(topK: 10),
  );
  print('${diverseResults.length} documents');

  // With pre-computed embeddings (no embedding calls for the documents).
  // Both MMR rerankers read a document's vector from metadata['embedding'],
  // not from Document.embedding.
  final queryEmbedding = (await embedder.embedStrings([query])).first;
  final precomputedReranker = PrecomputedMMRReranker(
    queryEmbedding: queryEmbedding,
    lambda: 0.7,
  );
  final withVectors = [
    for (final doc in documents)
      doc.copyWith(metadata: {...doc.metadata, 'embedding': doc.embedding}),
  ];
  final fastResults = await precomputedReranker.rerank(query, withVectors);
  print('${fastResults.length} documents');
}
