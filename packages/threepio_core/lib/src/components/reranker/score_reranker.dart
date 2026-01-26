import '../../schema/document.dart';
import 'reranker.dart';

/// Simple reranker that uses existing document scores.
///
/// Useful for normalizing and filtering already-scored documents.
///
/// Example:
/// ```dart
/// final reranker = ScoreReranker(normalize: true);
///
/// final results = await reranker.rerank('query', documents);
/// // Documents reordered by their existing scores
/// ```
class ScoreReranker extends BaseReranker {
  /// Creates a score reranker.
  ScoreReranker({
    this.normalize = false,
    this.defaultScore = 0.0,
    this.scoreKey = 'score',
  });

  /// Whether to normalize scores to [0, 1] range.
  final bool normalize;

  /// Default score for documents without scores.
  final double defaultScore;

  /// Key to look for score in document metadata.
  final String scoreKey;

  @override
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  }) async {
    if (documents.isEmpty) {
      return [];
    }

    // Extract scores
    var results = documents.asMap().entries.map((entry) {
      final doc = entry.value;
      var score = doc.score ??
                  doc.metadata[scoreKey] as double? ??
                  defaultScore;

      return RerankResult(
        document: doc,
        score: score,
        originalIndex: entry.key,
      );
    }).toList();

    // Normalize if requested
    if (normalize) {
      results = _normalizeScores(results);
    }

    return applyFilters(results, options);
  }

  List<RerankResult> _normalizeScores(List<RerankResult> results) {
    if (results.isEmpty) return results;

    final scores = results.map((r) => r.score).toList();
    final minScore = scores.reduce((a, b) => a < b ? a : b);
    final maxScore = scores.reduce((a, b) => a > b ? a : b);
    final range = maxScore - minScore;

    if (range == 0) {
      // All scores are the same
      return results.map((r) => r.withScore(1.0)).toList();
    }

    return results.map((r) {
      final normalized = (r.score - minScore) / range;
      return r.withScore(normalized);
    }).toList();
  }
}

/// Reranker that uses a custom scoring function.
///
/// Example:
/// ```dart
/// final reranker = FunctionReranker(
///   scorer: (query, doc) async {
///     // Custom relevance calculation
///     return calculateSimilarity(query, doc.content);
///   },
/// );
/// ```
class FunctionReranker extends BaseReranker {
  /// Creates a function reranker.
  FunctionReranker({
    required this.scorer,
  });

  /// Function to calculate relevance score.
  final Future<double> Function(String query, Document document) scorer;

  @override
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  }) async {
    final results = <RerankResult>[];

    for (var i = 0; i < documents.length; i++) {
      final doc = documents[i];
      final score = await scorer(query, doc);

      results.add(RerankResult(
        document: doc,
        score: score,
        originalIndex: i,
      ));
    }

    return applyFilters(results, options);
  }
}

/// Reranker that combines multiple rerankers.
///
/// Example:
/// ```dart
/// final reranker = CompositeReranker(
///   rerankers: [reranker1, reranker2],
///   weights: [0.6, 0.4],
/// );
/// ```
class CompositeReranker extends BaseReranker {
  /// Creates a composite reranker.
  CompositeReranker({
    required this.rerankers,
    List<double>? weights,
  }) : weights = weights ?? List.filled(rerankers.length, 1.0 / rerankers.length);

  /// The rerankers to combine.
  final List<Reranker> rerankers;

  /// Weights for each reranker (must sum to 1).
  final List<double> weights;

  @override
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  }) async {
    if (documents.isEmpty || rerankers.isEmpty) {
      return [];
    }

    // Get results from each reranker
    final allResults = <List<RerankResult>>[];
    for (final reranker in rerankers) {
      final results = await reranker.rerank(query, documents);
      allResults.add(results);
    }

    // Combine scores
    final combinedScores = <int, double>{};
    final documentMap = <int, Document>{};

    for (var i = 0; i < allResults.length; i++) {
      final weight = weights[i];
      for (final result in allResults[i]) {
        final index = result.originalIndex ?? 0;
        combinedScores[index] = (combinedScores[index] ?? 0) + result.score * weight;
        documentMap[index] = result.document;
      }
    }

    // Build combined results
    final results = combinedScores.entries.map((entry) {
      return RerankResult(
        document: documentMap[entry.key]!,
        score: entry.value,
        originalIndex: entry.key,
      );
    }).toList();

    return applyFilters(results, options);
  }
}
