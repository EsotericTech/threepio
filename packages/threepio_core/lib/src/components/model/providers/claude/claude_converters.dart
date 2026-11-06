/// The wire format of `ClaudeChatModel`: the request body of the Anthropic
/// Messages API built from messages, tools and options, and messages built
/// from its responses and stream events.
///
/// Port of the conversion functions of eino-ext `components/model/claude`
/// (`genParamsAndOptions`, `populateInput`, `populateTools`,
/// `populateToolChoice`, `convSchemaMessage`, `convOutputMessage`,
/// `convStreamEvent`, …). Go builds `anthropic-sdk-go` parameter structs;
/// here the JSON is built directly, in the shape the SDK sends.
///
/// Everything here is internal to threepio: it is public in `src/` for the
/// model and its tests only.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../../errors.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import '../../chat_model_options.dart';
import 'claude_config.dart';
import 'claude_message_extras.dart';
import 'claude_options.dart';

/// The `anthropic-version` header the Go SDK sends.
@internal
const claudeApiVersion = '2023-06-01';

/// The `extra` key of the thinking text (Go: `keyOfThinking`).
@internal
const claudeKeyOfThinking = '_eino_claude_thinking';

/// The `extra` key of a cache breakpoint (Go: `keyOfBreakPoint`).
@internal
const claudeKeyOfBreakPoint = '_eino_claude_breakpoint';

/// The `extra` key of a breakpoint's TTL (Go: `keyOfBreakPointTTL`).
@internal
const claudeKeyOfBreakPointTtl = '_eino_claude_breakpoint_ttl';

/// The `extra` key of the thinking signature (Go: `keyOfThinkingSignature`).
@internal
const claudeKeyOfThinkingSignature = '_eino_claude_thinking_signature';

/// The `extra` key of the tool search events (Go: `keyOfToolSearchEvents`).
@internal
const claudeKeyOfToolSearchEvents = '_eino_claude_tool_search_events';

/// The `extra` key of the cache-creation token count (Go:
/// `keyOfCacheCreationInputTokens`).
@internal
const claudeKeyOfCacheCreationInputTokens =
    '_eino_claude_cache_creation_input_tokens';

// ---------------------------------------------------------------------------
// Message extras (the unexported half of message_extra.go)
// ---------------------------------------------------------------------------

/// Whether [extra] marks a cache breakpoint (Go: `isBreakpointMessage`,
/// `isBreakpointTool`).
@internal
bool claudeIsBreakpoint(Map<String, dynamic>? extra) =>
    extra?[claudeKeyOfBreakPoint] == true;

/// The cache control of the breakpoint in [extra], or `null` when it has no
/// TTL (Go: `getMessageBreakpointCacheControl`,
/// `getToolBreakpointCacheControl`).
@internal
ClaudeCacheControl? claudeBreakpointCacheControl(Map<String, dynamic>? extra) {
  final ttl = extra?[claudeKeyOfBreakPointTtl];
  if (ttl is! String || ttl.isEmpty) return null;
  return ClaudeCacheControl(ttl: ClaudeCacheTtl(ttl));
}

/// The thinking signature in [extra], or `null` (Go: `getThinkingSignature`).
@internal
String? claudeThinkingSignatureOf(Map<String, dynamic>? extra) {
  final value = extra?[claudeKeyOfThinkingSignature];
  return value is String ? value : null;
}

/// Whether [extra] has a thinking text, empty or not (Go: the `ok` of
/// `GetThinking`).
@internal
bool claudeHasThinking(Map<String, dynamic>? extra) =>
    extra?[claudeKeyOfThinking] is String;

/// Stores [thinking] in [extra] (Go: `setThinking`).
@internal
void claudeSetThinking(Map<String, dynamic> extra, String thinking) =>
    extra[claudeKeyOfThinking] = thinking;

/// Stores [signature] in [extra] (Go: `setThinkingSignature`).
@internal
void claudeSetThinkingSignature(Map<String, dynamic> extra, String signature) =>
    extra[claudeKeyOfThinkingSignature] = signature;

/// Stores [tokens] in [extra] when there are any (Go:
/// `setCacheCreationInputTokens`).
@internal
void claudeSetCacheCreationInputTokens(Map<String, dynamic> extra, int tokens) {
  if (tokens > 0) extra[claudeKeyOfCacheCreationInputTokens] = tokens;
}

/// Appends [event] to the events in [extra] (Go: `appendToolSearchEvent`).
@internal
void claudeAppendToolSearchEvent(
  Map<String, dynamic> extra,
  ClaudeToolSearchEvent event,
) {
  final existing = extra[claudeKeyOfToolSearchEvents];
  extra[claudeKeyOfToolSearchEvents] = [
    if (existing is List) ...existing,
    event.toJson(),
  ];
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

/// The Claude-specific settings of one call: the config's values with the
/// [ClaudeRequestOptions] of the call applied.
///
/// Port of eino-ext claude's `options` struct as `GetImplSpecificOptions`
/// returns it.
@internal
@immutable
final class ResolvedClaudeOptions {
  /// The settings of a call.
  const ResolvedClaudeOptions({
    required this.timeout,
    this.topK,
    this.thinkingConfig,
    this.disableParallelToolUse,
    this.autoCacheControl,
    this.responseFormat,
    this.customHeaders = const [],
  });

  /// The settings of a call with [options] made with [config].
  factory ResolvedClaudeOptions.of(
    ClaudeConfig config,
    ChatModelOptions options,
  ) {
    var topK = config.topK;
    var thinkingConfig = config.thinkingConfig;
    var disableParallelToolUse = config.disableParallelToolUse;
    var autoCacheControl = config.autoCacheControl;
    var responseFormat = config.responseFormat;
    var timeout = config.timeout;
    final headers = <MapEntry<String, String>>[];

    final all = options.extensions.whereType<ClaudeRequestOptions>().toList();
    // The first one found wins, so they are applied from the last one on.
    for (final o in all.reversed) {
      topK = o.topK ?? topK;
      thinkingConfig = o.thinkingConfig ?? thinkingConfig;
      disableParallelToolUse =
          o.disableParallelToolUse ?? disableParallelToolUse;
      if (o.autoCacheControl != null) {
        autoCacheControl = o.autoCacheControl;
      } else if (o.disableAutoCacheControl) {
        autoCacheControl = null;
      }
      responseFormat = o.responseFormat ?? responseFormat;
      final requestTimeout = o.requestTimeout;
      if (requestTimeout != null && requestTimeout > Duration.zero) {
        timeout = requestTimeout;
      }
      // As Go's WithCustomHeaders, a later map replaces an earlier one.
      final custom = o.customHeaders;
      if (custom != null) {
        headers
          ..clear()
          ..addAll(custom.entries);
      }
    }

    return ResolvedClaudeOptions(
      topK: topK,
      thinkingConfig: thinkingConfig,
      disableParallelToolUse: disableParallelToolUse,
      autoCacheControl: autoCacheControl,
      responseFormat: responseFormat,
      timeout: timeout,
      customHeaders: headers,
    );
  }

  /// `top_k`, or `null`.
  final int? topK;

  /// `thinking`, or `null`.
  final ClaudeThinkingConfig? thinkingConfig;

  /// `disable_parallel_tool_use` of the tool choice, or `null`.
  final bool? disableParallelToolUse;

  /// The cache control of automatic breakpoints, or `null` for none.
  final ClaudeCacheControl? autoCacheControl;

  /// Structured output, or `null`.
  final ClaudeResponseFormat? responseFormat;

  /// The timeout of the call.
  final Duration timeout;

  /// Headers to add to the request of the call.
  final List<MapEntry<String, String>> customHeaders;
}

/// The options of one call of a model made with [config], with [boundTools]
/// bound: the config's common settings, then the bound tools with the tool
/// choice `allowed` (Go's `WithTools`/`BindTools`), then [options].
@internal
ChatModelOptions claudeCallOptions(
  ClaudeConfig config,
  List<ToolInfo>? boundTools,
  ChatModelOptions? options,
) {
  final hasTools = boundTools != null && boundTools.isNotEmpty;
  return ChatModelOptions(
    model: config.model,
    maxTokens: config.maxTokens,
    temperature: config.temperature,
    topP: config.topP,
    stop: config.stopSequences,
    tools: hasTools ? boundTools : null,
    toolChoice: hasTools ? ToolChoice.allowed : null,
  ).merge(options);
}

// ---------------------------------------------------------------------------
// Request
// ---------------------------------------------------------------------------

/// One request to the Messages API.
@internal
@immutable
final class ClaudeRequest {
  /// A request.
  const ClaudeRequest({
    required this.url,
    required this.headers,
    required this.body,
    required this.timeout,
  });

  /// `{baseUrl}/v1/messages`.
  final Uri url;

  /// The headers.
  final Map<String, String> headers;

  /// The JSON body.
  final Map<String, Object?> body;

  /// The timeout of the call.
  final Duration timeout;
}

/// The request for [input] with [options] (see [claudeCallOptions]).
///
/// Port of eino-ext claude's `genParamsAndOptions`. Throws a
/// `ThreepioFormatException` for input messages the API cannot take and an
/// [ArgumentError] for a tool choice that does not fit the tools.
@internal
ClaudeRequest buildClaudeRequest(
  ClaudeConfig config,
  List<Message> input,
  ChatModelOptions options, {
  required bool stream,
}) {
  if (input.isEmpty) throw const ThreepioFormatException('input is empty');

  final (system, messages) = _preProcessMessages(input);
  final spec = ResolvedClaudeOptions.of(config, options);

  final body = <String, Object?>{
    'model': options.model ?? config.model,
    'max_tokens': options.maxTokens ?? config.maxTokens,
  };
  final temperature = options.temperature ?? config.temperature;
  if (temperature != null) body['temperature'] = temperature;
  final topP = options.topP ?? config.topP;
  if (topP != null) body['top_p'] = topP;
  final stop = options.stop ?? config.stopSequences;
  if (stop != null && stop.isNotEmpty) body['stop_sequences'] = stop;
  if (spec.topK != null) body['top_k'] = spec.topK;
  if (spec.thinkingConfig != null) {
    body['thinking'] = spec.thinkingConfig!.toJson();
  }
  if (spec.responseFormat != null) {
    body['output_config'] = {'format': spec.responseFormat!.toJson()};
  }

  _populateTools(body, options, spec, config.toolSearchAlgorithm);
  _populateInput(body, system, messages, spec);
  populateClaudeToolSearchResultTools(body, messages);

  final additional = config.additionalRequestFields;
  if (additional != null) {
    for (final entry in additional.entries) {
      claudeSetJsonPath(body, entry.key, entry.value);
    }
  }
  // As anthropic-sdk-go's NewStreaming, which sets it after the client's
  // options.
  if (stream) body['stream'] = true;

  return ClaudeRequest(
    url: Uri.parse('${_trimTrailingSlash(config.baseUrl)}/v1/messages'),
    headers: claudeHeaders(config, spec, stream: stream),
    body: body,
    timeout: spec.timeout,
  );
}

/// The headers of a request.
///
/// `x-api-key` and `Authorization: Bearer` as anthropic-sdk-go's
/// `WithAPIKey`/`WithAuthToken`, the `anthropic-version` it sends, then the
/// config's additional headers and the call's custom headers, added as
/// `WithHeaderAdd` adds them: a header that is already set gets the value
/// appended, comma-separated.
@internal
Map<String, String> claudeHeaders(
  ClaudeConfig config,
  ResolvedClaudeOptions spec, {
  required bool stream,
}) {
  final headers = <String, String>{
    'content-type': 'application/json',
    'accept': stream ? 'text/event-stream' : 'application/json',
    'anthropic-version': claudeApiVersion,
  };
  final apiKey = config.apiKey;
  if (apiKey != null && apiKey.isNotEmpty) headers['x-api-key'] = apiKey;
  final authToken = config.authToken;
  if (authToken != null && authToken.isNotEmpty) {
    headers['authorization'] = 'Bearer $authToken';
  }
  void add(String name, String value) {
    final key = name.toLowerCase();
    final existing = headers[key];
    headers[key] = existing == null ? value : '$existing, $value';
  }

  config.additionalHeaderFields?.forEach(add);
  for (final header in spec.customHeaders) {
    add(header.key, header.value);
  }
  return headers;
}

/// Sets [value] at [path] in [body], as `option.WithJSONSet` (sjson) does.
///
/// A dot separates the keys; `\` makes the next character part of the key
/// (`\.` is a dot in a key), and a key that starts with `:` is always an
/// object key. In a list, an integer key is an index (past the end, the list
/// is padded with `null`s) and `-1` appends; another key throws an
/// [ArgumentError], as sjson fails. Where the path does not exist yet, a
/// list is created when the next key is an integer or `-1`, an object
/// otherwise; a scalar on the way is replaced the same way. The objects and
/// lists on the way are copied, so maps and lists of the caller (a response
/// format's schema) and constant ones are never changed.
@internal
void claudeSetJsonPath(Map<String, Object?> body, String path, Object? value) {
  final segments = _jsonPathSegments(path);
  final first = segments.first.key;
  body[first] = _setAtPath(body[first], segments, 1, value, path);
}

Object? _setAtPath(
  Object? current,
  List<_JsonPathSegment> segments,
  int position,
  Object? value,
  String path,
) {
  if (position == segments.length) return value;
  final segment = segments[position];
  Object? rest(Object? next) =>
      _setAtPath(next, segments, position + 1, value, path);

  if (current is List) {
    final copy = List<Object?>.of(current);
    if (segment.appends) {
      copy.add(rest(null));
      return copy;
    }
    final index = segment.index;
    if (index == null) {
      throw ArgumentError.value(
        path,
        'path',
        "cannot set array element for non-numeric key '${segment.key}'",
      );
    }
    while (copy.length < index) {
      copy.add(null);
    }
    if (index == copy.length) {
      copy.add(rest(null));
    } else {
      copy[index] = rest(copy[index]);
    }
    return copy;
  }
  if (current is Map) {
    final copy = Map<String, Object?>.of(current.cast<String, Object?>());
    copy[segment.key] = rest(copy[segment.key]);
    return copy;
  }
  // Nothing there yet (or a scalar): built as sjson's appendBuild does.
  final index = segment.index;
  if (index != null || segment.appends) {
    return <Object?>[
      for (var i = 0; i < (index ?? 0); i++) null,
      rest(null),
    ];
  }
  return <String, Object?>{segment.key: rest(null)};
}

/// One key of an sjson path.
final class _JsonPathSegment {
  _JsonPathSegment(this.key, {required this.forced});

  final String key;

  /// Whether the key was written with a leading `:`: always an object key.
  final bool forced;

  /// The array index the key stands for, or `null`.
  int? get index {
    if (forced || key.isEmpty) return null;
    for (var i = 0; i < key.length; i++) {
      final unit = key.codeUnitAt(i);
      if (unit < 0x30 || unit > 0x39) return null;
    }
    return int.parse(key);
  }

  /// Whether the key is `-1`, which appends to an array.
  bool get appends => !forced && key == '-1';
}

List<_JsonPathSegment> _jsonPathSegments(String path) {
  final segments = <_JsonPathSegment>[];
  final key = StringBuffer();
  var forced = false;
  var atStart = true;
  for (var i = 0; i < path.length; i++) {
    final char = path[i];
    if (atStart && char == ':') {
      forced = true;
      atStart = false;
      continue;
    }
    atStart = false;
    if (char == r'\' && i + 1 < path.length) {
      key.write(path[i + 1]);
      i++;
    } else if (char == '.') {
      segments.add(_JsonPathSegment(key.toString(), forced: forced));
      key.clear();
      forced = false;
      atStart = true;
    } else {
      key.write(char);
    }
  }
  segments.add(_JsonPathSegment(key.toString(), forced: forced));
  return segments;
}

String _trimTrailingSlash(String url) {
  var end = url.length;
  while (end > 0 && url[end - 1] == '/') {
    end--;
  }
  return url.substring(0, end);
}

/// Port of eino-ext claude's `preProcessMessages`: the leading system
/// messages and the rest, which must start with a user message.
(List<Message>, List<Message>) _preProcessMessages(List<Message> input) {
  var firstNonSystem = 0;
  for (var i = 0; i < input.length; i++) {
    if (input[i].role != RoleType.system) {
      firstNonSystem = i;
      break;
    }
    if (i == input.length - 1) {
      throw const ThreepioFormatException(
        'only system message in input, require at least 1 user message',
      );
    }
  }
  if (input[firstNonSystem].role != RoleType.user) {
    throw const ThreepioFormatException(
      'first non-system message should be user message',
    );
  }
  return (
    input.sublist(0, firstNonSystem),
    input.sublist(firstNonSystem),
  );
}

/// Port of eino-ext claude's `populateInput`.
void _populateInput(
  Map<String, Object?> body,
  List<Message> system,
  List<Message> messages,
  ResolvedClaudeOptions spec,
) {
  final systemBlocks = <Map<String, Object?>>[];
  var hasSystemBreakpoint = false;
  for (final message in system) {
    final block = <String, Object?>{'type': 'text', 'text': message.content};
    if (claudeIsBreakpoint(message.extra)) {
      hasSystemBreakpoint = true;
      block['cache_control'] =
          claudeCacheControlParam(claudeBreakpointCacheControl(message.extra));
    }
    systemBlocks.add(block);
  }
  // Without a breakpoint of its own, the last system message gets one.
  final auto = spec.autoCacheControl;
  if (systemBlocks.isNotEmpty && !hasSystemBreakpoint && auto != null) {
    systemBlocks.last['cache_control'] = claudeCacheControlParam(auto);
  }
  if (systemBlocks.isNotEmpty) body['system'] = systemBlocks;

  var params = <Map<String, Object?>>[];
  var hasMessageBreakpoint = false;
  for (final message in messages) {
    final param = claudeMessageParam(message);
    final content = _content(param);
    if (content.isNotEmpty && content.last['cache_control'] != null) {
      hasMessageBreakpoint = true;
    }
    params.add(param);
  }

  params = claudeMergeAdjacentToolResults(params);
  params = claudeMergeAdjacentSystemMessages(params);

  if (!hasMessageBreakpoint && auto != null) {
    populateClaudeBlockBreakpoint(_content(params.last).last, auto);
  }
  body['messages'] = params;
}

List<Map<String, Object?>> _content(Map<String, Object?> param) =>
    param['content']! as List<Map<String, Object?>>;

/// Merges neighbouring user messages that hold only `tool_result` blocks,
/// because the API wants all the tool results of a turn in one message.
///
/// Port of eino-ext claude's `mergeAdjacentToolResults`.
@internal
List<Map<String, Object?>> claudeMergeAdjacentToolResults(
  List<Map<String, Object?>> params,
) {
  if (params.length <= 1) return params;
  final result = <Map<String, Object?>>[];
  for (final param in params) {
    if (result.isNotEmpty &&
        _isToolResultMessage(param) &&
        _isToolResultMessage(result.last)) {
      result.last['content'] = [..._content(result.last), ..._content(param)];
    } else {
      result.add({...param, 'content': [..._content(param)]});
    }
  }
  return result;
}

/// Merges neighbouring system messages, because the API allows a system
/// message only right before a user or assistant message.
///
/// Port of eino-ext claude's `mergeAdjacentSystemMessages`.
@internal
List<Map<String, Object?>> claudeMergeAdjacentSystemMessages(
  List<Map<String, Object?>> params,
) {
  if (params.length <= 1) return params;
  final result = <Map<String, Object?>>[];
  for (final param in params) {
    if (result.isNotEmpty &&
        param['role'] == 'system' &&
        result.last['role'] == 'system') {
      result.last['content'] = [..._content(result.last), ..._content(param)];
    } else {
      result.add({...param, 'content': [..._content(param)]});
    }
  }
  return result;
}

/// Port of eino-ext claude's `isToolResultMessage`.
bool _isToolResultMessage(Map<String, Object?> param) {
  if (param['role'] != 'user') return false;
  final content = _content(param);
  return content.isNotEmpty &&
      content.every((block) => block['type'] == 'tool_result');
}

/// Port of eino-ext claude's `populateTools`, tool choice included.
void _populateTools(
  Map<String, Object?> body,
  ChatModelOptions options,
  ResolvedClaudeOptions spec,
  ClaudeToolSearchAlgorithm? configAlgorithm,
) {
  final tools = <Map<String, Object?>>[];
  final optionTools = options.tools;
  if (optionTools != null) tools.addAll(claudeToolParams(optionTools));

  var algorithm = configAlgorithm;
  final deferred = options.deferredTools;
  if (deferred != null && deferred.isNotEmpty) {
    tools.addAll(claudeToolParams(deferred, deferLoading: true));
    // With deferred tools, BM25 search is the default.
    algorithm ??= ClaudeToolSearchAlgorithm.bm25;
  }
  if (algorithm != null) {
    tools.add({'type': algorithm.toolType, 'name': algorithm.toolName});
  }

  final searchTool = options.toolSearchTool;
  if (searchTool != null) tools.addAll(claudeToolParams([searchTool]));

  final auto = spec.autoCacheControl;
  if (tools.isNotEmpty && auto != null) {
    final hasBreakpoint = tools.any((tool) => tool['cache_control'] != null);
    // Without a breakpoint of its own, the last custom tool gets one.
    if (!hasBreakpoint) {
      for (var i = tools.length - 1; i >= 0; i--) {
        if (_isCustomTool(tools[i])) {
          tools[i]['cache_control'] = claudeCacheControlParam(auto);
          break;
        }
      }
    }
  }

  if (tools.isNotEmpty) body['tools'] = tools;

  populateClaudeToolChoice(
    body,
    options.toolChoice,
    options.allowedToolNames,
    disableParallelToolUse: spec.disableParallelToolUse,
  );
}

/// A tool defined by the caller (Go: `ToolUnionParam.OfTool`), as opposed to
/// a server tool, which has a `type`.
bool _isCustomTool(Map<String, Object?> tool) => !tool.containsKey('type');

/// The tool definitions of [tools].
///
/// Port of eino-ext claude's `toAnthropicToolParam` and, with
/// [deferLoading], `toAnthropicDeferredToolParam`. As in Go, the input
/// schema keeps the properties and the required names of the tool's schema
/// and is always of type `object`.
@internal
List<Map<String, Object?>> claudeToolParams(
  List<ToolInfo> tools, {
  bool deferLoading = false,
}) =>
    [
      for (final tool in tools)
        {
          'name': tool.name,
          'description': tool.desc ?? '',
          'input_schema': _inputSchema(tool),
          if (claudeIsBreakpoint(tool.extra))
            'cache_control': claudeCacheControlParam(
              claudeBreakpointCacheControl(tool.extra),
            ),
          if (deferLoading) 'defer_loading': true,
        },
    ];

Map<String, Object?> _inputSchema(ToolInfo tool) {
  final schema = tool.function.parameters;
  if (schema == null) return {'type': 'object'};
  return {
    'type': 'object',
    'properties': {
      for (final entry in schema.properties.entries)
        entry.key: _property(entry.value),
    },
    if (schema.required.isNotEmpty) 'required': [...schema.required],
  };
}

Map<String, Object?> _property(JSONSchemaProperty property) => {
      'type': property.type,
      if (property.description != null) 'description': property.description,
      if (property.enumValues != null) 'enum': property.enumValues,
      if (property.items != null) 'items': _property(property.items!),
      if (property.properties != null)
        'properties': {
          for (final entry in property.properties!.entries)
            entry.key: _property(entry.value),
        },
      if (property.required != null && property.required!.isNotEmpty)
        'required': property.required,
      if (property.additionalProperties != null)
        'additionalProperties': property.additionalProperties,
    };

/// Sets the request's `tool_choice` for [choice].
///
/// Port of eino-ext claude's `populateToolChoice`: `forbidden` is `none`,
/// `allowed` is `auto` (which cannot be limited to [allowedToolNames]),
/// `forced` is `tool` when one tool is named or there is only one, and `any`
/// otherwise. [disableParallelToolUse] goes with `auto` and `any`. Call it
/// after the `tools` of [body] are set.
@internal
void populateClaudeToolChoice(
  Map<String, Object?> body,
  ToolChoice? choice,
  List<String>? allowedToolNames, {
  bool? disableParallelToolUse,
}) {
  if (choice == null) return;
  final allowed = allowedToolNames ?? const <String>[];

  switch (choice) {
    case ToolChoice.forbidden:
      body['tool_choice'] = {'type': 'none'};
    case ToolChoice.allowed:
      if (allowed.isNotEmpty) {
        throw ArgumentError(
          "tool_choice 'allowed' is not supported when allowed tool names "
          'are present',
        );
      }
      body['tool_choice'] = {
        'type': 'auto',
        if (disableParallelToolUse != null)
          'disable_parallel_tool_use': disableParallelToolUse,
      };
    case ToolChoice.forced:
      final tools = body['tools'] as List<Map<String, Object?>>? ?? const [];
      if (tools.isEmpty) {
        throw ArgumentError('tool choice is forced but tool is not provided');
      }
      String? onlyOneToolName;
      if (allowed.isNotEmpty) {
        if (allowed.length > 1) {
          throw ArgumentError('only one allowed tool name can be configured');
        }
        final name = allowed.single;
        final names = {
          for (final tool in tools)
            if (tool['name'] is String) tool['name']! as String,
        };
        if (!names.contains(name)) {
          throw ArgumentError(
            "allowed tool name '$name' not found in tools list",
          );
        }
        onlyOneToolName = name;
      } else if (tools.length == 1) {
        onlyOneToolName = tools.single['name'] as String?;
      }

      if (onlyOneToolName != null && onlyOneToolName.isNotEmpty) {
        body['tool_choice'] = {'type': 'tool', 'name': onlyOneToolName};
      } else {
        body['tool_choice'] = {
          'type': 'any',
          if (disableParallelToolUse != null)
            'disable_parallel_tool_use': disableParallelToolUse,
        };
      }
  }
}

/// Adds the tools found by the tool searches in the tool messages of
/// [messages] to the `tools` of [body], deferred.
///
/// Port of eino-ext claude's `populateToolSearchResultTools`. Throws a
/// `ThreepioFormatException` when such a tool has the name of a tool that is
/// already there.
@internal
void populateClaudeToolSearchResultTools(
  Map<String, Object?> body,
  List<Message> messages,
) {
  final tools = [
    ...?body['tools'] as List<Map<String, Object?>>?,
  ];
  final names = {
    for (final tool in tools)
      if (tool['name'] is String) tool['name']! as String,
  };
  var added = false;
  for (final message in messages) {
    if (message.role != RoleType.tool) continue;
    for (final part
        in message.userInputMultiContent ?? const <MessageInputPart>[]) {
      final result = part.toolSearchResult;
      if (part.type != ChatMessagePartType.toolSearchResult ||
          result == null) {
        continue;
      }
      for (final tool in result.tools) {
        if (!names.add(tool.name)) {
          throw ThreepioFormatException(
            "tool '${tool.name}' from ToolSearchResult already exists in "
            'tool list',
          );
        }
      }
      tools.addAll(claudeToolParams(result.tools, deferLoading: true));
      added = true;
    }
  }
  if (added) body['tools'] = tools;
}

/// A `cache_control` object for [control].
///
/// Port of eino-ext claude's `newCacheControlParam`: always ephemeral, with
/// the TTL of [control] when it has one.
@internal
Map<String, Object?> claudeCacheControlParam(ClaudeCacheControl? control) {
  final ttl = control?.ttl?.value;
  return {
    'type': 'ephemeral',
    if (ttl != null && ttl.isNotEmpty) 'ttl': ttl,
  };
}

/// Puts a cache breakpoint on [block] when it is a text, image, tool result
/// or tool use block; other blocks are left as they are.
///
/// Port of eino-ext claude's `populateContentBlockBreakPoint`.
@internal
void populateClaudeBlockBreakpoint(
  Map<String, Object?> block,
  ClaudeCacheControl? control,
) {
  switch (block['type']) {
    case 'text' || 'image' || 'tool_result' || 'tool_use':
      block['cache_control'] = claudeCacheControlParam(control);
  }
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

/// The Go name of a part type, for error messages.
String _partTypeName(ChatMessagePartType type) => switch (type) {
      ChatMessagePartType.text => 'text',
      ChatMessagePartType.imageUrl => 'image_url',
      ChatMessagePartType.audioUrl => 'audio_url',
      ChatMessagePartType.videoUrl => 'video_url',
      ChatMessagePartType.fileUrl => 'file_url',
      ChatMessagePartType.reasoning => 'reasoning',
      ChatMessagePartType.toolSearchResult => 'tool_search_result',
    };

/// [message] as a message of the request: `{"role": …, "content": [...]}`.
///
/// Port of eino-ext claude's `convSchemaMessage`. Assistant messages start
/// with their thinking (when it has a signature) and their tool search
/// events; tool messages become `user` messages with a `tool_result`;
/// system messages keep the role `system`. Throws a
/// `ThreepioFormatException` for content the API cannot take.
@internal
Map<String, Object?> claudeMessageParam(Message message) {
  final blocks = <Map<String, Object?>>[];

  if (message.role == RoleType.assistant) {
    final thinking = message.claudeThinking;
    if (thinking != null && thinking.isNotEmpty) {
      final signature = claudeThinkingSignatureOf(message.extra);
      if (signature != null && signature.isNotEmpty) {
        blocks.add({
          'type': 'thinking',
          'signature': signature,
          'thinking': thinking,
        });
      }
    }
    for (final event in message.claudeToolSearchEvents) {
      blocks.add(_toolSearchEventBlock(event));
    }
  }

  final userParts =
      message.userInputMultiContent ?? const <MessageInputPart>[];
  final assistantParts =
      message.assistantGenMultiContent ?? const <MessageOutputPart>[];
  if (userParts.isNotEmpty && assistantParts.isNotEmpty) {
    throw const ThreepioFormatException(
      'a message cannot contain both UserInputMultiContent and '
      'AssistantGenMultiContent',
    );
  }

  if (userParts.isNotEmpty) {
    if (message.role != RoleType.user && message.role != RoleType.tool) {
      throw ThreepioFormatException(
        'user input multi content only support user role, got '
        '${message.role.name}',
      );
    }
    final toolCallId = message.toolCallId ?? '';
    if (message.role == RoleType.tool) {
      final hasToolSearchResult = userParts
          .any((part) => part.type == ChatMessagePartType.toolSearchResult);
      if (hasToolSearchResult) {
        for (final part in userParts) {
          if (part.type != ChatMessagePartType.toolSearchResult) continue;
          final result = part.toolSearchResult;
          if (result == null) {
            throw const ThreepioFormatException(
              'ToolSearchResult field must not be nil when Type is '
              'ChatMessagePartTypeToolSearchResult',
            );
          }
          blocks.add({
            'type': 'tool_result',
            'tool_use_id': toolCallId,
            'content': [
              for (final tool in result.tools)
                {'type': 'tool_reference', 'tool_name': tool.name},
            ],
          });
        }
      } else {
        blocks.add(_toolMultiContent(toolCallId, userParts));
      }
    } else {
      for (final part in userParts) {
        final fileBlock = _fileIdContentBlock(part);
        if (fileBlock != null) {
          blocks.add(fileBlock);
          continue;
        }
        switch (part.type) {
          case ChatMessagePartType.text:
            blocks.add({'type': 'text', 'text': part.text ?? ''});
          case ChatMessagePartType.imageUrl:
            final image = part.image;
            if (image == null) {
              throw const ThreepioFormatException(
                'image field must not be nil when Type is '
                'ChatMessagePartTypeImageURL in user message',
              );
            }
            blocks.add(_imageBlock(image.common));
          case ChatMessagePartType.audioUrl ||
                ChatMessagePartType.videoUrl ||
                ChatMessagePartType.fileUrl ||
                ChatMessagePartType.reasoning ||
                ChatMessagePartType.toolSearchResult:
            throw ThreepioFormatException(
              'anthropic message type not supported: '
              '${_partTypeName(part.type)}',
            );
        }
      }
    }
  } else if (assistantParts.isNotEmpty) {
    if (message.role != RoleType.assistant) {
      throw ThreepioFormatException(
        'assistant gen multi content only support assistant role, got '
        '${message.role.name}',
      );
    }
    for (final part in assistantParts) {
      switch (part.type) {
        case ChatMessagePartType.text:
          blocks.add({'type': 'text', 'text': part.text ?? ''});
        case ChatMessagePartType.imageUrl:
          final image = part.image;
          if (image == null) {
            throw const ThreepioFormatException(
              'image field must not be nil when Type is '
              'ChatMessagePartTypeImageURL in assistant message',
            );
          }
          blocks.add(_imageBlock(image));
        case ChatMessagePartType.audioUrl ||
              ChatMessagePartType.videoUrl ||
              ChatMessagePartType.fileUrl ||
              ChatMessagePartType.reasoning ||
              ChatMessagePartType.toolSearchResult:
          throw ThreepioFormatException(
            'anthropic message type not supported: '
            '${_partTypeName(part.type)}',
          );
      }
    }
  } else if (message.content.isNotEmpty) {
    if (message.role == RoleType.tool) {
      // anthropic.NewToolResultBlock(id, content, false)
      blocks.add({
        'type': 'tool_result',
        'tool_use_id': message.toolCallId ?? '',
        'content': [
          {'type': 'text', 'text': message.content},
        ],
        'is_error': false,
      });
    } else {
      blocks.add({'type': 'text', 'text': message.content});
    }
  }

  for (final call in message.toolCalls ?? const <ToolCall>[]) {
    final arguments =
        call.function.arguments.isEmpty ? '{}' : call.function.arguments;
    final Object? input;
    try {
      input = jsonDecode(arguments);
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        "arguments of tool call '${call.id}' are not valid JSON: "
        '${error.message}',
        source: arguments,
        cause: error,
      );
    }
    blocks.add({
      'type': 'tool_use',
      'id': call.id,
      'input': input,
      'name': call.function.name,
    });
  }

  if (blocks.isNotEmpty && claudeIsBreakpoint(message.extra)) {
    populateClaudeBlockBreakpoint(
      blocks.last,
      claudeBreakpointCacheControl(message.extra),
    );
  }
  // An empty message is sent as one with empty text, as in Go.
  if (blocks.isEmpty) blocks.add({'type': 'text', 'text': ''});

  return {
    'role': switch (message.role) {
      RoleType.assistant => 'assistant',
      RoleType.system => 'system',
      RoleType.user || RoleType.tool => 'user',
    },
    'content': blocks,
  };
}

/// Port of eino-ext claude's `restoreToolSearchEventBlock`.
Map<String, Object?> _toolSearchEventBlock(ClaudeToolSearchEvent event) {
  switch (event.type) {
    case ClaudeToolSearchEventType.serverToolUse:
      return {
        'type': 'server_tool_use',
        'id': event.id,
        'name': event.name,
        'input': event.input ?? const <String, Object?>{},
      };
    case ClaudeToolSearchEventType.toolSearchToolResult:
      final content = event.content;
      return {
        'type': 'tool_search_tool_result',
        'tool_use_id': event.toolUseId,
        if (content != null)
          'content': content.type == 'tool_search_tool_search_result'
              ? {
                  'type': 'tool_search_tool_search_result',
                  'tool_references': [
                    for (final ref in content.toolReferences)
                      {'type': 'tool_reference', 'tool_name': ref.toolName},
                  ],
                }
              : {
                  'type': 'tool_search_tool_result_error',
                  'error_code': content.errorCode,
                },
      };
  }
}

/// An image block for [common]: by URL, else as base64 data.
Map<String, Object?> _imageBlock(MessagePartCommon common) {
  final url = common.url;
  if (url != null && url.isNotEmpty) {
    return {
      'type': 'image',
      'source': {'type': 'url', 'url': url},
    };
  }
  final data = common.base64Data;
  if (data != null && data.isNotEmpty) {
    final mimeType = common.mimeType ?? '';
    if (mimeType.isEmpty) {
      throw const ThreepioFormatException(
        'image part must have MIMEType when use Base64Data',
      );
    }
    if (data.startsWith('data:')) {
      throw const ThreepioFormatException(
        "Base64Data should be a raw base64 string, but it has a 'data:' "
        'prefix',
      );
    }
    return {
      'type': 'image',
      'source': {'type': 'base64', 'media_type': mimeType, 'data': data},
    };
  }
  throw const ThreepioFormatException(
    'image part must have either a URL or Base64Data',
  );
}

/// Port of eino-ext claude's `convToolMultiContent`: a `tool_result` with
/// text, images and files.
Map<String, Object?> _toolMultiContent(
  String toolCallId,
  List<MessageInputPart> parts,
) {
  final content = <Map<String, Object?>>[];
  for (final part in parts) {
    final fileBlock = _fileIdContentBlock(part);
    if (fileBlock != null) {
      content.add(fileBlock);
      continue;
    }
    switch (part.type) {
      case ChatMessagePartType.text:
        content.add({'type': 'text', 'text': part.text ?? ''});
      case ChatMessagePartType.imageUrl:
        final image = part.image;
        if (image == null) {
          // Go's message, which says "assistant" here too.
          throw const ThreepioFormatException(
            'image field must not be nil when Type is '
            'ChatMessagePartTypeImageURL in assistant message',
          );
        }
        content.add(_imageBlock(image.common));
      case ChatMessagePartType.audioUrl ||
            ChatMessagePartType.videoUrl ||
            ChatMessagePartType.fileUrl ||
            ChatMessagePartType.reasoning ||
            ChatMessagePartType.toolSearchResult:
        throw ThreepioFormatException(
          'anthropic message type not supported: '
          '${_partTypeName(part.type)}',
        );
    }
  }
  return {'type': 'tool_result', 'tool_use_id': toolCallId, 'content': content};
}

/// An image or document block that refers to a file uploaded to the Files
/// API, or `null` when [part] has a URL or data (which take precedence) or
/// no file id.
///
/// Port of eino-ext claude's `fileIDContentBlock`.
Map<String, Object?>? _fileIdContentBlock(MessageInputPart part) {
  final MessagePartCommon common;
  final String blockType;
  if (part.type == ChatMessagePartType.imageUrl && part.image != null) {
    common = part.image!.common;
    blockType = 'image';
  } else if (part.type == ChatMessagePartType.fileUrl && part.file != null) {
    common = part.file!.common;
    blockType = 'document';
  } else {
    return null;
  }
  final url = common.url;
  final data = common.base64Data;
  final fileId = common.fileId;
  if ((url != null && url.isNotEmpty) ||
      (data != null && data.isNotEmpty) ||
      fileId == null) {
    return null;
  }
  if (fileId.isEmpty) {
    throw const ThreepioFormatException('FileID must not be empty');
  }
  return {
    'type': blockType,
    'source': {'type': 'file', 'file_id': fileId},
  };
}

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

/// The token usage of an Anthropic `usage` object.
///
/// Port of eino-ext claude's `toTokenUsage` and `toDeltaTokenUsage`: the
/// prompt tokens are the input tokens plus those read from and written to
/// the cache; the reads are `cachedTokens`, the writes `cacheWriteTokens`;
/// `output_tokens_details.thinking_tokens` are the reasoning tokens.
@internal
TokenUsage claudeTokenUsage(Map<String, Object?>? usage) {
  final input = _int(usage?['input_tokens']);
  final cacheRead = _int(usage?['cache_read_input_tokens']);
  final cacheCreation = _int(usage?['cache_creation_input_tokens']);
  final output = _int(usage?['output_tokens']);
  final thinking =
      _int(_map(usage?['output_tokens_details'])?['thinking_tokens']);
  final prompt = input + cacheRead + cacheCreation;
  return TokenUsage(
    promptTokens: prompt,
    completionTokens: output,
    totalTokens: prompt + output,
    promptTokenDetails: PromptTokenDetails(
      cachedTokens: cacheRead,
      cacheWriteTokens: cacheCreation,
    ),
    completionTokenDetails: CompletionTokenDetails(reasoningTokens: thinking),
  );
}

/// The assistant message of a Messages API response.
///
/// Port of eino-ext claude's `convOutputMessage`. Throws a
/// `ThreepioFormatException` for content blocks it does not know, as Go does.
@internal
Message claudeOutputMessage(Map<String, Object?> response) =>
    ClaudeStreamConverter()._outputMessage(response);

/// Whether [message] carries nothing a reader would see: no content, no tool
/// calls and no thinking. Such stream chunks are held back and joined with
/// the next one.
///
/// Port of eino-ext claude's `isMessageEmpty`.
@internal
bool isClaudeMessageEmpty(Message message) =>
    message.content.isEmpty &&
    (message.toolCalls?.isEmpty ?? true) &&
    (message.assistantGenMultiContent?.isEmpty ?? true) &&
    !claudeHasThinking(message.extra);

/// Turns the events of one stream into message chunks.
///
/// Port of eino-ext claude's `convStreamEvent` with its `streamContext`. A
/// started `tool_use` block gets the next tool call index; its
/// `input_json_delta` fragments carry the same index and an empty type, so
/// that `concatMessages` joins them.
@internal
final class ClaudeStreamConverter {
  /// A converter for a new stream.
  ClaudeStreamConverter();

  int? _toolIndex;

  /// The `server_tool_use` blocks being streamed, by block index.
  final Map<int, _PendingServerToolUse> _pendingServerToolUses = {};

  /// The chunk for [event] (the decoded `data` of a server-sent event), or
  /// `null` for an event that carries nothing.
  ///
  /// Throws a `ThreepioFormatException` for an event or block type it does
  /// not know.
  Message? convert(Map<String, Object?> event) {
    final type = event['type'];
    switch (type) {
      case 'message_start':
        return _outputMessage(_map(event['message']) ?? const {});

      case 'message_delta':
        final usage = _map(event['usage']);
        final extra = <String, dynamic>{};
        claudeSetCacheCreationInputTokens(
          extra,
          _int(usage?['cache_creation_input_tokens']),
        );
        return Message(
          role: RoleType.assistant,
          responseMeta: ResponseMeta(
            finishReason: _nonEmpty(_map(event['delta'])?['stop_reason']),
            usage: claudeTokenUsage(usage),
          ),
          extra: extra.isEmpty ? null : extra,
        );

      case 'message_stop':
        return null;

      case 'content_block_stop':
        final pending = _pendingServerToolUses.remove(_int(event['index']));
        if (pending == null) return null;
        final builder = _MessageBuilder();
        claudeAppendToolSearchEvent(builder.extra, pending.event());
        return builder.build();

      case 'content_block_start':
        final builder = _MessageBuilder();
        _contentBlock(
          _map(event['content_block']) ?? const {},
          builder,
          streamIndex: _int(event['index']),
        );
        return builder.build();

      case 'content_block_delta':
        final delta = _map(event['delta']) ?? const {};
        final builder = _MessageBuilder();
        switch (delta['type']) {
          case 'text_delta':
            builder.content.write(_string(delta['text']));
          case 'thinking_delta':
            final thinking = _string(delta['thinking']);
            claudeSetThinking(builder.extra, thinking);
            builder.reasoning = thinking;
          case 'input_json_delta':
            final partial = _string(delta['partial_json']);
            final pending = _pendingServerToolUses[_int(event['index'])];
            if (pending != null) {
              pending.input.write(partial);
              return null;
            }
            builder.toolCalls.add(_toolEvent(isStart: false, arguments: partial));
          case 'signature_delta':
            claudeSetThinkingSignature(
              builder.extra,
              _string(delta['signature']),
            );
        }
        return builder.build();

      default:
        throw ThreepioFormatException('unknown stream event type: $type');
    }
  }

  Message _outputMessage(Map<String, Object?> response) {
    final usage = _map(response['usage']);
    final builder = _MessageBuilder()
      ..responseMeta = ResponseMeta(
        finishReason: _nonEmpty(response['stop_reason']),
        usage: claudeTokenUsage(usage),
      );
    claudeSetCacheCreationInputTokens(
      builder.extra,
      _int(usage?['cache_creation_input_tokens']),
    );
    // The blocks of a whole message count their tool calls on their own.
    final blocks = ClaudeStreamConverter();
    for (final block in _list(response['content'])) {
      blocks._contentBlock(_map(block) ?? const {}, builder);
    }
    return builder.build();
  }

  /// Port of eino-ext claude's `convContentBlockToEinoMsg`. [streamIndex] is
  /// the index of the block in a stream, `null` for a whole message.
  void _contentBlock(
    Map<String, Object?> block,
    _MessageBuilder builder, {
    int? streamIndex,
  }) {
    final type = block['type'];
    switch (type) {
      case 'text':
        builder.content.write(_string(block['text']));
      case 'tool_use':
        builder.toolCalls.add(
          _toolEvent(
            isStart: true,
            id: _string(block['id']),
            name: _string(block['name']),
            arguments: _rawJson(block['input']),
          ),
        );
      case 'server_tool_use':
        final name = _string(block['name']);
        if (!name.contains('tool_search_tool_')) {
          throw ThreepioFormatException('server_tool_use not supported: $name');
        }
        final event = ClaudeToolSearchEvent(
          type: ClaudeToolSearchEventType.serverToolUse,
          id: _string(block['id']),
          name: name,
          input: block['input'],
        );
        if (streamIndex == null) {
          claudeAppendToolSearchEvent(builder.extra, event);
        } else {
          // Its input follows as input_json_delta fragments; the event is
          // complete at content_block_stop.
          _pendingServerToolUses[streamIndex] = _PendingServerToolUse(event);
        }
      case 'tool_search_tool_result':
        final content = _map(block['content']) ?? const {};
        claudeAppendToolSearchEvent(
          builder.extra,
          ClaudeToolSearchEvent(
            type: ClaudeToolSearchEventType.toolSearchToolResult,
            toolUseId: _string(block['tool_use_id']),
            content: ClaudeToolSearchEventContent(
              type: _string(content['type']),
              toolReferences: [
                for (final ref in _list(content['tool_references']))
                  ClaudeToolSearchEventToolReference(
                    _string(_map(ref)?['tool_name']),
                  ),
              ],
              errorCode: _string(content['error_code']),
              errorMessage: _string(content['error_message']),
            ),
          ),
        );
      case 'web_search_tool_result':
        throw const ThreepioFormatException('web_search tool not supported');
      case 'thinking':
        final thinking = _string(block['thinking']);
        claudeSetThinking(builder.extra, thinking);
        builder.reasoning = thinking;
        claudeSetThinkingSignature(builder.extra, _string(block['signature']));
      case 'redacted_thinking':
        // Dropped, as in Go.
        break;
      default:
        throw ThreepioFormatException(
          'unknown anthropic content block type: $type',
        );
    }
  }

  /// Port of eino-ext claude's `toolEvent`.
  ToolCall _toolEvent({
    required bool isStart,
    required String arguments,
    String id = '',
    String name = '',
  }) {
    final index = isStart ? (_toolIndex ?? -1) + 1 : (_toolIndex ?? 0);
    _toolIndex = index;
    return ToolCall(
      index: index,
      id: id,
      // The fragments that follow the first one carry no type, so that they
      // join it.
      type: isStart ? 'function' : '',
      function: FunctionCall(
        name: name,
        // Claude repeats "{}" for a call without arguments, which would not
        // concatenate.
        arguments: arguments == '{}' ? '' : arguments,
      ),
    );
  }
}

/// A streamed `server_tool_use` block whose input is still arriving.
final class _PendingServerToolUse {
  _PendingServerToolUse(this.start);

  final ClaudeToolSearchEvent start;
  final StringBuffer input = StringBuffer();

  ClaudeToolSearchEvent event() {
    final text = input.toString();
    if (text.isEmpty) return start;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        'server_tool_use input is not valid JSON: ${error.message}',
        source: text,
        cause: error,
      );
    }
    return ClaudeToolSearchEvent(
      type: start.type,
      id: start.id,
      name: start.name,
      input: decoded,
    );
  }
}

/// The parts of a message being built from response blocks.
final class _MessageBuilder {
  final StringBuffer content = StringBuffer();
  String? reasoning;
  final List<ToolCall> toolCalls = [];
  final Map<String, dynamic> extra = {};
  ResponseMeta? responseMeta;

  Message build() => Message(
        role: RoleType.assistant,
        content: content.toString(),
        reasoningContent: reasoning,
        toolCalls: toolCalls.isEmpty ? null : List.unmodifiable(toolCalls),
        responseMeta: responseMeta,
        extra: extra.isEmpty ? null : extra,
      );
}

Map<String, Object?>? _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : null;

List<Object?> _list(Object? value) =>
    value is List ? value.cast<Object?>() : const [];

String _string(Object? value) => value is String ? value : '';

String? _nonEmpty(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int _int(Object? value) => value is num ? value.toInt() : 0;

/// The JSON text of a block's `input` (Go keeps the raw JSON).
String _rawJson(Object? value) => value == null ? '' : jsonEncode(value);
