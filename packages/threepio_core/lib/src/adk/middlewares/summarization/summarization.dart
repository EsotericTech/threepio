/// A middleware that summarizes the conversation when it gets too long.
///
/// Port of eino `adk/middlewares/summarization/summarization.go` (classic
/// messages; the agentic path is P13).
library;

import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

import '../../../components/model/base_chat_model.dart';
import '../../../components/model/cancel_token.dart';
import '../../../components/model/chat_model_options.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/tool_info.dart';
import '../../eino/agent_action.dart';
import '../../eino/agent_context.dart';
import '../../eino/agent_event.dart';
import '../../eino/middleware.dart';
import '../../eino/middleware_context.dart';
import '../../eino/model_retry.dart' show sleepUnlessCancelled;
import '../internal/go_compat.dart';
import 'customized_action.dart';
import 'prompt.dart';

/// The `extra` key that marks the messages the middleware writes. Port of
/// `extraKeyContentType`.
@internal
const String summarizationContentTypeKey = '_eino_summarization_content_type';

/// The `extra` value of a summary message. Port of `contentTypeSummary`.
@internal
const String contentTypeSummary = 'summary';

/// The `extra` value of a preserved-skills message. Port of
/// `contentTypeSkills`.
@internal
const String contentTypeSkills = 'skills';

/// How many tokens of the user's own messages a summary keeps. Port of
/// `preserveUserMsgsMaxTokens`.
const int _preserveUserMsgsMaxTokens = 30000;

/// The trigger used when none is configured. Port of
/// `defaultTriggerContextTokens`.
const int _defaultTriggerContextTokens = 160000;

/// What a media part counts in the default estimate. Port of
/// `multimodalTokenEstimate`.
const int _multimodalTokenEstimate = 2000;

final ContextKey<List<Message>> _modelInputKey = ContextKey<List<Message>>('summarization.modelInput');

/// The model input of the summary being finalized, which finalizer steps
/// such as `PreserveSkills` read. Port of the `ctxKeyModelInput` value.
@internal
List<Message>? summarizationModelInputOf(RunContext ctx) => ctx.value(_modelInputKey);

/// What a token counter counts. Port of eino
/// `summarization.TokenCounterInput`.
@immutable
final class TokenCounterInput {
  /// The [messages] and [tools] to count.
  const TokenCounterInput({required this.messages, this.tools = const []});

  /// The messages.
  final List<Message> messages;

  /// The tools the model is told about.
  final List<ToolInfo> tools;
}

/// Counts the tokens of messages and tools. Port of eino
/// `summarization.TokenCounterFunc`.
typedef SummarizationTokenCounter = FutureOr<int> Function(
  RunContext ctx,
  TokenCounterInput input,
);

/// Builds the input of the summary model from the system instruction, the
/// user instruction and the whole history. Port of eino
/// `summarization.GenModelInputFunc`.
typedef SummarizationModelInputBuilder = FutureOr<List<Message>> Function(
  RunContext ctx,
  Message systemInstruction,
  Message userInstruction,
  List<Message> originalMessages,
);

/// Turns the model's summary into the new history. Port of eino
/// `summarization.FinalizeFunc`.
typedef SummaryFinalizer = FutureOr<List<Message>> Function(
  RunContext ctx,
  List<Message> originalMessages,
  Message summary,
);

/// Sees the state before and after a summary; must not change them. Port of
/// eino `summarization.CallbackFunc`.
typedef SummarizationCallback = FutureOr<void> Function(
  RunContext ctx,
  ChatModelAgentState before,
  ChatModelAgentState after,
);

/// Decides from an attempt's answer and error whether to try again. Port of
/// the `ShouldRetry`/`ShouldFailover` fields.
typedef SummaryAttemptPredicate = bool Function(
  RunContext ctx,
  Message? response,
  Object? error,
);

/// The wait before attempt [attempt] + 1 (attempt starts at 1). Port of the
/// `BackoffFunc` fields.
typedef SummaryBackoff = Duration Function(
  RunContext ctx,
  int attempt,
  Message? response,
  Object? error,
);

/// Chooses the model and its input for a failover attempt. Port of eino
/// `summarization.GetFailoverModelFunc`; the input must not be empty.
typedef SummaryFailoverModelGetter = FutureOr<(BaseChatModel, List<Message>)> Function(
  RunContext ctx,
  SummarizationFailoverContext failoverContext,
);

/// When to summarize: when **any** set condition is met. Port of eino
/// `summarization.TriggerCondition`.
///
/// As in eino, a trigger replaces the default of 160 000 tokens with
/// [contextTokens] even when that is 0 (any token count above 0 fires).
@immutable
final class SummarizationTrigger {
  /// A trigger; at least one condition must be above 0.
  const SummarizationTrigger({this.contextTokens = 0, this.contextMessages = 0});

  /// Summarize when the token count exceeds this.
  final int contextTokens;

  /// Summarize when the number of messages exceeds this.
  final int contextMessages;

  void _check() {
    if (contextTokens < 0) {
      throw ArgumentError.value(contextTokens, 'contextTokens', 'contextTokens must be non-negative');
    }
    if (contextMessages < 0) {
      throw ArgumentError.value(
        contextMessages,
        'contextMessages',
        'contextMessages must be non-negative',
      );
    }
    if (contextTokens == 0 && contextMessages == 0) {
      throw ArgumentError(
        'at least one of contextTokens or contextMessages must be non-negative',
      );
    }
  }
}

/// Retries of the primary model. Port of eino `summarization.RetryConfig`.
@immutable
final class SummarizationRetryConfig {
  /// Retries by [shouldRetry] (default: any error), waiting [backoff]
  /// (default: exponential from 1 s, capped at 10 s, with jitter).
  const SummarizationRetryConfig({this.maxRetries, this.shouldRetry, this.backoff});

  /// How many retries after the first attempt; `null` is 3.
  final int? maxRetries;

  /// Whether an attempt should be retried; `null` retries on an error.
  final SummaryAttemptPredicate? shouldRetry;

  /// The wait before the next attempt; `null` for the default.
  final SummaryBackoff? backoff;
}

/// Failover after the primary model gave up. Port of eino
/// `summarization.FailoverConfig`.
@immutable
final class SummarizationFailoverConfig {
  /// Fails over by [shouldFailover] (default: any error) at most
  /// [maxRetries] times (default 3).
  const SummarizationFailoverConfig({
    this.maxRetries,
    this.shouldFailover,
    this.backoff,
    this.getFailoverModel,
  });

  /// How many failover attempts; `null` is 3.
  final int? maxRetries;

  /// Whether to fail over (again); `null` fails over on an error.
  final SummaryAttemptPredicate? shouldFailover;

  /// The wait before the next failover attempt; `null` for the default.
  final SummaryBackoff? backoff;

  /// The model and input of an attempt; `null` reuses the primary model
  /// with the default input.
  final SummaryFailoverModelGetter? getFailoverModel;
}

/// What a failover attempt knows. Port of eino
/// `summarization.FailoverContext`.
@immutable
final class SummarizationFailoverContext {
  /// The context of failover attempt [attempt].
  const SummarizationFailoverContext({
    required this.attempt,
    required this.systemInstruction,
    required this.userInstruction,
    required this.originalMessages,
    this.lastModelResponse,
    this.lastError,
  });

  /// The attempt, from 1.
  final int attempt;

  /// The system instruction of the summary (set by the middleware).
  final Message systemInstruction;

  /// The user instruction of the summary.
  final Message userInstruction;

  /// The whole history before the summary.
  final List<Message> originalMessages;

  /// The previous attempt's answer, if any.
  final Message? lastModelResponse;

  /// The previous attempt's error, if any.
  final Object? lastError;
}

/// The result of one model attempt: what it answered and what it threw (Go
/// returns both as values).
@visibleForTesting
typedef SummaryAttemptResult = ({Message? response, Object? error, StackTrace? stackTrace});

/// Summarizes the conversation once it gets too long, before a model call.
///
/// Port of eino `summarization.New`. Before every model call the history is
/// measured (by [tokenCounter], by default the total tokens of the last
/// assistant answer plus about one token per 4 bytes of what came after it,
/// tools included). When it is over [trigger] (default 160 000 tokens) the
/// conversation is sent to [model] with a summary instruction, and the
/// history becomes: the system messages, then one user message with the
/// summary (between a preamble and an instruction to go on; the summary's
/// `<all_user_messages>` block is replaced with the user's latest messages,
/// up to about 30 000 tokens; [transcriptFilePath] is mentioned when set).
/// [finalize] replaces that post-processing ([SummaryFinalizerBuilder]
/// builds one with extra steps; [defaultSummaryFinalize] is the default).
///
/// With [emitInternalEvents] the run gets events whose `customizedAction`
/// is a [SummarizationAction]: before the summary, for every model attempt,
/// and after it.
///
/// Put this middleware **before** the agents.md middleware.
final class SummarizationMiddleware extends ChatModelAgentMiddleware {
  /// A middleware that summarizes with [model].
  ///
  /// Throws [ArgumentError] for an invalid [trigger], or a negative
  /// `maxRetries` in [retry] or [failover].
  SummarizationMiddleware({
    required this.model,
    this.modelOptions,
    this.tokenCounter,
    this.trigger,
    this.emitInternalEvents = false,
    this.userInstruction = '',
    this.transcriptFilePath = '',
    this.genModelInput,
    this.finalize,
    this.callback,
    this.retry,
    this.failover,
  }) {
    trigger?._check();
    final retryMax = retry?.maxRetries;
    if (retryMax != null && retryMax < 0) {
      throw ArgumentError.value(retryMax, 'retry.maxRetries', 'retry.MaxRetries must be non-negative');
    }
    final failoverMax = failover?.maxRetries;
    if (failoverMax != null && failoverMax < 0) {
      throw ArgumentError.value(
        failoverMax,
        'failover.maxRetries',
        'failover.MaxRetries must be non-negative',
      );
    }
    ensureSummarizationTypesRegistered();
  }

  /// The model that writes the summary.
  final BaseChatModel model;

  /// Options for the summary model's calls.
  final ChatModelOptions? modelOptions;

  /// Counts tokens; `null` for the default estimate.
  final SummarizationTokenCounter? tokenCounter;

  /// When to summarize; `null` is above 160 000 tokens.
  final SummarizationTrigger? trigger;

  /// Whether to send [SummarizationAction] events.
  final bool emitInternalEvents;

  /// Replaces the default summary instruction (the last user message of the
  /// model input) when not empty.
  final String userInstruction;

  /// Where the full transcript is kept; the summary tells the model. Only
  /// used without [finalize].
  final String transcriptFilePath;

  /// Builds the summary model's input; `null` for system instruction, the
  /// history without its system messages, then the user instruction.
  final SummarizationModelInputBuilder? genModelInput;

  /// Builds the new history from the summary; `null` for the default.
  final SummaryFinalizer? finalize;

  /// Called after [finalize] with the states before and after.
  final SummarizationCallback? callback;

  /// Retries of [model]; `null` is none.
  final SummarizationRetryConfig? retry;

  /// Failover after [model] gave up; `null` is none.
  final SummarizationFailoverConfig? failover;

  @override
  Future<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async {
    final triggered = await shouldSummarize(
      ctx,
      TokenCounterInput(messages: state.messages, tools: state.toolInfos),
    );
    if (!triggered) return (ctx, state);
    final messages = await summarize(ctx, state);
    return (
      ctx,
      ChatModelAgentState(
        messages: messages,
        toolInfos: state.toolInfos,
        deferredToolInfos: state.deferredToolInfos,
      ),
    );
  }

  /// Summarizes [state]'s messages now and returns the new history, whatever
  /// the trigger says. Port of eino `Middleware.Summarize`.
  Future<List<Message>> summarize(RunContext ctx, ChatModelAgentState state) async {
    final before = _copyState(state);
    if (emitInternalEvents) {
      await _emit(
        ctx,
        SummarizationAction(
          type: SummarizationActionType.beforeSummarize,
          before: BeforeSummarizeAction(messages: before.messages),
        ),
      );
    }
    final (rawSummary, modelInput) = await _summarize(ctx, before.messages);
    final finalizeCtx = ctx.withValue(_modelInputKey, modelInput);
    final finalizer = finalize ?? _internalFinalizer;
    final finalMessages = await finalizer(finalizeCtx, before.messages, rawSummary);

    final callback = this.callback;
    if (callback != null) {
      final after = _copyState(before)..messages = List.of(finalMessages);
      await callback(ctx, before, after);
    }
    if (emitInternalEvents) {
      await _emit(
        ctx,
        SummarizationAction(
          type: SummarizationActionType.afterSummarize,
          after: AfterSummarizeAction(messages: finalMessages),
        ),
      );
    }
    return finalMessages;
  }

  /// Whether [input] is over the trigger. Port of `shouldSummarize`.
  @visibleForTesting
  Future<bool> shouldSummarize(RunContext ctx, TokenCounterInput input) async {
    final trigger = this.trigger;
    if (trigger != null && trigger.contextMessages > 0) {
      if (input.messages.length > trigger.contextMessages) return true;
    }
    final int tokens;
    try {
      tokens = await countTokens(ctx, input);
    } on Object catch (error) {
      throw ThreepioException('failed to count tokens: ${goValueString(error)}', cause: error);
    }
    return tokens > (trigger?.contextTokens ?? _defaultTriggerContextTokens);
  }

  /// The tokens of [input], by [tokenCounter] or the default estimate. Port
  /// of `countTokens`.
  @visibleForTesting
  Future<int> countTokens(RunContext ctx, TokenCounterInput input) async {
    final counter = tokenCounter;
    if (counter != null) return counter(ctx, input);
    return defaultSummarizationTokenCount(input);
  }

  Future<(Message, List<Message>)> _summarize(RunContext ctx, List<Message> originalMessages) async {
    final (_, contextMessages) = splitSystemAndContextMessages(originalMessages);
    var modelInput = await buildSummarizationModelInput(ctx, originalMessages, contextMessages);
    var attempt = await generateWithRetry(ctx, model, modelInput, retry);
    if (_shouldFailover(ctx, failover, attempt.response, attempt.error)) {
      final (failoverAttempt, failoverInput) =
          await runFailover(ctx, originalMessages, modelInput, attempt.response, attempt.error);
      _throwIfError(failoverAttempt);
      attempt = failoverAttempt;
      modelInput = failoverInput;
    } else if (attempt.error != null) {
      Error.throwWithStackTrace(
        ThreepioException(
          'failed to generate summary: ${goValueString(attempt.error)}',
          cause: attempt.error,
        ),
        attempt.stackTrace ?? StackTrace.current,
      );
    }
    final summary = attempt.response;
    if (summary == null) throw const ThreepioException('summary content is empty');
    return (summary, modelInput);
  }

  /// The default model input: system instruction, the history without its
  /// leading system messages, user instruction; or [genModelInput]. Port of
  /// `buildSummarizationModelInput`.
  @visibleForTesting
  Future<List<Message>> buildSummarizationModelInput(
    RunContext ctx,
    List<Message> originalMessages,
    List<Message> contextMessages,
  ) async {
    final (system, user) = modelInstructions();
    final builder = genModelInput;
    if (builder != null) {
      try {
        return await builder(ctx, system, user, originalMessages);
      } on Object catch (error) {
        throw ThreepioException(
          'failed to generate model input: ${goValueString(error)}',
          cause: error,
        );
      }
    }
    return [system, ...contextMessages, user];
  }

  /// The system and user instruction messages of the summary. Port of
  /// `getModelInstructions`.
  @visibleForTesting
  (Message, Message) modelInstructions() {
    final user = userInstruction.isEmpty ? getUserSummaryInstruction() : userInstruction;
    return (Message.system(getSystemInstruction()), Message.user(user));
  }

  /// Calls [chatModel] with retries by [retryConfig]; the result carries the
  /// last answer and error (as values, as in Go). Port of
  /// `generateWithRetry`.
  @visibleForTesting
  Future<SummaryAttemptResult> generateWithRetry(
    RunContext ctx,
    BaseChatModel chatModel,
    List<Message> input,
    SummarizationRetryConfig? retryConfig,
  ) async {
    if (retryConfig == null) {
      return _generateAndEmit(ctx, chatModel, input, 1, GenerateSummaryPhase.primary);
    }
    final shouldRetry = retryConfig.shouldRetry ?? _defaultShouldRetry;
    final backoff = retryConfig.backoff ?? _defaultBackoff;
    final maxRetries = retryConfig.maxRetries ?? 3;
    final totalAttempts = maxRetries + 1;
    Message? lastResponse;
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 1; attempt <= totalAttempts; attempt++) {
      final result = await _generateAndEmit(ctx, chatModel, input, attempt, GenerateSummaryPhase.primary);
      if (!shouldRetry(ctx, result.response, result.error)) return result;
      lastResponse = result.response;
      lastError = result.error;
      lastStackTrace = result.stackTrace;
      if (attempt < totalAttempts) {
        final cancelled = await _wait(ctx, backoff(ctx, attempt, result.response, result.error));
        if (cancelled != null) return (response: null, error: cancelled, stackTrace: null);
      }
    }
    if (maxRetries > 0) {
      return (
        response: lastResponse,
        error: ThreepioException(
          // Go formats a nil error with %w as "%!w(<nil>)".
          'exceeds max retries: ${lastError == null ? '%!w(<nil>)' : goValueString(lastError)}',
          cause: lastError,
        ),
        stackTrace: lastStackTrace,
      );
    }
    return (response: lastResponse, error: lastError, stackTrace: lastStackTrace);
  }

  /// The failover rounds after the primary model gave up; returns the last
  /// attempt (which may carry an error) and the input it used. Port of
  /// `runFailover`.
  @visibleForTesting
  Future<(SummaryAttemptResult, List<Message>)> runFailover(
    RunContext ctx,
    List<Message> originalMessages,
    List<Message> defaultInput,
    Message? lastResponse,
    Object? lastError,
  ) async {
    final config = failover;
    final (system, user) = modelInstructions();
    final maxRetries = config?.maxRetries ?? 3;
    final backoff = config?.backoff ?? _defaultBackoff;
    var modelInput = defaultInput;
    SummaryAttemptResult last = (response: lastResponse, error: lastError, stackTrace: null);
    if (maxRetries <= 0) return (last, modelInput);

    for (var attempt = 1;; attempt++) {
      final failoverContext = SummarizationFailoverContext(
        attempt: attempt,
        systemInstruction: system,
        userInstruction: user,
        originalMessages: originalMessages,
        lastModelResponse: last.response,
        lastError: last.error,
      );
      BaseChatModel? failoverModel;
      List<Message>? nextInput;
      try {
        (failoverModel, nextInput) = await getFailoverModel(ctx, failoverContext, defaultInput);
      } on Object catch (error, stackTrace) {
        last = (response: null, error: error, stackTrace: stackTrace);
        try {
          await _emitGenerateSummary(ctx, attempt, GenerateSummaryPhase.failover, null, error);
        } on _EmitFailure catch (failure) {
          throw failure.error;
        }
      }
      if (failoverModel != null && nextInput != null) {
        modelInput = nextInput;
        last = await _generateAndEmit(ctx, failoverModel, modelInput, attempt, GenerateSummaryPhase.failover);
      }
      if (!_shouldFailover(ctx, config, last.response, last.error)) return (last, modelInput);
      if (attempt == maxRetries) {
        final error = last.error;
        throw error != null
            ? ThreepioException('exceeds max failover attempts: ${goValueString(error)}', cause: error)
            : const ThreepioException('exceeds max failover attempts');
      }
      final cancelled = await _wait(ctx, backoff(ctx, attempt, last.response, last.error));
      if (cancelled != null) throw cancelled;
    }
  }

  /// The model and input of a failover attempt. Port of `getFailoverModel`.
  @visibleForTesting
  Future<(BaseChatModel, List<Message>)> getFailoverModel(
    RunContext ctx,
    SummarizationFailoverContext failoverContext,
    List<Message> defaultInput,
  ) async {
    final config = failover;
    if (config == null) throw const ThreepioException('failover config is required');
    final getter = config.getFailoverModel;
    if (getter == null) return (model, defaultInput);
    final BaseChatModel failoverModel;
    final List<Message> input;
    try {
      (failoverModel, input) = await getter(ctx, failoverContext);
    } on Object catch (error) {
      throw ThreepioException('failed to get failover model: ${goValueString(error)}', cause: error);
    }
    if (input.isEmpty) {
      throw const ThreepioException('failover model input messages are required');
    }
    return (failoverModel, input);
  }

  Future<SummaryAttemptResult> _generateAndEmit(
    RunContext ctx,
    BaseChatModel chatModel,
    List<Message> input,
    int attempt,
    GenerateSummaryPhase phase,
  ) async {
    Message? response;
    Object? error;
    StackTrace? stackTrace;
    try {
      response = await chatModel.generate(
        input,
        options: (modelOptions ?? const ChatModelOptions()).copyWith(runContext: ctx),
      );
    } on Object catch (e, s) {
      error = e;
      stackTrace = s;
    }
    try {
      await _emitGenerateSummary(ctx, attempt, phase, response, error);
    } on _EmitFailure catch (failure) {
      // Go returns the emit error in place of the model's result.
      return (response: null, error: failure.error, stackTrace: null);
    }
    return (response: response, error: error, stackTrace: stackTrace);
  }

  Future<void> _emitGenerateSummary(
    RunContext ctx,
    int attempt,
    GenerateSummaryPhase phase,
    Message? response,
    Object? error,
  ) async {
    if (!emitInternalEvents) return;
    await _emit(
      ctx,
      SummarizationAction(
        type: SummarizationActionType.generateSummary,
        generateSummary: GenerateSummaryAction(
          attempt: attempt,
          phase: phase,
          modelResponse: response,
          error: error,
        ),
      ),
      wrapFailure: true,
    );
  }

  Future<void> _emit(
    RunContext ctx,
    SummarizationAction action, {
    bool wrapFailure = false,
  }) async {
    try {
      await ctx.sendEvent(AgentEvent(action: AgentAction(customizedAction: action)));
      // Outside a run sendEvent throws StateError; Go returns an error.
      // ignore: avoid_catching_errors
    } on StateError catch (error) {
      final failure = ThreepioException(
        'failed to send internal event: ${error.message}',
        cause: error,
      );
      if (wrapFailure) throw _EmitFailure(failure);
      throw failure;
    }
  }

  Future<List<Message>> _internalFinalizer(
    RunContext ctx,
    List<Message> originalMessages,
    Message rawSummary,
  ) async {
    final (system, context) = splitSystemAndContextMessages(originalMessages);
    final processed = postProcessSummary(
      contextMessages: context,
      summaryContent: assistantTextContent(rawSummary),
      transcriptPath: transcriptFilePath,
    );
    return [...system, processed];
  }
}

/// A failure to send an attempt's event, which Go returns in place of the
/// model's result.
final class _EmitFailure implements Exception {
  const _EmitFailure(this.error);

  final ThreepioException error;
}

ChatModelAgentState _copyState(ChatModelAgentState state) => ChatModelAgentState(
      messages: state.messages,
      toolInfos: state.toolInfos,
      deferredToolInfos: state.deferredToolInfos,
    );

void _throwIfError(SummaryAttemptResult attempt) {
  final error = attempt.error;
  if (error != null) Error.throwWithStackTrace(error, attempt.stackTrace ?? StackTrace.current);
}

/// Waits [delay]; returns the cancellation instead of throwing it, as Go
/// returns `ctx.Err()`.
Future<CancelledException?> _wait(RunContext ctx, Duration delay) async {
  try {
    // Go's select sees a done context also when the backoff is zero.
    ctx.cancelToken.throwIfCancelled();
    await sleepUnlessCancelled(ctx, delay);
    return null;
  } on CancelledException catch (error) {
    return error;
  }
}

bool _shouldFailover(
  RunContext ctx,
  SummarizationFailoverConfig? config,
  Message? response,
  Object? error,
) {
  if (config == null) return false;
  final predicate = config.shouldFailover;
  if (predicate == null) return error != null;
  return predicate(ctx, response, error);
}

bool _defaultShouldRetry(RunContext ctx, Message? response, Object? error) => error != null;

Duration _defaultBackoff(RunContext ctx, int attempt, Message? response, Object? error) =>
    defaultSummaryBackoff(attempt);

final Random _random = Random();

/// The default wait before attempt [attempt] + 1: 1 s doubling up to 10 s,
/// plus up to half again as jitter. Port of `defaultBackoffDuration`.
@visibleForTesting
Duration defaultSummaryBackoff(int attempt) {
  const base = Duration(seconds: 1);
  const maxDelay = Duration(seconds: 10);
  if (attempt <= 0) return base;
  if (attempt > 7) {
    return maxDelay + Duration(microseconds: _random.nextInt(maxDelay.inMicroseconds ~/ 2));
  }
  var delay = base * (1 << (attempt - 1));
  if (delay > maxDelay) delay = maxDelay;
  return delay + Duration(microseconds: _random.nextInt(delay.inMicroseconds ~/ 2));
}

/// The leading system messages and the rest. Port of
/// `splitSystemAndContextMsgs`.
@internal
(List<Message>, List<Message>) splitSystemAndContextMessages(List<Message> messages) {
  var count = 0;
  while (count < messages.length && messages[count].role == RoleType.system) {
    count++;
  }
  return (messages.sublist(0, count), messages.sublist(count));
}

/// The text of an assistant message: its text parts joined by newlines, or
/// its content; `''` for another role. Port of `getAssistantTextContent`.
@internal
String assistantTextContent(Message message) {
  if (message.role != RoleType.assistant) return '';
  final parts = [
    for (final part in message.assistantGenMultiContent ?? const <MessageOutputPart>[])
      if (part.type == ChatMessagePartType.text && (part.text ?? '').isNotEmpty) part.text!,
  ];
  return parts.isNotEmpty ? parts.join('\n') : message.content;
}

/// The text of a user (or tool) message: its text parts joined by newlines,
/// or its content. Port of `messageUserTextContent`.
@internal
String userTextContent(Message message) {
  final parts = [
    for (final part in message.userInputMultiContent ?? const <MessageInputPart>[])
      if (part.type == ChatMessagePartType.text && (part.text ?? '').isNotEmpty) part.text!,
  ];
  return parts.isNotEmpty ? parts.join('\n') : message.content;
}

/// The summarization content type of [message] (`summary`, `skills` or
/// `''`). Port of `typedGetContentType`.
@internal
String summarizationContentType(Message message) {
  final value = message.extra?[summarizationContentTypeKey];
  return value is String ? value : '';
}

/// [message] with its summarization content type set to [type].
@internal
Message withSummarizationContentType(Message message, String type) =>
    message.copyWith(extra: {...?message.extra, summarizationContentTypeKey: type});

/// Whether [message] is one the middleware wrote. Port of
/// `isInternalUserMessage`.
@internal
bool isInternalUserMessage(Message message) {
  final type = summarizationContentType(message);
  return type == contentTypeSummary || type == contentTypeSkills;
}

/// The summary message: the model's text with the user's latest messages
/// put back, the transcript path, and the preamble and closing instruction.
/// Port of `postProcessSummary`.
@internal
Message postProcessSummary({
  required List<Message> contextMessages,
  required String summaryContent,
  String transcriptPath = '',
}) {
  var content = summaryContent;
  if (content.isEmpty) throw const ThreepioException('summary content is empty');
  if (contextMessages.isNotEmpty) {
    try {
      content = replaceUserMessagesInSummary(contextMessages, content);
    } on Object catch (error) {
      throw ThreepioException(
        'failed to populate user messages in summary: ${goValueString(error)}',
        cause: error,
      );
    }
  }
  if (transcriptPath.isNotEmpty) {
    content = appendSection(content, goSprintf(getTranscriptPathInstruction(), [transcriptPath]));
  }
  content = appendSection(getSummaryPreamble(), content);
  content = appendSection(content, getContinueInstruction());
  return withSummarizationContentType(Message.user(content), contentTypeSummary);
}

/// [summaryText] with its last `<all_user_messages>` block replaced by the
/// user's latest messages (up to about 30 000 tokens). Port of
/// `replaceUserMessagesInSummary`.
@internal
String replaceUserMessagesInSummary(List<Message> contextMessages, String summaryText) {
  final userMessages = [
    for (final message in contextMessages)
      if (!isInternalUserMessage(message) && message.role == RoleType.user) message,
  ];
  if (userMessages.isEmpty) return summaryText;

  List<Message> selected;
  if (userMessages.length == 1) {
    selected = userMessages;
  } else {
    selected = [];
    var totalTokens = 0;
    for (var i = userMessages.length - 1; i >= 0; i--) {
      final message = userMessages[i];
      final tokens = defaultSummarizationTokenCount(TokenCounterInput(messages: [message]));
      final remaining = _preserveUserMsgsMaxTokens - totalTokens;
      if (tokens <= remaining) {
        totalTokens += tokens;
        selected.add(message);
        continue;
      }
      final trimmed = defaultTrimUserMessage(message, remaining);
      if (trimmed != null) selected.add(trimmed);
      break;
    }
    selected = selected.reversed.toList();
  }

  final lines = [
    for (final message in selected)
      if (userTextContent(message).isNotEmpty) '    - ${userTextContent(message)}',
  ];
  final userText = lines.join('\n');

  final matches = allUserMessagesTagRegex.allMatches(summaryText).toList();
  if (matches.isEmpty) return summaryText;
  final last = matches.last;
  final replacement = selected.length < userMessages.length
      ? '<all_user_messages>\n${getUserMessagesReplacedNote()}\n$userText\n</all_user_messages>'
      : '<all_user_messages>\n$userText\n</all_user_messages>';
  return summaryText.substring(0, last.start) + replacement + summaryText.substring(last.end);
}

/// [base] and [section] separated by a blank line; either alone when the
/// other is empty. Port of `appendSection`.
@internal
String appendSection(String base, String section) {
  if (base.isEmpty) return section;
  if (section.isEmpty) return base;
  return '$base\n\n$section';
}

/// [text] cut to its first and last 1000 characters with a marker between,
/// when it has more than 2000. Port of `truncateTextByChars`.
@internal
String truncateTextByChars(String text) {
  const maxRunes = 2000;
  if (text.isEmpty) return '';
  final runes = text.runes.toList();
  if (runes.length <= maxRunes) return text;
  const half = maxRunes ~/ 2;
  final prefix = String.fromCharCodes(runes.sublist(0, half));
  final suffix = String.fromCharCodes(runes.sublist(runes.length - half));
  final marker = goSprintf(getTruncatedMarkerFormat(), [runes.length - maxRunes]);
  return prefix + marker + suffix;
}

/// A shortened copy of a user message for the remaining budget, or `null`
/// when nothing is left. Port of `defaultTypedTrimUserMessage`.
@internal
Message? defaultTrimUserMessage(Message message, int remainingTokens) {
  if (remainingTokens <= 0) return null;
  final text = userTextContent(message);
  if (text.isEmpty) return null;
  final trimmed = truncateTextByChars(text);
  if (trimmed.isEmpty) return null;
  return Message.user(trimmed);
}

/// The default token count: the total tokens of the last assistant answer
/// that reports them, plus an estimate of everything after it and of the
/// tools. Port of `defaultTypedTokenCounter`.
@internal
int defaultSummarizationTokenCount(TokenCounterInput input) {
  var baseTokens = 0;
  var incrementStart = 0;
  for (var i = input.messages.length - 1; i >= 0; i--) {
    final tokens = assistantTotalTokens(input.messages[i]);
    if (tokens > 0) {
      baseTokens = tokens;
      incrementStart = i + 1;
      break;
    }
  }
  var incrementTokens = 0;
  for (final message in input.messages.sublist(incrementStart)) {
    incrementTokens += estimateMessageTokens(message);
  }
  for (final tool in input.tools) {
    incrementTokens += estimateTokenCount(utf8Length(goToolInfoValueJson(tool)));
  }
  return baseTokens + incrementTokens;
}

/// The total tokens an assistant message reports, or 0. Port of
/// `getAssistantTotalTokens`.
@internal
int assistantTotalTokens(Message? message) {
  if (message == null || message.role != RoleType.assistant) return 0;
  return message.responseMeta?.usage?.totalTokens ?? 0;
}

/// One token per 4 bytes. Port of `estimateTokenCount`.
@internal
int estimateTokenCount(int byteLength) => byteLength ~/ 4;

/// Bytes for [tokens] tokens. Port of `estimateTokenBytes`.
@internal
int estimateTokenBytes(int tokens) => tokens * 4;

bool _isMedia(ChatMessagePartType type) =>
    type == ChatMessagePartType.imageUrl ||
    type == ChatMessagePartType.audioUrl ||
    type == ChatMessagePartType.videoUrl ||
    type == ChatMessagePartType.fileUrl;

/// The estimated tokens of one message (media parts count 2000). Port of
/// `estimateMessageTokens`.
@internal
int estimateMessageTokens(Message? message) {
  if (message == null) return 0;
  var totalLength = 0;
  var multimodalTokens = 0;
  if (message.role == RoleType.assistant) {
    final parts = message.assistantGenMultiContent;
    if (parts != null && parts.isNotEmpty) {
      var hasReasoning = false;
      for (final part in parts) {
        if (part.type == ChatMessagePartType.text) {
          totalLength += utf8Length(part.text ?? '');
        } else if (part.type == ChatMessagePartType.reasoning) {
          hasReasoning = true;
          totalLength += utf8Length(part.reasoning?.text ?? '');
        } else if (_isMedia(part.type)) {
          multimodalTokens += _multimodalTokenEstimate;
        }
      }
      if (!hasReasoning) totalLength += utf8Length(message.reasoningContent ?? '');
    } else {
      totalLength += utf8Length(message.content) + utf8Length(message.reasoningContent ?? '');
    }
    for (final call in message.toolCalls ?? const <ToolCall>[]) {
      totalLength += utf8Length(call.function.name) + utf8Length(call.function.arguments);
    }
  } else {
    final parts = message.userInputMultiContent;
    if (parts != null && parts.isNotEmpty) {
      for (final part in parts) {
        if (part.type == ChatMessagePartType.text) {
          totalLength += utf8Length(part.text ?? '');
        } else if (part.type == ChatMessagePartType.toolSearchResult) {
          for (final tool in part.toolSearchResult?.tools ?? const <ToolInfo>[]) {
            totalLength += utf8Length(tool.name) +
                utf8Length(tool.desc ?? '') +
                goParamsOneOfJsonLength(tool);
          }
        } else if (_isMedia(part.type)) {
          multimodalTokens += _multimodalTokenEstimate;
        }
      }
    } else {
      totalLength += utf8Length(message.content);
    }
  }
  return estimateTokenCount(totalLength) + multimodalTokens;
}
