/// The failures of the OpenAI Responses agentic model.
library;

import '../../model_errors.dart';
import '../../openai_compatible/errors.dart';

/// A failure of an `OpenAIResponsesModel` call: an invalid request (a
/// message the Responses API cannot take, an unsupported option), an HTTP
/// error, a failed or broken stream, or a response that cannot be read.
///
/// Go reports these as wrapped `error`s (`failed to generate request: …`,
/// `failed to create response: …`); [message] keeps Go's wording and
/// [cause] the wrapped error. Classified for retry and failover: 408, 409,
/// 429 and 5xx responses, timeouts and transport failures are retryable; a
/// 404 or a "model not found" message means the model is unavailable.
final class OpenAIResponsesException implements ChatModelException {
  /// A failure described by [message].
  OpenAIResponsesException(
    this.message, {
    this.statusCode,
    this.response,
    this.errorCode,
    bool? isRetryable,
    bool? isModelUnavailable,
    this.cause,
  })  : isRetryable = isRetryable ??
            (isRetryableHttpStatus(statusCode) || statusCode == 409),
        isModelUnavailable = isModelUnavailable ??
            (statusCode != null &&
                looksLikeModelUnavailable(statusCode, message));

  /// A response with [statusCode] and [body], classified.
  factory OpenAIResponsesException.fromHttp(
    int statusCode,
    String body, {
    String prefix = '',
  }) {
    final detail = ProviderErrorDetail.parse(body);
    return OpenAIResponsesException(
      '${prefix}API request failed with status $statusCode: $body',
      statusCode: statusCode,
      response: body,
      errorCode: detail.code,
      isModelUnavailable: looksLikeModelUnavailable(statusCode, detail.message),
    );
  }

  /// What went wrong, in Go's words.
  @override
  final String message;

  /// The HTTP status of a failed response.
  final int? statusCode;

  /// The body of a failed response.
  final String? response;

  /// The `error.code` of a failed response, when the API sent one.
  final Object? errorCode;

  @override
  final bool isRetryable;

  @override
  final bool isModelUnavailable;

  @override
  final Object? cause;

  /// This failure with [prefix] in front of its message (Go's
  /// `fmt.Errorf("prefix: %w", err)`); the classification is kept.
  OpenAIResponsesException wrap(String prefix) => OpenAIResponsesException(
        '$prefix: $message',
        statusCode: statusCode,
        response: response,
        errorCode: errorCode,
        isRetryable: isRetryable,
        isModelUnavailable: isModelUnavailable,
        cause: this,
      );

  @override
  String toString() => 'OpenAIResponsesException: $message'
      '${statusCode != null ? ' (status: $statusCode)' : ''}';
}

/// Whether an error the API reports inside a stream (an `error` event or a
/// payload with an `error` member) is worth retrying: a server error or a
/// rate limit, by its [code] or [type]. Go does not classify these errors;
/// the classification only feeds `ChatModelException.isRetryable`, so that
/// both shapes of one error are classified alike.
bool isRetryableStreamError({String? code, String? type}) =>
    const {'server_error', 'rate_limit_exceeded'}.contains(code) ||
    const {'server_error', 'rate_limit_error'}.contains(type);
