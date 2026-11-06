/// Gemini-specific fields of agentic messages.
///
/// Port of eino `schema/gemini` (`extension.go`). **Beta**, as the whole
/// agentic path is upstream. Every type carries a `Gemini` prefix where Go
/// has the package name.
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../agentic_wire.dart';

/// Gemini's part of `AgenticResponseMeta`. Port of eino
/// `gemini.ResponseMetaExtension`.
@immutable
final class GeminiResponseMetaExtension {
  const GeminiResponseMetaExtension({
    this.id = '',
    this.finishReason = '',
    this.groundingMeta,
  });

  /// Reads Go's JSON form (snake_case keys, as [toJson] writes them).
  factory GeminiResponseMetaExtension.fromJson(Map<String, Object?> json) =>
      GeminiResponseMetaExtension(
        id: readString(json, 'id'),
        finishReason: readString(json, 'finish_reason'),
        groundingMeta: readObject(
          json,
          'grounding_meta',
          GeminiGroundingMetadata.fromJson,
        ),
      );

  final String id;
  final String finishReason;
  final GeminiGroundingMetadata? groundingMeta;

  /// Go's JSON form: snake_case keys, empty fields left out.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'id', id);
    putString(json, 'finish_reason', finishReason);
    putObject(json, 'grounding_meta', groundingMeta?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeminiResponseMetaExtension &&
          other.id == id &&
          other.finishReason == finishReason &&
          other.groundingMeta == groundingMeta;

  @override
  int get hashCode => Object.hash(id, finishReason, groundingMeta);

  @override
  String toString() => 'GeminiResponseMetaExtension${toJson()}';
}

/// Port of eino `gemini.GroundingMetadata`.
@immutable
final class GeminiGroundingMetadata {
  GeminiGroundingMetadata({
    List<GeminiGroundingChunk> groundingChunks = const [],
    List<GeminiGroundingSupport> groundingSupports = const [],
    this.searchEntryPoint,
    List<String> webSearchQueries = const [],
  })  : groundingChunks = List.unmodifiable(groundingChunks),
        groundingSupports = List.unmodifiable(groundingSupports),
        webSearchQueries = List.unmodifiable(webSearchQueries);

  /// Reads Go's JSON form.
  factory GeminiGroundingMetadata.fromJson(Map<String, Object?> json) =>
      GeminiGroundingMetadata(
        groundingChunks: readObjects(
          json,
          'grounding_chunks',
          GeminiGroundingChunk.fromJson,
        ),
        groundingSupports: readObjects(
          json,
          'grounding_supports',
          GeminiGroundingSupport.fromJson,
        ),
        searchEntryPoint: readObject(
          json,
          'search_entry_point',
          GeminiSearchEntryPoint.fromJson,
        ),
        webSearchQueries: [
          for (final query
              in json['web_search_queries'] as List<Object?>? ?? const [])
            query! as String,
        ],
      );

  final List<GeminiGroundingChunk> groundingChunks;
  final List<GeminiGroundingSupport> groundingSupports;
  final GeminiSearchEntryPoint? searchEntryPoint;
  final List<String> webSearchQueries;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putList(json, 'grounding_chunks', [
      for (final chunk in groundingChunks) chunk.toJson(),
    ]);
    putList(json, 'grounding_supports', [
      for (final support in groundingSupports) support.toJson(),
    ]);
    putObject(json, 'search_entry_point', searchEntryPoint?.toJson());
    putList(json, 'web_search_queries', webSearchQueries);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeminiGroundingMetadata &&
          const ListEquality<GeminiGroundingChunk>()
              .equals(other.groundingChunks, groundingChunks) &&
          const ListEquality<GeminiGroundingSupport>()
              .equals(other.groundingSupports, groundingSupports) &&
          other.searchEntryPoint == searchEntryPoint &&
          const ListEquality<String>()
              .equals(other.webSearchQueries, webSearchQueries);

  @override
  int get hashCode => Object.hash(
        const ListEquality<GeminiGroundingChunk>().hash(groundingChunks),
        const ListEquality<GeminiGroundingSupport>().hash(groundingSupports),
        searchEntryPoint,
        const ListEquality<String>().hash(webSearchQueries),
      );

  @override
  String toString() => 'GeminiGroundingMetadata${toJson()}';
}

/// Port of eino `gemini.GroundingChunk`.
@immutable
final class GeminiGroundingChunk {
  const GeminiGroundingChunk({this.web});

  /// Reads Go's JSON form.
  factory GeminiGroundingChunk.fromJson(Map<String, Object?> json) =>
      GeminiGroundingChunk(
        web: readObject(json, 'web', GeminiGroundingChunkWeb.fromJson),
      );

  final GeminiGroundingChunkWeb? web;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putObject(json, 'web', web?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeminiGroundingChunk && other.web == web;

  @override
  int get hashCode => web.hashCode;

  @override
  String toString() => 'GeminiGroundingChunk${toJson()}';
}

/// Port of eino `gemini.GroundingChunkWeb`.
@immutable
final class GeminiGroundingChunkWeb {
  const GeminiGroundingChunkWeb({
    this.domain = '',
    this.title = '',
    this.uri = '',
  });

  /// Reads Go's JSON form.
  factory GeminiGroundingChunkWeb.fromJson(Map<String, Object?> json) =>
      GeminiGroundingChunkWeb(
        domain: readString(json, 'domain'),
        title: readString(json, 'title'),
        uri: readString(json, 'uri'),
      );

  final String domain;
  final String title;
  final String uri;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'domain', domain);
    putString(json, 'title', title);
    putString(json, 'uri', uri);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeminiGroundingChunkWeb &&
          other.domain == domain &&
          other.title == title &&
          other.uri == uri;

  @override
  int get hashCode => Object.hash(domain, title, uri);

  @override
  String toString() => 'GeminiGroundingChunkWeb${toJson()}';
}

/// Port of eino `gemini.GroundingSupport`.
@immutable
final class GeminiGroundingSupport {
  GeminiGroundingSupport({
    List<double> confidenceScores = const [],
    List<int> groundingChunkIndices = const [],
    this.segment,
  })  : confidenceScores = List.unmodifiable(confidenceScores),
        groundingChunkIndices = List.unmodifiable(groundingChunkIndices);

  /// Reads Go's JSON form.
  factory GeminiGroundingSupport.fromJson(Map<String, Object?> json) =>
      GeminiGroundingSupport(
        confidenceScores: [
          for (final score
              in json['confidence_scores'] as List<Object?>? ?? const [])
            (score! as num).toDouble(),
        ],
        groundingChunkIndices: [
          for (final index
              in json['grounding_chunk_indices'] as List<Object?>? ??
                  const [])
            (index! as num).toInt(),
        ],
        segment: readObject(json, 'segment', GeminiSegment.fromJson),
      );

  final List<double> confidenceScores;
  final List<int> groundingChunkIndices;
  final GeminiSegment? segment;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putList(json, 'confidence_scores', confidenceScores);
    putList(json, 'grounding_chunk_indices', groundingChunkIndices);
    putObject(json, 'segment', segment?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeminiGroundingSupport &&
          const ListEquality<double>()
              .equals(other.confidenceScores, confidenceScores) &&
          const ListEquality<int>()
              .equals(other.groundingChunkIndices, groundingChunkIndices) &&
          other.segment == segment;

  @override
  int get hashCode => Object.hash(
        const ListEquality<double>().hash(confidenceScores),
        const ListEquality<int>().hash(groundingChunkIndices),
        segment,
      );

  @override
  String toString() => 'GeminiGroundingSupport${toJson()}';
}

/// Port of eino `gemini.Segment`.
@immutable
final class GeminiSegment {
  const GeminiSegment({
    this.endIndex = 0,
    this.partIndex = 0,
    this.startIndex = 0,
    this.text = '',
  });

  /// Reads Go's JSON form.
  factory GeminiSegment.fromJson(Map<String, Object?> json) => GeminiSegment(
        endIndex: readInt(json, 'end_index'),
        partIndex: readInt(json, 'part_index'),
        startIndex: readInt(json, 'start_index'),
        text: readString(json, 'text'),
      );

  final int endIndex;
  final int partIndex;
  final int startIndex;
  final String text;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putInt(json, 'end_index', endIndex);
    putInt(json, 'part_index', partIndex);
    putInt(json, 'start_index', startIndex);
    putString(json, 'text', text);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeminiSegment &&
          other.endIndex == endIndex &&
          other.partIndex == partIndex &&
          other.startIndex == startIndex &&
          other.text == text;

  @override
  int get hashCode => Object.hash(endIndex, partIndex, startIndex, text);

  @override
  String toString() => 'GeminiSegment${toJson()}';
}

/// Port of eino `gemini.SearchEntryPoint`.
@immutable
final class GeminiSearchEntryPoint {
  GeminiSearchEntryPoint({this.renderedContent = '', List<int>? sdkBlob})
      : sdkBlob = sdkBlob == null ? null : List.unmodifiable(sdkBlob);

  /// Reads Go's JSON form ([sdkBlob] as a base64 string).
  factory GeminiSearchEntryPoint.fromJson(Map<String, Object?> json) {
    final blob = json['sdk_blob'] as String?;
    return GeminiSearchEntryPoint(
      renderedContent: readString(json, 'rendered_content'),
      sdkBlob: blob == null ? null : base64Decode(blob),
    );
  }

  final String renderedContent;

  /// Raw bytes (Go `[]byte`, base64 in JSON).
  final List<int>? sdkBlob;

  /// Go's JSON form: [sdkBlob] as standard base64, left out when empty.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'rendered_content', renderedContent);
    final blob = sdkBlob;
    if (blob != null && blob.isNotEmpty) json['sdk_blob'] = base64Encode(blob);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeminiSearchEntryPoint &&
          other.renderedContent == renderedContent &&
          const ListEquality<int>().equals(other.sdkBlob, sdkBlob);

  @override
  int get hashCode => Object.hash(
        renderedContent,
        const ListEquality<int>().hash(sdkBlob),
      );

  @override
  String toString() => 'GeminiSearchEntryPoint${toJson()}';
}

/// Joins the response metadata extensions of the chunks of one response.
///
/// Port of eino `gemini.ConcatResponseMetaExtensions`: a single chunk is
/// returned as it is; otherwise each field takes the last value that is set.
/// Throws [ArgumentError] when [chunks] is empty.
GeminiResponseMetaExtension concatGeminiResponseMetaExtensions(
  List<GeminiResponseMetaExtension> chunks,
) {
  if (chunks.isEmpty) throw ArgumentError('no response meta extension found');
  if (chunks.length == 1) return chunks.single;

  var id = '';
  var finishReason = '';
  GeminiGroundingMetadata? groundingMeta;
  for (final chunk in chunks) {
    if (chunk.id.isNotEmpty) id = chunk.id;
    if (chunk.finishReason.isNotEmpty) finishReason = chunk.finishReason;
    if (chunk.groundingMeta != null) groundingMeta = chunk.groundingMeta;
  }
  return GeminiResponseMetaExtension(
    id: id,
    finishReason: finishReason,
    groundingMeta: groundingMeta,
  );
}
