/// Langfuse client configuration
///
/// **Framework Source: Eino (CloudWeGo)** - Configuration patterns
/// **Framework Source: Langfuse** - API authentication

import 'dart:convert';

/// Configuration for the Langfuse client
///
/// Example:
/// ```dart
/// final config = LangfuseConfig(
///   host: 'https://cloud.langfuse.com',
///   publicKey: 'pk-lf-...',
///   secretKey: 'sk-lf-...',
///   flushAt: 20,
///   flushInterval: Duration(seconds: 5),
/// );
/// ```
class LangfuseConfig {
  /// Langfuse server URL (required)
  /// Examples: 'https://cloud.langfuse.com', 'https://us.cloud.langfuse.com'
  final String host;

  /// Public API key (required)
  final String publicKey;

  /// Secret API key (required)
  final String secretKey;

  /// Number of concurrent workers for processing events
  /// Default: 1
  final int threads;

  /// HTTP request timeout
  /// Default: 30 seconds
  final Duration timeout;

  /// Maximum number of events to buffer
  /// Default: 100
  final int maxTaskQueueSize;

  /// Number of events to batch before sending
  /// Default: 15
  final int flushAt;

  /// How often to flush events automatically
  /// Default: 500 milliseconds
  final Duration flushInterval;

  /// Sampling rate (0.0 to 1.0)
  /// 1.0 = send all events, 0.5 = send 50% of events
  /// Default: 1.0 (send all)
  final double sampleRate;

  /// Maximum retry attempts for failed requests
  /// Default: 3
  final int maxRetry;

  /// Function to mask sensitive data before sending
  /// Example: (data) => data.replaceAll(RegExp(r'\d{16}'), '****')
  final String Function(String)? maskFunc;

  /// Default trace name
  final String? defaultTraceName;

  /// Default user ID for traces
  final String? defaultUserId;

  /// Default session ID for traces
  final String? defaultSessionId;

  /// Default release version
  final String? defaultRelease;

  /// Default tags for traces
  final List<String>? defaultTags;

  /// SDK version (automatically set)
  final String sdkVersion;

  /// SDK name (automatically set)
  final String sdkName;

  /// SDK integration name
  final String sdkIntegration;

  const LangfuseConfig({
    required this.host,
    required this.publicKey,
    required this.secretKey,
    this.threads = 1,
    this.timeout = const Duration(seconds: 30),
    this.maxTaskQueueSize = 100,
    this.flushAt = 15,
    this.flushInterval = const Duration(milliseconds: 500),
    this.sampleRate = 1.0,
    this.maxRetry = 3,
    this.maskFunc,
    this.defaultTraceName,
    this.defaultUserId,
    this.defaultSessionId,
    this.defaultRelease,
    this.defaultTags,
    this.sdkVersion = '0.1.0',
    this.sdkName = 'Dart',
    this.sdkIntegration = 'threepio',
  });

  /// Generate Basic Authentication header value
  String get basicAuthHeader {
    final credentials = '$publicKey:$secretKey';
    final encoded = base64Encode(utf8.encode(credentials));
    return 'Basic $encoded';
  }

  /// Get batch metadata
  Map<String, String> getBatchMetadata(int batchSize) {
    return {
      'batch_size': batchSize.toString(),
      'sdk_integration': sdkIntegration,
      'sdk_name': sdkName,
      'sdk_version': sdkVersion,
      'public_key': publicKey,
    };
  }
}
