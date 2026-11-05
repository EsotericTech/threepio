import 'dart:io';

import '../../../../errors.dart';

/// Configuration for Google Gemini API
///
/// Provides settings for connecting to the Gemini API, including
/// authentication, endpoint configuration, and default model selection.
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

  /// Creates a copy with updated values
  GeminiConfig copyWith({
    String? apiKey,
    String? baseUrl,
    String? defaultModel,
    Duration? timeout,
  }) {
    return GeminiConfig(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      defaultModel: defaultModel ?? this.defaultModel,
      timeout: timeout ?? this.timeout,
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
