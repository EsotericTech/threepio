import 'dart:async';

import '../../components/model/cancel_token.dart';
import '../../schema/message.dart';
import '../../streaming/stream_reader.dart';
import '../events/agent_event.dart' hide TokenUsage;
import 'chat_model_agent.dart';

/// Thrown when a session already has a run in progress.
class RunInProgressException implements Exception {
  const RunInProgressException(this.sessionId);

  final String sessionId;

  @override
  String toString() => 'RunInProgressException: session $sessionId is busy';
}

/// Outcome of a run, assembled from its events.
class RunResult {
  const RunResult({
    required this.runId,
    required this.messages,
    required this.usage,
    this.finalMessage,
    this.cancelled = false,
    this.error,
  });

  final String runId;

  /// Messages the agent appended (assistant turns and tool results), in
  /// order — persist these after the user's message.
  final List<Message> messages;

  /// The last assistant message without tool calls, if the run finished.
  final Message? finalMessage;
  final TokenUsage usage;
  final bool cancelled;

  /// Last non-recoverable error, if any.
  final String? error;

  bool get succeeded => error == null && !cancelled;
}

/// A live run: its events, cancellation and approval channel.
class RunHandle {
  RunHandle._({
    required this.runId,
    required this.sessionId,
    required Stream<AgentEvent> events,
    required Future<RunResult> result,
    required CancelToken cancelToken,
    required Map<String, Completer<bool>> pendingApprovals,
  })  : _events = events,
        _result = result,
        _cancelToken = cancelToken,
        _pendingApprovals = pendingApprovals;

  final String runId;
  final String? sessionId;
  final Stream<AgentEvent> _events;
  final Future<RunResult> _result;
  final CancelToken _cancelToken;
  final Map<String, Completer<bool>> _pendingApprovals;

  /// Single-subscription stream of events, buffered until listened to.
  Stream<AgentEvent> get events => _events;

  /// Completes when the run ends (also on cancel or error).
  Future<RunResult> get result => _result;

  bool get isCancelled => _cancelToken.isCancelled;

  /// Tool call ids currently waiting for approval.
  Iterable<String> get pendingApprovalIds => _pendingApprovals.keys;

  /// Stops the run at the next safe point.
  void cancel([String? reason]) => _cancelToken.cancel(reason);

  /// Answers a pending approval; returns false if none is pending for [id].
  bool approve(String toolCallId, {required bool allow}) {
    final completer = _pendingApprovals.remove(toolCallId);
    if (completer == null || completer.isCompleted) return false;
    completer.complete(allow);
    return true;
  }
}

/// Runs a [ChatModelAgent] with per-session tracking (one run per session),
/// approval plumbing with timeout and default decision, and a [RunResult]
/// assembled from the events (Eino's `Runner`).
class Runner {
  Runner({
    required this.agent,
    this.approvalTimeout = const Duration(seconds: 60),
    this.defaultApproval = false,
  });

  final ChatModelAgent agent;

  /// How long an approval request waits before [defaultApproval] applies.
  final Duration approvalTimeout;

  /// Decision applied when nobody answers in time.
  final bool defaultApproval;

  final Map<String, RunHandle> _active = {};

  /// The run in progress for [sessionId], if any.
  RunHandle? activeRun(String sessionId) => _active[sessionId];

  /// Starts a run. Throws [RunInProgressException] when [sessionId] is busy.
  ///
  /// The session is reserved before anything asynchronous happens, so two
  /// calls for the same session can never both start.
  Future<RunHandle> run(
    List<Message> messages, {
    String? sessionId,
    Map<String, dynamic> metadata = const {},
  }) async {
    if (sessionId != null && _active.containsKey(sessionId)) {
      throw RunInProgressException(sessionId);
    }

    final cancelToken = CancelToken();
    final pending = <String, Completer<bool>>{};
    final context = AgentRunScope(
      sessionId: sessionId,
      cancelToken: cancelToken,
      metadata: metadata,
      requestApproval: (call, reason) {
        final completer = Completer<bool>();
        pending[call.id] = completer;
        return completer.future
            .timeout(approvalTimeout, onTimeout: () => defaultApproval)
            .whenComplete(() => pending.remove(call.id));
      },
    );

    final controller = StreamController<AgentEvent>();
    final resultCompleter = Completer<RunResult>();
    final handle = RunHandle._(
      runId: context.runId,
      sessionId: sessionId,
      events: controller.stream,
      result: resultCompleter.future,
      cancelToken: cancelToken,
      pendingApprovals: pending,
    );
    if (sessionId != null) _active[sessionId] = handle;

    final appended = <Message>[];
    Message? finalMessage;
    var usage = TokenUsage.zero;
    var cancelled = false;
    String? error;

    /// Ends the run: frees the session, closes [RunHandle.events] and
    /// completes [RunHandle.result].
    Future<void> finish() async {
      if (sessionId != null) _active.remove(sessionId);

      // A listener sees every event before the result completes. Without a
      // listener the done event is never delivered, so waiting for it would
      // leave the result pending forever; the events stay buffered instead.
      final closed = controller.close();
      if (controller.hasListener) await closed;

      resultCompleter.complete(
        RunResult(
          runId: context.runId,
          messages: appended,
          finalMessage: finalMessage,
          usage: usage,
          cancelled: cancelled || cancelToken.isCancelled,
          error: error,
        ),
      );
    }

    final StreamReader<AgentEvent> reader;
    try {
      reader = await agent.run(messages, context: context);
    } catch (e) {
      error = e.toString();
      await finish();
      rethrow;
    }

    unawaited(() async {
      try {
        await for (final event in reader.asStream()) {
          switch (event) {
            case AgentMessageEvent(:final message):
              appended.add(message);
            case AgentOutputEvent(:final message, :final isPartial)
                when !isPartial:
              finalMessage = message;
            case AgentUsageEvent(usage: final u):
              usage = usage + u;
            case AgentCancelledEvent():
              cancelled = true;
            case AgentErrorEvent(error: final message, :final isRecoverable)
                when !isRecoverable:
              error = message;
            default:
              break;
          }
          controller.add(event);
        }
      } catch (e, st) {
        error ??= e.toString();
        controller.addError(e, st);
      } finally {
        await finish();
      }
    }());

    return handle;
  }
}
