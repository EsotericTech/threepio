import 'package:freezed_annotation/freezed_annotation.dart';

part 'document.freezed.dart';
part 'document.g.dart';

/// Document source information
@freezed
abstract class DocumentSource with _$DocumentSource {
  const factory DocumentSource({
    /// URI of the document source
    required String uri,

    /// Additional metadata
    Map<String, dynamic>? metadata,
  }) = _DocumentSource;

  factory DocumentSource.fromJson(Map<String, dynamic> json) =>
      _$DocumentSourceFromJson(json);
}

/// Document for RAG (Retrieval-Augmented Generation)
@freezed
abstract class Document with _$Document {
  const factory Document({
    /// Unique identifier for the document
    String? id,

    /// Text content of the document
    required String content,

    /// Metadata associated with the document
    @Default({}) Map<String, dynamic> metadata,

    /// Source information
    DocumentSource? source,

    /// Embedding vector (if available)
    List<double>? embedding,

    /// Relevance score (if from retrieval)
    double? score,
  }) = _Document;

  const Document._();

  factory Document.fromJson(Map<String, dynamic> json) =>
      _$DocumentFromJson(json);

  /// Create a simple document with just content
  factory Document.simple(String content) => Document(
        content: content,
      );

  /// Create a document with metadata
  factory Document.withMetadata(
    String content,
    Map<String, dynamic> metadata,
  ) =>
      Document(
        content: content,
        metadata: metadata,
      );

  /// Create a document from a source
  factory Document.fromSource(String content, String sourceUri) => Document(
        content: content,
        source: DocumentSource(uri: sourceUri),
      );
}

/// Document chunk (for splitting large documents)
@freezed
abstract class DocumentChunk with _$DocumentChunk {
  const factory DocumentChunk({
    /// Chunk content
    required String content,

    /// Metadata from parent document
    @Default({}) Map<String, dynamic> metadata,

    /// Chunk index in the parent document
    int? index,

    /// Parent document ID
    String? parentId,

    /// Start position in parent
    int? startPosition,

    /// End position in parent
    int? endPosition,
  }) = _DocumentChunk;

  factory DocumentChunk.fromJson(Map<String, dynamic> json) =>
      _$DocumentChunkFromJson(json);
}

/// Document with chunks
@freezed
abstract class ChunkedDocument with _$ChunkedDocument {
  const factory ChunkedDocument({
    /// Original document
    required Document document,

    /// Document chunks
    required List<DocumentChunk> chunks,
  }) = _ChunkedDocument;

  factory ChunkedDocument.fromJson(Map<String, dynamic> json) =>
      _$ChunkedDocumentFromJson(json);
}

/// The Eino accessors for the well-known entries of [Document.metadata].
///
/// Port of the `With…` methods and getters of eino `schema.Document`, with the
/// same metadata keys, so that documents written by one side are understood
/// by the other. A document is immutable: every `with…` returns a copy.
///
/// Two of the entries also exist as fields of [Document]. The two stay
/// consistent: [withScore] and [withDenseVector] set field and entry, and
/// [effectiveScore] and [denseVector] read the field first.
///
/// The getters accept what comes back from JSON as well (a `List<dynamic>` of
/// numbers, a map with string keys).
extension DocumentMetaX on Document {
  static const _subIndexesKey = '_sub_indexes';
  static const _scoreKey = '_score';
  static const _extraInfoKey = '_extra_info';
  static const _dslKey = '_dsl';
  static const _denseVectorKey = '_dense_vector';
  static const _sparseVectorKey = '_sparse_vector';

  Document _withMeta(String key, Object? value) =>
      copyWith(metadata: {...metadata, key: value});

  /// A copy with the sub-indexes the document is to be stored under.
  ///
  /// Port of eino `Document.WithSubIndexes`.
  Document withSubIndexes(List<String> indexes) =>
      _withMeta(_subIndexesKey, indexes);

  /// The sub-indexes of the document, or `null` (Eino: `SubIndexes`).
  List<String>? get subIndexes => switch (metadata[_subIndexesKey]) {
        final List<String> indexes => indexes,
        final List<Object?> indexes when indexes.every((i) => i is String) =>
          indexes.cast<String>(),
        _ => null,
      };

  /// A copy with [score] in both the [Document.score] field and the metadata.
  ///
  /// Port of eino `Document.WithScore`.
  Document withScore(double score) =>
      copyWith(score: score, metadata: {...metadata, _scoreKey: score});

  /// The relevance score: the [Document.score] field when it is set, else the
  /// metadata entry, else `null` (Eino: `Score`, which returns 0 then).
  double? get effectiveScore =>
      score ??
      switch (metadata[_scoreKey]) {
        final num value => value.toDouble(),
        _ => null,
      };

  /// A copy with free-form extra information, for example for a reranker.
  ///
  /// Port of eino `Document.WithExtraInfo`.
  Document withExtraInfo(String extraInfo) =>
      _withMeta(_extraInfoKey, extraInfo);

  /// The extra information, or `null` (Eino: `ExtraInfo`).
  String? get extraInfo => switch (metadata[_extraInfoKey]) {
        final String info => info,
        _ => null,
      };

  /// A copy with a query in the domain-specific language of a search engine.
  ///
  /// Port of eino `Document.WithDSLInfo`.
  Document withDslInfo(Map<String, dynamic> dslInfo) =>
      _withMeta(_dslKey, dslInfo);

  /// The DSL query, or `null` (Eino: `DSLInfo`).
  Map<String, dynamic>? get dslInfo => switch (metadata[_dslKey]) {
        final Map<String, dynamic> dsl => dsl,
        _ => null,
      };

  /// A copy with [vector] in both the [Document.embedding] field and the
  /// metadata.
  ///
  /// Port of eino `Document.WithDenseVector`.
  Document withDenseVector(List<double> vector) => copyWith(
        embedding: vector,
        metadata: {...metadata, _denseVectorKey: vector},
      );

  /// The dense vector: the [Document.embedding] field when it is set, else
  /// the metadata entry, else `null` (Eino: `DenseVector`).
  List<double>? get denseVector =>
      embedding ??
      switch (metadata[_denseVectorKey]) {
        final List<double> vector => vector,
        final List<Object?> vector when vector.every((v) => v is num) => [
            for (final value in vector) (value! as num).toDouble(),
          ],
        _ => null,
      };

  /// A copy with a sparse vector: weights by dimension.
  ///
  /// Port of eino `Document.WithSparseVector`. The dimensions are stored as
  /// strings, so that the document can still be written as JSON.
  Document withSparseVector(Map<int, double> sparse) => _withMeta(
        _sparseVectorKey,
        {for (final entry in sparse.entries) '${entry.key}': entry.value},
      );

  /// The sparse vector, or `null` (Eino: `SparseVector`).
  Map<int, double>? get sparseVector {
    final stored = metadata[_sparseVectorKey];
    if (stored is! Map<Object?, Object?>) return null;

    final sparse = <int, double>{};
    for (final entry in stored.entries) {
      final dimension = switch (entry.key) {
        final int key => key,
        final String key => int.tryParse(key),
        _ => null,
      };
      final weight = entry.value;
      if (dimension == null || weight is! num) return null;
      sparse[dimension] = weight.toDouble();
    }
    return sparse;
  }
}
