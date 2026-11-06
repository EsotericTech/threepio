import '../../core/run_context.dart';
import '../../flow/retriever/multi_query_retriever.dart';
import '../../schema/document.dart';
import '../../schema/message.dart';
import '../embedding/embedder.dart';
import '../model/base_chat_model.dart';
import 'fusion/deduplication.dart';
import 'fusion/result_fusion.dart';
import 'fusion/scored_document.dart';
import 'retriever.dart';

export '../../flow/retriever/multi_query_retriever.dart'
    show MultiQueryRetrieverConfig;

/// A retriever that generates multiple query variants using an LLM
/// and fuses the results.
///
/// Multi-query retrieval improves recall by:
/// 1. Using an LLM to generate alternative phrasings of the original query
/// 2. Running each query variant through the base retriever
/// 3. Fusing results using Reciprocal Rank Fusion (RRF)
///
/// This is particularly effective for ambiguous queries or when users
/// don't know the exact terminology in the document corpus.
///
/// Example:
/// ```dart
/// final multiRetriever = MultiQueryRetriever(
///   baseRetriever: vectorRetriever,
///   chatModel: openAIModel,
///   numQueries: 3,
/// );
///
/// // Original query: "How do I debug?"
/// // LLM generates: ["debugging techniques", "troubleshooting errors", "finding bugs"]
/// // All queries run in parallel, results fused with RRF
/// final docs = await multiRetriever.retrieve('How do I debug?');
/// ```
///
/// [MultiQueryRetriever.fromConfig] builds the retriever as Eino does
/// instead (`flow/retriever/multiquery`): its own prompt, a handler in place
/// of the model if wanted, and fusion by document id.
class MultiQueryRetriever implements Retriever {
  MultiQueryRetriever({
    required this.baseRetriever,
    required this.chatModel,
    this.numQueries = 3,
    this.fusionStrategy,
    this.deduplicationStrategy,
    this.includeOriginalQuery = true,
    this.queryGenerationPrompt,
    this.parseQueriesFunction,
  });

  /// A multi-query retriever as Eino builds it: the queries come from a
  /// chat model or a handler, at most [MultiQueryRetrieverConfig.maxQueries]
  /// of them are retrieved from the original retriever at the same time, and
  /// the results are fused (by default each document id once, first come
  /// first served).
  ///
  /// Port of eino `multiquery.NewRetriever`:
  ///
  /// ```dart
  /// final retriever = await MultiQueryRetriever.fromConfig(
  ///   ctx,
  ///   MultiQueryRetrieverConfig(
  ///     origRetriever: vectorRetriever,
  ///     rewriteModel: chatModel,
  ///   ),
  /// );
  /// final docs = await retriever.retrieve('how to build agent with eino');
  /// ```
  ///
  /// The chain that writes the queries is compiled here, under [ctx], which
  /// is why this is asynchronous (Go's `NewRetriever(ctx, config)` compiles
  /// it too; the retrievals use the context of each call instead). The
  /// result is a [Retriever], not a [MultiQueryRetriever] (Eino's
  /// constructor returns the `retriever.Retriever` interface too): it has
  /// none of this class's settings and behaves as described at
  /// [MultiQueryRetrieverConfig]. It reports its steps to the callback
  /// handlers of the run (`options.runContext`): the rewrite as the chain
  /// `QueryRewrite`, every retrieval as a retriever, the fusion as the
  /// lambda `FusionFuncLambda`. Its implementation name is `MultiQuery`.
  /// Unlike Eino's, it passes the options of `retrieve` on to the original
  /// retriever (all of them, so a legacy `callbackManager` and its `context`
  /// map reach every one of the concurrent retrievals).
  ///
  /// Throws [ArgumentError] when [config] has neither a rewrite model nor a
  /// rewrite handler.
  static Future<Retriever> fromConfig(
    RunContext ctx,
    MultiQueryRetrieverConfig config,
  ) =>
      FlowMultiQueryRetriever.create(ctx, config);

  /// The base retriever to use for each query.
  final Retriever baseRetriever;

  /// Chat model for generating query variants.
  final BaseChatModel chatModel;

  /// Number of query variants to generate.
  final int numQueries;

  /// Strategy for fusing results. Defaults to RRF with k=60.
  final ResultFusionStrategy? fusionStrategy;

  /// Strategy for deduplicating results. Defaults to ID deduplication.
  final DeduplicationStrategy? deduplicationStrategy;

  /// Whether to include the original query in retrieval.
  final bool includeOriginalQuery;

  /// Custom prompt for query generation. Defaults to a standard prompt.
  final String? queryGenerationPrompt;

  /// Custom function for parsing generated queries from LLM response.
  final List<String> Function(String response)? parseQueriesFunction;

  static const _defaultPrompt = '''You are an AI assistant that helps generate alternative search queries.
Given a user's question, generate {num_queries} different versions of the question that could help find relevant information.
The questions should:
- Be different phrasings of the same underlying question
- Use different keywords and terminology
- Capture different aspects of what the user might be looking for

Original question: {question}

Generate exactly {num_queries} alternative questions, one per line.
Do not include numbers, bullets, or any other formatting.
Just write each question on its own line.''';

  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    // Generate query variants
    final queries = await _generateQueryVariants(query);

    // Collect all queries to run (including original if configured)
    final allQueries = <String>[
      if (includeOriginalQuery) query,
      ...queries,
    ];

    // Run all queries in parallel
    final resultFutures = allQueries.map(
      (q) => _retrieveForQuery(q, options),
    );
    final resultSets = await Future.wait(resultFutures);

    // Fuse results
    final strategy = fusionStrategy ?? const ReciprocalRankFusion();
    final fusedResults = strategy.fuse(resultSets);

    // Deduplicate
    final dedupStrategy = deduplicationStrategy ?? const IdDeduplication();
    final deduplicated = await dedupStrategy.deduplicate(fusedResults);

    // Apply topK if specified
    final topK = options?.topK;
    final finalResults = topK != null && deduplicated.length > topK
        ? deduplicated.take(topK).toList()
        : deduplicated;

    // Convert back to Documents
    return finalResults.map((sd) => sd.document).toList();
  }

  /// Retrieve with full scored documents for access to fusion metadata.
  Future<List<ScoredDocument>> retrieveWithScores(
    String query, {
    RetrieverOptions? options,
  }) async {
    final queries = await _generateQueryVariants(query);

    final allQueries = <String>[
      if (includeOriginalQuery) query,
      ...queries,
    ];

    final resultFutures = allQueries.map(
      (q) => _retrieveForQuery(q, options),
    );
    final resultSets = await Future.wait(resultFutures);

    final strategy = fusionStrategy ?? const ReciprocalRankFusion();
    final fusedResults = strategy.fuse(resultSets);

    final dedupStrategy = deduplicationStrategy ?? const IdDeduplication();
    final deduplicated = await dedupStrategy.deduplicate(fusedResults);

    final topK = options?.topK;
    return topK != null && deduplicated.length > topK
        ? deduplicated.take(topK).toList()
        : deduplicated;
  }

  /// Generate alternative query variants using the LLM.
  Future<List<String>> _generateQueryVariants(String query) async {
    final prompt = (queryGenerationPrompt ?? _defaultPrompt)
        .replaceAll('{question}', query)
        .replaceAll('{num_queries}', numQueries.toString());

    final response = await chatModel.generate([
      Message.user(prompt),
    ]);

    final responseText = response.content;

    // Parse queries from response
    if (parseQueriesFunction != null) {
      return parseQueriesFunction!(responseText);
    }

    return _defaultParseQueries(responseText);
  }

  List<String> _defaultParseQueries(String response) {
    // Split by newlines and filter empty lines
    final lines = response
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .where((line) => !line.startsWith('#')) // Remove markdown headers
        .map((line) {
          // Remove common prefixes like "1.", "- ", "* "
          var cleaned = line;
          cleaned = cleaned.replaceFirst(RegExp(r'^\d+[\.\)]\s*'), '');
          cleaned = cleaned.replaceFirst(RegExp(r'^[-\*•]\s*'), '');
          return cleaned.trim();
        })
        .where((line) => line.isNotEmpty)
        .take(numQueries)
        .toList();

    return lines;
  }

  Future<List<ScoredDocument>> _retrieveForQuery(
    String query,
    RetrieverOptions? options,
  ) async {
    final docs = await baseRetriever.retrieve(query, options: options);

    // Convert to scored documents with rank
    return docs.asMap().entries.map((entry) {
      return ScoredDocument(
        document: entry.value,
        score: entry.value.score ?? (1.0 / (entry.key + 1)), // Use score or compute from rank
        sourceId: 'query_${query.hashCode}',
        rank: entry.key + 1,
      );
    }).toList();
  }
}

/// Options specific to multi-query retrieval.
class MultiQueryRetrieverOptions extends RetrieverOptions {
  const MultiQueryRetrieverOptions({
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
    this.customQueries,
    this.skipQueryGeneration = false,
  });

  /// Provide custom queries instead of generating them.
  final List<String>? customQueries;

  /// Skip LLM query generation and use only the original query.
  final bool skipQueryGeneration;

  @override
  MultiQueryRetrieverOptions copyWith({
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
    List<String>? customQueries,
    bool? skipQueryGeneration,
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
        customQueries: customQueries ?? this.customQueries,
        skipQueryGeneration: skipQueryGeneration ?? this.skipQueryGeneration,
      );

  /// These options with what [other] sets taking precedence. The fields of
  /// this class are taken from [other] when it is a
  /// [MultiQueryRetrieverOptions], and kept otherwise.
  @override
  MultiQueryRetrieverOptions merge(RetrieverOptions? other) {
    if (other == null) return this;
    final multiQuery = other is MultiQueryRetrieverOptions ? other : null;
    return _from(
      super.merge(other),
      customQueries: multiQuery?.customQueries ?? customQueries,
      skipQueryGeneration:
          multiQuery?.skipQueryGeneration ?? skipQueryGeneration,
    );
  }

  static MultiQueryRetrieverOptions _from(
    RetrieverOptions base, {
    required List<String>? customQueries,
    required bool skipQueryGeneration,
  }) =>
      MultiQueryRetrieverOptions(
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
        customQueries: customQueries,
        skipQueryGeneration: skipQueryGeneration,
      );
}
