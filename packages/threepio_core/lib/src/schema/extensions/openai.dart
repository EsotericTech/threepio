/// OpenAI-specific fields of agentic messages.
///
/// Port of eino `schema/openai` (`consts.go`, `extension.go`). **Beta**, as
/// the whole agentic path is upstream. Eino's package name is the namespace
/// there; here every type carries an `OpenAI` prefix instead.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../agentic_wire.dart';
import '../message_concat.dart';

/// The kind of an [OpenAITextAnnotation]. An open set: values the API adds
/// later are kept as they come.
///
/// Port of eino `openai.TextAnnotationType`.
@immutable
final class OpenAITextAnnotationType {
  /// The annotation type whose wire value is [value].
  const OpenAITextAnnotationType(this.value);

  /// A citation of an uploaded file.
  static const fileCitation = OpenAITextAnnotationType('file_citation');

  /// A citation of a web page.
  static const urlCitation = OpenAITextAnnotationType('url_citation');

  /// A citation of a file in a container.
  static const containerFileCitation =
      OpenAITextAnnotationType('container_file_citation');

  /// The path of a generated file.
  static const filePath = OpenAITextAnnotationType('file_path');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAITextAnnotationType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// How much the model reasons. Port of eino `openai.ReasoningEffort`.
@immutable
final class OpenAIReasoningEffort {
  /// The effort whose wire value is [value].
  const OpenAIReasoningEffort(this.value);

  /// `minimal`.
  static const minimal = OpenAIReasoningEffort('minimal');

  /// `low`.
  static const low = OpenAIReasoningEffort('low');

  /// `medium`.
  static const medium = OpenAIReasoningEffort('medium');

  /// `high`.
  static const high = OpenAIReasoningEffort('high');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIReasoningEffort && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// How the model summarises its reasoning. Port of eino
/// `openai.ReasoningSummary`.
@immutable
final class OpenAIReasoningSummary {
  /// The summary mode whose wire value is [value].
  const OpenAIReasoningSummary(this.value);

  /// `auto`.
  static const auto = OpenAIReasoningSummary('auto');

  /// `concise`.
  static const concise = OpenAIReasoningSummary('concise');

  /// `detailed`.
  static const detailed = OpenAIReasoningSummary('detailed');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIReasoningSummary && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The processing tier of a request. Port of eino `openai.ServiceTier`.
@immutable
final class OpenAIServiceTier {
  /// The tier whose wire value is [value].
  const OpenAIServiceTier(this.value);

  /// `auto`.
  static const auto = OpenAIServiceTier('auto');

  /// `default`.
  static const defaultTier = OpenAIServiceTier('default');

  /// `flex`.
  static const flex = OpenAIServiceTier('flex');

  /// `scale`.
  static const scale = OpenAIServiceTier('scale');

  /// `priority`.
  static const priority = OpenAIServiceTier('priority');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIServiceTier && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// How long a prompt cache entry is kept. Port of eino
/// `openai.PromptCacheRetention`.
@immutable
final class OpenAIPromptCacheRetention {
  /// The retention whose wire value is [value].
  const OpenAIPromptCacheRetention(this.value);

  /// `in-memory`.
  static const inMemory = OpenAIPromptCacheRetention('in-memory');

  /// `24h`.
  static const hours24 = OpenAIPromptCacheRetention('24h');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIPromptCacheRetention && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The status of a response. Port of eino `openai.ResponseStatus`.
@immutable
final class OpenAIResponseStatus {
  /// The status whose wire value is [value].
  const OpenAIResponseStatus(this.value);

  /// `completed`.
  static const completed = OpenAIResponseStatus('completed');

  /// `failed`.
  static const failed = OpenAIResponseStatus('failed');

  /// `in_progress`.
  static const inProgress = OpenAIResponseStatus('in_progress');

  /// `cancelled`.
  static const cancelled = OpenAIResponseStatus('cancelled');

  /// `queued`.
  static const queued = OpenAIResponseStatus('queued');

  /// `incomplete`.
  static const incomplete = OpenAIResponseStatus('incomplete');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponseStatus && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The code of a response error. An open set; port of eino
/// `openai.ResponseErrorCode` (the constants are Go's).
@immutable
final class OpenAIResponseErrorCode {
  /// The code whose wire value is [value].
  const OpenAIResponseErrorCode(this.value);

  static const serverError = OpenAIResponseErrorCode('server_error');
  static const rateLimitExceeded =
      OpenAIResponseErrorCode('rate_limit_exceeded');
  static const invalidPrompt = OpenAIResponseErrorCode('invalid_prompt');
  static const vectorStoreTimeout =
      OpenAIResponseErrorCode('vector_store_timeout');
  static const invalidImage = OpenAIResponseErrorCode('invalid_image');
  static const invalidImageFormat =
      OpenAIResponseErrorCode('invalid_image_format');
  static const invalidBase64Image =
      OpenAIResponseErrorCode('invalid_base64_image');
  static const invalidImageUrl = OpenAIResponseErrorCode('invalid_image_url');
  static const imageTooLarge = OpenAIResponseErrorCode('image_too_large');
  static const imageTooSmall = OpenAIResponseErrorCode('image_too_small');
  static const imageParseError = OpenAIResponseErrorCode('image_parse_error');
  static const imageContentPolicyViolation =
      OpenAIResponseErrorCode('image_content_policy_violation');
  static const invalidImageMode =
      OpenAIResponseErrorCode('invalid_image_mode');
  static const imageFileTooLarge =
      OpenAIResponseErrorCode('image_file_too_large');
  static const unsupportedImageMediaType =
      OpenAIResponseErrorCode('unsupported_image_media_type');
  static const emptyImageFile = OpenAIResponseErrorCode('empty_image_file');
  static const failedToDownloadImage =
      OpenAIResponseErrorCode('failed_to_download_image');
  static const imageFileNotFound =
      OpenAIResponseErrorCode('image_file_not_found');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponseErrorCode && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// OpenAI's part of `AgenticResponseMeta`. Port of eino
/// `openai.ResponseMetaExtension`. Empty strings and `0` stand for "not
/// set", as in Go.
@immutable
final class OpenAIResponseMetaExtension {
  const OpenAIResponseMetaExtension({
    this.id = '',
    this.status,
    this.error,
    this.incompleteDetails,
    this.previousResponseId = '',
    this.reasoning,
    this.serviceTier,
    this.createdAt = 0,
    this.promptCacheRetention,
  });

  /// Reads Go's JSON form (snake_case keys, as [toJson] writes them).
  factory OpenAIResponseMetaExtension.fromJson(Map<String, Object?> json) =>
      OpenAIResponseMetaExtension(
        id: readString(json, 'id'),
        status: readOpenValue(json, 'status', OpenAIResponseStatus.new),
        error: readObject(json, 'error', OpenAIResponseError.fromJson),
        incompleteDetails: readObject(
          json,
          'incomplete_details',
          OpenAIIncompleteDetails.fromJson,
        ),
        previousResponseId: readString(json, 'previous_response_id'),
        reasoning: readObject(json, 'reasoning', OpenAIReasoning.fromJson),
        serviceTier:
            readOpenValue(json, 'service_tier', OpenAIServiceTier.new),
        createdAt: readInt(json, 'created_at'),
        promptCacheRetention: readOpenValue(
          json,
          'prompt_cache_retention',
          OpenAIPromptCacheRetention.new,
        ),
      );

  final String id;
  final OpenAIResponseStatus? status;
  final OpenAIResponseError? error;
  final OpenAIIncompleteDetails? incompleteDetails;
  final String previousResponseId;
  final OpenAIReasoning? reasoning;
  final OpenAIServiceTier? serviceTier;

  /// Seconds since the epoch.
  final int createdAt;
  final OpenAIPromptCacheRetention? promptCacheRetention;

  /// Go's JSON form: snake_case keys, empty fields left out.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'id', id);
    putString(json, 'status', status?.value ?? '');
    putObject(json, 'error', error?.toJson());
    putObject(json, 'incomplete_details', incompleteDetails?.toJson());
    putString(json, 'previous_response_id', previousResponseId);
    putObject(json, 'reasoning', reasoning?.toJson());
    putString(json, 'service_tier', serviceTier?.value ?? '');
    putInt(json, 'created_at', createdAt);
    putString(
      json,
      'prompt_cache_retention',
      promptCacheRetention?.value ?? '',
    );
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAIResponseMetaExtension &&
          other.id == id &&
          other.status == status &&
          other.error == error &&
          other.incompleteDetails == incompleteDetails &&
          other.previousResponseId == previousResponseId &&
          other.reasoning == reasoning &&
          other.serviceTier == serviceTier &&
          other.createdAt == createdAt &&
          other.promptCacheRetention == promptCacheRetention;

  @override
  int get hashCode => Object.hash(
        id,
        status,
        error,
        incompleteDetails,
        previousResponseId,
        reasoning,
        serviceTier,
        createdAt,
        promptCacheRetention,
      );

  @override
  String toString() => 'OpenAIResponseMetaExtension${toJson()}';
}

/// OpenAI's part of an `AssistantGenText`. Port of eino
/// `openai.AssistantGenTextExtension`.
@immutable
final class OpenAIAssistantGenTextExtension {
  OpenAIAssistantGenTextExtension({
    this.refusal,
    List<OpenAITextAnnotation> annotations = const [],
  }) : annotations = List.unmodifiable(annotations);

  /// Reads Go's JSON form.
  factory OpenAIAssistantGenTextExtension.fromJson(
    Map<String, Object?> json,
  ) =>
      OpenAIAssistantGenTextExtension(
        refusal: readObject(json, 'refusal', OpenAIOutputRefusal.fromJson),
        annotations:
            readObjects(json, 'annotations', OpenAITextAnnotation.fromJson),
      );

  final OpenAIOutputRefusal? refusal;
  final List<OpenAITextAnnotation> annotations;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putObject(json, 'refusal', refusal?.toJson());
    putList(json, 'annotations', [
      for (final annotation in annotations) annotation.toJson(),
    ]);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAIAssistantGenTextExtension &&
          other.refusal == refusal &&
          const ListEquality<OpenAITextAnnotation>()
              .equals(other.annotations, annotations);

  @override
  int get hashCode => Object.hash(
        refusal,
        const ListEquality<OpenAITextAnnotation>().hash(annotations),
      );

  @override
  String toString() => 'OpenAIAssistantGenTextExtension${toJson()}';
}

/// OpenAI's part of a `Reasoning`. Port of eino `openai.ReasoningExtension`.
@immutable
final class OpenAIReasoningExtension {
  OpenAIReasoningExtension({List<OpenAIReasoningContent> content = const []})
      : content = List.unmodifiable(content);

  /// Reads Go's JSON form.
  factory OpenAIReasoningExtension.fromJson(Map<String, Object?> json) =>
      OpenAIReasoningExtension(
        content: readObjects(json, 'content', OpenAIReasoningContent.fromJson),
      );

  /// The reasoning text, in parts.
  final List<OpenAIReasoningContent> content;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putList(json, 'content', [for (final part in content) part.toJson()]);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAIReasoningExtension &&
          const ListEquality<OpenAIReasoningContent>()
              .equals(other.content, content);

  @override
  int get hashCode =>
      const ListEquality<OpenAIReasoningContent>().hash(content);

  @override
  String toString() => 'OpenAIReasoningExtension${toJson()}';
}

/// One part of the reasoning text. Port of eino `openai.ReasoningContent`.
@immutable
final class OpenAIReasoningContent {
  const OpenAIReasoningContent({this.index, this.text = ''});

  /// Reads Go's JSON form.
  factory OpenAIReasoningContent.fromJson(Map<String, Object?> json) =>
      OpenAIReasoningContent(
        index: readIntOrNull(json, 'index'),
        text: readString(json, 'text'),
      );

  /// Where the part goes in the final response; streaming only.
  final int? index;
  final String text;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putObject(json, 'index', index);
    putString(json, 'text', text);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAIReasoningContent &&
          other.index == index &&
          other.text == text;

  @override
  int get hashCode => Object.hash(index, text);

  @override
  String toString() => 'OpenAIReasoningContent${toJson()}';
}

/// Port of eino `openai.ResponseError`.
@immutable
final class OpenAIResponseError {
  const OpenAIResponseError({this.code, this.message = ''});

  /// Reads Go's JSON form.
  factory OpenAIResponseError.fromJson(Map<String, Object?> json) =>
      OpenAIResponseError(
        code: readOpenValue(json, 'code', OpenAIResponseErrorCode.new),
        message: readString(json, 'message'),
      );

  final OpenAIResponseErrorCode? code;
  final String message;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'code', code?.value ?? '');
    putString(json, 'message', message);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAIResponseError &&
          other.code == code &&
          other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'OpenAIResponseError${toJson()}';
}

/// Port of eino `openai.IncompleteDetails`.
@immutable
final class OpenAIIncompleteDetails {
  const OpenAIIncompleteDetails({this.reason = ''});

  /// Reads Go's JSON form.
  factory OpenAIIncompleteDetails.fromJson(Map<String, Object?> json) =>
      OpenAIIncompleteDetails(reason: readString(json, 'reason'));

  final String reason;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'reason', reason);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAIIncompleteDetails && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'OpenAIIncompleteDetails${toJson()}';
}

/// Port of eino `openai.Reasoning`.
@immutable
final class OpenAIReasoning {
  const OpenAIReasoning({this.effort, this.summary});

  /// Reads Go's JSON form.
  factory OpenAIReasoning.fromJson(Map<String, Object?> json) =>
      OpenAIReasoning(
        effort: readOpenValue(json, 'effort', OpenAIReasoningEffort.new),
        summary: readOpenValue(json, 'summary', OpenAIReasoningSummary.new),
      );

  final OpenAIReasoningEffort? effort;
  final OpenAIReasoningSummary? summary;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'effort', effort?.value ?? '');
    putString(json, 'summary', summary?.value ?? '');
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAIReasoning &&
          other.effort == effort &&
          other.summary == summary;

  @override
  int get hashCode => Object.hash(effort, summary);

  @override
  String toString() => 'OpenAIReasoning${toJson()}';
}

/// Port of eino `openai.OutputRefusal`.
@immutable
final class OpenAIOutputRefusal {
  const OpenAIOutputRefusal({this.reason = ''});

  /// Reads Go's JSON form.
  factory OpenAIOutputRefusal.fromJson(Map<String, Object?> json) =>
      OpenAIOutputRefusal(reason: readString(json, 'reason'));

  final String reason;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'reason', reason);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAIOutputRefusal && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'OpenAIOutputRefusal${toJson()}';
}

/// An annotation of generated text. Port of eino `openai.TextAnnotation`.
/// The field that matches [type] is set.
@immutable
final class OpenAITextAnnotation {
  const OpenAITextAnnotation({
    this.index = 0,
    this.type,
    this.fileCitation,
    this.urlCitation,
    this.containerFileCitation,
    this.filePath,
  });

  /// Reads Go's JSON form.
  factory OpenAITextAnnotation.fromJson(Map<String, Object?> json) =>
      OpenAITextAnnotation(
        index: readInt(json, 'index'),
        type: readOpenValue(json, 'type', OpenAITextAnnotationType.new),
        fileCitation: readObject(
          json,
          'file_citation',
          OpenAITextAnnotationFileCitation.fromJson,
        ),
        urlCitation: readObject(
          json,
          'url_citation',
          OpenAITextAnnotationUrlCitation.fromJson,
        ),
        containerFileCitation: readObject(
          json,
          'container_file_citation',
          OpenAITextAnnotationContainerFileCitation.fromJson,
        ),
        filePath: readObject(
          json,
          'file_path',
          OpenAITextAnnotationFilePath.fromJson,
        ),
      );

  /// Where the annotation goes in the final response; streaming only.
  final int index;
  final OpenAITextAnnotationType? type;
  final OpenAITextAnnotationFileCitation? fileCitation;
  final OpenAITextAnnotationUrlCitation? urlCitation;
  final OpenAITextAnnotationContainerFileCitation? containerFileCitation;
  final OpenAITextAnnotationFilePath? filePath;

  /// A copy with [index] replaced.
  OpenAITextAnnotation withIndex(int index) => OpenAITextAnnotation(
        index: index,
        type: type,
        fileCitation: fileCitation,
        urlCitation: urlCitation,
        containerFileCitation: containerFileCitation,
        filePath: filePath,
      );

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putInt(json, 'index', index);
    putString(json, 'type', type?.value ?? '');
    putObject(json, 'file_citation', fileCitation?.toJson());
    putObject(json, 'url_citation', urlCitation?.toJson());
    putObject(
      json,
      'container_file_citation',
      containerFileCitation?.toJson(),
    );
    putObject(json, 'file_path', filePath?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAITextAnnotation &&
          other.index == index &&
          other.type == type &&
          other.fileCitation == fileCitation &&
          other.urlCitation == urlCitation &&
          other.containerFileCitation == containerFileCitation &&
          other.filePath == filePath;

  @override
  int get hashCode => Object.hash(
        index,
        type,
        fileCitation,
        urlCitation,
        containerFileCitation,
        filePath,
      );

  @override
  String toString() => 'OpenAITextAnnotation${toJson()}';
}

/// Port of eino `openai.TextAnnotationFileCitation`.
@immutable
final class OpenAITextAnnotationFileCitation {
  const OpenAITextAnnotationFileCitation({
    this.fileId = '',
    this.filename = '',
    this.index = 0,
  });

  /// Reads Go's JSON form.
  factory OpenAITextAnnotationFileCitation.fromJson(
    Map<String, Object?> json,
  ) =>
      OpenAITextAnnotationFileCitation(
        fileId: readString(json, 'file_id'),
        filename: readString(json, 'filename'),
        index: readInt(json, 'index'),
      );

  final String fileId;
  final String filename;
  final int index;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'file_id', fileId);
    putString(json, 'filename', filename);
    putInt(json, 'index', index);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAITextAnnotationFileCitation &&
          other.fileId == fileId &&
          other.filename == filename &&
          other.index == index;

  @override
  int get hashCode => Object.hash(fileId, filename, index);

  @override
  String toString() => 'OpenAITextAnnotationFileCitation${toJson()}';
}

/// Port of eino `openai.TextAnnotationURLCitation`.
@immutable
final class OpenAITextAnnotationUrlCitation {
  const OpenAITextAnnotationUrlCitation({
    this.title = '',
    this.url = '',
    this.startIndex = 0,
    this.endIndex = 0,
  });

  /// Reads Go's JSON form.
  factory OpenAITextAnnotationUrlCitation.fromJson(
    Map<String, Object?> json,
  ) =>
      OpenAITextAnnotationUrlCitation(
        title: readString(json, 'title'),
        url: readString(json, 'url'),
        startIndex: readInt(json, 'start_index'),
        endIndex: readInt(json, 'end_index'),
      );

  final String title;
  final String url;
  final int startIndex;
  final int endIndex;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'title', title);
    putString(json, 'url', url);
    putInt(json, 'start_index', startIndex);
    putInt(json, 'end_index', endIndex);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAITextAnnotationUrlCitation &&
          other.title == title &&
          other.url == url &&
          other.startIndex == startIndex &&
          other.endIndex == endIndex;

  @override
  int get hashCode => Object.hash(title, url, startIndex, endIndex);

  @override
  String toString() => 'OpenAITextAnnotationUrlCitation${toJson()}';
}

/// Port of eino `openai.TextAnnotationContainerFileCitation`.
@immutable
final class OpenAITextAnnotationContainerFileCitation {
  const OpenAITextAnnotationContainerFileCitation({
    this.containerId = '',
    this.fileId = '',
    this.filename = '',
    this.startIndex = 0,
    this.endIndex = 0,
  });

  /// Reads Go's JSON form.
  factory OpenAITextAnnotationContainerFileCitation.fromJson(
    Map<String, Object?> json,
  ) =>
      OpenAITextAnnotationContainerFileCitation(
        containerId: readString(json, 'container_id'),
        fileId: readString(json, 'file_id'),
        filename: readString(json, 'filename'),
        startIndex: readInt(json, 'start_index'),
        endIndex: readInt(json, 'end_index'),
      );

  final String containerId;
  final String fileId;
  final String filename;
  final int startIndex;
  final int endIndex;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'container_id', containerId);
    putString(json, 'file_id', fileId);
    putString(json, 'filename', filename);
    putInt(json, 'start_index', startIndex);
    putInt(json, 'end_index', endIndex);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAITextAnnotationContainerFileCitation &&
          other.containerId == containerId &&
          other.fileId == fileId &&
          other.filename == filename &&
          other.startIndex == startIndex &&
          other.endIndex == endIndex;

  @override
  int get hashCode =>
      Object.hash(containerId, fileId, filename, startIndex, endIndex);

  @override
  String toString() => 'OpenAITextAnnotationContainerFileCitation${toJson()}';
}

/// Port of eino `openai.TextAnnotationFilePath`.
@immutable
final class OpenAITextAnnotationFilePath {
  const OpenAITextAnnotationFilePath({this.fileId = '', this.index = 0});

  /// Reads Go's JSON form.
  factory OpenAITextAnnotationFilePath.fromJson(Map<String, Object?> json) =>
      OpenAITextAnnotationFilePath(
        fileId: readString(json, 'file_id'),
        index: readInt(json, 'index'),
      );

  final String fileId;
  final int index;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'file_id', fileId);
    putInt(json, 'index', index);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OpenAITextAnnotationFilePath &&
          other.fileId == fileId &&
          other.index == index;

  @override
  int get hashCode => Object.hash(fileId, index);

  @override
  String toString() => 'OpenAITextAnnotationFilePath${toJson()}';
}

/// Joins the extensions of the chunks of one streamed `AssistantGenText`.
///
/// Port of eino `openai.ConcatAssistantGenTextExtensions`. The annotations
/// of all chunks are put in the order of their streaming index
/// ([OpenAITextAnnotation.index], reset to 0 in the result); two annotations
/// with the same index throw [MessageConcatException]. The refusal reasons
/// are concatenated. Throws [ArgumentError] when [chunks] is empty.
OpenAIAssistantGenTextExtension concatOpenAIAssistantGenTextExtensions(
  List<OpenAIAssistantGenTextExtension> chunks,
) {
  if (chunks.isEmpty) {
    throw ArgumentError('no assistant generated text extension found');
  }

  final byIndex = <int, OpenAITextAnnotation>{};
  final indices = <int>[];
  for (final chunk in chunks) {
    for (final annotation in chunk.annotations) {
      if (byIndex.containsKey(annotation.index)) {
        throw MessageConcatException(
          'duplicate annotation index ${annotation.index}',
        );
      }
      byIndex[annotation.index] = annotation;
      indices.add(annotation.index);
    }
  }
  indices.sort();

  OpenAIOutputRefusal? refusal;
  for (final chunk in chunks) {
    final next = chunk.refusal;
    if (next == null) continue;
    refusal = refusal == null
        ? next
        : OpenAIOutputRefusal(reason: refusal.reason + next.reason);
  }

  return OpenAIAssistantGenTextExtension(
    refusal: refusal,
    annotations: [for (final index in indices) byIndex[index]!.withIndex(0)],
  );
}

/// Joins the extensions of the chunks of one streamed `Reasoning`.
///
/// Port of eino `openai.ConcatReasoningExtensions`. Parts with an index are
/// joined per index and ordered by it; parts without one are kept in the
/// order they came. The result's parts carry no index. Chunks that mix the
/// two kinds throw [MessageConcatException]; an empty [chunks] throws
/// [ArgumentError].
OpenAIReasoningExtension concatOpenAIReasoningExtensions(
  List<OpenAIReasoningExtension> chunks,
) {
  if (chunks.isEmpty) throw ArgumentError('no reasoning extension found');

  final unindexed = <OpenAIReasoningContent>[];
  final byIndex = <int, StringBuffer>{};
  final indices = <int>[];
  var hasIndexed = false;
  var hasUnindexed = false;

  for (final chunk in chunks) {
    for (final part in chunk.content) {
      final index = part.index;
      if (index == null) {
        hasUnindexed = true;
        unindexed.add(OpenAIReasoningContent(text: part.text));
        continue;
      }
      hasIndexed = true;
      final known = byIndex[index];
      if (known != null) {
        known.write(part.text);
      } else {
        byIndex[index] = StringBuffer(part.text);
        indices.add(index);
      }
    }
  }

  if (hasIndexed && hasUnindexed) {
    throw const MessageConcatException(
      'reasoning content chunks mix indexed and non-indexed content',
    );
  }

  if (!hasIndexed) return OpenAIReasoningExtension(content: unindexed);
  indices.sort();
  return OpenAIReasoningExtension(
    content: [
      for (final index in indices)
        OpenAIReasoningContent(text: byIndex[index].toString()),
    ],
  );
}

/// Joins the response metadata extensions of the chunks of one response.
///
/// Port of eino `openai.ConcatResponseMetaExtensions`: a single chunk is
/// returned as it is; otherwise each field takes the last value that is set.
/// Throws [ArgumentError] when [chunks] is empty.
OpenAIResponseMetaExtension concatOpenAIResponseMetaExtensions(
  List<OpenAIResponseMetaExtension> chunks,
) {
  if (chunks.isEmpty) throw ArgumentError('no response meta extension found');
  if (chunks.length == 1) return chunks.single;

  var id = '';
  OpenAIResponseStatus? status;
  OpenAIResponseError? error;
  OpenAIIncompleteDetails? incompleteDetails;
  var previousResponseId = '';
  OpenAIReasoning? reasoning;
  OpenAIServiceTier? serviceTier;
  var createdAt = 0;
  OpenAIPromptCacheRetention? promptCacheRetention;

  for (final chunk in chunks) {
    if (chunk.id.isNotEmpty) id = chunk.id;
    if (chunk.status?.value.isNotEmpty ?? false) status = chunk.status;
    if (chunk.error != null) error = chunk.error;
    if (chunk.incompleteDetails != null) {
      incompleteDetails = chunk.incompleteDetails;
    }
    if (chunk.previousResponseId.isNotEmpty) {
      previousResponseId = chunk.previousResponseId;
    }
    if (chunk.reasoning != null) reasoning = chunk.reasoning;
    if (chunk.serviceTier?.value.isNotEmpty ?? false) {
      serviceTier = chunk.serviceTier;
    }
    if (chunk.createdAt != 0) createdAt = chunk.createdAt;
    if (chunk.promptCacheRetention?.value.isNotEmpty ?? false) {
      promptCacheRetention = chunk.promptCacheRetention;
    }
  }

  return OpenAIResponseMetaExtension(
    id: id,
    status: status,
    error: error,
    incompleteDetails: incompleteDetails,
    previousResponseId: previousResponseId,
    reasoning: reasoning,
    serviceTier: serviceTier,
    createdAt: createdAt,
    promptCacheRetention: promptCacheRetention,
  );
}
