import 'dart:math' as math;

import 'scored_document.dart';

/// Interface for result fusion strategies.
///
/// Combines results from multiple retrieval sources into a single
/// ranked list of documents.
abstract class ResultFusionStrategy {
  /// Fuse multiple result sets into a single ranked list.
  ///
  /// [resultSets] contains results from each retrieval source.
  /// Returns a combined and re-ranked list of scored documents.
  List<ScoredDocument> fuse(List<List<ScoredDocument>> resultSets);
}

/// Reciprocal Rank Fusion (RRF) strategy.
///
/// Combines rankings from multiple sources using the formula:
/// score(d) = Σ 1 / (k + rank(d))
///
/// RRF is effective because it:
/// - Doesn't require score normalization across sources
/// - Gives diminishing returns to lower-ranked documents
/// - Is robust to outliers and scoring differences
///
/// Example:
/// ```dart
/// final rrf = ReciprocalRankFusion(k: 60);
/// final fused = rrf.fuse([
///   vectorResults,
///   keywordResults,
///   semanticResults,
/// ]);
/// ```
class ReciprocalRankFusion implements ResultFusionStrategy {
  const ReciprocalRankFusion({
    this.k = 60.0,
  });

  /// Ranking constant (default 60, as per original RRF paper).
  /// Higher values give more weight to lower-ranked documents.
  final double k;

  @override
  List<ScoredDocument> fuse(List<List<ScoredDocument>> resultSets) {
    if (resultSets.isEmpty) return [];
    if (resultSets.length == 1) return resultSets.first;

    // Map document ID to accumulated RRF score
    final scoreMap = <String, double>{};
    // Map document ID to the document itself
    final docMap = <String, ScoredDocument>{};
    // Track which sources contributed to each document
    final sourcesMap = <String, Set<String>>{};

    for (var setIndex = 0; setIndex < resultSets.length; setIndex++) {
      final results = resultSets[setIndex];

      for (var rank = 0; rank < results.length; rank++) {
        final doc = results[rank];
        final docId = doc.document.id ?? doc.document.content.hashCode.toString();

        // RRF formula: 1 / (k + rank)
        // rank is 0-indexed, so we add 1 to make it 1-indexed
        final rrfScore = 1.0 / (k + rank + 1);

        scoreMap[docId] = (scoreMap[docId] ?? 0.0) + rrfScore;

        // Keep the document with the highest original score
        if (!docMap.containsKey(docId) ||
            doc.score > docMap[docId]!.score) {
          docMap[docId] = doc;
        }

        // Track source
        sourcesMap.putIfAbsent(docId, () => {});
        if (doc.sourceId != null) {
          sourcesMap[docId]!.add(doc.sourceId!);
        } else {
          sourcesMap[docId]!.add('source_$setIndex');
        }
      }
    }

    // Create fused results with RRF scores
    final fusedResults = scoreMap.entries.map((entry) {
      final docId = entry.key;
      final rrfScore = entry.value;
      final originalDoc = docMap[docId]!;

      return ScoredDocument(
        document: originalDoc.document,
        score: rrfScore,
        metadata: {
          ...originalDoc.metadata,
          'fusion_method': 'rrf',
          'source_count': sourcesMap[docId]!.length,
          'sources': sourcesMap[docId]!.toList(),
          'original_score': originalDoc.score,
        },
      );
    }).toList();

    // Sort by RRF score descending
    fusedResults.sort((a, b) => b.score.compareTo(a.score));

    return fusedResults;
  }
}

/// Weighted score fusion strategy.
///
/// Combines scores from multiple sources using weighted averaging.
/// Optionally normalizes scores before fusion.
///
/// Example:
/// ```dart
/// final fusion = WeightedScoreFusion(
///   weights: [0.6, 0.4],  // 60% weight to first source
///   normalizeScores: true,
/// );
/// final fused = fusion.fuse([vectorResults, keywordResults]);
/// ```
class WeightedScoreFusion implements ResultFusionStrategy {
  const WeightedScoreFusion({
    this.weights,
    this.normalizeScores = true,
    this.normalizationMethod = ScoreNormalization.minMax,
  });

  /// Weights for each result set. If null, uses equal weights.
  final List<double>? weights;

  /// Whether to normalize scores before fusion.
  final bool normalizeScores;

  /// Method used for score normalization.
  final ScoreNormalization normalizationMethod;

  @override
  List<ScoredDocument> fuse(List<List<ScoredDocument>> resultSets) {
    if (resultSets.isEmpty) return [];
    if (resultSets.length == 1) return resultSets.first;

    // Determine weights
    final effectiveWeights = weights ?? List.filled(resultSets.length, 1.0 / resultSets.length);

    if (effectiveWeights.length != resultSets.length) {
      throw ArgumentError(
        'Number of weights (${effectiveWeights.length}) must match '
        'number of result sets (${resultSets.length})',
      );
    }

    // Normalize weights to sum to 1
    final weightSum = effectiveWeights.fold(0.0, (sum, w) => sum + w);
    final normalizedWeights = effectiveWeights.map((w) => w / weightSum).toList();

    // Optionally normalize scores within each result set
    final normalizedSets = normalizeScores
        ? resultSets.map((results) => _normalizeScores(results)).toList()
        : resultSets;

    // Map document ID to weighted score accumulator
    final scoreMap = <String, double>{};
    final docMap = <String, ScoredDocument>{};
    final sourcesMap = <String, Set<String>>{};
    final weightSumMap = <String, double>{};

    for (var setIndex = 0; setIndex < normalizedSets.length; setIndex++) {
      final results = normalizedSets[setIndex];
      final weight = normalizedWeights[setIndex];

      for (final doc in results) {
        final docId = doc.document.id ?? doc.document.content.hashCode.toString();

        scoreMap[docId] = (scoreMap[docId] ?? 0.0) + (doc.score * weight);
        weightSumMap[docId] = (weightSumMap[docId] ?? 0.0) + weight;

        if (!docMap.containsKey(docId)) {
          docMap[docId] = doc;
        }

        sourcesMap.putIfAbsent(docId, () => {});
        if (doc.sourceId != null) {
          sourcesMap[docId]!.add(doc.sourceId!);
        } else {
          sourcesMap[docId]!.add('source_$setIndex');
        }
      }
    }

    // Create fused results
    final fusedResults = scoreMap.entries.map((entry) {
      final docId = entry.key;
      final score = entry.value;
      final originalDoc = docMap[docId]!;

      return ScoredDocument(
        document: originalDoc.document,
        score: score,
        metadata: {
          ...originalDoc.metadata,
          'fusion_method': 'weighted',
          'source_count': sourcesMap[docId]!.length,
          'sources': sourcesMap[docId]!.toList(),
        },
      );
    }).toList();

    fusedResults.sort((a, b) => b.score.compareTo(a.score));

    return fusedResults;
  }

  List<ScoredDocument> _normalizeScores(List<ScoredDocument> results) {
    if (results.isEmpty) return results;

    switch (normalizationMethod) {
      case ScoreNormalization.minMax:
        return _minMaxNormalize(results);
      case ScoreNormalization.zScore:
        return _zScoreNormalize(results);
      case ScoreNormalization.rank:
        return _rankNormalize(results);
    }
  }

  List<ScoredDocument> _minMaxNormalize(List<ScoredDocument> results) {
    final scores = results.map((r) => r.score).toList();
    final minScore = scores.reduce(math.min);
    final maxScore = scores.reduce(math.max);
    final range = maxScore - minScore;

    if (range == 0) {
      return results.map((r) => r.copyWith(score: 1.0)).toList();
    }

    return results.map((r) {
      return r.copyWith(score: (r.score - minScore) / range);
    }).toList();
  }

  List<ScoredDocument> _zScoreNormalize(List<ScoredDocument> results) {
    final scores = results.map((r) => r.score).toList();
    final mean = scores.reduce((a, b) => a + b) / scores.length;
    final variance = scores.map((s) => (s - mean) * (s - mean)).reduce((a, b) => a + b) / scores.length;
    final stdDev = math.sqrt(variance);

    if (stdDev == 0) {
      return results.map((r) => r.copyWith(score: 0.0)).toList();
    }

    return results.map((r) {
      return r.copyWith(score: (r.score - mean) / stdDev);
    }).toList();
  }

  List<ScoredDocument> _rankNormalize(List<ScoredDocument> results) {
    final sorted = List<ScoredDocument>.from(results)
      ..sort((a, b) => b.score.compareTo(a.score));

    final n = sorted.length;
    return sorted.asMap().entries.map((entry) {
      final rank = entry.key;
      final doc = entry.value;
      // Normalize to [0, 1] where highest rank gets 1
      final normalizedScore = (n - rank) / n;
      return doc.copyWith(score: normalizedScore);
    }).toList();
  }
}

/// Score normalization methods.
enum ScoreNormalization {
  /// Min-max normalization to [0, 1] range.
  minMax,

  /// Z-score normalization (standard score).
  zScore,

  /// Rank-based normalization.
  rank,
}

/// Simple union fusion - combines all results without re-scoring.
///
/// Useful when you want all unique documents from multiple sources
/// without changing their original scores.
class UnionFusion implements ResultFusionStrategy {
  const UnionFusion({
    this.keepHighestScore = true,
  });

  /// When documents appear in multiple sets, keep the highest score.
  final bool keepHighestScore;

  @override
  List<ScoredDocument> fuse(List<List<ScoredDocument>> resultSets) {
    if (resultSets.isEmpty) return [];
    if (resultSets.length == 1) return resultSets.first;

    final docMap = <String, ScoredDocument>{};

    for (final results in resultSets) {
      for (final doc in results) {
        final docId = doc.document.id ?? doc.document.content.hashCode.toString();

        if (!docMap.containsKey(docId)) {
          docMap[docId] = doc;
        } else if (keepHighestScore && doc.score > docMap[docId]!.score) {
          docMap[docId] = doc;
        }
      }
    }

    final fusedResults = docMap.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return fusedResults;
  }
}
