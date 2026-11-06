/// Agentic messages: a role and an ordered list of typed content blocks
/// (reasoning, text, media, function/server/MCP tool calls and results).
///
/// Port of eino `schema/agentic_message.go`. **Beta**, as the whole agentic
/// path is upstream ("keep `Message` unless you need model-native agentic
/// protocols"). Hand-written immutable classes rather than freezed: the JSON
/// form is Go's, with the payload of a block nested under its type
/// (`{"type": "reasoning", "reasoning": {...}}`), which freezed unions do not
/// produce.
///
/// Every type here has value equality (deep for lists and maps), `toJson` /
/// `fromJson` in Go's `encoding/json` shape (snake_case keys, empty fields
/// left out as Go's `omitempty` does), and a `toString()` that is Go's
/// `String()` where Go has one. Joining streamed chunks is
/// `concatAgenticMessages` (`agentic_message_concat.dart`).
///
/// **Values of a type only the producer knows** — [AgenticResponseMeta.extension],
/// [AssistantGenText.extension], [ServerToolCall.arguments],
/// [ServerToolResult.content] — and the values of the `extra` maps are
/// written with `TypeRegistry.encode` and read back with
/// `TypeRegistry.decode`: JSON values (strings, numbers, bools, lists, maps)
/// come out exactly as Go writes them, and a value of a type registered with
/// `TypeRegistry.registerName` is tagged with its name and comes back as
/// itself (Go's checkpoints keep such values through `gob`). A value that is
/// neither makes `toJson` throw [ArgumentError].
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../core/field_addressable.dart';
import '../core/run_context.dart';
import '../errors.dart';
import 'agentic_message_template.dart';
import 'agentic_wire.dart';
import 'extensions/claude.dart';
import 'extensions/gemini.dart';
import 'extensions/openai.dart';
import 'message.dart';
import 'message_template.dart';
import 'tool_info.dart';

/// The kind of a [ContentBlock]; [value] is Go's wire value.
///
/// Port of eino `schema.ContentBlockType`.
enum ContentBlockType {
  reasoning('reasoning'),
  userInputText('user_input_text'),
  userInputImage('user_input_image'),
  userInputAudio('user_input_audio'),
  userInputVideo('user_input_video'),
  userInputFile('user_input_file'),
  toolSearchResult('tool_search_result'),
  assistantGenText('assistant_gen_text'),
  assistantGenImage('assistant_gen_image'),
  assistantGenAudio('assistant_gen_audio'),
  assistantGenVideo('assistant_gen_video'),
  functionToolCall('function_tool_call'),
  functionToolResult('function_tool_result'),
  serverToolCall('server_tool_call'),
  serverToolResult('server_tool_result'),
  mcpToolCall('mcp_tool_call'),
  mcpToolResult('mcp_tool_result'),
  mcpListToolsResult('mcp_list_tools_result'),
  mcpToolApprovalRequest('mcp_tool_approval_request'),
  mcpToolApprovalResponse('mcp_tool_approval_response');

  const ContentBlockType(this.value);

  /// The wire value.
  final String value;

  /// The type whose wire value is [value], or `null` for an unknown one.
  static ContentBlockType? fromValue(String value) =>
      values.firstWhereOrNull((type) => type.value == value);

  /// The key of a block's payload in Go's JSON: the wire value, except for
  /// [toolSearchResult], whose payload field is
  /// `tool_search_function_tool_result`.
  String get payloadKey => switch (this) {
        toolSearchResult => 'tool_search_function_tool_result',
        _ => value,
      };
}

/// Who an [AgenticMessage] is from. Port of eino `schema.AgenticRoleType`.
enum AgenticRoleType {
  system('system'),
  user('user'),
  assistant('assistant');

  const AgenticRoleType(this.value);

  /// The wire value.
  final String value;

  /// The role whose wire value is [value], or `null` for an unknown one.
  static AgenticRoleType? fromValue(String value) =>
      values.firstWhereOrNull((role) => role.value == value);
}

/// A message of the agentic path: a [role] and its [contentBlocks].
///
/// Port of eino `schema.AgenticMessage`. Tool results travel as
/// [FunctionToolResult] blocks in [AgenticRoleType.user] messages.
///
/// A message is also an [AgenticMessagesTemplate]: [format] fills the
/// placeholders of its user input blocks. It is [FieldAddressable], so the
/// field mappings of a workflow reach its fields ([getField]).
@immutable
final class AgenticMessage
    implements AgenticMessagesTemplate, FieldAddressable {
  /// A message from [role].
  AgenticMessage({
    required this.role,
    List<ContentBlock> contentBlocks = const [],
    this.responseMeta,
    Map<String, Object?>? extra,
  })  : contentBlocks = List.unmodifiable(contentBlocks),
        extra = extra == null ? null : Map.unmodifiable(extra);

  /// A system message with one [UserInputText] block. Port of eino
  /// `schema.SystemAgenticMessage`.
  factory AgenticMessage.system(String text) => AgenticMessage(
        role: AgenticRoleType.system,
        contentBlocks: [ContentBlock(UserInputText(text: text))],
      );

  /// A user message with one [UserInputText] block. Port of eino
  /// `schema.UserAgenticMessage`.
  factory AgenticMessage.user(String text) => AgenticMessage(
        role: AgenticRoleType.user,
        contentBlocks: [ContentBlock(UserInputText(text: text))],
      );

  /// Reads Go's JSON form, as [toJson] writes it.
  ///
  /// Throws [ThreepioFormatException] for a missing or unknown role or block
  /// type.
  factory AgenticMessage.fromJson(Map<String, Object?> json) {
    final roleValue = readString(json, 'role');
    final role = AgenticRoleType.fromValue(roleValue) ??
        (throw ThreepioFormatException(
          'unknown agentic role type: "$roleValue"',
        ));
    return AgenticMessage(
      role: role,
      contentBlocks: readObjects(json, 'content_blocks', ContentBlock.fromJson),
      responseMeta:
          readObject(json, 'response_meta', AgenticResponseMeta.fromJson),
      extra: readExtra(json, 'extra'),
    );
  }

  final AgenticRoleType role;
  final List<ContentBlock> contentBlocks;
  final AgenticResponseMeta? responseMeta;

  /// Additional information. Port of the field `Extra`.
  final Map<String, Object?>? extra;

  /// A copy with the given fields replaced. Pass [clearResponseMeta] or
  /// [clearExtra] to remove those fields.
  AgenticMessage copyWith({
    AgenticRoleType? role,
    List<ContentBlock>? contentBlocks,
    AgenticResponseMeta? responseMeta,
    Map<String, Object?>? extra,
    bool clearResponseMeta = false,
    bool clearExtra = false,
  }) =>
      AgenticMessage(
        role: role ?? this.role,
        contentBlocks: contentBlocks ?? this.contentBlocks,
        responseMeta:
            clearResponseMeta ? null : responseMeta ?? this.responseMeta,
        extra: clearExtra ? null : extra ?? this.extra,
      );

  /// The field [name] of the message, for the field mappings of a workflow
  /// (Go reaches the struct fields by reflection).
  ///
  /// The names are those of the constructor parameters, as for `Message`:
  /// `role`, `contentBlocks`, `responseMeta`, `extra`. Go's field names
  /// (`Role`, `ContentBlocks`, `ResponseMeta`, `Extra`) are accepted too.
  @override
  Object? getField(String name) => switch (name) {
        'role' || 'Role' => role,
        'contentBlocks' || 'ContentBlocks' => contentBlocks,
        'responseMeta' || 'ResponseMeta' => responseMeta,
        'extra' || 'Extra' => extra,
        _ => throw ArgumentError.value(
            name,
            'name',
            'AgenticMessage has no such field',
          ),
      };

  /// A copy of the message with [value] as its field [name]; see [getField]
  /// for the names. `null` clears `responseMeta`, `extra` and
  /// `contentBlocks`.
  @override
  AgenticMessage withField(String name, Object? value) => switch (name) {
        'role' || 'Role' => copyWith(role: value! as AgenticRoleType),
        'contentBlocks' || 'ContentBlocks' => copyWith(
            contentBlocks:
                (value as List<Object?>?)?.cast<ContentBlock>() ?? const [],
          ),
        'responseMeta' || 'ResponseMeta' => value == null
            ? copyWith(clearResponseMeta: true)
            : copyWith(responseMeta: value as AgenticResponseMeta),
        'extra' || 'Extra' => value == null
            ? copyWith(clearExtra: true)
            : copyWith(extra: (value as Map<Object?, Object?>).cast()),
        _ => throw ArgumentError.value(
            name,
            'name',
            'AgenticMessage has no such field',
          ),
      };

  /// This message with the placeholders of its user input blocks filled
  /// from [vars], read as [type].
  ///
  /// Port of eino `AgenticMessage.Format`. Only user input is rendered: the
  /// text of [UserInputText], and the non-empty `url`, `fileId` and
  /// `base64Data` of [UserInputImage], [UserInputAudio], [UserInputVideo]
  /// and [UserInputFile] (and the `name` of a file). Every other block, and
  /// the role, metadata and extras, are kept as they are.
  ///
  /// Throws [FormatException] (a [ThreepioFormatException]) for a malformed
  /// template or a missing variable, and [UnsupportedError] for
  /// [FormatType.goTemplate].
  @override
  Future<List<AgenticMessage>> format(
    RunContext ctx,
    Map<String, Object?> vars,
    FormatType type,
  ) async =>
      [_formatMessage(this, vars, type)];

  /// Go's JSON form: `role`, then `content_blocks`, `response_meta` and
  /// `extra` unless they are empty.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{'role': role.value};
    putList(json, 'content_blocks', [
      for (final block in contentBlocks) block.toJson(),
    ]);
    putObject(json, 'response_meta', responseMeta?.toJson());
    putExtra(json, 'extra', extra);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticMessage &&
          other.role == role &&
          const ListEquality<ContentBlock>()
              .equals(other.contentBlocks, contentBlocks) &&
          other.responseMeta == responseMeta &&
          deepEquals(other.extra, extra);

  @override
  int get hashCode => Object.hash(
        role,
        const ListEquality<ContentBlock>().hash(contentBlocks),
        responseMeta,
        deepHash(extra),
      );

  /// Port of eino `AgenticMessage.String`.
  @override
  String toString() {
    final sb = StringBuffer('role: ${role.value}\n');
    if (contentBlocks.isNotEmpty) {
      sb.write('content_blocks:\n');
      for (final (index, block) in contentBlocks.indexed) {
        sb.write('  [$index] $block');
      }
    }
    final meta = responseMeta;
    if (meta != null) sb.write(meta);
    return sb.toString();
  }
}

/// The metadata of a model response. Port of eino
/// `schema.AgenticResponseMeta`.
@immutable
final class AgenticResponseMeta {
  const AgenticResponseMeta({
    this.tokenUsage,
    this.openAIExtension,
    this.geminiExtension,
    this.claudeExtension,
    this.extension,
  });

  /// Reads Go's JSON form, as [toJson] writes it.
  factory AgenticResponseMeta.fromJson(Map<String, Object?> json) =>
      AgenticResponseMeta(
        tokenUsage: readObject(json, 'token_usage', _tokenUsageFromJson),
        openAIExtension: readObject(
          json,
          'openai_extension',
          OpenAIResponseMetaExtension.fromJson,
        ),
        geminiExtension: readObject(
          json,
          'gemini_extension',
          GeminiResponseMetaExtension.fromJson,
        ),
        claudeExtension: readObject(
          json,
          'claude_extension',
          ClaudeResponseMetaExtension.fromJson,
        ),
        extension: readAny(json, 'extension'),
      );

  final TokenUsage? tokenUsage;
  final OpenAIResponseMetaExtension? openAIExtension;
  final GeminiResponseMetaExtension? geminiExtension;
  final ClaudeResponseMetaExtension? claudeExtension;

  /// The extension of any other model, supplied by its implementer.
  final Object? extension;

  /// Go's JSON form. The token usage is written with Go's keys
  /// (`prompt_tokens`, `prompt_token_details.cached_tokens`, …); the fields
  /// threepio's [TokenUsage] has beyond Go's (`cost`, and the image and
  /// audio tokens of the completion details) follow under snake_case keys
  /// of their own when they are set.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    final usage = tokenUsage;
    if (usage != null) json['token_usage'] = _tokenUsageToJson(usage);
    putObject(json, 'openai_extension', openAIExtension?.toJson());
    putObject(json, 'gemini_extension', geminiExtension?.toJson());
    putObject(json, 'claude_extension', claudeExtension?.toJson());
    putAny(json, 'extension', extension);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticResponseMeta &&
          other.tokenUsage == tokenUsage &&
          other.openAIExtension == openAIExtension &&
          other.geminiExtension == geminiExtension &&
          other.claudeExtension == claudeExtension &&
          deepEquals(other.extension, extension);

  @override
  int get hashCode => Object.hash(
        tokenUsage,
        openAIExtension,
        geminiExtension,
        claudeExtension,
        deepHash(extension),
      );

  /// Port of eino `AgenticResponseMeta.String`.
  @override
  String toString() {
    final sb = StringBuffer('response_meta:\n');
    final usage = tokenUsage;
    if (usage != null) {
      sb.write(
        '  token_usage: prompt=${usage.promptTokens}, '
        'completion=${usage.completionTokens}, total=${usage.totalTokens}\n',
      );
    }
    return sb.toString();
  }
}

/// Go's `schema.TokenUsage` JSON. Go writes both detail objects always (they
/// are struct values there); a detail object whose counters are all zero is
/// read back as `null`.
Map<String, Object?> _tokenUsageToJson(TokenUsage usage) {
  final prompt = usage.promptTokenDetails;
  final completion = usage.completionTokenDetails;
  final completionJson = <String, Object?>{};
  putInt(completionJson, 'reasoning_tokens', completion?.reasoningTokens ?? 0);
  putInt(completionJson, 'image_tokens', completion?.imageTokens ?? 0);
  putInt(completionJson, 'audio_tokens', completion?.audioTokens ?? 0);
  return {
    'prompt_tokens': usage.promptTokens,
    'prompt_token_details': {
      'cached_tokens': prompt?.cachedTokens ?? 0,
      'cache_write_tokens': prompt?.cacheWriteTokens ?? 0,
    },
    'completion_tokens': usage.completionTokens,
    'total_tokens': usage.totalTokens,
    'completion_token_details': completionJson,
    if (usage.cost != null) 'cost': usage.cost,
  };
}

TokenUsage _tokenUsageFromJson(Map<String, Object?> json) {
  final prompt = readMap(json, 'prompt_token_details') ?? const {};
  final cached = readInt(prompt, 'cached_tokens');
  final cacheWrite = readInt(prompt, 'cache_write_tokens');
  final completion = readMap(json, 'completion_token_details') ?? const {};
  final reasoning = readInt(completion, 'reasoning_tokens');
  final image = readInt(completion, 'image_tokens');
  final audio = readInt(completion, 'audio_tokens');
  return TokenUsage(
    promptTokens: readInt(json, 'prompt_tokens'),
    completionTokens: readInt(json, 'completion_tokens'),
    totalTokens: readInt(json, 'total_tokens'),
    promptTokenDetails: cached == 0 && cacheWrite == 0
        ? null
        : PromptTokenDetails(
            cachedTokens: cached,
            cacheWriteTokens: cacheWrite,
          ),
    completionTokenDetails: reasoning == 0 && image == 0 && audio == 0
        ? null
        : CompletionTokenDetails(
            reasoningTokens: reasoning,
            imageTokens: image,
            audioTokens: audio,
          ),
    cost: (json['cost'] as num?)?.toDouble(),
  );
}

/// Where a streamed block goes in the final response. Port of eino
/// `schema.StreamingMeta`.
@immutable
final class StreamingMeta {
  const StreamingMeta({required this.index});

  /// Reads Go's JSON form (`{"index": 0}`).
  factory StreamingMeta.fromJson(Map<String, Object?> json) =>
      StreamingMeta(index: readInt(json, 'index'));

  /// The position of the block in the final message.
  final int index;

  /// Go's JSON form; the index is always written.
  Map<String, Object?> toJson() => {'index': index};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is StreamingMeta && other.index == index;

  @override
  int get hashCode => index.hashCode;

  @override
  String toString() => 'StreamingMeta(index: $index)';
}

/// One block of an [AgenticMessage]: its [content] and, for a streamed
/// chunk, its [streamingMeta].
///
/// Port of eino `schema.ContentBlock`. Go's struct has a `Type` and one
/// non-nil payload pointer; here [content] is the payload, a member of the
/// sealed [ContentBlockVariant] hierarchy, and [type] follows from it.
/// `ContentBlock(Reasoning(text: 'x'))` is Go's
/// `NewContentBlock(&Reasoning{Text: "x"})`, and passing [streamingMeta] is
/// `NewContentBlockChunk`.
@immutable
final class ContentBlock {
  ContentBlock(this.content, {this.streamingMeta, Map<String, Object?>? extra})
      : extra = extra == null ? null : Map.unmodifiable(extra);

  /// Reads Go's JSON form, as [toJson] writes it.
  ///
  /// A block without its payload (Go: a nil payload pointer) gets the
  /// payload with every field at its zero value. Throws
  /// [ThreepioFormatException] for an unknown block type.
  factory ContentBlock.fromJson(Map<String, Object?> json) {
    final typeValue = readString(json, 'type');
    final type = ContentBlockType.fromValue(typeValue) ??
        (throw ThreepioFormatException(
          'unknown content block type: "$typeValue"',
        ));
    final payload = readMap(json, type.payloadKey) ?? const {};
    final content = switch (type) {
      ContentBlockType.reasoning => Reasoning.fromJson(payload),
      ContentBlockType.userInputText => UserInputText.fromJson(payload),
      ContentBlockType.userInputImage => UserInputImage.fromJson(payload),
      ContentBlockType.userInputAudio => UserInputAudio.fromJson(payload),
      ContentBlockType.userInputVideo => UserInputVideo.fromJson(payload),
      ContentBlockType.userInputFile => UserInputFile.fromJson(payload),
      ContentBlockType.toolSearchResult =>
        ToolSearchFunctionToolResult.fromJson(payload),
      ContentBlockType.assistantGenText => AssistantGenText.fromJson(payload),
      ContentBlockType.assistantGenImage =>
        AssistantGenImage.fromJson(payload),
      ContentBlockType.assistantGenAudio =>
        AssistantGenAudio.fromJson(payload),
      ContentBlockType.assistantGenVideo =>
        AssistantGenVideo.fromJson(payload),
      ContentBlockType.functionToolCall => FunctionToolCall.fromJson(payload),
      ContentBlockType.functionToolResult =>
        FunctionToolResult.fromJson(payload),
      ContentBlockType.serverToolCall => ServerToolCall.fromJson(payload),
      ContentBlockType.serverToolResult => ServerToolResult.fromJson(payload),
      ContentBlockType.mcpToolCall => AgenticMcpToolCall.fromJson(payload),
      ContentBlockType.mcpToolResult => AgenticMcpToolResult.fromJson(payload),
      ContentBlockType.mcpListToolsResult =>
        AgenticMcpListToolsResult.fromJson(payload),
      ContentBlockType.mcpToolApprovalRequest =>
        AgenticMcpToolApprovalRequest.fromJson(payload),
      ContentBlockType.mcpToolApprovalResponse =>
        AgenticMcpToolApprovalResponse.fromJson(payload),
    };
    return ContentBlock(
      content,
      streamingMeta: readObject(json, 'streaming_meta', StreamingMeta.fromJson),
      extra: readExtra(json, 'extra'),
    );
  }

  /// The payload.
  final ContentBlockVariant content;

  /// Set on streamed chunks only.
  final StreamingMeta? streamingMeta;

  /// Additional information. Port of the field `Extra`.
  final Map<String, Object?>? extra;

  /// The kind of block, from [content].
  ContentBlockType get type => content.blockType;

  Reasoning? get reasoning => switch (content) {
        final Reasoning c => c,
        _ => null,
      };
  UserInputText? get userInputText => switch (content) {
        final UserInputText c => c,
        _ => null,
      };
  UserInputImage? get userInputImage => switch (content) {
        final UserInputImage c => c,
        _ => null,
      };
  UserInputAudio? get userInputAudio => switch (content) {
        final UserInputAudio c => c,
        _ => null,
      };
  UserInputVideo? get userInputVideo => switch (content) {
        final UserInputVideo c => c,
        _ => null,
      };
  UserInputFile? get userInputFile => switch (content) {
        final UserInputFile c => c,
        _ => null,
      };
  AssistantGenText? get assistantGenText => switch (content) {
        final AssistantGenText c => c,
        _ => null,
      };
  AssistantGenImage? get assistantGenImage => switch (content) {
        final AssistantGenImage c => c,
        _ => null,
      };
  AssistantGenAudio? get assistantGenAudio => switch (content) {
        final AssistantGenAudio c => c,
        _ => null,
      };
  AssistantGenVideo? get assistantGenVideo => switch (content) {
        final AssistantGenVideo c => c,
        _ => null,
      };
  FunctionToolCall? get functionToolCall => switch (content) {
        final FunctionToolCall c => c,
        _ => null,
      };
  FunctionToolResult? get functionToolResult => switch (content) {
        final FunctionToolResult c => c,
        _ => null,
      };
  ToolSearchFunctionToolResult? get toolSearchFunctionToolResult =>
      switch (content) {
        final ToolSearchFunctionToolResult c => c,
        _ => null,
      };
  ServerToolCall? get serverToolCall => switch (content) {
        final ServerToolCall c => c,
        _ => null,
      };
  ServerToolResult? get serverToolResult => switch (content) {
        final ServerToolResult c => c,
        _ => null,
      };
  AgenticMcpToolCall? get mcpToolCall => switch (content) {
        final AgenticMcpToolCall c => c,
        _ => null,
      };
  AgenticMcpToolResult? get mcpToolResult => switch (content) {
        final AgenticMcpToolResult c => c,
        _ => null,
      };
  AgenticMcpListToolsResult? get mcpListToolsResult => switch (content) {
        final AgenticMcpListToolsResult c => c,
        _ => null,
      };
  AgenticMcpToolApprovalRequest? get mcpToolApprovalRequest =>
      switch (content) {
        final AgenticMcpToolApprovalRequest c => c,
        _ => null,
      };
  AgenticMcpToolApprovalResponse? get mcpToolApprovalResponse =>
      switch (content) {
        final AgenticMcpToolApprovalResponse c => c,
        _ => null,
      };

  /// A copy with the given fields replaced. Pass [clearStreamingMeta] or
  /// [clearExtra] to remove those fields.
  ContentBlock copyWith({
    ContentBlockVariant? content,
    StreamingMeta? streamingMeta,
    Map<String, Object?>? extra,
    bool clearStreamingMeta = false,
    bool clearExtra = false,
  }) =>
      ContentBlock(
        content ?? this.content,
        streamingMeta:
            clearStreamingMeta ? null : streamingMeta ?? this.streamingMeta,
        extra: clearExtra ? null : extra ?? this.extra,
      );

  /// Go's JSON form: `type`, the payload under [ContentBlockType.payloadKey],
  /// then `streaming_meta` and `extra` when they are set.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'type': type.value,
      type.payloadKey: content.toJson(),
    };
    putObject(json, 'streaming_meta', streamingMeta?.toJson());
    putExtra(json, 'extra', extra);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContentBlock &&
          other.content == content &&
          other.streamingMeta == streamingMeta &&
          deepEquals(other.extra, extra);

  @override
  int get hashCode => Object.hash(content, streamingMeta, deepHash(extra));

  /// Port of eino `ContentBlock.String`: the type, the payload's lines, and
  /// the streaming index when there is one.
  @override
  String toString() {
    final sb = StringBuffer('type: ${type.value}\n')..write(content);
    final meta = streamingMeta;
    if (meta != null) sb.write('      stream_index: ${meta.index}\n');
    return sb.toString();
  }
}

/// The payload of a [ContentBlock].
///
/// Port of eino's `contentBlockVariant` type constraint, as a sealed class:
/// a `switch` over it is exhaustive. Every variant has Go's JSON form
/// ([toJson] and a `fromJson` factory) and Go's `String()` as `toString()`.
@immutable
sealed class ContentBlockVariant {
  const ContentBlockVariant();

  /// The [ContentBlockType] of a block with this payload.
  ContentBlockType get blockType;

  /// Go's JSON form of the payload.
  Map<String, Object?> toJson();
}

/// The input kinds a user sends (text, image, audio, video, file); also the
/// content of a [FunctionToolResultContentBlock]. Port of eino's
/// `userInputVariant` constraint.
sealed class UserInputVariant extends ContentBlockVariant {
  const UserInputVariant();
}

/// Reasoning the model produced. Port of eino `schema.Reasoning`.
final class Reasoning extends ContentBlockVariant {
  const Reasoning({this.text = '', this.signature = '', this.openAIExtension});

  /// Reads Go's JSON form.
  factory Reasoning.fromJson(Map<String, Object?> json) => Reasoning(
        text: readString(json, 'text'),
        signature: readString(json, 'signature'),
        openAIExtension: readObject(
          json,
          'openai_extension',
          OpenAIReasoningExtension.fromJson,
        ),
      );

  /// The thought summary or the raw reasoning text.
  final String text;

  /// Encrypted reasoning tokens some models need back.
  final String signature;
  final OpenAIReasoningExtension? openAIExtension;

  @override
  ContentBlockType get blockType => ContentBlockType.reasoning;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'text', text);
    putString(json, 'signature', signature);
    putObject(json, 'openai_extension', openAIExtension?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Reasoning &&
          other.text == text &&
          other.signature == signature &&
          other.openAIExtension == openAIExtension;

  @override
  int get hashCode => Object.hash(text, signature, openAIExtension);

  /// Port of eino `Reasoning.String`.
  @override
  String toString() {
    final sb = StringBuffer('      text: $text\n');
    if (signature.isNotEmpty) {
      sb.write('      signature: ${truncateString(signature, 50)}\n');
    }
    return sb.toString();
  }
}

/// Text from the user (or a system prompt). Port of eino
/// `schema.UserInputText`.
final class UserInputText extends UserInputVariant {
  const UserInputText({this.text = ''});

  /// Reads Go's JSON form.
  factory UserInputText.fromJson(Map<String, Object?> json) =>
      UserInputText(text: readString(json, 'text'));

  final String text;

  @override
  ContentBlockType get blockType => ContentBlockType.userInputText;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'text', text);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is UserInputText && other.text == text;

  @override
  int get hashCode => text.hashCode;

  /// Port of eino `UserInputText.String`.
  @override
  String toString() => '      text: $text\n';
}

/// An image from the user: one of [url], [base64Data] or [fileId]. Port of
/// eino `schema.UserInputImage`.
final class UserInputImage extends UserInputVariant {
  const UserInputImage({
    this.url = '',
    this.base64Data = '',
    this.fileId = '',
    this.mimeType = '',
    this.detail,
  });

  /// Reads Go's JSON form; an unknown `detail` reads as `null`.
  factory UserInputImage.fromJson(Map<String, Object?> json) {
    final detail = readString(json, 'detail');
    return UserInputImage(
      url: readString(json, 'url'),
      base64Data: readString(json, 'base64_data'),
      fileId: readString(json, 'file_id'),
      mimeType: readString(json, 'mime_type'),
      detail: ImageURLDetail.values.firstWhereOrNull((d) => d.name == detail),
    );
  }

  final String url;
  final String base64Data;

  /// An opaque file id or URI issued by the model provider.
  final String fileId;
  final String mimeType;
  final ImageURLDetail? detail;

  @override
  ContentBlockType get blockType => ContentBlockType.userInputImage;

  /// A copy with the given fields replaced. Pass [clearDetail] to remove
  /// [detail].
  UserInputImage copyWith({
    String? url,
    String? base64Data,
    String? fileId,
    String? mimeType,
    ImageURLDetail? detail,
    bool clearDetail = false,
  }) =>
      UserInputImage(
        url: url ?? this.url,
        base64Data: base64Data ?? this.base64Data,
        fileId: fileId ?? this.fileId,
        mimeType: mimeType ?? this.mimeType,
        detail: clearDetail ? null : detail ?? this.detail,
      );

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'url', url);
    putString(json, 'base64_data', base64Data);
    putString(json, 'file_id', fileId);
    putString(json, 'mime_type', mimeType);
    putString(json, 'detail', detail?.name ?? '');
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserInputImage &&
          other.url == url &&
          other.base64Data == base64Data &&
          other.fileId == fileId &&
          other.mimeType == mimeType &&
          other.detail == detail;

  @override
  int get hashCode => Object.hash(url, base64Data, fileId, mimeType, detail);

  /// Port of eino `UserInputImage.String`.
  @override
  String toString() =>
      formatMediaString(url, base64Data, fileId, mimeType, detail?.name ?? '');
}

/// Audio from the user. Port of eino `schema.UserInputAudio`.
final class UserInputAudio extends UserInputVariant {
  const UserInputAudio({
    this.url = '',
    this.base64Data = '',
    this.fileId = '',
    this.mimeType = '',
  });

  /// Reads Go's JSON form.
  factory UserInputAudio.fromJson(Map<String, Object?> json) => UserInputAudio(
        url: readString(json, 'url'),
        base64Data: readString(json, 'base64_data'),
        fileId: readString(json, 'file_id'),
        mimeType: readString(json, 'mime_type'),
      );

  final String url;
  final String base64Data;
  final String fileId;
  final String mimeType;

  @override
  ContentBlockType get blockType => ContentBlockType.userInputAudio;

  /// A copy with the given fields replaced.
  UserInputAudio copyWith({
    String? url,
    String? base64Data,
    String? fileId,
    String? mimeType,
  }) =>
      UserInputAudio(
        url: url ?? this.url,
        base64Data: base64Data ?? this.base64Data,
        fileId: fileId ?? this.fileId,
        mimeType: mimeType ?? this.mimeType,
      );

  @override
  Map<String, Object?> toJson() =>
      _mediaJson(url, base64Data, fileId, mimeType);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserInputAudio &&
          other.url == url &&
          other.base64Data == base64Data &&
          other.fileId == fileId &&
          other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(url, base64Data, fileId, mimeType);

  /// Port of eino `UserInputAudio.String`.
  @override
  String toString() => formatMediaString(url, base64Data, fileId, mimeType, '');
}

/// Video from the user. Port of eino `schema.UserInputVideo`.
final class UserInputVideo extends UserInputVariant {
  const UserInputVideo({
    this.url = '',
    this.base64Data = '',
    this.fileId = '',
    this.mimeType = '',
  });

  /// Reads Go's JSON form.
  factory UserInputVideo.fromJson(Map<String, Object?> json) => UserInputVideo(
        url: readString(json, 'url'),
        base64Data: readString(json, 'base64_data'),
        fileId: readString(json, 'file_id'),
        mimeType: readString(json, 'mime_type'),
      );

  final String url;
  final String base64Data;
  final String fileId;
  final String mimeType;

  @override
  ContentBlockType get blockType => ContentBlockType.userInputVideo;

  /// A copy with the given fields replaced.
  UserInputVideo copyWith({
    String? url,
    String? base64Data,
    String? fileId,
    String? mimeType,
  }) =>
      UserInputVideo(
        url: url ?? this.url,
        base64Data: base64Data ?? this.base64Data,
        fileId: fileId ?? this.fileId,
        mimeType: mimeType ?? this.mimeType,
      );

  @override
  Map<String, Object?> toJson() =>
      _mediaJson(url, base64Data, fileId, mimeType);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserInputVideo &&
          other.url == url &&
          other.base64Data == base64Data &&
          other.fileId == fileId &&
          other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(url, base64Data, fileId, mimeType);

  /// Port of eino `UserInputVideo.String`.
  @override
  String toString() => formatMediaString(url, base64Data, fileId, mimeType, '');
}

/// A file from the user. Port of eino `schema.UserInputFile`.
final class UserInputFile extends UserInputVariant {
  const UserInputFile({
    this.url = '',
    this.name = '',
    this.base64Data = '',
    this.fileId = '',
    this.mimeType = '',
  });

  /// Reads Go's JSON form.
  factory UserInputFile.fromJson(Map<String, Object?> json) => UserInputFile(
        url: readString(json, 'url'),
        name: readString(json, 'name'),
        base64Data: readString(json, 'base64_data'),
        fileId: readString(json, 'file_id'),
        mimeType: readString(json, 'mime_type'),
      );

  final String url;
  final String name;
  final String base64Data;
  final String fileId;
  final String mimeType;

  @override
  ContentBlockType get blockType => ContentBlockType.userInputFile;

  /// A copy with the given fields replaced.
  UserInputFile copyWith({
    String? url,
    String? name,
    String? base64Data,
    String? fileId,
    String? mimeType,
  }) =>
      UserInputFile(
        url: url ?? this.url,
        name: name ?? this.name,
        base64Data: base64Data ?? this.base64Data,
        fileId: fileId ?? this.fileId,
        mimeType: mimeType ?? this.mimeType,
      );

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'url', url);
    putString(json, 'name', name);
    putString(json, 'base64_data', base64Data);
    putString(json, 'file_id', fileId);
    putString(json, 'mime_type', mimeType);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserInputFile &&
          other.url == url &&
          other.name == name &&
          other.base64Data == base64Data &&
          other.fileId == fileId &&
          other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(url, name, base64Data, fileId, mimeType);

  /// Port of eino `UserInputFile.String`.
  @override
  String toString() {
    final sb = StringBuffer();
    if (name.isNotEmpty) sb.write('      name: $name\n');
    sb.write(formatMediaString(url, base64Data, fileId, mimeType, ''));
    return sb.toString();
  }
}

/// The JSON of a media payload with url, base64 data, file id and MIME type.
Map<String, Object?> _mediaJson(
  String url,
  String base64Data,
  String fileId,
  String mimeType,
) {
  final json = <String, Object?>{};
  putString(json, 'url', url);
  putString(json, 'base64_data', base64Data);
  putString(json, 'file_id', fileId);
  putString(json, 'mime_type', mimeType);
  return json;
}

/// Text the model generated. Port of eino `schema.AssistantGenText`.
final class AssistantGenText extends ContentBlockVariant {
  const AssistantGenText({
    this.text = '',
    this.openAIExtension,
    this.claudeExtension,
    this.extension,
  });

  /// Reads Go's JSON form; `extension` through `TypeRegistry.decode`.
  factory AssistantGenText.fromJson(Map<String, Object?> json) =>
      AssistantGenText(
        text: readString(json, 'text'),
        openAIExtension: readObject(
          json,
          'openai_extension',
          OpenAIAssistantGenTextExtension.fromJson,
        ),
        claudeExtension: readObject(
          json,
          'claude_extension',
          ClaudeAssistantGenTextExtension.fromJson,
        ),
        extension: readAny(json, 'extension'),
      );

  final String text;
  final OpenAIAssistantGenTextExtension? openAIExtension;
  final ClaudeAssistantGenTextExtension? claudeExtension;

  /// The extension of any other model, supplied by its implementer.
  final Object? extension;

  @override
  ContentBlockType get blockType => ContentBlockType.assistantGenText;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'text', text);
    putObject(json, 'openai_extension', openAIExtension?.toJson());
    putObject(json, 'claude_extension', claudeExtension?.toJson());
    putAny(json, 'extension', extension);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssistantGenText &&
          other.text == text &&
          other.openAIExtension == openAIExtension &&
          other.claudeExtension == claudeExtension &&
          deepEquals(other.extension, extension);

  @override
  int get hashCode =>
      Object.hash(text, openAIExtension, claudeExtension, deepHash(extension));

  /// Port of eino `AssistantGenText.String`.
  @override
  String toString() => '      text: $text\n';
}

/// An image the model generated. Port of eino `schema.AssistantGenImage`.
final class AssistantGenImage extends ContentBlockVariant {
  const AssistantGenImage({
    this.url = '',
    this.base64Data = '',
    this.mimeType = '',
  });

  /// Reads Go's JSON form.
  factory AssistantGenImage.fromJson(Map<String, Object?> json) =>
      AssistantGenImage(
        url: readString(json, 'url'),
        base64Data: readString(json, 'base64_data'),
        mimeType: readString(json, 'mime_type'),
      );

  final String url;
  final String base64Data;
  final String mimeType;

  @override
  ContentBlockType get blockType => ContentBlockType.assistantGenImage;

  @override
  Map<String, Object?> toJson() => _mediaJson(url, base64Data, '', mimeType);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssistantGenImage &&
          other.url == url &&
          other.base64Data == base64Data &&
          other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(url, base64Data, mimeType);

  /// Port of eino `AssistantGenImage.String`.
  @override
  String toString() => formatMediaString(url, base64Data, '', mimeType, '');
}

/// Audio the model generated. Port of eino `schema.AssistantGenAudio`.
final class AssistantGenAudio extends ContentBlockVariant {
  const AssistantGenAudio({
    this.url = '',
    this.base64Data = '',
    this.mimeType = '',
  });

  /// Reads Go's JSON form.
  factory AssistantGenAudio.fromJson(Map<String, Object?> json) =>
      AssistantGenAudio(
        url: readString(json, 'url'),
        base64Data: readString(json, 'base64_data'),
        mimeType: readString(json, 'mime_type'),
      );

  final String url;
  final String base64Data;
  final String mimeType;

  @override
  ContentBlockType get blockType => ContentBlockType.assistantGenAudio;

  @override
  Map<String, Object?> toJson() => _mediaJson(url, base64Data, '', mimeType);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssistantGenAudio &&
          other.url == url &&
          other.base64Data == base64Data &&
          other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(url, base64Data, mimeType);

  /// Port of eino `AssistantGenAudio.String`.
  @override
  String toString() => formatMediaString(url, base64Data, '', mimeType, '');
}

/// Video the model generated. Port of eino `schema.AssistantGenVideo`.
final class AssistantGenVideo extends ContentBlockVariant {
  const AssistantGenVideo({
    this.url = '',
    this.base64Data = '',
    this.mimeType = '',
  });

  /// Reads Go's JSON form.
  factory AssistantGenVideo.fromJson(Map<String, Object?> json) =>
      AssistantGenVideo(
        url: readString(json, 'url'),
        base64Data: readString(json, 'base64_data'),
        mimeType: readString(json, 'mime_type'),
      );

  final String url;
  final String base64Data;
  final String mimeType;

  @override
  ContentBlockType get blockType => ContentBlockType.assistantGenVideo;

  @override
  Map<String, Object?> toJson() => _mediaJson(url, base64Data, '', mimeType);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssistantGenVideo &&
          other.url == url &&
          other.base64Data == base64Data &&
          other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(url, base64Data, mimeType);

  /// Port of eino `AssistantGenVideo.String`.
  @override
  String toString() => formatMediaString(url, base64Data, '', mimeType, '');
}

/// A call of a user-defined (function) tool. Port of eino
/// `schema.FunctionToolCall`. A streamed chunk may carry only part of
/// [arguments], with [callId] and [name] empty.
final class FunctionToolCall extends ContentBlockVariant {
  const FunctionToolCall({
    this.callId = '',
    this.name = '',
    this.arguments = '',
  });

  /// Reads Go's JSON form.
  factory FunctionToolCall.fromJson(Map<String, Object?> json) =>
      FunctionToolCall(
        callId: readString(json, 'call_id'),
        name: readString(json, 'name'),
        arguments: readString(json, 'arguments'),
      );

  final String callId;
  final String name;

  /// The arguments as a JSON string.
  final String arguments;

  @override
  ContentBlockType get blockType => ContentBlockType.functionToolCall;

  /// Go's JSON form; `name` is always written.
  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'call_id', callId);
    json['name'] = name;
    putString(json, 'arguments', arguments);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FunctionToolCall &&
          other.callId == callId &&
          other.name == name &&
          other.arguments == arguments;

  @override
  int get hashCode => Object.hash(callId, name, arguments);

  /// Port of eino `FunctionToolCall.String`.
  @override
  String toString() => '      call_id: $callId\n'
      '      name: $name\n'
      '      arguments: $arguments\n';
}

/// The kind of a [FunctionToolResultContentBlock]. Port of eino
/// `schema.FunctionToolResultContentBlockType`.
enum FunctionToolResultContentBlockType {
  text('text'),
  image('image'),
  audio('audio'),
  video('video'),
  file('file');

  const FunctionToolResultContentBlockType(this.value);

  /// The wire value.
  final String value;

  /// The type whose wire value is [value], or `null` for an unknown one.
  static FunctionToolResultContentBlockType? fromValue(String value) =>
      values.firstWhereOrNull((type) => type.value == value);
}

/// One part of a [FunctionToolResult]: text or media.
///
/// Port of eino `schema.FunctionToolResultContentBlock`. Go's `Type` plus
/// one of `Text`/`Image`/`Audio`/`Video`/`File` becomes [content]; [type]
/// follows from it.
@immutable
final class FunctionToolResultContentBlock {
  FunctionToolResultContentBlock(this.content, {Map<String, Object?>? extra})
      : extra = extra == null ? null : Map.unmodifiable(extra);

  /// Reads Go's JSON form (`{"type": "text", "text": {...}}`).
  ///
  /// A block without its payload gets one with every field at its zero
  /// value. Throws [ThreepioFormatException] for an unknown type.
  factory FunctionToolResultContentBlock.fromJson(Map<String, Object?> json) {
    final typeValue = readString(json, 'type');
    final type = FunctionToolResultContentBlockType.fromValue(typeValue) ??
        (throw ThreepioFormatException(
          typeValue.isEmpty
              ? 'unknown block type: <empty>'
              : 'unknown block type: $typeValue',
        ));
    final payload = readMap(json, type.value) ?? const {};
    final content = switch (type) {
      FunctionToolResultContentBlockType.text => UserInputText.fromJson(payload),
      FunctionToolResultContentBlockType.image =>
        UserInputImage.fromJson(payload),
      FunctionToolResultContentBlockType.audio =>
        UserInputAudio.fromJson(payload),
      FunctionToolResultContentBlockType.video =>
        UserInputVideo.fromJson(payload),
      FunctionToolResultContentBlockType.file =>
        UserInputFile.fromJson(payload),
    };
    return FunctionToolResultContentBlock(
      content,
      extra: readExtra(json, 'extra'),
    );
  }

  final UserInputVariant content;
  final Map<String, Object?>? extra;

  FunctionToolResultContentBlockType get type => switch (content) {
        UserInputText() => FunctionToolResultContentBlockType.text,
        UserInputImage() => FunctionToolResultContentBlockType.image,
        UserInputAudio() => FunctionToolResultContentBlockType.audio,
        UserInputVideo() => FunctionToolResultContentBlockType.video,
        UserInputFile() => FunctionToolResultContentBlockType.file,
      };

  /// Go's JSON form: `type`, the payload under the type's value, and
  /// `extra` when it is set.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'type': type.value,
      type.value: content.toJson(),
    };
    putExtra(json, 'extra', extra);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FunctionToolResultContentBlock &&
          other.content == content &&
          deepEquals(other.extra, extra);

  @override
  int get hashCode => Object.hash(content, deepHash(extra));

  /// Port of eino `FunctionToolResultContentBlock.String`: the payload's
  /// lines. (Go's texts for an empty or unknown type and a missing payload
  /// cannot occur here.)
  @override
  String toString() => content.toString();
}

/// The result of a function tool call. Port of eino
/// `schema.FunctionToolResult`.
final class FunctionToolResult extends ContentBlockVariant {
  FunctionToolResult({
    this.callId = '',
    this.name = '',
    List<FunctionToolResultContentBlock> content = const [],
  }) : content = List.unmodifiable(content);

  /// Reads Go's JSON form.
  factory FunctionToolResult.fromJson(Map<String, Object?> json) =>
      FunctionToolResult(
        callId: readString(json, 'call_id'),
        name: readString(json, 'name'),
        content: readObjects(
          json,
          'content',
          FunctionToolResultContentBlock.fromJson,
        ),
      );

  final String callId;
  final String name;

  /// The output, as ordered text and media parts.
  final List<FunctionToolResultContentBlock> content;

  @override
  ContentBlockType get blockType => ContentBlockType.functionToolResult;

  /// Go's JSON form; `name` is always written.
  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'call_id', callId);
    json['name'] = name;
    putList(json, 'content', [for (final block in content) block.toJson()]);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FunctionToolResult &&
          other.callId == callId &&
          other.name == name &&
          const ListEquality<FunctionToolResultContentBlock>()
              .equals(other.content, content);

  @override
  int get hashCode => Object.hash(
        callId,
        name,
        const ListEquality<FunctionToolResultContentBlock>().hash(content),
      );

  /// Port of eino `FunctionToolResult.String`.
  @override
  String toString() {
    final sb = StringBuffer('      call_id: $callId\n      name: $name\n');
    if (content.isNotEmpty) {
      sb.write('      content: (${content.length} blocks)\n');
      for (final (index, block) in content.indexed) {
        sb.write('        [$index] $block');
      }
    }
    return sb.toString();
  }
}

/// The result of a client-side tool search tool call: the definitions of
/// the tools it found. Port of eino `schema.ToolSearchFunctionToolResult`.
///
/// [result] is written in threepio's JSON form of [ToolSearchResult]
/// (`{"tools": [...]}` with threepio's [ToolInfo] JSON): Go's `ToolInfo` has
/// no JSON form that survives a round trip.
final class ToolSearchFunctionToolResult extends ContentBlockVariant {
  const ToolSearchFunctionToolResult({
    this.callId = '',
    this.name = '',
    this.result,
  });

  /// Reads the JSON [toJson] writes.
  factory ToolSearchFunctionToolResult.fromJson(Map<String, Object?> json) =>
      ToolSearchFunctionToolResult(
        callId: readString(json, 'call_id'),
        name: readString(json, 'name'),
        result: readObject(json, 'result', ToolSearchResult.fromJson),
      );

  final String callId;
  final String name;
  final ToolSearchResult? result;

  @override
  ContentBlockType get blockType => ContentBlockType.toolSearchResult;

  /// Go's JSON form; `name` is always written.
  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'call_id', callId);
    json['name'] = name;
    putObject(json, 'result', result?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolSearchFunctionToolResult &&
          other.callId == callId &&
          other.name == name &&
          other.result == result;

  @override
  int get hashCode => Object.hash(callId, name, result);

  /// Port of eino `ToolSearchFunctionToolResult.String`: Go's
  /// `ToolSearchResult.String` (`ToolSearchResult[a,b,]`, no line break), or
  /// nothing without a result.
  @override
  String toString() {
    final found = result;
    if (found == null) return '';
    final sb = StringBuffer('ToolSearchResult[');
    for (final tool in found.tools) {
      sb
        ..write(tool.name)
        ..write(',');
    }
    sb.write(']');
    return sb.toString();
  }
}

/// A call of a tool built into the model provider (web search, code
/// execution, …). Port of eino `schema.ServerToolCall`.
final class ServerToolCall extends ContentBlockVariant {
  const ServerToolCall({this.name = '', this.callId = '', this.arguments});

  /// Reads Go's JSON form; `arguments` through `TypeRegistry.decode`.
  factory ServerToolCall.fromJson(Map<String, Object?> json) => ServerToolCall(
        name: readString(json, 'name'),
        callId: readString(json, 'call_id'),
        arguments: readAny(json, 'arguments'),
      );

  /// The provider's name for the tool (`web_search`, `googleSearch`, …).
  final String name;
  final String callId;

  /// The raw input, in the provider implementation's own type.
  final Object? arguments;

  @override
  ContentBlockType get blockType => ContentBlockType.serverToolCall;

  /// Go's JSON form; `name` is always written, `arguments` through
  /// `TypeRegistry.encode`.
  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{'name': name};
    putString(json, 'call_id', callId);
    putAny(json, 'arguments', arguments);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerToolCall &&
          other.name == name &&
          other.callId == callId &&
          deepEquals(other.arguments, arguments);

  @override
  int get hashCode => Object.hash(name, callId, deepHash(arguments));

  /// Port of eino `ServerToolCall.String`.
  @override
  String toString() {
    final sb = StringBuffer('      name: $name\n');
    if (callId.isNotEmpty) sb.write('      call_id: $callId\n');
    sb.write('      arguments: ${printAny(arguments)}\n');
    return sb.toString();
  }
}

/// The result of a server tool call. Port of eino `schema.ServerToolResult`.
final class ServerToolResult extends ContentBlockVariant {
  const ServerToolResult({this.name = '', this.callId = '', this.content});

  /// Reads Go's JSON form; `content` through `TypeRegistry.decode`.
  factory ServerToolResult.fromJson(Map<String, Object?> json) =>
      ServerToolResult(
        name: readString(json, 'name'),
        callId: readString(json, 'call_id'),
        content: readAny(json, 'content'),
      );

  final String name;
  final String callId;

  /// The raw output, in the provider implementation's own type.
  final Object? content;

  @override
  ContentBlockType get blockType => ContentBlockType.serverToolResult;

  /// Go's JSON form; `name` is always written, `content` through
  /// `TypeRegistry.encode`.
  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{'name': name};
    putString(json, 'call_id', callId);
    putAny(json, 'content', content);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServerToolResult &&
          other.name == name &&
          other.callId == callId &&
          deepEquals(other.content, content);

  @override
  int get hashCode => Object.hash(name, callId, deepHash(content));

  /// Port of eino `ServerToolResult.String`.
  @override
  String toString() {
    final sb = StringBuffer('      name: $name\n');
    if (callId.isNotEmpty) sb.write('      call_id: $callId\n');
    sb.write('      content: ${printAny(content)}\n');
    return sb.toString();
  }
}

/// A call of an MCP tool the model provider runs on a remote MCP server.
///
/// Port of eino `schema.MCPToolCall`. Named `AgenticMcp…` because the
/// `Mcp…` names belong to threepio's MCP client (`McpListToolsResult`).
final class AgenticMcpToolCall extends ContentBlockVariant {
  const AgenticMcpToolCall({
    this.serverLabel = '',
    this.approvalRequestId = '',
    this.callId = '',
    this.name = '',
    this.arguments = '',
  });

  /// Reads Go's JSON form.
  factory AgenticMcpToolCall.fromJson(Map<String, Object?> json) =>
      AgenticMcpToolCall(
        serverLabel: readString(json, 'server_label'),
        approvalRequestId: readString(json, 'approval_request_id'),
        callId: readString(json, 'call_id'),
        name: readString(json, 'name'),
        arguments: readString(json, 'arguments'),
      );

  final String serverLabel;
  final String approvalRequestId;
  final String callId;
  final String name;

  /// The arguments as a JSON string.
  final String arguments;

  @override
  ContentBlockType get blockType => ContentBlockType.mcpToolCall;

  /// Go's JSON form; `name` is always written.
  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'server_label', serverLabel);
    putString(json, 'approval_request_id', approvalRequestId);
    putString(json, 'call_id', callId);
    json['name'] = name;
    putString(json, 'arguments', arguments);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticMcpToolCall &&
          other.serverLabel == serverLabel &&
          other.approvalRequestId == approvalRequestId &&
          other.callId == callId &&
          other.name == name &&
          other.arguments == arguments;

  @override
  int get hashCode =>
      Object.hash(serverLabel, approvalRequestId, callId, name, arguments);

  /// Port of eino `MCPToolCall.String`.
  @override
  String toString() => '      server_label: $serverLabel\n'
      '      call_id: $callId\n'
      '      name: $name\n'
      '      arguments: $arguments\n';
}

/// The result of an [AgenticMcpToolCall]. Port of eino
/// `schema.MCPToolResult`.
final class AgenticMcpToolResult extends ContentBlockVariant {
  const AgenticMcpToolResult({
    this.serverLabel = '',
    this.callId = '',
    this.name = '',
    this.content = '',
    this.error,
  });

  /// Reads Go's JSON form.
  factory AgenticMcpToolResult.fromJson(Map<String, Object?> json) =>
      AgenticMcpToolResult(
        serverLabel: readString(json, 'server_label'),
        callId: readString(json, 'call_id'),
        name: readString(json, 'name'),
        content: readString(json, 'content'),
        error: readObject(json, 'error', AgenticMcpToolCallError.fromJson),
      );

  final String serverLabel;
  final String callId;
  final String name;

  /// The result as a JSON string.
  final String content;
  final AgenticMcpToolCallError? error;

  @override
  ContentBlockType get blockType => ContentBlockType.mcpToolResult;

  /// Go's JSON form; `name` is always written.
  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'server_label', serverLabel);
    putString(json, 'call_id', callId);
    json['name'] = name;
    putString(json, 'content', content);
    putObject(json, 'error', error?.toJson());
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticMcpToolResult &&
          other.serverLabel == serverLabel &&
          other.callId == callId &&
          other.name == name &&
          other.content == content &&
          other.error == error;

  @override
  int get hashCode => Object.hash(serverLabel, callId, name, content, error);

  /// Port of eino `MCPToolResult.String`.
  @override
  String toString() {
    final sb = StringBuffer(
      '      call_id: $callId\n      name: $name\n      content: $content\n',
    );
    final failure = error;
    if (failure != null) {
      final code = failure.code;
      sb.write(
        code != null
            ? '      error: [$code] ${failure.message}\n'
            : '      error: ${failure.message}\n',
      );
    }
    return sb.toString();
  }
}

/// Why an MCP server failed to run a tool. Port of eino
/// `schema.MCPToolCallError`.
@immutable
final class AgenticMcpToolCallError {
  const AgenticMcpToolCallError({this.code, this.message = ''});

  /// Reads Go's JSON form.
  factory AgenticMcpToolCallError.fromJson(Map<String, Object?> json) =>
      AgenticMcpToolCallError(
        code: readIntOrNull(json, 'code'),
        message: readString(json, 'message'),
      );

  final int? code;
  final String message;

  /// Go's JSON form.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putObject(json, 'code', code);
    putString(json, 'message', message);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticMcpToolCallError &&
          other.code == code &&
          other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'AgenticMcpToolCallError${toJson()}';
}

/// The tools a remote MCP server offers, as the model provider reports
/// them. Port of eino `schema.MCPListToolsResult`.
final class AgenticMcpListToolsResult extends ContentBlockVariant {
  AgenticMcpListToolsResult({
    this.serverLabel = '',
    List<AgenticMcpListToolsItem> tools = const [],
    this.error = '',
  }) : tools = List.unmodifiable(tools);

  /// Reads Go's JSON form.
  factory AgenticMcpListToolsResult.fromJson(Map<String, Object?> json) =>
      AgenticMcpListToolsResult(
        serverLabel: readString(json, 'server_label'),
        tools: readObjects(json, 'tools', AgenticMcpListToolsItem.fromJson),
        error: readString(json, 'error'),
      );

  final String serverLabel;
  final List<AgenticMcpListToolsItem> tools;
  final String error;

  @override
  ContentBlockType get blockType => ContentBlockType.mcpListToolsResult;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'server_label', serverLabel);
    putList(json, 'tools', [for (final tool in tools) tool.toJson()]);
    putString(json, 'error', error);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticMcpListToolsResult &&
          other.serverLabel == serverLabel &&
          const ListEquality<AgenticMcpListToolsItem>()
              .equals(other.tools, tools) &&
          other.error == error;

  @override
  int get hashCode => Object.hash(
        serverLabel,
        const ListEquality<AgenticMcpListToolsItem>().hash(tools),
        error,
      );

  /// Port of eino `MCPListToolsResult.String`.
  @override
  String toString() {
    final sb = StringBuffer(
      '      server_label: $serverLabel\n'
      '      tools: ${tools.length} items\n',
    );
    for (final tool in tools) {
      sb.write('        - ${tool.name}: ${tool.description}\n');
    }
    if (error.isNotEmpty) sb.write('      error: $error\n');
    return sb.toString();
  }
}

/// One tool of an [AgenticMcpListToolsResult]. Port of eino
/// `schema.MCPListToolsItem`; the input schema is the raw JSON Schema
/// document (Go: `*jsonschema.Schema`), written as it is.
@immutable
final class AgenticMcpListToolsItem {
  AgenticMcpListToolsItem({
    this.name = '',
    this.description = '',
    Map<String, Object?>? inputSchema,
  }) : inputSchema = inputSchema == null ? null : Map.unmodifiable(inputSchema);

  /// Reads Go's JSON form.
  factory AgenticMcpListToolsItem.fromJson(Map<String, Object?> json) =>
      AgenticMcpListToolsItem(
        name: readString(json, 'name'),
        description: readString(json, 'description'),
        inputSchema: readMap(json, 'input_schema'),
      );

  final String name;
  final String description;
  final Map<String, Object?>? inputSchema;

  /// Go's JSON form; `name` and `description` are always written.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{'name': name, 'description': description};
    putObject(json, 'input_schema', inputSchema);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticMcpListToolsItem &&
          other.name == name &&
          other.description == description &&
          deepEquals(other.inputSchema, inputSchema);

  @override
  int get hashCode => Object.hash(name, description, deepHash(inputSchema));

  @override
  String toString() => 'AgenticMcpListToolsItem${toJson()}';
}

/// The model provider asks for approval before it calls an MCP tool. Port
/// of eino `schema.MCPToolApprovalRequest`.
final class AgenticMcpToolApprovalRequest extends ContentBlockVariant {
  const AgenticMcpToolApprovalRequest({
    this.id = '',
    this.name = '',
    this.arguments = '',
    this.serverLabel = '',
  });

  /// Reads Go's JSON form.
  factory AgenticMcpToolApprovalRequest.fromJson(Map<String, Object?> json) =>
      AgenticMcpToolApprovalRequest(
        id: readString(json, 'id'),
        name: readString(json, 'name'),
        arguments: readString(json, 'arguments'),
        serverLabel: readString(json, 'server_label'),
      );

  final String id;
  final String name;
  final String arguments;
  final String serverLabel;

  @override
  ContentBlockType get blockType => ContentBlockType.mcpToolApprovalRequest;

  /// Go's JSON form; `name` is always written.
  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'id', id);
    json['name'] = name;
    putString(json, 'arguments', arguments);
    putString(json, 'server_label', serverLabel);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticMcpToolApprovalRequest &&
          other.id == id &&
          other.name == name &&
          other.arguments == arguments &&
          other.serverLabel == serverLabel;

  @override
  int get hashCode => Object.hash(id, name, arguments, serverLabel);

  /// Port of eino `MCPToolApprovalRequest.String`.
  @override
  String toString() => '      server_label: $serverLabel\n'
      '      id: $id\n'
      '      name: $name\n'
      '      arguments: $arguments\n';
}

/// The user's answer to an [AgenticMcpToolApprovalRequest]. Port of eino
/// `schema.MCPToolApprovalResponse`.
final class AgenticMcpToolApprovalResponse extends ContentBlockVariant {
  const AgenticMcpToolApprovalResponse({
    this.approvalRequestId = '',
    this.approve = false,
    this.reason = '',
  });

  /// Reads Go's JSON form.
  factory AgenticMcpToolApprovalResponse.fromJson(Map<String, Object?> json) =>
      AgenticMcpToolApprovalResponse(
        approvalRequestId: readString(json, 'approval_request_id'),
        approve: readBool(json, 'approve'),
        reason: readString(json, 'reason'),
      );

  final String approvalRequestId;
  final bool approve;
  final String reason;

  @override
  ContentBlockType get blockType => ContentBlockType.mcpToolApprovalResponse;

  /// Go's JSON form; `approve` is always written.
  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putString(json, 'approval_request_id', approvalRequestId);
    json['approve'] = approve;
    putString(json, 'reason', reason);
    return json;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticMcpToolApprovalResponse &&
          other.approvalRequestId == approvalRequestId &&
          other.approve == approve &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(approvalRequestId, approve, reason);

  /// Port of eino `MCPToolApprovalResponse.String`.
  @override
  String toString() {
    final sb = StringBuffer(
      '      approval_request_id: $approvalRequestId\n'
      '      approve: $approve\n',
    );
    if (reason.isNotEmpty) sb.write('      reason: $reason\n');
    return sb.toString();
  }
}

// ---------------------------------------------------------------------------
// Format: port of AgenticMessage.Format and the formatUserInput* functions.
// ---------------------------------------------------------------------------

AgenticMessage _formatMessage(
  AgenticMessage message,
  Map<String, Object?> vars,
  FormatType type,
) {
  if (message.contentBlocks.isEmpty) return message;

  /// A text that is empty is left alone, as in Eino.
  String text(String source) =>
      source.isEmpty ? source : formatTemplateText(source, vars, type);

  ContentBlockVariant formatted(ContentBlockVariant content) =>
      switch (content) {
        final UserInputText c => UserInputText(text: text(c.text)),
        final UserInputImage c => c.copyWith(
            url: text(c.url),
            fileId: text(c.fileId),
            base64Data: text(c.base64Data),
          ),
        final UserInputAudio c => c.copyWith(
            url: text(c.url),
            fileId: text(c.fileId),
            base64Data: text(c.base64Data),
          ),
        final UserInputVideo c => c.copyWith(
            url: text(c.url),
            fileId: text(c.fileId),
            base64Data: text(c.base64Data),
          ),
        final UserInputFile c => c.copyWith(
            url: text(c.url),
            name: text(c.name),
            fileId: text(c.fileId),
            base64Data: text(c.base64Data),
          ),
        _ => content,
      };

  return message.copyWith(
    contentBlocks: [
      for (final block in message.contentBlocks)
        block.copyWith(content: formatted(block.content)),
    ],
  );
}
