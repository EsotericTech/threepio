/// Langfuse HTTP client for API communication
///
/// **Framework Source: Eino (CloudWeGo)** - Client implementation patterns
/// **Framework Source: Langfuse** - API endpoints and authentication

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'langfuse_config.dart';
import 'models/langfuse_event.dart';

/// HTTP client for Langfuse API
class LangfuseHttpClient {
  final LangfuseConfig _config;
  final http.Client _httpClient;

  static const String _ingestionPath = '/api/public/ingestion';
  static const String _contentType = 'application/json';

  LangfuseHttpClient(this._config, {http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  /// Add base headers for authentication and SDK info
  Map<String, String> _getBaseHeaders() {
    return {
      'Authorization': _config.basicAuthHeader,
      'x_langfuse_public_key': _config.publicKey,
      'x_langfuse_sdk_name': _config.sdkName,
      'x_langfuse_sdk_version': _config.sdkVersion,
      'Content-Type': _contentType,
    };
  }

  /// Batch ingest events to Langfuse
  ///
  /// Returns the response or throws [LangfuseApiException]
  Future<LangfuseBatchIngestionResponse> batchIngestion(
    List<LangfuseIngestionEvent> batch,
    Map<String, String>? metadata,
  ) async {
    final url = Uri.parse('${_config.host}$_ingestionPath');

    final request = LangfuseBatchIngestionRequest(
      batch: batch,
      metadata: metadata,
    );

    final response = await _httpClient
        .post(
          url,
          headers: _getBaseHeaders(),
          body: jsonEncode(request.toJson()),
        )
        .timeout(_config.timeout);

    // Parse response
    final responseBody = jsonDecode(response.body) as Map<String, dynamic>;
    final ingestionResponse =
        LangfuseBatchIngestionResponse.fromJson(responseBody);

    // Check status codes
    if (response.statusCode == 200 || response.statusCode == 201) {
      return ingestionResponse;
    } else if (response.statusCode == 207) {
      // Multi-status - some succeeded, some failed
      if (ingestionResponse.hasErrors) {
        throw LangfuseApiMultiStatusException(ingestionResponse.errors);
      }
      return ingestionResponse;
    } else {
      throw LangfuseApiException(
        statusCode: response.statusCode,
        message: response.body,
      );
    }
  }

  /// Close the HTTP client
  void close() {
    _httpClient.close();
  }
}

/// Base exception for Langfuse API errors
class LangfuseApiException implements Exception {
  final int statusCode;
  final String message;
  final dynamic details;

  const LangfuseApiException({
    required this.statusCode,
    required this.message,
    this.details,
  });

  /// Whether this error should be retried
  bool get shouldRetry {
    // Retry on 5xx server errors or 429 rate limit
    if (statusCode >= 500 || statusCode == 429) {
      return true;
    }
    // Don't retry on 4xx client errors (except 429)
    if (statusCode >= 400 && statusCode < 500) {
      return false;
    }
    return true;
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.writeln('LangfuseApiException [');
    buffer.writeln('  Status: $statusCode');
    buffer.writeln('  Message: $message');
    if (details != null) {
      buffer.writeln('  Details: $details');
    }
    buffer.writeln(']');
    return buffer.toString();
  }
}

/// Exception for multi-status batch ingestion (207)
class LangfuseApiMultiStatusException implements Exception {
  final List<LangfuseBatchError> errors;

  const LangfuseApiMultiStatusException(this.errors);

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer
        .writeln('LangfuseApiMultiStatusException - ${errors.length} errors:');
    for (final error in errors) {
      buffer.writeln('  $error');
    }
    return buffer.toString();
  }
}
