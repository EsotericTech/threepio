/// A middleware that keeps tool results from filling the context: it cuts
/// large results as they come (offloading the full text to a file) and
/// clears old results when the conversation gets too long.
///
/// Port of eino `adk/middlewares/reduction/reduction.go` (classic messages;
/// the agentic path is P13). Not ported: the deprecated
/// `NewClearToolResult` and `NewToolResultMiddleware` (`legacy.go` and the
/// `internal` package behind them).
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/message_concat.dart';
import '../../../schema/tool_info.dart';
import '../../../schema/tool_result.dart';
import '../../../streaming/stream_reader.dart';
import '../../eino/middleware.dart';
import '../../eino/middleware_context.dart';
import '../../filesystem/backend.dart';
import '../../filesystem/requests.dart';
import '../internal/go_compat.dart';
import 'consts.dart';

const _uuid = Uuid();

/// Counts the tokens of messages and tools. Port of eino
/// `reduction.Config.TokenCounter`.
typedef ReductionTokenCounter = FutureOr<int> Function(
  RunContext ctx,
  List<Message> messages,
  List<ToolInfo> tools,
);

/// Where to offload a tool's result. Port of eino
/// `Config.GenTruncOffloadFilePath` / `GenClearOffloadFilePath`.
typedef OffloadFilePathGenerator = FutureOr<String> Function(RunContext ctx, ToolDetail detail);

/// Decides about cutting one tool result. Port of eino
/// `ToolReductionConfig.TruncHandler`.
typedef TruncHandler = FutureOr<TruncResult> Function(RunContext ctx, ToolDetail detail);

/// Decides about clearing one old tool call and its result. Port of eino
/// `ToolReductionConfig.ClearHandler`.
typedef ClearHandler = FutureOr<ClearResult> Function(RunContext ctx, ToolDetail detail);

/// Rewrites an assistant tool-call message and its tool results before the
/// clear phase; `null` removes them. Port of eino
/// `Config.ClearMessageRewriter`.
typedef ClearMessageRewriter = FutureOr<List<Message>?> Function(
  RunContext ctx,
  Message toolCallMessage,
  List<Message>? toolResponseMessages,
);

/// Runs after a clear was applied; returns the context to go on with. Port
/// of eino `Config.ClearPostProcess`.
typedef ClearPostProcess = RunContext Function(RunContext ctx, ChatModelAgentState state);

/// The reduction settings of one tool, which take precedence over the
/// middleware's. Port of eino `reduction.ToolReductionConfig`.
@immutable
final class ToolReductionConfig {
  /// The settings of one tool.
  const ToolReductionConfig({
    this.backend,
    this.skipTruncation = false,
    this.truncHandler,
    this.skipClear = false,
    this.clearHandler,
  });

  /// Where this tool's results are offloaded; required when truncation is on
  /// and offloads.
  final FileWriteBackend? backend;

  /// Never cut this tool's results.
  final bool skipTruncation;

  /// Decides about cutting; `null` (with truncation on) uses the default.
  final TruncHandler? truncHandler;

  /// Never clear this tool's results.
  final bool skipClear;

  /// Decides about clearing; `null` (with clearing on) uses the default.
  final ClearHandler? clearHandler;
}

/// One tool call: which tool, its arguments, and its result (complete or as
/// a stream). Port of eino `reduction.ToolDetail`.
@immutable
final class ToolDetail {
  /// The call [toolContext] with [toolArgument] and its result.
  const ToolDetail({
    required this.toolContext,
    required this.toolArgument,
    this.toolResult,
    this.streamToolResult,
  });

  /// The tool's name and the call's id.
  final ToolContext toolContext;

  /// The arguments.
  final ToolArgument toolArgument;

  /// The result of a tool that returns one.
  final ToolResult? toolResult;

  /// The result of a tool that streams.
  final StreamReader<ToolResult>? streamToolResult;
}

/// What a [TruncHandler] decided. Port of eino `reduction.TruncResult`.
@immutable
final class TruncResult {
  /// A decision; with [needTrunc] the cut result must be given (as a
  /// [toolResult] or [streamToolResult], like the input), with
  /// [needOffload] the file to write.
  const TruncResult({
    required this.needTrunc,
    this.toolResult,
    this.streamToolResult,
    this.needOffload = false,
    this.offloadFilePath = '',
    this.offloadContent = '',
  });

  /// Whether to replace the result.
  final bool needTrunc;

  /// The cut result of a tool that returns one.
  final ToolResult? toolResult;

  /// The cut result of a tool that streams.
  final StreamReader<ToolResult>? streamToolResult;

  /// Whether to write [offloadContent] to [offloadFilePath].
  final bool needOffload;

  /// The file the full result goes to.
  final String offloadFilePath;

  /// The full result.
  final String offloadContent;
}

/// What a [ClearHandler] decided. Port of eino `reduction.ClearResult`.
@immutable
final class ClearResult {
  /// A decision; with [needClear] the new [toolArgument] and [toolResult]
  /// must be given, with [needOffload] the file to write.
  const ClearResult({
    required this.needClear,
    this.toolArgument,
    this.toolResult,
    this.needOffload = false,
    this.offloadFilePath = '',
    this.offloadContent = '',
  });

  /// Whether to replace the call's arguments and result.
  final bool needClear;

  /// The new arguments.
  final ToolArgument? toolArgument;

  /// The new result.
  final ToolResult? toolResult;

  /// Whether to write [offloadContent] to [offloadFilePath].
  final bool needOffload;

  /// The file the full result goes to.
  final String offloadFilePath;

  /// The full result.
  final String offloadContent;
}

enum _Scene { truncation, clear }

/// Keeps tool results from filling the context, in two phases.
///
/// Port of eino `reduction.New`.
///
/// * **Truncation**, right after a tool call: a result longer than
///   [maxLengthForTrunc] UTF-8 bytes (default 50 000) is written to
///   [backend] (by default under `<rootDir>/trunc/<call id>`) and replaced
///   by a notice with its first and last part and the path, which the agent
///   can read with the tool [readFileToolName] (`read_file` by default; give
///   the agent such a tool, for example with `FilesystemMiddleware`). A
///   streaming tool is passed through until the limit and then ends with
///   the notice.
/// * **Clear**, before a model call: when the conversation has more than
///   [maxTokensForClear] tokens (default 160 000, by [tokenCounter], by
///   default one token per 4 bytes), the results of old tool calls (all but
///   the last [clearRetentionSuffixLimit] rounds) are replaced by a
///   placeholder, after being offloaded under `<rootDir>/clear/<call id>`
///   when there is a [backend]. With [clearAtLeastTokens] the clear only
///   applies when it saves that many tokens.
///
/// [toolConfig] overrides both phases per tool; [truncExcludeTools] and
/// [clearExcludeTools] leave tools alone.
final class ToolReductionMiddleware extends ChatModelAgentMiddleware {
  /// A reduction middleware. As in eino, `0` and `''` also mean the
  /// default. Throws [ArgumentError] without a [backend] unless
  /// [skipTruncation].
  ToolReductionMiddleware({
    this.backend,
    this.skipTruncation = false,
    this.skipClear = false,
    String readFileToolName = 'read_file',
    String rootDir = '/tmp',
    OffloadFilePathGenerator? genTruncOffloadFilePath,
    OffloadFilePathGenerator? genClearOffloadFilePath,
    int maxLengthForTrunc = 50000,
    List<String> truncExcludeTools = const [],
    ReductionTokenCounter? tokenCounter,
    int maxTokensForClear = 160000,
    int clearRetentionSuffixLimit = 1,
    this.clearAtLeastTokens = 0,
    List<String> clearExcludeTools = const [],
    this.clearMessageRewriter,
    this.clearPostProcess,
    Map<String, ToolReductionConfig> toolConfig = const {},
  })  : readFileToolName = readFileToolName.isEmpty ? 'read_file' : readFileToolName,
        rootDir = rootDir.isEmpty ? '/tmp' : rootDir,
        maxLengthForTrunc = maxLengthForTrunc == 0 ? 50000 : maxLengthForTrunc,
        tokenCounter = tokenCounter ?? defaultReductionTokenCount,
        maxTokensForClear = maxTokensForClear == 0 ? 160000 : maxTokensForClear,
        clearRetentionSuffixLimit = clearRetentionSuffixLimit == 0 ? 1 : clearRetentionSuffixLimit,
        truncExcludeTools = Set.of(truncExcludeTools),
        clearExcludeTools = Set.of(clearExcludeTools),
        toolConfig = Map.unmodifiable(toolConfig) {
    if (backend == null && !skipTruncation) {
      throw ArgumentError.value(
        backend,
        'backend',
        'backend must be set when not skipping truncation',
      );
    }
    final root = this.rootDir;
    this.genTruncOffloadFilePath = genTruncOffloadFilePath ??
        (ctx, detail) => goJoin([root, 'trunc', _callIdOrUuid(detail)]);
    this.genClearOffloadFilePath = genClearOffloadFilePath ??
        (ctx, detail) => goJoin([root, 'clear', _callIdOrUuid(detail)]);
    defaultConfig = ToolReductionConfig(
      backend: backend,
      skipTruncation: skipTruncation,
      skipClear: skipClear,
      truncHandler: skipTruncation
          ? null
          : defaultTruncHandler(this.genTruncOffloadFilePath, this.maxLengthForTrunc, this.readFileToolName),
      clearHandler: skipClear
          ? null
          : defaultClearHandler(this.genClearOffloadFilePath, backend != null, this.readFileToolName),
    );
  }

  /// Where offloaded content is written.
  final FileWriteBackend? backend;

  /// Whether the truncation phase is off.
  final bool skipTruncation;

  /// Whether the clear phase is off.
  final bool skipClear;

  /// The tool the agent reads offloaded content with.
  final String readFileToolName;

  /// The directory the default paths are under.
  final String rootDir;

  /// The path of a truncated result.
  late final OffloadFilePathGenerator genTruncOffloadFilePath;

  /// The path of a cleared result.
  late final OffloadFilePathGenerator genClearOffloadFilePath;

  /// The UTF-8 bytes a tool result may have before it is cut.
  final int maxLengthForTrunc;

  /// Tools whose results are never cut.
  final Set<String> truncExcludeTools;

  /// Counts the conversation's tokens.
  final ReductionTokenCounter tokenCounter;

  /// The tokens above which old results are cleared.
  final int maxTokensForClear;

  /// How many of the latest tool-call rounds are never cleared.
  final int clearRetentionSuffixLimit;

  /// The tokens a clear must save to be applied; 0 always applies it.
  final int clearAtLeastTokens;

  /// Tools whose calls and results are never cleared.
  final Set<String> clearExcludeTools;

  /// Rewrites tool-call rounds before the clear.
  final ClearMessageRewriter? clearMessageRewriter;

  /// Runs after an applied clear.
  final ClearPostProcess? clearPostProcess;

  /// Settings per tool.
  final Map<String, ToolReductionConfig> toolConfig;

  /// The settings of tools without their own. Port of `defaultConfig`.
  @visibleForTesting
  late final ToolReductionConfig defaultConfig;

  static String _callIdOrUuid(ToolDetail detail) {
    final id = detail.toolContext.callId;
    return id.isEmpty ? _uuid.v4() : id;
  }

  /// The settings for [toolName] in a phase: the tool's own unless it has
  /// the phase on without a handler. Port of `getToolConfig`.
  @visibleForTesting
  ToolReductionConfig toolConfigFor(String toolName, {required bool clear}) =>
      _toolConfig(toolName, clear ? _Scene.clear : _Scene.truncation);

  ToolReductionConfig _toolConfig(String toolName, _Scene scene) {
    final config = toolConfig[toolName];
    if (config == null) return defaultConfig;
    if ((scene == _Scene.truncation && !config.skipTruncation && config.truncHandler == null) ||
        (scene == _Scene.clear && !config.skipClear && config.clearHandler == null)) {
      return defaultConfig;
    }
    return config;
  }

  ToolReductionConfig? _truncationConfig(ToolContext tool) {
    final config = _toolConfig(tool.name, _Scene.truncation);
    if (config.truncHandler == null) return null;
    if (truncExcludeTools.contains(tool.name)) return null;
    return config;
  }

  @override
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  ) {
    final config = _truncationConfig(tool);
    if (config == null) return next;
    return (ctx, argumentsJson, options) async {
      final output = await next(ctx, argumentsJson, options);
      final detail = ToolDetail(
        toolContext: tool,
        toolArgument: ToolArgument(argumentsJson),
        toolResult: ToolResult.text(output),
      );
      final result = await config.truncHandler!(ctx, detail);
      if (!result.needTrunc) return output;
      await _writeTruncOffload(ctx, config, result);
      final parts = result.toolResult?.parts;
      if (parts == null || parts.isEmpty) {
        throw const ThreepioException('truncation: TruncResult.ToolResult is required');
      }
      return parts.first.text ?? '';
    };
  }

  @override
  StreamableToolCallEndpoint wrapStreamableToolCall(
    RunContext ctx,
    StreamableToolCallEndpoint next,
    ToolContext tool,
  ) {
    final config = _truncationConfig(tool);
    if (config == null) return next;
    return (ctx, argumentsJson, options) async {
      final output = await next(ctx, argumentsJson, options);
      if (identical(config, defaultConfig)) {
        return _defaultStreamTruncation(ctx, config, tool, argumentsJson, output);
      }
      final readers = output.copy(2);
      final original = readers[1];
      final detail = ToolDetail(
        toolContext: tool,
        toolArgument: ToolArgument(argumentsJson),
        streamToolResult: readers[0].convert((text) => ToolResult.text(text)),
      );
      final TruncResult result;
      try {
        result = await config.truncHandler!(ctx, detail);
      } on Object {
        unawaited(original.close());
        rethrow;
      }
      if (!result.needTrunc) return original;
      unawaited(original.close());
      await _writeTruncOffload(ctx, config, result);
      final stream = result.streamToolResult;
      if (stream == null) {
        throw const ThreepioException('truncation: TruncResult.StreamToolResult is required');
      }
      return stream.convert(
        (chunk) => chunk.parts.isEmpty ? '' : (chunk.parts.first.text ?? ''),
      );
    };
  }

  @override
  EnhancedInvokableToolCallEndpoint wrapEnhancedInvokableToolCall(
    RunContext ctx,
    EnhancedInvokableToolCallEndpoint next,
    ToolContext tool,
  ) {
    final config = _truncationConfig(tool);
    if (config == null) return next;
    return (ctx, argument, options) async {
      final output = await next(ctx, argument, options);
      final detail = ToolDetail(toolContext: tool, toolArgument: argument, toolResult: output);
      final result = await config.truncHandler!(ctx, detail);
      if (!result.needTrunc) return output;
      await _writeTruncOffload(ctx, config, result);
      final truncated = result.toolResult;
      if (truncated == null) {
        throw const ThreepioException('truncation: TruncResult.ToolResult is required');
      }
      return truncated;
    };
  }

  @override
  EnhancedStreamableToolCallEndpoint wrapEnhancedStreamableToolCall(
    RunContext ctx,
    EnhancedStreamableToolCallEndpoint next,
    ToolContext tool,
  ) {
    final config = _truncationConfig(tool);
    if (config == null) return next;
    return (ctx, argument, options) async {
      final output = await next(ctx, argument, options);
      if (identical(config, defaultConfig)) {
        return _defaultEnhancedStreamTruncation(ctx, config, tool, argument, output);
      }
      final readers = output.copy(2);
      final original = readers[1];
      final detail = ToolDetail(toolContext: tool, toolArgument: argument, streamToolResult: readers[0]);
      final TruncResult result;
      try {
        result = await config.truncHandler!(ctx, detail);
      } on Object {
        unawaited(original.close());
        rethrow;
      }
      if (!result.needTrunc) return original;
      unawaited(original.close());
      await _writeTruncOffload(ctx, config, result);
      final stream = result.streamToolResult;
      if (stream == null) {
        throw const ThreepioException('truncation: TruncResult.StreamToolResult is required');
      }
      return stream;
    };
  }

  /// Passes text chunks through until [maxLengthForTrunc] bytes, swallows
  /// the rest, and at the end offloads everything and emits the notice. A
  /// source error after the cut replays what was swallowed and then the
  /// error. Port of `wrapDefaultStreamableTruncation`.
  StreamReader<String> _defaultStreamTruncation(
    RunContext ctx,
    ToolReductionConfig config,
    ToolContext tool,
    String argumentsJson,
    StreamReader<String> output,
  ) {
    final fullOutput = StringBuffer();
    var currentSize = 0;
    var reachedLimit = false;
    var prefix = '';
    var triggeredFullText = '';
    Object? sourceError;

    final truncated = output.convert<String>(
      (chunk) {
        if (chunk.isEmpty) throw const NoValueException();
        fullOutput.write(chunk);
        if (reachedLimit) throw const NoValueException();
        final size = utf8Length(chunk);
        if (currentSize + size < maxLengthForTrunc) {
          currentSize += size;
          return chunk;
        }
        reachedLimit = true;
        triggeredFullText = fullOutput.toString();
        final left = maxLengthForTrunc - currentSize;
        if (left > 0) prefix = utf8Prefix(chunk, left);
        throw const NoValueException();
      },
      errWrapper: (error) {
        if (reachedLimit) {
          sourceError = error;
          return null;
        }
        return error;
      },
      onEof: () async {
        if (sourceError != null) {
          final full = fullOutput.toString();
          return utf8Length(full) > currentSize ? utf8From(full, currentSize) : null;
        }
        if (!reachedLimit) return null;
        final detail = ToolDetail(
          toolContext: tool,
          toolArgument: ToolArgument(argumentsJson),
          toolResult: ToolResult.text(triggeredFullText),
        );
        final notice = await _streamNotice(ctx, config, detail, fullOutput.toString());
        return prefix + notice;
      },
    );
    return truncated.convert<String>(
      (chunk) => chunk,
      onEof: () {
        final error = sourceError;
        if (error != null) throw error;
        return null;
      },
    );
  }

  /// The [ToolResult] counterpart of [_defaultStreamTruncation]. Port of
  /// `wrapDefaultEnhancedStreamableTruncation`.
  StreamReader<ToolResult> _defaultEnhancedStreamTruncation(
    RunContext ctx,
    ToolReductionConfig config,
    ToolContext tool,
    ToolArgument argument,
    StreamReader<ToolResult> output,
  ) {
    final chunks = <ToolResult>[];
    final replayChunks = <ToolResult>[];
    var fullLength = 0;
    var reachedLimit = false;
    ToolResult? prefix;
    ToolResult? triggered;
    Object? sourceError;

    final truncated = output.convert<ToolResult>(
      (chunk) {
        chunks.add(chunk);
        final length = toolResultTextLength(chunk);
        if (reachedLimit) {
          fullLength += length;
          replayChunks.add(chunk);
          throw const NoValueException();
        }
        if (fullLength + length < maxLengthForTrunc) {
          fullLength += length;
          return chunk;
        }
        reachedLimit = true;
        replayChunks.add(chunk);
        prefix = toolResultTextPrefix(chunk, maxLengthForTrunc - fullLength);
        fullLength += length;
        triggered = ToolResult(flattenToolResultParts(chunks));
        throw const NoValueException();
      },
      errWrapper: (error) {
        if (reachedLimit) {
          sourceError = error;
          return null;
        }
        return error;
      },
      onEof: () async {
        if (sourceError != null) {
          final replay = ToolResult(flattenToolResultParts(replayChunks));
          return replay.parts.isNotEmpty ? replay : null;
        }
        if (!reachedLimit) return null;
        final full = ToolResult(flattenToolResultParts(chunks));
        final detail = ToolDetail(toolContext: tool, toolArgument: argument, toolResult: triggered);
        final notice =
            await _streamNotice(ctx, config, detail, stringifyToolOutputParts(full.parts));
        return ToolResult([...?prefix?.parts, ToolOutputPart.text(notice)]);
      },
    );
    return truncated.convert<ToolResult>(
      (chunk) => chunk,
      onEof: () {
        final error = sourceError;
        if (error != null) throw error;
        return null;
      },
    );
  }

  Future<String> _streamNotice(
    RunContext ctx,
    ToolReductionConfig config,
    ToolDetail detail,
    String fullContent,
  ) async {
    var offloadNotify = '';
    var errorNotify = '';
    String? filePath;
    try {
      filePath = await genTruncOffloadFilePath(ctx, detail);
    } on Object catch (error) {
      errorNotify = formatStreamOffloadFailedNotify(error);
    }
    if (filePath != null) {
      final backend = config.backend;
      if (backend == null) {
        errorNotify = formatStreamOffloadFailedNotify(
          const ThreepioException('truncation: no backend for offload'),
        );
      } else {
        try {
          await backend.write(ctx, WriteRequest(filePath: filePath, content: fullContent));
          offloadNotify = formatStreamOffloadSavedNotify(filePath, readFileToolName);
        } on Object catch (error) {
          errorNotify = formatStreamOffloadFailedNotify(error);
        }
      }
    }
    return formatStreamTruncNotice(maxLengthForTrunc, offloadNotify, errorNotify);
  }

  @override
  Future<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async {
    final estimatedTokens = await tokenCounter(ctx, state.messages, state.toolInfos);
    if (estimatedTokens < maxTokensForClear) return (ctx, state);

    final messages = state.messages;
    var start = 0;
    var end = messages.length;
    for (; start < messages.length; start++) {
      final message = messages[start];
      if (message.role == RoleType.assistant && !messageClearedFlag(message)) break;
    }
    var retention = clearRetentionSuffixLimit;
    for (; retention > 0 && end > 0; end--) {
      final message = messages[end - 1];
      if (message.role == RoleType.assistant && (message.toolCalls?.isNotEmpty ?? false)) {
        retention--;
        if (retention == 0) {
          end--;
          break;
        }
      }
    }
    if (start >= end) return (ctx, state);

    final List<Message> editTarget;
    (editTarget, end) = await _applyClearRewrite(ctx, messages, start, end);
    final offloadStash = <(ToolReductionConfig, ClearResult)>[];

    for (var index = start; index < end; index++) {
      var toolCallMessage = editTarget[index];
      final toolCalls = toolCallMessage.toolCalls ?? const <ToolCall>[];
      if (toolCallMessage.role != RoleType.assistant || toolCalls.isEmpty) continue;
      for (var callIndex = 0; callIndex < toolCalls.length; callIndex++) {
        final call = toolCalls[callIndex];
        final resultIndex = _findToolResult(
          editTarget,
          index + 1,
          index + 1 + toolCalls.length,
          call.id,
        );
        if (resultIndex < 0) continue;
        if (clearExcludeTools.contains(call.function.name)) continue;
        final config = _toolConfig(call.function.name, _Scene.clear);
        final handler = config.clearHandler;
        if (handler == null) continue;

        final resultMessage = editTarget[resultIndex];
        final (toolResult, fromContent) = toolResultFromMessage(resultMessage);
        final detail = ToolDetail(
          toolContext: ToolContext(name: call.function.name, callId: call.id),
          toolArgument: ToolArgument(call.function.arguments),
          toolResult: toolResult,
        );
        final decision = await handler(ctx, detail);
        if (!decision.needClear) continue;
        final newArgument = decision.toolArgument;
        final newResult = decision.toolResult;
        if (newArgument == null || newResult == null) {
          // Go dereferences both (and panics without them).
          throw const ThreepioException(
            'clear: ClearResult.ToolArgument and ToolResult are required when NeedClear is true',
          );
        }
        if (decision.needOffload) {
          final backend = config.backend;
          if (backend == null) throw const ThreepioException('clear: no backend for offload');
          if (clearAtLeastTokens > 0) {
            offloadStash.add((config, decision));
          } else {
            await backend.write(
              ctx,
              WriteRequest(filePath: decision.offloadFilePath, content: decision.offloadContent),
            );
          }
        }
        toolCallMessage = withToolCallArguments(toolCallMessage, callIndex, newArgument.text);
        editTarget[resultIndex] = withToolResultContent(
          resultMessage,
          newResult,
          fromContent: fromContent,
        );
      }
      editTarget[index] = withMessageClearedFlag(toolCallMessage);
    }

    if (clearAtLeastTokens > 0) {
      final after = await tokenCounter(ctx, editTarget, state.toolInfos);
      if (estimatedTokens - after < clearAtLeastTokens) return (ctx, state);
      for (final (config, decision) in offloadStash) {
        await config.backend!.write(
          ctx,
          WriteRequest(filePath: decision.offloadFilePath, content: decision.offloadContent),
        );
      }
    }

    state.messages = editTarget;
    final postProcess = clearPostProcess;
    final nextCtx = postProcess == null ? ctx : postProcess(ctx, state);
    return (nextCtx, state);
  }

  /// The messages to clear in, after [clearMessageRewriter], and the new end
  /// of the range. Port of `applyClearRewriteGeneric`.
  Future<(List<Message>, int)> _applyClearRewrite(
    RunContext ctx,
    List<Message> messages,
    int start,
    int end,
  ) async {
    final editTarget = List<Message>.of(messages.sublist(0, start));
    final part = messages.sublist(start, end);
    final rewriter = clearMessageRewriter;
    if (rewriter == null) {
      editTarget
        ..addAll(part)
        ..addAll(messages.sublist(end));
      return (editTarget, end);
    }
    final rewritten = <Message>[];
    for (var i = 0; i < part.length;) {
      final message = part[i];
      switch (message.role) {
        case RoleType.system:
        case RoleType.user:
          rewritten.add(message);
          i++;
        case RoleType.tool:
          i++;
        case RoleType.assistant:
          final toolCalls = message.toolCalls ?? const <ToolCall>[];
          if (toolCalls.isEmpty) {
            rewritten.add(message);
            i++;
            continue;
          }
          final trStart = i + 1;
          final trEnd = i + toolCalls.length + 1;
          final responses = trStart >= trEnd || trStart >= part.length || trEnd > part.length
              ? null
              : part.sublist(trStart, trEnd);
          rewritten.addAll(await rewriter(ctx, message, responses) ?? const []);
          i = trEnd;
      }
    }
    editTarget
      ..addAll(rewritten)
      ..addAll(messages.sublist(end));
    return (editTarget, end - part.length + rewritten.length);
  }

  Future<void> _writeTruncOffload(
    RunContext ctx,
    ToolReductionConfig config,
    TruncResult result,
  ) async {
    if (!result.needOffload) return;
    final backend = config.backend;
    if (backend == null) throw const ThreepioException('truncation: no backend for offload');
    await backend.write(
      ctx,
      WriteRequest(filePath: result.offloadFilePath, content: result.offloadContent),
    );
  }
}

/// The index of the tool message for [callId] among the tool messages that
/// directly follow (from [startIndex], before [endIndex]), or -1. Port of
/// `findToolResultByCallID`.
int _findToolResult(List<Message> messages, int startIndex, int endIndex, String callId) {
  final stop = endIndex < messages.length ? endIndex : messages.length;
  for (var i = startIndex; i < stop; i++) {
    final message = messages[i];
    if (message.role != RoleType.tool) return -1;
    // Go compares strings: a missing id is "".
    if ((message.toolCallId ?? '') == callId) return i;
  }
  return -1;
}

/// The cut notice of a stream. Port of `formatStreamTruncNotice`.
@visibleForTesting
String formatStreamTruncNotice(int previewSize, String offloadNotify, String errorMessageNotify) =>
    formatNamed(getStreamTruncFmt(), {
      'preview_size': previewSize,
      'offload_notify': offloadNotify,
      'error_msg_notify': errorMessageNotify,
    });

/// The text parts of [result] up to [maxLength] bytes in all (other parts
/// kept), or `null`. Port of `toolResultTextPrefix`.
@visibleForTesting
ToolResult? toolResultTextPrefix(ToolResult? result, int maxLength) {
  if (result == null || maxLength <= 0) return null;
  var length = 0;
  final parts = <ToolOutputPart>[];
  for (final part in result.parts) {
    if (part.type != ToolPartType.text) {
      parts.add(part);
      continue;
    }
    final remaining = maxLength - length;
    if (remaining <= 0) break;
    final text = part.text ?? '';
    final textLength = utf8Length(text);
    if (textLength <= remaining) {
      parts.add(part);
      length += textLength;
      continue;
    }
    final cut = utf8Prefix(text, remaining);
    if (cut.isNotEmpty) parts.add(part.copyWith(text: cut));
    break;
  }
  return parts.isEmpty ? null : ToolResult(parts);
}

/// The UTF-8 bytes of [result]'s text parts. Port of `toolResultTextLength`.
@visibleForTesting
int toolResultTextLength(ToolResult? result) {
  if (result == null) return 0;
  var length = 0;
  for (final part in result.parts) {
    if (part.type == ToolPartType.text) length += utf8Length(part.text ?? '');
  }
  return length;
}

/// The parts of all [chunks], in order. Port of `flattenToolResultParts`.
@visibleForTesting
List<ToolOutputPart> flattenToolResultParts(List<ToolResult?> chunks) => [
      for (final chunk in chunks) ...?chunk?.parts,
    ];

/// The default truncation: a result whose text parts have more than
/// [truncMaxLength] bytes gets every long text part replaced by a notice
/// with its first and last bytes and the offload path. A stream is read to
/// the end first (a read error leaves it alone) and given back as one
/// chunk. Port of `defaultTruncHandler`.
@visibleForTesting
TruncHandler defaultTruncHandler(
  OffloadFilePathGenerator genOffloadFilePath,
  int truncMaxLength,
  String readFileToolName,
) =>
    (ctx, detail) async {
      final isStream = detail.streamToolResult != null;
      final parts = await jointToolResult(detail);
      if (parts == null) return const TruncResult(needTrunc: false);

      var fullLength = 0;
      var textParts = 0;
      for (final part in parts) {
        if (part.type == ToolPartType.text) {
          fullLength += utf8Length(part.text ?? '');
          textParts++;
        }
      }
      if (textParts == 0 || fullLength <= truncMaxLength) {
        return const TruncResult(needTrunc: false);
      }
      final offloadContent = stringifyToolOutputParts(parts);
      final partLength = truncMaxLength ~/ textParts;
      final previewSize = partLength ~/ 2;
      final filePath = await genOffloadFilePath(ctx, detail);
      final truncatedParts = [
        for (final part in parts)
          if (part.type != ToolPartType.text || utf8Length(part.text ?? '') < partLength)
            part
          else
            part.copyWith(
              text: formatNamed(getTruncFmt(), {
                'original_size': utf8Length(part.text ?? ''),
                'file_path': filePath,
                'preview_size': previewSize,
                'preview_first': utf8Prefix(part.text ?? '', previewSize),
                'preview_last': utf8Suffix(part.text ?? '', previewSize),
                'read_tool_name': readFileToolName,
              }),
            ),
      ];
      final result = ToolResult(truncatedParts);
      return TruncResult(
        needTrunc: true,
        needOffload: true,
        offloadFilePath: filePath,
        offloadContent: offloadContent,
        toolResult: isStream ? null : result,
        streamToolResult: isStream ? StreamReader.fromIterable([result]) : null,
      );
    };

/// The default clear: every text part becomes a placeholder; with
/// [needOffload] the full result is offloaded and the placeholder says
/// where. Port of `defaultClearHandler`.
@visibleForTesting
ClearHandler defaultClearHandler(
  OffloadFilePathGenerator genOffloadFilePath,
  bool needOffload,
  String readFileToolName,
) =>
    (ctx, detail) async {
      final parts = await jointToolResult(detail);
      if (parts == null) return const ClearResult(needClear: false);
      if (needOffload) {
        final filePath = await genOffloadFilePath(ctx, detail);
        final placeholder = formatNamed(getClearWithOffloadingFmt(), {
          'file_path': filePath,
          'read_tool_name': readFileToolName,
        });
        final offloadContent = stringifyToolOutputParts(parts);
        return ClearResult(
          needClear: true,
          toolArgument: detail.toolArgument,
          toolResult: ToolResult(_replaceTexts(parts, placeholder)),
          needOffload: true,
          offloadFilePath: filePath,
          offloadContent: offloadContent,
        );
      }
      return ClearResult(
        needClear: true,
        toolArgument: detail.toolArgument,
        toolResult: ToolResult(_replaceTexts(parts, getClearWithoutOffloadingFmt())),
      );
    };

List<ToolOutputPart> _replaceTexts(List<ToolOutputPart> parts, String text) => [
      for (final part in parts) part.type == ToolPartType.text ? part.copyWith(text: text) : part,
    ];

/// The parts of [detail]'s result (a stream is read and joined), or `null`
/// when there is nothing to process: no parts, or a stream that failed.
/// Throws when the detail has no result at all. Port of
/// `getJointToolResult`.
@visibleForTesting
Future<List<ToolOutputPart>?> jointToolResult(ToolDetail detail) async {
  final result = detail.toolResult;
  final stream = detail.streamToolResult;
  if (result == null && stream == null) {
    throw const ThreepioException('ToolResult and StreamToolResult are both nil');
  }
  List<ToolOutputPart> parts;
  if (result != null) {
    parts = result.parts;
  } else {
    final chunks = <ToolResult>[];
    try {
      while (true) {
        chunks.add(await stream!.recv());
      }
    } on StreamEOFException {
      // The whole stream was read.
    } on Object {
      return null;
    }
    parts = concatToolResults(chunks).parts;
  }
  return parts.isEmpty ? null : parts;
}

/// [parts] as the text eino offloads: a single text part as it is,
/// anything else as indented JSON. Port of `stringifyToolOutputParts`.
@visibleForTesting
String stringifyToolOutputParts(List<ToolOutputPart> parts) {
  if (parts.isEmpty) return '';
  if (parts.length == 1 && parts.single.type == ToolPartType.text) return parts.single.text ?? '';
  return goIndentedToolOutputParts(parts);
}

/// Whether the clear phase has handled [message]. Port of
/// `getMsgClearedFlag`.
@visibleForTesting
bool messageClearedFlag(Message message) => message.extra?[msgClearedFlag] == true;

/// [message] marked as handled by the clear phase. Port of
/// `setMsgClearedFlag`.
@visibleForTesting
Message withMessageClearedFlag(Message message) =>
    message.copyWith(extra: {...?message.extra, msgClearedFlag: true});

/// [message] with the arguments of its tool call [index] replaced. Port of
/// `setToolCallArguments`.
@visibleForTesting
Message withToolCallArguments(Message message, int index, String arguments) {
  final calls = List<ToolCall>.of(message.toolCalls ?? const []);
  final call = calls[index];
  calls[index] = call.copyWith(function: call.function.copyWith(arguments: arguments));
  return message.copyWith(toolCalls: calls);
}

/// The result in a tool message, and whether it came from the content
/// (`true`) or the parts. Port of `toolResultFromMessage`.
@visibleForTesting
(ToolResult, bool) toolResultFromMessage(Message message) {
  if (message.role != RoleType.tool) {
    throw ThreepioException('message role ${message.role.name} is not a tool');
  }
  final multi = message.userInputMultiContent;
  if (multi != null && multi.isNotEmpty) {
    return (ToolResult([for (final part in multi) messageInputPartToToolOutputPart(part)]), false);
  }
  return (ToolResult.text(message.content), true);
}

/// A message part as a tool output part. Port of
/// `convMessageInputPartToToolOutputPart`.
@visibleForTesting
ToolOutputPart messageInputPartToToolOutputPart(MessageInputPart part) {
  MessagePartCommon common(MessagePartCommon? value) =>
      value ?? (throw ThreepioException('${part.type.name} content is nil'));
  return switch (part.type) {
    ChatMessagePartType.text => ToolOutputPart.text(part.text ?? ''),
    ChatMessagePartType.imageUrl => ToolOutputPart(
        type: ToolPartType.image,
        image: ToolOutputImage(common: common(part.image?.common)),
      ),
    ChatMessagePartType.audioUrl => ToolOutputPart(
        type: ToolPartType.audio,
        audio: ToolOutputAudio(common: common(part.audio?.common)),
      ),
    ChatMessagePartType.videoUrl => ToolOutputPart(
        type: ToolPartType.video,
        video: ToolOutputVideo(common: common(part.video?.common)),
      ),
    ChatMessagePartType.fileUrl => ToolOutputPart(
        type: ToolPartType.file,
        file: ToolOutputFile(common: common(part.file?.common)),
      ),
    _ => throw ThreepioException('unknown msg part type: ${_partTypeName(part.type)}'),
  };
}

/// The value eino writes for [type] (`image_url`, `tool_search_result`, ...).
String _partTypeName(ChatMessagePartType type) => switch (type) {
      ChatMessagePartType.text => 'text',
      ChatMessagePartType.imageUrl => 'image_url',
      ChatMessagePartType.audioUrl => 'audio_url',
      ChatMessagePartType.videoUrl => 'video_url',
      ChatMessagePartType.fileUrl => 'file_url',
      ChatMessagePartType.reasoning => 'reasoning',
      ChatMessagePartType.toolSearchResult => 'tool_search_result',
    };

/// [message] with [result] written back as its content ([fromContent]) or
/// its parts. Port of `setToolResultContent`.
@visibleForTesting
Message withToolResultContent(Message message, ToolResult result, {required bool fromContent}) {
  if (fromContent) {
    return result.parts.isEmpty ? message : message.copyWith(content: result.parts.first.text ?? '');
  }
  try {
    return message.copyWith(userInputMultiContent: result.toMessageInputParts());
    // Go leaves the message as it is when the conversion fails.
    // ignore: avoid_catching_errors
  } on StateError {
    return message;
  }
}

/// The default token count: one token per 4 bytes of each message's role,
/// reasoning, content, tool calls and text parts, and of each tool. Port of
/// `defaultTokenCounter`.
int defaultReductionTokenCount(RunContext ctx, List<Message> messages, List<ToolInfo> tools) {
  var tokens = 0;
  for (final message in messages) {
    final text = StringBuffer()
      ..write(message.role.name)
      ..write('\n')
      ..write(message.reasoningContent ?? '')
      ..write('\n')
      ..write(message.content)
      ..write('\n');
    if (message.role == RoleType.assistant) {
      for (final call in message.toolCalls ?? const <ToolCall>[]) {
        text
          ..write(call.function.name)
          ..write('\n')
          ..write(call.function.arguments);
      }
    }
    for (final part in message.userInputMultiContent ?? const <MessageInputPart>[]) {
      if (part.type == ChatMessagePartType.text) {
        text
          ..write(part.text ?? '')
          ..write('\n');
      }
    }
    for (final part in message.assistantGenMultiContent ?? const <MessageOutputPart>[]) {
      if (part.type == ChatMessagePartType.text) {
        text
          ..write(part.text ?? '')
          ..write('\n');
      }
    }
    tokens += utf8Length(text.toString()) ~/ 4;
  }
  for (final tool in tools) {
    tokens += utf8Length(goToolInfoValueJson(tool)) ~/ 4;
  }
  return tokens;
}
