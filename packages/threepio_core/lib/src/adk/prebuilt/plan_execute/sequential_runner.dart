/// Runs agents one after the other: the outer half of the plan-execute agent.
///
/// Port of the sequential mode of eino's `workflowAgent` (`adk/workflow.go`:
/// `runSequential`, `sequentialWorkflowState`, `cancelAtTransition`). Eino's
/// public `NewSequentialAgent` is marked as not recommended and is not
/// ported; this runner is internal to the plan-execute port and **not
/// exported** from `adk.dart` or any other library.
@internal
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../../components/component_type.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/type_registry.dart';
import '../../../streaming/stream_reader.dart';
import '../../eino/agent.dart';
import '../../eino/agent_context.dart';
import '../../eino/agent_event.dart';
import '../../eino/cancel.dart';
import '../../eino/interrupt.dart';
import '../../eino/run_options.dart';
import '../../eino/runner.dart';
import 'loop_runner.dart';

/// Runs [subAgents] in order, each in its own wrapper (address, callbacks,
/// event names), sharing the run's session; stops at the first error event
/// and turns a sub-agent's interrupt into its own, so that a resume continues
/// at that sub-agent.
///
/// Port of eino's sequential `workflowAgent`, without agent transfer (no
/// `Exit` action, no run path; a sub-agent gets the run's root input as its
/// input, not the history of the agents before it).
@internal
final class SequentialRunner implements WorkflowRunnerAgent, TypedComponent {
  /// A runner of [subAgents] called [name].
  SequentialRunner({
    required this.name,
    required List<Agent> subAgents,
    this.description = '',
  }) : subAgents = List.unmodifiable(subAgents) {
    ensureRunnerTypesRegistered();
  }

  @override
  final String name;

  @override
  final String description;

  /// The agents, in the order they run.
  final List<Agent> subAgents;

  /// Port of `workflowAgent.GetType` for the sequential mode.
  @override
  String get componentTypeName => 'Sequential';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      runnerEvents((writer) => _runSequential(ctx, writer, input, null, null, options));

  @override
  StreamReader<AgentEvent> resume(
    RunContext ctx,
    ResumeInfo info, {
    List<AgentRunOption> options = const [],
  }) =>
      runnerEvents((writer) async {
        final state = info.interruptState;
        if (state == null) {
          throw ThreepioException(
            "workflowAgent.Resume: agent '$name' was asked to resume but has "
            'no state',
          );
        }
        if (state is! SequentialRunnerState) {
          throw ThreepioException(
            'unsupported workflow agent state type: ${state.runtimeType}',
          );
        }
        await _runSequential(ctx, writer, rootInputOf(ctx), state, info, options);
      });

  Future<void> _runSequential(
    RunContext ctx,
    StreamWriter<AgentEvent> writer,
    AgentInput input,
    SequentialRunnerState? resumed,
    ResumeInfo? info,
    List<AgentRunOption> options,
  ) async {
    var state = resumed;
    for (var i = state?.interruptIndex ?? 0; i < subAgents.length; i++) {
      final subAgent = subAgents[i];
      // A transition between sub-agents is always a safe point.
      final cancelContext = cancelContextOf(ctx);
      if (cancelContext != null && cancelContext.shouldCancel) {
        writer.send(
          cancelAtTransition(
            ctx,
            'Sequential workflow cancel at transition',
            SequentialRunnerState(interruptIndex: i),
          ),
        );
        return;
      }
      final events = startSubAgent(
        ctx,
        subAgent,
        input,
        options,
        resume: state?.subAgentInterrupted ?? false,
        enableStreaming: info?.enableStreaming ?? false,
      );
      state = null;

      AgentEvent? lastAction;
      try {
        for (var event = await events.nextOrNull();
            event != null;
            event = await events.nextOrNull()) {
          if (event.error != null) {
            writer.send(event);
            return;
          }
          if (lastAction != null) {
            writer.send(lastAction);
            lastAction = null;
          }
          if (event.action != null) {
            lastAction = event;
            continue;
          }
          writer.send(event);
        }
      } finally {
        await events.close();
      }

      if (lastAction != null) {
        final signal = lastAction.action!.interruptSignal;
        if (signal != null) {
          writer.send(
            compositeInterruptEvent(
              ctx,
              'Sequential workflow interrupted',
              SequentialRunnerState(interruptIndex: i, subAgentInterrupted: true),
              [signal],
            ).copyWith(agentName: lastAction.agentName),
          );
          return;
        }
        writer.send(lastAction);
      }
    }
  }

  @override
  String toString() => 'SequentialRunner($name)';
}

/// Where a [SequentialRunner] stopped. Port of eino
/// `sequentialWorkflowState` plus whether the sub-agent at [interruptIndex]
/// interrupted (eino keeps that as `WorkflowInterruptInfo` in the
/// checkpoint's deprecated `Info`); without it, the sub-agent is run again
/// from the start (a cancel at the transition before it). Unlike eino, whose
/// cancel checkpoint drops that `Info`, the flag also survives a cancel of
/// the whole run, so a resume continues the sub-agent from its checkpoint.
@internal
@immutable
final class SequentialRunnerState {
  /// The state of a runner that stopped before or inside sub-agent
  /// [interruptIndex].
  const SequentialRunnerState({
    required this.interruptIndex,
    this.subAgentInterrupted = false,
  });

  /// A state from its JSON form.
  factory SequentialRunnerState.fromJson(Map<String, Object?> json) =>
      SequentialRunnerState(
        interruptIndex: (json['interrupt_index']! as num).toInt(),
        subAgentInterrupted: json['sub_agent_interrupted'] == true,
      );

  /// The sub-agent to continue with.
  final int interruptIndex;

  /// Whether that sub-agent interrupted and is to be resumed.
  final bool subAgentInterrupted;

  /// The JSON form, as checkpoints keep it.
  Map<String, Object?> toJson() => {
        'interrupt_index': interruptIndex,
        'sub_agent_interrupted': subAgentInterrupted,
      };

  @override
  bool operator ==(Object other) =>
      other is SequentialRunnerState &&
      other.interruptIndex == interruptIndex &&
      other.subAgentInterrupted == subAgentInterrupted;

  @override
  int get hashCode => Object.hash(interruptIndex, subAgentInterrupted);

  @override
  String toString() =>
      'SequentialRunnerState($interruptIndex, interrupted: $subAgentInterrupted)';
}

/// The events of [body], which writes them; what it throws becomes the last
/// event (eino recovers a panic of the goroutine into an error event).
@internal
StreamReader<AgentEvent> runnerEvents(
  Future<void> Function(StreamWriter<AgentEvent> writer) body,
) {
  final (reader, writer) = pipe<AgentEvent>();
  unawaited(() async {
    try {
      await body(writer);
      // The runner's own failure is its last event.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      writer.send(AgentEvent(error: error, stackTrace: stackTrace));
    } finally {
      await writer.close();
    }
  }());
  return reader;
}

/// Runs or resumes [subAgent] in its wrapper, with a cancel context derived
/// from the run's (eino's `deriveCheckpointAwareSubAgentCancelContext` and
/// `appendCancelContextOption`).
@internal
StreamReader<AgentEvent> startSubAgent(
  RunContext ctx,
  Agent subAgent,
  AgentInput input,
  List<AgentRunOption> options, {
  required bool resume,
  required bool enableStreaming,
}) {
  final childCancel = deriveCheckpointAwareSubAgentCancelContext(ctx, options);
  final childOptions = appendCancelContextOption(options, childCancel);
  final wrapped = FlowAgent(subAgent);
  return resume
      ? wrapped.resume(ctx, ResumeInfo(enableStreaming: enableStreaming), childOptions)
      : wrapped.run(ctx, input, childOptions);
}

/// The input a sub-agent gets on resume: the root input of the run (eino's
/// sub-agents build theirs from it too).
@internal
AgentInput rootInputOf(RunContext ctx) =>
    adkRunContextOf(ctx)?.rootInput ?? AgentInput();

/// The interrupt a runner sends when it is cancelled between two
/// sub-agents: a leaf interrupt that keeps [state]. Port of eino
/// `cancelAtTransition`; the cancel wrapper of the root turns it into an
/// `AgentRunCancelledException`.
@internal
AgentEvent cancelAtTransition(RunContext ctx, String info, Object state) =>
    statefulInterruptEvent(ctx, info, state);

/// Registers the runners' interrupt states under eino's names. Idempotent.
@internal
void ensureRunnerTypesRegistered() {
  if (!TypeRegistry.isRegistered<SequentialRunnerState>()) {
    TypeRegistry.registerName<SequentialRunnerState>(
      'eino_adk_sequential_workflow_state',
      fromJson: SequentialRunnerState.fromJson,
      toJson: (state) => state.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<LoopRunnerState>()) {
    TypeRegistry.registerName<LoopRunnerState>(
      'eino_adk_loop_workflow_state',
      fromJson: LoopRunnerState.fromJson,
      toJson: (state) => state.toJson(),
    );
  }
}
