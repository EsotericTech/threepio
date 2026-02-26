// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'document.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_DocumentSource _$DocumentSourceFromJson(Map<String, dynamic> json) =>
    _DocumentSource(
      uri: json['uri'] as String,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );

Map<String, dynamic> _$DocumentSourceToJson(_DocumentSource instance) =>
    <String, dynamic>{
      'uri': instance.uri,
      'metadata': instance.metadata,
    };

_Document _$DocumentFromJson(Map<String, dynamic> json) => _Document(
      id: json['id'] as String?,
      content: json['content'] as String,
      metadata: json['metadata'] as Map<String, dynamic>? ?? const {},
      source: json['source'] == null
          ? null
          : DocumentSource.fromJson(json['source'] as Map<String, dynamic>),
      embedding: (json['embedding'] as List<dynamic>?)
          ?.map((e) => (e as num).toDouble())
          .toList(),
      score: (json['score'] as num?)?.toDouble(),
    );

Map<String, dynamic> _$DocumentToJson(_Document instance) => <String, dynamic>{
      'id': instance.id,
      'content': instance.content,
      'metadata': instance.metadata,
      'source': instance.source?.toJson(),
      'embedding': instance.embedding,
      'score': instance.score,
    };

_DocumentChunk _$DocumentChunkFromJson(Map<String, dynamic> json) =>
    _DocumentChunk(
      content: json['content'] as String,
      metadata: json['metadata'] as Map<String, dynamic>? ?? const {},
      index: (json['index'] as num?)?.toInt(),
      parentId: json['parentId'] as String?,
      startPosition: (json['startPosition'] as num?)?.toInt(),
      endPosition: (json['endPosition'] as num?)?.toInt(),
    );

Map<String, dynamic> _$DocumentChunkToJson(_DocumentChunk instance) =>
    <String, dynamic>{
      'content': instance.content,
      'metadata': instance.metadata,
      'index': instance.index,
      'parentId': instance.parentId,
      'startPosition': instance.startPosition,
      'endPosition': instance.endPosition,
    };

_ChunkedDocument _$ChunkedDocumentFromJson(Map<String, dynamic> json) =>
    _ChunkedDocument(
      document: Document.fromJson(json['document'] as Map<String, dynamic>),
      chunks: (json['chunks'] as List<dynamic>)
          .map((e) => DocumentChunk.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$ChunkedDocumentToJson(_ChunkedDocument instance) =>
    <String, dynamic>{
      'document': instance.document.toJson(),
      'chunks': instance.chunks.map((e) => e.toJson()).toList(),
    };
