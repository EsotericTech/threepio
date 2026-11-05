/// Turns the events of the Eino-shaped engine into the events of the
/// Kortney runtime.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../compose/errors.dart';
import '../../compose/tools_node.dart' show ToolsNodeException;
import '../../errors.dart';
import '../../schema/message.dart';
import '../../streaming/stream_reader.dart';
import '../eino/agent_event.dart' as eino;
import '../eino/react_graph.dart';
import '../events/agent_action.dart';
import '../events/agent_event.dart' hide TokenUsage;
import 'legacy_run.dart';

/// Maps one run of the engine to the legacy event sequence.
///
/// | engine | legacy |
/// |---|---|
/// | model stream chunks | `AgentOutputEvent(isPartial: true)` (with text), `AgentReasoningEvent` |
/// | end of the model stream | `AgentUsageEvent` |
/// | turn done (after the `afterModel` handlers) | `AgentMessageEvent`, then the final `AgentOutputEvent` and `AgentRunEndEvent`, or one `AgentActionEvent` per tool call |
/// | approval request | `AgentApprovalRequestEvent` |
/// | tool result | `ToolResultEvent`, `AgentArtifactEvent`s; once all calls of the turn have one, their `AgentMessageEvent`s in the order of the calls |
/// | cancel | `AgentCancelledEvent`, with synthetic results for the calls still running |
/// | `ExceedMaxIterationsException` | `AgentErrorEvent(isRecoverable: true)`, the last assistant output, `AgentRunEndEvent` |
/// | any other failure | `AgentErrorEvent(isRecoverable: false)` |
///
/// The legacy runtime reacted to its cancel token while tools were running;
/// the mapper does the same: it does not wait for the engine there.
@internal
final class LegacyEventMapper {
  LegacyEventMapper({
    required this.run,
    required this.writer,
    required this.input,
  });

  final LegacyRun run;
  final StreamWriter<AgentEvent> writer;
  final List<Message> input;

  final Stopwatch _stopwatch = Stopwatch();
  var _toolCallCount = 0;
  var _turn = -1;
  Message? _lastAssistant;
  List<ToolCall>? _pending;
  final Map<String, Message> _results = {};
  final Set<String> _skipped = {};

  /// Completes when the run is cancelled; one listener for the whole run.
  Future<Object?>? _cancelSignal;

  String get _runId => run.scope.runId;

  /// Emits the run's start event.
  void start() {
    _stopwatch.start();
    writer.send(
      AgentRunStartEvent(
        runId: _runId,
        agentName: run.config.name,
        inputMessages: input,
        metadata: run.scope.metadata,
      ),
    );
  }

  /// Maps [events] until the run ends, then closes them.
  Future<void> map(StreamReader<eino.AgentEvent> events) async {
    final cancel = run.scope.cancelToken;
    try {
      for (;;) {
        final eino.AgentEvent? event;
        if (_pending != null && run.config.parallelToolExecution) {
          // Tools are running side by side: the legacy runtime stopped
          // waiting for them when the run was cancelled. (Run one after the
          // other, the call in progress finished and the rest did not start;
          // see `skippedForCancel`.)
          final next = events.nextOrNull().then<Object?>(
                (event) => event ?? const _End(),
                onError: (Object error, StackTrace stackTrace) =>
                    _Failure(error, stackTrace),
              );
          final first = await Future.any<Object?>([
            next,
            _cancelSignal ??=
                cancel.whenCancelled.then((_) => const _Cancelled()),
          ]);
          switch (first) {
            case _Cancelled():
              _cancelled();
              return;
            case _End():
              return;
            case _Failure(:final error, :final stackTrace):
              Error.throwWithStackTrace(error, stackTrace);
            case final eino.AgentEvent value:
              event = value;
            default:
              return;
          }
        } else {
          event = await events.nextOrNull();
          if (event == null) return;
        }
        if (await _handle(event)) return;
      }
    } finally {
      await events.close();
    }
  }

  /// Handles one engine event; `true` when the run has ended.
  Future<bool> _handle(eino.AgentEvent event) async {
    final error = event.error;
    if (error != null) return _failed(error, event.stackTrace);
    final interrupted = event.action?.interrupted;
    if (interrupted != null) {
      // Nothing in this runtime resumes an interrupt: as before, it ends the
      // run as an error.
      return _failed(
        ThreepioException('the run was interrupted: $interrupted'),
        StackTrace.current,
      );
    }
    final output = event.output;
    final signal = output?.customizedOutput;
    if (signal is FacadeSignal) return _signal(signal);
    final variant = output?.messageOutput;
    if (variant != null && variant.role != RoleType.tool) {
      return _modelTurn(variant);
    }
    return false;
  }

  Future<bool> _modelTurn(eino.MessageVariant variant) async {
    _turn++;
    final cancel = run.scope.cancelToken;
    final callStopwatch = Stopwatch()..start();
    final chunks = <Message>[];
    void onChunk(Message raw) {
      final chunk = withoutMessageId(raw);
      chunks.add(chunk);
      if (run.config.emitPartialOutputs && chunk.content.isNotEmpty) {
        writer.send(
          AgentOutputEvent(runId: _runId, message: chunk, isPartial: true),
        );
      }
      final reasoning = chunk.reasoningContent;
      if (reasoning != null && reasoning.isNotEmpty) {
        writer.send(AgentReasoningEvent(runId: _runId, delta: reasoning));
      }
    }

    final stream = variant.messageStream;
    if (stream == null) {
      onChunk(variant.message!);
    } else {
      try {
        for (var chunk = await stream.nextOrNull();
            chunk != null;
            chunk = await stream.nextOrNull()) {
          onChunk(chunk);
        }
        // The model stream's failure ends the run.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        await stream.close();
        return _failed(error, stackTrace);
      }
    }
    if (cancel.isCancelled) {
      _cancelled();
      return true;
    }
    final usage = legacyAssemble(chunks).responseMeta?.usage;
    if (usage != null) {
      writer.send(
        AgentUsageEvent(
          runId: _runId,
          usage: usage,
          model: run.config.modelOptions?.model,
          latency: callStopwatch.elapsed,
        ),
      );
    }
    return false;
  }

  bool _signal(FacadeSignal signal) {
    switch (signal) {
      case FacadeTurnDone(:final response):
        _lastAssistant = response;
        writer.send(AgentMessageEvent(runId: _runId, message: response));
        final calls = response.toolCalls ?? const <ToolCall>[];
        if (calls.isEmpty) {
          writer.send(AgentOutputEvent(runId: _runId, message: response));
          _runEnd(response);
          return true;
        }
        _toolCallCount += calls.length;
        for (final call in calls) {
          writer.send(
            AgentActionEvent(
              runId: _runId,
              action: ToolCallAction(
                toolCallId: call.id,
                toolName: call.function.name,
                arguments: call.function.arguments,
              ),
              stepNumber: _turn,
            ),
          );
        }
        _pending = calls;
        _results.clear();
        _skipped.clear();
        return false;
      case FacadeApprovalRequested(:final call, :final reason):
        writer.send(
          AgentApprovalRequestEvent(runId: _runId, toolCall: call, reason: reason),
        );
        return false;
      case FacadeToolResult(:final call, :final output, :final durationMs):
        writer.send(
          ToolResultEvent(
            runId: _runId,
            toolCallId: call.id,
            toolName: call.function.name,
            result: output.content,
            isError: output.isError,
            durationMs: durationMs,
          ),
        );
        for (final artifact in output.artifacts) {
          writer.send(
            AgentArtifactEvent(
              runId: _runId,
              artifact: artifact,
              toolCallId: call.id,
            ),
          );
        }
        _results[call.id] = legacyToolMessage(call, output);
        return _turnOfToolsDone();
      case FacadeToolSkipped(:final call):
        _skipped.add(call.id);
        return _turnOfToolsDone();
    }
  }

  /// Once every call of the turn has a result or was skipped: their messages
  /// in the order of the calls, then the cancel check the legacy runtime made
  /// after the tools.
  bool _turnOfToolsDone() {
    final pending = _pending;
    if (pending == null ||
        !pending.every(
          (call) => _results.containsKey(call.id) || _skipped.contains(call.id),
        )) {
      return false;
    }
    if (run.scope.cancelToken.isCancelled) {
      _cancelled();
      return true;
    }
    _toolMessages(pending);
    _pending = null;
    return false;
  }

  /// The tool messages of [calls], in the order of the calls; a call
  /// without a result gets the synthetic cancelled result.
  List<String> _toolMessages(List<ToolCall> calls) {
    final missing = <String>[];
    for (final call in calls) {
      final message = _results[call.id];
      if (message == null) missing.add(call.id);
      writer.send(
        AgentMessageEvent(
          runId: _runId,
          message: message ?? legacyCancelledToolMessage(call),
        ),
      );
    }
    return missing;
  }

  void _cancelled() {
    final pending = _pending;
    final missing = pending == null ? const <String>[] : _toolMessages(pending);
    _pending = null;
    writer.send(
      AgentCancelledEvent(
        runId: _runId,
        reason: run.scope.cancelToken.reason,
        cancelledToolCallIds: missing,
      ),
    );
  }

  bool _failed(Object error, StackTrace? stackTrace) {
    if (run.scope.cancelToken.isCancelled) {
      _cancelled();
      return true;
    }
    final root = _rootCause(error);
    if (ThreepioException.findCause<ExceedMaxIterationsException>(error) !=
        null) {
      writer.send(
        AgentErrorEvent(
          runId: _runId,
          error: 'Stopped after ${run.config.maxIterations} iterations without '
              'a final answer',
          isRecoverable: true,
        ),
      );
      final output = _lastAssistant ?? Message.assistant('');
      writer.send(AgentOutputEvent(runId: _runId, message: output));
      _runEnd(output);
      return true;
    }
    writer.send(
      AgentErrorEvent(
        runId: _runId,
        error: root.toString(),
        stackTrace: (stackTrace ?? StackTrace.current).toString(),
        isRecoverable: false,
      ),
    );
    return true;
  }

  void _runEnd(Message output) => writer.send(
        AgentRunEndEvent(
          runId: _runId,
          agentName: run.config.name,
          outputMessage: output,
          durationMs: _stopwatch.elapsedMilliseconds,
          toolCallCount: _toolCallCount,
        ),
      );

  /// What the engine's graph wrapped [error] around: the failure the legacy
  /// runtime reported.
  static Object _rootCause(Object error) {
    var current = error;
    for (var depth = 0; depth < 64; depth++) {
      if ((current is GraphRunException || current is ToolsNodeException) &&
          (current as ThreepioException).cause != null) {
        current = current.cause!;
        continue;
      }
      break;
    }
    return current;
  }
}

final class _End {
  const _End();
}

final class _Cancelled {
  const _Cancelled();
}

final class _Failure {
  const _Failure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
