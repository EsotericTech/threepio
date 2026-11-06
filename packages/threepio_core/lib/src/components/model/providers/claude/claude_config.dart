/// The configuration of `ClaudeChatModel` and the values it is made of.
///
/// Port of eino-ext `components/model/claude` `Config`, `ResponseFormat`,
/// `ToolSearchAlgorithm`, `CacheControl` and `CacheTTL`, and of the
/// `anthropic.ThinkingConfigParamUnion` the Go config takes from the SDK.
library;

import 'package:meta/meta.dart';

/// How long a prompt cache entry lives.
///
/// Port of eino-ext `claude.CacheTTL` (`anthropic.CacheControlEphemeralTTL`).
/// The API knows [fiveMinutes] (its default) and [oneHour]. As in Go, any
/// other value is sent as it is and left to the API to judge, which is why
/// this is a value class rather than an enum.
@immutable
final class ClaudeCacheTtl {
  /// A TTL with the wire value [value] (`5m`, `1h`).
  const ClaudeCacheTtl(this.value);

  /// Five minutes, the API default (Go: `CacheTTL5m`).
  static const fiveMinutes = ClaudeCacheTtl('5m');

  /// One hour (Go: `CacheTTL1h`).
  static const oneHour = ClaudeCacheTtl('1h');

  /// The value sent as `cache_control.ttl`.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ClaudeCacheTtl && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ClaudeCacheTtl($value)';
}

/// The settings of a cache breakpoint.
///
/// Port of eino-ext `claude.CacheControl`. A `null` [ttl] (Go: the zero
/// value) means the API default of five minutes.
@immutable
final class ClaudeCacheControl {
  /// A breakpoint that keeps the cache entry for [ttl].
  const ClaudeCacheControl({this.ttl});

  /// How long the cache entry lives, or `null` for the API default.
  final ClaudeCacheTtl? ttl;

  @override
  bool operator ==(Object other) =>
      other is ClaudeCacheControl && other.ttl == ttl;

  @override
  int get hashCode => ttl.hashCode;

  @override
  String toString() => 'ClaudeCacheControl(ttl: ${ttl?.value})';
}

/// How much of Claude's thinking a response shows.
///
/// Port of the `display` field of `anthropic.ThinkingConfigAdaptiveParam`
/// (`ThinkingConfigAdaptiveDisplaySummarized`/`Omitted`).
enum ClaudeThinkingDisplay {
  /// A readable summary of the thinking.
  summarized('summarized'),

  /// Thinking blocks with empty text (the signature is still returned).
  ///
  /// Warning: as in eino-ext (`convSchemaMessage` sends a thinking block back
  /// only when its text is not empty), the signed thinking of such a
  /// response is not sent back with the assistant message in the next
  /// request. The API may then reject a tool-use continuation that requires
  /// the thinking block of the previous turn.
  omitted('omitted');

  const ClaudeThinkingDisplay(this.wireValue);

  /// The value sent as `thinking.display`.
  final String wireValue;
}

/// Whether and how Claude thinks before it answers.
///
/// Port of `anthropic.ThinkingConfigParamUnion`, the type of eino-ext
/// `Config.ThinkingConfig` and `WithThinkingConfig` (the deprecated
/// `Config.Thinking`/`WithThinking` are not ported). One of
/// [ClaudeThinkingConfig.enabled], [ClaudeThinkingConfig.adaptive] and
/// [ClaudeThinkingConfig.disabled]; sent as the request's `thinking` object.
@immutable
sealed class ClaudeThinkingConfig {
  const ClaudeThinkingConfig._();

  /// Thinking with a fixed token budget (`{"type": "enabled",
  /// "budget_tokens": n}`), for models that still take one.
  const factory ClaudeThinkingConfig.enabled({
    required int budgetTokens,
    ClaudeThinkingDisplay? display,
  }) = ClaudeThinkingEnabled;

  /// Thinking whose depth the model chooses (`{"type": "adaptive"}`).
  const factory ClaudeThinkingConfig.adaptive({
    ClaudeThinkingDisplay? display,
  }) = ClaudeThinkingAdaptive;

  /// No thinking (`{"type": "disabled"}`).
  const factory ClaudeThinkingConfig.disabled() = ClaudeThinkingDisabled;

  /// The request's `thinking` object.
  Map<String, Object?> toJson();
}

/// Thinking with a token budget.
///
/// Port of `anthropic.ThinkingConfigEnabledParam`.
final class ClaudeThinkingEnabled extends ClaudeThinkingConfig {
  /// Thinking with at most [budgetTokens] tokens.
  const ClaudeThinkingEnabled({required this.budgetTokens, this.display})
      : super._();

  /// The most tokens the model may think with.
  final int budgetTokens;

  /// How much of the thinking the response shows, or `null` for the model's
  /// default.
  final ClaudeThinkingDisplay? display;

  @override
  Map<String, Object?> toJson() => {
        'type': 'enabled',
        'budget_tokens': budgetTokens,
        if (display != null) 'display': display!.wireValue,
      };

  @override
  bool operator ==(Object other) =>
      other is ClaudeThinkingEnabled &&
      other.budgetTokens == budgetTokens &&
      other.display == display;

  @override
  int get hashCode => Object.hash('enabled', budgetTokens, display);

  @override
  String toString() =>
      'ClaudeThinkingConfig.enabled(budgetTokens: $budgetTokens, '
      'display: ${display?.wireValue})';
}

/// Thinking whose depth the model chooses.
///
/// Port of `anthropic.ThinkingConfigAdaptiveParam`.
final class ClaudeThinkingAdaptive extends ClaudeThinkingConfig {
  /// Adaptive thinking shown as [display].
  const ClaudeThinkingAdaptive({this.display}) : super._();

  /// How much of the thinking the response shows, or `null` for the model's
  /// default.
  final ClaudeThinkingDisplay? display;

  @override
  Map<String, Object?> toJson() => {
        'type': 'adaptive',
        if (display != null) 'display': display!.wireValue,
      };

  @override
  bool operator ==(Object other) =>
      other is ClaudeThinkingAdaptive && other.display == display;

  @override
  int get hashCode => Object.hash('adaptive', display);

  @override
  String toString() =>
      'ClaudeThinkingConfig.adaptive(display: ${display?.wireValue})';
}

/// No thinking.
///
/// Port of `anthropic.ThinkingConfigDisabledParam`.
final class ClaudeThinkingDisabled extends ClaudeThinkingConfig {
  /// Thinking turned off.
  const ClaudeThinkingDisabled() : super._();

  @override
  Map<String, Object?> toJson() => {'type': 'disabled'};

  @override
  bool operator ==(Object other) => other is ClaudeThinkingDisabled;

  @override
  int get hashCode => 'disabled'.hashCode;

  @override
  String toString() => 'ClaudeThinkingConfig.disabled()';
}

/// Structured output: the response is JSON that conforms to [schema].
///
/// Port of eino-ext `claude.ResponseFormat`. Sent as
/// `output_config: {"format": {"type": "json_schema", "schema": …}}`.
@immutable
final class ClaudeResponseFormat {
  /// Output constrained by [schema], a JSON schema as a JSON map.
  const ClaudeResponseFormat({required this.schema});

  /// The JSON schema the model's response must conform to.
  final Map<String, Object?> schema;

  /// The request's `output_config.format` object.
  Map<String, Object?> toJson() => {'type': 'json_schema', 'schema': schema};

  @override
  String toString() => 'ClaudeResponseFormat($schema)';
}

/// The server-side search the model uses to find deferred tools.
///
/// Port of eino-ext `claude.ToolSearchAlgorithm`.
enum ClaudeToolSearchAlgorithm {
  /// BM25 ranking (`tool_search_tool_bm25_20251119`), the default when
  /// deferred tools are given.
  bm25('bm25', 'tool_search_tool_bm25_20251119', 'tool_search_tool_bm25'),

  /// Regular expressions (`tool_search_tool_regex_20251119`).
  regex('regex', 'tool_search_tool_regex_20251119', 'tool_search_tool_regex');

  const ClaudeToolSearchAlgorithm(this.wireValue, this.toolType, this.toolName);

  /// The Go constant's value (`bm25`, `regex`).
  final String wireValue;

  /// The `type` of the server tool added to the request.
  final String toolType;

  /// The `name` of the server tool added to the request.
  final String toolName;
}

/// The configuration of a `ClaudeChatModel`.
///
/// Port of eino-ext `claude.Config` for the direct Anthropic API. The Bedrock
/// and Vertex transports (`ByBedrock`, `ByVertex` and their credentials) are
/// not ported (they need AWS SigV4 and Google OAuth signing), nor is
/// `HTTPClient` (pass `httpClient` to the model). Nothing is read from the
/// environment: Go falls back to `ANTHROPIC_MODEL`, `ANTHROPIC_API_KEY`,
/// `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_BASE_URL`; here the values are given.
///
/// ```dart
/// const config = ClaudeConfig(
///   apiKey: apiKey,
///   model: 'claude-opus-5-5',
///   maxTokens: 16000,
///   thinkingConfig: ClaudeThinkingConfig.adaptive(),
/// );
/// ```
@immutable
final class ClaudeConfig {
  /// A configuration for [model] that generates at most [maxTokens] tokens.
  const ClaudeConfig({
    required this.model,
    required this.maxTokens,
    this.apiKey,
    this.authToken,
    this.baseUrl = defaultBaseUrl,
    this.temperature,
    this.topP,
    this.topK,
    this.stopSequences,
    this.thinkingConfig,
    this.timeout = defaultTimeout,
    this.idleTimeout = defaultIdleTimeout,
    this.disableParallelToolUse,
    this.toolSearchAlgorithm,
    this.responseFormat,
    this.additionalHeaderFields,
    this.additionalRequestFields,
    this.autoCacheControl,
  });

  /// The endpoint of the Anthropic API.
  static const defaultBaseUrl = 'https://api.anthropic.com';

  /// The default of [timeout]: ten minutes, the Anthropic SDKs' default.
  static const defaultTimeout = Duration(minutes: 10);

  /// The default of [idleTimeout].
  static const defaultIdleTimeout = Duration(seconds: 90);

  /// The API key, sent as `x-api-key` (Go: `APIKey`). Optional when
  /// [authToken] is set.
  final String? apiKey;

  /// A bearer token, sent as `Authorization: Bearer …` (Go: `AuthToken`).
  /// Optional when [apiKey] is set. When both are set, both are sent, as in
  /// Go.
  final String? authToken;

  /// The API endpoint (Go: `BaseURL`); requests go to `{baseUrl}/v1/messages`.
  final String baseUrl;

  /// The model to use (Go: `Model`). Required.
  final String model;

  /// The most tokens a response may have (Go: `MaxTokens`). Required by the
  /// API; sent as given.
  final int maxTokens;

  /// Sampling temperature, 0.0 to 1.0 (Go: `Temperature`).
  final double? temperature;

  /// Nucleus sampling threshold, 0.0 to 1.0 (Go: `TopP`).
  final double? topP;

  /// Sample from the [topK] most likely tokens only (Go: `TopK`).
  final int? topK;

  /// Sequences that end the generation (Go: `StopSequences`).
  final List<String>? stopSequences;

  /// Whether and how the model thinks (Go: `ThinkingConfig`).
  final ClaudeThinkingConfig? thinkingConfig;

  /// The longest wait for a response (Go: `RequestTimeout`).
  ///
  /// For `generate` it covers the whole response; for `stream` the arrival of
  /// the response headers, after which [idleTimeout] applies. Go's
  /// `RequestTimeout` is a deadline for the whole call and has no default;
  /// here the default is [defaultTimeout]. `ClaudeRequestOptions.requestTimeout`
  /// overrides it for one call.
  final Duration timeout;

  /// The longest silence between two lines of a stream before it fails with
  /// a retryable `ClaudeException`, or `null` for no limit. The API sends
  /// `ping` events while it works, so a silent stream is a broken one. Not in
  /// Go.
  final Duration? idleTimeout;

  /// Whether the model may call at most one tool per turn (Go:
  /// `DisableParallelToolUse`). Sent with the `auto` and `any` tool choices.
  final bool? disableParallelToolUse;

  /// The server-side tool search to add to the tools (Go:
  /// `ToolSearchAlgorithm`). When `null` and a call has deferred tools,
  /// [ClaudeToolSearchAlgorithm.bm25] is used.
  final ClaudeToolSearchAlgorithm? toolSearchAlgorithm;

  /// Structured output (Go: `ResponseFormat`).
  final ClaudeResponseFormat? responseFormat;

  /// Headers added to every request (Go: `AdditionalHeaderFields`). A header
  /// that is already set gets the value appended, comma-separated, as Go's
  /// `option.WithHeaderAdd` does.
  final Map<String, String>? additionalHeaderFields;

  /// Fields set in every request body after it is built, overriding what the
  /// model put there (Go: `AdditionalRequestFields`, applied with
  /// `option.WithJSONSet`, whose sjson path syntax the keys follow).
  ///
  /// A key with dots is a path: `thinking.display` sets a field of the
  /// `thinking` object, `tools.0.cache_control` a field of the first tool,
  /// `stop_sequences.-1` appends to that list. An integer past the end of a
  /// list pads it with `null`s; a key that is not an integer or `-1` where
  /// the path meets a list throws an [ArgumentError] when the request is
  /// built. Write `\.` for a dot that belongs to the key, and start a key
  /// with `:` (`metadata.:42`) to make an integer an object key. Missing
  /// objects and lists on the way are created. The values must be
  /// JSON-encodable.
  final Map<String, Object?>? additionalRequestFields;

  /// When set, cache breakpoints are placed automatically on the last tool,
  /// the last system message and the last message of every request that has
  /// none of its own there (Go: `AutoCacheControl`; the same as
  /// `ClaudeRequestOptions.autoCacheControl` on every call).
  final ClaudeCacheControl? autoCacheControl;
}
