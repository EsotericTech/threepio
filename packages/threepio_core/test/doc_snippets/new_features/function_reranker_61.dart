// Mirror of doc/NEW_FEATURES.md, "6. Reranking System > Custom Scoring Function".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

Future<void> functionReranker(String query, List<Document> documents) async {
  final functionReranker = FunctionReranker(
    scorer: (query, document) async {
      // Custom relevance scoring
      final queryTerms = query.toLowerCase().split(' ');
      final docTerms = document.content.toLowerCase().split(' ');

      var matches = 0;
      for (final term in queryTerms) {
        if (docTerms.contains(term)) matches++;
      }

      return matches / queryTerms.length;
    },
  );

  final results = await functionReranker.rerank(query, documents);
  print(results.map((r) => r.score).toList());
}
