/// Storing documents in a Qdrant collection.
///
/// Port of eino-ext `components/indexer/qdrant` (`indexer.go`, `consts.go`),
/// over Qdrant's REST API instead of gRPC (see `QdrantClient`).
library;

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../../callbacks/callback_context.dart';
import '../../../callbacks/component_callbacks.dart';
import '../../../callbacks/run_info.dart';
import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/document.dart';
import '../../component_type.dart';
import '../../embedding/embedder.dart';
import '../../model/cancel_token.dart';
import '../../qdrant/qdrant_client.dart';
import '../indexer.dart';
import '../indexer_callbacks.dart';

/// The configuration of a [QdrantIndexer].
///
/// Port of eino-ext `qdrant.Config` (indexer). Go's checks that `Client` and
/// `Embedding` are set are the non-nullable types of [client] and
/// [embedding].
@immutable
final class QdrantIndexerConfig {
  /// A configuration that stores into [collection] through [client], with
  /// vectors computed by [embedding].
  const QdrantIndexerConfig({
    required this.client,
    required this.embedding,
    this.collection,
    this.vectorDim = 0,
    this.distance,
    this.batchSize,
  });

  /// The client of the Qdrant server (Go: `Client`). The indexer does not
  /// close it.
  final QdrantClient client;

  /// The name of the collection, [QdrantIndexer.defaultCollection]
  /// (`eino_collection`) when `null` or empty (Go: `Collection`).
  final String? collection;

  /// The number of dimensions of the vectors, used when the collection is
  /// created (Go: `VectorDim`). Only needed when the collection may not exist
  /// yet.
  final int vectorDim;

  /// The distance metric of the vectors, used when the collection is created
  /// (Go: `Distance`). Only needed when the collection may not exist yet;
  /// `null` is Go's `UnknownDistance`, which Qdrant refuses.
  final QdrantDistance? distance;

  /// How many documents are embedded and upserted together,
  /// [QdrantIndexer.defaultBatchSize] (10) when `null` or 0 (Go:
  /// `BatchSize`). It may not be negative.
  final int? batchSize;

  /// The embedder that computes the vectors of the documents, unless a call
  /// brings its own in `IndexerOptions.embedding` (Go: `Embedding`).
  final Embedder embedding;
}

/// An [Indexer] that stores documents as points of a Qdrant collection.
///
/// Port of eino-ext `qdrant.Indexer` (indexer). Each document becomes one
/// point: its id is the point id (a UUID; Qdrant refuses other strings), its
/// vector is computed by the embedder from the content, and the payload holds
/// the content under [contentKey] and the metadata under [metadataKey]. The
/// documents are embedded and upserted [QdrantIndexerConfig.batchSize] at a
/// time, one embedder call and one upsert per batch.
///
/// ```dart
/// final client = QdrantClient();
/// final indexer = await QdrantIndexer.create(
///   ctx,
///   QdrantIndexerConfig(
///     client: client,
///     collection: 'docs',
///     vectorDim: 1536,
///     distance: QdrantDistance.cosine,
///     embedding: embedder,
///   ),
/// );
/// final ids = await indexer.store(ctx, documents);
/// ```
///
/// Each call reports to the callback handlers of its run context (and the
/// global ones): an [IndexerCallbackInput] with the documents, then an
/// [IndexerCallbackOutput] with the ids, or the error. The embedder is called
/// in a context that introduces it as an embedder named after its
/// implementation (eino-ext's `makeEmbeddingCtx`).
final class QdrantIndexer
    implements Indexer, TypedComponent, CallbackAwareComponent {
  QdrantIndexer._(this.config, this.collection, this.batchSize);

  /// The collection used when the configuration names none (Go:
  /// `defaultCollection`).
  static const defaultCollection = 'eino_collection';

  /// The batch size used when the configuration sets none.
  static const defaultBatchSize = 10;

  /// The payload field that holds the content of a document (Go:
  /// `defaultContentKey`).
  static const contentKey = 'content';

  /// The payload field that holds the metadata of a document (Go:
  /// `defaultMetadataKey`).
  static const metadataKey = 'metadata';

  static const _uuid = Uuid();

  /// An indexer for [config], once the collection exists: when the server
  /// does not have it, it is created with [QdrantIndexerConfig.vectorDim]
  /// and [QdrantIndexerConfig.distance].
  ///
  /// Port of eino-ext `qdrant.NewIndexer` (indexer). A negative batch size
  /// throws an [ArgumentError]. When the collection cannot be checked or
  /// created this throws a [ThreepioException]
  /// (`[NewIndexer] failed to ensure collection: …`) caused by the
  /// [QdrantException].
  static Future<QdrantIndexer> create(
    RunContext ctx,
    QdrantIndexerConfig config,
  ) async {
    final batchSize = config.batchSize;
    if (batchSize != null && batchSize < 0) {
      throw ArgumentError.value(
        batchSize,
        'batchSize',
        '[NewIndexer] batch size may not be negative',
      );
    }
    final collection = config.collection;
    final indexer = QdrantIndexer._(
      config,
      collection == null || collection.isEmpty ? defaultCollection : collection,
      batchSize == null || batchSize == 0 ? defaultBatchSize : batchSize,
    );
    try {
      await indexer._ensureCollection(ctx);
    } on QdrantException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        ThreepioException(
          '[NewIndexer] failed to ensure collection: ${error.message}',
          cause: error,
        ),
        stackTrace,
      );
    }
    return indexer;
  }

  /// The configuration the indexer was created with.
  final QdrantIndexerConfig config;

  /// The collection the documents are stored in.
  final String collection;

  /// How many documents go into one embedder call and one upsert.
  final int batchSize;

  /// `Qdrant` (Go `GetType()`).
  @override
  String get componentTypeName => 'Qdrant';

  /// `true`: the indexer fires its callbacks itself (Go
  /// `IsCallbacksEnabled()`).
  @override
  bool get isCallbacksEnabled => true;

  /// Port of eino-ext `Indexer.ensureCollection`.
  Future<void> _ensureCollection(RunContext ctx) async {
    final client = config.client;
    if (await client.collectionExists(ctx, collection)) return;
    await client.createCollection(
      ctx,
      collection,
      vectorSize: config.vectorDim,
      distance: config.distance,
    );
  }

  /// Stores [docs] and returns their ids.
  ///
  /// Port of eino-ext `Indexer.Store` (indexer). The embedder is
  /// `options.embedding`, or else the one of the configuration. A document
  /// without an id is given a random UUID (the `Indexer` contract; Go sends
  /// the empty id, which Qdrant refuses).
  ///
  /// Failures, each a [ThreepioException] with Go's message:
  /// `[batchUpsert] embedding failed, …` (the embedder threw),
  /// `[batchUpsert] invalid vector length, expected=…, got=…` (it returned
  /// another number of vectors than texts) and
  /// `[batchUpsert] failed to upsert points to qdrant, …` (caused by the
  /// [QdrantException]). A payload value Qdrant cannot store throws a
  /// [ThreepioFormatException]. The batches before a failure stay stored.
  @override
  Future<List<String>> store(
    RunContext ctx,
    List<Document> docs, {
    IndexerOptions? options,
  }) async {
    final embedder = options?.embedding ?? config.embedding;
    final ids = [for (final doc in docs) doc.id ?? _uuid.v4()];

    var runCtx = ensureRunInfo(ctx, componentTypeName, ComponentType.indexer);
    if (!runCtx.hasCallbacks) {
      // No handler to report to, here or global: the embedder gets the
      // context of the call as it is.
      await _batchUpsert(ctx, docs, ids, embedder, ctx);
      return ids;
    }

    runCtx = await onStart(runCtx, IndexerCallbackInput(docs: docs));
    try {
      await _batchUpsert(
        runCtx,
        docs,
        ids,
        embedder,
        _embeddingContext(runCtx, embedder),
      );
    } catch (error, stackTrace) {
      await onError(runCtx, error, stackTrace);
      rethrow;
    }
    await onEnd(runCtx, IndexerCallbackOutput(ids: ids));
    return ids;
  }

  /// Port of eino-ext `Indexer.batchUpsert`.
  Future<void> _batchUpsert(
    RunContext ctx,
    List<Document> docs,
    List<String> ids,
    Embedder embedder,
    RunContext embeddingCtx,
  ) async {
    for (var start = 0; start < docs.length; start += batchSize) {
      ctx.cancelToken.throwIfCancelled();
      final end =
          start + batchSize > docs.length ? docs.length : start + batchSize;
      final batch = docs.sublist(start, end);

      final List<List<double>> vectors;
      try {
        vectors = await embedder.embedStrings(
          [for (final doc in batch) doc.content],
          options: EmbedderOptions(runContext: embeddingCtx),
        );
      } catch (error, stackTrace) {
        if (isInterrupt(error) || error is CancelledException) rethrow;
        Error.throwWithStackTrace(
          ThreepioException(
            '[batchUpsert] embedding failed, ${_messageOf(error)}',
            cause: error,
          ),
          stackTrace,
        );
      }
      if (vectors.length != batch.length) {
        throw ThreepioException(
          '[batchUpsert] invalid vector length, '
          'expected=${batch.length}, got=${vectors.length}',
        );
      }

      final points = [
        for (final (index, doc) in batch.indexed)
          QdrantPoint(
            id: ids[start + index],
            vector: vectors[index],
            payload: {contentKey: doc.content, metadataKey: doc.metadata},
          ),
      ];
      try {
        await config.client.upsert(ctx, collection, points);
      } on QdrantException catch (error, stackTrace) {
        Error.throwWithStackTrace(
          ThreepioException(
            '[batchUpsert] failed to upsert points to qdrant, '
            '${error.message}',
            cause: error,
          ),
          stackTrace,
        );
      }
    }
  }

  /// [ctx] with the run info of [embedder], for its callbacks. Port of
  /// eino-ext `Indexer.makeEmbeddingCtx`.
  static RunContext _embeddingContext(RunContext ctx, Embedder embedder) {
    final type = componentTypeNameOf(embedder) ?? '';
    return reuseHandlers(
      ctx,
      RunInfo(
        name: '$type${ComponentType.embedder.einoName}',
        type: type,
        componentType: ComponentType.embedder,
      ),
    );
  }

  @override
  String toString() =>
      'QdrantIndexer(collection: $collection, batchSize: $batchSize)';
}

/// How Go's `%w` prints [error]: a threepio exception by its message.
String _messageOf(Object error) =>
    error is ThreepioException ? error.message : '$error';
