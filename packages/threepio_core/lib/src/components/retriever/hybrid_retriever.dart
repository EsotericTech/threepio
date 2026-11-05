import 'dart:math' as math;

import '../../core/run_context.dart';
import '../../schema/document.dart';
import '../embedding/embedder.dart';
import 'fusion/deduplication.dart';
import 'fusion/result_fusion.dart';
import 'fusion/scored_document.dart';
import 'retriever.dart';

/// A retriever that combines vector (semantic) and keyword (BM25) search.
///
/// Hybrid retrieval improves both precision and recall by:
/// - Vector search captures semantic meaning ("car" matches "automobile")
/// - Keyword search captures exact terms (technical jargon, names, codes)
///
/// Example:
/// ```dart
/// final hybridRetriever = HybridRetriever(
///   vectorRetriever: vectorRetriever,
///   keywordSearcher: bm25Searcher,
///   vectorWeight: 0.7,
///   keywordWeight: 0.3,
/// );
///
/// // Combines semantic understanding with exact matching
/// final docs = await hybridRetriever.retrieve('error code E-1234');
/// ```
class HybridRetriever implements Retriever {
  HybridRetriever({
    required this.vectorRetriever,
    required this.keywordSearcher,
    this.vectorWeight = 0.5,
    this.keywordWeight = 0.5,
    this.fusionStrategy,
    this.deduplicationStrategy,
    this.normalizeScores = true,
  });

  /// Vector/semantic retriever.
  final Retriever vectorRetriever;

  /// Keyword search function.
  final KeywordSearcher keywordSearcher;

  /// Weight for vector search results (0.0 to 1.0).
  final double vectorWeight;

  /// Weight for keyword search results (0.0 to 1.0).
  final double keywordWeight;

  /// Fusion strategy. Defaults to weighted score fusion.
  final ResultFusionStrategy? fusionStrategy;

  /// Deduplication strategy. Defaults to ID deduplication.
  final DeduplicationStrategy? deduplicationStrategy;

  /// Whether to normalize scores before fusion.
  final bool normalizeScores;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    // Run both retrievers in parallel
    final results = await Future.wait([
      vectorRetriever.retrieve(query, options: options),
      keywordSearcher.search(query, topK: options?.topK ?? 10),
    ]);

    final vectorDocs = results[0];
    final keywordDocs = results[1];

    // Convert to scored documents
    final vectorScored = vectorDocs.asMap().entries.map((entry) {
      return ScoredDocument(
        document: entry.value,
        score: entry.value.score ?? (1.0 / (entry.key + 1)),
        sourceId: 'vector',
        rank: entry.key + 1,
      );
    }).toList();

    final keywordScored = keywordDocs.asMap().entries.map((entry) {
      return ScoredDocument(
        document: entry.value,
        score: entry.value.score ?? (1.0 / (entry.key + 1)),
        sourceId: 'keyword',
        rank: entry.key + 1,
      );
    }).toList();

    // Fuse results
    final strategy = fusionStrategy ??
        WeightedScoreFusion(
          weights: [vectorWeight, keywordWeight],
          normalizeScores: normalizeScores,
        );

    final fused = strategy.fuse([vectorScored, keywordScored]);

    // Deduplicate
    final dedupStrategy = deduplicationStrategy ?? const IdDeduplication();
    final deduplicated = await dedupStrategy.deduplicate(fused);

    // Apply topK
    final topK = options?.topK;
    final limited = topK != null && deduplicated.length > topK
        ? deduplicated.take(topK).toList()
        : deduplicated;

    return limited.map((sd) => sd.document).toList();
  }

  /// Retrieve with full scored documents for access to fusion metadata.
  Future<List<ScoredDocument>> retrieveWithScores(
    String query, {
    RetrieverOptions? options,
  }) async {
    final results = await Future.wait([
      vectorRetriever.retrieve(query, options: options),
      keywordSearcher.search(query, topK: options?.topK ?? 10),
    ]);

    final vectorDocs = results[0];
    final keywordDocs = results[1];

    final vectorScored = vectorDocs.asMap().entries.map((entry) {
      return ScoredDocument(
        document: entry.value,
        score: entry.value.score ?? (1.0 / (entry.key + 1)),
        sourceId: 'vector',
        rank: entry.key + 1,
      );
    }).toList();

    final keywordScored = keywordDocs.asMap().entries.map((entry) {
      return ScoredDocument(
        document: entry.value,
        score: entry.value.score ?? (1.0 / (entry.key + 1)),
        sourceId: 'keyword',
        rank: entry.key + 1,
      );
    }).toList();

    final strategy = fusionStrategy ??
        WeightedScoreFusion(
          weights: [vectorWeight, keywordWeight],
          normalizeScores: normalizeScores,
        );

    final fused = strategy.fuse([vectorScored, keywordScored]);

    final dedupStrategy = deduplicationStrategy ?? const IdDeduplication();
    final deduplicated = await dedupStrategy.deduplicate(fused);

    final topK = options?.topK;
    return topK != null && deduplicated.length > topK
        ? deduplicated.take(topK).toList()
        : deduplicated;
  }
}

/// Interface for keyword-based search.
abstract class KeywordSearcher {
  /// Search for documents matching the query.
  Future<List<Document>> search(String query, {int topK = 10});
}

/// In-memory BM25 keyword searcher.
///
/// BM25 (Best Matching 25) is a ranking function used for text retrieval
/// that considers term frequency, document frequency, and document length.
///
/// Example:
/// ```dart
/// final searcher = InMemoryBM25Searcher();
///
/// // Add documents
/// await searcher.addDocuments([
///   Document.simple('The quick brown fox'),
///   Document.simple('The lazy dog'),
/// ]);
///
/// // Search
/// final results = await searcher.search('quick fox', topK: 5);
/// ```
class InMemoryBM25Searcher implements KeywordSearcher {
  InMemoryBM25Searcher({
    this.k1 = 1.2,
    this.b = 0.75,
    this.tokenizer,
  });

  /// BM25 k1 parameter (term frequency saturation).
  final double k1;

  /// BM25 b parameter (document length normalization).
  final double b;

  /// Custom tokenizer. Defaults to whitespace + lowercase.
  final List<String> Function(String text)? tokenizer;

  final List<Document> _documents = [];
  final List<List<String>> _tokenizedDocs = [];
  final Map<String, int> _documentFrequency = {};
  double _avgDocLength = 0;

  /// Add documents to the search index.
  Future<void> addDocuments(List<Document> documents) async {
    for (final doc in documents) {
      final tokens = _tokenize(doc.content);
      _documents.add(doc);
      _tokenizedDocs.add(tokens);

      // Update document frequency
      final uniqueTokens = tokens.toSet();
      for (final token in uniqueTokens) {
        _documentFrequency[token] = (_documentFrequency[token] ?? 0) + 1;
      }
    }

    // Update average document length
    if (_tokenizedDocs.isNotEmpty) {
      final totalLength = _tokenizedDocs.fold(0, (sum, doc) => sum + doc.length);
      _avgDocLength = totalLength / _tokenizedDocs.length;
    }
  }

  /// Clear all documents from the index.
  void clear() {
    _documents.clear();
    _tokenizedDocs.clear();
    _documentFrequency.clear();
    _avgDocLength = 0;
  }

  /// Get the number of indexed documents.
  int get documentCount => _documents.length;

  @override
  Future<List<Document>> search(String query, {int topK = 10}) async {
    if (_documents.isEmpty) return [];

    final queryTokens = _tokenize(query);
    if (queryTokens.isEmpty) return [];

    final scores = <int, double>{};
    final n = _documents.length;

    for (var i = 0; i < _documents.length; i++) {
      final docTokens = _tokenizedDocs[i];
      final docLength = docTokens.length;

      var score = 0.0;

      for (final queryToken in queryTokens) {
        final tf = _termFrequency(queryToken, docTokens);
        if (tf == 0) continue;

        final df = _documentFrequency[queryToken] ?? 0;
        final idf = _inverseDocumentFrequency(df, n);

        // BM25 formula
        final numerator = tf * (k1 + 1);
        final denominator = tf + k1 * (1 - b + b * docLength / _avgDocLength);

        score += idf * numerator / denominator;
      }

      if (score > 0) {
        scores[i] = score;
      }
    }

    // Sort by score descending
    final sortedIndices = scores.keys.toList()
      ..sort((a, b) => scores[b]!.compareTo(scores[a]!));

    // Return top K documents
    final results = <Document>[];
    for (final index in sortedIndices.take(topK)) {
      final doc = _documents[index];
      results.add(doc.copyWith(score: scores[index]));
    }

    return results;
  }

  List<String> _tokenize(String text) {
    if (tokenizer != null) {
      return tokenizer!(text);
    }

    // Default tokenizer: lowercase, split on non-alphanumeric
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty && t.length > 1) // Remove single chars
        .toList();
  }

  int _termFrequency(String term, List<String> document) {
    return document.where((t) => t == term).length;
  }

  double _inverseDocumentFrequency(int documentFrequency, int totalDocuments) {
    if (documentFrequency == 0) return 0;

    // IDF with smoothing
    return math.log(
      (totalDocuments - documentFrequency + 0.5) /
      (documentFrequency + 0.5) +
      1,
    );
  }
}

/// Keyword searcher that wraps an existing retriever.
///
/// Useful when you have a keyword-based retriever and want to use it
/// with HybridRetriever.
class RetrieverKeywordSearcher implements KeywordSearcher {
  RetrieverKeywordSearcher({
    required this.retriever,
  });

  final Retriever retriever;

  @override
  Future<List<Document>> search(String query, {int topK = 10}) {
    return retriever.retrieve(query, options: RetrieverOptions(topK: topK));
  }
}

/// Options specific to hybrid retrieval.
class HybridRetrieverOptions extends RetrieverOptions {
  const HybridRetrieverOptions({
    super.topK,
    super.scoreThreshold,
    super.extra,
    super.callbackManager,
    super.context,
    super.metadata,
    super.index,
    super.subIndex,
    super.embedding,
    super.dslInfo,
    super.runContext,
    super.extensions,
    this.vectorTopK,
    this.keywordTopK,
    this.overrideVectorWeight,
    this.overrideKeywordWeight,
  });

  /// Override topK for vector retrieval.
  final int? vectorTopK;

  /// Override topK for keyword retrieval.
  final int? keywordTopK;

  /// Override vector weight for this query.
  final double? overrideVectorWeight;

  /// Override keyword weight for this query.
  final double? overrideKeywordWeight;

  @override
  HybridRetrieverOptions copyWith({
    int? topK,
    double? scoreThreshold,
    Map<String, dynamic>? extra,
    Map<String, dynamic>? metadata,
    String? index,
    String? subIndex,
    Embedder? embedding,
    Map<String, Object?>? dslInfo,
    RunContext? runContext,
    List<Object>? extensions,
    int? vectorTopK,
    int? keywordTopK,
    double? overrideVectorWeight,
    double? overrideKeywordWeight,
  }) =>
      _from(
        super.copyWith(
          topK: topK,
          scoreThreshold: scoreThreshold,
          extra: extra,
          metadata: metadata,
          index: index,
          subIndex: subIndex,
          embedding: embedding,
          dslInfo: dslInfo,
          runContext: runContext,
          extensions: extensions,
        ),
        vectorTopK: vectorTopK ?? this.vectorTopK,
        keywordTopK: keywordTopK ?? this.keywordTopK,
        overrideVectorWeight: overrideVectorWeight ?? this.overrideVectorWeight,
        overrideKeywordWeight:
            overrideKeywordWeight ?? this.overrideKeywordWeight,
      );

  /// These options with what [other] sets taking precedence. The fields of
  /// this class are taken from [other] when it is a [HybridRetrieverOptions]
  /// that sets them, and kept otherwise.
  @override
  HybridRetrieverOptions merge(RetrieverOptions? other) {
    if (other == null) return this;
    final hybrid = other is HybridRetrieverOptions ? other : null;
    return _from(
      super.merge(other),
      vectorTopK: hybrid?.vectorTopK ?? vectorTopK,
      keywordTopK: hybrid?.keywordTopK ?? keywordTopK,
      overrideVectorWeight:
          hybrid?.overrideVectorWeight ?? overrideVectorWeight,
      overrideKeywordWeight:
          hybrid?.overrideKeywordWeight ?? overrideKeywordWeight,
    );
  }

  static HybridRetrieverOptions _from(
    RetrieverOptions base, {
    required int? vectorTopK,
    required int? keywordTopK,
    required double? overrideVectorWeight,
    required double? overrideKeywordWeight,
  }) =>
      HybridRetrieverOptions(
        topK: base.topK,
        scoreThreshold: base.scoreThreshold,
        extra: base.extra,
        callbackManager: base.callbackManager,
        context: base.context,
        metadata: base.metadata,
        index: base.index,
        subIndex: base.subIndex,
        embedding: base.embedding,
        dslInfo: base.dslInfo,
        runContext: base.runContext,
        extensions: base.extensions,
        vectorTopK: vectorTopK,
        keywordTopK: keywordTopK,
        overrideVectorWeight: overrideVectorWeight,
        overrideKeywordWeight: overrideKeywordWeight,
      );
}
