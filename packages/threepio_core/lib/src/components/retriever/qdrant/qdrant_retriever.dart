/// Retrieving documents from a Qdrant collection.
///
/// Port of eino-ext `components/retriever/qdrant` (`retriever.go`,
/// `options.go`, `consts.go`), over Qdrant's REST API instead of gRPC (see
/// `QdrantClient`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../../callbacks/callback_context.dart';
import '../../../callbacks/component_callbacks.dart';
import '../../../callbacks/global_callbacks.dart';
import '../../../callbacks/run_info.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/document.dart';
import '../../component_type.dart';
import '../../embedding/embedder.dart';
import '../../qdrant/qdrant_client.dart';
import '../retriever.dart';
import '../retriever_callbacks.dart';

/// The configuration of a [QdrantRetriever].
///
/// Port of eino-ext `qdrant.Config` (retriever). Go's checks that the config,
/// `Client` and `Embedding` are set are the non-nullable types of [client]
/// and [embedding]; an empty [collection] is refused by the constructor of
/// [QdrantRetriever].
@immutable
final class QdrantRetrieverConfig {
  /// A configuration that searches [collection] through [client], with the
  /// query embedded by [embedding].
  const QdrantRetrieverConfig({
    required this.client,
    required this.collection,
    required this.embedding,
    this.scoreThreshold,
    this.topK,
  });

  /// The client of the Qdrant server (Go: `Client`). The retriever does not
  /// close it.
  final QdrantClient client;

  /// The name of the collection to search (Go: `Collection`).
  final String collection;

  /// The embedder that turns the query into a vector, unless a call brings
  /// its own in `RetrieverOptions.embedding` (Go: `Embedding`).
  final Embedder embedding;

  /// The lowest score a returned document may have, unless a call sets its
  /// own in `RetrieverOptions.scoreThreshold`; `null` for no limit (Go:
  /// `ScoreThreshold`).
  ///
  /// Deviation: Go's `Retrieve` sends only this configured threshold and
  /// leaves out the one of `retriever.WithScoreThreshold`, although it
  /// reports that one to the callbacks and applies the `TopK` of the call;
  /// the other eino-ext retrievers apply the threshold of the call, and so
  /// does this port.
  final double? scoreThreshold;

  /// The most documents a retrieval returns, unless a call sets its own in
  /// `RetrieverOptions.topK`; [QdrantRetriever.defaultTopK] (5) when `null`
  /// or 0 (Go: `TopK`).
  final int? topK;
}

/// The options of one [QdrantRetriever] call that only it understands. Put
/// an instance in `RetrieverOptions.extensions`.
///
/// Port of eino-ext `qdrant.WithFilter` (retriever, `implOptions`).
@immutable
final class QdrantRetrieverOptions {
  /// Options with a payload [filter].
  const QdrantRetrieverOptions({this.filter});

  /// A condition the payloads of the returned points meet, in Qdrant's REST
  /// form (https://qdrant.tech/documentation/concepts/filtering/). The
  /// metadata of a document stored by `QdrantIndexer` is under the payload
  /// field `metadata`, so its keys are addressed as `metadata.<key>`:
  ///
  /// ```dart
  /// final docs = await retriever.retrieve(
  ///   'tourist attraction',
  ///   options: const RetrieverOptions(
  ///     extensions: [
  ///       QdrantRetrieverOptions(filter: {
  ///         'must': [
  ///           {'key': 'metadata.country', 'match': {'value': 'France'}},
  ///         ],
  ///       }),
  ///     ],
  ///   ),
  /// );
  /// ```
  final Map<String, Object?>? filter;
}

/// A [Retriever] that finds the documents of a Qdrant collection nearest to
/// the query.
///
/// Port of eino-ext `qdrant.Retriever`. The query is embedded and the
/// collection queried with that vector (`POST /collections/{c}/points/query`,
/// the REST form of go-client `Client.Query`) with the payloads. Each point
/// found becomes a document: its UUID as the id, the payload field
/// [contentKey] as the content, the payload field [metadataKey] as the entry
/// `metadata` of the metadata, and the score (`DocumentMetaX.withScore`).
/// The `metadata` entry is the plain JSON object of the payload field (Go
/// keeps go-client's `map[string]*qdrant.Value`, which has no Dart
/// counterpart).
///
/// ```dart
/// final retriever = QdrantRetriever(
///   QdrantRetrieverConfig(
///     client: QdrantClient(),
///     collection: 'docs',
///     embedding: embedder,
///   ),
/// );
/// final docs = await retriever.retrieve(
///   'tourist attraction',
///   options: RetrieverOptions(topK: 3, runContext: ctx),
/// );
/// ```
///
/// Each retrieval reports to the callback handlers of its run
/// (`options.runContext`, and the global handlers): a
/// [RetrieverCallbackInput] with the query, the number of documents asked
/// for, the filter as JSON and the score threshold, then a
/// [RetrieverCallbackOutput] with the documents, or the error. The filter is
/// the JSON of the REST form the call gave ([QdrantRetrieverOptions.filter]),
/// where Go marshals its protobuf `qdrant.Filter` (another shape); without a
/// filter it is `null`, where Go reports the string `null` (the JSON of its
/// nil `*qdrant.Filter`). The embedder
/// is called in a context that introduces it as an embedder named after its
/// implementation (eino-ext's `makeEmbeddingCtx`).
final class QdrantRetriever extends Retriever
    implements TypedComponent, CallbackAwareComponent {
  /// A retriever for [config].
  ///
  /// Port of eino-ext `qdrant.NewRetriever`: an empty collection throws an
  /// [ArgumentError] with Go's message.
  QdrantRetriever(this.config)
      : topK = config.topK == null || config.topK == 0
            ? defaultTopK
            : config.topK! {
    if (config.collection.isEmpty) {
      throw ArgumentError.value(
        config.collection,
        'collection',
        '[NewRetriever] qdrant collection not provided',
      );
    }
  }

  /// The number of documents returned when neither the configuration nor
  /// the call sets one.
  static const defaultTopK = 5;

  /// The payload field read as the content of a document (Go:
  /// `defaultContentKey`).
  static const contentKey = 'content';

  /// The payload field read as the metadata of a document, and the key it is
  /// kept under in the document's metadata (Go: `defaultMetadataKey`).
  static const metadataKey = 'metadata';

  /// The configuration of the retriever.
  final QdrantRetrieverConfig config;

  /// The number of documents a call returns unless it sets its own.
  final int topK;

  /// `Qdrant` (Go `GetType()`).
  @override
  String get componentTypeName => 'Qdrant';

  /// `true`: the retriever fires its callbacks itself (Go
  /// `IsCallbacksEnabled()`).
  @override
  bool get isCallbacksEnabled => true;

  /// The documents of the collection nearest to [query], best first.
  ///
  /// Port of eino-ext `Retriever.Retrieve`. From [options] it reads `topK`,
  /// `scoreThreshold` and `embedding` (each overriding the configuration),
  /// a [QdrantRetrieverOptions] in `extensions` for the filter, and
  /// `runContext` for the callbacks and cancellation. Unlike Go, the
  /// `scoreThreshold` of the call is sent to Qdrant (see
  /// [QdrantRetrieverConfig.scoreThreshold]).
  ///
  /// What the embedder throws is rethrown as it is. Other failures, each a
  /// [ThreepioException] with Go's message:
  /// `[qdrant retriever] invalid return length of vector, got=…, expected=1`
  /// and `[Retriever] qdrant search failed: …` (caused by the
  /// [QdrantException]). A point whose payload field `metadata` is not an
  /// object throws a [ThreepioFormatException].
  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) {
    final runContext = options?.runContext;
    final base = runContext ??
        (GlobalCallbacks.isEmpty ? null : RunContext.background());
    final embedder = options?.embedding ?? config.embedding;
    final effectiveTopK = options?.topK ?? topK;
    final scoreThreshold = options?.scoreThreshold ?? config.scoreThreshold;
    final filter = options?.extension<QdrantRetrieverOptions>()?.filter;

    Future<List<Document>> run(RunContext ctx, RunContext? embeddingCtx) =>
        _retrieve(
          ctx,
          query,
          embedder,
          embeddingCtx,
          topK: effectiveTopK,
          scoreThreshold: scoreThreshold,
          filter: filter,
        );

    if (base == null) return run(RunContext.background(), null);
    final ctx = ensureRunInfo(base, componentTypeName, ComponentType.retriever);
    if (!ctx.hasCallbacks) return run(base, runContext);

    return _reported(
      ctx,
      RetrieverCallbackInput(
        query: query,
        topK: effectiveTopK,
        filter: filter == null ? null : _filterJson(filter),
        scoreThreshold: scoreThreshold,
      ),
      embedder,
      run,
    );
  }

  /// Runs [retrieve] between the start callback and the end or error
  /// callback, as eino-ext's `Retrieve` does (`EnsureRunInfo`, `OnStart`,
  /// `OnEnd`, `OnError`). [retrieve] gets the context the start callback
  /// returned, for the query (Go queries with that `ctx`), and the context
  /// for the embedder.
  Future<List<Document>> _reported(
    RunContext ctx,
    RetrieverCallbackInput input,
    Embedder embedder,
    Future<List<Document>> Function(RunContext ctx, RunContext embeddingCtx)
        retrieve,
  ) async {
    final started = await onStart(ctx, input);
    final List<Document> docs;
    try {
      docs = await retrieve(started, _embeddingContext(started, embedder));
    } catch (error, stackTrace) {
      await onError(started, error, stackTrace);
      rethrow;
    }
    await onEnd(started, RetrieverCallbackOutput(docs: docs));
    return docs;
  }

  Future<List<Document>> _retrieve(
    RunContext ctx,
    String query,
    Embedder embedder,
    RunContext? embeddingCtx, {
    required int topK,
    required double? scoreThreshold,
    required Map<String, Object?>? filter,
  }) async {
    ctx.cancelToken.throwIfCancelled();
    final vectors = await embedder.embedStrings(
      [query],
      options:
          embeddingCtx == null ? null : EmbedderOptions(runContext: embeddingCtx),
    );
    if (vectors.length != 1) {
      throw ThreepioException(
        '[qdrant retriever] invalid return length of vector, '
        'got=${vectors.length}, expected=1',
      );
    }

    final List<QdrantScoredPoint> points;
    try {
      points = await config.client.query(
        ctx,
        config.collection,
        query: vectors.single,
        limit: topK,
        scoreThreshold: scoreThreshold,
        filter: filter,
      );
    } on QdrantException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        ThreepioException(
          '[Retriever] qdrant search failed: ${error.message}',
          cause: error,
        ),
        stackTrace,
      );
    }
    return [for (final point in points) _document(point)];
  }

  /// The document Go builds from [point].
  static Document _document(QdrantScoredPoint point) {
    final payload = point.payload ?? const <String, Object?>{};
    final metadata = <String, dynamic>{};
    if (payload.containsKey(metadataKey)) {
      final value = payload[metadataKey];
      if (value is! Map) {
        // Go reads it with `GetStructValue().Fields`, which fails on
        // anything but an object.
        throw ThreepioFormatException(
          '[qdrant retriever] the payload field "$metadataKey" of point '
          '${point.id} is not an object: $value',
        );
      }
      metadata[metadataKey] = Map<String, dynamic>.from(value);
    }
    return Document(
      // Go: `Id.GetUuid()`, which is empty for a numeric id.
      id: switch (point.id) {
        final String uuid => uuid,
        _ => '',
      },
      // Go: `GetStringValue()`, which is empty for anything but a string.
      content: switch (payload[contentKey]) {
        final String content => content,
        _ => '',
      },
      metadata: metadata,
    ).withScore(_float32(point.score));
  }

  /// [value] as the float32 it was on the server: Go reads the score as a
  /// `float32` and widens it (`float64(pt.Score)`).
  static double _float32(double value) => (Float32List(1)..[0] = value)[0];

  /// Port of eino-ext `tryMarshalJsonString`: the filter as JSON, or an empty
  /// string when it cannot be written as JSON.
  static String _filterJson(Map<String, Object?> filter) {
    try {
      return jsonEncode(filter);
      // Go's json.Marshal returns an error where jsonEncode throws one.
      // ignore: avoid_catching_errors
    } on JsonUnsupportedObjectError {
      return '';
    }
  }

  /// [ctx] with the run info of [embedder], for its callbacks. Port of
  /// eino-ext `Retriever.makeEmbeddingCtx`.
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
      'QdrantRetriever(collection: ${config.collection}, topK: $topK)';
}
