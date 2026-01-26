import '../../schema/document.dart';

/// Options for reranking operations.
class RerankerOptions {
  /// Creates reranker options.
  const RerankerOptions({
    this.topK,
    this.threshold,
    this.extra,
  });

  /// Maximum number of documents to return.
  final int? topK;

  /// Minimum score threshold for inclusion.
  final double? threshold;

  /// Reranker-specific options.
  final Map<String, dynamic>? extra;
}

/// Result of reranking a document.
class RerankResult {
  /// Creates a rerank result.
  const RerankResult({
    required this.document,
    required this.score,
    this.originalIndex,
    this.metadata,
  });

  /// The reranked document.
  final Document document;

  /// Relevance score (higher is more relevant).
  final double score;

  /// Original index in the input list.
  final int? originalIndex;

  /// Additional metadata about the reranking.
  final Map<String, dynamic>? metadata;

  /// Create a copy with updated score.
  RerankResult withScore(double newScore) {
    return RerankResult(
      document: document,
      score: newScore,
      originalIndex: originalIndex,
      metadata: metadata,
    );
  }
}

/// Interface for reranking documents by relevance to a query.
///
/// Rerankers improve retrieval quality by reordering documents
/// based on their relevance to a specific query, often using
/// more sophisticated models than the initial retrieval.
///
/// Example:
/// ```dart
/// final reranker = ScoreReranker();
///
/// final query = "What is machine learning?";
/// final documents = await retriever.retrieve(query);
///
/// final reranked = await reranker.rerank(query, documents);
///
/// // Documents are now ordered by relevance
/// for (final result in reranked) {
///   print('Score: ${result.score}, Content: ${result.document.content}');
/// }
/// ```
abstract class Reranker {
  /// Rerank documents by relevance to a query.
  ///
  /// [query] - The query to rank documents against
  /// [documents] - Documents to rerank
  /// [options] - Reranking options
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  });
}

/// Base class with common reranker functionality.
abstract class BaseReranker implements Reranker {
  /// Apply topK filter to results.
  List<RerankResult> applyTopK(List<RerankResult> results, int? topK) {
    if (topK == null || topK <= 0 || topK >= results.length) {
      return results;
    }
    return results.sublist(0, topK);
  }

  /// Apply threshold filter to results.
  List<RerankResult> applyThreshold(List<RerankResult> results, double? threshold) {
    if (threshold == null) {
      return results;
    }
    return results.where((r) => r.score >= threshold).toList();
  }

  /// Sort results by score (descending).
  List<RerankResult> sortByScore(List<RerankResult> results) {
    final sorted = List<RerankResult>.from(results);
    sorted.sort((a, b) => b.score.compareTo(a.score));
    return sorted;
  }

  /// Apply standard filtering (threshold, sort, topK).
  List<RerankResult> applyFilters(
    List<RerankResult> results,
    RerankerOptions? options,
  ) {
    var filtered = applyThreshold(results, options?.threshold);
    filtered = sortByScore(filtered);
    filtered = applyTopK(filtered, options?.topK);
    return filtered;
  }
}
