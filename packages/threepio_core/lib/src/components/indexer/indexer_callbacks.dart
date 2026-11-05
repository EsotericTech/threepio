/// What an indexer reports to callback handlers.
///
/// Port of eino `components/indexer/callback_extra.go`.
library;

import 'package:meta/meta.dart';

import '../../schema/document.dart';

/// The input of an indexing call, as callback handlers see it.
///
/// Port of eino `indexer.CallbackInput`.
@immutable
final class IndexerCallbackInput {
  /// The input of a call that stores [docs].
  const IndexerCallbackInput({required this.docs, this.extra});

  /// The documents to store.
  final List<Document> docs;

  /// Whatever else the indexer wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the input of an indexing call, or returns `null` when it
  /// is not one.
  ///
  /// Port of eino `indexer.ConvCallbackInput`: accepts an
  /// [IndexerCallbackInput] or the plain list of documents a graph node
  /// reports.
  static IndexerCallbackInput? from(Object? raw) => switch (raw) {
        final IndexerCallbackInput input => input,
        final List<Document> docs => IndexerCallbackInput(docs: docs),
        _ => null,
      };

  @override
  String toString() => 'IndexerCallbackInput(docs: ${docs.length})';
}

/// The output of an indexing call, as callback handlers see it.
///
/// Port of eino `indexer.CallbackOutput`.
@immutable
final class IndexerCallbackOutput {
  /// The output of a call that stored documents under [ids].
  const IndexerCallbackOutput({required this.ids, this.extra});

  /// The ids of the stored documents, in the order of the documents.
  final List<String> ids;

  /// Whatever else the indexer wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the output of an indexing call, or returns `null` when it
  /// is not one.
  ///
  /// Port of eino `indexer.ConvCallbackOutput`: accepts an
  /// [IndexerCallbackOutput] or the plain list of ids a graph node reports.
  static IndexerCallbackOutput? from(Object? raw) => switch (raw) {
        final IndexerCallbackOutput output => output,
        final List<String> ids => IndexerCallbackOutput(ids: ids),
        _ => null,
      };

  @override
  String toString() => 'IndexerCallbackOutput(ids: $ids)';
}
