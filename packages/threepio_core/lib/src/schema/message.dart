import 'package:freezed_annotation/freezed_annotation.dart';

import '../core/run_context.dart';
import 'message_concat.dart';
import 'message_template.dart';
import 'tool_info.dart';

part 'message.freezed.dart';
part 'message.g.dart';

/// Role type for a message
enum RoleType {
  /// Message from the assistant/model
  @JsonValue('assistant')
  assistant,

  /// Message from the user
  @JsonValue('user')
  user,

  /// System message/instruction
  @JsonValue('system')
  system,

  /// Tool execution result
  @JsonValue('tool')
  tool,
}

/// Function call in a message
@freezed
abstract class FunctionCall with _$FunctionCall {
  const factory FunctionCall({
    /// Name of the function to call
    required String name,

    /// Arguments in JSON format
    required String arguments,
  }) = _FunctionCall;

  factory FunctionCall.fromJson(Map<String, dynamic> json) =>
      _$FunctionCallFromJson(json);
}

/// Tool call in a message
@freezed
abstract class ToolCall with _$ToolCall {
  const factory ToolCall({
    /// Index for multiple tool calls
    int? index,

    /// ID of the tool call
    required String id,

    /// Type of tool call (typically "function")
    @Default('function') String type,

    /// Function call details
    required FunctionCall function,

    /// Extra information
    Map<String, dynamic>? extra,
  }) = _ToolCall;

  factory ToolCall.fromJson(Map<String, dynamic> json) =>
      _$ToolCallFromJson(json);
}

/// Type of message part for multi-modal content
enum ChatMessagePartType {
  /// Text content
  @JsonValue('text')
  text,

  /// Image URL
  @JsonValue('image_url')
  imageUrl,

  /// Audio URL
  @JsonValue('audio_url')
  audioUrl,

  /// Video URL
  @JsonValue('video_url')
  videoUrl,

  /// File URL
  @JsonValue('file_url')
  fileUrl,

  /// Reasoning produced by the model (output parts only)
  @JsonValue('reasoning')
  reasoning,

  /// Result of a tool search: the definitions of the tools that were found
  @JsonValue('tool_search_result')
  toolSearchResult,
}

/// Image detail level
enum ImageURLDetail {
  /// High quality
  @JsonValue('high')
  high,

  /// Low quality
  @JsonValue('low')
  low,

  /// Auto quality
  @JsonValue('auto')
  auto,
}

/// Common structure for multi-modal message parts
///
/// Port of eino `schema.MessagePartCommon`. Give exactly one of [url],
/// [base64Data] and [fileId].
@freezed
abstract class MessagePartCommon with _$MessagePartCommon {
  const factory MessagePartCommon({
    /// URL (traditional or RFC-2397 data URI)
    String? url,

    /// Base64 encoded data
    String? base64Data,

    /// Reference to a file hosted by the model provider: a file id or a
    /// provider-specific file URI. Whether it is accepted depends on the
    /// model and the API.
    String? fileId,

    /// MIME type (e.g., "image/png", "audio/wav")
    String? mimeType,

    /// Extra information
    @Deprecated('Use MessageInputPart.extra / MessageOutputPart.extra')
    Map<String, dynamic>? extra,
  }) = _MessagePartCommon;

  factory MessagePartCommon.fromJson(Map<String, dynamic> json) =>
      _$MessagePartCommonFromJson(json);
}

/// Image input in a message
@freezed
abstract class MessageInputImage with _$MessageInputImage {
  const factory MessageInputImage({
    /// Common fields
    required MessagePartCommon common,

    /// Image quality detail
    ImageURLDetail? detail,
  }) = _MessageInputImage;

  factory MessageInputImage.fromJson(Map<String, dynamic> json) =>
      _$MessageInputImageFromJson(json);
}

/// Audio input in a message
@freezed
abstract class MessageInputAudio with _$MessageInputAudio {
  const factory MessageInputAudio({
    /// Common fields
    required MessagePartCommon common,
  }) = _MessageInputAudio;

  factory MessageInputAudio.fromJson(Map<String, dynamic> json) =>
      _$MessageInputAudioFromJson(json);
}

/// Video input in a message
@freezed
abstract class MessageInputVideo with _$MessageInputVideo {
  const factory MessageInputVideo({
    /// Common fields
    required MessagePartCommon common,
  }) = _MessageInputVideo;

  factory MessageInputVideo.fromJson(Map<String, dynamic> json) =>
      _$MessageInputVideoFromJson(json);
}

/// File input in a message
@freezed
abstract class MessageInputFile with _$MessageInputFile {
  const factory MessageInputFile({
    /// Common fields
    required MessagePartCommon common,

    /// File name
    String? name,
  }) = _MessageInputFile;

  factory MessageInputFile.fromJson(Map<String, dynamic> json) =>
      _$MessageInputFileFromJson(json);
}

/// Input part of a message (user-provided)
@freezed
abstract class MessageInputPart with _$MessageInputPart {
  const factory MessageInputPart({
    /// Type of the part
    required ChatMessagePartType type,

    /// Text content (when type is text)
    String? text,

    /// Image input (when type is imageUrl)
    MessageInputImage? image,

    /// Audio input (when type is audioUrl)
    MessageInputAudio? audio,

    /// Video input (when type is videoUrl)
    MessageInputVideo? video,

    /// File input (when type is fileUrl)
    MessageInputFile? file,

    /// Tools found by a tool search (when type is toolSearchResult)
    ToolSearchResult? toolSearchResult,

    /// Extra information
    Map<String, dynamic>? extra,
  }) = _MessageInputPart;

  factory MessageInputPart.fromJson(Map<String, dynamic> json) =>
      _$MessageInputPartFromJson(json);

  /// Create a text part
  factory MessageInputPart.text(String text) => MessageInputPart(
        type: ChatMessagePartType.text,
        text: text,
      );

  /// Create an image part from URL
  factory MessageInputPart.imageUrl(String url, {ImageURLDetail? detail}) =>
      MessageInputPart(
        type: ChatMessagePartType.imageUrl,
        image: MessageInputImage(
          common: MessagePartCommon(url: url),
          detail: detail,
        ),
      );

  /// Create an audio part. Give exactly one of [url], [base64Data] and
  /// [fileId].
  factory MessageInputPart.audio({
    String? url,
    String? base64Data,
    String? fileId,
    String? mimeType,
  }) =>
      MessageInputPart(
        type: ChatMessagePartType.audioUrl,
        audio: MessageInputAudio(
          common: MessagePartCommon(
            url: url,
            base64Data: base64Data,
            fileId: fileId,
            mimeType: mimeType,
          ),
        ),
      );

  /// Create a video part. Give exactly one of [url], [base64Data] and
  /// [fileId].
  factory MessageInputPart.video({
    String? url,
    String? base64Data,
    String? fileId,
    String? mimeType,
  }) =>
      MessageInputPart(
        type: ChatMessagePartType.videoUrl,
        video: MessageInputVideo(
          common: MessagePartCommon(
            url: url,
            base64Data: base64Data,
            fileId: fileId,
            mimeType: mimeType,
          ),
        ),
      );

  /// Create a file part. Give exactly one of [url], [base64Data] and
  /// [fileId]; [name] is the file name shown to the model.
  factory MessageInputPart.file({
    String? url,
    String? base64Data,
    String? fileId,
    String? mimeType,
    String? name,
  }) =>
      MessageInputPart(
        type: ChatMessagePartType.fileUrl,
        file: MessageInputFile(
          common: MessagePartCommon(
            url: url,
            base64Data: base64Data,
            fileId: fileId,
            mimeType: mimeType,
          ),
          name: name,
        ),
      );
}

/// Reasoning produced by a reasoning model, as one part of its output
///
/// Port of eino `schema.MessageOutputReasoning`.
@freezed
abstract class MessageOutputReasoning with _$MessageOutputReasoning {
  const factory MessageOutputReasoning({
    /// The thought summary, or the raw reasoning text
    @Default('') String text,

    /// Encrypted reasoning tokens. Some models require them when the
    /// reasoning is passed back in a later request.
    @Default('') String signature,
  }) = _MessageOutputReasoning;

  factory MessageOutputReasoning.fromJson(Map<String, dynamic> json) =>
      _$MessageOutputReasoningFromJson(json);
}

/// Where a streamed output part belongs in the final response
///
/// Port of eino `schema.MessageStreamingMeta`. When a model streams several
/// parts in one response, chunks with the same [index] are fragments of the
/// same part; [concatMessages] joins them.
@freezed
abstract class MessageStreamingMeta with _$MessageStreamingMeta {
  const factory MessageStreamingMeta({
    /// Position of the part in the final response
    @Default(0) int index,
  }) = _MessageStreamingMeta;

  factory MessageStreamingMeta.fromJson(Map<String, dynamic> json) =>
      _$MessageStreamingMetaFromJson(json);
}

/// Output part of a message (model-generated)
@freezed
abstract class MessageOutputPart with _$MessageOutputPart {
  const factory MessageOutputPart({
    /// Type of the part
    required ChatMessagePartType type,

    /// Text content
    String? text,

    /// Image output
    MessagePartCommon? image,

    /// Audio output
    MessagePartCommon? audio,

    /// Video output
    MessagePartCommon? video,

    /// Reasoning output (when type is reasoning)
    MessageOutputReasoning? reasoning,

    /// Extra information
    Map<String, dynamic>? extra,

    /// Position of this part while it is being streamed. Runtime information
    /// that is not written to JSON, as in Eino.
    @JsonKey(includeFromJson: false, includeToJson: false)
    MessageStreamingMeta? streamingMeta,
  }) = _MessageOutputPart;

  factory MessageOutputPart.fromJson(Map<String, dynamic> json) =>
      _$MessageOutputPartFromJson(json);
}

/// Token usage information
@freezed
abstract class TokenUsage with _$TokenUsage {
  const factory TokenUsage({
    /// Number of prompt tokens
    required int promptTokens,

    /// Number of completion tokens
    required int completionTokens,

    /// Total number of tokens
    required int totalTokens,

    /// Breakdown of prompt token details
    PromptTokenDetails? promptTokenDetails,

    /// Breakdown of completion token details (reasoning, image, audio)
    CompletionTokenDetails? completionTokenDetails,

    /// Cost in USD as reported by the provider (OpenRouter `usage.cost`)
    double? cost,
  }) = _TokenUsage;

  const TokenUsage._();

  factory TokenUsage.fromJson(Map<String, dynamic> json) =>
      _$TokenUsageFromJson(json);

  /// Usage with every counter at zero
  static const TokenUsage zero =
      TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0);

  /// Sum of two usages (details and cost included)
  TokenUsage operator +(TokenUsage other) => TokenUsage(
        promptTokens: promptTokens + other.promptTokens,
        completionTokens: completionTokens + other.completionTokens,
        totalTokens: totalTokens + other.totalTokens,
        promptTokenDetails: promptTokenDetails == null &&
                other.promptTokenDetails == null
            ? null
            : PromptTokenDetails(
                cachedTokens: (promptTokenDetails?.cachedTokens ?? 0) +
                    (other.promptTokenDetails?.cachedTokens ?? 0),
                cacheWriteTokens:
                    (promptTokenDetails?.cacheWriteTokens ?? 0) +
                        (other.promptTokenDetails?.cacheWriteTokens ?? 0),
              ),
        completionTokenDetails: completionTokenDetails == null &&
                other.completionTokenDetails == null
            ? null
            : CompletionTokenDetails(
                reasoningTokens:
                    (completionTokenDetails?.reasoningTokens ?? 0) +
                        (other.completionTokenDetails?.reasoningTokens ?? 0),
                imageTokens: (completionTokenDetails?.imageTokens ?? 0) +
                    (other.completionTokenDetails?.imageTokens ?? 0),
                audioTokens: (completionTokenDetails?.audioTokens ?? 0) +
                    (other.completionTokenDetails?.audioTokens ?? 0),
              ),
        cost: cost == null && other.cost == null
            ? null
            : (cost ?? 0) + (other.cost ?? 0),
      );
}

/// Completion token details
@freezed
abstract class CompletionTokenDetails with _$CompletionTokenDetails {
  const factory CompletionTokenDetails({
    /// Tokens spent on reasoning / thinking
    @Default(0) int reasoningTokens,

    /// Tokens spent producing images
    @Default(0) int imageTokens,

    /// Tokens spent producing audio
    @Default(0) int audioTokens,
  }) = _CompletionTokenDetails;

  factory CompletionTokenDetails.fromJson(Map<String, dynamic> json) =>
      _$CompletionTokenDetailsFromJson(json);
}

/// Prompt token details
@freezed
abstract class PromptTokenDetails with _$PromptTokenDetails {
  const factory PromptTokenDetails({
    /// Prompt tokens read from the cache
    @Default(0) int cachedTokens,

    /// Prompt tokens written to the cache
    @Default(0) int cacheWriteTokens,
  }) = _PromptTokenDetails;

  factory PromptTokenDetails.fromJson(Map<String, dynamic> json) =>
      _$PromptTokenDetailsFromJson(json);
}

/// Log probability information for a token
@freezed
abstract class LogProb with _$LogProb {
  const factory LogProb({
    /// The token text
    required String token,

    /// Log probability of this token
    required double logProb,

    /// UTF-8 bytes representation
    List<int>? bytes,

    /// Top log probabilities at this position
    @Default([]) List<TopLogProb> topLogProbs,
  }) = _LogProb;

  factory LogProb.fromJson(Map<String, dynamic> json) =>
      _$LogProbFromJson(json);
}

/// Top log probability information
@freezed
abstract class TopLogProb with _$TopLogProb {
  const factory TopLogProb({
    /// The token text
    required String token,

    /// Log probability of this token
    required double logProb,

    /// UTF-8 bytes representation
    List<int>? bytes,
  }) = _TopLogProb;

  factory TopLogProb.fromJson(Map<String, dynamic> json) =>
      _$TopLogProbFromJson(json);
}

/// Log probabilities structure
@freezed
abstract class LogProbs with _$LogProbs {
  const factory LogProbs({
    /// Content with log probability information
    @Default([]) List<LogProb> content,
  }) = _LogProbs;

  factory LogProbs.fromJson(Map<String, dynamic> json) =>
      _$LogProbsFromJson(json);
}

/// Response metadata
@freezed
abstract class ResponseMeta with _$ResponseMeta {
  const factory ResponseMeta({
    /// Reason for finishing (e.g., "stop", "length", "tool_calls")
    String? finishReason,

    /// Token usage information
    TokenUsage? usage,

    /// Log probability information
    LogProbs? logProbs,
  }) = _ResponseMeta;

  factory ResponseMeta.fromJson(Map<String, dynamic> json) =>
      _$ResponseMetaFromJson(json);
}

/// Main message class
///
/// Port of eino `schema.Message`. A message is also a [MessagesTemplate] of
/// itself: [format] fills the placeholders in its content.
@freezed
abstract class Message with _$Message implements MessagesTemplate {
  const factory Message({
    /// Role of the message sender
    required RoleType role,

    /// Text content of the message
    @Default('') String content,

    /// Multi-modal input content (user messages)
    List<MessageInputPart>? userInputMultiContent,

    /// Multi-modal output content (assistant messages)
    List<MessageOutputPart>? assistantGenMultiContent,

    /// Name of the sender
    String? name,

    /// Tool calls (for assistant messages)
    List<ToolCall>? toolCalls,

    /// Tool call ID (for tool messages)
    String? toolCallId,

    /// Tool name (for tool messages)
    String? toolName,

    /// Response metadata
    ResponseMeta? responseMeta,

    /// Reasoning content (thinking process)
    String? reasoningContent,

    /// Extra custom information
    Map<String, dynamic>? extra,
  }) = _Message;

  const Message._();

  factory Message.fromJson(Map<String, dynamic> json) =>
      _$MessageFromJson(json);

  /// Create a user message
  factory Message.user(String content) => Message(
        role: RoleType.user,
        content: content,
      );

  /// Create an assistant message
  factory Message.assistant(
    String content, {
    List<ToolCall>? toolCalls,
  }) =>
      Message(
        role: RoleType.assistant,
        content: content,
        toolCalls: toolCalls,
      );

  /// Create a system message
  factory Message.system(String content) => Message(
        role: RoleType.system,
        content: content,
      );

  /// Create a tool message
  factory Message.tool({
    required String content,
    required String toolCallId,
    String? toolName,
  }) =>
      Message(
        role: RoleType.tool,
        content: content,
        toolCallId: toolCallId,
        toolName: toolName,
      );

  /// This message with the placeholders in its text filled from [vars].
  ///
  /// Port of eino `Message.Format`. [content] is rendered, and so are the
  /// text parts and the media sources (`url`, `base64Data`, `fileId`) of
  /// [userInputMultiContent]. The result is a list with that one message.
  ///
  /// ```dart
  /// final template = Message.user('hello, {name}');
  /// final messages = await template.format(
  ///   RunContext.background(),
  ///   {'name': 'eino'},
  ///   FormatType.fString,
  /// ); // messages.single.content == 'hello, eino'
  /// ```
  ///
  /// Throws [FormatException] when the text is not a valid template or names
  /// a variable that [vars] does not have, and [UnsupportedError] for
  /// [FormatType.goTemplate].
  @override
  Future<List<Message>> format(
    RunContext ctx,
    Map<String, Object?> vars,
    FormatType type,
  ) async =>
      [formatMessage(this, vars, type)];

  /// Get a string representation of the message
  String toDisplayString() {
    final buffer = StringBuffer();
    buffer.write('${role.name}: $content');

    if (reasoningContent != null && reasoningContent!.isNotEmpty) {
      buffer.write('\nreasoning content:\n$reasoningContent');
    }

    if (toolCalls != null && toolCalls!.isNotEmpty) {
      buffer.write('\ntool_calls:\n');
      for (final tc in toolCalls!) {
        if (tc.index != null) {
          buffer.write('index[${tc.index}]:');
        }
        buffer.write('$tc\n');
      }
    }

    if (toolCallId != null) {
      buffer.write('\ntool_call_id: $toolCallId');
    }

    if (toolName != null) {
      buffer.write('\ntool_call_name: $toolName');
    }

    if (responseMeta != null) {
      buffer.write('\nfinish_reason: ${responseMeta!.finishReason}');
      if (responseMeta!.usage != null) {
        buffer.write('\nusage: ${responseMeta!.usage}');
      }
    }

    return buffer.toString();
  }
}

/// Helper to concatenate message chunks from a stream
///
/// The class form of [concatMessages], kept for existing callers.
class MessageConcatenator {
  /// Concatenate multiple messages into a single message
  ///
  /// The same as [concatMessages].
  static Message concat(List<Message> messages) => concatMessages(messages);
}
