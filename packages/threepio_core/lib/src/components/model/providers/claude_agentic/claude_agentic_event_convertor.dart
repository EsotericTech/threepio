/// The events of a Messages API stream as agentic message chunks.
///
/// Port of eino-ext `components/model/agenticclaude/event_convertor.go`.
/// Everything here is internal to threepio.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../../errors.dart';
import '../../../../schema/agentic_message.dart';
import '../../../../schema/extensions/claude.dart';
import 'claude_agentic_consts.dart';
import 'claude_agentic_convertor.dart';
import 'claude_agentic_extension.dart';
import 'claude_agentic_utils.dart';

/// Turns the events of one stream into agentic message chunks.
///
/// Port of eino-ext agenticclaude `streamConverter`. Each block of a
/// `content_block_start` or `content_block_delta` event becomes a chunk with
/// one block whose `StreamingMeta.index` is the event's index;
/// `message_start` and `message_delta` become chunks with the response meta
/// (and the cache-creation token count in `extra`); other events give
/// nothing. The converter remembers the kind of each started block, so that
/// the `input_json_delta` of a server tool call is decoded as that tool's
/// arguments and the one of a function tool call is passed on as text.
@internal
final class ClaudeAgenticStreamConverter {
  /// A converter for a new stream.
  ClaudeAgenticStreamConverter();

  /// The kind of each started block, by index (Go: `blockKinds`).
  final Map<int, ContentBlockType> blockKinds = {};

  /// The tool of each started server tool call, by index (Go:
  /// `serverToolNames`).
  final Map<int, ClaudeServerToolName> serverToolNames = {};

  final ClaudeAgenticBlockConverter _blocks = ClaudeAgenticBlockConverter();

  /// The chunk for [event] (the decoded `data` of a server-sent event), or
  /// `null` for an event that carries nothing.
  ///
  /// Port of eino-ext agenticclaude `toMessageStreamingChunk`. Throws a
  /// [ThreepioFormatException] for a block it cannot convert and for a
  /// delta type it does not know.
  AgenticMessage? convert(Map<String, Object?> event) {
    switch (event['type']) {
      case 'message_start':
        return _blocks.message(_map(event['message']) ?? const {});
      case 'message_delta':
        final usage = _map(event['usage']);
        final cacheCreation = _int(usage?['cache_creation_input_tokens']);
        return AgenticMessage(
          role: AgenticRoleType.assistant,
          responseMeta: claudeAgenticDeltaResponseMeta(event),
          extra: cacheCreation > 0
              ? {claudeAgenticKeyOfCacheCreationInputTokens: cacheCreation}
              : null,
        );
      case 'content_block_start':
        return _chunk(
          startBlock(
            _int(event['index']),
            _map(event['content_block']) ?? const {},
          ),
        );
      case 'content_block_delta':
        return _chunk(
          deltaBlock(_int(event['index']), _map(event['delta']) ?? const {}),
        );
      default:
        return null;
    }
  }

  /// Port of eino-ext agenticclaude `newAssistantStreamingChunk`.
  static AgenticMessage? _chunk(ContentBlock? block) => block == null
      ? null
      : AgenticMessage(role: AgenticRoleType.assistant, contentBlocks: [block]);

  /// The chunk block of a `content_block_start` at [index], or `null` for a
  /// block that is dropped (redacted thinking, types it does not know, a
  /// tool search result whose call is not in this stream).
  ///
  /// Port of eino-ext agenticclaude `toStreamingStartBlock`: text and
  /// thinking with what they start with, a function tool call with its id
  /// and name only (its arguments come as deltas), server tool calls and
  /// results as `generate` converts them. Unlike Go, which builds the chunk
  /// from the payload only, a web search or web fetch result keeps its
  /// caller in `extra`, as in `generate`, so that it is sent back.
  ContentBlock? startBlock(int index, Map<String, Object?> block) {
    final meta = StreamingMeta(index: index);
    switch (block['type']) {
      case 'text':
        blockKinds[index] = ContentBlockType.assistantGenText;
        return ContentBlock(
          AssistantGenText(
            text: _str(block['text']),
            claudeExtension: claudeAgenticTextExtension(block['citations']),
          ),
          streamingMeta: meta,
        );
      case 'thinking':
        blockKinds[index] = ContentBlockType.reasoning;
        return ContentBlock(
          Reasoning(
            text: _str(block['thinking']),
            signature: _str(block['signature']),
          ),
          streamingMeta: meta,
        );
      case 'tool_use':
        blockKinds[index] = ContentBlockType.functionToolCall;
        return ContentBlock(
          FunctionToolCall(
            callId: _str(block['id']),
            name: _str(block['name']),
          ),
          streamingMeta: meta,
        );
      case 'server_tool_use':
        final converted = _blocks.serverToolUse(block);
        blockKinds[index] = ContentBlockType.serverToolCall;
        serverToolNames[index] = ClaudeServerToolName(_str(block['name']));
        return ContentBlock(converted.content, streamingMeta: meta);
      case 'tool_search_tool_result'
          when !_blocks.isToolSearchCall(_str(block['tool_use_id'])):
        // Go drops every tool search result of a stream. This one is
        // converted only when its call came earlier in the stream (which
        // tells the BM25 result from the regex one); otherwise it is dropped,
        // as in Go, rather than failing the stream.
        return null;
      case 'web_search_tool_result':
      case 'web_fetch_tool_result':
      case 'code_execution_tool_result':
      case 'bash_code_execution_tool_result':
      case 'text_editor_code_execution_tool_result':
      case 'tool_search_tool_result':
        blockKinds[index] = ContentBlockType.serverToolResult;
        final converted = _blocks.contentBlock(block)!;
        return converted.copyWith(streamingMeta: meta);
      default:
        return null;
    }
  }

  /// The chunk block of a `content_block_delta` at [index], or `null` for a
  /// citation of a type it does not know.
  ///
  /// Port of eino-ext agenticclaude `toStreamingDeltaBlock`. Throws a
  /// [ThreepioFormatException] for a delta type it does not know.
  ContentBlock? deltaBlock(int index, Map<String, Object?> delta) {
    final meta = StreamingMeta(index: index);
    final type = _str(delta['type']);
    switch (type) {
      case 'text_delta':
        return ContentBlock(
          AssistantGenText(text: _str(delta['text'])),
          streamingMeta: meta,
        );
      case 'citations_delta':
        final citation = claudeAgenticTextCitation(
          _map(delta['citation']) ?? const {},
        );
        if (citation == null) return null;
        return ContentBlock(
          AssistantGenText(
            claudeExtension: ClaudeAssistantGenTextExtension(
              citations: [citation],
            ),
          ),
          streamingMeta: meta,
        );
      case 'thinking_delta':
        return ContentBlock(
          Reasoning(text: _str(delta['thinking'])),
          streamingMeta: meta,
        );
      case 'signature_delta':
        return ContentBlock(
          Reasoning(signature: _str(delta['signature'])),
          streamingMeta: meta,
        );
      case 'input_json_delta':
        final partial = _str(delta['partial_json']);
        if (blockKinds[index] == ContentBlockType.serverToolCall) {
          return serverToolCallDelta(index, partial, meta);
        }
        return ContentBlock(
          FunctionToolCall(arguments: partial),
          streamingMeta: meta,
        );
      default:
        throw ThreepioFormatException('invalid stream delta type "$type"');
    }
  }

  /// The chunk block of an `input_json_delta` of the server tool call at
  /// [index].
  ///
  /// Port of eino-ext agenticclaude `toStreamingServerToolCallDeltaBlock`:
  /// as in Go, each delta is decoded as a complete JSON document of the
  /// tool's arguments. Unlike Go, an empty (or blank) delta gives no chunk
  /// instead of failing the stream ("unexpected end of JSON input"). Throws
  /// a [ThreepioFormatException] for an unknown tool and for a delta that is
  /// not the tool's arguments.
  ContentBlock? serverToolCallDelta(
    int index,
    String partialJson,
    StreamingMeta meta,
  ) {
    final name = serverToolNames[index] ?? const ClaudeServerToolName('');
    final ClaudeServerToolCallArguments Function(Map<String, Object?> json)
    decode;
    if (name == ClaudeServerToolName.webSearch) {
      decode = (json) => ClaudeServerToolCallArguments(
        webSearch: ClaudeWebSearchArguments.fromJson(json),
      );
    } else if (name == ClaudeServerToolName.webFetch) {
      decode = (json) => ClaudeServerToolCallArguments(
        webFetch: ClaudeWebFetchArguments.fromJson(json),
      );
    } else if (name == ClaudeServerToolName.codeExecution) {
      decode = (json) => ClaudeServerToolCallArguments(
        codeExecution: ClaudeCodeExecutionArguments.fromJson(json),
      );
    } else if (name == ClaudeServerToolName.bashCodeExecution) {
      decode = (json) => ClaudeServerToolCallArguments(
        bashCodeExecution: ClaudeBashCodeExecutionArguments.fromJson(json),
      );
    } else if (name == ClaudeServerToolName.textEditorCodeExecution) {
      decode = (json) => ClaudeServerToolCallArguments(
        textEditorCodeExecution:
            ClaudeTextEditorCodeExecutionArguments.fromJson(json),
      );
    } else if (name == ClaudeServerToolName.toolSearchToolBm25) {
      decode = (json) => ClaudeServerToolCallArguments(
        toolSearchToolBm25: ClaudeToolSearchToolBm25Arguments.fromJson(json),
      );
    } else if (name == ClaudeServerToolName.toolSearchToolRegex) {
      decode = (json) => ClaudeServerToolCallArguments(
        toolSearchToolRegex: ClaudeToolSearchToolRegexArguments.fromJson(json),
      );
    } else {
      throw ThreepioFormatException('invalid server tool name "${name.value}"');
    }
    if (partialJson.trim().isEmpty) return null;
    return ContentBlock(
      ServerToolCall(
        arguments: claudeAgenticDecodeServerToolArguments(
          name,
          partialJson,
          decode,
        ),
      ),
      streamingMeta: meta,
    );
  }
}

/// [partialJson] decoded with [decode] as the arguments of the server tool
/// [name].
///
/// Port of the `sonic.UnmarshalString` of eino-ext agenticclaude's
/// `toStreaming…CallDeltaBlock` functions: `null` decodes to empty
/// arguments; anything else that is not an object of the tool's fields is a
/// [ThreepioFormatException] saying "failed to decode `name` server tool
/// arguments".
@internal
ClaudeServerToolCallArguments claudeAgenticDecodeServerToolArguments(
  ClaudeServerToolName name,
  String partialJson,
  ClaudeServerToolCallArguments Function(Map<String, Object?> json) decode,
) {
  ThreepioFormatException failed(String detail, [Object? cause]) =>
      ThreepioFormatException(
        'failed to decode ${name.value} server tool arguments: $detail',
        source: partialJson,
        cause: cause,
      );
  final Object? json;
  try {
    json = jsonDecode(partialJson);
  } on FormatException catch (error) {
    throw failed(error.message, error);
  }
  if (json == null) return decode(const {});
  if (json is! Map) {
    throw failed('expected an object, got ${claudeGoTypeName(json)}');
  }
  try {
    return decode(json.cast<String, Object?>());
  } on ThreepioFormatException catch (error) {
    throw failed(error.message, error);
  }
}

String _str(Object? value) => value is String ? value : '';

int _int(Object? value) => value is num ? value.toInt() : 0;

Map<String, Object?>? _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;
