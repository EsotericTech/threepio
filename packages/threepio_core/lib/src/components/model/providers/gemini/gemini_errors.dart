/// The exception of the Gemini chat model and embedder.
library;

import '../../model_errors.dart';
import '../../openai_compatible/errors.dart';

/// Gemini API exception
///
/// Port of the errors the genai SDK returns for a failed call (`genai.APIError`
/// with its HTTP code, message and status), classified for
/// `RetryingChatModel` and `FailoverChatModel`: [isRetryable] for 408, 429,
/// 5xx and the statuses `RESOURCE_EXHAUSTED`, `UNAVAILABLE` and
/// `DEADLINE_EXCEEDED` (and for timeouts and transport failures), and
/// [isModelUnavailable] for 404 and `NOT_FOUND`.
class GeminiException implements ChatModelException {
  GeminiException(
    this.message, {
    this.statusCode,
    this.code,
    this.status,
    this.cause,
    bool? isRetryable,
    bool? isModelUnavailable,
  })  : _isRetryable = isRetryable,
        _isModelUnavailable = isModelUnavailable;

  factory GeminiException.fromResponse(
    int statusCode,
    Map<String, dynamic> body,
  ) {
    final error = body['error'] as Map<String, dynamic>?;
    if (error != null) {
      return GeminiException(
        error['message'] as String? ?? 'Unknown error',
        statusCode: statusCode,
        code: error['code'] as int?,
        status: error['status'] as String?,
      );
    }
    return GeminiException(
      'API request failed with status $statusCode',
      statusCode: statusCode,
    );
  }

  /// The exception for an HTTP response with [statusCode] and [body], which
  /// may be Gemini's JSON error (`{"error": {"code", "message", "status"}}`)
  /// or any other text.
  ///
  /// Port of genai `newAPIError`.
  factory GeminiException.fromHttp(int statusCode, String body) {
    if (body.trim().isEmpty) {
      return GeminiException(
        'API request failed with status $statusCode',
        statusCode: statusCode,
      );
    }
    final detail = ProviderErrorDetail.parse(body);
    final code = detail.code;
    return GeminiException(
      detail.message,
      statusCode: statusCode,
      code: code is int ? code : int.tryParse('${code ?? ''}'),
      status: detail.status,
    );
  }

  static const _retryableStatuses = {
    'RESOURCE_EXHAUSTED',
    'UNAVAILABLE',
    'DEADLINE_EXCEEDED',
  };

  @override
  final String message;
  final int? statusCode;
  final int? code;
  final String? status;

  /// The error this exception was raised for (a transport failure, a body
  /// that is not JSON), or `null`.
  @override
  final Object? cause;

  final bool? _isRetryable;
  final bool? _isModelUnavailable;

  /// Worth retrying with backoff: 408, 429, 5xx, `RESOURCE_EXHAUSTED`,
  /// `UNAVAILABLE`, `DEADLINE_EXCEEDED`, a timeout or a failed transport.
  @override
  bool get isRetryable =>
      _isRetryable ??
      (isRetryableHttpStatus(statusCode ?? code) ||
          _retryableStatuses.contains(status));

  /// The model cannot be served (404, `NOT_FOUND`): switch models instead of
  /// retrying.
  @override
  bool get isModelUnavailable =>
      _isModelUnavailable ??
      (looksLikeModelUnavailable(statusCode ?? code, message) ||
          status == 'NOT_FOUND');

  @override
  String toString() {
    final parts = ['GeminiException: $message'];
    if (statusCode != null) parts.add('statusCode: $statusCode');
    if (code != null) parts.add('code: $code');
    if (status != null) parts.add('status: $status');
    return parts.join(', ');
  }
}
