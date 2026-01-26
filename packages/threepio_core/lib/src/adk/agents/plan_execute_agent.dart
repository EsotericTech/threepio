import 'dart:async';
import 'dart:convert';

import '../../components/model/base_chat_model.dart';
import '../../schema/message.dart';
import '../../streaming/stream_reader.dart';
import '../../streaming/stream_utils.dart';
import '../../streaming/stream_writer.dart';
import '../core/agent_exception.dart';
import '../core/base_agent.dart';
import '../events/agent_action.dart';
import '../events/agent_event.dart';

/// Configuration for plan-execute agent.
class PlanExecuteConfig {
  /// Creates configuration.
  const PlanExecuteConfig({
    this.maxReplanAttempts = 3,
    this.replanOnError = true,
    this.replanOnFeedback = true,
    this.maxStepsPerPlan = 10,
  });

  /// Maximum number of replanning attempts.
  final int maxReplanAttempts;

  /// Whether to replan when a step fails.
  final bool replanOnError;

  /// Whether to allow replanning based on execution feedback.
  final bool replanOnFeedback;

  /// Maximum steps in a single plan.
  final int maxStepsPerPlan;
}

/// A step in an execution plan.
class PlanStep {
  /// Creates a plan step.
  const PlanStep({
    required this.description,
    required this.agentName,
    this.inputs = const [],
    this.expectedOutput,
    this.dependencies = const [],
  });

  /// Description of what this step does.
  final String description;

  /// Name of the agent to execute this step.
  final String agentName;

  /// Required inputs for this step.
  final List<String> inputs;

  /// Expected output description.
  final String? expectedOutput;

  /// Names of steps this depends on.
  final List<String> dependencies;

  /// Create from JSON.
  factory PlanStep.fromJson(Map<String, dynamic> json) {
    return PlanStep(
      description: json['description'] as String,
      agentName: json['agent'] as String? ?? 'default',
      inputs: (json['inputs'] as List<dynamic>?)?.cast<String>() ?? [],
      expectedOutput: json['expected_output'] as String?,
      dependencies: (json['dependencies'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
        'description': description,
        'agent': agentName,
        'inputs': inputs,
        if (expectedOutput != null) 'expected_output': expectedOutput,
        if (dependencies.isNotEmpty) 'dependencies': dependencies,
      };
}

/// An execution plan containing multiple steps.
class ExecutionPlan {
  /// Creates an execution plan.
  const ExecutionPlan({
    required this.goal,
    required this.steps,
    this.reasoning,
  });

  /// The goal this plan achieves.
  final String goal;

  /// Steps to execute.
  final List<PlanStep> steps;

  /// Optional reasoning for the plan.
  final String? reasoning;

  /// Create from JSON.
  factory ExecutionPlan.fromJson(Map<String, dynamic> json) {
    return ExecutionPlan(
      goal: json['goal'] as String,
      steps: (json['steps'] as List<dynamic>)
          .map((s) => PlanStep.fromJson(s as Map<String, dynamic>))
          .toList(),
      reasoning: json['reasoning'] as String?,
    );
  }

  /// Convert to JSON.
  Map<String, dynamic> toJson() => {
        'goal': goal,
        'steps': steps.map((s) => s.toJson()).toList(),
        if (reasoning != null) 'reasoning': reasoning,
      };
}

/// Agent that plans before executing.
///
/// Implements a two-phase approach:
/// 1. Planning: Uses an LLM to create an execution plan
/// 2. Execution: Executes each step, optionally replanning
///
/// Example:
/// ```dart
/// final agent = PlanExecuteAgent(
///   name: 'planner',
///   description: 'Plans and executes complex tasks',
///   plannerModel: gpt4,
///   executors: {
///     'research': researchAgent,
///     'summarize': summaryAgent,
///   },
/// );
///
/// final result = await agent.invoke([
///   Message.user('Research and summarize recent AI papers'),
/// ]);
/// ```
class PlanExecuteAgent with AgentMixin implements BaseAgent {
  /// Creates a plan-execute agent.
  PlanExecuteAgent({
    required this.name,
    required this.description,
    required BaseChatModel plannerModel,
    required Map<String, BaseAgent> executors,
    BaseAgent? defaultExecutor,
    this.plannerSystemPrompt,
    this.config = const PlanExecuteConfig(),
  })  : _plannerModel = plannerModel,
        _executors = executors,
        _defaultExecutor = defaultExecutor;

  @override
  final String name;

  @override
  final String description;

  final BaseChatModel _plannerModel;
  final Map<String, BaseAgent> _executors;
  final BaseAgent? _defaultExecutor;

  /// System prompt for the planner.
  final String? plannerSystemPrompt;

  /// Agent configuration.
  final PlanExecuteConfig config;

  @override
  Future<StreamReader<AgentEvent>> run(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    final ctx = context ?? AgentRunContext();
    final (reader, writer) = pipe<AgentEvent>();

    _runPlanExecute(messages, writer, ctx)
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
    return PlanExecuteAgent(
      name: name ?? this.name,
      description: description ?? this.description,
      plannerModel: _plannerModel,
      executors: _executors,
      defaultExecutor: _defaultExecutor,
      plannerSystemPrompt: plannerSystemPrompt,
      config: config,
    );
  }

  Future<void> _runPlanExecute(
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

    var replanAttempts = 0;
    ExecutionPlan? currentPlan;
    final results = <String, Message>{};
    String? lastError;

    while (replanAttempts <= config.maxReplanAttempts) {
      checkCancellation(context);

      // Plan phase
      writer.send(AgentStateUpdateEvent(
        stateName: 'phase',
        newValue: 'planning',
        runId: context.runId,
      ));

      currentPlan = await _createPlan(
        messages,
        results,
        lastError,
        replanAttempts > 0,
        context,
      );

      writer.send(AgentActionEvent(
        action: ThinkAction(
          thought: 'Created plan with ${currentPlan.steps.length} steps: '
              '${currentPlan.reasoning ?? currentPlan.goal}',
        ),
        runId: context.runId,
      ));

      // Execute phase
      writer.send(AgentStateUpdateEvent(
        stateName: 'phase',
        newValue: 'executing',
        runId: context.runId,
      ));

      try {
        final finalResult = await _executePlan(
          currentPlan,
          messages,
          results,
          writer,
          context,
        );

        // Success - emit final output
        writer.send(AgentRunEndEvent(
          agentName: name,
          outputMessage: finalResult,
          durationMs: DateTime.now().difference(startTime).inMilliseconds,
          runId: context.runId,
        ));

        return;
      } catch (e) {
        lastError = e.toString();
        if (config.replanOnError && replanAttempts < config.maxReplanAttempts) {
          replanAttempts++;
          writer.send(AgentErrorEvent(
            error: 'Step failed, replanning (attempt $replanAttempts): $e',
            isRecoverable: true,
            runId: context.runId,
          ));
          continue;
        }
        rethrow;
      }
    }

    throw PlanningException(
      message: 'Failed after $replanAttempts replanning attempts',
      agentName: name,
      runId: context.runId,
    );
  }

  Future<ExecutionPlan> _createPlan(
    List<Message> messages,
    Map<String, Message> previousResults,
    String? lastError,
    bool isReplan,
    AgentRunContext context,
  ) async {
    final plannerMessages = <Message>[];

    // System prompt
    final systemPrompt = plannerSystemPrompt ?? _defaultPlannerPrompt();
    plannerMessages.add(Message.system(systemPrompt));

    // Add user messages
    plannerMessages.addAll(messages);

    // Add context for replanning
    if (isReplan) {
      final contextMessage = StringBuffer('Previous execution context:\n');
      if (previousResults.isNotEmpty) {
        contextMessage.writeln('Completed steps:');
        for (final entry in previousResults.entries) {
          contextMessage.writeln('- ${entry.key}: ${entry.value.content}');
        }
      }
      if (lastError != null) {
        contextMessage.writeln('\nLast error: $lastError');
      }
      contextMessage.writeln('\nPlease create a new plan addressing the error.');
      plannerMessages.add(Message.user(contextMessage.toString()));
    }

    // Generate plan
    final response = await _plannerModel.generate(plannerMessages);

    // Parse plan from response
    return _parsePlan(response.content);
  }

  ExecutionPlan _parsePlan(String content) {
    // Try to parse JSON from the response
    final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(content);
    if (jsonMatch != null) {
      try {
        final json = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
        return ExecutionPlan.fromJson(json);
      } catch (_) {
        // Fall through to text parsing
      }
    }

    // Parse as structured text
    final lines = content.split('\n');
    final steps = <PlanStep>[];
    String? goal;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('Goal:')) {
        goal = trimmed.substring(5).trim();
      } else if (RegExp(r'^\d+\.').hasMatch(trimmed)) {
        // Numbered step
        final stepText = trimmed.replaceFirst(RegExp(r'^\d+\.\s*'), '');
        steps.add(PlanStep(
          description: stepText,
          agentName: 'default',
        ));
      }
    }

    if (steps.isEmpty) {
      // Single step plan from the entire content
      steps.add(PlanStep(
        description: content,
        agentName: 'default',
      ));
    }

    return ExecutionPlan(
      goal: goal ?? 'Execute requested task',
      steps: steps,
    );
  }

  Future<Message> _executePlan(
    ExecutionPlan plan,
    List<Message> originalMessages,
    Map<String, Message> results,
    StreamWriter<AgentEvent> writer,
    AgentRunContext context,
  ) async {
    Message? lastResult;

    for (var i = 0; i < plan.steps.length; i++) {
      checkCancellation(context);

      final step = plan.steps[i];
      final stepName = 'step_${i + 1}';

      // Skip if already completed (for replanning)
      if (results.containsKey(stepName)) {
        continue;
      }

      writer.send(AgentStateUpdateEvent(
        stateName: 'current_step',
        newValue: stepName,
        runId: context.runId,
      ));

      // Find executor
      final executor = _executors[step.agentName] ?? _defaultExecutor;
      if (executor == null) {
        throw PlanningException(
          message: 'No executor found for agent: ${step.agentName}',
          agentName: name,
          runId: context.runId,
        );
      }

      // Build input messages
      final input = <Message>[...originalMessages];

      // Add step instruction
      input.add(Message.user(
        'Execute step ${i + 1}: ${step.description}\n'
        'Inputs: ${step.inputs.join(", ")}\n'
        'Expected output: ${step.expectedOutput ?? "Complete the step successfully"}',
      ));

      // Add relevant previous results
      for (final dep in step.dependencies) {
        if (results.containsKey(dep)) {
          input.add(Message.assistant('Result from $dep: ${results[dep]!.content}'));
        }
      }

      // Execute step
      final childContext = context.child(
        additionalMetadata: {'plan_step': stepName},
      );

      final result = await executor.invoke(input, context: childContext);
      results[stepName] = result;
      lastResult = result;

      writer.send(AgentOutputEvent(
        message: result,
        isPartial: false,
        runId: context.runId,
      ));
    }

    return lastResult ?? Message.assistant('Plan completed with no output');
  }

  String _defaultPlannerPrompt() {
    final executorNames = _executors.keys.join(', ');
    return '''You are a planning agent. Your job is to create execution plans for complex tasks.

Available executors: $executorNames${_defaultExecutor != null ? ', default' : ''}

Create a plan as JSON with this structure:
{
  "goal": "The main goal to achieve",
  "reasoning": "Why this plan will work",
  "steps": [
    {
      "description": "What this step does",
      "agent": "executor_name",
      "inputs": ["required", "inputs"],
      "expected_output": "What success looks like",
      "dependencies": ["step_1"]  // if depends on previous steps
    }
  ]
}

Keep plans focused with no more than ${config.maxStepsPerPlan} steps.''';
  }
}
