/// Retrying the model calls of a `ChatModelAgent`.
///
/// Port of eino `adk/retry_chatmodel.go`.
library;

import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

import '../../components/model/base_chat_model.dart';
import '../../components/model/cancel_token.dart';
import '../../components/model/chat_model_options.dart';
import '../../compose/errors.dart';
import '../../compose/local_state.dart';
import '../../core/interrupt_signal.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../schema/message_concat.dart';
import '../../streaming/stream_reader.dart';
import 'agent_context.dart';
import 'agent_event.dart';
import 'react_graph.dart';

/// What a retry policy is told about a model call.
///
/// Port of eino `adk.RetryContext`.
@immutable
final class RetryContext {
  /// The context of attempt [retryAttempt].
  const RetryContext({
    required this.retryAttempt,
    required this.inputMessages,
    this.options,
    this.outputMessage,
    this.error,
  });

  /// The number of the attempt that just ended, from 1.
  final int retryAttempt;

  /// What the model was sent.
  final List<Message> inputMessages;

  /// The options of the call.
  final ChatModelOptions? options;

  /// What the model answered, joined from its chunks for a stream; `null`
  /// when the call failed before it answered.
  final Message? outputMessage;

  /// What the call failed with, or `null`.
  final Object? error;
}

/// What a retry policy decides about a model call.
///
/// Port of eino `adk.RetryDecision`.
@immutable
final class RetryDecision {
  /// A decision; [retry] false accepts the result (or the error).
  const RetryDecision({
    this.retry = false,
    this.rewriteError,
    this.modifiedInputMessages,
    this.persistModifiedInputMessages = false,
    this.additionalOptions,
    this.backoff,
    this.rejectReason,
  });

  /// Whether to call the model again.
  final bool retry;

  /// When not retrying: the error to fail with instead of the result.
  final Object? rewriteError;

  /// When retrying: the messages to send instead.
  final List<Message>? modifiedInputMessages;

  /// Whether [modifiedInputMessages] replace the agent's history.
  final bool persistModifiedInputMessages;

  /// When retrying: options merged over the current ones.
  final ChatModelOptions? additionalOptions;

  /// When retrying: how long to wait; the policy's `backoff` otherwise.
  final Duration? backoff;

  /// Why the output was rejected, reported with [WillRetryException].
  final Object? rejectReason;
}

/// When and how a `ChatModelAgent` calls its model again.
///
/// Port of eino `adk.ModelRetryConfig`. Without [shouldRetry] every error is
/// retried (eino's deprecated `IsRetryAble` is not ported). With
/// [shouldRetry] the policy also sees successful answers and may reject them.
@immutable
final class ModelRetryConfig {
  /// A retry policy.
  const ModelRetryConfig({this.maxRetries = 0, this.shouldRetry, this.backoff});

  /// How many calls may follow the first one.
  final int maxRetries;

  /// Decides after every attempt; `null` from it means "do not retry".
  final FutureOr<RetryDecision?> Function(RunContext ctx, RetryContext retry)?
      shouldRetry;

  /// How long to wait before attempt [attempt] (from 1); exponential with
  /// jitter by default (100 ms doubling, at most 10 s). Port of
  /// `BackoffFunc`.
  final Duration Function(RunContext ctx, int attempt)? backoff;
}

/// Every allowed model call failed.
///
/// Port of eino `adk.RetryExhaustedError`. As in eino (whose `Unwrap` is
/// the sentinel `ErrExceedMaxRetries`), the last failure is not its [cause]:
/// it is in [lastError], so that checks through the cause chain (an
/// interrupt, a cancel) do not see the failure of an earlier attempt.
class RetryExhaustedException extends ThreepioException {
  /// The calls ran out after [totalRetries] retries; [lastError] is the last
  /// failure.
  RetryExhaustedException({required this.totalRetries, this.lastError})
      : super(
          lastError == null
              ? 'exceeds max retries'
              : 'exceeds max retries: last error: $lastError',
        );

  /// What the last attempt failed with.
  final Object? lastError;

  /// The number of retries that were made.
  final int totalRetries;

  @override
  String toString() => 'RetryExhaustedException: $message';
}

/// The error a streamed model output ends with when the model will be called
/// again: the stream so far is not the agent's answer.
///
/// Port of eino `adk.WillRetryError`. It reaches the readers of the agent's
/// events at the end of the message stream; the retry follows as a new
/// event.
class WillRetryException extends ThreepioException {
  /// The stream failed with [cause] (text [errorText]) on attempt
  /// [retryAttempt] (from 0) and the model is called again.
  WillRetryException({
    required this.errorText,
    this.retryAttempt = 0,
    this.rejectReason,
    Object? cause,
  }) : super(errorText, cause: cause);

  /// The text of the error. Port of the field `ErrStr`.
  final String errorText;

  /// The attempt that failed, from 0.
  final int retryAttempt;

  /// Why the policy rejected the output, when it did. Port of
  /// `WillRetryError.RejectReason()`.
  final Object? rejectReason;

  @override
  String toString() => errorText;
}

/// Eino's default backoff: 100 ms doubling per attempt up to 10 s, plus up to
/// half of it as jitter. Port of eino `defaultBackoff`.
@internal
Duration defaultBackoff(RunContext ctx, int attempt) {
  const base = Duration(milliseconds: 100);
  const maxDelay = Duration(seconds: 10);
  if (attempt <= 0) return base;
  if (attempt > 7) {
    return maxDelay +
        Duration(microseconds: _random.nextInt(maxDelay.inMicroseconds ~/ 2));
  }
  var delay = base * (1 << (attempt - 1));
  if (delay > maxDelay) delay = maxDelay;
  return delay + Duration(microseconds: _random.nextInt(delay.inMicroseconds ~/ 2));
}

final _random = Random();

/// One verdict of a stream retry, for the readers of the event stream. Port
/// of eino `retryVerdict`.
@internal
final class RetryVerdict {
  /// A verdict.
  const RetryVerdict({
    required this.willRetry,
    this.retryAttempt = 0,
    this.error,
    this.rejectReason,
  });

  final bool willRetry;
  final int retryAttempt;
  final Object? error;
  final Object? rejectReason;
}

/// Hands the verdict of one stream attempt to the event stream. Port of eino
/// `retryVerdictSignal`.
@internal
final class RetryVerdictSignal {
  final Completer<RetryVerdict> _verdict = Completer<RetryVerdict>();

  /// The verdict, once decided.
  Future<RetryVerdict> get verdict => _verdict.future;

  /// Decides; later calls are ignored.
  void deliver(RetryVerdict verdict) {
    if (!_verdict.isCompleted) _verdict.complete(verdict);
  }
}

/// Whether [error] is a cancel injected into a stream (eino
/// `ErrStreamCanceled`).
@internal
bool isStreamCanceled(Object? error) =>
    error != null &&
    ThreepioException.findCause<StreamCanceledException>(error) != null;

/// Waits [delay], or fails with [CancelledException] when [ctx] is cancelled
/// first. Port of `contextAwareSleep`.
@internal
Future<void> sleepUnlessCancelled(RunContext ctx, Duration delay) async {
  if (delay <= Duration.zero) return;
  ctx.cancelToken.throwIfCancelled();
  final done = Completer<void>();
  final timer = Timer(delay, () {
    if (!done.isCompleted) done.complete();
  });
  unawaited(ctx.cancelToken.whenCancelled.then((_) {
    if (done.isCompleted) return;
    timer.cancel();
    done.completeError(CancelledException(ctx.cancelToken.reason));
  }));
  return done.future;
}

Future<void> _setRetryAttempt(RunContext ctx, int attempt) async {
  try {
    await processState<ReactState>(ctx, (_, state) => state.retryAttempt = attempt);
    // Outside an agent there is no state to note the attempt in.
    // ignore: avoid_catching_errors
  } on StateError {
    return;
  }
}

/// A model that calls [inner] again by [config]. Port of eino
/// `typedRetryModelWrapper`.
@internal
final class RetryModel extends BaseChatModel {
  /// [inner] with retries by [config].
  RetryModel(this.inner, this.config);

  final BaseChatModel inner;
  final ModelRetryConfig config;

  Duration Function(RunContext, int) get _backoff =>
      config.backoff ?? defaultBackoff;

  static RunContext _ctxOf(ChatModelOptions? options) =>
      options?.runContext ?? RunContext.background();

  static bool _final(Object error) => isInterrupt(error) || isStreamCanceled(error);

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) =>
      config.shouldRetry != null
          ? _generateWithShouldRetry(input, options)
          : _generateLegacy(input, options);

  Future<Message> _generateLegacy(
    List<Message> input,
    ChatModelOptions? options,
  ) async {
    final ctx = _ctxOf(options);
    Object? lastError;
    for (var attempt = 0; attempt <= config.maxRetries; attempt++) {
      try {
        return await inner.generate(input, options: options);
        // Every failure is a candidate for a retry.
        // ignore: avoid_catches_without_on_clauses
      } catch (error) {
        if (_final(error)) rethrow;
        lastError = error;
      }
      if (attempt < config.maxRetries) {
        await sleepUnlessCancelled(ctx, _backoff(ctx, attempt + 1));
      }
    }
    throw RetryExhaustedException(
      lastError: lastError,
      totalRetries: config.maxRetries,
    );
  }

  Future<Message> _generateWithShouldRetry(
    List<Message> input,
    ChatModelOptions? options,
  ) async {
    final ctx = _ctxOf(options);
    final exec = execContextOf(ctx);
    var currentInput = input;
    var currentOptions = options;
    Object? lastError;
    try {
      for (var attempt = 0; attempt <= config.maxRetries; attempt++) {
        await _setRetryAttempt(ctx, attempt);
        exec?.suppressEventSend = true;
        Message? output;
        Object? error;
        try {
          output = await inner.generate(currentInput, options: currentOptions);
          // The policy sees every failure.
          // ignore: avoid_catches_without_on_clauses
        } catch (thrown) {
          if (_final(thrown)) rethrow;
          error = thrown;
        } finally {
          exec?.suppressEventSend = false;
        }
        final decision = await config.shouldRetry!(
              ctx,
              RetryContext(
                retryAttempt: attempt + 1,
                inputMessages: currentInput,
                options: currentOptions,
                outputMessage: output,
                error: error,
              ),
            ) ??
            const RetryDecision();
        if (!decision.retry) {
          final rewrite = decision.rewriteError;
          // ignore: only_throw_errors
          if (rewrite != null) throw rewrite;
          // ignore: only_throw_errors
          if (error != null) throw error;
          if (exec != null && output != null) {
            exec.send(AgentEvent.fromMessage(output, role: RoleType.assistant));
          }
          return output!;
        }
        lastError = error ??
            ThreepioException(
              'model output rejected by ShouldRetry at attempt ${attempt + 1}',
            );
        if (attempt >= config.maxRetries) break;
        (currentInput, currentOptions) = await _apply(
          ctx,
          decision,
          currentInput,
          currentOptions,
        );
        await sleepUnlessCancelled(
          ctx,
          decision.backoff ?? _backoff(ctx, attempt + 1),
        );
      }
    } finally {
      await _setRetryAttempt(ctx, 0);
    }
    throw RetryExhaustedException(
      lastError: lastError,
      totalRetries: config.maxRetries,
    );
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) =>
      config.shouldRetry != null
          ? _streamWithShouldRetry(input, options)
          : _streamLegacy(input, options);

  Future<StreamReader<Message>> _streamLegacy(
    List<Message> input,
    ChatModelOptions? options,
  ) async {
    final ctx = _ctxOf(options);
    Object? lastError;
    try {
      for (var attempt = 0; attempt <= config.maxRetries; attempt++) {
        await _setRetryAttempt(ctx, attempt);
        final StreamReader<Message> stream;
        try {
          stream = await inner.stream(input, options: options);
          // Every failure is a candidate for a retry.
          // ignore: avoid_catches_without_on_clauses
        } catch (error) {
          if (_final(error)) rethrow;
          lastError = error;
          if (attempt < config.maxRetries) {
            await sleepUnlessCancelled(ctx, _backoff(ctx, attempt + 1));
          }
          continue;
        }
        final [check, returned] = stream.copy(2);
        final streamError = await _errorOf(check);
        if (streamError == null) return returned;
        await returned.close();
        if (isStreamCanceled(streamError)) throw streamError;
        lastError = streamError;
        if (attempt < config.maxRetries) {
          await sleepUnlessCancelled(ctx, _backoff(ctx, attempt + 1));
        }
      }
    } finally {
      await _setRetryAttempt(ctx, 0);
    }
    throw RetryExhaustedException(
      lastError: lastError,
      totalRetries: config.maxRetries,
    );
  }

  Future<StreamReader<Message>> _streamWithShouldRetry(
    List<Message> input,
    ChatModelOptions? options,
  ) async {
    final ctx = _ctxOf(options);
    final exec = execContextOf(ctx);
    var currentInput = input;
    var currentOptions = options;
    Object? lastError;
    RetryVerdictSignal? current;
    try {
      for (var attempt = 0; attempt <= config.maxRetries; attempt++) {
        await _setRetryAttempt(ctx, attempt);
        final signal = current = RetryVerdictSignal();
        exec?.retryVerdictSignal = signal;
        final StreamReader<Message> stream;
        try {
          stream = await inner.stream(currentInput, options: currentOptions);
          // The policy sees every failure.
          // ignore: avoid_catches_without_on_clauses
        } catch (error) {
          signal.deliver(const RetryVerdict(willRetry: false));
          if (_final(error)) rethrow;
          final decision = await config.shouldRetry!(
                ctx,
                RetryContext(
                  retryAttempt: attempt + 1,
                  inputMessages: currentInput,
                  options: currentOptions,
                  error: error,
                ),
              ) ??
              const RetryDecision();
          if (!decision.retry) {
            final rewrite = decision.rewriteError;
            // ignore: only_throw_errors
            if (rewrite != null) throw rewrite;
            rethrow;
          }
          lastError = error;
          if (attempt < config.maxRetries) {
            (currentInput, currentOptions) = await _apply(
              ctx,
              decision,
              currentInput,
              currentOptions,
            );
            await sleepUnlessCancelled(
              ctx,
              decision.backoff ?? _backoff(ctx, attempt + 1),
            );
          }
          continue;
        }

        final [check, returned] = stream.copy(2);
        final (message, streamError) = await consumeMessageStream(check);
        if (isStreamCanceled(streamError)) {
          signal.deliver(const RetryVerdict(willRetry: false));
          await returned.close();
          throw streamError!;
        }
        final decision = await config.shouldRetry!(
              ctx,
              RetryContext(
                retryAttempt: attempt + 1,
                inputMessages: currentInput,
                options: currentOptions,
                outputMessage: message,
                error: streamError,
              ),
            ) ??
            const RetryDecision();
        if (!decision.retry) {
          signal.deliver(const RetryVerdict(willRetry: false));
          final rewrite = decision.rewriteError;
          if (rewrite != null) {
            await returned.close();
            // ignore: only_throw_errors
            throw rewrite;
          }
          if (streamError != null) {
            await returned.close();
            // ignore: only_throw_errors
            throw streamError;
          }
          return returned;
        }
        final verdictError = streamError ??
            ThreepioException(
              'model output rejected by ShouldRetry at attempt ${attempt + 1}',
            );
        signal.deliver(
          RetryVerdict(
            willRetry: true,
            retryAttempt: attempt,
            error: verdictError,
            rejectReason: decision.rejectReason,
          ),
        );
        await returned.close();
        lastError = verdictError;
        if (attempt < config.maxRetries) {
          (currentInput, currentOptions) = await _apply(
            ctx,
            decision,
            currentInput,
            currentOptions,
          );
          await sleepUnlessCancelled(
            ctx,
            decision.backoff ?? _backoff(ctx, attempt + 1),
          );
        }
      }
    } on Object catch (error) {
      current?.deliver(RetryVerdict(willRetry: false, error: error));
      rethrow;
    } finally {
      await _setRetryAttempt(ctx, 0);
    }
    throw RetryExhaustedException(
      lastError: lastError,
      totalRetries: config.maxRetries,
    );
  }

  // Port of eino `applyDecisionForRetry`.
  static Future<(List<Message>, ChatModelOptions?)> _apply(
    RunContext ctx,
    RetryDecision decision,
    List<Message> input,
    ChatModelOptions? options,
  ) async {
    var nextInput = input;
    final modified = decision.modifiedInputMessages;
    if (modified != null) {
      nextInput = modified;
      if (decision.persistModifiedInputMessages) {
        try {
          await processState<ReactState>(
            ctx,
            (_, state) => state.messages = List.of(modified),
          );
          // Outside an agent there is no history to replace.
          // ignore: avoid_catching_errors
        } on StateError {
          // Nothing to persist.
        }
      }
    }
    final additional = decision.additionalOptions;
    final nextOptions = additional == null
        ? options
        : (options ?? const ChatModelOptions()).merge(additional);
    return (nextInput, nextOptions);
  }

  static Future<Object?> _errorOf(StreamReader<Message> stream) async {
    try {
      while (await stream.nextOrNull() != null) {}
      return null;
      // The error of the stream is the result.
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      return error;
    } finally {
      await stream.close();
    }
  }
}

/// Reads [stream] to its end and joins what arrived; the error it ended with
/// is returned beside the joined chunks. Port of eino `typedConsumeStream`.
@internal
Future<(Message?, Object?)> consumeMessageStream(
  StreamReader<Message> stream,
) async {
  final chunks = <Message>[];
  Object? error;
  try {
    for (var chunk = await stream.nextOrNull();
        chunk != null;
        chunk = await stream.nextOrNull()) {
      chunks.add(chunk);
    }
    // The error of the stream is part of the result.
    // ignore: avoid_catches_without_on_clauses
  } catch (thrown) {
    error = thrown;
  } finally {
    await stream.close();
  }
  Message? joined;
  if (chunks.isNotEmpty) {
    try {
      joined = concatMessages(chunks);
      // Eino ignores a failure to join here.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      joined = null;
    }
  }
  return (joined, error);
}
