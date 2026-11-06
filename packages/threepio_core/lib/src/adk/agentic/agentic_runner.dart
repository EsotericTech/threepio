/// The entry point for running an agentic agent.
///
/// Port of eino `adk.TypedRunner[*schema.AgenticMessage]` (`adk/runner.go`)
/// and of the agentic `typedFlowAgent` (`adk/flow.go`). **Beta**.
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
import '../../schema/agentic_message.dart';
import '../../streaming/stream_reader.dart';
import '../eino/agent_action.dart';
import '../eino/agent_context.dart';
import '../eino/cancel.dart';
import '../eino/interrupt.dart';
import '../eino/run_options.dart';
import 'agentic_agent.dart';
import 'agentic_callbacks.dart';
import 'agentic_react_graph.dart' show registerAgenticAdkTypes;

/// Runs an agentic agent: sets up the run's session values and callbacks,
/// names the agent's events, and saves and loads checkpoints for interrupt
/// and resume.
///
/// Port of eino `adk.TypedRunner[*schema.AgenticMessage]`
/// (`NewTypedRunner(TypedRunnerConfig{...})`). The checkpoint is the one the
/// classic `Runner` writes (`_eino_adk_serialization`), with the agentic
/// input as its agentic root input.
///
/// ```dart
/// final runner = AgenticRunner(
///   agent: agent,
///   checkpointStore: InMemoryCheckpointStore(),
/// );
/// final events = runner.query(ctx, 'Book a table',
///     options: [AgentRunOption.checkpointId('order-1')]);
/// // … an event with action.interrupted arrives; later:
/// final resumed = await runner.resumeWithParams(ctx, 'order-1',
///     ResumeParams(targets: {interruptId: approval}));
/// ```
final class AgenticRunner {
  /// A runner of [agent].
  AgenticRunner({
    required this.agent,
    this.enableStreaming = false,
    this.checkpointStore,
  });

  /// The agent the runner runs.
  final AgenticAgent agent;

  /// Whether the agent streams its model output.
  final bool enableStreaming;

  /// Where checkpoints are saved when a run interrupts (with
  /// `AgentRunOption.checkpointId`) and loaded from by [resume].
  final CheckpointStore? checkpointStore;

  /// Runs the agent on [messages]. Port of eino `TypedRunner.Run`.
  StreamReader<AgenticAgentEvent> run(
    RunContext ctx,
    List<AgenticMessage> messages, {
    List<AgentRunOption> options = const [],
  }) {
    // The checkpoint writes the agentic input; any agent may interrupt.
    registerAgenticAdkTypes();
    final common = CommonAgentOptions.of(options);
    final input = AgenticAgentInput(
      messages: messages,
      enableStreaming: enableStreaming,
    );
    final parent =
        common.sharedParentSession ? adkRunContextOf(ctx)?.session : null;
    final runCtx = withAdkRunContext(
      ctx,
      AdkRunContext(session: parent ?? RunSession(), agenticRootInput: input),
    )..addSessionValues(common.sessionValues);
    final events = AgenticFlowAgent(agent).run(runCtx, input, options);
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

  /// Runs the agent on one user message [text]. Port of eino
  /// `TypedRunner.Query`.
  StreamReader<AgenticAgentEvent> query(
    RunContext ctx,
    String text, {
    List<AgentRunOption> options = const [],
  }) =>
      run(ctx, [AgenticMessage.user(text)], options: options);

  /// Continues the run saved as [checkpointId], resuming every interrupted
  /// point without data. Port of eino `TypedRunner.Resume`.
  ///
  /// The run streams as the saved run did, whatever [enableStreaming] says.
  /// Throws [ThreepioException] when there is no store or no such
  /// checkpoint.
  Future<StreamReader<AgenticAgentEvent>> resume(
    RunContext ctx,
    String checkpointId, {
    List<AgentRunOption> options = const [],
  }) =>
      _resume(ctx, checkpointId, const {}, options);

  /// Continues the run saved as [checkpointId], giving the interrupt points
  /// in [ResumeParams.targets] their data. Port of eino
  /// `TypedRunner.ResumeWithParams`.
  Future<StreamReader<AgenticAgentEvent>> resumeWithParams(
    RunContext ctx,
    String checkpointId,
    ResumeParams params, {
    List<AgentRunOption> options = const [],
  }) =>
      _resume(ctx, checkpointId, params.targets, options);

  Future<StreamReader<AgenticAgentEvent>> _resume(
    RunContext ctx,
    String checkpointId,
    Map<String, Object?> targets,
    List<AgentRunOption> options,
  ) async {
    final store = checkpointStore;
    if (store == null) {
      throw const ThreepioException('failed to resume: store is nil');
    }
    registerAgenticAdkTypes();
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
        run = AdkRunContext(
          session: parent,
          rootInput: run.rootInput,
          agenticRootInput: run.agenticRootInput,
        );
      }
    }
    var runCtx = withAdkRunContext(loadedCtx, run)
      ..addSessionValues(common.sessionValues);
    if (targets.isNotEmpty) runCtx = runCtx.batchResumeWithData(targets);
    final events = AgenticFlowAgent(agent).resume(runCtx, info, options);
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
  static StreamReader<AgenticAgentEvent> _withCheckpoints(
    RunContext ctx,
    StreamReader<AgenticAgentEvent> events, {
    required CheckpointStore? store,
    required String? checkpointId,
    required bool enableStreaming,
    CancelContext? cancelContext,
  }) {
    final (reader, writer) = pipe<AgenticAgentEvent>();
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
                  AgenticAgentEvent(
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
            current = AgenticAgentEvent(
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
                  AgenticAgentEvent(
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
        writer.send(AgenticAgentEvent(error: error, stackTrace: stackTrace));
      } finally {
        await events.close();
        await writer.close();
      }
    }());
    return reader;
  }
}

/// The wrapper every agentic agent runs in: the run context, the agent's
/// address, its callbacks and the naming of its events.
///
/// Port of eino `typedFlowAgent` (the minimal wrapper eino uses for the
/// agentic path: no transfer, no history rewriting), with the cancel
/// bookkeeping of `wrapIterWithCancelCtx`. Eino names every event
/// without a run path; run paths are not ported, so, as in the classic
/// wrapper, an event is named when its agent name is empty.
@internal
final class AgenticFlowAgent {
  /// The wrapper of [agent].
  AgenticFlowAgent(this.agent);

  /// The agent.
  final AgenticAgent agent;

  /// Runs the agent. Port of `typedFlowAgent.Run`.
  StreamReader<AgenticAgentEvent> run(
    RunContext context,
    AgenticAgentInput input,
    List<AgentRunOption> options,
  ) {
    final name = agent.name;
    final cancelContext = CommonAgentOptions.of(options).cancelContext;
    final (entered, _) =
        initAdkRunContext(context, name, null, agenticInput: input);
    final ctx = withCancelContext(
      appendAddressSegmentTo(entered, addressSegmentAgent, name),
      cancelContext,
    );
    final filtered = filterOptions(name, options);
    final callbackCtx = initAgenticAgentCallbacks(
      ctx,
      name,
      agenticAgentTypeOf(agent),
      filtered,
    );
    // Without handlers the start callback does nothing: the agent starts at
    // once, as in eino, where `typedFlowAgent.Run` calls it synchronously.
    final started = callbackCtx.hasCallbacks
        ? null
        : _runSafely(callbackCtx, input, filtered);
    final (reader, writer) = pipe<AgenticAgentEvent>();
    unawaited(() async {
      try {
        var events = started;
        var forwardCtx = callbackCtx;
        if (events == null) {
          forwardCtx = await callbacks.onStart(
            callbackCtx,
            AgenticAgentCallbackInput(input: input),
          );
          events = _runSafely(forwardCtx, input, filtered);
        }
        await _forward(forwardCtx, events, writer, agentName: name);
        // Whatever escaped is the run's failure.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        writer.send(AgenticAgentEvent(error: error, stackTrace: stackTrace));
      } finally {
        await writer.close();
      }
    }());
    return wrapAgenticEventsWithCancelContext(reader, cancelContext);
  }

  /// Resumes the agent. Port of `typedFlowAgent.Resume`.
  StreamReader<AgenticAgentEvent> resume(
    RunContext context,
    ResumeInfo info,
    List<AgentRunOption> options,
  ) {
    final name = agent.name;
    final cancelContext = CommonAgentOptions.of(options).cancelContext;
    final (built, resumeInfo) = buildResumeInfo(context, name, info);
    final ctx = withCancelContext(built, cancelContext);
    final filtered = filterOptions(name, options);
    final (reader, writer) = pipe<AgenticAgentEvent>();
    unawaited(() async {
      try {
        var callbackCtx = initAgenticAgentCallbacks(
          ctx,
          name,
          agenticAgentTypeOf(agent),
          filtered,
        );
        callbackCtx = await callbacks.onStart(
          callbackCtx,
          AgenticAgentCallbackInput(resumeInfo: resumeInfo),
        );
        final resumable =
            agent is ResumableAgenticAgent ? agent as ResumableAgenticAgent : null;
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
              '${agent.runtimeType}) does not implement ResumableAgent '
              'interface. To support resume, your custom agent wrapper must '
              'implement the ResumableAgent interface',
            ),
            writer,
          );
          return;
        }
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
        writer.send(AgenticAgentEvent(error: error, stackTrace: stackTrace));
      } finally {
        await writer.close();
      }
    }());
    return wrapAgenticEventsWithCancelContext(reader, cancelContext);
  }

  /// The agent's events, or one error event when its `run` throws.
  StreamReader<AgenticAgentEvent> _runSafely(
    RunContext ctx,
    AgenticAgentInput input,
    List<AgentRunOption> options,
  ) {
    try {
      return agent.run(ctx, input, options: options);
      // A custom agent's failure becomes its event, as everywhere else.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      return StreamReader<AgenticAgentEvent>.fromIterable([
        AgenticAgentEvent(error: error, stackTrace: stackTrace),
      ]);
    }
  }

  /// The agent's events on resume, or one error event when `resume` throws.
  static StreamReader<AgenticAgentEvent> _resumeSafely(
    ResumableAgenticAgent agent,
    RunContext ctx,
    ResumeInfo info,
    List<AgentRunOption> options,
  ) {
    try {
      return agent.resume(ctx, info, options: options);
      // A custom agent's failure becomes its event, as everywhere else.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      return StreamReader<AgenticAgentEvent>.fromIterable([
        AgenticAgentEvent(error: error, stackTrace: stackTrace),
      ]);
    }
  }

  static StreamReader<AgenticAgentEvent> _failed(String message) =>
      StreamReader<AgenticAgentEvent>.fromIterable([
        AgenticAgentEvent(error: ThreepioException(message)),
      ]);

  /// Passes [events] on, names them with [agentName] when they have no
  /// name, and hands a copy of each to the callback handlers. Port of
  /// `typedFlowAgent.run` and `wrapAgenticIterWithOnEnd`.
  static Future<void> _forward(
    RunContext ctx,
    StreamReader<AgenticAgentEvent> events,
    StreamWriter<AgenticAgentEvent> writer, {
    String? agentName,
  }) async {
    StreamWriter<AgenticAgentEvent>? forCallbacks;
    if (ctx.hasCallbacks) {
      final (callbackEvents, callbackWriter) = pipe<AgenticAgentEvent>();
      forCallbacks = callbackWriter;
      unawaited(
        callbacks.onEndWithCopies(
          ctx,
          AgenticAgentCallbackOutput(callbackEvents),
          copyAgenticAgentCallbackOutput,
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
          final copy = copyAgenticAgentEvent(current);
          setAgenticAutomaticClose(copy);
          forCallbacks.send(copy);
        }
        setAgenticAutomaticClose(current);
        writer.send(current);
      }
    } finally {
      await events.close();
      await forCallbacks?.close();
    }
  }
}

/// [events] with the cancel bookkeeping of the run (eino
/// `wrapIterWithCancelCtx[*schema.AgenticMessage]`): the shared
/// `wrapTypedEventsWithCancelContext` with agentic events.
@internal
StreamReader<AgenticAgentEvent> wrapAgenticEventsWithCancelContext(
  StreamReader<AgenticAgentEvent> events,
  CancelContext? cancelContext,
) =>
    wrapTypedEventsWithCancelContext<AgenticAgentEvent>(
      events,
      cancelContext,
      interruptSignalOf: (event) => event.action?.interruptSignal,
      errorEvent: (error, [stackTrace]) =>
          AgenticAgentEvent(error: error, stackTrace: stackTrace),
    );
