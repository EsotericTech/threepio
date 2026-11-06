/// The Messages API request of one call of `ClaudeAgenticModel`: body,
/// headers and timeout.
///
/// Port of the request half of eino-ext
/// `components/model/agenticclaude/model.go` (`getOptions`,
/// `genParamsAndOptions`, `populateTools`, `populateToolChoice`,
/// `appendCustomHeaders` and the server tool selection). Go fills an
/// anthropic-sdk-go `MessageNewParams` and request options; here the JSON
/// body and the headers are built directly, in the shape the SDK sends.
/// Everything here is internal to threepio.
library;

import 'package:meta/meta.dart';

import '../../../../errors.dart';
import '../../../../schema/agentic_message.dart';
import '../../../../schema/agentic_tool_choice.dart';
import '../../../../schema/tool_info.dart';
import '../../chat_model_options.dart';
import '../claude/claude_converters.dart'
    show claudeApiVersion, claudeCacheControlParam, claudeSetJsonPath;
import 'claude_agentic_config.dart';
import 'claude_agentic_consts.dart';
import 'claude_agentic_convertor.dart';
import 'claude_agentic_options.dart';
import 'claude_agentic_utils.dart';

/// The Claude-specific settings of one call: the config's values with the
/// [ClaudeAgenticOptions] of the call applied.
///
/// Port of eino-ext agenticclaude's `claudeOptions` as
/// `GetImplSpecificOptions` returns it, with the timeout resolved as
/// `genParamsAndOptions` does.
@internal
@immutable
final class ResolvedClaudeAgenticOptions {
  /// The settings of a call.
  const ResolvedClaudeAgenticOptions({
    required this.timeout,
    this.serverTools = const [],
    this.customHeaders,
    this.extraFields,
  });

  /// The settings of a call with [options] made with [config].
  factory ResolvedClaudeAgenticOptions.of(
    ClaudeAgenticConfig config,
    ChatModelOptions options,
  ) {
    var serverTools = const <ClaudeServerToolConfig>[];
    var customHeaders = config.customHeaders;
    var extraFields = config.extraFields;
    var timeout = config.requestTimeout;
    final all = options.extensions.whereType<ClaudeAgenticOptions>().toList();
    // The first one found wins, so they are applied from the last one on.
    for (final o in all.reversed) {
      serverTools = o.serverTools ?? serverTools;
      customHeaders = o.customHeaders ?? customHeaders;
      extraFields = o.extraFields ?? extraFields;
      final requestTimeout = o.requestTimeout;
      if (requestTimeout != null && requestTimeout > Duration.zero) {
        timeout = requestTimeout;
      }
    }
    return ResolvedClaudeAgenticOptions(
      timeout: timeout,
      serverTools: serverTools,
      customHeaders: customHeaders,
      extraFields: extraFields,
    );
  }

  /// The server tools of the call.
  final List<ClaudeServerToolConfig> serverTools;

  /// The custom headers of the call.
  final Map<String, String>? customHeaders;

  /// The extra body fields of the call.
  final Map<String, Object?>? extraFields;

  /// The timeout of the call.
  final Duration timeout;
}

/// One request to the Messages API.
@internal
@immutable
final class ClaudeAgenticRequest {
  /// A request.
  const ClaudeAgenticRequest({
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

/// The options of one call of a model made with [config]: the config's
/// model, token limit and stop sequences, then [options].
///
/// Port of the defaults of eino-ext agenticclaude `getOptions`
/// (`model.GetCommonOptions`).
@internal
ChatModelOptions claudeAgenticCallOptions(
  ClaudeAgenticConfig config,
  ChatModelOptions? options,
) => ChatModelOptions(
  model: config.model,
  maxTokens: config.maxTokens,
  stop: config.stopSequences,
).merge(options);

/// Throws an [ArgumentError] for the common options this model does not
/// take. Port of the checks of eino-ext agenticclaude `getOptions`.
@internal
void claudeAgenticCheckOptions(ChatModelOptions options) {
  if (options.toolChoice != null) {
    throw ArgumentError(
      "'ToolChoice' option is not supported, please use 'AgenticToolChoice'",
    );
  }
  final allowed = options.allowedToolNames;
  if (allowed != null && allowed.isNotEmpty) {
    throw ArgumentError(
      "'AllowedToolNames' option is not supported by AgenticClaude",
    );
  }
}

/// The request for [input] with [options] (see [claudeAgenticCallOptions]).
///
/// Port of eino-ext agenticclaude `getOptions` and `genParamsAndOptions`.
/// Throws an [ArgumentError] for options the model does not take and a tool
/// choice that does not fit the tools, and a [ThreepioFormatException] for
/// input messages or tools the API cannot take.
@internal
ClaudeAgenticRequest buildClaudeAgenticRequest(
  ClaudeAgenticConfig config,
  List<AgenticMessage> input,
  ChatModelOptions options, {
  required bool stream,
}) {
  claudeAgenticCheckOptions(options);
  final spec = ResolvedClaudeAgenticOptions.of(config, options);

  final body = <String, Object?>{
    'model': options.model ?? config.model,
    'max_tokens': options.maxTokens ?? config.maxTokens,
  };
  if (options.temperature != null) body['temperature'] = options.temperature;
  if (options.topP != null) body['top_p'] = options.topP;
  final stop = options.stop;
  if (stop != null && stop.isNotEmpty) body['stop_sequences'] = stop;
  final thinking = config.thinking;
  if (thinking != null) body['thinking'] = thinking.toJson();

  final ({
    List<Map<String, Object?>> system,
    List<Map<String, Object?>> messages,
  })
  converted;
  try {
    converted = claudeAgenticToAnthropicMessages(input);
  } on ThreepioFormatException catch (error) {
    throw ThreepioFormatException(
      'convert input messages failed: ${error.message}',
      cause: error,
    );
  }
  if (converted.system.isNotEmpty) body['system'] = converted.system;
  body['messages'] = converted.messages;

  final tools = claudeAgenticTools(options, spec.serverTools);
  if (tools.isNotEmpty) body['tools'] = tools;

  final toolChoice = claudeAgenticToolChoice(
    options.agenticToolChoice,
    tools,
    disableParallelToolUse: config.disableParallelToolUse,
  );
  if (toolChoice != null) body['tool_choice'] = toolChoice;

  final cacheControl = config.cacheControl;
  if (cacheControl != null) {
    body['cache_control'] = claudeCacheControlParam(cacheControl);
  }

  // anthropic-sdk-go's NewStreaming puts its `WithJSONSet("stream", true)`
  // in front of the request options, so the extra fields, set after it, can
  // override it.
  if (stream) body['stream'] = true;
  final extraFields = spec.extraFields;
  if (extraFields != null) {
    for (final entry in extraFields.entries) {
      claudeSetJsonPath(body, entry.key, entry.value);
    }
  }

  return ClaudeAgenticRequest(
    url: Uri.parse('${_trimTrailingSlash(config.baseUrl)}/v1/messages'),
    headers: claudeAgenticHeaders(config, spec, stream: stream),
    body: body,
    timeout: spec.timeout,
  );
}

/// The `tools` of a request: the function tools of [options], its deferred
/// tools (`defer_loading`), its tool search tool, then the selected
/// [serverTools].
///
/// Port of eino-ext agenticclaude `populateTools`. Throws a
/// [ThreepioFormatException] for a tool whose schema cannot be sent.
@internal
List<Map<String, Object?>> claudeAgenticTools(
  ChatModelOptions options,
  List<ClaudeServerToolConfig> serverTools,
) {
  List<Map<String, Object?>> convert(
    List<ToolInfo> tools,
    String what, {
    bool deferLoading = false,
  }) {
    try {
      return claudeAgenticFunctionTools(tools, deferLoading: deferLoading);
    } on ThreepioFormatException catch (error) {
      throw ThreepioFormatException(
        'convert call-time $what failed: ${error.message}',
        cause: error,
      );
    }
  }

  final searchTool = options.toolSearchTool;
  return [
    if (options.tools case final tools?) ...convert(tools, 'function tools'),
    if (options.deferredTools case final deferred?)
      ...convert(deferred, 'deferred tools', deferLoading: true),
    if (searchTool != null) ...convert([searchTool], 'tool search tool'),
    for (final tool in claudeAgenticSelectServerTools(serverTools))
      tool.toJson(),
  ];
}

/// The server tools to send: per tool version, the definition of the last
/// config that sets it, in a fixed order (web search, web fetch, code
/// execution, BM25 search, regex search).
///
/// Port of eino-ext agenticclaude `toServerTools`, `selectServerTools` and
/// `getSelectedServerToolParam`.
@internal
List<ClaudeServerTool> claudeAgenticSelectServerTools(
  List<ClaudeServerToolConfig> configs,
) {
  T? last<T extends ClaudeServerTool>(
    T? Function(ClaudeServerToolConfig config) field,
  ) {
    for (final config in configs.reversed) {
      final tool = field(config);
      if (tool != null) return tool;
    }
    return null;
  }

  return [
    ?last((c) => c.webSearch20260209),
    ?last((c) => c.webFetch20260309),
    ?last((c) => c.codeExecution20260120),
    ?last((c) => c.toolSearchToolBm25V20251119),
    ?last((c) => c.toolSearchToolRegex20251119),
  ];
}

/// The betas the selected server tools need: `web-fetch-2026-03-09` for
/// the web fetch tool. Port of eino-ext agenticclaude
/// `collectServerToolBetaHeaders`.
@internal
List<String> claudeAgenticServerToolBetas(
  List<ClaudeServerToolConfig> configs,
) => [
  for (final tool in claudeAgenticSelectServerTools(configs))
    if (tool is ClaudeWebFetchTool20260309) claudeAgenticBetaWebFetch20260309,
];

/// The values of a comma-separated header, trimmed, without empty ones and
/// duplicates, in their order. Port of eino-ext agenticclaude
/// `splitHeaderValues` (a set in Go).
@internal
Set<String> claudeAgenticSplitHeaderValues(String? header) => {
  for (final part in (header ?? '').split(','))
    if (part.trim().isNotEmpty) part.trim(),
};

/// The headers of a request.
///
/// `x-api-key` and `Authorization: Bearer` as anthropic-sdk-go's
/// `WithAPIKey`/`WithAuthToken`, the `anthropic-version` it sends, then, as
/// eino-ext agenticclaude `appendCustomHeaders`, the custom headers other
/// than `anthropic-beta` (added as `WithHeaderAdd` adds them: a header that
/// is already set gets the value appended, comma-separated) and the betas:
/// those of the custom `anthropic-beta` header and those the server tools
/// need, each once.
@internal
Map<String, String> claudeAgenticHeaders(
  ClaudeAgenticConfig config,
  ResolvedClaudeAgenticOptions spec, {
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

  // Every key that names `anthropic-beta`, whatever its case: Go matches the
  // lowercase key only and adds the others as they are (`WithHeaderAdd`), so
  // their values reach the API too.
  final customBetas = <String>[];
  spec.customHeaders?.forEach((name, value) {
    if (name.toLowerCase() == claudeAgenticHeaderAnthropicBeta) {
      customBetas.add(value);
    } else {
      add(name, value);
    }
  });
  final betas = <String>{
    for (final value in customBetas) ...claudeAgenticSplitHeaderValues(value),
    ...claudeAgenticServerToolBetas(spec.serverTools),
  };
  for (final beta in betas) {
    add(claudeAgenticHeaderAnthropicBeta, beta);
  }
  return headers;
}

/// The names [choice] narrows the tools to, each once, in their order.
///
/// Port of eino-ext agenticclaude `getAllowedToolNames`. Throws an
/// [ArgumentError] for an empty name and for MCP tools.
@internal
List<String> claudeAgenticAllowedToolNames(AgenticToolChoice choice) {
  final tools = switch (choice.type) {
    ToolChoice.allowed => choice.allowed?.tools ?? const <AllowedTool>[],
    ToolChoice.forced => choice.forced?.tools ?? const <AllowedTool>[],
    ToolChoice.forbidden => const <AllowedTool>[],
  };
  final names = <String>[];
  final seen = <String>{};
  for (final tool in tools) {
    final name = switch (tool) {
      AllowedServerTool(:final name) =>
        name.isEmpty ? throw ArgumentError('server tool name is empty') : name,
      AllowedMcpTool() => throw ArgumentError(
        'mcp tools are not supported yet',
      ),
      AllowedFunctionTool(:final name) =>
        name.isEmpty
            ? throw ArgumentError('allowed function tool name is empty')
            : name,
    };
    if (seen.add(name)) names.add(name);
  }
  return names;
}

/// The request's `tool_choice` for [choice] and the request's [tools], or
/// `null` when the call sets none.
///
/// Port of eino-ext agenticclaude `populateToolChoice`: `forbidden` is
/// `none`; `allowed` is `auto` (which cannot be narrowed to some tools);
/// `forced` is `tool` when one tool is named or there is only one, and `any`
/// otherwise. [disableParallelToolUse] goes with `auto`, `tool` and `any`.
/// Throws an [ArgumentError] when the choice does not fit the tools.
@internal
Map<String, Object?>? claudeAgenticToolChoice(
  AgenticToolChoice? choice,
  List<Map<String, Object?>> tools, {
  bool? disableParallelToolUse,
}) {
  if (choice == null) return null;
  final allowed = claudeAgenticAllowedToolNames(choice);
  final parallel = <String, Object?>{
    if (disableParallelToolUse != null)
      'disable_parallel_tool_use': disableParallelToolUse,
  };

  switch (choice.type) {
    case ToolChoice.forbidden:
      return {'type': 'none'};
    case ToolChoice.allowed:
      if (allowed.isNotEmpty) {
        throw ArgumentError(
          "tool choice 'allowed' with specific tools is not supported",
        );
      }
      return {'type': 'auto', ...parallel};
    case ToolChoice.forced:
      if (tools.isEmpty) {
        throw ArgumentError('tool choice is forced but no tools are provided');
      }
      if (allowed.length > 1) {
        throw ArgumentError(
          "tool choice 'forced' with multiple specific tools is not "
          'supported',
        );
      }
      var forced = '';
      if (allowed.length == 1) {
        forced = allowed.single;
      } else if (tools.length == 1) {
        forced = _toolName(tools.single);
      }
      if (forced.isNotEmpty) {
        if (!tools.any((tool) => _supportsForcedToolName(tool, forced))) {
          throw ArgumentError(
            'forced tool "$forced" is not found in the provided tools',
          );
        }
        return {'type': 'tool', 'name': forced, ...parallel};
      }
      return {'type': 'any', ...parallel};
  }
}

/// Port of eino-ext agenticclaude `getToolName`: every tool definition here
/// has its name (a server tool's is its fixed name).
String _toolName(Map<String, Object?> tool) {
  final name = tool['name'];
  return name is String ? name : '';
}

/// Port of eino-ext agenticclaude `supportsForcedToolName`: the code
/// execution tool also answers to its runtime names `bash_code_execution`
/// and `text_editor_code_execution`.
bool _supportsForcedToolName(Map<String, Object?> tool, String forced) {
  final name = _toolName(tool);
  if (name == forced) return true;
  if (forced != ClaudeServerToolName.bashCodeExecution.value &&
      forced != ClaudeServerToolName.textEditorCodeExecution.value) {
    return false;
  }
  return name == ClaudeServerToolName.codeExecution.value;
}

String _trimTrailingSlash(String url) {
  var end = url.length;
  while (end > 0 && url[end - 1] == '/') {
    end--;
  }
  return url.substring(0, end);
}
