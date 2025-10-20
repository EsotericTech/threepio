import '../../schema/document.dart';

/// Options for retriever operations
class RetrieverOptions {
  const RetrieverOptions({
    this.topK,
    this.scoreThreshold,
    this.extra,
    this.callbackManager,
    this.context,
    this.metadata,
  });

  /// Maximum number of documents to retrieve
  final int? topK;

  /// Minimum relevance score threshold
  final double? scoreThreshold;

  /// Implementation-specific options
  final Map<String, dynamic>? extra;

  /// Callback manager for execution lifecycle events
  final dynamic callbackManager;

  /// Execution context that flows through callbacks
  final Map<String, dynamic>? context;

  /// Arbitrary metadata to pass through execution
  final Map<String, dynamic>? metadata;

  /// Get the context, creating an empty one if null
  Map<String, dynamic> getOrCreateContext() {
    return context ?? {};
  }
}

/// Interface for document retrieval
///
/// Used to retrieve relevant documents from a source based on a query.
/// Implementations can connect to various backends like vector databases,
/// search engines, or custom data sources.
///
/// Example usage:
/// ```dart
/// final retriever = MyRetriever();
///
/// // Basic retrieval
/// final docs = await retriever.retrieve('machine learning');
///
/// // With options
/// final topDocs = await retriever.retrieve(
///   'machine learning',
///   options: RetrieverOptions(topK: 5),
/// );
///
/// for (final doc in topDocs) {
///   print('${doc.content} (score: ${doc.score})');
/// }
/// ```
abstract class Retriever {
  /// Retrieve documents based on a query string
  ///
  /// Returns a list of documents ordered by relevance score (if available).
  /// The [query] parameter specifies what to search for.
  /// Options can control the number of results, score thresholds, etc.
  ///
  /// Throws if retrieval fails or the query is invalid.
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  });
}
