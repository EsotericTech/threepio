/// A reranker as a document transformer.
library;

import 'package:meta/meta.dart';

import '../../schema/document.dart';
import '../document/transformer.dart';
import 'reranker.dart';

/// The query a [RerankerTransformer] ranks the documents against, as an
/// option of one call:
/// `TransformerOptions(extensions: [RerankQuery('what the user asked')])`.
@immutable
final class RerankQuery {
  /// The [query] of one call.
  const RerankQuery(this.query);

  /// What the documents are ranked against.
  final String query;
}

/// Makes a [Reranker] usable where a [DocumentTransformer] is expected.
///
/// A reranker orders documents by how well they answer a query, and a
/// transformer is only ever given documents. The query therefore comes from
/// one of two places: from the call, as a [RerankQuery] among the extensions
/// of its options, or else from the [query] given here.
///
/// The result has the documents in the order of the ranking, each with its
/// rank score (`Document.score`). Documents the reranker dropped (top-k,
/// threshold) are not in it.
final class RerankerTransformer extends DocumentTransformer {
  /// A transformer that ranks with [reranker].
  ///
  /// [query] is used by calls that bring no [RerankQuery], and [options] by
  /// calls that bring no [RerankerOptions] among their extensions.
  const RerankerTransformer(this.reranker, {this.query, this.options});

  /// The reranker that does the work.
  final Reranker reranker;

  /// The query of calls that do not bring one.
  final String? query;

  /// The reranker options of calls that do not bring any.
  final RerankerOptions? options;

  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async {
    final query = options?.extension<RerankQuery>()?.query ?? this.query;
    if (query == null) {
      throw StateError(
        'RerankerTransformer has no query to rank against. Give it one when '
        'it is created, or pass TransformerOptions(extensions: '
        '[RerankQuery(...)]) with the call.',
      );
    }

    final results = await reranker.rerank(
      query,
      documents,
      options: options?.extension<RerankerOptions>() ?? this.options,
    );
    return [for (final result in results) result.document.withScore(result.score)];
  }
}
