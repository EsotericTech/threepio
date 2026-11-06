/// Claude-specific fields of agentic messages.
///
/// Port of eino `schema/claude` (`consts.go`, `extension.go`). **Beta**, as
/// the whole agentic path is upstream. Every type carries a `Claude` prefix
/// where Go has the package name.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../agentic_wire.dart';

/// The kind of a [ClaudeTextCitation]. An open set. Port of eino
/// `claude.TextCitationType`.
@immutable
final class ClaudeTextCitationType {
  /// The citation type whose wire value is [value].
  const ClaudeTextCitationType(this.value);

  /// `char_location`.
  static const charLocation = ClaudeTextCitationType('char_location');

  /// `page_location`.
  static const pageLocation = ClaudeTextCitationType('page_location');

  /// `content_block_location`.
  static const contentBlockLocation =
      ClaudeTextCitationType('content_block_location');

  /// `web_search_result_location`.
  static const webSearchResultLocation =
      ClaudeTextCitationType('web_search_result_location');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ClaudeTextCitationType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Claude's part of `AgenticResponseMeta`. Port of eino
/// `claude.ResponseMetaExtension`.
@immutable
final class ClaudeResponseMetaExtension {
  const ClaudeResponseMetaExtension({
    this.id = '',
    this.stopReason = '',
    this.stopSequence = '',
    this.stopDetails,
  });

  /// Reads Go's JSON form (snake_case keys, as [toJson] writes them).
  factory ClaudeResponseMetaExtension.fromJson(Map<String, Object?> json) =>
      ClaudeResponseMetaExtension(
        id: readString(json, 'id'),
        stopReason: readString(json, 'stop_reason'),
        stopSequence: readString(json, 'stop_sequence'),
        stopDetails:
            readObject(json, 'stop_details', ClaudeStopDetails.fromJson),
      );

  final String id;
  final String stopReason;
  final String stopSequence;
  final ClaudeStopDetails? stopDetails;

  /// Go's JSON form: snake_case keys, empty fields left out.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'id', id);
    putString(json, 'stop_reason', stopReason);
    putString(json, 'stop_sequence', stopSequence);
    putObject(json, 'stop_details', stopDetails?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClaudeResponseMetaExtension &&
          other.id == id &&
          other.stopReason == stopReason &&
          other.stopSequence == stopSequence &&
          other.stopDetails == stopDetails;

  @override
  int get hashCode => Object.hash(id, stopReason, stopSequence, stopDetails);

  @override
  String toString() => 'ClaudeResponseMetaExtension${toJson()}';
}

/// Port of eino `claude.StopDetails`.
@immutable
final class ClaudeStopDetails {
  const ClaudeStopDetails({this.category = '', this.explanation = ''});

  /// Reads Go's JSON form.
  factory ClaudeStopDetails.fromJson(Map<String, Object?> json) =>
      ClaudeStopDetails(
        category: readString(json, 'category'),
        explanation: readString(json, 'explanation'),
      );

  final String category;
  final String explanation;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'category', category);
    putString(json, 'explanation', explanation);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClaudeStopDetails &&
          other.category == category &&
          other.explanation == explanation;

  @override
  int get hashCode => Object.hash(category, explanation);

  @override
  String toString() => 'ClaudeStopDetails${toJson()}';
}

/// Claude's part of an `AssistantGenText`. Port of eino
/// `claude.AssistantGenTextExtension`.
@immutable
final class ClaudeAssistantGenTextExtension {
  ClaudeAssistantGenTextExtension({
    List<ClaudeTextCitation> citations = const [],
  }) : citations = List.unmodifiable(citations);

  /// Reads Go's JSON form.
  factory ClaudeAssistantGenTextExtension.fromJson(
    Map<String, Object?> json,
  ) =>
      ClaudeAssistantGenTextExtension(
        citations: readObjects(json, 'citations', ClaudeTextCitation.fromJson),
      );

  final List<ClaudeTextCitation> citations;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putList(json, 'citations', [
      for (final citation in citations) citation.toJson(),
    ]);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClaudeAssistantGenTextExtension &&
          const ListEquality<ClaudeTextCitation>()
              .equals(other.citations, citations);

  @override
  int get hashCode => const ListEquality<ClaudeTextCitation>().hash(citations);

  @override
  String toString() => 'ClaudeAssistantGenTextExtension${toJson()}';
}

/// A citation in generated text; the field that matches [type] is set.
/// Port of eino `claude.TextCitation`.
@immutable
final class ClaudeTextCitation {
  const ClaudeTextCitation({
    this.type,
    this.charLocation,
    this.pageLocation,
    this.contentBlockLocation,
    this.webSearchResultLocation,
  });

  /// Reads Go's JSON form.
  factory ClaudeTextCitation.fromJson(Map<String, Object?> json) =>
      ClaudeTextCitation(
        type: readOpenValue(json, 'type', ClaudeTextCitationType.new),
        charLocation: readObject(
          json,
          'char_location',
          ClaudeCitationCharLocation.fromJson,
        ),
        pageLocation: readObject(
          json,
          'page_location',
          ClaudeCitationPageLocation.fromJson,
        ),
        contentBlockLocation: readObject(
          json,
          'content_block_location',
          ClaudeCitationContentBlockLocation.fromJson,
        ),
        webSearchResultLocation: readObject(
          json,
          'web_search_result_location',
          ClaudeCitationWebSearchResultLocation.fromJson,
        ),
      );

  final ClaudeTextCitationType? type;
  final ClaudeCitationCharLocation? charLocation;
  final ClaudeCitationPageLocation? pageLocation;
  final ClaudeCitationContentBlockLocation? contentBlockLocation;
  final ClaudeCitationWebSearchResultLocation? webSearchResultLocation;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'type', type?.value ?? '');
    putObject(json, 'char_location', charLocation?.toJson());
    putObject(json, 'page_location', pageLocation?.toJson());
    putObject(json, 'content_block_location', contentBlockLocation?.toJson());
    putObject(
      json,
      'web_search_result_location',
      webSearchResultLocation?.toJson(),
    );
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClaudeTextCitation &&
          other.type == type &&
          other.charLocation == charLocation &&
          other.pageLocation == pageLocation &&
          other.contentBlockLocation == contentBlockLocation &&
          other.webSearchResultLocation == webSearchResultLocation;

  @override
  int get hashCode => Object.hash(
        type,
        charLocation,
        pageLocation,
        contentBlockLocation,
        webSearchResultLocation,
      );

  @override
  String toString() => 'ClaudeTextCitation${toJson()}';
}

/// Port of eino `claude.CitationCharLocation`.
@immutable
final class ClaudeCitationCharLocation {
  const ClaudeCitationCharLocation({
    this.citedText = '',
    this.documentTitle = '',
    this.documentIndex = 0,
    this.startCharIndex = 0,
    this.endCharIndex = 0,
  });

  /// Reads Go's JSON form.
  factory ClaudeCitationCharLocation.fromJson(Map<String, Object?> json) =>
      ClaudeCitationCharLocation(
        citedText: readString(json, 'cited_text'),
        documentTitle: readString(json, 'document_title'),
        documentIndex: readInt(json, 'document_index'),
        startCharIndex: readInt(json, 'start_char_index'),
        endCharIndex: readInt(json, 'end_char_index'),
      );

  final String citedText;
  final String documentTitle;
  final int documentIndex;
  final int startCharIndex;
  final int endCharIndex;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'cited_text', citedText);
    putString(json, 'document_title', documentTitle);
    putInt(json, 'document_index', documentIndex);
    putInt(json, 'start_char_index', startCharIndex);
    putInt(json, 'end_char_index', endCharIndex);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClaudeCitationCharLocation &&
          other.citedText == citedText &&
          other.documentTitle == documentTitle &&
          other.documentIndex == documentIndex &&
          other.startCharIndex == startCharIndex &&
          other.endCharIndex == endCharIndex;

  @override
  int get hashCode => Object.hash(
        citedText,
        documentTitle,
        documentIndex,
        startCharIndex,
        endCharIndex,
      );

  @override
  String toString() => 'ClaudeCitationCharLocation${toJson()}';
}

/// Port of eino `claude.CitationPageLocation`.
@immutable
final class ClaudeCitationPageLocation {
  const ClaudeCitationPageLocation({
    this.citedText = '',
    this.documentTitle = '',
    this.documentIndex = 0,
    this.startPageNumber = 0,
    this.endPageNumber = 0,
  });

  /// Reads Go's JSON form.
  factory ClaudeCitationPageLocation.fromJson(Map<String, Object?> json) =>
      ClaudeCitationPageLocation(
        citedText: readString(json, 'cited_text'),
        documentTitle: readString(json, 'document_title'),
        documentIndex: readInt(json, 'document_index'),
        startPageNumber: readInt(json, 'start_page_number'),
        endPageNumber: readInt(json, 'end_page_number'),
      );

  final String citedText;
  final String documentTitle;
  final int documentIndex;
  final int startPageNumber;
  final int endPageNumber;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'cited_text', citedText);
    putString(json, 'document_title', documentTitle);
    putInt(json, 'document_index', documentIndex);
    putInt(json, 'start_page_number', startPageNumber);
    putInt(json, 'end_page_number', endPageNumber);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClaudeCitationPageLocation &&
          other.citedText == citedText &&
          other.documentTitle == documentTitle &&
          other.documentIndex == documentIndex &&
          other.startPageNumber == startPageNumber &&
          other.endPageNumber == endPageNumber;

  @override
  int get hashCode => Object.hash(
        citedText,
        documentTitle,
        documentIndex,
        startPageNumber,
        endPageNumber,
      );

  @override
  String toString() => 'ClaudeCitationPageLocation${toJson()}';
}

/// Port of eino `claude.CitationContentBlockLocation`.
@immutable
final class ClaudeCitationContentBlockLocation {
  const ClaudeCitationContentBlockLocation({
    this.citedText = '',
    this.documentTitle = '',
    this.documentIndex = 0,
    this.startBlockIndex = 0,
    this.endBlockIndex = 0,
  });

  /// Reads Go's JSON form.
  factory ClaudeCitationContentBlockLocation.fromJson(
    Map<String, Object?> json,
  ) =>
      ClaudeCitationContentBlockLocation(
        citedText: readString(json, 'cited_text'),
        documentTitle: readString(json, 'document_title'),
        documentIndex: readInt(json, 'document_index'),
        startBlockIndex: readInt(json, 'start_block_index'),
        endBlockIndex: readInt(json, 'end_block_index'),
      );

  final String citedText;
  final String documentTitle;
  final int documentIndex;
  final int startBlockIndex;
  final int endBlockIndex;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'cited_text', citedText);
    putString(json, 'document_title', documentTitle);
    putInt(json, 'document_index', documentIndex);
    putInt(json, 'start_block_index', startBlockIndex);
    putInt(json, 'end_block_index', endBlockIndex);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClaudeCitationContentBlockLocation &&
          other.citedText == citedText &&
          other.documentTitle == documentTitle &&
          other.documentIndex == documentIndex &&
          other.startBlockIndex == startBlockIndex &&
          other.endBlockIndex == endBlockIndex;

  @override
  int get hashCode => Object.hash(
        citedText,
        documentTitle,
        documentIndex,
        startBlockIndex,
        endBlockIndex,
      );

  @override
  String toString() => 'ClaudeCitationContentBlockLocation${toJson()}';
}

/// Port of eino `claude.CitationWebSearchResultLocation`.
@immutable
final class ClaudeCitationWebSearchResultLocation {
  const ClaudeCitationWebSearchResultLocation({
    this.citedText = '',
    this.title = '',
    this.url = '',
    this.encryptedIndex = '',
  });

  /// Reads Go's JSON form.
  factory ClaudeCitationWebSearchResultLocation.fromJson(
    Map<String, Object?> json,
  ) =>
      ClaudeCitationWebSearchResultLocation(
        citedText: readString(json, 'cited_text'),
        title: readString(json, 'title'),
        url: readString(json, 'url'),
        encryptedIndex: readString(json, 'encrypted_index'),
      );

  final String citedText;
  final String title;
  final String url;
  final String encryptedIndex;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'cited_text', citedText);
    putString(json, 'title', title);
    putString(json, 'url', url);
    putString(json, 'encrypted_index', encryptedIndex);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClaudeCitationWebSearchResultLocation &&
          other.citedText == citedText &&
          other.title == title &&
          other.url == url &&
          other.encryptedIndex == encryptedIndex;

  @override
  int get hashCode => Object.hash(citedText, title, url, encryptedIndex);

  @override
  String toString() => 'ClaudeCitationWebSearchResultLocation${toJson()}';
}

/// Joins the extensions of the chunks of one streamed `AssistantGenText`.
///
/// Port of eino `claude.ConcatAssistantGenTextExtensions`: a single chunk is
/// returned as it is; otherwise the citations of all chunks are appended in
/// order. Throws [ArgumentError] when [chunks] is empty.
ClaudeAssistantGenTextExtension concatClaudeAssistantGenTextExtensions(
  List<ClaudeAssistantGenTextExtension> chunks,
) {
  if (chunks.isEmpty) {
    throw ArgumentError('no assistant generated text extension found');
  }
  if (chunks.length == 1) return chunks.single;
  return ClaudeAssistantGenTextExtension(
    citations: [for (final chunk in chunks) ...chunk.citations],
  );
}

/// Joins the response metadata extensions of the chunks of one response.
///
/// Port of eino `claude.ConcatResponseMetaExtensions`: a single chunk is
/// returned as it is; otherwise each field takes the last value that is set.
/// Throws [ArgumentError] when [chunks] is empty.
ClaudeResponseMetaExtension concatClaudeResponseMetaExtensions(
  List<ClaudeResponseMetaExtension> chunks,
) {
  if (chunks.isEmpty) throw ArgumentError('no response meta extension found');
  if (chunks.length == 1) return chunks.single;

  var id = '';
  var stopReason = '';
  var stopSequence = '';
  ClaudeStopDetails? stopDetails;
  for (final chunk in chunks) {
    if (chunk.id.isNotEmpty) id = chunk.id;
    if (chunk.stopReason.isNotEmpty) stopReason = chunk.stopReason;
    if (chunk.stopSequence.isNotEmpty) stopSequence = chunk.stopSequence;
    if (chunk.stopDetails != null) stopDetails = chunk.stopDetails;
  }
  return ClaudeResponseMetaExtension(
    id: id,
    stopReason: stopReason,
    stopSequence: stopSequence,
    stopDetails: stopDetails,
  );
}
