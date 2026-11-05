import '../../core/run_context.dart';
import '../../internal/option_extensions.dart';
import '../../schema/document.dart';
import '../embedding/embedder.dart';

/// Options for retriever operations
///
/// Port of eino `retriever.Options`. Go passes a list of `retriever.Option`
/// functions (`WithTopK`, `WithIndex`, …); here one immutable object carries
/// the same settings, and [merge] takes the place of applying options one
/// after the other.
///
/// Which of the settings mean something depends on the retriever: one whose
/// store has a single index has no use for [index], for example. A retriever
/// ignores the settings it does not support.
class RetrieverOptions {
  const RetrieverOptions({
    this.topK,
    this.scoreThreshold,
    this.extra,
    this.callbackManager,
    this.context,
    this.metadata,
    this.index,
    this.subIndex,
    this.embedding,
    this.dslInfo,
    this.runContext,
    this.extensions = const [],
  });

  /// Maximum number of documents to retrieve
  final int? topK;

  /// Minimum relevance score threshold
  final double? scoreThreshold;

  /// The index to search, for a retriever whose store has several (Eino:
  /// `retriever.WithIndex`).
  final String? index;

  /// The part of the index to search (Eino: `retriever.WithSubIndex`).
  final String? subIndex;

  /// The embedder that turns the query into a vector for this call, instead
  /// of the one the retriever was built with (Eino:
  /// `retriever.WithEmbedding`).
  final Embedder? embedding;

  /// A filter or query in the language of the store behind the retriever
  /// (Eino: `retriever.WithDSLInfo`). What it has to look like is up to the
  /// retriever.
  final Map<String, Object?>? dslInfo;

  /// Implementation-specific options
  final Map<String, dynamic>? extra;

  /// Callback manager for execution lifecycle events
  ///
  /// Belongs to the callback API threepio had before [runContext]. It keeps
  /// working: a retriever that reports to a `CallbackManager` still does.
  @Deprecated(
    'Put the handlers on the run context instead: '
    'runContext: ctx.withHandlers([...]). The CallbackManager given here '
    'keeps being called.',
  )
  final dynamic callbackManager;

  /// Execution context that flows through callbacks
  ///
  /// Belongs to the callback API threepio had before [runContext]: it is the
  /// map the handlers of a `CallbackManager` pass along.
  @Deprecated(
    'Use runContext, the context of the run, instead. The map given here '
    'keeps being passed to the handlers of callbackManager.',
  )
  final Map<String, dynamic>? context;

  /// Arbitrary metadata to pass through execution
  final Map<String, dynamic>? metadata;

  /// The context of the run this call belongs to: its cancellation and its
  /// values.
  ///
  /// [Retriever.retrieve] keeps the signature it had before [RunContext]
  /// existed, so the context travels here. A graph sets it for its retriever
  /// nodes.
  final RunContext? runContext;

  /// Options that only one implementation understands, each an instance of a
  /// class that implementation defines.
  ///
  /// The counterpart of eino's `retriever.WrapImplSpecificOptFn`.
  final List<Object> extensions;

  /// The first of the [extensions] that is a [T], or `null`.
  ///
  /// The counterpart of eino's `retriever.GetImplSpecificOptions`.
  T? extension<T extends Object>() => findExtension<T>(extensions);

  /// A copy with the given fields replaced.
  ///
  /// A subclass that adds fields overrides this to keep them.
  RetrieverOptions copyWith({
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
  }) =>
      RetrieverOptions(
        topK: topK ?? this.topK,
        scoreThreshold: scoreThreshold ?? this.scoreThreshold,
        extra: extra ?? this.extra,
        callbackManager: callbackManager,
        context: context,
        metadata: metadata ?? this.metadata,
        index: index ?? this.index,
        subIndex: subIndex ?? this.subIndex,
        embedding: embedding ?? this.embedding,
        dslInfo: dslInfo ?? this.dslInfo,
        runContext: runContext ?? this.runContext,
        extensions: extensions ?? this.extensions,
      );

  /// These options with what [other] sets taking precedence, field by field.
  /// The [extensions] of both are kept, those of [other] first.
  ///
  /// A subclass that adds fields overrides this to keep them.
  RetrieverOptions merge(RetrieverOptions? other) => other == null
      ? this
      : RetrieverOptions(
          topK: other.topK ?? topK,
          scoreThreshold: other.scoreThreshold ?? scoreThreshold,
          extra: other.extra ?? extra,
          callbackManager: other.callbackManager ?? callbackManager,
          context: other.context ?? context,
          metadata: other.metadata ?? metadata,
          index: other.index ?? index,
          subIndex: other.subIndex ?? subIndex,
          embedding: other.embedding ?? embedding,
          dslInfo: other.dslInfo ?? dslInfo,
          runContext: other.runContext ?? runContext,
          extensions: mergeExtensions(extensions, other.extensions),
        );

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
