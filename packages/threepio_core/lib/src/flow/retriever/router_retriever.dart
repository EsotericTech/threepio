/// A retriever that sends the query to the retrievers a router picks and
/// fuses what they find.
///
/// Port of eino `flow/retriever/router`. The entry point is
/// `RouterRetriever.fromConfig`; the retriever it returns is
/// [FlowRouterRetriever], which no library exports (Go's `routerRetriever`
/// is unexported too).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../components/component_type.dart';
import '../../components/retriever/retriever.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/document.dart';
import 'retrieve_utils.dart';

/// The retriever `RouterRetriever.fromConfig` returns.
///
/// Port of eino's unexported `routerRetriever`. Internal: use the static
/// method.
@internal
final class FlowRouterRetriever implements Retriever, TypedComponent {
  /// The retriever of `router.NewRetriever`. Throws [ArgumentError] when
  /// [retrievers] is empty.
  ///
  /// Without a [router], every retriever is asked, in the order of
  /// [retrievers]. Without a [fusion], the results are fused by reciprocal
  /// rank ([rrfFusion]).
  FlowRouterRetriever({
    required Map<String, Retriever> retrievers,
    FutureOr<List<String>> Function(RunContext ctx, String query)? router,
    FutureOr<List<Document>> Function(
      RunContext ctx,
      Map<String, List<Document>> result,
    )? fusion,
  })  : _retrievers = Map.unmodifiable(retrievers),
        _router = router ?? _routeToAll(retrievers.keys.toList()),
        _fusion = fusion ?? rrfFusion {
    if (retrievers.isEmpty) throw ArgumentError('retrievers is empty');
  }

  final Map<String, Retriever> _retrievers;
  final FutureOr<List<String>> Function(RunContext ctx, String query) _router;
  final FutureOr<List<Document>> Function(
    RunContext ctx,
    Map<String, List<Document>> result,
  ) _fusion;

  static FutureOr<List<String>> Function(RunContext ctx, String query)
      _routeToAll(List<String> names) {
    final all = List<String>.unmodifiable(names);
    return (ctx, query) => all;
  }

  /// Asks the router which retrievers to use, retrieves [query] from each
  /// of them at the same time, and fuses the results. Port of
  /// `routerRetriever.Retrieve`.
  ///
  /// The context of the run is `options.runContext` (a fresh one when it is
  /// not set). The router is reported to its callback handlers as the lambda
  /// `RouterLambda` (input the query, output the names), each retrieval as a
  /// retriever, the fusion as the lambda `FusionFuncLambda` (input the
  /// results by name). [options] are passed on to every retrieval.
  ///
  /// Throws [ThreepioException] when the router picks no retriever or a name
  /// that is not one of the retrievers; the first retrieval that fails, in
  /// the router's order, fails the whole call.
  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    final ctx = options?.runContext ?? RunContext.background();

    final names = await runReported(
      withLambdaRunInfo(ctx, 'Router'),
      query,
      (ctx, query) async {
        final names = await _router(ctx, query);
        if (names.isEmpty) {
          throw const ThreepioException('no retriever has been selected');
        }
        return names;
      },
    );

    final tasks = <RetrieveTask>[];
    for (final name in names) {
      final retriever = _retrievers[name];
      if (retriever == null) {
        throw ThreepioException('router output[$name] has not registered');
      }
      tasks.add(
        RetrieveTask(
          name: name,
          retriever: retriever,
          query: query,
          options: options,
        ),
      );
    }
    await concurrentRetrieve(ctx, tasks);
    throwFirstFailure(tasks);
    final result = <String, List<Document>>{
      for (final task in tasks) task.name: task.result!,
    };

    return runReported(
      withLambdaRunInfo(ctx, 'FusionFunc'),
      result,
      (ctx, result) async => _fusion(ctx, result),
    );
  }

  /// Port of `routerRetriever.GetType`.
  @override
  String get componentTypeName => 'Router';

  @override
  String toString() =>
      'RouterRetriever.fromConfig(retrievers: ${_retrievers.keys.toList()})';
}

/// Reciprocal rank fusion, the fusion of a router retriever when none is
/// given. Port of eino's unexported `rrf`.
///
/// A document scores `1 / (60 + rank)` in each list it is in (rank 0 for
/// the first) and the scores add up; documents are matched by id (a
/// document without an id counts as having the empty id, as in Eino, where
/// an id is a string), and for an id in several lists the document of the
/// last list is returned. The result is sorted by score, highest first;
/// documents with equal scores keep the order in which their ids first
/// appeared (Go's order there depends on map iteration and is random).
///
/// With a single list, that list is returned as it is, without matching
/// ids. An empty [result] is a [ThreepioException] (`no documents`).
@internal
Future<List<Document>> rrfFusion(
  RunContext ctx,
  Map<String, List<Document>> result,
) async {
  if (result.isEmpty) throw const ThreepioException('no documents');
  if (result.length == 1) return result.values.single;

  final scores = <String, double>{};
  final docs = <String, Document>{};
  for (final list in result.values) {
    for (final (rank, doc) in list.indexed) {
      final id = doc.id ?? '';
      docs[id] = doc;
      scores[id] = (scores[id] ?? 0) + 1.0 / (rank + 60);
    }
  }

  final ids = docs.keys.toList();
  final firstSeen = {for (final (index, id) in ids.indexed) id: index};
  ids.sort((a, b) {
    final byScore = scores[b]!.compareTo(scores[a]!);
    return byScore != 0 ? byScore : firstSeen[a]!.compareTo(firstSeen[b]!);
  });
  return [for (final id in ids) docs[id]!];
}
