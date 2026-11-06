/// The entry point for running an agent.
///
/// Port of eino `adk.Runner` (`adk/runner.go`) and of the parts of eino's
/// `flowAgent` (`adk/flow.go`) that are not agent transfer.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../callbacks/callback_context.dart';
import '../../callbacks/component_callbacks.dart' as callbacks;
import '../../compose/checkpoint_store.dart';
import '../../compose/interrupt.dart';
import '../../compose/resume.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../streaming/stream_reader.dart';
import 'agent.dart';
import 'agent_action.dart';
import 'agent_callbacks.dart';
import 'agent_context.dart';
import 'agent_event.dart';
import 'cancel.dart';
import 'interrupt.dart';
import 'run_options.dart';

/// Runs an agent: sets up the run's session values and callbacks, names the
/// agent's events, and saves and loads checkpoints for interrupt and resume.
///
/// Port of eino `adk.Runner` (`NewRunner(RunnerConfig{...})`).
///
/// ```dart
/// final runner = Runner(
///   agent: agent,
///   enableStreaming: true,
///   checkpointStore: InMemoryCheckpointStore(),
/// );
/// final events = runner.query(ctx, 'Book a table',
///     options: [AgentRunOption.checkpointId('order-1')]);
/// // … an event with action.interrupted arrives; later:
/// final resumed = await runner.resumeWithParams(ctx, 'order-1',
///     ResumeParams(targets: {interruptId: approval}));
/// ```
///
/// This is the Eino-shaped `Runner` of `package:threepio_core/adk.dart`; the
/// umbrella library exports an unrelated, older `Runner` (the Kortney
/// runtime, which is built on this one).
final class Runner {
  /// A runner of [agent].
  Runner({
    required this.agent,
    this.enableStreaming = false,
    this.checkpointStore,
  });

  /// The agent the runner runs.
  final Agent agent;

  /// Whether the agent streams its model output.
  final bool enableStreaming;

  /// Where checkpoints are saved when a run interrupts (with
  /// `AgentRunOption.checkpointId`) and loaded from by [resume].
  final CheckpointStore? checkpointStore;

  /// Runs the agent on [messages]. Port of eino `Runner.Run`.
  StreamReader<AgentEvent> run(
    RunContext ctx,
    List<Message> messages, {
    List<AgentRunOption> options = const [],
  }) {
    final common = CommonAgentOptions.of(options);
    final input = AgentInput(messages: messages, enableStreaming: enableStreaming);
    final runCtx = withNewAdkRunContext(
      ctx,
      input,
      sharedParentSession: common.sharedParentSession,
    )..addSessionValues(common.sessionValues);
    final events = FlowAgent(agent).run(runCtx, input, options);
    final store = checkpointStore;
    if (store == null && common.cancelContext == null) return events;
    return _withCheckpoints(
      runCtx,
      events,
      store: store,
      checkpointId: common.checkpointId,
      enableStreaming: enableStreaming,
      cancelContext: common.cancelContext,
    );
  }

  /// Runs the agent on one user message [text]. Port of eino `Runner.Query`.
  StreamReader<AgentEvent> query(
    RunContext ctx,
    String text, {
    List<AgentRunOption> options = const [],
  }) =>
      run(ctx, [Message.user(text)], options: options);

  /// Continues the run saved as [checkpointId], resuming every interrupted
  /// point without data. Port of eino `Runner.Resume`.
  ///
  /// The run streams as the saved run did, whatever [enableStreaming] says.
  /// Throws [ThreepioException] when there is no store or no such
  /// checkpoint.
  Future<StreamReader<AgentEvent>> resume(
    RunContext ctx,
    String checkpointId, {
    List<AgentRunOption> options = const [],
  }) =>
      _resume(ctx, checkpointId, const {}, options);

  /// Continues the run saved as [checkpointId], giving the interrupt points
  /// in [ResumeParams.targets] their data. Port of eino
  /// `Runner.ResumeWithParams`.
  ///
  /// Points named in the targets see themselves as resume targets
  /// (`getResumeContext`); an interrupted leaf that is not named interrupts
  /// again, while the agents and tools on the way to a named point go on.
  Future<StreamReader<AgentEvent>> resumeWithParams(
    RunContext ctx,
    String checkpointId,
    ResumeParams params, {
    List<AgentRunOption> options = const [],
  }) =>
      _resume(ctx, checkpointId, params.targets, options);

  Future<StreamReader<AgentEvent>> _resume(
    RunContext ctx,
    String checkpointId,
    Map<String, Object?> targets,
    List<AgentRunOption> options,
  ) async {
    final store = checkpointStore;
    if (store == null) {
      throw const ThreepioException('failed to resume: store is nil');
    }
    final RunContext loadedCtx;
    AdkRunContext run;
    final ResumeInfo info;
    try {
      (loadedCtx, run, info) = await loadAdkCheckpoint(store, ctx, checkpointId);
    } on ThreepioException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        ThreepioException(
          'failed to load from checkpoint: ${error.message}',
          cause: error,
        ),
        stackTrace,
      );
    }
    final common = CommonAgentOptions.of(options);
    if (common.sharedParentSession) {
      final parent = adkRunContextOf(ctx)?.session;
      if (parent != null) {
        run = AdkRunContext(session: parent, rootInput: run.rootInput);
      }
    }
    var runCtx = withAdkRunContext(loadedCtx, run)
      ..addSessionValues(common.sessionValues);
    if (targets.isNotEmpty) runCtx = runCtx.batchResumeWithData(targets);
    final events = FlowAgent(agent).resume(runCtx, info, options);
    return _withCheckpoints(
      runCtx,
      events,
      store: store,
      checkpointId: checkpointId,
      enableStreaming: info.enableStreaming,
      cancelContext: common.cancelContext,
    );
  }

  /// Passes [events] on and saves a checkpoint when the run interrupts or is
  /// cancelled. Port of eino `typedRunnerHandleIterImpl`.
  static StreamReader<AgentEvent> _withCheckpoints(
    RunContext ctx,
    StreamReader<AgentEvent> events, {
    required CheckpointStore? store,
    required String? checkpointId,
    required bool enableStreaming,
    CancelContext? cancelContext,
  }) {
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(() async {
      AddressedInterruptSignal? interrupt;
      try {
        for (var event = await events.nextOrNull();
            event != null;
            event = await events.nextOrNull()) {
          final cancelled =
              ThreepioException.findCause<AgentRunCancelledException>(
            event.error,
          );
          if (cancelled != null) {
            if (cancelContext != null &&
                cancelContext.isRoot &&
                cancelContext.shouldCancel) {
              cancelContext.markCancelHandled();
            }
            var cancelEvent = event;
            final signal = cancelled.interruptSignal;
            if (signal != null && checkpointId != null) {
              final withContexts = cancelled.withInterruptContexts(
                toInterruptContexts(
                  signal,
                  allowedSegmentTypes: allowedAddressSegmentTypes,
                ),
              );
              // The root's cancel wrapper sends the error itself; a wrapped
              // one (from a custom agent) is passed on as it is.
              cancelEvent = identical(event.error, cancelled)
                  ? event.copyWith(error: withContexts)
                  : event;
            }
            if (signal != null && checkpointId != null && store != null) {
              try {
                await saveAdkCheckpoint(
                  enableStreaming: enableStreaming,
                  store: store,
                  ctx: ctx,
                  key: checkpointId,
                  signal: signal,
                );
                // Whatever the store or the encoder throws.
                // ignore: avoid_catches_without_on_clauses
              } catch (error, stackTrace) {
                writer.send(
                  AgentEvent(
                    error: ThreepioException(
                      'failed to save checkpoint on cancel: $error',
                      cause: error,
                    ),
                    stackTrace: stackTrace,
                  ),
                );
              }
            }
            writer.send(cancelEvent);
            break;
          }
          var current = event;
          final action = event.action;
          final signal = action?.interruptSignal;
          if (action != null && signal != null) {
            if (interrupt != null) {
              throw StateError(
                'multiple interrupt actions should not happen in Runner',
              );
            }
            interrupt = signal;
            current = AgentEvent(
              agentName: event.agentName,
              output: event.output,
              action: AgentAction.interruptedBy(
                AgentInterruptInfo(
                  data: action.interrupted?.data,
                  interruptContexts: toInterruptContexts(
                    signal,
                    allowedSegmentTypes: allowedAddressSegmentTypes,
                  ),
                ),
                signal,
              ),
            );
            if (checkpointId != null && store != null) {
              try {
                await saveAdkCheckpoint(
                  enableStreaming: enableStreaming,
                  store: store,
                  ctx: ctx,
                  key: checkpointId,
                  signal: signal,
                );
                // Whatever the store or the encoder throws.
                // ignore: avoid_catches_without_on_clauses
              } catch (error, stackTrace) {
                writer.send(
                  AgentEvent(
                    error: ThreepioException(
                      'failed to save checkpoint: $error',
                      cause: error,
                    ),
                    stackTrace: stackTrace,
                  ),
                );
              }
            }
          }
          writer.send(current);
        }
        // A failure of the loop itself becomes the last event.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        writer.send(AgentEvent(error: error, stackTrace: stackTrace));
      } finally {
        await events.close();
        await writer.close();
      }
    }());
    return reader;
  }
}

/// The wrapper every agent runs in: the run context, the agent's address,
/// its callbacks and the naming of its events.
///
/// Port of eino `flowAgent` without agent transfer (sub-agents, history
/// rewriting, transfer actions and run paths are not ported).
@internal
final class FlowAgent {
  /// The wrapper of [agent].
  FlowAgent(this.agent);

  /// The agent.
  final Agent agent;

  /// Runs the agent. Port of `flowAgent.Run`.
  StreamReader<AgentEvent> run(
    RunContext context,
    AgentInput input,
    List<AgentRunOption> options,
  ) {
    final name = agent.name;
    final cancelContext = CommonAgentOptions.of(options).cancelContext;
    final (entered, run) = initAdkRunContext(context, name, input);
    final ctx = withCancelContext(
      appendAddressSegmentTo(entered, addressSegmentAgent, name),
      cancelContext,
    );
    final filtered = filterOptions(name, options);
    final processed = _inputOf(run, input);
    final callbackCtx =
        initAgentCallbacks(ctx, name, agentTypeOf(agent), filtered);
    // Without handlers the start callback does nothing: the agent starts at
    // once, as in eino, where `flowAgent.Run` calls it synchronously.
    final started = callbackCtx.hasCallbacks
        ? null
        : _runSafely(callbackCtx, processed, filtered);
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(() async {
      try {
        var events = started;
        var forwardCtx = callbackCtx;
        if (events == null) {
          forwardCtx = await callbacks.onStart(
            callbackCtx,
            AgentCallbackInput(input: processed),
          );
          events = _runSafely(forwardCtx, processed, filtered);
        }
        await _forward(forwardCtx, events, writer, agentName: name);
        // Whatever escaped is the run's failure.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        writer.send(AgentEvent(error: error, stackTrace: stackTrace));
      } finally {
        await writer.close();
      }
    }());
    return wrapEventsWithCancelContext(reader, cancelContext);
  }

  /// Resumes the agent. Port of `flowAgent.Resume`.
  StreamReader<AgentEvent> resume(
    RunContext context,
    ResumeInfo info,
    List<AgentRunOption> options,
  ) {
    final name = agent.name;
    final cancelContext = CommonAgentOptions.of(options).cancelContext;
    final (built, resumeInfo) = buildResumeInfo(context, name, info);
    final ctx = withCancelContext(built, cancelContext);
    final filtered = filterOptions(name, options);
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(() async {
      try {
        var callbackCtx = initAgentCallbacks(ctx, name, agentTypeOf(agent), filtered);
        callbackCtx = await callbacks.onStart(
          callbackCtx,
          AgentCallbackInput(resumeInfo: resumeInfo),
        );
        final resumable = agent is ResumableAgent ? agent as ResumableAgent : null;
        if (resumeInfo.wasInterrupted) {
          if (resumable == null) {
            cancelContext?.markDone();
            await _forward(
              callbackCtx,
              _failed(
                "failed to resume agent: agent '$name' is an interrupt point "
                'but is not a ResumableAgent',
              ),
              writer,
            );
            return;
          }
          await _forward(
            callbackCtx,
            _resumeSafely(resumable, callbackCtx, resumeInfo, options),
            writer,
            agentName: name,
          );
          return;
        }
        try {
          nextResumeAgent(ctx);
        } on ThreepioException catch (error) {
          cancelContext?.markDone();
          await _forward(callbackCtx, _failed(error.message), writer);
          return;
        }
        if (resumable == null) {
          await _forward(
            callbackCtx,
            _failed(
              "failed to resume agent: agent '$name' (type "
              '${agent.runtimeType}) has no sub-agents and does not implement '
              'ResumableAgent interface. To support resume, your custom agent '
              'wrapper must implement the ResumableAgent interface',
            ),
            writer,
          );
          return;
        }
        // Eino hands the agent the options without the cancel option here:
        // it reaches the run's cancel context through the context.
        await _forward(
          callbackCtx,
          _resumeSafely(
            resumable,
            callbackCtx,
            resumeInfo,
            filterCancelOption(options),
          ),
          writer,
        );
        // Whatever escaped is the run's failure.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        writer.send(AgentEvent(error: error, stackTrace: stackTrace));
      } finally {
        await writer.close();
      }
    }());
    return wrapEventsWithCancelContext(reader, cancelContext);
  }

  /// The agent's events, or one error event when its `run` throws.
  StreamReader<AgentEvent> _runSafely(
    RunContext ctx,
    AgentInput input,
    List<AgentRunOption> options,
  ) {
    try {
      return agent.run(ctx, input, options: options);
      // A custom agent's failure becomes its event, as everywhere else.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      return StreamReader<AgentEvent>.fromIterable([
        AgentEvent(error: error, stackTrace: stackTrace),
      ]);
    }
  }

  /// The agent's events on resume, or one error event when `resume` throws.
  static StreamReader<AgentEvent> _resumeSafely(
    ResumableAgent agent,
    RunContext ctx,
    ResumeInfo info,
    List<AgentRunOption> options,
  ) {
    try {
      return agent.resume(ctx, info, options: options);
      // A custom agent's failure becomes its event, as everywhere else.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      return StreamReader<AgentEvent>.fromIterable([
        AgentEvent(error: error, stackTrace: stackTrace),
      ]);
    }
  }

  /// The input the agent gets. Port of eino `genAgentInput` without the
  /// history of agent transfer: a copy of the root input of the run.
  static AgentInput _inputOf(AdkRunContext run, AgentInput input) {
    final root = run.rootInput ?? input;
    return AgentInput(
      messages: root.messages,
      enableStreaming: root.enableStreaming,
    );
  }

  static StreamReader<AgentEvent> _failed(String message) =>
      StreamReader<AgentEvent>.fromIterable([
        AgentEvent(error: ThreepioException(message)),
      ]);

  /// Passes [events] on, names them with [agentName] when they have no name,
  /// and hands a copy of each to the callback handlers. Port of
  /// `flowAgent.run` and `wrapIterWithOnEnd`.
  static Future<void> _forward(
    RunContext ctx,
    StreamReader<AgentEvent> events,
    StreamWriter<AgentEvent> writer, {
    String? agentName,
  }) async {
    StreamWriter<AgentEvent>? forCallbacks;
    if (ctx.hasCallbacks) {
      final (callbackEvents, callbackWriter) = pipe<AgentEvent>();
      forCallbacks = callbackWriter;
      unawaited(
        callbacks.onEndWithCopies(
          ctx,
          AgentCallbackOutput(callbackEvents),
          copyAgentCallbackOutput,
        ),
      );
    }
    try {
      for (var event = await events.nextOrNull();
          event != null;
          event = await events.nextOrNull()) {
        var current = event;
        if (agentName != null && current.agentName.isEmpty) {
          current = current.copyWith(agentName: agentName);
        }
        if (forCallbacks != null) {
          final copy = copyAgentEvent(current);
          setAutomaticClose(copy);
          forCallbacks.send(copy);
        }
        setAutomaticClose(current);
        writer.send(current);
      }
    } finally {
      await events.close();
      await forCallbacks?.close();
    }
  }
}
