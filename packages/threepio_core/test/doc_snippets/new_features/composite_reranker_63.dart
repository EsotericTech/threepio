// Mirror of doc/NEW_FEATURES.md, "6. Reranking System > Composite Reranking".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> compositeReranker(Reranker functionReranker, Embedder embedder, String query, List<Document> documents) async {
  final compositeReranker = CompositeReranker(
    rerankers: [
      ScoreReranker(normalize: true),      // Use retrieval scores
      functionReranker,                     // Custom scoring
      MMRReranker(embedder: embedder),     // Diversity
    ],
    weights: [0.4, 0.3, 0.3],  // One per reranker; each scales its scores
  );

  final results = await compositeReranker.rerank(
    query,
    documents,
    options: const RerankerOptions(
      topK: 10,
      threshold: 0.5,  // Minimum score
    ),
  );
  print('${results.length} documents');
}
