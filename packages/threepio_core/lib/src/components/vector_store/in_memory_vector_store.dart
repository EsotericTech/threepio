import 'dart:math' as math;

import '../../callbacks/callback_handler.dart';
import '../../callbacks/callback_manager.dart';
import '../../callbacks/run_info.dart';
import '../../schema/document.dart';
import 'vector_store.dart';

/// In-memory vector store implementation
///
/// Stores documents and their embeddings in memory using cosine similarity
/// for retrieval. This is useful for development, testing, and small-scale
/// applications where persistence is not required.
///
/// Example usage:
/// ```dart
/// // Create store
/// final store = InMemoryVectorStore();
///
/// // Add documents with embeddings
/// final docs = [
///   Document(
///     id: '1',
///     content: 'The capital of France is Paris',
///     embedding: [0.1, 0.2, 0.3],
///   ),
///   Document(
///     id: '2',
///     content: 'The capital of Germany is Berlin',
///     embedding: [0.2, 0.3, 0.4],
///   ),
/// ];
///
/// await store.addDocuments(docs);
///
/// // Search for similar documents
/// final results = await store.similaritySearch(
///   queryEmbedding: [0.15, 0.25, 0.35],
///   k: 1,
/// );
///
/// print('Most similar: ${results.first.document.content}');
/// print('Score: ${results.first.score}');
/// ```
class InMemoryVectorStore implements VectorStore {
  InMemoryVectorStore({
    this.similarityMetric = SimilarityMetric.cosine,
  });

  /// Similarity metric to use for retrieval
  final SimilarityMetric similarityMetric;

  /// Internal storage for documents
  final List<Document> _documents = [];

  /// Internal ID counter for documents without IDs
  int _nextId = 1;

  @override
  Future<void> addDocuments(
    List<Document> documents, {
    VectorStoreOptions? options,
  }) async {
    // Validate all documents have embeddings
    for (final doc in documents) {
      if (doc.embedding == null || doc.embedding!.isEmpty) {
        throw VectorStoreException(
          'Document must have an embedding before adding to vector store',
        );
      }
    }

    // Get callback manager if available
    final callbackManager = options?.callbackManager as CallbackManager?;

    if (callbackManager != null) {
      final runInfo = RunInfo(
        name: 'InMemoryVectorStore.addDocuments',
        type: 'InMemoryVectorStore',
        componentType: ComponentType.custom,
        metadata: {
          'operation': 'addDocuments',
          'document_count': documents.length,
        },
      );

      return await callbackManager.runWithCallbacks(
        options?.context ?? {},
        runInfo,
        documents,
        () => _addDocumentsInternal(documents),
      );
    } else {
      return _addDocumentsInternal(documents);
    }
  }

  Future<void> _addDocumentsInternal(List<Document> documents) async {
    // Validate dimensions match if we have existing documents
    if (_documents.isNotEmpty) {
      final existingDim = _documents.first.embedding!.length;
      for (final doc in documents) {
        if (doc.embedding!.length != existingDim) {
          throw VectorStoreException(
            'Embedding dimension mismatch: expected $existingDim, got ${doc.embedding!.length}',
          );
        }
      }
    }

    // Add documents, ensuring they all have IDs
    for (final doc in documents) {
      final docWithId =
          doc.id == null ? doc.copyWith(id: 'doc_${_nextId++}') : doc;
      _documents.add(docWithId);
    }
  }

  @override
  Future<List<SimilaritySearchResult>> similaritySearch({
    required List<double> queryEmbedding,
    int k = 4,
    VectorStoreOptions? options,
  }) async {
    if (_documents.isEmpty) {
      return [];
    }

    // Validate dimension
    final expectedDim = _documents.first.embedding!.length;
    if (queryEmbedding.length != expectedDim) {
      throw VectorStoreException(
        'Query embedding dimension mismatch: expected $expectedDim, got ${queryEmbedding.length}',
      );
    }

    // Get callback manager if available
    final callbackManager = options?.callbackManager as CallbackManager?;

    if (callbackManager != null) {
      final runInfo = RunInfo(
        name: 'InMemoryVectorStore.similaritySearch',
        type: 'InMemoryVectorStore',
        componentType: ComponentType.custom,
        metadata: {
          'operation': 'similaritySearch',
          'k': k,
          'embedding_dimension': queryEmbedding.length,
        },
      );

      return await callbackManager.runWithCallbacks(
        options?.context ?? {},
        runInfo,
        queryEmbedding,
        () => _similaritySearchInternal(queryEmbedding, k),
      );
    } else {
      return _similaritySearchInternal(queryEmbedding, k);
    }
  }

  Future<List<SimilaritySearchResult>> _similaritySearchInternal(
    List<double> queryEmbedding,
    int k,
  ) async {
    // Calculate similarity scores for all documents
    final results = <SimilaritySearchResult>[];

    for (final doc in _documents) {
      final score = _calculateSimilarity(
        queryEmbedding,
        doc.embedding!,
        similarityMetric,
      );

      results.add(
        SimilaritySearchResult(
          document: doc.copyWith(score: score),
          score: score,
        ),
      );
    }

    // Sort by score (descending) and take top k
    results.sort((a, b) => b.score.compareTo(a.score));

    return results.take(k).toList();
  }

  @override
  Future<List<SimilaritySearchResult>> similaritySearchWithThreshold({
    required List<double> queryEmbedding,
    required double scoreThreshold,
    VectorStoreOptions? options,
  }) async {
    if (_documents.isEmpty) {
      return [];
    }

    // Validate dimension
    final expectedDim = _documents.first.embedding!.length;
    if (queryEmbedding.length != expectedDim) {
      throw VectorStoreException(
        'Query embedding dimension mismatch: expected $expectedDim, got ${queryEmbedding.length}',
      );
    }

    // Get callback manager if available
    final callbackManager = options?.callbackManager as CallbackManager?;

    if (callbackManager != null) {
      final runInfo = RunInfo(
        name: 'InMemoryVectorStore.similaritySearchWithThreshold',
        type: 'InMemoryVectorStore',
        componentType: ComponentType.custom,
        metadata: {
          'operation': 'similaritySearchWithThreshold',
          'score_threshold': scoreThreshold,
          'embedding_dimension': queryEmbedding.length,
        },
      );

      return await callbackManager.runWithCallbacks(
        options?.context ?? {},
        runInfo,
        queryEmbedding,
        () => _similaritySearchWithThresholdInternal(
          queryEmbedding,
          scoreThreshold,
        ),
      );
    } else {
      return _similaritySearchWithThresholdInternal(
        queryEmbedding,
        scoreThreshold,
      );
    }
  }

  Future<List<SimilaritySearchResult>> _similaritySearchWithThresholdInternal(
    List<double> queryEmbedding,
    double scoreThreshold,
  ) async {
    // Calculate similarity scores for all documents
    final results = <SimilaritySearchResult>[];

    for (final doc in _documents) {
      final score = _calculateSimilarity(
        queryEmbedding,
        doc.embedding!,
        similarityMetric,
      );

      // Only include results above threshold
      if (score >= scoreThreshold) {
        results.add(
          SimilaritySearchResult(
            document: doc.copyWith(score: score),
            score: score,
          ),
        );
      }
    }

    // Sort by score (descending)
    results.sort((a, b) => b.score.compareTo(a.score));

    return results;
  }

  @override
  Future<int> delete(List<String> ids) async {
    final idsSet = ids.toSet();
    final initialCount = _documents.length;

    _documents.removeWhere((doc) => idsSet.contains(doc.id));

    return initialCount - _documents.length;
  }

  @override
  Future<int> count() async {
    return _documents.length;
  }

  @override
  Future<void> clear() async {
    _documents.clear();
    _nextId = 1;
  }

  /// Calculate similarity between two vectors
  static double _calculateSimilarity(
    List<double> vector1,
    List<double> vector2,
    SimilarityMetric metric,
  ) {
    switch (metric) {
      case SimilarityMetric.cosine:
        return _cosineSimilarity(vector1, vector2);
      case SimilarityMetric.euclidean:
        return _euclideanDistance(vector1, vector2);
      case SimilarityMetric.dotProduct:
        return _dotProduct(vector1, vector2);
    }
  }

  /// Calculate cosine similarity between two vectors
  ///
  /// Returns a value between -1 and 1, where:
  /// - 1 = identical vectors
  /// - 0 = orthogonal vectors
  /// - -1 = opposite vectors
  static double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('Vectors must have the same dimension');
    }

    var dotProduct = 0.0;
    var normA = 0.0;
    var normB = 0.0;

    for (var i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    normA = math.sqrt(normA);
    normB = math.sqrt(normB);

    if (normA == 0.0 || normB == 0.0) {
      return 0.0;
    }

    return dotProduct / (normA * normB);
  }

  /// Calculate Euclidean distance between two vectors
  ///
  /// Returns the L2 distance. Smaller values indicate more similar vectors.
  /// This is converted to a similarity score by taking the negative.
  static double _euclideanDistance(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('Vectors must have the same dimension');
    }

    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      final diff = a[i] - b[i];
      sum += diff * diff;
    }

    // Return negative distance so higher values = more similar
    return -math.sqrt(sum);
  }

  /// Calculate dot product between two vectors
  ///
  /// Returns the sum of element-wise products.
  static double _dotProduct(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('Vectors must have the same dimension');
    }

    var product = 0.0;
    for (var i = 0; i < a.length; i++) {
      product += a[i] * b[i];
    }

    return product;
  }
}

/// Similarity metric for vector comparison
enum SimilarityMetric {
  /// Cosine similarity (default) - range [-1, 1]
  cosine,

  /// Euclidean distance (L2) - smaller is more similar
  euclidean,

  /// Dot product - higher is more similar
  dotProduct,
}

/// Vector store exception
class VectorStoreException implements Exception {
  VectorStoreException(this.message);

  final String message;

  @override
  String toString() => 'VectorStoreException: $message';
}
