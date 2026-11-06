/// The Gemini-specific settings of a chat model call: the per-call options of
/// eino-ext's `gemini` chat model and the value types that its `Config` and
/// those options share.
///
/// Go takes these from the genai SDK (`genai.ThinkingConfig`,
/// `genai.SafetySetting`, `genai.GoogleSearch`, …). Here each is a small
/// immutable class that writes the JSON of the Gemini REST API, which is what
/// the SDK sends.
library;

import 'package:meta/meta.dart';

import '../../chat_model_options.dart';

/// What a Gemini model may answer with.
///
/// Port of eino-ext `gemini.GeminiResponseModality`.
enum GeminiResponseModality {
  /// Text (Go `GeminiResponseModalityText`).
  text('TEXT'),

  /// Images (Go `GeminiResponseModalityImage`).
  image('IMAGE'),

  /// Audio (Go `GeminiResponseModalityAudio`).
  audio('AUDIO');

  const GeminiResponseModality(this.wireValue);

  /// The value the REST API expects.
  final String wireValue;
}

/// How much a thinking model thinks.
///
/// Port of genai `ThinkingLevel`.
enum GeminiThinkingLevel {
  /// As little thinking as the model allows.
  minimal('MINIMAL'),

  /// Little thinking.
  low('LOW'),

  /// Medium thinking.
  medium('MEDIUM'),

  /// Much thinking.
  high('HIGH');

  const GeminiThinkingLevel(this.wireValue);

  /// The value the REST API expects.
  final String wireValue;
}

/// The thinking settings of a request.
///
/// Port of genai `ThinkingConfig` (`generationConfig.thinkingConfig`). With
/// [includeThoughts] the model's thought summaries come back as
/// `Message.reasoningContent`.
@immutable
final class GeminiThinkingConfig {
  /// Thinking settings; every field is optional.
  const GeminiThinkingConfig({
    this.includeThoughts = false,
    this.thinkingBudget,
    this.thinkingLevel,
  });

  /// Whether the response carries the model's thought summaries.
  final bool includeThoughts;

  /// The most tokens the model may think with. `0` turns thinking off on the
  /// models that allow it, `-1` lets the model decide.
  final int? thinkingBudget;

  /// The level of thinking (Gemini 3 and later), instead of a budget.
  final GeminiThinkingLevel? thinkingLevel;

  /// The REST JSON of these settings.
  Map<String, Object?> toJson() => {
        if (includeThoughts) 'includeThoughts': true,
        if (thinkingBudget != null) 'thinkingBudget': thinkingBudget,
        if (thinkingLevel != null) 'thinkingLevel': thinkingLevel!.wireValue,
      };

  @override
  bool operator ==(Object other) =>
      other is GeminiThinkingConfig &&
      other.includeThoughts == includeThoughts &&
      other.thinkingBudget == thinkingBudget &&
      other.thinkingLevel == thinkingLevel;

  @override
  int get hashCode => Object.hash(includeThoughts, thinkingBudget, thinkingLevel);

  @override
  String toString() => 'GeminiThinkingConfig(${toJson()})';
}

/// The image generation settings of a request.
///
/// Port of genai `ImageConfig` (`generationConfig.imageConfig`), with the
/// fields the Gemini API accepts (the SDK rejects `outputMimeType` and
/// `outputCompressionQuality` there).
@immutable
final class GeminiImageConfig {
  /// Image settings; every field is optional.
  const GeminiImageConfig({this.aspectRatio, this.imageSize});

  /// `1:1`, `2:3`, `3:2`, `3:4`, `4:3`, `9:16`, `16:9` or `21:9`.
  final String? aspectRatio;

  /// `1K` (the default), `2K` or `4K`.
  final String? imageSize;

  /// The REST JSON of these settings.
  Map<String, Object?> toJson() => {
        if (aspectRatio != null) 'aspectRatio': aspectRatio,
        if (imageSize != null) 'imageSize': imageSize,
      };

  @override
  bool operator ==(Object other) =>
      other is GeminiImageConfig &&
      other.aspectRatio == aspectRatio &&
      other.imageSize == imageSize;

  @override
  int get hashCode => Object.hash(aspectRatio, imageSize);

  @override
  String toString() => 'GeminiImageConfig(${toJson()})';
}

/// How finely images and video frames are tokenized.
///
/// Port of genai `MediaResolution` (`generationConfig.mediaResolution`).
enum GeminiMediaResolution {
  /// 64 tokens per image.
  low('MEDIA_RESOLUTION_LOW'),

  /// 256 tokens per image.
  medium('MEDIA_RESOLUTION_MEDIUM'),

  /// Zoomed reframing with 256 tokens.
  high('MEDIA_RESOLUTION_HIGH');

  const GeminiMediaResolution(this.wireValue);

  /// The value the REST API expects.
  final String wireValue;
}

/// A category of harmful content.
///
/// Port of genai `HarmCategory`, with the categories the Gemini API filters.
enum GeminiHarmCategory {
  /// Harassment.
  harassment('HARM_CATEGORY_HARASSMENT'),

  /// Hate speech.
  hateSpeech('HARM_CATEGORY_HATE_SPEECH'),

  /// Sexually explicit content.
  sexuallyExplicit('HARM_CATEGORY_SEXUALLY_EXPLICIT'),

  /// Dangerous content.
  dangerousContent('HARM_CATEGORY_DANGEROUS_CONTENT'),

  /// Content that could harm civic integrity.
  civicIntegrity('HARM_CATEGORY_CIVIC_INTEGRITY');

  const GeminiHarmCategory(this.wireValue);

  /// The value the REST API expects.
  final String wireValue;
}

/// From which probability of harm content is blocked.
///
/// Port of genai `HarmBlockThreshold`.
enum GeminiHarmBlockThreshold {
  /// Block content with a low or higher probability of harm.
  blockLowAndAbove('BLOCK_LOW_AND_ABOVE'),

  /// Block content with a medium or higher probability of harm.
  blockMediumAndAbove('BLOCK_MEDIUM_AND_ABOVE'),

  /// Block content with a high probability of harm only.
  blockOnlyHigh('BLOCK_ONLY_HIGH'),

  /// Block nothing.
  blockNone('BLOCK_NONE'),

  /// Turn the safety filter off.
  off('OFF');

  const GeminiHarmBlockThreshold(this.wireValue);

  /// The value the REST API expects.
  final String wireValue;
}

/// One safety filter setting.
///
/// Port of genai `SafetySetting` (the Gemini API has no `method`).
@immutable
final class GeminiSafetySetting {
  /// Blocks content of [category] from [threshold] on.
  const GeminiSafetySetting({required this.category, required this.threshold});

  /// The category the setting is for.
  final GeminiHarmCategory category;

  /// The threshold from which content is blocked.
  final GeminiHarmBlockThreshold threshold;

  /// The REST JSON of this setting.
  Map<String, Object?> toJson() => {
        'category': category.wireValue,
        'threshold': threshold.wireValue,
      };

  @override
  bool operator ==(Object other) =>
      other is GeminiSafetySetting &&
      other.category == category &&
      other.threshold == threshold;

  @override
  int get hashCode => Object.hash(category, threshold);

  @override
  String toString() => 'GeminiSafetySetting(${toJson()})';
}

/// A span of time.
///
/// Port of genai `Interval`.
@immutable
final class GeminiInterval {
  /// The span from [startTime] to [endTime]; either end may be open.
  const GeminiInterval({this.startTime, this.endTime});

  /// The start of the span, inclusive.
  final DateTime? startTime;

  /// The end of the span, exclusive.
  final DateTime? endTime;

  /// The REST JSON of this span (RFC 3339 timestamps).
  Map<String, Object?> toJson() => {
        if (startTime != null) 'startTime': startTime!.toUtc().toIso8601String(),
        if (endTime != null) 'endTime': endTime!.toUtc().toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      other is GeminiInterval &&
      other.startTime == startTime &&
      other.endTime == endTime;

  @override
  int get hashCode => Object.hash(startTime, endTime);
}

/// The Google Search server tool.
///
/// Port of genai `GoogleSearch` (`Config.EnableGoogleSearch`), with the
/// fields the Gemini API accepts.
@immutable
final class GeminiGoogleSearch {
  /// Google Search, optionally limited to results from [timeRangeFilter].
  const GeminiGoogleSearch({this.timeRangeFilter});

  /// Only results published in this span.
  final GeminiInterval? timeRangeFilter;

  /// The REST JSON of the tool's settings.
  Map<String, Object?> toJson() => {
        if (timeRangeFilter != null) 'timeRangeFilter': timeRangeFilter!.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is GeminiGoogleSearch && other.timeRangeFilter == timeRangeFilter;

  @override
  int get hashCode => timeRangeFilter.hashCode;
}

/// When Google Search retrieval runs.
///
/// Port of genai `DynamicRetrievalConfigMode`.
enum GeminiDynamicRetrievalMode {
  /// Always retrieve (`MODE_UNSPECIFIED`).
  always('MODE_UNSPECIFIED'),

  /// Retrieve only when the model decides it is needed.
  dynamicRetrieval('MODE_DYNAMIC');

  const GeminiDynamicRetrievalMode(this.wireValue);

  /// The value the REST API expects.
  final String wireValue;
}

/// The dynamic retrieval settings of [GeminiGoogleSearchRetrieval].
///
/// Port of genai `DynamicRetrievalConfig`.
@immutable
final class GeminiDynamicRetrievalConfig {
  /// Retrieval settings; both fields are optional.
  const GeminiDynamicRetrievalConfig({this.mode, this.dynamicThreshold});

  /// When to retrieve.
  final GeminiDynamicRetrievalMode? mode;

  /// The prediction score above which retrieval runs in dynamic mode.
  final double? dynamicThreshold;

  /// The REST JSON of these settings.
  Map<String, Object?> toJson() => {
        if (mode != null) 'mode': mode!.wireValue,
        if (dynamicThreshold != null) 'dynamicThreshold': dynamicThreshold,
      };

  @override
  bool operator ==(Object other) =>
      other is GeminiDynamicRetrievalConfig &&
      other.mode == mode &&
      other.dynamicThreshold == dynamicThreshold;

  @override
  int get hashCode => Object.hash(mode, dynamicThreshold);
}

/// The Google Search retrieval server tool of the older models.
///
/// Port of genai `GoogleSearchRetrieval`
/// (`Config.EnableGoogleSearchRetrieval`).
@immutable
final class GeminiGoogleSearchRetrieval {
  /// Search retrieval with optional [dynamicRetrievalConfig].
  const GeminiGoogleSearchRetrieval({this.dynamicRetrievalConfig});

  /// When retrieval runs.
  final GeminiDynamicRetrievalConfig? dynamicRetrievalConfig;

  /// The REST JSON of the tool's settings.
  Map<String, Object?> toJson() => {
        if (dynamicRetrievalConfig != null)
          'dynamicRetrievalConfig': dynamicRetrievalConfig!.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is GeminiGoogleSearchRetrieval &&
      other.dynamicRetrievalConfig == dynamicRetrievalConfig;

  @override
  int get hashCode => dynamicRetrievalConfig.hashCode;
}

/// Where the computer use tool operates.
///
/// Port of genai `Environment`.
enum GeminiComputerUseEnvironment {
  /// A web browser.
  browser('ENVIRONMENT_BROWSER');

  const GeminiComputerUseEnvironment(this.wireValue);

  /// The value the REST API expects.
  final String wireValue;
}

/// The computer use server tool.
///
/// Port of genai `ComputerUse` (`Config.EnableComputerUse`).
@immutable
final class GeminiComputerUse {
  /// Computer use in [environment], without the predefined functions named
  /// in [excludedPredefinedFunctions].
  const GeminiComputerUse({
    this.environment = GeminiComputerUseEnvironment.browser,
    this.excludedPredefinedFunctions,
  });

  /// Where the model operates.
  final GeminiComputerUseEnvironment environment;

  /// Predefined functions the model must not use.
  final List<String>? excludedPredefinedFunctions;

  /// The REST JSON of the tool's settings.
  Map<String, Object?> toJson() => {
        'environment': environment.wireValue,
        if (excludedPredefinedFunctions != null &&
            excludedPredefinedFunctions!.isNotEmpty)
          'excludedPredefinedFunctions': excludedPredefinedFunctions,
      };
}

/// The URL context server tool: the model reads the pages the prompt links.
///
/// Port of genai `URLContext` (`Config.EnableURLContext`).
@immutable
final class GeminiUrlContext {
  /// The URL context tool; it has no settings.
  const GeminiUrlContext();

  /// The REST JSON of the tool's settings (an empty object).
  Map<String, Object?> toJson() => const {};

  @override
  bool operator ==(Object other) => other is GeminiUrlContext;

  @override
  int get hashCode => (GeminiUrlContext).hashCode;
}

/// The file search server tool: retrieval from file search stores.
///
/// Port of genai `FileSearch` (`Config.EnableFileSearch`).
@immutable
final class GeminiFileSearch {
  /// Search in [fileSearchStoreNames] (`fileSearchStores/…`).
  const GeminiFileSearch({
    required this.fileSearchStoreNames,
    this.topK,
    this.metadataFilter,
  });

  /// The stores to search.
  final List<String> fileSearchStoreNames;

  /// How many chunks to retrieve.
  final int? topK;

  /// A filter on the chunks' metadata.
  final String? metadataFilter;

  /// The REST JSON of the tool's settings.
  Map<String, Object?> toJson() => {
        if (fileSearchStoreNames.isNotEmpty)
          'fileSearchStoreNames': fileSearchStoreNames,
        if (topK != null) 'topK': topK,
        if (metadataFilter != null && metadataFilter!.isNotEmpty)
          'metadataFilter': metadataFilter,
      };
}

/// The Google Maps grounding server tool.
///
/// Port of genai `GoogleMaps` (`Config.EnableGoogleMaps`), with the fields the
/// Gemini API accepts.
@immutable
final class GeminiGoogleMaps {
  /// Google Maps grounding; [enableWidget] asks for a widget context token.
  const GeminiGoogleMaps({this.enableWidget});

  /// Whether the response carries a Maps widget context token.
  final bool? enableWidget;

  /// The REST JSON of the tool's settings.
  Map<String, Object?> toJson() => {
        if (enableWidget != null) 'enableWidget': enableWidget,
      };

  @override
  bool operator ==(Object other) =>
      other is GeminiGoogleMaps && other.enableWidget == enableWidget;

  @override
  int get hashCode => enableWidget.hashCode;
}

/// How long a prefix cache made by `GeminiChatModel.createPrefixCache`
/// lives.
///
/// Port of eino-ext `gemini.CacheConfig`.
@immutable
final class GeminiCacheConfig {
  /// Give [ttl] or [expireTime].
  const GeminiCacheConfig({this.ttl, this.expireTime});

  /// How long the cache lives, counted from its creation.
  final Duration? ttl;

  /// When the cache expires.
  final DateTime? expireTime;

  @override
  bool operator ==(Object other) =>
      other is GeminiCacheConfig &&
      other.ttl == ttl &&
      other.expireTime == expireTime;

  @override
  int get hashCode => Object.hash(ttl, expireTime);
}

/// Gemini-specific options of one call.
///
/// Port of the implementation-specific options of eino-ext's `gemini` chat
/// model (`option.go`): `WithTopK`, `WithResponseJSONSchema`,
/// `WithThinkingConfig`, `WithResponseModalities`, `WithCachedContentName`,
/// `WithImageConfig`, `WithLabels`, `WithExtraFields`, `WithCustomHeaders`,
/// `WithResponseLogprobs` and `WithLogprobs`. A field that is `null` leaves
/// the model's `GeminiConfig` value in place.
///
/// Pass the object in `ChatModelOptions.extensions`, or build the options
/// with [toOptions] / [applyTo]:
///
/// ```dart
/// final reply = await model.generate(
///   messages,
///   options: GeminiRequestOptions(
///     thinkingConfig: const GeminiThinkingConfig(includeThoughts: true),
///     cachedContentName: cache.name,
///   ).toOptions(temperature: 0.2),
/// );
/// ```
@immutable
final class GeminiRequestOptions {
  /// Options of one call; every field is optional.
  ///
  /// [customHeaders], [labels] and [responseModalities] are copied, as Go's
  /// `WithCustomHeaders` copies its headers. [extraFields] is not: as in Go,
  /// the map and its nested values must not be changed while the options are
  /// in use.
  GeminiRequestOptions({
    this.topK,
    this.responseJsonSchema,
    this.thinkingConfig,
    List<GeminiResponseModality>? responseModalities,
    this.imageConfig,
    this.cachedContentName,
    Map<String, String>? labels,
    this.extraFields,
    Map<String, String>? customHeaders,
    this.responseLogprobs,
    this.logprobs,
  })  : responseModalities = responseModalities == null
            ? null
            : List.unmodifiable(responseModalities),
        labels = labels == null ? null : Map.unmodifiable(labels),
        customHeaders =
            customHeaders == null ? null : Map.unmodifiable(customHeaders);

  /// Sample from the [topK] most likely tokens (Go `WithTopK`).
  final int? topK;

  /// A JSON schema the response must follow (Go `WithResponseJSONSchema`).
  /// The response MIME type becomes `application/json`.
  final Map<String, Object?>? responseJsonSchema;

  /// Thinking settings (Go `WithThinkingConfig`).
  final GeminiThinkingConfig? thinkingConfig;

  /// What the model may answer with (Go `WithResponseModalities`).
  final List<GeminiResponseModality>? responseModalities;

  /// Image generation settings (Go `WithImageConfig`).
  final GeminiImageConfig? imageConfig;

  /// The cached content (`cachedContents/…`) to use as the prefix of the
  /// prompt (Go `WithCachedContentName`). The request then carries neither
  /// system instruction nor tools: they are part of the cache.
  final String? cachedContentName;

  /// Metadata labels of the request (Go `WithLabels`). Only the Vertex AI
  /// backend accepts them; this model talks to the Gemini API, which rejects
  /// them, so a call with labels fails as it does in Go on that backend.
  final Map<String, String>? labels;

  /// Fields merged into the JSON body of the request after everything else,
  /// maps recursively (Go `WithExtraFields`). They may override fields the
  /// model sets.
  final Map<String, Object?>? extraFields;

  /// HTTP headers of the request (Go `WithCustomHeaders`). The headers the
  /// model manages itself (`Content-Type`, `x-goog-api-key`) take
  /// precedence.
  final Map<String, String>? customHeaders;

  /// Whether the response carries the log probabilities of the chosen tokens
  /// (Go `WithResponseLogprobs`); overrides `GeminiConfig.responseLogprobs`.
  final bool? responseLogprobs;

  /// How many top candidates per token the log probabilities list (Go
  /// `WithLogprobs`); takes effect with [responseLogprobs].
  final int? logprobs;

  /// Returns [options] with this object first in its `extensions`, where
  /// `options.extension<GeminiRequestOptions>()` finds it.
  ChatModelOptions applyTo(ChatModelOptions options) =>
      options.copyWith(extensions: [this, ...options.extensions]);

  /// Builds [ChatModelOptions] that carry this object in `extensions`.
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
        extensions: [this],
      );
}
