import '../../callbacks/callback_context.dart';
import '../../callbacks/callback_manager.dart';
import '../../callbacks/component_callbacks.dart';
import '../../callbacks/global_callbacks.dart';
import '../../callbacks/run_info.dart';
import '../../core/run_context.dart';
import '../../schema/document.dart';
import '../component_type.dart';
import '../embedding/embedder.dart';
import '../vector_store/vector_store.dart';
import 'retriever.dart';
import 'retriever_callbacks.dart';

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
///
/// Each retrieval is reported to the callback handlers of its run
/// (`options.runContext`, and the global handlers), as the retrievers of
/// eino-ext report theirs: a [RetrieverCallbackInput] with the query, the
/// number of documents asked for and the score threshold, then a
/// [RetrieverCallbackOutput] with the documents, or the error. The embedder
/// is called in a context in which it has been introduced as an embedder
/// named after its implementation. A legacy `callbackManager` in the options
/// is still called as well.
class VectorRetriever
    implements Retriever, TypedComponent, CallbackAwareComponent {
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

  /// The implementation name, which shows in traces as `VectorRetriever`.
  /// Port of eino `components.Typer`.
  @override
  String get componentTypeName => 'Vector';

  /// `true`: the retriever fires its callbacks itself, so a graph does not
  /// fire them around it. Port of eino `components.Checker`.
  @override
  bool get isCallbacksEnabled => true;

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
        () => _reported(
          query,
          options,
          (embedderOptions) =>
              _retrieveInternal(query, options, embedderOptions),
          (docs) => docs,
        ),
      );
    } else {
      return _reported(
        query,
        options,
        (embedderOptions) => _retrieveInternal(query, options, embedderOptions),
        (docs) => docs,
      );
    }
  }

  Future<List<Document>> _retrieveInternal(
    String query,
    RetrieverOptions? options,
    EmbedderOptions? embedderOptions,
  ) async {
    // Embed the query, with the embedder of the call if it brings one
    final embeddings = await (options?.embedding ?? embedder).embedStrings(
      [query],
      options: embedderOptions,
    );
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
        () => _reported(
          query,
          options,
          (embedderOptions) =>
              _retrieveWithScoresInternal(query, options, embedderOptions),
          _documentsOf,
        ),
      );
    } else {
      return _reported(
        query,
        options,
        (embedderOptions) =>
            _retrieveWithScoresInternal(query, options, embedderOptions),
        _documentsOf,
      );
    }
  }

  static List<Document> _documentsOf(List<SimilaritySearchResult> results) =>
      [for (final result in results) result.document];

  /// Runs [retrieve] between the start callback and the end or error
  /// callback of the run, as eino-ext's retrievers do (`EnsureRunInfo`,
  /// `OnStart` with a `retriever.CallbackInput`, `OnEnd` with a
  /// `retriever.CallbackOutput`, `OnError`). [retrieve] gets the options for
  /// the embedder.
  ///
  /// Without any handler to report to (none in the run context, none
  /// global) nothing is fired and the embedder gets the run context of the
  /// call as it is.
  Future<T> _reported<T>(
    String query,
    RetrieverOptions? options,
    Future<T> Function(EmbedderOptions? embedderOptions) retrieve,
    List<Document> Function(T result) documentsOf,
  ) async {
    final runContext = options?.runContext;
    final base = runContext ??
        (GlobalCallbacks.isEmpty ? null : RunContext.background());
    if (base == null) return retrieve(null);
    var ctx = ensureRunInfo(base, componentTypeName, ComponentType.retriever);
    if (!ctx.hasCallbacks) {
      return retrieve(
        runContext == null ? null : EmbedderOptions(runContext: runContext),
      );
    }

    ctx = await onStart(
      ctx,
      RetrieverCallbackInput(
        query: query,
        topK: options?.topK ?? defaultTopK,
        scoreThreshold: options?.scoreThreshold,
      ),
    );
    final T result;
    try {
      result = await retrieve(
        EmbedderOptions(
          runContext: _embeddingContext(ctx, options?.embedding ?? embedder),
        ),
      );
    } catch (error, stackTrace) {
      await onError(ctx, error, stackTrace);
      rethrow;
    }
    await onEnd(ctx, RetrieverCallbackOutput(docs: documentsOf(result)));
    return result;
  }

  /// [ctx] with the run info of [embedder], for its callbacks. Port of the
  /// `makeEmbeddingCtx` of eino-ext's retrievers.
  static RunContext _embeddingContext(RunContext ctx, Embedder embedder) {
    final type = componentTypeNameOf(embedder) ?? '';
    return reuseHandlers(
      ctx,
      RunInfo(
        name: '$type${ComponentType.embedder.einoName}',
        type: type,
        componentType: ComponentType.embedder,
      ),
    );
  }

  Future<List<SimilaritySearchResult>> _retrieveWithScoresInternal(
    String query,
    RetrieverOptions? options,
    EmbedderOptions? embedderOptions,
  ) async {
    // Embed the query, with the embedder of the call if it brings one
    final embeddings = await (options?.embedding ?? embedder).embedStrings(
      [query],
      options: embedderOptions,
    );
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
