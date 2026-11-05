/// Switching a `ChatModelAgent` to another model when a call fails.
///
/// Port of eino `adk/failover_chatmodel.go`.
library;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../../components/component_type.dart';
import '../../components/component_type.dart' as component;
import '../../components/model/base_chat_model.dart';
import '../../components/model/chat_model_options.dart';
import '../../core/interrupt_signal.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../streaming/stream_reader.dart';
import 'agent_context.dart';
import 'event_senders.dart';
import 'model_retry.dart';

final _log = Logger('threepio.adk');

/// What a failover policy is told before it picks the next model.
///
/// Port of eino `adk.FailoverContext`.
@immutable
final class FailoverContext {
  /// The context of failover attempt [failoverAttempt].
  const FailoverContext({
    required this.failoverAttempt,
    required this.inputMessages,
    this.lastOutputMessage,
    this.lastError,
  });

  /// The number of the failover attempt, from 1.
  final int failoverAttempt;

  /// What the agent sent the model.
  final List<Message> inputMessages;

  /// What the last model answered, joined, if anything.
  final Message? lastOutputMessage;

  /// What the last model failed with.
  final Object? lastError;
}

/// Which model a `ChatModelAgent` falls back to.
///
/// Port of eino `adk.ModelFailoverConfig`. The agent first calls the model
/// that succeeded last (at first the configured model); when that fails and
/// [shouldFailover] agrees, [getFailoverModel] picks the model of each of up
/// to [maxRetries] more attempts. Failover wraps retry: every attempt is
/// retried by `ModelRetryConfig` first.
@immutable
final class ModelFailoverConfig {
  /// A failover policy.
  const ModelFailoverConfig({
    required this.shouldFailover,
    required this.getFailoverModel,
    this.maxRetries = 0,
  });

  /// How many failover attempts may follow the first call.
  final int maxRetries;

  /// Whether to try another model after an answer [outputMessage] or an
  /// error [outputError].
  final FutureOr<bool> Function(
    RunContext ctx,
    Message? outputMessage,
    Object? outputError,
  ) shouldFailover;

  /// The model of the next attempt and, optionally, the messages to send it
  /// (`null` sends the agent's messages).
  final FutureOr<(BaseChatModel, List<Message>?)> Function(
    RunContext ctx,
    FailoverContext failover,
  ) getFailoverModel;
}

final _currentModelKey = ContextKey<BaseChatModel>('adk.failoverCurrentModel');
final _hasMoreKey = ContextKey<bool>('adk.failoverHasMoreAttempts');

/// Whether a failover attempt follows the one [ctx] belongs to. Port of eino
/// `getFailoverHasMoreAttempts`.
@internal
bool failoverHasMoreAttempts(RunContext ctx) => ctx.value(_hasMoreKey) ?? false;

ChatModelOptions _withContext(ChatModelOptions? options, RunContext ctx) =>
    (options ?? const ChatModelOptions()).copyWith(runContext: ctx);

/// The model that dispatches to the model the failover chose. Port of eino
/// `typedFailoverProxyModel`.
@internal
final class FailoverProxyModel extends BaseChatModel
    implements TypedComponent, CallbackAwareComponent {
  /// A proxy.
  FailoverProxyModel();

  BaseChatModel _target(ChatModelOptions? options) {
    final target = options?.runContext?.value(_currentModelKey);
    if (target == null) {
      throw StateError('failover current model not found in context');
    }
    return component.isCallbacksEnabled(target)
        ? bindToolsFor(target, options)
        : CallbackInjectedModel(target);
  }

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) =>
      _target(options).generate(input, options: options);

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) =>
      _target(options).stream(input, options: options);

  @override
  bool get isCallbacksEnabled => true;

  @override
  String get componentTypeName => 'FailoverProxyModel';
}

/// A model that tries other models by [config]. Port of eino
/// `failoverModelWrapper`.
@internal
final class FailoverModel extends BaseChatModel {
  /// [inner] (the chain down to the proxy) with failover by [config].
  FailoverModel(this.inner, this.config);

  final BaseChatModel inner;
  final ModelFailoverConfig config;

  Future<bool> _needFailover(
    RunContext ctx,
    Message? output,
    Object? error,
  ) async {
    if (ctx.cancelToken.isCancelled) return false;
    if (error != null && (isInterrupt(error) || isStreamCanceled(error))) {
      return false;
    }
    return config.shouldFailover(ctx, output, error);
  }

  RunContext _attemptContext(RunContext ctx, BaseChatModel model, bool hasMore) =>
      ctx.withValue(_currentModelKey, model).withValue(_hasMoreKey, hasMore);

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final ctx = options?.runContext ?? RunContext.background();
    final exec = execContextOf(ctx);
    Message? lastOutput;
    Object? lastError;
    StackTrace? lastTrace;

    final lastSuccess = exec?.failoverLastSuccessModel;
    if (lastSuccess != null) {
      ctx.cancelToken.throwIfCancelled();
      final attemptCtx =
          _attemptContext(ctx, lastSuccess, config.maxRetries > 0);
      try {
        return await inner.generate(
          input,
          options: _withContext(options, attemptCtx),
        );
        // Every failure may fail over.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        lastError = error;
        lastTrace = stackTrace;
        if (!await _needFailover(ctx, null, error)) rethrow;
        _log.warning(
          'failover ChatModel.generate lastSuccessModel failed: $error',
        );
      }
    }

    for (var attempt = 1; attempt <= config.maxRetries; attempt++) {
      ctx.cancelToken.throwIfCancelled();
      final (model, messages) = await config.getFailoverModel(
        ctx,
        FailoverContext(
          failoverAttempt: attempt,
          inputMessages: input,
          lastOutputMessage: lastOutput,
          lastError: lastError,
        ),
      );
      final attemptCtx =
          _attemptContext(ctx, model, attempt < config.maxRetries);
      try {
        final result = await inner.generate(
          messages ?? input,
          options: _withContext(options, attemptCtx),
        );
        exec?.failoverLastSuccessModel = model;
        return result;
        // Every failure may fail over.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        lastOutput = null;
        lastError = error;
        lastTrace = stackTrace;
        if (!await _needFailover(ctx, null, error)) rethrow;
        if (attempt < config.maxRetries) {
          _log.warning('failover ChatModel.generate attempt $attempt failed: '
              '$error');
        }
      }
    }
    if (lastError != null) Error.throwWithStackTrace(lastError, lastTrace!);
    throw const ThreepioException('failover: no model was called');
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final ctx = options?.runContext ?? RunContext.background();
    final exec = execContextOf(ctx);
    Message? lastOutput;
    Object? lastError;
    StackTrace? lastTrace;

    Future<StreamReader<Message>?> attempt(
      BaseChatModel model,
      List<Message> messages,
      bool hasMore,
    ) async {
      final attemptCtx = _attemptContext(ctx, model, hasMore);
      final StreamReader<Message> stream;
      try {
        stream = await inner.stream(
          messages,
          options: _withContext(options, attemptCtx),
        );
        // Every failure may fail over.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        lastOutput = null;
        lastError = error;
        lastTrace = stackTrace;
        if (!await _needFailover(ctx, null, error)) rethrow;
        return null;
      }
      final [check, returned] = stream.copy(2);
      final (output, streamError) = await consumeMessageStream(check);
      if (streamError == null) return returned;
      lastOutput = output;
      lastError = streamError;
      lastTrace = StackTrace.current;
      await returned.close();
      if (!await _needFailover(ctx, output, streamError)) {
        // ignore: only_throw_errors
        throw streamError;
      }
      return null;
    }

    final lastSuccess = exec?.failoverLastSuccessModel;
    if (lastSuccess != null) {
      ctx.cancelToken.throwIfCancelled();
      final result = await attempt(lastSuccess, input, config.maxRetries > 0);
      if (result != null) return result;
      _log.warning('failover ChatModel.stream lastSuccessModel failed: '
          '$lastError');
    }

    for (var number = 1; number <= config.maxRetries; number++) {
      ctx.cancelToken.throwIfCancelled();
      final (model, messages) = await config.getFailoverModel(
        ctx,
        FailoverContext(
          failoverAttempt: number,
          inputMessages: input,
          lastOutputMessage: lastOutput,
          lastError: lastError,
        ),
      );
      final result =
          await attempt(model, messages ?? input, number < config.maxRetries);
      if (result != null) {
        exec?.failoverLastSuccessModel = model;
        return result;
      }
      if (number < config.maxRetries) {
        _log.warning('failover ChatModel.stream attempt $number failed: '
            '$lastError');
      }
    }
    if (lastError != null) Error.throwWithStackTrace(lastError!, lastTrace!);
    throw const ThreepioException('failover: no model was called');
  }
}
