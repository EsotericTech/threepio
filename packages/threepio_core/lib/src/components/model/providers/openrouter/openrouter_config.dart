/// Configuration for OpenRouter API
///
/// OpenRouter (https://openrouter.ai) is a unified API gateway that provides
/// access to multiple LLM providers through a single OpenAI-compatible interface.
///
/// Example usage:
/// ```dart
/// final config = OpenRouterConfig(
///   apiKey: 'your-api-key',
///   siteName: 'My App',
///   siteUrl: 'https://myapp.com',
///   defaultModel: 'google/gemini-2.5-flash',
/// );
/// ```
class OpenRouterConfig {
  const OpenRouterConfig({
    required this.apiKey,
    this.baseUrl = 'https://openrouter.ai/api/v1',
    this.defaultModel = 'google/gemini-2.5-flash',
    this.siteName,
    this.siteUrl,
    this.timeout = const Duration(seconds: 60),
    this.includeRawResponse = false,
    this.transforms,
  });

  /// API key for authentication with OpenRouter
  final String apiKey;

  /// Base URL for API requests
  ///
  /// Defaults to 'https://openrouter.ai/api/v1'
  final String baseUrl;

  /// Default model to use if not specified in options
  ///
  /// OpenRouter supports many models from different providers.
  /// Format is typically 'provider/model-name' (e.g., 'openai/gpt-4', 'google/gemini-2.5-flash')
  final String defaultModel;

  /// Site name for tracking and rankings
  ///
  /// Optional. Used by OpenRouter for analytics and to identify your app.
  /// Will be included in HTTP-Referer header.
  final String? siteName;

  /// Site URL for tracking and rankings
  ///
  /// Optional. Used by OpenRouter for analytics.
  /// Will be included in X-Title header.
  final String? siteUrl;

  /// Request timeout duration
  ///
  /// Maximum time to wait for API responses before timing out.
  final Duration timeout;

  /// Include raw OpenRouter response in metadata
  ///
  /// When true, the raw API response will be included in the Message's
  /// extra field for debugging purposes.
  final bool includeRawResponse;

  /// OpenRouter-specific transform options
  ///
  /// Optional map of transformation parameters supported by OpenRouter.
  /// See OpenRouter documentation for available transforms.
  final Map<String, dynamic>? transforms;

  /// Create config from environment variables
  ///
  /// Looks for OPENROUTER_API_KEY environment variable.
  factory OpenRouterConfig.fromEnvironment({
    String? apiKey,
    String? baseUrl,
    String? defaultModel,
    String? siteName,
    String? siteUrl,
  }) {
    final envApiKey =
        apiKey ?? const String.fromEnvironment('OPENROUTER_API_KEY');
    if (envApiKey.isEmpty) {
      throw ArgumentError('OpenRouter API key is required');
    }

    return OpenRouterConfig(
      apiKey: envApiKey,
      baseUrl: baseUrl ?? 'https://openrouter.ai/api/v1',
      defaultModel: defaultModel ?? 'google/gemini-2.5-flash',
      siteName: siteName,
      siteUrl: siteUrl,
    );
  }

  /// Copy with method for creating modified copies
  OpenRouterConfig copyWith({
    String? apiKey,
    String? baseUrl,
    String? defaultModel,
    String? siteName,
    String? siteUrl,
    Duration? timeout,
    bool? includeRawResponse,
    Map<String, dynamic>? transforms,
  }) {
    return OpenRouterConfig(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      defaultModel: defaultModel ?? this.defaultModel,
      siteName: siteName ?? this.siteName,
      siteUrl: siteUrl ?? this.siteUrl,
      timeout: timeout ?? this.timeout,
      includeRawResponse: includeRawResponse ?? this.includeRawResponse,
      transforms: transforms ?? this.transforms,
    );
  }
}
