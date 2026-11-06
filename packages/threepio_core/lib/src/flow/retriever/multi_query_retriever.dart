/// A retriever that rewrites the query into several and retrieves for each.
///
/// Port of eino `flow/retriever/multiquery`. The entry point is
/// `MultiQueryRetriever.fromConfig`; the retriever it returns is
/// [FlowMultiQueryRetriever], which no library exports (Go's
/// `multiQueryRetriever` is unexported too).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../components/component_type.dart';
import '../../components/model/base_chat_model.dart';
import '../../components/prompt/chat_template.dart';
import '../../components/retriever/retriever.dart';
import '../../compose/chain.dart';
import '../../compose/graph_options.dart';
import '../../compose/lambda.dart';
import '../../compose/runnable.dart';
import '../../core/run_context.dart';
import '../../schema/document.dart';
import '../../schema/message.dart';
import '../../schema/message_template.dart';
import 'retrieve_utils.dart';

/// How `MultiQueryRetriever.fromConfig` builds its retriever.
///
/// Port of eino `multiquery.Config`. The queries come from one of two
/// places:
///
/// 1. a chat model: [rewriteModel] is asked with [rewriteTemplate] (Eino's
///    prompt for three rewrites when not given), whose variable [queryVar]
///    holds the query, and [outputParser] turns its answer into queries
///    (one per line when not given);
/// 2. [rewriteHandler], a function of your own; when given, it is used and
///    the model fields are ignored.
///
/// At most [maxQueries] of the queries are used. Each is retrieved from
/// [origRetriever], all at the same time, and [fusion] joins the results
/// (the default keeps the first document of each id).
@immutable
final class MultiQueryRetrieverConfig {
  /// The configuration of a multi-query retriever over [origRetriever]. One
  /// of [rewriteModel] and [rewriteHandler] must be given.
  const MultiQueryRetrieverConfig({
    required this.origRetriever,
    this.rewriteModel,
    this.rewriteTemplate,
    this.queryVar = '',
    this.outputParser,
    this.rewriteHandler,
    this.maxQueries = 5,
    this.fusion,
  });

  /// The retriever every query is sent to. Port of `OrigRetriever`.
  final Retriever origRetriever;

  /// The chat model that writes the queries. Port of `RewriteLLM`.
  final BaseChatModel? rewriteModel;

  /// The prompt for [rewriteModel]. Port of `RewriteTemplate`.
  ///
  /// When it is not given, Eino's prompt is used: it asks for three versions
  /// of the query, one per line, and takes the query in its variable `query`
  /// ([queryVar] is then ignored).
  final ChatTemplate? rewriteTemplate;

  /// The variable of [rewriteTemplate] that receives the query. Port of
  /// `QueryVar`. Only read when [rewriteTemplate] is given; as in Eino it
  /// has no default then, so give it with the template.
  final String queryVar;

  /// Turns the answer of [rewriteModel] into the queries. Port of
  /// `LLMOutputParser`. When it is not given, the content of the answer is
  /// split at each line break, as it is: lines are neither trimmed nor
  /// dropped when empty.
  final FutureOr<List<String>> Function(RunContext ctx, Message message)?
      outputParser;

  /// Writes the queries without a chat model. Port of `RewriteHandler`.
  /// When given, it takes precedence over [rewriteModel], [rewriteTemplate],
  /// [queryVar] and [outputParser].
  final FutureOr<List<String>> Function(RunContext ctx, String query)?
      rewriteHandler;

  /// The most queries that are retrieved; the ones after are dropped. Port
  /// of `MaxQueriesNum`. A value of zero or less means 5, the default (Eino
  /// treats zero that way).
  final int maxQueries;

  /// Joins the documents found for each query, given in the order of the
  /// queries, into the result. Port of `FusionFunc`.
  ///
  /// When it is not given, the documents are taken query by query, in
  /// order, and a document whose id was already taken is skipped (a document
  /// without an id counts as having the empty id, as in Eino, where an id is
  /// a string).
  final FutureOr<List<Document>> Function(
    RunContext ctx,
    List<List<Document>> docs,
  )? fusion;
}

/// The retriever `MultiQueryRetriever.fromConfig` returns.
///
/// Port of eino's unexported `multiQueryRetriever`. Internal: use the
/// static method.
@internal
final class FlowMultiQueryRetriever implements Retriever, TypedComponent {
  FlowMultiQueryRetriever._({
    required Runnable<String, List<String>> queryRunner,
    required int maxQueries,
    required Retriever origRetriever,
    required FutureOr<List<Document>> Function(
      RunContext ctx,
      List<List<Document>> docs,
    ) fusion,
  })  : _queryRunner = queryRunner,
        _maxQueries = maxQueries,
        _origRetriever = origRetriever,
        _fusion = fusion;

  /// The retriever of [config]. Port of `multiquery.NewRetriever`: the
  /// chain that writes the queries is compiled here, under [ctx], as the
  /// chain `QueryRewrite`.
  ///
  /// Throws [ArgumentError] when [config] has neither a rewrite model nor a
  /// rewrite handler.
  static Future<FlowMultiQueryRetriever> create(
    RunContext ctx,
    MultiQueryRetrieverConfig config,
  ) async {
    final rewriteHandler = config.rewriteHandler;
    final rewriteModel = config.rewriteModel;
    if (rewriteHandler == null && rewriteModel == null) {
      throw ArgumentError(
        'at least one of rewriteHandler and rewriteModel must be given',
      );
    }

    final chain = Chain<String, List<String>>();
    if (rewriteHandler != null) {
      chain.appendLambda(
        Lambda<String, List<String>>.invokable(rewriteHandler),
        options: const NodeOptions(name: 'CustomQueryRewriter'),
      );
    } else {
      var template = config.rewriteTemplate;
      var variable = config.queryVar;
      if (template == null) {
        template = ChatTemplate.fromMessages(
          FormatType.jinja2,
          [Message.user(defaultRewritePrompt)],
        );
        variable = defaultQueryVariable;
      }
      final parser = config.outputParser ?? _splitLines;
      chain
        ..appendLambda(
          Lambda<String, Map<String, dynamic>>.invokable(
            (ctx, input) => <String, dynamic>{variable: input},
          ),
          options: const NodeOptions(name: 'Converter'),
        )
        ..appendChatTemplate(template)
        ..appendChatModel(rewriteModel!)
        ..appendLambda(
          Lambda<Message, List<String>>.invokable(parser),
          options: const NodeOptions(name: 'OutputParser'),
        );
    }
    final queryRunner = await chain.compile(
      ctx,
      options: const GraphCompileOptions(graphName: 'QueryRewrite'),
    );

    return FlowMultiQueryRetriever._(
      queryRunner: queryRunner,
      maxQueries: config.maxQueries <= 0 ? defaultMaxQueries : config.maxQueries,
      origRetriever: config.origRetriever,
      fusion: config.fusion ?? deduplicateFusion,
    );
  }

  final Runnable<String, List<String>> _queryRunner;
  final int _maxQueries;
  final Retriever _origRetriever;
  final FutureOr<List<Document>> Function(
    RunContext ctx,
    List<List<Document>> docs,
  ) _fusion;

  /// Writes the queries for [query], retrieves each from the original
  /// retriever at the same time, and joins the results with the fusion
  /// function. Port of `multiQueryRetriever.Retrieve`.
  ///
  /// The context of the run is `options.runContext` (a fresh one when it is
  /// not set). Each retrieval is reported to its callback handlers as a
  /// retriever, the fusion as the lambda `FusionFuncLambda`; the chain that
  /// writes the queries reports itself as the chain `QueryRewrite`.
  ///
  /// [options] are passed on to every retrieval (Eino passes none). The
  /// first retrieval that fails, in the order of the queries, fails the
  /// whole call.
  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    final ctx = options?.runContext ?? RunContext.background();

    var queries = await _queryRunner.invoke(ctx, query);
    if (queries.length > _maxQueries) {
      queries = queries.sublist(0, _maxQueries);
    }

    final tasks = [
      for (final query in queries)
        RetrieveTask(retriever: _origRetriever, query: query, options: options),
    ];
    await concurrentRetrieve(ctx, tasks);
    throwFirstFailure(tasks);
    final result = [for (final task in tasks) task.result!];

    return runReported(
      withLambdaRunInfo(ctx, 'FusionFunc'),
      result,
      (ctx, docs) async => _fusion(ctx, docs),
    );
  }

  /// Port of `multiQueryRetriever.GetType`.
  @override
  String get componentTypeName => 'MultiQuery';

  @override
  String toString() =>
      'MultiQueryRetriever.fromConfig(maxQueries: $_maxQueries, '
      'origRetriever: $_origRetriever)';
}

/// The variable of [defaultRewritePrompt] that receives the query. Port of
/// `defaultQueryVariable`.
@internal
const defaultQueryVariable = 'query';

/// How many queries are used when the configuration does not say. Port of
/// `defaultMaxQueriesNum`.
@internal
const defaultMaxQueries = 5;

/// The prompt that asks the rewrite model for three versions of the query,
/// a Jinja2 template with the variable [defaultQueryVariable]. Port of
/// `defaultRewritePrompt`, byte for byte (its odd indentation included).
@internal
const defaultRewritePrompt = _defaultRewritePrompt;

/// The fusion used when the configuration has none: the documents query by
/// query, each id once. Port of eino's unexported `deduplicateFusion`.
@internal
Future<List<Document>> deduplicateFusion(
  RunContext ctx,
  List<List<Document>> docs,
) async {
  final seen = <String>{};
  return [
    for (final list in docs)
      for (final doc in list)
        if (seen.add(doc.id ?? '')) doc,
  ];
}

List<String> _splitLines(RunContext ctx, Message message) =>
    message.content.split('\n');

// Generated from eino v0.9.22 `flow/retriever/multiquery/multi_query.go`
// with `go_consts.py`; the tabs and the space after "newlines." are Go's.
const _defaultRewritePrompt = r'''
You are an helpful assistant.
	Your role is to create three different versions of the user query to retrieve relevant documents from store.
    Your goal is to improve the performance of similarity search by generating text from different perspectives based on the user query.
	Only provide the generated queries and separate them by newlines. 
	user query: {{query}}''';
