/// An indexer that cuts documents into sub-documents, gives each its own id
/// and remembers the document it came from.
///
/// Port of eino `flow/indexer/parent`.
library;

import 'dart:async';

import '../../components/document/transformer.dart';
import '../../components/indexer/indexer.dart';
import '../../core/interrupt_signal.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/document.dart';

/// An [Indexer] that splits documents with a [transformer] before it stores
/// them with [indexer], so that a parent retriever
/// (`ParentRetriever.fromConfig`) can find the small pieces and return the
/// whole documents.
///
/// Port of eino `parent.NewIndexer`:
///
/// ```dart
/// final indexer = ParentIndexer(
///   indexer: vectorStoreIndexer,
///   transformer: splitter,
///   parentIdKey: 'source_doc_id',
///   subIdGenerator: (ctx, parentId, count) => [
///     for (var i = 1; i <= count; i++) '${parentId}_chunk_$i',
///   ],
/// );
/// await indexer.store(ctx, documents);
/// ```
///
/// The transformer must keep the parent's id on every sub-document it
/// makes: a document with id `doc_1` cut into three gives three
/// sub-documents with id `doc_1`. [store] then writes that id into each
/// sub-document's metadata under [parentIdKey] and replaces the ids by the
/// ones [subIdGenerator] makes.
final class ParentIndexer implements Indexer {
  /// An indexer that stores through [indexer] what [transformer] makes of
  /// the documents.
  const ParentIndexer({
    required this.indexer,
    required this.transformer,
    required this.parentIdKey,
    required this.subIdGenerator,
  });

  /// The indexer that stores the sub-documents. Port of `Indexer`.
  final Indexer indexer;

  /// Cuts the documents into sub-documents that keep their parent's id.
  /// Port of `Transformer`.
  final DocumentTransformer transformer;

  /// The metadata key under which every sub-document gets the id of its
  /// parent. Port of `ParentIDKey`.
  final String parentIdKey;

  /// Makes `count` ids for the sub-documents of the document `parentId`.
  /// Port of `SubIDGenerator`. It must return exactly `count` ids.
  final FutureOr<List<String>> Function(
    RunContext ctx,
    String parentId,
    int count,
  ) subIdGenerator;

  /// Transforms [docs], gives the sub-documents their parent's id in the
  /// metadata and ids of their own, and stores them with [indexer]; returns
  /// what [indexer] returns. Port of `parentIndexer.Store`.
  ///
  /// The transformer gets the context of the run in its options. A run of
  /// consecutive sub-documents with the same id counts as the pieces of one
  /// parent: [subIdGenerator] is called once per run, with the parent's id
  /// and the length of the run. As in Eino, sub-documents of one parent that
  /// are not next to each other form two runs (and may get the same ids),
  /// and a sub-document without an id counts as one with the empty id.
  /// [options] are passed to [indexer] as they are.
  ///
  /// Throws [ThreepioException] when the transformer fails (`transform docs
  /// fail: …`, with the failure as its cause), when it returns no documents,
  /// and when [subIdGenerator] returns the wrong number of ids. What
  /// [subIdGenerator] and [indexer] throw is rethrown as it is, and so is an
  /// interrupt from the transformer.
  @override
  Future<List<String>> store(
    RunContext ctx,
    List<Document> docs, {
    IndexerOptions? options,
  }) async {
    final List<Document> subDocs;
    try {
      subDocs = await transformer.transform(
        docs,
        options: TransformerOptions(runContext: ctx),
      );
      // Whatever the transformer throws is wrapped, as Go wraps its error.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      if (isInterrupt(error)) rethrow;
      Error.throwWithStackTrace(
        ThreepioException(
          'transform docs fail: ${_messageOf(error)}',
          cause: error,
        ),
        stackTrace,
      );
    }
    if (subDocs.isEmpty) {
      throw const ThreepioException('doc transformer returned no documents');
    }

    final parentIds = [for (final subDoc in subDocs) subDoc.id ?? ''];
    final newIds = List<String>.filled(subDocs.length, '');
    var start = 0;
    for (var i = 1; i <= subDocs.length; i++) {
      if (i < subDocs.length && parentIds[i] == parentIds[start]) continue;
      final count = i - start;
      final ids = await subIdGenerator(ctx, parentIds[start], count);
      if (ids.length != count) {
        throw const ThreepioException("generated sub IDs' num is unexpected");
      }
      newIds.setRange(start, i, ids);
      start = i;
    }

    return indexer.store(
      ctx,
      [
        for (final (i, subDoc) in subDocs.indexed)
          subDoc.copyWith(
            id: newIds[i],
            metadata: {...subDoc.metadata, parentIdKey: parentIds[i]},
          ),
      ],
      options: options,
    );
  }

  @override
  String toString() => 'ParentIndexer(parentIdKey: $parentIdKey, '
      'indexer: $indexer, transformer: $transformer)';
}

/// How Go's `%w` prints [error]: a threepio exception by its message.
String _messageOf(Object error) =>
    error is ThreepioException ? error.message : '$error';
