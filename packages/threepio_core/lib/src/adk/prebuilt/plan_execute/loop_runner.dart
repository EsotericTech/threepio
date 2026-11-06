/// Runs agents in a loop until one breaks it: the execute-replan half of the
/// plan-execute agent.
///
/// Port of the loop mode of eino's `workflowAgent` (`adk/workflow.go`:
/// `runLoop`, `loopWorkflowState`, `BreakLoopAction`). Eino's public
/// `NewLoopAgent` and `NewBreakLoopAction` are marked as not recommended and
/// are not ported; this runner and [LoopBreak] are internal to the
/// plan-execute port and **not exported** from `adk.dart` or any other
/// library.
@internal
library;

import 'package:meta/meta.dart';

import '../../../components/component_type.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../streaming/stream_reader.dart';
import '../../eino/agent.dart';
import '../../eino/agent_event.dart';
import '../../eino/cancel.dart';
import '../../eino/interrupt.dart';
import '../../eino/run_options.dart';
import '../../eino/runner.dart';
import 'sequential_runner.dart';

/// The request of a sub-agent to end the loop it runs in.
///
/// Port of eino `BreakLoopAction` (`NewBreakLoopAction(agentName)`): the
/// replanner sends it in `AgentAction.customizedAction` when it answers. The
/// [LoopRunner] that receives it ends after the sub-agent and **does not
/// pass the action on** (eino marks it `Done` and forwards it); an event
/// that carried only the action is dropped, one with output keeps its output.
@internal
@immutable
final class LoopBreak {
  /// A break asked for by the agent [from].
  const LoopBreak(this.from);

  /// The name of the agent that asked for the break.
  final String from;

  @override
  bool operator ==(Object other) => other is LoopBreak && other.from == from;

  @override
  int get hashCode => from.hashCode;

  @override
  String toString() => 'LoopBreak(from: $from)';
}

/// Runs [subAgents] in order, again and again, at most [maxIterations]
/// times, until one of them sends a [LoopBreak]; stops at the first error
/// event and turns a sub-agent's interrupt into its own.
///
/// Port of eino's loop `workflowAgent`, without agent transfer (no `Exit`
/// action, no run path). Unlike eino, [maxIterations] must be positive (eino
/// loops without end for 0; the plan-execute agent never passes 0).
@internal
final class LoopRunner implements WorkflowRunnerAgent, TypedComponent {
  /// A runner of [subAgents] called [name]. Throws [ArgumentError] for
  /// [maxIterations] below 1.
  LoopRunner({
    required this.name,
    required List<Agent> subAgents,
    required this.maxIterations,
    this.description = '',
  }) : subAgents = List.unmodifiable(subAgents) {
    if (maxIterations < 1) {
      throw ArgumentError.value(maxIterations, 'maxIterations', 'must be positive');
    }
    ensureRunnerTypesRegistered();
  }

  @override
  final String name;

  @override
  final String description;

  /// The agents, in the order they run in each iteration.
  final List<Agent> subAgents;

  /// How many iterations the loop may run.
  final int maxIterations;

  /// Port of `workflowAgent.GetType` for the loop mode.
  @override
  String get componentTypeName => 'Loop';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      runnerEvents((writer) => _runLoop(ctx, writer, input, null, null, options));

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
        if (state is! LoopRunnerState) {
          throw ThreepioException(
            'unsupported workflow agent state type: ${state.runtimeType}',
          );
        }
        await _runLoop(ctx, writer, rootInputOf(ctx), state, info, options);
      });

  Future<void> _runLoop(
    RunContext ctx,
    StreamWriter<AgentEvent> writer,
    AgentInput input,
    LoopRunnerState? resumed,
    ResumeInfo? info,
    List<AgentRunOption> options,
  ) async {
    if (subAgents.isEmpty) return;
    var state = resumed;
    var startIndex = state?.subAgentIndex ?? 0;
    for (var i = state?.loopIterations ?? 0; i < maxIterations; i++) {
      for (var j = startIndex; j < subAgents.length; j++) {
        final subAgent = subAgents[j];
        final cancelContext = cancelContextOf(ctx);
        if (cancelContext != null && cancelContext.shouldCancel) {
          writer.send(
            cancelAtTransition(
              ctx,
              'Loop workflow cancel at transition',
              LoopRunnerState(loopIterations: i, subAgentIndex: j),
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
        var breakLoop = false;
        try {
          for (var event = await events.nextOrNull();
              event != null;
              event = await events.nextOrNull()) {
            if (event.error != null) {
              writer.send(event);
              return;
            }
            if (lastAction != null) {
              breakLoop = _forward(writer, lastAction) || breakLoop;
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
                'Loop workflow interrupted',
                LoopRunnerState(
                  loopIterations: i,
                  subAgentIndex: j,
                  subAgentInterrupted: true,
                ),
                [signal],
              ).copyWith(agentName: lastAction.agentName),
            );
            return;
          }
          breakLoop = _forward(writer, lastAction) || breakLoop;
        }
        if (breakLoop) return;
      }
      startIndex = 0;
    }
  }

  /// Sends the action event [event], without a [LoopBreak]; returns whether
  /// it carried one.
  static bool _forward(StreamWriter<AgentEvent> writer, AgentEvent event) {
    if (event.action?.customizedAction is! LoopBreak) {
      writer.send(event);
      return false;
    }
    final output = event.output;
    if (output != null) {
      writer.send(AgentEvent(agentName: event.agentName, output: output));
    }
    return true;
  }

  @override
  String toString() => 'LoopRunner($name, max $maxIterations)';
}

/// Where a [LoopRunner] stopped. Port of eino `loopWorkflowState` plus
/// whether the sub-agent at [subAgentIndex] interrupted (see
/// `SequentialRunnerState.subAgentInterrupted`).
@internal
@immutable
final class LoopRunnerState {
  /// The state of a runner that stopped in iteration [loopIterations],
  /// before or inside sub-agent [subAgentIndex].
  const LoopRunnerState({
    required this.loopIterations,
    required this.subAgentIndex,
    this.subAgentInterrupted = false,
  });

  /// A state from its JSON form.
  factory LoopRunnerState.fromJson(Map<String, Object?> json) => LoopRunnerState(
        loopIterations: (json['loop_iterations']! as num).toInt(),
        subAgentIndex: (json['sub_agent_index']! as num).toInt(),
        subAgentInterrupted: json['sub_agent_interrupted'] == true,
      );

  /// The iteration to continue in (0-based).
  final int loopIterations;

  /// The sub-agent to continue with.
  final int subAgentIndex;

  /// Whether that sub-agent interrupted and is to be resumed.
  final bool subAgentInterrupted;

  /// The JSON form, as checkpoints keep it.
  Map<String, Object?> toJson() => {
        'loop_iterations': loopIterations,
        'sub_agent_index': subAgentIndex,
        'sub_agent_interrupted': subAgentInterrupted,
      };

  @override
  bool operator ==(Object other) =>
      other is LoopRunnerState &&
      other.loopIterations == loopIterations &&
      other.subAgentIndex == subAgentIndex &&
      other.subAgentInterrupted == subAgentInterrupted;

  @override
  int get hashCode =>
      Object.hash(loopIterations, subAgentIndex, subAgentInterrupted);

  @override
  String toString() => 'LoopRunnerState($loopIterations, $subAgentIndex, '
      'interrupted: $subAgentInterrupted)';
}
