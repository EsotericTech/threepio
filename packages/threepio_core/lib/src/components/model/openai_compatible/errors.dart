/// How the HTTP providers classify a failed request, so that
/// `RetryingChatModel` and `FailoverChatModel` can act on any of them.
///
/// Eino leaves classification to each provider's SDK error type; threepio's
/// providers all implement `ChatModelException` and fill `isRetryable` and
/// `isModelUnavailable` with these rules.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

/// Whether a request that failed with HTTP [statusCode] is worth retrying:
/// 408 (timeout), 429 (rate limit) and every 5xx.
bool isRetryableHttpStatus(int? statusCode) =>
    statusCode != null &&
    (statusCode == 408 || statusCode == 429 || statusCode >= 500);

/// Whether a failure says that the requested model cannot be served at all,
/// so that a caller should switch models instead of retrying: HTTP 404, or a
/// message that says so in the words OpenAI-compatible gateways use.
bool looksLikeModelUnavailable(int? statusCode, String message) {
  if (statusCode == 404) return true;
  final lower = message.toLowerCase();
  return lower.contains('not a valid model') ||
      lower.contains('no endpoints found') ||
      lower.contains('model not found') ||
      lower.contains('model_not_found') ||
      (lower.contains('model') && lower.contains('does not exist'));
}

/// The error a provider put in a JSON response body.
///
/// Reads the shapes of OpenAI (`{"error": {"message", "type", "code"}}`),
/// Anthropic (`{"type": "error", "error": {"type", "message"}}`), Gemini
/// (`{"error": {"code", "message", "status"}}`) and Ollama
/// (`{"error": "message"}`). Anything else keeps the raw body as [message].
@immutable
final class ProviderErrorDetail {
  /// An error with [message].
  const ProviderErrorDetail(this.message, {this.type, this.code, this.status});

  /// Reads [body]; never throws.
  factory ProviderErrorDetail.parse(String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      return ProviderErrorDetail(body);
    }
    if (json is Map) {
      final error = json['error'];
      if (error is Map) {
        return ProviderErrorDetail(
          '${error['message'] ?? body}',
          type: error['type'] is String ? error['type'] as String : null,
          code: error['code'],
          status: error['status'] is String ? error['status'] as String : null,
        );
      }
      if (error is String) return ProviderErrorDetail(error);
      final message = json['message'];
      if (message is String) return ProviderErrorDetail(message);
    }
    return ProviderErrorDetail(body);
  }

  /// The provider's description of the error.
  final String message;

  /// The error type (`invalid_request_error`, `overloaded_error`, …).
  final String? type;

  /// The error code, a string or a number depending on the provider.
  final Object? code;

  /// The status name (Gemini: `RESOURCE_EXHAUSTED`, `NOT_FOUND`, …).
  final String? status;

  @override
  String toString() => message;
}
