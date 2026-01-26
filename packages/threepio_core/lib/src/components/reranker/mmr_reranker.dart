import 'dart:math' as math;

import '../../schema/document.dart';
import '../embedding/embedder.dart';
import 'reranker.dart';

/// Maximal Marginal Relevance (MMR) reranker.
///
/// Balances relevance to query with diversity among results,
/// reducing redundancy in the returned documents.
///
/// MMR = λ * Sim(d, q) - (1-λ) * max(Sim(d, d'))
///
/// Where:
/// - d is a candidate document
/// - q is the query
/// - d' are already selected documents
/// - λ (lambda) controls the relevance-diversity tradeoff
///
/// Example:
/// ```dart
/// final reranker = MMRReranker(
///   embedder: openAIEmbedder,
///   lambda: 0.7, // Favor relevance over diversity
/// );
///
/// final results = await reranker.rerank(query, documents);
/// // Documents balanced for relevance and diversity
/// ```
class MMRReranker extends BaseReranker {
  /// Creates an MMR reranker.
  ///
  /// [embedder] - Embedder for computing document similarities
  /// [lambda] - Balance between relevance (1.0) and diversity (0.0)
  /// [useExistingEmbeddings] - Whether to use embeddings from document metadata
  /// [embeddingKey] - Key for embeddings in document metadata
  MMRReranker({
    required this.embedder,
    this.lambda = 0.5,
    this.useExistingEmbeddings = true,
    this.embeddingKey = 'embedding',
  }) : assert(lambda >= 0 && lambda <= 1, 'Lambda must be between 0 and 1');

  /// Embedder for computing similarities.
  final Embedder embedder;

  /// Balance between relevance and diversity.
  /// - 1.0 = pure relevance (no diversity consideration)
  /// - 0.0 = pure diversity (no relevance consideration)
  /// - 0.5 = balanced (default)
  final double lambda;

  /// Whether to use existing embeddings from document metadata.
  final bool useExistingEmbeddings;

  /// Key to look for embeddings in document metadata.
  final String embeddingKey;

  @override
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  }) async {
    if (documents.isEmpty) {
      return [];
    }

    final topK = options?.topK ?? documents.length;

    // Get query embedding
    final queryEmbeddings = await embedder.embedStrings([query]);
    final queryEmbedding = queryEmbeddings.first;

    // Get document embeddings
    final docEmbeddings = await _getDocumentEmbeddings(documents);

    // Compute relevance scores (similarity to query)
    final relevanceScores = <int, double>{};
    for (var i = 0; i < documents.length; i++) {
      relevanceScores[i] = _cosineSimilarity(queryEmbedding, docEmbeddings[i]);
    }

    // MMR selection
    final selected = <int>[];
    final candidates = List<int>.generate(documents.length, (i) => i);

    while (selected.length < topK && candidates.isNotEmpty) {
      int? bestCandidate;
      double bestScore = double.negativeInfinity;

      for (final candidateIdx in candidates) {
        final relevance = relevanceScores[candidateIdx]!;

        // Compute max similarity to already selected documents
        double maxSimilarityToSelected = 0;
        if (selected.isNotEmpty) {
          for (final selectedIdx in selected) {
            final similarity = _cosineSimilarity(
              docEmbeddings[candidateIdx],
              docEmbeddings[selectedIdx],
            );
            maxSimilarityToSelected = math.max(maxSimilarityToSelected, similarity);
          }
        }

        // MMR score
        final mmrScore = lambda * relevance - (1 - lambda) * maxSimilarityToSelected;

        if (mmrScore > bestScore) {
          bestScore = mmrScore;
          bestCandidate = candidateIdx;
        }
      }

      if (bestCandidate != null) {
        selected.add(bestCandidate);
        candidates.remove(bestCandidate);
      } else {
        break;
      }
    }

    // Build results in MMR order
    final results = <RerankResult>[];
    for (var rank = 0; rank < selected.length; rank++) {
      final idx = selected[rank];
      results.add(RerankResult(
        document: documents[idx],
        score: relevanceScores[idx]!,
        originalIndex: idx,
        metadata: {
          'mmr_rank': rank,
          'relevance_score': relevanceScores[idx],
        },
      ));
    }

    return applyFilters(results, options);
  }

  Future<List<List<double>>> _getDocumentEmbeddings(List<Document> documents) async {
    final embeddings = <List<double>>[];

    for (final doc in documents) {
      List<double>? embedding;

      // Try to get existing embedding from metadata
      if (useExistingEmbeddings && doc.metadata.containsKey(embeddingKey)) {
        final stored = doc.metadata[embeddingKey];
        if (stored is List) {
          embedding = stored.cast<double>();
        }
      }

      // Compute embedding if not found
      if (embedding == null) {
        final embeddings = await embedder.embedStrings([doc.content]);
        embedding = embeddings.first;
      }

      embeddings.add(embedding);
    }

    return embeddings;
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('Vectors must have same length');
    }

    double dotProduct = 0;
    double normA = 0;
    double normB = 0;

    for (var i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    final denominator = math.sqrt(normA) * math.sqrt(normB);
    if (denominator == 0) return 0;

    return dotProduct / denominator;
  }
}

/// MMR reranker that works with pre-computed embeddings only.
///
/// Use this when all documents already have embeddings stored
/// and you want to avoid making additional embedding API calls.
///
/// Example:
/// ```dart
/// final reranker = PrecomputedMMRReranker(
///   queryEmbedding: await embedder.embedQuery(query),
///   lambda: 0.6,
/// );
///
/// final results = await reranker.rerank(query, documentsWithEmbeddings);
/// ```
class PrecomputedMMRReranker extends BaseReranker {
  /// Creates a precomputed MMR reranker.
  PrecomputedMMRReranker({
    required this.queryEmbedding,
    this.lambda = 0.5,
    this.embeddingKey = 'embedding',
  }) : assert(lambda >= 0 && lambda <= 1, 'Lambda must be between 0 and 1');

  /// Pre-computed query embedding.
  final List<double> queryEmbedding;

  /// Balance between relevance and diversity.
  final double lambda;

  /// Key to look for embeddings in document metadata.
  final String embeddingKey;

  @override
  Future<List<RerankResult>> rerank(
    String query,
    List<Document> documents, {
    RerankerOptions? options,
  }) async {
    if (documents.isEmpty) {
      return [];
    }

    final topK = options?.topK ?? documents.length;

    // Extract embeddings from documents
    final docEmbeddings = <List<double>>[];
    for (final doc in documents) {
      final stored = doc.metadata[embeddingKey];
      if (stored == null || stored is! List) {
        throw ArgumentError(
          'Document missing embedding at key "$embeddingKey". '
          'All documents must have pre-computed embeddings.',
        );
      }
      docEmbeddings.add((stored).cast<double>());
    }

    // Compute relevance scores
    final relevanceScores = <int, double>{};
    for (var i = 0; i < documents.length; i++) {
      relevanceScores[i] = _cosineSimilarity(queryEmbedding, docEmbeddings[i]);
    }

    // MMR selection
    final selected = <int>[];
    final candidates = List<int>.generate(documents.length, (i) => i);

    while (selected.length < topK && candidates.isNotEmpty) {
      int? bestCandidate;
      double bestScore = double.negativeInfinity;

      for (final candidateIdx in candidates) {
        final relevance = relevanceScores[candidateIdx]!;

        double maxSimilarityToSelected = 0;
        if (selected.isNotEmpty) {
          for (final selectedIdx in selected) {
            final similarity = _cosineSimilarity(
              docEmbeddings[candidateIdx],
              docEmbeddings[selectedIdx],
            );
            maxSimilarityToSelected = math.max(maxSimilarityToSelected, similarity);
          }
        }

        final mmrScore = lambda * relevance - (1 - lambda) * maxSimilarityToSelected;

        if (mmrScore > bestScore) {
          bestScore = mmrScore;
          bestCandidate = candidateIdx;
        }
      }

      if (bestCandidate != null) {
        selected.add(bestCandidate);
        candidates.remove(bestCandidate);
      } else {
        break;
      }
    }

    // Build results
    final results = <RerankResult>[];
    for (var rank = 0; rank < selected.length; rank++) {
      final idx = selected[rank];
      results.add(RerankResult(
        document: documents[idx],
        score: relevanceScores[idx]!,
        originalIndex: idx,
        metadata: {
          'mmr_rank': rank,
          'relevance_score': relevanceScores[idx],
        },
      ));
    }

    return applyFilters(results, options);
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('Vectors must have same length');
    }

    double dotProduct = 0;
    double normA = 0;
    double normB = 0;

    for (var i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    final denominator = math.sqrt(normA) * math.sqrt(normB);
    if (denominator == 0) return 0;

    return dotProduct / denominator;
  }
}
