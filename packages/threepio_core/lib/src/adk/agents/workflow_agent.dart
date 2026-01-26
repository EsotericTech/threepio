import 'dart:async';

import '../../schema/message.dart';
import '../../streaming/stream_reader.dart';
import '../../streaming/stream_utils.dart';
import '../../streaming/stream_writer.dart';
import '../core/agent_exception.dart';
import '../core/base_agent.dart';
import '../events/agent_event.dart';

/// Execution mode for workflow agent.
enum WorkflowMode {
  /// Execute steps one after another.
  sequential,

  /// Execute steps in a loop until condition is met.
  loop,

  /// Execute all steps concurrently.
  parallel,
}

/// Configuration for workflow execution.
class WorkflowConfig {
  /// Creates workflow configuration.
  const WorkflowConfig({
    this.mode = WorkflowMode.sequential,
    this.maxLoopIterations = 10,
    this.loopCondition,
    this.parallelLimit,
    this.stopOnFirstError = false,
  });

  /// Execution mode.
  final WorkflowMode mode;

  /// Maximum iterations for loop mode.
  final int maxLoopIterations;

  /// Condition to continue looping (returns true to continue).
  final bool Function(Message result, int iteration)? loopCondition;

  /// Maximum concurrent executions in parallel mode.
  final int? parallelLimit;

  /// Whether to stop on first error in parallel mode.
  final bool stopOnFirstError;
}

/// A step in a workflow.
class WorkflowStep {
  /// Creates a workflow step.
  const WorkflowStep({
    required this.name,
    required this.agent,
    this.inputTransform,
    this.outputTransform,
    this.condition,
  });

  /// Name of this step.
  final String name;

  /// Agent to execute.
  final BaseAgent agent;

  /// Optional function to transform input before passing to agent.
  final List<Message> Function(List<Message> input)? inputTransform;

  /// Optional function to transform output before passing to next step.
  final List<Message> Function(Message output)? outputTransform;

  /// Optional condition to determine if step should run.
  final bool Function(List<Message> currentMessages)? condition;
}

/// Agent that orchestrates multiple steps in a workflow.
///
/// Supports three execution modes:
/// - Sequential: Steps run one after another
/// - Loop: Steps repeat until a condition is met
/// - Parallel: All steps run concurrently
///
/// Example:
/// ```dart
/// final workflow = WorkflowAgent(
///   name: 'research_workflow',
///   description: 'Research and summarize',
///   steps: [
///     WorkflowStep(name: 'research', agent: researchAgent),
///     WorkflowStep(name: 'summarize', agent: summaryAgent),
///   ],
///   config: WorkflowConfig(mode: WorkflowMode.sequential),
/// );
///
/// final result = await workflow.invoke([Message.user('Research AI trends')]);
/// ```
class WorkflowAgent with AgentMixin implements BaseAgent {
  /// Creates a workflow agent.
  WorkflowAgent({
    required this.name,
    required this.description,
    required this.steps,
    this.config = const WorkflowConfig(),
  });

  @override
  final String name;

  @override
  final String description;

  /// Steps in this workflow.
  final List<WorkflowStep> steps;

  /// Workflow configuration.
  final WorkflowConfig config;

  @override
  Future<StreamReader<AgentEvent>> run(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    final ctx = context ?? AgentRunContext();
    final (reader, writer) = pipe<AgentEvent>();

    _runWorkflow(messages, writer, ctx)
        .then((_) => writer.close())
        .catchError((Object error, StackTrace stackTrace) {
      writer.send(AgentErrorEvent(
        error: error.toString(),
        stackTrace: stackTrace.toString(),
        runId: ctx.runId,
      ));
      writer.close();
    });

    return reader;
  }

  @override
  Future<Message> invoke(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    final reader = await run(messages, context: context);
    Message? lastOutput;

    try {
      while (true) {
        final event = await reader.recv();
        if (event is AgentRunEndEvent) {
          return event.outputMessage;
        }
        if (event is AgentOutputEvent && !event.isPartial) {
          lastOutput = event.message;
        }
      }
    } on StreamEOFException {
      // Stream ended
    } finally {
      await reader.close();
    }

    return lastOutput ?? Message.assistant('');
  }

  @override
  BaseAgent copyWith({
    String? name,
    String? description,
  }) {
    return WorkflowAgent(
      name: name ?? this.name,
      description: description ?? this.description,
      steps: steps,
      config: config,
    );
  }

  Future<void> _runWorkflow(
    List<Message> messages,
    StreamWriter<AgentEvent> writer,
    AgentRunContext context,
  ) async {
    final startTime = DateTime.now();

    writer.send(AgentRunStartEvent(
      agentName: name,
      inputMessages: messages,
      runId: context.runId,
      parentRunId: context.parentRunId,
    ));

    Message? finalOutput;

    switch (config.mode) {
      case WorkflowMode.sequential:
        finalOutput = await _runSequential(messages, writer, context);
      case WorkflowMode.loop:
        finalOutput = await _runLoop(messages, writer, context);
      case WorkflowMode.parallel:
        finalOutput = await _runParallel(messages, writer, context);
    }

    writer.send(AgentRunEndEvent(
      agentName: name,
      outputMessage: finalOutput,
      durationMs: DateTime.now().difference(startTime).inMilliseconds,
      runId: context.runId,
    ));
  }

  Future<Message> _runSequential(
    List<Message> messages,
    StreamWriter<AgentEvent> writer,
    AgentRunContext context,
  ) async {
    var currentMessages = List<Message>.from(messages);
    Message? lastOutput;

    for (var i = 0; i < steps.length; i++) {
      checkCancellation(context);

      final step = steps[i];

      // Check condition
      if (step.condition != null && !step.condition!(currentMessages)) {
        continue;
      }

      // Emit state update
      writer.send(AgentStateUpdateEvent(
        stateName: 'current_step',
        newValue: step.name,
        previousValue: i > 0 ? steps[i - 1].name : null,
        runId: context.runId,
      ));

      // Transform input if needed
      final input = step.inputTransform?.call(currentMessages) ?? currentMessages;

      // Create child context
      final childContext = context.child(
        additionalMetadata: {'workflow_step': step.name},
      );

      // Run step
      try {
        final output = await step.agent.invoke(input, context: childContext);
        lastOutput = output;

        // Emit output
        writer.send(AgentOutputEvent(
          message: output,
          isPartial: false,
          runId: context.runId,
        ));

        // Transform and prepare for next step
        if (step.outputTransform != null) {
          currentMessages = step.outputTransform!(output);
        } else {
          currentMessages = [...currentMessages, output];
        }
      } catch (e) {
        throw WorkflowException(
          message: 'Step "${step.name}" failed: $e',
          failedStep: step.name,
          stepIndex: i,
          agentName: name,
          runId: context.runId,
          cause: e,
        );
      }
    }

    return lastOutput ?? Message.assistant('Workflow completed with no output');
  }

  Future<Message> _runLoop(
    List<Message> messages,
    StreamWriter<AgentEvent> writer,
    AgentRunContext context,
  ) async {
    var currentMessages = List<Message>.from(messages);
    Message? lastOutput;
    var iteration = 0;

    while (iteration < config.maxLoopIterations) {
      checkCancellation(context);
      iteration++;

      // Emit iteration state
      writer.send(AgentStateUpdateEvent(
        stateName: 'loop_iteration',
        newValue: iteration,
        previousValue: iteration - 1,
        runId: context.runId,
      ));

      // Run all steps in sequence
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];

        if (step.condition != null && !step.condition!(currentMessages)) {
          continue;
        }

        final input = step.inputTransform?.call(currentMessages) ?? currentMessages;
        final childContext = context.child(
          additionalMetadata: {
            'workflow_step': step.name,
            'loop_iteration': iteration,
          },
        );

        final output = await step.agent.invoke(input, context: childContext);
        lastOutput = output;

        writer.send(AgentOutputEvent(
          message: output,
          isPartial: false,
          runId: context.runId,
        ));

        if (step.outputTransform != null) {
          currentMessages = step.outputTransform!(output);
        } else {
          currentMessages = [...currentMessages, output];
        }
      }

      // Check loop condition
      if (lastOutput != null && config.loopCondition != null) {
        if (!config.loopCondition!(lastOutput, iteration)) {
          break;
        }
      } else if (config.loopCondition == null) {
        // No condition means run once through all steps
        break;
      }
    }

    if (iteration >= config.maxLoopIterations && lastOutput == null) {
      throw MaxIterationsExceededException(
        iterations: iteration,
        maxIterations: config.maxLoopIterations,
        agentName: name,
        runId: context.runId,
      );
    }

    return lastOutput ?? Message.assistant('Loop completed with no output');
  }

  Future<Message> _runParallel(
    List<Message> messages,
    StreamWriter<AgentEvent> writer,
    AgentRunContext context,
  ) async {
    // Filter steps by condition
    final stepsToRun = steps.where((step) {
      return step.condition == null || step.condition!(messages);
    }).toList();

    if (stepsToRun.isEmpty) {
      return Message.assistant('No steps matched conditions');
    }

    // Emit state
    writer.send(AgentStateUpdateEvent(
      stateName: 'parallel_steps',
      newValue: stepsToRun.map((s) => s.name).toList(),
      runId: context.runId,
    ));

    // Create futures for all steps
    final futures = <Future<(String, Message)>>[];
    for (final step in stepsToRun) {
      final input = step.inputTransform?.call(messages) ?? messages;
      final childContext = context.child(
        additionalMetadata: {'workflow_step': step.name},
      );

      futures.add(
        step.agent.invoke(input, context: childContext).then(
              (output) => (step.name, output),
            ),
      );
    }

    // Execute with optional limit
    final results = <(String, Message)>[];

    if (config.parallelLimit != null) {
      // Execute in batches
      for (var i = 0; i < futures.length; i += config.parallelLimit!) {
        final batch = futures.skip(i).take(config.parallelLimit!);

        if (config.stopOnFirstError) {
          results.addAll(await Future.wait(batch));
        } else {
          final batchResults = await Future.wait(
            batch,
            eagerError: false,
          );
          results.addAll(batchResults);
        }
      }
    } else {
      // Execute all at once
      if (config.stopOnFirstError) {
        results.addAll(await Future.wait(futures));
      } else {
        results.addAll(await Future.wait(futures, eagerError: false));
      }
    }

    // Emit results
    for (final (_, output) in results) {
      writer.send(AgentOutputEvent(
        message: output,
        isPartial: false,
        runId: context.runId,
      ));
    }

    // Combine results
    final combinedContent = results
        .map((r) => '## ${r.$1}\n${r.$2.content}')
        .join('\n\n');

    return Message.assistant(combinedContent);
  }
}
