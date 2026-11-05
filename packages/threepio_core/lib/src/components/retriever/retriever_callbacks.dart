/// What a retriever reports to callback handlers.
///
/// Port of eino `components/retriever/callback_extra.go`.
library;

import 'package:meta/meta.dart';

import '../../schema/document.dart';

/// The input of a retrieval, as callback handlers see it.
///
/// Port of eino `retriever.CallbackInput`.
@immutable
final class RetrieverCallbackInput {
  /// The input of a retrieval for [query].
  const RetrieverCallbackInput({
    required this.query,
    this.topK,
    this.filter,
    this.scoreThreshold,
    this.extra,
  });

  /// What is searched for.
  final String query;

  /// The most documents the retrieval may return.
  final int? topK;

  /// The filter the retrieval applies, in the words of the retriever.
  final String? filter;

  /// The lowest score a returned document may have.
  final double? scoreThreshold;

  /// Whatever else the retriever wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the input of a retrieval, or returns `null` when it is
  /// not one.
  ///
  /// Port of eino `retriever.ConvCallbackInput`: accepts a
  /// [RetrieverCallbackInput] or the plain query a graph node reports.
  static RetrieverCallbackInput? from(Object? raw) => switch (raw) {
        final RetrieverCallbackInput input => input,
        final String query => RetrieverCallbackInput(query: query),
        _ => null,
      };

  @override
  String toString() => 'RetrieverCallbackInput(query: $query, topK: $topK, '
      'filter: $filter, scoreThreshold: $scoreThreshold)';
}

/// The output of a retrieval, as callback handlers see it.
///
/// Port of eino `retriever.CallbackOutput`.
@immutable
final class RetrieverCallbackOutput {
  /// The output of a retrieval that found [docs].
  const RetrieverCallbackOutput({required this.docs, this.extra});

  /// The documents that were found.
  final List<Document> docs;

  /// Whatever else the retriever wants handlers to know.
  final Map<String, Object?>? extra;

  /// Reads [raw] as the output of a retrieval, or returns `null` when it is
  /// not one.
  ///
  /// Port of eino `retriever.ConvCallbackOutput`: accepts a
  /// [RetrieverCallbackOutput] or the plain list of documents a graph node
  /// reports.
  static RetrieverCallbackOutput? from(Object? raw) => switch (raw) {
        final RetrieverCallbackOutput output => output,
        final List<Document> docs => RetrieverCallbackOutput(docs: docs),
        _ => null,
      };

  @override
  String toString() => 'RetrieverCallbackOutput(docs: ${docs.length})';
}
