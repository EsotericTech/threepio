/// What an enhanced tool takes and returns: [ToolArgument] and the
/// multimodal [ToolResult].
///
/// Port of the tool result types of eino `schema/tool.go`.
library;

import 'package:freezed_annotation/freezed_annotation.dart';

import 'message.dart';
import 'tool_info.dart';

part 'tool_result.freezed.dart';
part 'tool_result.g.dart';

/// The kind of content in a [ToolOutputPart].
///
/// Port of eino `schema.ToolPartType`.
enum ToolPartType {
  /// Text
  @JsonValue('text')
  text,

  /// An image
  @JsonValue('image')
  image,

  /// Audio
  @JsonValue('audio')
  audio,

  /// A video
  @JsonValue('video')
  video,

  /// Any other file
  @JsonValue('file')
  file,

  /// The tools found by a tool search
  @JsonValue('tool_search_result')
  toolSearchResult,
}

/// An image in the output of a tool. Port of eino `schema.ToolOutputImage`.
@freezed
abstract class ToolOutputImage with _$ToolOutputImage {
  const factory ToolOutputImage({
    /// Where the image is: exactly one of URL, base64 data and file id
    required MessagePartCommon common,
  }) = _ToolOutputImage;

  factory ToolOutputImage.fromJson(Map<String, dynamic> json) =>
      _$ToolOutputImageFromJson(json);
}

/// Audio in the output of a tool. Port of eino `schema.ToolOutputAudio`.
@freezed
abstract class ToolOutputAudio with _$ToolOutputAudio {
  const factory ToolOutputAudio({
    /// Where the audio is: exactly one of URL, base64 data and file id
    required MessagePartCommon common,
  }) = _ToolOutputAudio;

  factory ToolOutputAudio.fromJson(Map<String, dynamic> json) =>
      _$ToolOutputAudioFromJson(json);
}

/// A video in the output of a tool. Port of eino `schema.ToolOutputVideo`.
@freezed
abstract class ToolOutputVideo with _$ToolOutputVideo {
  const factory ToolOutputVideo({
    /// Where the video is: exactly one of URL, base64 data and file id
    required MessagePartCommon common,
  }) = _ToolOutputVideo;

  factory ToolOutputVideo.fromJson(Map<String, dynamic> json) =>
      _$ToolOutputVideoFromJson(json);
}

/// A file in the output of a tool. Port of eino `schema.ToolOutputFile`.
@freezed
abstract class ToolOutputFile with _$ToolOutputFile {
  const factory ToolOutputFile({
    /// Where the file is: exactly one of URL, base64 data and file id
    required MessagePartCommon common,
  }) = _ToolOutputFile;

  factory ToolOutputFile.fromJson(Map<String, dynamic> json) =>
      _$ToolOutputFileFromJson(json);
}

/// One part of the output of a tool.
///
/// Port of eino `schema.ToolOutputPart`. [type] says which of the other
/// fields is set.
@freezed
abstract class ToolOutputPart with _$ToolOutputPart {
  const factory ToolOutputPart({
    /// Kind of content
    required ToolPartType type,

    /// Text (when type is text)
    String? text,

    /// Image (when type is image)
    ToolOutputImage? image,

    /// Audio (when type is audio)
    ToolOutputAudio? audio,

    /// Video (when type is video)
    ToolOutputVideo? video,

    /// File (when type is file)
    ToolOutputFile? file,

    /// Tools that were found (when type is toolSearchResult)
    ToolSearchResult? toolSearchResult,

    /// Extra information
    Map<String, dynamic>? extra,
  }) = _ToolOutputPart;

  factory ToolOutputPart.fromJson(Map<String, dynamic> json) =>
      _$ToolOutputPartFromJson(json);

  /// Create a text part
  factory ToolOutputPart.text(String text, {Map<String, dynamic>? extra}) =>
      ToolOutputPart(type: ToolPartType.text, text: text, extra: extra);
}

/// The input of a tool call, as an enhanced tool receives it.
///
/// Port of eino `schema.ToolArgument`.
@freezed
abstract class ToolArgument with _$ToolArgument {
  const factory ToolArgument(
    /// The arguments of the call, as JSON text
    String text,
  ) = _ToolArgument;

  factory ToolArgument.fromJson(Map<String, dynamic> json) =>
      _$ToolArgumentFromJson(json);
}

/// The multimodal output of a tool: text, images, files and so on.
///
/// Port of eino `schema.ToolResult`. Chunks of a streamed result are joined
/// with `concatToolResults`.
@freezed
abstract class ToolResult with _$ToolResult {
  const factory ToolResult([
    /// The parts of the output, in order
    @Default(<ToolOutputPart>[]) List<ToolOutputPart> parts,
  ]) = _ToolResult;

  const ToolResult._();

  factory ToolResult.fromJson(Map<String, dynamic> json) =>
      _$ToolResultFromJson(json);

  /// A result that is one piece of text.
  factory ToolResult.text(String text) => ToolResult([ToolOutputPart.text(text)]);

  /// The parts as input parts of a message, which is how a tool result is
  /// given back to the model.
  ///
  /// Port of eino `ToolResult.ToMessageInputParts`. Throws [StateError] when a
  /// part lacks the content its type announces.
  List<MessageInputPart> toMessageInputParts() =>
      [for (final part in parts) _toMessageInputPart(part)];
}

MessageInputPart _toMessageInputPart(ToolOutputPart part) {
  T content<T>(T? value, String what) =>
      value ??
      (throw StateError(
        '$what is nil for tool part type ${part.type.name}',
      ));

  return switch (part.type) {
    ToolPartType.text => MessageInputPart(
        type: ChatMessagePartType.text,
        text: part.text ?? '',
        extra: part.extra,
      ),
    ToolPartType.image => MessageInputPart(
        type: ChatMessagePartType.imageUrl,
        image: MessageInputImage(
          common: content(part.image, 'image content').common,
        ),
        extra: part.extra,
      ),
    ToolPartType.audio => MessageInputPart(
        type: ChatMessagePartType.audioUrl,
        audio: MessageInputAudio(
          common: content(part.audio, 'audio content').common,
        ),
        extra: part.extra,
      ),
    ToolPartType.video => MessageInputPart(
        type: ChatMessagePartType.videoUrl,
        video: MessageInputVideo(
          common: content(part.video, 'video content').common,
        ),
        extra: part.extra,
      ),
    ToolPartType.file => MessageInputPart(
        type: ChatMessagePartType.fileUrl,
        file: MessageInputFile(
          common: content(part.file, 'file content').common,
        ),
        extra: part.extra,
      ),
    ToolPartType.toolSearchResult => MessageInputPart(
        type: ChatMessagePartType.toolSearchResult,
        toolSearchResult: content(part.toolSearchResult, 'tool search result'),
      ),
  };
}
