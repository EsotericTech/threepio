import 'dart:async';
import 'dart:math';

import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import 'base_chat_model.dart';
import 'cancel_token.dart';
import 'chat_model_options.dart';
import 'model_errors.dart';

/// Decides whether an error is worth retrying.
typedef RetryPredicate = bool Function(Object error, int attempt);

/// Decides whether an error should switch to the fallback model.
typedef FailoverPredicate = bool Function(Object error);

/// Default: provider-classified retryable errors and timeouts, never
/// cancellations or model-unavailable errors.
bool defaultShouldRetry(Object error, int attempt) {
  if (error is CancelledException) return false;
  if (error is ChatModelException) {
    return error.isRetryable && !error.isModelUnavailable;
  }
  return error is TimeoutException;
}

/// Default: anything except a cancellation.
bool defaultShouldFailover(Object error) => error is! CancelledException;

/// Retries the model call with exponential backoff and jitter (Eino's
/// `ModelRetryConfig`). Streams are retried only until the first chunk has
/// been requested; a stream that breaks mid-way is not replayed.
class RetryingChatModel extends ToolCallingChatModel {
  RetryingChatModel(
    this.inner, {
    this.maxAttempts = 3,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 8),
    RetryPredicate? shouldRetry,
    this.onRetry,
    Random? random,
  })  : shouldRetry = shouldRetry ?? defaultShouldRetry,
        _random = random ?? Random();

  final ToolCallingChatModel inner;
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final RetryPredicate shouldRetry;

  /// Observability hook: called before each retry sleep.
  final void Function(Object error, int attempt, Duration delay)? onRetry;
  final Random _random;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) =>
      _attempt(() => inner.generate(input, options: options), options);

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) =>
      _attempt(() => inner.stream(input, options: options), options);

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => RetryingChatModel(
        inner.withTools(tools),
        maxAttempts: maxAttempts,
        baseDelay: baseDelay,
        maxDelay: maxDelay,
        shouldRetry: shouldRetry,
        onRetry: onRetry,
        random: _random,
      );

  Future<T> _attempt<T>(
    Future<T> Function() call,
    ChatModelOptions? options,
  ) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await call();
      } catch (error) {
        if (attempt >= maxAttempts || !shouldRetry(error, attempt)) rethrow;
        final delay = _delayFor(attempt);
        onRetry?.call(error, attempt, delay);
        final cancel = options?.cancelToken;
        if (cancel != null) {
          await Future.any<void>([
            Future<void>.delayed(delay),
            cancel.whenCancelled,
          ]);
          cancel.throwIfCancelled();
        } else {
          await Future<void>.delayed(delay);
        }
      }
    }
  }

  Duration _delayFor(int attempt) {
    final exponential = baseDelay.inMilliseconds * pow(2, attempt - 1);
    final jitter = _random.nextDouble() * baseDelay.inMilliseconds;
    final ms = min(exponential + jitter, maxDelay.inMilliseconds.toDouble());
    return Duration(milliseconds: ms.round());
  }
}

/// Switches to [fallback] when [primary] fails (Eino's `ModelFailoverConfig`).
/// Wrap a [RetryingChatModel] to get "retry, then fail over".
class FailoverChatModel extends ToolCallingChatModel {
  FailoverChatModel({
    required this.primary,
    required this.fallback,
    FailoverPredicate? shouldFailover,
    this.onFailover,
  }) : shouldFailover = shouldFailover ?? defaultShouldFailover;

  final ToolCallingChatModel primary;
  final ToolCallingChatModel fallback;
  final FailoverPredicate shouldFailover;

  /// Observability hook: called when the fallback takes over.
  final void Function(Object error)? onFailover;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) =>
      _failover(
        () => primary.generate(input, options: options),
        () => fallback.generate(input, options: options),
      );

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) =>
      _failover(
        () => primary.stream(input, options: options),
        () => fallback.stream(input, options: options),
      );

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => FailoverChatModel(
        primary: primary.withTools(tools),
        fallback: fallback.withTools(tools),
        shouldFailover: shouldFailover,
        onFailover: onFailover,
      );

  Future<T> _failover<T>(
    Future<T> Function() first,
    Future<T> Function() second,
  ) async {
    try {
      return await first();
    } catch (error) {
      if (!shouldFailover(error)) rethrow;
      onFailover?.call(error);
      return second();
    }
  }
}
