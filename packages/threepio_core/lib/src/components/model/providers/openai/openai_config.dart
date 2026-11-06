import '../openrouter/openrouter_options.dart';
import 'openai_options.dart';

/// Configuration for OpenAI API
///
/// Port of eino-ext `openai.ChatModelConfig` (and of the transport part of
/// `openai.EmbeddingConfig`). [OpenAIChatModel] and [OpenAIEmbedder] read it.
/// The request settings ([temperature], [presencePenalty], [responseFormat],
/// …) are the defaults of every call; the options of a call override the
/// ones they share with `ChatModelOptions`, and [OpenAIRequestOptions] the
/// ones Go lets a call override.
///
/// For Azure OpenAI set [byAzure], [baseUrl] to the resource endpoint
/// (`https://{resource}.openai.azure.com`) and [apiVersion]; requests then go
/// to `{baseUrl}/openai/deployments/{deployment}/chat/completions` with an
/// `api-key` header, the deployment being [azureModelMapper] applied to the
/// model name.
class OpenAIConfig {
  const OpenAIConfig({
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.organization,
    this.defaultModel = 'gpt-4o-mini',
    this.timeout = const Duration(seconds: 60),
    this.byAzure = false,
    this.apiVersion,
    this.azureModelMapper,
    this.temperature,
    this.topP,
    this.stop,
    this.maxCompletionTokens,
    this.presencePenalty,
    this.frequencyPenalty,
    this.responseFormat,
    this.seed,
    this.logitBias,
    this.user,
    this.logProbs = false,
    this.topLogProbs,
    this.reasoningEffort,
    this.extraFields,
    this.customHeaders,
    this.modalities,
    this.audio,
    this.idleTimeout,
  });

  /// API key for authentication
  final String apiKey;

  /// Base URL for API requests
  final String baseUrl;

  /// Optional organization ID
  final String? organization;

  /// Default model to use if not specified in options
  final String defaultModel;

  /// Request timeout duration
  ///
  /// The longest wait for the response headers (for a complete response: for
  /// the whole response).
  final Duration timeout;

  /// Whether [baseUrl] is an Azure OpenAI resource (Go `ByAzure`).
  final bool byAzure;

  /// The Azure OpenAI API version; `2023-05-15` when not set (Go
  /// `APIVersion`).
  final String? apiVersion;

  /// Maps a model name to the Azure deployment name. By default `.` and `:`
  /// are removed from the model name, as go-openai does (Go
  /// `AzureModelMapperFunc`).
  final String Function(String model)? azureModelMapper;

  /// Default sampling temperature, 0 to 2.
  final double? temperature;

  /// Default nucleus-sampling probability mass, 0 to 1.
  final double? topP;

  /// Default stop sequences.
  final List<String>? stop;

  /// Upper bound of generated tokens including reasoning tokens
  /// (`max_completion_tokens`). Port of Go `MaxCompletionTokens`; Go's
  /// deprecated `MaxTokens` is not ported (use `ChatModelOptions.maxTokens`
  /// for the old field).
  final int? maxCompletionTokens;

  /// Penalty for tokens already present, -2 to 2.
  final double? presencePenalty;

  /// Penalty proportional to token frequency, -2 to 2.
  final double? frequencyPenalty;

  /// Structured output (`response_format`).
  final ResponseFormat? responseFormat;

  /// Seed for deterministic sampling.
  final int? seed;

  /// Token id → bias (-100 to 100).
  final Map<String, int>? logitBias;

  /// An id for the end user, for abuse monitoring.
  final String? user;

  /// Whether to return the log probabilities of the output tokens.
  final bool logProbs;

  /// How many most likely tokens to return per position, with [logProbs].
  final int? topLogProbs;

  /// How much reasoning models reason (`reasoning_effort`).
  final ReasoningEffort? reasoningEffort;

  /// Request fields added to every body, overriding fields of the same name.
  final Map<String, Object?>? extraFields;

  /// HTTP headers added to every request.
  final Map<String, String>? customHeaders;

  /// Output modalities; [OpenAIModality.audio] needs [audio].
  final List<OpenAIModality>? modalities;

  /// Audio output settings.
  final OpenAIAudioConfig? audio;

  /// The longest silence between two streamed chunks before the stream
  /// fails. `null` waits for as long as the server keeps the connection.
  final Duration? idleTimeout;

  /// Create config from environment variables
  factory OpenAIConfig.fromEnvironment({
    String? apiKey,
    String? baseUrl,
    String? organization,
    String? defaultModel,
  }) {
    final envApiKey = apiKey ?? const String.fromEnvironment('OPENAI_API_KEY');
    if (envApiKey.isEmpty) {
      throw ArgumentError('OpenAI API key is required');
    }

    return OpenAIConfig(
      apiKey: envApiKey,
      baseUrl: baseUrl ?? 'https://api.openai.com/v1',
      organization: organization,
      defaultModel: defaultModel ?? 'gpt-4o-mini',
    );
  }

  /// Copy with method
  OpenAIConfig copyWith({
    String? apiKey,
    String? baseUrl,
    String? organization,
    String? defaultModel,
    Duration? timeout,
    bool? byAzure,
    String? apiVersion,
    String Function(String model)? azureModelMapper,
    double? temperature,
    double? topP,
    List<String>? stop,
    int? maxCompletionTokens,
    double? presencePenalty,
    double? frequencyPenalty,
    ResponseFormat? responseFormat,
    int? seed,
    Map<String, int>? logitBias,
    String? user,
    bool? logProbs,
    int? topLogProbs,
    ReasoningEffort? reasoningEffort,
    Map<String, Object?>? extraFields,
    Map<String, String>? customHeaders,
    List<OpenAIModality>? modalities,
    OpenAIAudioConfig? audio,
    Duration? idleTimeout,
  }) {
    return OpenAIConfig(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      organization: organization ?? this.organization,
      defaultModel: defaultModel ?? this.defaultModel,
      timeout: timeout ?? this.timeout,
      byAzure: byAzure ?? this.byAzure,
      apiVersion: apiVersion ?? this.apiVersion,
      azureModelMapper: azureModelMapper ?? this.azureModelMapper,
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      stop: stop ?? this.stop,
      maxCompletionTokens: maxCompletionTokens ?? this.maxCompletionTokens,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      responseFormat: responseFormat ?? this.responseFormat,
      seed: seed ?? this.seed,
      logitBias: logitBias ?? this.logitBias,
      user: user ?? this.user,
      logProbs: logProbs ?? this.logProbs,
      topLogProbs: topLogProbs ?? this.topLogProbs,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      extraFields: extraFields ?? this.extraFields,
      customHeaders: customHeaders ?? this.customHeaders,
      modalities: modalities ?? this.modalities,
      audio: audio ?? this.audio,
      idleTimeout: idleTimeout ?? this.idleTimeout,
    );
  }
}
