import 'package:freezed_annotation/freezed_annotation.dart';

part 'document.freezed.dart';
part 'document.g.dart';

/// Document source information
@freezed
class DocumentSource with _$DocumentSource {
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
class Document with _$Document {
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
class DocumentChunk with _$DocumentChunk {
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
class ChunkedDocument with _$ChunkedDocument {
  const factory ChunkedDocument({
    /// Original document
    required Document document,

    /// Document chunks
    required List<DocumentChunk> chunks,
  }) = _ChunkedDocument;

  factory ChunkedDocument.fromJson(Map<String, dynamic> json) =>
      _$ChunkedDocumentFromJson(json);
}
