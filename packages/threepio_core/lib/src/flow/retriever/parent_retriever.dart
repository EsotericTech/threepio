/// A retriever that finds small documents and returns the documents they
/// were cut from.
///
/// Port of eino `flow/retriever/parent`. The entry point is
/// `ParentRetriever.fromConfig`; the retriever it returns is
/// [FlowParentRetriever], which no library exports (Go's `parentRetriever`
/// is unexported too).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../components/retriever/retriever.dart';
import '../../core/run_context.dart';
import '../../schema/document.dart';

/// The retriever `ParentRetriever.fromConfig` returns.
///
/// Port of eino's unexported `parentRetriever`. Internal: use the static
/// method.
@internal
final class FlowParentRetriever implements Retriever {
  /// The retriever of `parent.NewRetriever`.
  FlowParentRetriever({
    required this.retriever,
    required this.parentIdKey,
    required this.origDocGetter,
  });

  /// The retriever that finds the sub-documents. Port of `Retriever`.
  final Retriever retriever;

  /// The metadata key under which a sub-document keeps the id of its
  /// parent. Port of `ParentIDKey`.
  final String parentIdKey;

  /// Fetches the parent documents by their ids. Port of `OrigDocGetter`.
  final FutureOr<List<Document>> Function(RunContext ctx, List<String> ids)
      origDocGetter;

  /// Retrieves the sub-documents for [query] and returns their parents.
  /// Port of `parentRetriever.Retrieve`.
  ///
  /// [options] go to the inner retriever as they are. The parent ids are
  /// read from the sub-documents' metadata under the parent id key, in the
  /// order the sub-documents came in, each once; a sub-document without
  /// that key, or with a value there that is not a string, is skipped. The
  /// documents the getter returns for those ids are the result, as they
  /// are. The getter is called even when there are no ids, with the context
  /// of the run (`options.runContext`, or a fresh one).
  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async {
    final subDocs = await retriever.retrieve(query, options: options);
    final seen = <String>{};
    final ids = <String>[
      for (final subDoc in subDocs)
        if (subDoc.metadata[parentIdKey] case final String id
            when seen.add(id))
          id,
    ];
    return origDocGetter(options?.runContext ?? RunContext.background(), ids);
  }

  @override
  String toString() => 'ParentRetriever.fromConfig(parentIdKey: '
      '$parentIdKey, retriever: $retriever)';
}
