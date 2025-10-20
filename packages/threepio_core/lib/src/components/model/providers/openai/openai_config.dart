/// Configuration for OpenAI API
class OpenAIConfig {
  const OpenAIConfig({
    required this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.organization,
    this.defaultModel = 'gpt-4o-mini',
    this.timeout = const Duration(seconds: 60),
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
  final Duration timeout;

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
  }) {
    return OpenAIConfig(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      organization: organization ?? this.organization,
      defaultModel: defaultModel ?? this.defaultModel,
      timeout: timeout ?? this.timeout,
    );
  }
}
