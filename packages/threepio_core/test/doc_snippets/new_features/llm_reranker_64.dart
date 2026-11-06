// Mirror of doc/NEW_FEATURES.md, "6. Reranking System > Cross-Encoder Reranking (with LLM)".
// ignore_for_file: avoid_print, avoid_redundant_argument_values, prefer_int_literals
import 'package:threepio_core/threepio_core.dart';

class LLMReranker extends BaseReranker {
  LLMReranker({required this.model});

  final BaseChatModel model;

  @override
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  }) async {
    final results = <RerankResult>[];

    for (var i = 0; i < documents.length; i++) {
      final doc = documents[i];

      // Ask LLM to score relevance
      final response = await model.generate([
        Message.system('''
Rate the relevance of the document to the query on a scale of 0-10.
Return only the number.
'''),
        Message.user('''
Query: $query

Document: ${doc.content}
'''),
      ]);

      final score = double.tryParse(response.content.trim()) ?? 0;

      results.add(RerankResult(
        document: doc,
        score: score / 10,  // Normalize to 0-1
        originalIndex: i,
      ));
    }

    // Threshold, sort by score, top-k
    return applyFilters(results, options);
  }
}
