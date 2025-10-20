import 'package:freezed_annotation/freezed_annotation.dart';

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
class FunctionCall with _$FunctionCall {
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
class ToolCall with _$ToolCall {
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
@freezed
class MessagePartCommon with _$MessagePartCommon {
  const factory MessagePartCommon({
    /// URL (traditional or RFC-2397 data URI)
    String? url,

    /// Base64 encoded data
    String? base64Data,

    /// MIME type (e.g., "image/png", "audio/wav")
    String? mimeType,

    /// Extra information
    Map<String, dynamic>? extra,
  }) = _MessagePartCommon;

  factory MessagePartCommon.fromJson(Map<String, dynamic> json) =>
      _$MessagePartCommonFromJson(json);
}

/// Image input in a message
@freezed
class MessageInputImage with _$MessageInputImage {
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
class MessageInputAudio with _$MessageInputAudio {
  const factory MessageInputAudio({
    /// Common fields
    required MessagePartCommon common,
  }) = _MessageInputAudio;

  factory MessageInputAudio.fromJson(Map<String, dynamic> json) =>
      _$MessageInputAudioFromJson(json);
}

/// Video input in a message
@freezed
class MessageInputVideo with _$MessageInputVideo {
  const factory MessageInputVideo({
    /// Common fields
    required MessagePartCommon common,
  }) = _MessageInputVideo;

  factory MessageInputVideo.fromJson(Map<String, dynamic> json) =>
      _$MessageInputVideoFromJson(json);
}

/// File input in a message
@freezed
class MessageInputFile with _$MessageInputFile {
  const factory MessageInputFile({
    /// Common fields
    required MessagePartCommon common,
  }) = _MessageInputFile;

  factory MessageInputFile.fromJson(Map<String, dynamic> json) =>
      _$MessageInputFileFromJson(json);
}

/// Input part of a message (user-provided)
@freezed
class MessageInputPart with _$MessageInputPart {
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
}

/// Output part of a message (model-generated)
@freezed
class MessageOutputPart with _$MessageOutputPart {
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
  }) = _MessageOutputPart;

  factory MessageOutputPart.fromJson(Map<String, dynamic> json) =>
      _$MessageOutputPartFromJson(json);
}

/// Token usage information
@freezed
class TokenUsage with _$TokenUsage {
  const factory TokenUsage({
    /// Number of prompt tokens
    required int promptTokens,

    /// Number of completion tokens
    required int completionTokens,

    /// Total number of tokens
    required int totalTokens,

    /// Breakdown of prompt token details
    PromptTokenDetails? promptTokenDetails,
  }) = _TokenUsage;

  factory TokenUsage.fromJson(Map<String, dynamic> json) =>
      _$TokenUsageFromJson(json);
}

/// Prompt token details
@freezed
class PromptTokenDetails with _$PromptTokenDetails {
  const factory PromptTokenDetails({
    /// Cached tokens in the prompt
    @Default(0) int cachedTokens,
  }) = _PromptTokenDetails;

  factory PromptTokenDetails.fromJson(Map<String, dynamic> json) =>
      _$PromptTokenDetailsFromJson(json);
}

/// Log probability information for a token
@freezed
class LogProb with _$LogProb {
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
class TopLogProb with _$TopLogProb {
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
class LogProbs with _$LogProbs {
  const factory LogProbs({
    /// Content with log probability information
    @Default([]) List<LogProb> content,
  }) = _LogProbs;

  factory LogProbs.fromJson(Map<String, dynamic> json) =>
      _$LogProbsFromJson(json);
}

/// Response metadata
@freezed
class ResponseMeta with _$ResponseMeta {
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
@freezed
class Message with _$Message {
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
class MessageConcatenator {
  /// Concatenate multiple messages into a single message
  static Message concat(List<Message> messages) {
    if (messages.isEmpty) {
      throw ArgumentError('Cannot concatenate empty message list');
    }

    if (messages.length == 1) {
      return messages.first;
    }

    final contents = <String>[];
    final reasoningContents = <String>[];
    final toolCalls = <ToolCall>[];
    final extras = <Map<String, dynamic>>[];

    RoleType? role;
    String? name;
    String? toolCallId;
    String? toolName;
    ResponseMeta? responseMeta;

    for (final msg in messages) {
      // Validate role consistency
      if (role == null) {
        role = msg.role;
      } else if (role != msg.role) {
        throw ArgumentError(
          'Cannot concat messages with different roles: $role and ${msg.role}',
        );
      }

      // Validate name consistency
      if (msg.name != null) {
        if (name == null) {
          name = msg.name;
        } else if (name != msg.name) {
          throw ArgumentError(
            'Cannot concat messages with different names: $name and ${msg.name}',
          );
        }
      }

      // Validate tool call ID consistency
      if (msg.toolCallId != null) {
        if (toolCallId == null) {
          toolCallId = msg.toolCallId;
        } else if (toolCallId != msg.toolCallId) {
          throw ArgumentError(
            'Cannot concat messages with different toolCallIds',
          );
        }
      }

      // Validate tool name consistency
      if (msg.toolName != null) {
        if (toolName == null) {
          toolName = msg.toolName;
        } else if (toolName != msg.toolName) {
          throw ArgumentError(
            'Cannot concat messages with different toolNames',
          );
        }
      }

      // Collect content
      if (msg.content.isNotEmpty) {
        contents.add(msg.content);
      }

      // Collect reasoning content
      if (msg.reasoningContent != null && msg.reasoningContent!.isNotEmpty) {
        reasoningContents.add(msg.reasoningContent!);
      }

      // Collect tool calls
      if (msg.toolCalls != null) {
        toolCalls.addAll(msg.toolCalls!);
      }

      // Collect extras
      if (msg.extra != null) {
        extras.add(msg.extra!);
      }

      // Update response meta (keep last non-null)
      if (msg.responseMeta != null) {
        responseMeta = msg.responseMeta;
      }
    }

    return Message(
      role: role ?? messages.first.role,
      content: contents.join(),
      name: name,
      toolCallId: toolCallId,
      toolName: toolName,
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      reasoningContent:
          reasoningContents.isEmpty ? null : reasoningContents.join(),
      responseMeta: responseMeta,
      extra: extras.isEmpty ? null : _mergeExtras(extras),
    );
  }

  static Map<String, dynamic>? _mergeExtras(List<Map<String, dynamic>> extras) {
    if (extras.isEmpty) return null;
    if (extras.length == 1) return extras.first;

    final merged = <String, dynamic>{};
    for (final extra in extras) {
      merged.addAll(extra);
    }
    return merged;
  }
}
