/// Error classification shared by providers so generic decorators
/// ([RetryingChatModel], [FailoverChatModel]) can act without knowing the
/// provider.
abstract class ChatModelException implements Exception {
  String get message;

  /// Worth retrying with backoff (rate limit, upstream failure, timeout).
  bool get isRetryable;

  /// The requested model cannot be served; switch models instead of retrying.
  bool get isModelUnavailable;
}
