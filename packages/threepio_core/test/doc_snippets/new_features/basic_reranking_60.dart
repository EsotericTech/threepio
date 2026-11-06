// Mirror of doc/NEW_FEATURES.md, "6. Reranking System > Basic Reranking".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> basicReranking(Retriever retriever, String query) async {
  // Retrieve documents
  final documents = await retriever.retrieve(query);

  // Rerank by existing scores
  final scoreReranker = ScoreReranker(
    normalize: true,
    defaultScore: 0.0,
  );

  final reranked = await scoreReranker.rerank(
    query,
    documents,
    options: const RerankerOptions(topK: 5),
  );

  for (final result in reranked) {
    print('${result.document.content}: ${result.score}');
  }
}
