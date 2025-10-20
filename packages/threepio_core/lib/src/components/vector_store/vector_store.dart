import '../../schema/document.dart';

/// Options for vector store operations
class VectorStoreOptions {
  const VectorStoreOptions({
    this.extra,
    this.callbackManager,
    this.context,
  });

  /// Implementation-specific options
  final Map<String, dynamic>? extra;

  /// Callback manager for execution lifecycle events
  final dynamic callbackManager;

  /// Execution context that flows through callbacks
  final Map<String, dynamic>? context;
}

/// Result from a similarity search
class SimilaritySearchResult {
  const SimilaritySearchResult({
    required this.document,
    required this.score,
  });

  /// The retrieved document
  final Document document;

  /// Similarity score (typically between 0.0 and 1.0, higher is more similar)
  final double score;

  @override
  String toString() =>
      'SimilaritySearchResult(score: $score, content: ${document.content.substring(0, document.content.length > 50 ? 50 : document.content.length)}...)';
}

/// Interface for vector storage and retrieval
///
/// A vector store persists documents along with their embedding vectors
/// and enables similarity-based retrieval. Documents are stored with
/// their embeddings and can be retrieved based on semantic similarity.
///
/// Example usage:
/// ```dart
/// final vectorStore = MyVectorStore();
///
/// // Add documents with embeddings
/// await vectorStore.addDocuments([
///   Document(content: 'Hello world', embedding: [0.1, 0.2, 0.3]),
///   Document(content: 'Goodbye world', embedding: [0.2, 0.3, 0.4]),
/// ]);
///
/// // Search for similar documents
/// final results = await vectorStore.similaritySearch(
///   queryEmbedding: [0.15, 0.25, 0.35],
///   k: 2,
/// );
///
/// for (final result in results) {
///   print('Score: ${result.score}, Content: ${result.document.content}');
/// }
/// ```
abstract class VectorStore {
  /// Add documents to the vector store
  ///
  /// Documents must have their embedding field populated before adding.
  /// Throws if documents are missing embeddings.
  Future<void> addDocuments(
    List<Document> documents, {
    VectorStoreOptions? options,
  });

  /// Search for documents similar to a query embedding
  ///
  /// Returns the [k] most similar documents along with their similarity scores.
  /// Results are sorted by similarity (most similar first).
  ///
  /// The [queryEmbedding] must have the same dimension as stored embeddings.
  /// Throws if dimensions don't match.
  Future<List<SimilaritySearchResult>> similaritySearch({
    required List<double> queryEmbedding,
    int k = 4,
    VectorStoreOptions? options,
  });

  /// Search for documents similar to a query embedding with a score threshold
  ///
  /// Returns all documents with a similarity score >= [scoreThreshold].
  /// Results are sorted by similarity (most similar first).
  ///
  /// The [queryEmbedding] must have the same dimension as stored embeddings.
  Future<List<SimilaritySearchResult>> similaritySearchWithThreshold({
    required List<double> queryEmbedding,
    required double scoreThreshold,
    VectorStoreOptions? options,
  });

  /// Delete documents from the vector store
  ///
  /// Removes documents matching the given IDs.
  /// Returns the number of documents deleted.
  Future<int> delete(List<String> ids);

  /// Get the total number of documents in the store
  Future<int> count();

  /// Clear all documents from the vector store
  Future<void> clear();
}
