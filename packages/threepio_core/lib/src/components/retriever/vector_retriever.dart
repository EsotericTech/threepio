import '../../callbacks/callback_handler.dart';
import '../../callbacks/callback_manager.dart';
import '../../callbacks/run_info.dart';
import '../../schema/document.dart';
import '../embedding/embedder.dart';
import '../vector_store/vector_store.dart';
import 'retriever.dart';

/// Vector-based document retriever
///
/// Retrieves documents from a vector store by converting the query to
/// an embedding and performing similarity search. This enables semantic
/// search where documents are retrieved based on meaning rather than
/// exact keyword matches.
///
/// Example usage:
/// ```dart
/// // Setup embedder and vector store
/// final embedder = OpenAIEmbedder(config: openAIConfig);
/// final vectorStore = InMemoryVectorStore();
///
/// // Add documents to the store
/// final docs = [
///   Document.simple('Paris is the capital of France'),
///   Document.simple('Berlin is the capital of Germany'),
/// ];
///
/// // Embed and store
/// for (final doc in docs) {
///   final embeddings = await embedder.embedStrings([doc.content]);
///   await vectorStore.addDocuments([
///     doc.copyWith(embedding: embeddings.first),
///   ]);
/// }
///
/// // Create retriever
/// final retriever = VectorRetriever(
///   embedder: embedder,
///   vectorStore: vectorStore,
/// );
///
/// // Retrieve relevant documents
/// final results = await retriever.retrieve(
///   'What is the capital of France?',
///   options: RetrieverOptions(topK: 2),
/// );
///
/// for (final doc in results) {
///   print('${doc.content} (score: ${doc.score})');
/// }
/// ```
class VectorRetriever implements Retriever {
  VectorRetriever({
    required this.embedder,
    required this.vectorStore,
    this.defaultTopK = 4,
  });

  /// Embedder for converting queries to vectors
  final Embedder embedder;

  /// Vector store for similarity search
  final VectorStore vectorStore;

  /// Default number of documents to retrieve
  final int defaultTopK;

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    // Get callback manager if available
    final callbackManager = options?.callbackManager as CallbackManager?;

    if (callbackManager != null) {
      final runInfo = RunInfo(
        name: 'VectorRetriever',
        type: 'VectorRetriever',
        componentType: ComponentType.retriever,
        metadata: {
          'query_length': query.length,
          'top_k': options?.topK ?? defaultTopK,
          'score_threshold': options?.scoreThreshold,
          ...?options?.metadata,
        },
      );

      return await callbackManager.runWithCallbacks(
        options?.getOrCreateContext() ?? {},
        runInfo,
        query,
        () => _retrieveInternal(query, options),
      );
    } else {
      return _retrieveInternal(query, options);
    }
  }

  Future<List<Document>> _retrieveInternal(
    String query,
    RetrieverOptions? options,
  ) async {
    // Embed the query
    final embeddings = await embedder.embedStrings([query]);
    final queryEmbedding = embeddings.first;

    final topK = options?.topK ?? defaultTopK;
    final scoreThreshold = options?.scoreThreshold;

    // Perform similarity search
    final List<SimilaritySearchResult> results;

    if (scoreThreshold != null) {
      // Use threshold-based search
      results = await vectorStore.similaritySearchWithThreshold(
        queryEmbedding: queryEmbedding,
        scoreThreshold: scoreThreshold,
      );

      // Still respect topK if provided
      if (results.length > topK) {
        return results.take(topK).map((r) => r.document).toList();
      }
    } else {
      // Use regular k-based search
      results = await vectorStore.similaritySearch(
        queryEmbedding: queryEmbedding,
        k: topK,
      );
    }

    // Extract documents from results
    return results.map((r) => r.document).toList();
  }

  /// Retrieve documents with full similarity scores
  ///
  /// Returns SimilaritySearchResult objects that include both the document
  /// and its similarity score. Useful when you need access to the raw scores.
  Future<List<SimilaritySearchResult>> retrieveWithScores(
    String query, {
    RetrieverOptions? options,
  }) async {
    // Get callback manager if available
    final callbackManager = options?.callbackManager as CallbackManager?;

    if (callbackManager != null) {
      final runInfo = RunInfo(
        name: 'VectorRetriever.retrieveWithScores',
        type: 'VectorRetriever',
        componentType: ComponentType.retriever,
        metadata: {
          'query_length': query.length,
          'top_k': options?.topK ?? defaultTopK,
          'score_threshold': options?.scoreThreshold,
          ...?options?.metadata,
        },
      );

      return await callbackManager.runWithCallbacks(
        options?.getOrCreateContext() ?? {},
        runInfo,
        query,
        () => _retrieveWithScoresInternal(query, options),
      );
    } else {
      return _retrieveWithScoresInternal(query, options);
    }
  }

  Future<List<SimilaritySearchResult>> _retrieveWithScoresInternal(
    String query,
    RetrieverOptions? options,
  ) async {
    // Embed the query
    final embeddings = await embedder.embedStrings([query]);
    final queryEmbedding = embeddings.first;

    final topK = options?.topK ?? defaultTopK;
    final scoreThreshold = options?.scoreThreshold;

    // Perform similarity search
    if (scoreThreshold != null) {
      final results = await vectorStore.similaritySearchWithThreshold(
        queryEmbedding: queryEmbedding,
        scoreThreshold: scoreThreshold,
      );

      // Still respect topK if provided
      if (results.length > topK) {
        return results.take(topK).toList();
      }

      return results;
    } else {
      return await vectorStore.similaritySearch(
        queryEmbedding: queryEmbedding,
        k: topK,
      );
    }
  }
}
