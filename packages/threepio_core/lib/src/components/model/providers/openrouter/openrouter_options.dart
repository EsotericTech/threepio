import 'package:meta/meta.dart';

import '../../chat_model_options.dart';

/// Reasoning effort accepted by OpenRouter's `reasoning` object.
enum ReasoningEffort { none, minimal, low, medium, high, xhigh }

/// Output modalities a model may produce (OpenRouter `modalities`).
enum OutputModality { text, image, audio }

/// How much of the reasoning OpenRouter summarises (`reasoning.summary`).
///
/// Port of eino-ext `openrouter.Summary`.
enum ReasoningSummary { auto, concise, detailed }

/// How long a prompt-cache entry lives (`cache_control.ttl`).
///
/// Port of eino-ext `openrouter.CacheControlTTL`.
enum OpenRouterCacheControlTtl {
  /// Five minutes, the default.
  fiveMinutes('5m'),

  /// One hour.
  oneHour('1h');

  const OpenRouterCacheControlTtl(this.wireValue);

  /// The value sent in `ttl`.
  final String wireValue;
}

/// A prompt-cache breakpoint (`cache_control`), always of type `ephemeral`.
///
/// Port of eino-ext `openrouter.CacheControl`. Set it for the whole request
/// with [OpenRouterRequestOptions.cacheControl], or on single messages and
/// parts with the `withOpenRouterCacheControl` extensions
/// (`openrouter_cache_control.dart`).
@immutable
class OpenRouterCacheControl {
  const OpenRouterCacheControl({
    this.ttl = OpenRouterCacheControlTtl.fiveMinutes,
  });

  /// Reads the JSON form; `null` for anything else.
  static OpenRouterCacheControl? fromJson(Object? json) {
    if (json is! Map || json['type'] != 'ephemeral') return null;
    final ttl = OpenRouterCacheControlTtl.values
        .where((t) => t.wireValue == json['ttl'])
        .firstOrNull;
    return OpenRouterCacheControl(
      ttl: ttl ?? OpenRouterCacheControlTtl.fiveMinutes,
    );
  }

  /// How long the entry lives.
  final OpenRouterCacheControlTtl ttl;

  /// The `cache_control` object.
  Map<String, Object?> toJson() => {'type': 'ephemeral', 'ttl': ttl.wireValue};

  @override
  bool operator ==(Object other) =>
      other is OpenRouterCacheControl && other.ttl == ttl;

  @override
  int get hashCode => ttl.hashCode;
}

/// Provider-routing preferences (OpenRouter `provider` object).
@immutable
class ProviderRouting {
  const ProviderRouting({
    this.order,
    this.only,
    this.ignore,
    this.allowFallbacks,
    this.requireParameters,
    this.dataCollection,
    this.sort,
  });

  /// Providers to try, in order.
  final List<String>? order;

  /// Restrict routing to these providers.
  final List<String>? only;

  /// Never route to these providers.
  final List<String>? ignore;

  /// Allow OpenRouter to fall back to other providers (default true).
  final bool? allowFallbacks;

  /// Only use providers that support every request parameter.
  final bool? requireParameters;

  /// `allow` or `deny` providers that may store prompts.
  final String? dataCollection;

  /// `price`, `throughput` or `latency`.
  final String? sort;

  Map<String, dynamic> toJson() => {
        if (order != null) 'order': order,
        if (only != null) 'only': only,
        if (ignore != null) 'ignore': ignore,
        if (allowFallbacks != null) 'allow_fallbacks': allowFallbacks,
        if (requireParameters != null) 'require_parameters': requireParameters,
        if (dataCollection != null) 'data_collection': dataCollection,
        if (sort != null) 'sort': sort,
      };
}

/// Structured-output request (`response_format`).
@immutable
class ResponseFormat {
  const ResponseFormat._(this._json);

  /// Plain JSON object output without a schema.
  const ResponseFormat.jsonObject() : _json = const {'type': 'json_object'};

  /// Plain text output, the default (eino-ext
  /// `ChatCompletionResponseFormatTypeText`).
  const ResponseFormat.text() : _json = const {'type': 'text'};

  /// JSON constrained by [schema] (an object schema). [strict] asks the
  /// provider to enforce the schema exactly.
  factory ResponseFormat.jsonSchema({
    required String name,
    required Map<String, dynamic> schema,
    bool strict = true,
    String? description,
  }) =>
      ResponseFormat._({
        'type': 'json_schema',
        'json_schema': {
          'name': name,
          if (description != null) 'description': description,
          'strict': strict,
          'schema': schema,
        },
      });

  final Map<String, dynamic> _json;

  Map<String, dynamic> toJson() => _json;
}

/// OpenRouter-specific request options.
///
/// These are the fields of the Chat Completions request that go beyond the
/// OpenAI baseline: reasoning control, output modalities, provider routing,
/// structured output and usage accounting. Attach them to any
/// [ChatModelOptions] with [applyTo], or build options directly with
/// [toOptions].
///
/// ```dart
/// final options = const OpenRouterRequestOptions(
///   reasoningEffort: ReasoningEffort.medium,
///   includeUsage: true,
/// ).toOptions(model: 'z-ai/glm-5.3', temperature: 0.2);
/// ```
@immutable
class OpenRouterRequestOptions {
  const OpenRouterRequestOptions({
    this.reasoningEffort,
    this.reasoningMaxTokens,
    this.excludeReasoning,
    this.modalities,
    this.provider,
    this.responseFormat,
    this.parallelToolCalls,
    this.includeUsage = true,
    this.extra,
    this.models,
    this.metadata,
    this.reasoningEnabled,
    this.reasoningSummary,
    this.cacheControl,
    this.logprobs,
    this.topLogprobs,
  });

  /// Reasoning effort; `none` disables reasoning where supported.
  final ReasoningEffort? reasoningEffort;

  /// Token budget for reasoning (alternative to effort on some providers).
  final int? reasoningMaxTokens;

  /// Ask the provider to reason but not return the reasoning text.
  final bool? excludeReasoning;

  /// Output modalities (`['image', 'text']` for image generation models).
  final List<OutputModality>? modalities;

  /// Provider routing preferences.
  final ProviderRouting? provider;

  /// Structured output.
  final ResponseFormat? responseFormat;

  /// Allow the model to request several tools in one turn.
  final bool? parallelToolCalls;

  /// Request `usage` (with cost) in the response — also on streams, where it
  /// arrives in the final chunk.
  final bool includeUsage;

  /// Any other request fields, merged last.
  final Map<String, dynamic>? extra;

  /// Models to fall back to, in order, when the first one fails (`models`;
  /// eino-ext `WithModels`).
  final List<String>? models;

  /// Key-value pairs stored with the generation (`metadata`; eino-ext
  /// `WithMetadata`).
  final Map<String, String>? metadata;

  /// Turns reasoning on or off (`reasoning.enabled`).
  final bool? reasoningEnabled;

  /// How the reasoning is summarised (`reasoning.summary`).
  final ReasoningSummary? reasoningSummary;

  /// A cache breakpoint for the whole request (`cache_control`; eino-ext
  /// `WithCacheControl`).
  final OpenRouterCacheControl? cacheControl;

  /// Return the log probabilities of the output tokens (`logprobs`).
  final bool? logprobs;

  /// How many most likely tokens to return per position (`top_logprobs`).
  final int? topLogprobs;

  /// Request-body fields for these options.
  Map<String, dynamic> toRequestFields() => {
        if (reasoningEffort != null ||
            reasoningMaxTokens != null ||
            excludeReasoning != null ||
            reasoningEnabled != null ||
            reasoningSummary != null)
          'reasoning': {
            if (reasoningEffort != null) 'effort': reasoningEffort!.name,
            if (reasoningMaxTokens != null) 'max_tokens': reasoningMaxTokens,
            if (excludeReasoning != null) 'exclude': excludeReasoning,
            if (reasoningEnabled != null) 'enabled': reasoningEnabled,
            if (reasoningSummary != null) 'summary': reasoningSummary!.name,
          },
        if (modalities != null)
          'modalities': modalities!.map((m) => m.name).toList(),
        if (provider != null) 'provider': provider!.toJson(),
        if (responseFormat != null) 'response_format': responseFormat!.toJson(),
        if (parallelToolCalls != null) 'parallel_tool_calls': parallelToolCalls,
        if (includeUsage) 'usage': {'include': true},
        if (models != null) 'models': models,
        if (metadata != null) 'metadata': metadata,
        if (cacheControl != null) 'cache_control': cacheControl!.toJson(),
        if (logprobs != null) 'logprobs': logprobs,
        if (topLogprobs != null) 'top_logprobs': topLogprobs,
        ...?extra,
      };

  /// Returns [options] with these fields merged into `extra`.
  ///
  /// This object is also added to the `extensions` of the result, ahead of
  /// the ones [options] already has, where
  /// `options.extension<OpenRouterRequestOptions>()` finds it.
  ChatModelOptions applyTo(ChatModelOptions options) => options.copyWith(
        extra: {...?options.extra, ...toRequestFields()},
        extensions: [this, ...options.extensions],
      );

  /// Builds [ChatModelOptions] carrying these fields.
  ///
  /// The fields are in `extra`, as request fields, and this object is in
  /// `extensions`. Passing it there directly works as well:
  /// `ChatModelOptions(extensions: [OpenRouterRequestOptions(...)])`.
  ChatModelOptions toOptions({
    String? model,
    double? temperature,
    int? maxTokens,
    double? topP,
    List<String>? stop,
  }) =>
      ChatModelOptions(
        model: model,
        temperature: temperature,
        maxTokens: maxTokens,
        topP: topP,
        stop: stop,
        extra: toRequestFields(),
        extensions: [this],
      );
}
