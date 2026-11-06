/// Helpers of `ClaudeAgenticModel`: the constants of its requests and
/// `extra` keys, reading server tool arguments and results back, and the
/// helpers of the content block extras.
///
/// Port of eino-ext `components/model/agenticclaude/utils.go`, of the
/// unexported half of `consts.go`, `extension.go` and
/// `content_block_extra.go`. Everything here is internal to threepio. Not
/// ported from `utils.go`: `getEnvWithFallbacks` (nothing is read from the
/// environment), `newClaudeOpt`/`newClaudeStrOpt` (the JSON is built
/// directly) and `panicErr` (Dart has no panics to recover).
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../../errors.dart';
import '../../../../schema/agentic_message.dart';
import '../../../../schema/tool_info.dart';
import 'claude_agentic_extension.dart';

/// The `type` of the web search server tool, version 2026-02-09 (Go:
/// `serverToolVersionWebSearch20260209`).
@internal
const claudeServerToolVersionWebSearch20260209 = 'web_search_20260209';

/// The `type` of the web fetch server tool, version 2026-03-09 (Go:
/// `serverToolVersionWebFetch20260309`).
@internal
const claudeServerToolVersionWebFetch20260309 = 'web_fetch_20260309';

/// The `type` of the code execution server tool, version 2026-01-20 (Go:
/// `serverToolVersionCodeExecution20260120`).
@internal
const claudeServerToolVersionCodeExecution20260120 = 'code_execution_20260120';

/// The `type` of the BM25 tool search server tool (Go:
/// `serverToolVersionToolSearchToolBm25_20251119`).
@internal
const claudeServerToolVersionToolSearchToolBm25V20251119 =
    'tool_search_tool_bm25_20251119';

/// The `type` of the regex tool search server tool (Go:
/// `serverToolVersionToolSearchToolRegex20251119`).
@internal
const claudeServerToolVersionToolSearchToolRegex20251119 =
    'tool_search_tool_regex_20251119';

/// The header that carries beta feature names (Go: `headerAnthropicBeta`).
@internal
const claudeAgenticHeaderAnthropicBeta = 'anthropic-beta';

/// The beta the web fetch tool of 2026-03-09 needs (Go:
/// `betaHeaderWebFetch20260309`).
@internal
const claudeAgenticBetaWebFetch20260309 = 'web-fetch-2026-03-09';

/// The component type name of `ClaudeAgenticModel` (Go: `implType`).
@internal
const claudeAgenticImplType = 'AgenticClaude';

/// The `AgenticMessage.extra` key of the cache-creation token count (Go:
/// `keyOfCacheCreationInputTokens`; the same key as the classic Claude
/// model's).
@internal
const claudeAgenticKeyOfCacheCreationInputTokens =
    '_eino_claude_cache_creation_input_tokens';

/// The Go name of the type a JSON value decodes to, for error messages
/// (Go's `%T`). Every number is `float64`, as Go decodes a JSON number into
/// an `any`, also when Dart's decoder gives an `int`.
@internal
String claudeGoTypeName(Object? value) => switch (value) {
  null => '<nil>',
  String() => 'string',
  bool() => 'bool',
  num() => 'float64',
  List<Object?>() => '[]interface {}',
  Map<Object?, Object?>() => 'map[string]interface {}',
  _ => value.runtimeType.toString(),
};

/// The `ContentBlock.extra` key of a web search result's caller, as raw JSON
/// (Go: `keyOfWebSearchToolResultCaller`).
@internal
const claudeAgenticKeyOfWebSearchToolResultCaller =
    '_agenticclaude_web_search_tool_result_caller';

/// The `ContentBlock.extra` key of a web fetch result's caller, as raw JSON
/// (Go: `keyOfWebFetchToolResultCaller`).
@internal
const claudeAgenticKeyOfWebFetchToolResultCaller =
    '_agenticclaude_web_fetch_tool_result_caller';

/// The `extra` key of a manual cache breakpoint's TTL, on content blocks and
/// tool infos (Go: `keyOfCacheControlTTL`). An empty string is the API's
/// default TTL.
@internal
const claudeAgenticKeyOfCacheControlTtl = '_agenticclaude_cache_control_ttl';

/// [block] with [value] under [key] in its `extra`.
///
/// Port of eino-ext agenticclaude `setContentBlockExtraValue` (which sets it
/// in place).
@internal
ContentBlock claudeContentBlockWithExtra(
  ContentBlock block,
  String key,
  Object? value,
) => block.copyWith(extra: {...?block.extra, key: value});

/// The value under [key] in the `extra` of [block] when it is a [T], or
/// `null`.
///
/// Port of eino-ext agenticclaude `getContentBlockExtraValue`.
@internal
T? claudeContentBlockExtraValue<T extends Object>(
  ContentBlock? block,
  String key,
) {
  final value = block?.extra?[key];
  return value is T ? value : null;
}

/// [block] with the raw JSON of a web search result's [caller] (the
/// response's `caller` object, or `null` when it had none) in its `extra`.
///
/// Port of eino-ext agenticclaude `setWebSearchResultCaller`. As Go stores
/// `caller.RawJSON()`, the value is an empty string when the response had no
/// caller.
@internal
ContentBlock claudeWithWebSearchResultCaller(
  ContentBlock block,
  Object? caller,
) => claudeContentBlockWithExtra(
  block,
  claudeAgenticKeyOfWebSearchToolResultCaller,
  caller == null ? '' : jsonEncode(caller),
);

/// The `caller` to send with the web search result of [block], or `null`
/// when it has none.
///
/// Port of eino-ext agenticclaude `toWebSearchResultCallerParam`. Throws a
/// [ThreepioFormatException] when the stored caller is not a JSON object.
@internal
Map<String, Object?>? claudeWebSearchResultCallerParam(ContentBlock block) =>
    _callerParam(block, claudeAgenticKeyOfWebSearchToolResultCaller);

/// [block] with the raw JSON of a web fetch result's [caller] in its
/// `extra`. Port of eino-ext agenticclaude `setWebFetchResultCaller`.
@internal
ContentBlock claudeWithWebFetchResultCaller(
  ContentBlock block,
  Object? caller,
) => claudeContentBlockWithExtra(
  block,
  claudeAgenticKeyOfWebFetchToolResultCaller,
  caller == null ? '' : jsonEncode(caller),
);

/// The `caller` to send with the web fetch result of [block], or `null`.
/// Port of eino-ext agenticclaude `toWebFetchResultCallerParam`.
@internal
Map<String, Object?>? claudeWebFetchResultCallerParam(ContentBlock block) =>
    _callerParam(block, claudeAgenticKeyOfWebFetchToolResultCaller);

Map<String, Object?>? _callerParam(ContentBlock block, String key) {
  final caller = claudeContentBlockExtraValue<String>(block, key);
  if (caller == null || caller.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(caller);
  } on FormatException catch (error) {
    throw ThreepioFormatException(
      'invalid result caller: ${error.message}',
      source: caller,
      cause: error,
    );
  }
  if (decoded is! Map) {
    throw ThreepioFormatException(
      'invalid result caller: not a JSON object',
      source: caller,
    );
  }
  return decoded.cast<String, Object?>();
}

/// Whether [block] carries a manual cache breakpoint. Port of eino-ext
/// agenticclaude `hasCacheControlOnContentBlock`.
@internal
bool claudeHasCacheControlOnContentBlock(ContentBlock block) =>
    block.extra?.containsKey(claudeAgenticKeyOfCacheControlTtl) ?? false;

/// The `cache_control` object of [block]'s manual breakpoint, or `null`.
/// Port of eino-ext agenticclaude `getContentBlockCacheControl`.
@internal
Map<String, Object?>? claudeContentBlockCacheControl(ContentBlock block) =>
    _cacheControl(block.extra?[claudeAgenticKeyOfCacheControlTtl]);

/// Whether [tool] carries a manual cache breakpoint. Port of eino-ext
/// agenticclaude `hasCacheControlOnToolInfo`.
@internal
bool claudeHasCacheControlOnToolInfo(ToolInfo tool) =>
    tool.extra?.containsKey(claudeAgenticKeyOfCacheControlTtl) ?? false;

/// The `cache_control` object of [tool]'s manual breakpoint, or `null`.
/// Port of eino-ext agenticclaude `getToolInfoCacheControl`.
@internal
Map<String, Object?>? claudeToolInfoCacheControl(ToolInfo tool) =>
    _cacheControl(tool.extra?[claudeAgenticKeyOfCacheControlTtl]);

Map<String, Object?>? _cacheControl(Object? ttl) {
  if (ttl is! String) return null;
  return {'type': 'ephemeral', if (ttl.isNotEmpty) 'ttl': ttl};
}

// ---------------------------------------------------------------------------
// Reading the blocks
// ---------------------------------------------------------------------------

/// The arguments of [call] as a [ClaudeServerToolCallArguments].
///
/// Port of eino-ext agenticclaude `getServerToolCallArguments`: the
/// arguments as this model set them, or a JSON map of them (what a JSON
/// round trip of the message gives), decoded with `mapstructure`'s rules.
/// Throws a [ThreepioFormatException] for missing arguments, a map that
/// cannot be decoded, or any other type.
@internal
ClaudeServerToolCallArguments claudeServerToolCallArguments(
  ServerToolCall call,
) {
  final arguments = call.arguments;
  switch (arguments) {
    case null:
      throw const ThreepioFormatException('server tool call arguments are nil');
    case final ClaudeServerToolCallArguments typed:
      return typed;
    case final Map<Object?, Object?> map:
      try {
        return ClaudeServerToolCallArguments.fromJson(
          map.cast<String, Object?>(),
        );
      } on ThreepioFormatException catch (error) {
        throw ThreepioFormatException(
          'failed to decode server tool call arguments: ${error.message}',
          cause: error,
        );
      }
    default:
      throw ThreepioFormatException(
        'unexpected type ${claudeGoTypeName(arguments)} for server tool call '
        'arguments',
      );
  }
}

/// The content of [result] as a [ClaudeServerToolResult].
///
/// Port of eino-ext agenticclaude `getServerToolResult`; see
/// [claudeServerToolCallArguments].
@internal
ClaudeServerToolResult claudeServerToolResultOf(ServerToolResult result) {
  final content = result.content;
  switch (content) {
    case null:
      throw const ThreepioFormatException('server tool result is nil');
    case final ClaudeServerToolResult typed:
      return typed;
    case final Map<Object?, Object?> map:
      try {
        return ClaudeServerToolResult.fromJson(map.cast<String, Object?>());
      } on ThreepioFormatException catch (error) {
        throw ThreepioFormatException(
          'failed to decode server tool result: ${error.message}',
          cause: error,
        );
      }
    default:
      throw ThreepioFormatException(
        'unexpected type ${claudeGoTypeName(content)} for server tool result',
      );
  }
}

/// Joins the arguments of the chunks of one streamed server tool call: the
/// start of the block and the decoded `input_json_delta` documents, each a
/// complete value. Field by field, the last non-empty value wins.
///
/// Not in Go, which registers no concat function for its arguments type, so
/// that `ConcatAgenticMessages` fails on a streamed server tool call ("cannot
/// concat multiple non-zero value"); registered with `StreamConcat` by
/// `ensureClaudeAgenticTypesRegistered`.
@internal
ClaudeServerToolCallArguments concatClaudeServerToolCallArguments(
  List<ClaudeServerToolCallArguments> chunks,
) {
  String last(Iterable<String> values) =>
      values.lastWhere((value) => value.isNotEmpty, orElse: () => '');
  T? merged<T>(Iterable<T?> values, T Function(List<T> present) join) {
    final present = values.whereType<T>().toList();
    return present.isEmpty ? null : join(present);
  }

  return ClaudeServerToolCallArguments(
    webSearch: merged(
      chunks.map((c) => c.webSearch),
      (all) => ClaudeWebSearchArguments(query: last(all.map((a) => a.query))),
    ),
    webFetch: merged(
      chunks.map((c) => c.webFetch),
      (all) => ClaudeWebFetchArguments(url: last(all.map((a) => a.url))),
    ),
    codeExecution: merged(
      chunks.map((c) => c.codeExecution),
      (all) => ClaudeCodeExecutionArguments(code: last(all.map((a) => a.code))),
    ),
    bashCodeExecution: merged(
      chunks.map((c) => c.bashCodeExecution),
      (all) => ClaudeBashCodeExecutionArguments(
        command: last(all.map((a) => a.command)),
      ),
    ),
    textEditorCodeExecution: merged(
      chunks.map((c) => c.textEditorCodeExecution),
      (all) => ClaudeTextEditorCodeExecutionArguments(
        command: last(all.map((a) => a.command)),
        path: last(all.map((a) => a.path)),
        fileText: last(all.map((a) => a.fileText)),
        oldStr: last(all.map((a) => a.oldStr)),
        newStr: last(all.map((a) => a.newStr)),
      ),
    ),
    toolSearchToolBm25: merged(
      chunks.map((c) => c.toolSearchToolBm25),
      (all) => ClaudeToolSearchToolBm25Arguments(
        query: last(all.map((a) => a.query)),
      ),
    ),
    toolSearchToolRegex: merged(
      chunks.map((c) => c.toolSearchToolRegex),
      (all) => ClaudeToolSearchToolRegexArguments(
        query: last(all.map((a) => a.query)),
      ),
    ),
  );
}
