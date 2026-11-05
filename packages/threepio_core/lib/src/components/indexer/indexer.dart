/// Storing documents so that a retriever finds them again.
///
/// Port of eino `components/indexer` (`interface.go`, `option.go`).
library;

import 'package:meta/meta.dart';

import '../../core/run_context.dart';
import '../../internal/option_extensions.dart';
import '../../schema/document.dart';
import '../embedding/embedder.dart';

/// Stores documents in a backend, typically together with their vectors, so
/// that a retriever can find them.
///
/// Port of eino `indexer.Indexer`.
// ignore: one_member_abstracts
abstract interface class Indexer {
  /// Stores [docs] and returns their ids, one for each document and in the
  /// same order.
  ///
  /// A document that has an id keeps it; the others are given one. [ctx] is
  /// the context of the call and [options] are the options of this one call.
  Future<List<String>> store(
    RunContext ctx,
    List<Document> docs, {
    IndexerOptions? options,
  });
}

/// Options for one call of [Indexer.store].
///
/// Port of eino `indexer.Options`.
@immutable
final class IndexerOptions {
  /// Options for a call.
  const IndexerOptions({
    this.index,
    this.subIndexes,
    this.embedding,
    this.extensions = const [],
  });

  /// The index to store into, for an indexer whose store has several (Eino:
  /// `indexer.WithIndex`).
  final String? index;

  /// The parts of the index the documents belong to (Eino:
  /// `indexer.WithSubIndexes`).
  final List<String>? subIndexes;

  /// The embedder that computes the vectors of the documents for this call,
  /// instead of the one the indexer was built with (Eino:
  /// `indexer.WithEmbedding`).
  final Embedder? embedding;

  /// Options that only one implementation understands, each an instance of a
  /// class that implementation defines.
  ///
  /// The counterpart of eino's `indexer.WrapImplSpecificOptFn`.
  final List<Object> extensions;

  /// The first of the [extensions] that is a [T], or `null`.
  ///
  /// The counterpart of eino's `indexer.GetImplSpecificOptions`.
  T? extension<T extends Object>() => findExtension<T>(extensions);

  /// A copy with the given fields replaced.
  IndexerOptions copyWith({
    String? index,
    List<String>? subIndexes,
    Embedder? embedding,
    List<Object>? extensions,
  }) =>
      IndexerOptions(
        index: index ?? this.index,
        subIndexes: subIndexes ?? this.subIndexes,
        embedding: embedding ?? this.embedding,
        extensions: extensions ?? this.extensions,
      );

  /// These options with what [other] sets taking precedence, field by field.
  /// The [extensions] of both are kept, those of [other] first.
  IndexerOptions merge(IndexerOptions? other) => other == null
      ? this
      : IndexerOptions(
          index: other.index ?? index,
          subIndexes: other.subIndexes ?? subIndexes,
          embedding: other.embedding ?? embedding,
          extensions: mergeExtensions(extensions, other.extensions),
        );
}
