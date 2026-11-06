/// The executor of the plan-execute agent.
///
/// Port of `ExecutorConfig`, `NewExecutor`, `defaultGenExecutorInputFn`,
/// `formatInput` and `formatExecutedSteps` of eino
/// `adk/prebuilt/planexecute/plan_execute.go`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../components/model/base_chat_model.dart';
import '../../../components/prompt/chat_template.dart';
import '../../../core/run_context.dart';
import '../../../schema/message.dart';
import '../../eino/agent_context.dart';
import '../../eino/chat_model_agent.dart';
import '../../eino/chat_model_agent_config.dart';
import '../../eino/middleware.dart';
import '../../eino/middleware_context.dart';
import '../../eino/react_graph.dart';
import 'plan.dart';
import 'plan_execute.dart';

/// Builds the model input of the executor (or of the replanner) from the
/// state of the plan. Port of eino `planexecute.GenModelInputFn`.
typedef ExecutionModelInput = FutureOr<List<Message>> Function(
  RunContext ctx,
  ExecutionContext input,
);

/// The configuration of the executor.
///
/// Port of eino `planexecute.ExecutorConfig`.
final class ExecutorConfig {
  /// The configuration of an executor with [model].
  const ExecutorConfig({
    required this.model,
    this.toolsConfig = const ToolsConfig(),
    this.maxIterations = 20,
    this.genInput,
  });

  /// The model. With tools it is told about them as a `ChatModelAgent`'s
  /// model is.
  final BaseChatModel model;

  /// The tools the executor can call.
  final ToolsConfig toolsConfig;

  /// How many model calls one step may take; 20 when 0 or less.
  final int maxIterations;

  /// Builds the model input; the default formats
  /// [PlanExecute.executorPrompt].
  final ExecutionModelInput? genInput;
}

/// The executor agent of [config]: a `ChatModelAgent` named `executor`. Port
/// of `planexecute.NewExecutor`.
///
/// Eino gives it `OutputKey: ExecutedStepSessionKey`; `OutputKey` is not
/// ported (agent transfer), so a private middleware writes the final answer
/// to that session key when the agent ends.
@internal
ChatModelAgent newExecutorAgent(ExecutorConfig config) {
  ensurePlanExecuteTypesRegistered();
  final genInput = config.genInput ?? defaultGenExecutorInput;
  return ChatModelAgent(
    ChatModelAgentConfig(
      name: 'executor',
      description: 'an executor agent',
      model: config.model,
      toolsConfig: config.toolsConfig,
      maxIterations: config.maxIterations,
      genModelInput: (ctx, instruction, input) async =>
          genInput(ctx, executionContextOf(ctx)),
      handlers: const [ExecutedStepOutputMiddleware()],
    ),
  );
}

/// The [ExecutionContext] of the session of [ctx]: the user's messages, the
/// plan and the steps done. Port of the session reads of `NewExecutor`'s
/// `genInput`; a missing plan or input is eino's `impossible` panic.
@internal
ExecutionContext executionContextOf(RunContext ctx) {
  if (!ctx.hasSessionValue(PlanExecute.planSessionKey)) {
    throw StateError('impossible: plan not found');
  }
  final plan = ctx.sessionValue(PlanExecute.planSessionKey)! as Plan;
  if (!ctx.hasSessionValue(PlanExecute.userInputSessionKey)) {
    throw StateError('impossible: user input not found');
  }
  return ExecutionContext(
    userInput: userInputOf(ctx),
    plan: plan,
    executedSteps: executedStepsOf(ctx),
  );
}

/// The session value of the user's messages.
@internal
List<Message> userInputOf(RunContext ctx) =>
    (ctx.sessionValue(PlanExecute.userInputSessionKey)! as List).cast<Message>();

/// The session value of the steps done so far; empty when there is none.
@internal
List<ExecutedStep> executedStepsOf(RunContext ctx) {
  final steps = ctx.sessionValue(PlanExecute.executedStepsSessionKey);
  return steps == null ? const [] : (steps as List).cast<ExecutedStep>();
}

/// The default executor input: [PlanExecute.executorPrompt] with the user's
/// messages, the plan as JSON, the steps done and the plan's first step.
/// Port of `defaultGenExecutorInputFn`.
@visibleForTesting
Future<List<Message>> defaultGenExecutorInput(
  RunContext ctx,
  ExecutionContext input,
) =>
    PlanExecute.executorPrompt.format(
      {
        'input': formatInput(input.userInput),
        'plan': jsonEncode(input.plan.toJson()),
        'executed_steps': formatExecutedSteps(input.executedSteps),
        'step': input.plan.firstStep(),
      },
      options: ChatTemplateOptions(runContext: ctx),
    );

/// The contents of [input], each followed by a newline. Port of eino
/// `formatInput`.
@internal
String formatInput(List<Message> input) => input.map((m) => '${m.content}\n').join();

/// `Step: …\nResult: …\n\n` for each step. Port of eino
/// `formatExecutedSteps`.
@internal
String formatExecutedSteps(List<ExecutedStep> steps) =>
    steps.map((s) => 'Step: ${s.step}\nResult: ${s.result}\n\n').join();

/// Writes the executor's final answer to the session value
/// [PlanExecute.executedStepSessionKey] when the agent ends: the text of the
/// last assistant message, or of the result of a `returnDirectly` tool.
///
/// The replacement of eino's `OutputKey: ExecutedStepSessionKey`
/// (`setOutputToSession` writes the content of the agent's output message).
@internal
final class ExecutedStepOutputMiddleware extends ChatModelAgentMiddleware {
  /// The middleware.
  const ExecutedStepOutputMiddleware();

  @override
  Future<RunContext> afterAgent(RunContext ctx, ChatModelAgentState state) async {
    final returnDirectlyId = await returnDirectlyToolCallIdOf(ctx);
    Message? output;
    if (returnDirectlyId.isNotEmpty) {
      for (final message in state.messages.reversed) {
        if (message.role == RoleType.tool && message.toolCallId == returnDirectlyId) {
          output = message;
          break;
        }
      }
    }
    output ??= state.messages.isEmpty ? null : state.messages.last;
    ctx.addSessionValue(PlanExecute.executedStepSessionKey, output?.content ?? '');
    return ctx;
  }
}
