/// What `ClaudeChatModel` keeps in `Message.extra` and `ToolInfo.extra`, and
/// the accessors for it.
///
/// Port of eino-ext `components/model/claude/message_extra.go`. `Message`
/// and `ToolInfo` are immutable, so the setters return a copy. The values are
/// stored under Go's keys as JSON values (strings, numbers, booleans, maps,
/// lists), so a message keeps them through a JSON round trip.
library;

import 'package:meta/meta.dart';

import '../../../../errors.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import 'claude_config.dart';
import 'claude_converters.dart';

/// The two kinds of [ClaudeToolSearchEvent].
///
/// Port of the values of eino-ext `ToolSearchEvent.Type`.
enum ClaudeToolSearchEventType {
  /// The model asked the server to search for tools.
  serverToolUse('server_tool_use'),

  /// The result of that search.
  toolSearchToolResult('tool_search_tool_result');

  const ClaudeToolSearchEventType(this.wireValue);

  /// The content block type.
  final String wireValue;
}

/// A tool name in a tool search result.
///
/// Port of eino-ext `claude.ToolSearchEventToolReference`.
@immutable
final class ClaudeToolSearchEventToolReference {
  /// A reference to the tool [toolName].
  const ClaudeToolSearchEventToolReference(this.toolName);

  /// The name of the tool that was found.
  final String toolName;

  @override
  bool operator ==(Object other) =>
      other is ClaudeToolSearchEventToolReference && other.toolName == toolName;

  @override
  int get hashCode => toolName.hashCode;

  @override
  String toString() => 'ClaudeToolSearchEventToolReference($toolName)';
}

/// The result or the error of a tool search.
///
/// Port of eino-ext `claude.ToolSearchEventContent`.
@immutable
final class ClaudeToolSearchEventContent {
  /// Content of the kind [type].
  const ClaudeToolSearchEventContent({
    required this.type,
    this.toolReferences = const [],
    this.errorCode = '',
    this.errorMessage = '',
  });

  /// `tool_search_tool_search_result` or `tool_search_tool_result_error`.
  /// Kept as the API sent it, as in Go.
  final String type;

  /// The tools that were found (for a search result).
  final List<ClaudeToolSearchEventToolReference> toolReferences;

  /// The error code (for an error).
  final String errorCode;

  /// The error message (for an error).
  final String errorMessage;

  @override
  String toString() => 'ClaudeToolSearchEventContent(type: $type, '
      'toolReferences: $toolReferences, errorCode: $errorCode)';
}

/// A tool search the model ran on the server, kept on the assistant message
/// so that it can be sent back in the next request.
///
/// Port of eino-ext `claude.ToolSearchEvent`: either a `server_tool_use`
/// block (the model asks for a search: [id], [name], [input]) or a
/// `tool_search_tool_result` block (the result: [toolUseId], [content]).
@immutable
final class ClaudeToolSearchEvent {
  /// An event of the kind [type]; see the fields for which belong to it.
  const ClaudeToolSearchEvent({
    required this.type,
    this.id = '',
    this.name = '',
    this.input,
    this.toolUseId = '',
    this.content,
  });

  /// An event read back from its [toJson] form.
  ///
  /// Throws a `ThreepioFormatException` when [json] is not such a form.
  factory ClaudeToolSearchEvent.fromJson(Map<String, Object?> json) {
    final typeName = json['type'];
    final type = ClaudeToolSearchEventType.values
        .where((t) => t.wireValue == typeName)
        .firstOrNull;
    if (type == null) {
      throw ThreepioFormatException(
        'unknown tool search event type: $typeName',
      );
    }
    final content = json['content'];
    return ClaudeToolSearchEvent(
      type: type,
      id: _string(json['id']),
      name: _string(json['name']),
      input: json['input'],
      toolUseId: _string(json['tool_use_id']),
      content: content is Map
          ? ClaudeToolSearchEventContent(
              type: _string(content['type']),
              toolReferences: [
                for (final ref in content['tool_references'] is List
                    ? content['tool_references'] as List
                    : const [])
                  if (ref is Map)
                    ClaudeToolSearchEventToolReference(
                      _string(ref['tool_name']),
                    ),
              ],
              errorCode: _string(content['error_code']),
              errorMessage: _string(content['error_message']),
            )
          : null,
    );
  }

  /// What kind of event this is.
  final ClaudeToolSearchEventType type;

  /// The block id (server tool use).
  final String id;

  /// The server tool, such as `tool_search_tool_bm25` (server tool use).
  final String name;

  /// The server tool's input as decoded JSON (server tool use; Go keeps the
  /// raw JSON).
  final Object? input;

  /// The id of the server tool use this result answers (tool search result).
  final String toolUseId;

  /// The search result or error (tool search result).
  final ClaudeToolSearchEventContent? content;

  /// The JSON form stored in `Message.extra`.
  Map<String, Object?> toJson() => {
        'type': type.wireValue,
        if (type == ClaudeToolSearchEventType.serverToolUse) ...{
          'id': id,
          'name': name,
          'input': input,
        },
        if (type == ClaudeToolSearchEventType.toolSearchToolResult) ...{
          'tool_use_id': toolUseId,
          if (content != null)
            'content': {
              'type': content!.type,
              if (content!.toolReferences.isNotEmpty)
                'tool_references': [
                  for (final ref in content!.toolReferences)
                    {'tool_name': ref.toolName},
                ],
              if (content!.errorCode.isNotEmpty)
                'error_code': content!.errorCode,
              if (content!.errorMessage.isNotEmpty)
                'error_message': content!.errorMessage,
            },
        },
      };

  @override
  String toString() => 'ClaudeToolSearchEvent(${toJson()})';

  static String _string(Object? value) => value is String ? value : '';
}

/// The Claude-specific values of a message.
///
/// Port of eino-ext claude's message helpers `GetThinking`,
/// `SetMessageCacheControl` and `GetCacheCreationInputTokens` (the
/// deprecated `SetMessageBreakpoint` is not ported).
extension ClaudeMessageExtras on Message {
  /// The thinking Claude did before this message, or `null` when it did not
  /// think (or the message is not Claude's).
  ///
  /// Port of eino-ext `claude.GetThinking`. The same text is in
  /// `reasoningContent`; this value is the one sent back with the signature.
  String? get claudeThinking {
    final value = extra?[claudeKeyOfThinking];
    return value is String ? value : null;
  }

  /// A copy of this message with a cache breakpoint: the prompt up to and
  /// including this message is cached, for the TTL of [control].
  ///
  /// Port of eino-ext `claude.SetMessageCacheControl`. A `null` [control] or
  /// one without a TTL means the API default of five minutes. The other
  /// values in `extra` are kept.
  Message withClaudeCacheControl([ClaudeCacheControl? control]) =>
      copyWith(extra: _withBreakpoint(extra, control));

  /// The number of input tokens written into a new prompt cache entry by the
  /// request that produced this message, or `null` when there were none.
  ///
  /// Port of eino-ext `claude.GetCacheCreationInputTokens`. The same count
  /// is in `responseMeta.usage.promptTokenDetails.cacheWriteTokens`; the
  /// tokens read from the cache are in `…cachedTokens`.
  int? get claudeCacheCreationInputTokens {
    final value = extra?[claudeKeyOfCacheCreationInputTokens];
    if (value is int) return value;
    if (value is double && value == value.truncateToDouble()) {
      return value.toInt();
    }
    return null;
  }

  /// The server-side tool searches of this assistant message, in the order
  /// the model ran them.
  ///
  /// Go keeps them under `_eino_claude_tool_search_events` without an
  /// exported getter; here they are stored as JSON and read with this
  /// getter. Entries that are not events are skipped.
  List<ClaudeToolSearchEvent> get claudeToolSearchEvents {
    final value = extra?[claudeKeyOfToolSearchEvents];
    if (value is! List) return const [];
    final events = <ClaudeToolSearchEvent>[];
    for (final entry in value) {
      if (entry is! Map) continue;
      try {
        events.add(ClaudeToolSearchEvent.fromJson(entry.cast<String, Object?>()));
      } on ThreepioFormatException {
        continue;
      }
    }
    return events;
  }
}

/// The Claude-specific values of a tool.
///
/// Port of eino-ext `claude.SetToolInfoCacheControl` (the deprecated
/// `SetToolInfoBreakpoint` is not ported).
extension ClaudeToolInfoExtras on ToolInfo {
  /// A copy of this tool with a cache breakpoint: the tool definitions up to
  /// and including this one are cached, for the TTL of [control].
  ///
  /// Port of eino-ext `claude.SetToolInfoCacheControl`. A `null` [control]
  /// or one without a TTL means the API default of five minutes.
  ToolInfo withClaudeCacheControl([ClaudeCacheControl? control]) =>
      copyWith(extra: _withBreakpoint(extra, control));
}

Map<String, dynamic> _withBreakpoint(
  Map<String, dynamic>? extra,
  ClaudeCacheControl? control,
) {
  final ttl = control?.ttl?.value;
  return {
    ...?extra,
    claudeKeyOfBreakPoint: true,
    if (ttl != null && ttl.isNotEmpty) claudeKeyOfBreakPointTtl: ttl,
  };
}
