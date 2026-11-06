import 'dart:io';

import '../../../../errors.dart';
import 'gemini_options.dart';

/// Configuration for Google Gemini API
///
/// Provides settings for connecting to the Gemini API, including
/// authentication, endpoint configuration, and default model selection.
///
/// Port of eino-ext `gemini.Config`: besides the connection, it carries the
/// defaults of every call ([maxTokens], [temperature], [topP], [topK],
/// [responseJsonSchema], [thinkingConfig], [imageConfig],
/// [responseModalities], [mediaResolution], [safetySettings],
/// [responseLogprobs], [logprobs]), the server tools the model may use
/// ([enableCodeExecution], [enableGoogleSearch], …) and the lifetime of the
/// prefix caches it creates ([cache]). Every one of them is optional; the
/// options of a call (`ChatModelOptions`, `GeminiRequestOptions`) override
/// them.
///
/// Example usage:
/// ```dart
/// final config = GeminiConfig(apiKey: 'your-api-key');
/// final model = GeminiChatModel(config: config);
/// ```
///
/// Or using environment variables:
/// ```dart
/// final config = GeminiConfig.fromEnvironment();
/// ```
class GeminiConfig {
  /// Creates a new Gemini configuration
  const GeminiConfig({
    required this.apiKey,
    this.baseUrl = 'https://generativelanguage.googleapis.com/v1beta',
    this.defaultModel = 'gemini-2.5-flash',
    this.timeout = const Duration(seconds: 120),
    this.maxTokens,
    this.temperature,
    this.topP,
    this.topK,
    this.responseJsonSchema,
    this.enableCodeExecution = false,
    this.enableGoogleSearch,
    this.enableGoogleSearchRetrieval,
    this.enableComputerUse,
    this.enableUrlContext,
    this.enableFileSearch,
    this.enableGoogleMaps,
    this.safetySettings,
    this.thinkingConfig,
    this.imageConfig,
    this.responseModalities,
    this.mediaResolution,
    this.cache,
    this.responseLogprobs = false,
    this.logprobs,
  });

  /// Creates configuration from environment variables
  ///
  /// Looks for:
  /// - `GEMINI_API_KEY` or `GOOGLE_API_KEY` for the API key
  /// - `GEMINI_BASE_URL` for custom base URL (optional)
  /// - `GEMINI_MODEL` for default model (optional)
  factory GeminiConfig.fromEnvironment({
    String? baseUrl,
    String? defaultModel,
    Duration? timeout,
  }) {
    final apiKey = Platform.environment['GEMINI_API_KEY'] ??
        Platform.environment['GOOGLE_API_KEY'];
    if (apiKey == null || apiKey.isEmpty) {
      throw GeminiConfigException(
        'GEMINI_API_KEY or GOOGLE_API_KEY environment variable not set',
      );
    }

    return GeminiConfig(
      apiKey: apiKey,
      baseUrl: baseUrl ??
          Platform.environment['GEMINI_BASE_URL'] ??
          'https://generativelanguage.googleapis.com/v1beta',
      defaultModel: defaultModel ??
          Platform.environment['GEMINI_MODEL'] ??
          'gemini-2.5-flash',
      timeout: timeout ?? const Duration(seconds: 120),
    );
  }

  /// API key for authentication
  final String apiKey;

  /// Base URL for the Gemini API
  final String baseUrl;

  /// Default model to use when not specified in options
  ///
  /// Recommended models:
  /// - `gemini-2.5-flash` - Best price/performance (default)
  /// - `gemini-2.5-pro` - Complex reasoning, STEM
  /// - `gemini-3-flash-preview` - Latest speed-optimized
  /// - `gemini-3-pro-preview` - Latest quality-optimized
  final String defaultModel;

  /// Request timeout duration
  final Duration timeout;

  /// The most tokens a response may have (Go `Config.MaxTokens`).
  /// `ChatModelOptions.maxTokens` overrides it.
  final int? maxTokens;

  /// The sampling temperature (Go `Config.Temperature`).
  /// `ChatModelOptions.temperature` overrides it.
  final double? temperature;

  /// The nucleus sampling threshold (Go `Config.TopP`).
  /// `ChatModelOptions.topP` overrides it.
  final double? topP;

  /// Sample from the [topK] most likely tokens (Go `Config.TopK`).
  /// `GeminiRequestOptions.topK` overrides it.
  final int? topK;

  /// A JSON schema every response must follow (Go
  /// `Config.ResponseJSONSchema`); the response MIME type becomes
  /// `application/json`. `GeminiRequestOptions.responseJsonSchema` overrides
  /// it.
  final Map<String, Object?>? responseJsonSchema;

  /// Whether the model may write and run code (Go
  /// `Config.EnableCodeExecution`). The code and its result come back as
  /// output parts. Default `false`.
  final bool enableCodeExecution;

  /// The Google Search server tool (Go `Config.EnableGoogleSearch`).
  final GeminiGoogleSearch? enableGoogleSearch;

  /// The Google Search retrieval server tool of the older models (Go
  /// `Config.EnableGoogleSearchRetrieval`).
  final GeminiGoogleSearchRetrieval? enableGoogleSearchRetrieval;

  /// The computer use server tool (Go `Config.EnableComputerUse`).
  final GeminiComputerUse? enableComputerUse;

  /// The URL context server tool (Go `Config.EnableURLContext`).
  final GeminiUrlContext? enableUrlContext;

  /// The file search server tool (Go `Config.EnableFileSearch`).
  final GeminiFileSearch? enableFileSearch;

  /// The Google Maps grounding server tool (Go `Config.EnableGoogleMaps`).
  final GeminiGoogleMaps? enableGoogleMaps;

  /// The safety filter settings (Go `Config.SafetySettings`). A
  /// `safetySettings` list in `ChatModelOptions.extra` overrides them.
  final List<GeminiSafetySetting>? safetySettings;

  /// The thinking settings (Go `Config.ThinkingConfig`).
  /// `GeminiRequestOptions.thinkingConfig` overrides them.
  final GeminiThinkingConfig? thinkingConfig;

  /// The image generation settings (Go `Config.ImageConfig`).
  /// `GeminiRequestOptions.imageConfig` overrides them.
  final GeminiImageConfig? imageConfig;

  /// What the model may answer with (Go `Config.ResponseModalities`).
  /// `GeminiRequestOptions.responseModalities` overrides it.
  final List<GeminiResponseModality>? responseModalities;

  /// How finely media is tokenized (Go `Config.MediaResolution`).
  final GeminiMediaResolution? mediaResolution;

  /// How long the prefix caches made by `GeminiChatModel.createPrefixCache`
  /// live (Go `Config.Cache`).
  final GeminiCacheConfig? cache;

  /// Whether responses carry the log probabilities of the chosen tokens, in
  /// `ResponseMeta.logProbs` (Go `Config.ResponseLogprobs`). Default
  /// `false`.
  final bool responseLogprobs;

  /// How many top candidates per token the log probabilities list (Go
  /// `Config.Logprobs`); takes effect with [responseLogprobs].
  final int? logprobs;

  /// Creates a copy with updated values
  ///
  /// A field that is not given keeps its value; a nullable field cannot be
  /// reset to `null` this way.
  GeminiConfig copyWith({
    String? apiKey,
    String? baseUrl,
    String? defaultModel,
    Duration? timeout,
    int? maxTokens,
    double? temperature,
    double? topP,
    int? topK,
    Map<String, Object?>? responseJsonSchema,
    bool? enableCodeExecution,
    GeminiGoogleSearch? enableGoogleSearch,
    GeminiGoogleSearchRetrieval? enableGoogleSearchRetrieval,
    GeminiComputerUse? enableComputerUse,
    GeminiUrlContext? enableUrlContext,
    GeminiFileSearch? enableFileSearch,
    GeminiGoogleMaps? enableGoogleMaps,
    List<GeminiSafetySetting>? safetySettings,
    GeminiThinkingConfig? thinkingConfig,
    GeminiImageConfig? imageConfig,
    List<GeminiResponseModality>? responseModalities,
    GeminiMediaResolution? mediaResolution,
    GeminiCacheConfig? cache,
    bool? responseLogprobs,
    int? logprobs,
  }) {
    return GeminiConfig(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      defaultModel: defaultModel ?? this.defaultModel,
      timeout: timeout ?? this.timeout,
      maxTokens: maxTokens ?? this.maxTokens,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      topK: topK ?? this.topK,
      responseJsonSchema: responseJsonSchema ?? this.responseJsonSchema,
      enableCodeExecution: enableCodeExecution ?? this.enableCodeExecution,
      enableGoogleSearch: enableGoogleSearch ?? this.enableGoogleSearch,
      enableGoogleSearchRetrieval:
          enableGoogleSearchRetrieval ?? this.enableGoogleSearchRetrieval,
      enableComputerUse: enableComputerUse ?? this.enableComputerUse,
      enableUrlContext: enableUrlContext ?? this.enableUrlContext,
      enableFileSearch: enableFileSearch ?? this.enableFileSearch,
      enableGoogleMaps: enableGoogleMaps ?? this.enableGoogleMaps,
      safetySettings: safetySettings ?? this.safetySettings,
      thinkingConfig: thinkingConfig ?? this.thinkingConfig,
      imageConfig: imageConfig ?? this.imageConfig,
      responseModalities: responseModalities ?? this.responseModalities,
      mediaResolution: mediaResolution ?? this.mediaResolution,
      cache: cache ?? this.cache,
      responseLogprobs: responseLogprobs ?? this.responseLogprobs,
      logprobs: logprobs ?? this.logprobs,
    );
  }

  @override
  String toString() => 'GeminiConfig(baseUrl: $baseUrl, model: $defaultModel)';
}

/// Exception thrown when Gemini configuration is invalid
class GeminiConfigException implements ThreepioException {
  GeminiConfigException(this.message);

  @override
  final String message;

  @override
  Object? get cause => null;

  @override
  String toString() => 'GeminiConfigException: $message';
}
