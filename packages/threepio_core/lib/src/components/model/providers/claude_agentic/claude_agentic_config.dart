/// The configuration of `ClaudeAgenticModel` and the server tools it can
/// offer.
///
/// Port of eino-ext `components/model/agenticclaude/model.go` `Config` and
/// `ServerToolConfig`, and of the anthropic-sdk-go tool parameters they
/// take. **Beta**, as the whole agentic path is upstream.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../claude/claude_config.dart';
import '../claude/claude_converters.dart' show claudeCacheControlParam;
import 'claude_agentic_consts.dart';
import 'claude_agentic_utils.dart';

const _jsonEquality = DeepCollectionEquality();

/// The configuration of a `ClaudeAgenticModel`.
///
/// Port of eino-ext agenticclaude `Config` for the direct Anthropic API.
/// Not ported: `ByBedrock` and `ByGoogleVertexAI` (AWS SigV4 and Google
/// OAuth signing, plan §2.4) and `HTTPClient` (pass `httpClient` to the
/// model). Nothing is read from the environment: Go's SDK falls back to
/// `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL`;
/// here the values are given. [thinking] and [cacheControl] take the classic
/// Claude model's [ClaudeThinkingConfig] and [ClaudeCacheControl].
///
/// ```dart
/// const config = ClaudeAgenticConfig(
///   apiKey: apiKey,
///   model: 'claude-opus-5-5',
///   maxTokens: 16000,
///   thinking: ClaudeThinkingConfig.adaptive(),
/// );
/// ```
@immutable
final class ClaudeAgenticConfig {
  /// A configuration for [model] that generates at most [maxTokens] tokens.
  const ClaudeAgenticConfig({
    required this.model,
    required this.maxTokens,
    this.apiKey,
    this.authToken,
    this.baseUrl = defaultBaseUrl,
    this.requestTimeout = defaultRequestTimeout,
    this.idleTimeout = defaultIdleTimeout,
    this.stopSequences,
    this.disableParallelToolUse,
    this.thinking,
    this.customHeaders,
    this.extraFields,
    this.cacheControl,
  });

  /// The endpoint of the Anthropic API.
  static const defaultBaseUrl = 'https://api.anthropic.com';

  /// The default of [requestTimeout]: ten minutes, the Anthropic SDKs'
  /// default.
  static const defaultRequestTimeout = Duration(minutes: 10);

  /// The default of [idleTimeout].
  static const defaultIdleTimeout = Duration(seconds: 90);

  /// The API key, sent as `x-api-key` (Go: `APIKey`). Optional when
  /// [authToken] is set.
  final String? apiKey;

  /// A bearer token, sent as `Authorization: Bearer …` (Go: `AuthToken`).
  /// Optional when [apiKey] is set; when both are set, both are sent.
  final String? authToken;

  /// The API endpoint (Go: `BaseURL`); requests go to `{baseUrl}/v1/messages`.
  final String baseUrl;

  /// The model to use (Go: `Model`). Required: the model throws an
  /// [ArgumentError] ("model is required") when it is empty.
  final String model;

  /// The most tokens a response may have (Go: `MaxTokens`). Required: the
  /// model throws an [ArgumentError] ("max_tokens must be positive") when it
  /// is not above zero. `ChatModelOptions.maxTokens` overrides it per call.
  final int maxTokens;

  /// The longest wait for a response (Go: `RequestTimeout`).
  ///
  /// For `generate` it covers the whole response; for `stream` the arrival
  /// of the response headers, after which [idleTimeout] applies (as for the
  /// classic `ClaudeChatModel`; Go's timeout covers the whole stream). Go
  /// has no default; here it is [defaultRequestTimeout]. anthropic-sdk-go's
  /// own default for a `generate` without a timeout (a time derived from
  /// `max_tokens`, refusing a request it expects to take longer than ten
  /// minutes) is not ported. `ClaudeAgenticOptions.requestTimeout` overrides
  /// it for one call.
  final Duration requestTimeout;

  /// The longest silence between two lines of a stream before it fails with
  /// a retryable `ClaudeException`, or `null` for no limit. Not in Go; the
  /// API sends `ping` events while it works.
  final Duration? idleTimeout;

  /// Sequences that end the generation (Go: `StopSequences`).
  /// `ChatModelOptions.stop` overrides them per call.
  final List<String>? stopSequences;

  /// Whether the model may call at most one tool per turn (Go:
  /// `DisableParallelToolUse`). Sent only with a
  /// `ChatModelOptions.agenticToolChoice` that is not `forbidden`.
  final bool? disableParallelToolUse;

  /// Whether and how the model thinks (Go: `Thinking`).
  final ClaudeThinkingConfig? thinking;

  /// Headers added to every request (Go: `CustomHeaders`); a call's
  /// `ClaudeAgenticOptions.customHeaders` replace them. The values of
  /// `anthropic-beta` are split at commas and merged with the betas the
  /// server tools need.
  final Map<String, String>? customHeaders;

  /// Fields set in every request body after it is built, overriding what the
  /// model put there (Go: `ExtraFields`, applied with `option.WithJSONSet`,
  /// whose sjson path syntax the keys follow: `metadata.user_id` sets a field
  /// of the `metadata` object). A call's `ClaudeAgenticOptions.extraFields`
  /// replace them. The values must be JSON-encodable.
  final Map<String, Object?>? extraFields;

  /// Automatic prompt caching (Go: `CacheControl`): sent as the request's
  /// top-level `cache_control`, with which the API puts a breakpoint on the
  /// last cacheable block. Breakpoints set with
  /// `withClaudeAgenticCacheControl` are kept.
  final ClaudeCacheControl? cacheControl;
}

/// The server tools to offer in one call, passed in
/// `ClaudeAgenticOptions.serverTools`.
///
/// Port of eino-ext agenticclaude `ServerToolConfig`. A config may set
/// several tools, and several configs may be given: per tool version the
/// last config that sets it wins, and the tools are sent in a fixed order
/// (web search, web fetch, code execution, BM25 search, regex search), as
/// Go's `selectServerTools` does.
@immutable
final class ClaudeServerToolConfig {
  /// A config of the tools that are given.
  const ClaudeServerToolConfig({
    this.webSearch20260209,
    this.webFetch20260309,
    this.codeExecution20260120,
    this.toolSearchToolBm25V20251119,
    this.toolSearchToolRegex20251119,
  });

  /// The web search tool, version 2026-02-09 (Go: `WebSearch20260209`).
  final ClaudeWebSearchTool20260209? webSearch20260209;

  /// The web fetch tool, version 2026-03-09 (Go: `WebFetch20260309`). Its
  /// beta header (`web-fetch-2026-03-09`) is added to the request.
  final ClaudeWebFetchTool20260309? webFetch20260309;

  /// The code execution tool, version 2026-01-20 (Go:
  /// `CodeExecution20260120`). It enables the runtime tool names
  /// `code_execution`, `bash_code_execution` and
  /// `text_editor_code_execution`.
  final ClaudeCodeExecutionTool20260120? codeExecution20260120;

  /// The BM25 tool search tool (Go: `ToolSearchToolBm25_20251119`).
  final ClaudeToolSearchToolBm25V20251119? toolSearchToolBm25V20251119;

  /// The regex tool search tool (Go: `ToolSearchToolRegex20251119`).
  final ClaudeToolSearchToolRegex20251119? toolSearchToolRegex20251119;

  @override
  bool operator ==(Object other) =>
      other is ClaudeServerToolConfig &&
      other.webSearch20260209 == webSearch20260209 &&
      other.webFetch20260309 == webFetch20260309 &&
      other.codeExecution20260120 == codeExecution20260120 &&
      other.toolSearchToolBm25V20251119 == toolSearchToolBm25V20251119 &&
      other.toolSearchToolRegex20251119 == toolSearchToolRegex20251119;

  @override
  int get hashCode => Object.hash(
    webSearch20260209,
    webFetch20260309,
    codeExecution20260120,
    toolSearchToolBm25V20251119,
    toolSearchToolRegex20251119,
  );

  @override
  String toString() =>
      'ClaudeServerToolConfig(webSearch20260209: '
      '$webSearch20260209, webFetch20260309: $webFetch20260309, '
      'codeExecution20260120: $codeExecution20260120, '
      'toolSearchToolBm25V20251119: $toolSearchToolBm25V20251119, '
      'toolSearchToolRegex20251119: $toolSearchToolRegex20251119)';
}

/// A server tool definition, sent in the request's `tools`.
///
/// Go takes anthropic-sdk-go's parameter structs
/// (`WebSearchTool20260209Param`, …). Here each tool has the fields the
/// API documents for it and [extraFields] for the others (`defer_loading`,
/// `allowed_callers`, fields of later API versions): they are added to the
/// definition as given and win over the typed fields.
@immutable
sealed class ClaudeServerTool {
  /// The fields every server tool definition has.
  const ClaudeServerTool({this.cacheControl, this.extraFields});

  /// A cache breakpoint on this tool definition.
  final ClaudeCacheControl? cacheControl;

  /// More fields of the definition, JSON-encodable.
  final Map<String, Object?>? extraFields;

  /// The tool's `type`, its versioned name (`web_search_20260209`).
  String get type;

  /// The tool's `name`, which the model calls it by.
  ClaudeServerToolName get name;

  /// The definition the request carries.
  Map<String, Object?> toJson() => {
    'type': type,
    'name': name.value,
    ..._fields(),
    if (cacheControl != null)
      'cache_control': claudeCacheControlParam(cacheControl),
    ...?extraFields,
  };

  Map<String, Object?> _fields() => const {};

  @override
  bool operator ==(Object other) =>
      other is ClaudeServerTool &&
      other.runtimeType == runtimeType &&
      _jsonEquality.equals(other.toJson(), toJson());

  @override
  int get hashCode => _jsonEquality.hash(toJson());

  @override
  String toString() => 'ClaudeServerTool(${toJson()})';
}

/// The web search server tool, version 2026-02-09 (`web_search_20260209`).
///
/// Port of anthropic-sdk-go `WebSearchTool20260209Param`.
final class ClaudeWebSearchTool20260209 extends ClaudeServerTool {
  /// A web search tool with the given limits.
  const ClaudeWebSearchTool20260209({
    this.maxUses,
    this.allowedDomains,
    this.blockedDomains,
    this.userLocation,
    super.cacheControl,
    super.extraFields,
  });

  /// The most searches in one request (`max_uses`).
  final int? maxUses;

  /// Only results from these domains (`allowed_domains`); not together with
  /// [blockedDomains].
  final List<String>? allowedDomains;

  /// Never results from these domains (`blocked_domains`).
  final List<String>? blockedDomains;

  /// Where the user is, for more relevant results (`user_location`).
  final ClaudeWebSearchUserLocation? userLocation;

  @override
  String get type => claudeServerToolVersionWebSearch20260209;

  @override
  ClaudeServerToolName get name => ClaudeServerToolName.webSearch;

  @override
  Map<String, Object?> _fields() => {
    if (maxUses != null) 'max_uses': maxUses,
    if (allowedDomains != null) 'allowed_domains': allowedDomains,
    if (blockedDomains != null) 'blocked_domains': blockedDomains,
    if (userLocation != null) 'user_location': userLocation!.toJson(),
  };
}

/// The approximate location of the user, for web search. Port of
/// anthropic-sdk-go's web search `UserLocationParam` (type `approximate`).
@immutable
final class ClaudeWebSearchUserLocation {
  /// A location with the fields that are known.
  const ClaudeWebSearchUserLocation({
    this.city,
    this.region,
    this.country,
    this.timezone,
  });

  /// The city.
  final String? city;

  /// The region or state.
  final String? region;

  /// The two-letter ISO country code.
  final String? country;

  /// The IANA time zone.
  final String? timezone;

  /// The `user_location` object.
  Map<String, Object?> toJson() => {
    'type': 'approximate',
    if (city != null) 'city': city,
    if (region != null) 'region': region,
    if (country != null) 'country': country,
    if (timezone != null) 'timezone': timezone,
  };

  @override
  bool operator ==(Object other) =>
      other is ClaudeWebSearchUserLocation &&
      other.city == city &&
      other.region == region &&
      other.country == country &&
      other.timezone == timezone;

  @override
  int get hashCode => Object.hash(city, region, country, timezone);

  @override
  String toString() => 'ClaudeWebSearchUserLocation(${toJson()})';
}

/// The web fetch server tool, version 2026-03-09 (`web_fetch_20260309`).
///
/// Port of anthropic-sdk-go `WebFetchTool20260309Param`. Requests that
/// offer it carry the beta header `web-fetch-2026-03-09`.
final class ClaudeWebFetchTool20260309 extends ClaudeServerTool {
  /// A web fetch tool with the given limits.
  const ClaudeWebFetchTool20260309({
    this.maxUses,
    this.allowedDomains,
    this.blockedDomains,
    this.citationsEnabled,
    this.maxContentTokens,
    super.cacheControl,
    super.extraFields,
  });

  /// The most fetches in one request (`max_uses`).
  final int? maxUses;

  /// Only these domains may be fetched (`allowed_domains`).
  final List<String>? allowedDomains;

  /// These domains are never fetched (`blocked_domains`).
  final List<String>? blockedDomains;

  /// Whether fetched documents can be cited (`citations.enabled`).
  final bool? citationsEnabled;

  /// The most tokens of a fetched page that go into the context
  /// (`max_content_tokens`).
  final int? maxContentTokens;

  @override
  String get type => claudeServerToolVersionWebFetch20260309;

  @override
  ClaudeServerToolName get name => ClaudeServerToolName.webFetch;

  @override
  Map<String, Object?> _fields() => {
    if (maxUses != null) 'max_uses': maxUses,
    if (allowedDomains != null) 'allowed_domains': allowedDomains,
    if (blockedDomains != null) 'blocked_domains': blockedDomains,
    if (citationsEnabled != null) 'citations': {'enabled': citationsEnabled},
    if (maxContentTokens != null) 'max_content_tokens': maxContentTokens,
  };
}

/// The code execution server tool, version 2026-01-20
/// (`code_execution_20260120`).
///
/// Port of anthropic-sdk-go `CodeExecutionTool20260120Param`.
final class ClaudeCodeExecutionTool20260120 extends ClaudeServerTool {
  /// The code execution tool.
  const ClaudeCodeExecutionTool20260120({
    super.cacheControl,
    super.extraFields,
  });

  @override
  String get type => claudeServerToolVersionCodeExecution20260120;

  @override
  ClaudeServerToolName get name => ClaudeServerToolName.codeExecution;
}

/// The BM25 tool search server tool (`tool_search_tool_bm25_20251119`),
/// with which the model finds deferred tools
/// (`ChatModelOptions.deferredTools`).
///
/// Port of anthropic-sdk-go `ToolSearchToolBm25_20251119Param`.
final class ClaudeToolSearchToolBm25V20251119 extends ClaudeServerTool {
  /// The BM25 tool search tool.
  const ClaudeToolSearchToolBm25V20251119({
    super.cacheControl,
    super.extraFields,
  });

  @override
  String get type => claudeServerToolVersionToolSearchToolBm25V20251119;

  @override
  ClaudeServerToolName get name => ClaudeServerToolName.toolSearchToolBm25;
}

/// The regex tool search server tool (`tool_search_tool_regex_20251119`).
///
/// Port of anthropic-sdk-go `ToolSearchToolRegex20251119Param`.
final class ClaudeToolSearchToolRegex20251119 extends ClaudeServerTool {
  /// The regex tool search tool.
  const ClaudeToolSearchToolRegex20251119({
    super.cacheControl,
    super.extraFields,
  });

  @override
  String get type => claudeServerToolVersionToolSearchToolRegex20251119;

  @override
  ClaudeServerToolName get name => ClaudeServerToolName.toolSearchToolRegex;
}
