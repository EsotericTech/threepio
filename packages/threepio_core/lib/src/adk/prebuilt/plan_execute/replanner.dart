/// The replanner of the plan-execute agent.
///
/// Port of `ReplannerConfig`, `NewReplanner`, `replanner` and
/// `buildGenReplannerInputFn` of eino
/// `adk/prebuilt/planexecute/plan_execute.go`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../components/model/base_chat_model.dart';
import '../../../components/model/chat_model_options.dart';
import '../../../components/prompt/chat_template.dart';
import '../../../compose/call_options.dart';
import '../../../compose/chain.dart';
import '../../../compose/graph_options.dart';
import '../../../compose/lambda.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/message_concat.dart';
import '../../../schema/tool_info.dart';
import '../../../streaming/stream_reader.dart';
import '../../eino/agent.dart';
import '../../eino/agent_action.dart';
import '../../eino/agent_context.dart';
import '../../eino/agent_event.dart';
import '../../eino/run_options.dart';
import 'executor.dart';
import 'loop_runner.dart';
import 'plan.dart';
import 'plan_execute.dart';
import 'planner.dart';

/// The configuration of the replanner.
///
/// Port of eino `planexecute.ReplannerConfig`.
final class ReplannerConfig {
  /// The configuration of a replanner with [chatModel].
  const ReplannerConfig({
    required this.chatModel,
    this.planTool,
    this.respondTool,
    this.genInput,
    this.planDecoder,
  });

  /// The model; it is given the plan and respond tools and asked to call
  /// one of them.
  final ToolCallingChatModel chatModel;

  /// The plan tool; [PlanExecute.planToolInfo] when `null`.
  final ToolInfo? planTool;

  /// The respond tool; [PlanExecute.respondToolInfo] when `null`.
  final ToolInfo? respondTool;

  /// Builds the model input; the default formats
  /// [PlanExecute.replannerPrompt] with the two tools' names.
  final ExecutionModelInput? genInput;

  /// Builds a revised plan from the plan tool's arguments; the default is
  /// `{"steps": [...]}`.
  final PlanDecoder? planDecoder;
}

/// The replanner agent of [config]. Port of `planexecute.NewReplanner`.
@internal
ReplannerAgent newReplannerAgent(ReplannerConfig config) {
  ensurePlanExecuteTypesRegistered();
  final planTool = config.planTool ?? PlanExecute.planToolInfo;
  final respondTool = config.respondTool ?? PlanExecute.respondToolInfo;
  return ReplannerAgent(
    chatModel: config.chatModel.withTools([planTool, respondTool]),
    planTool: planTool,
    respondTool: respondTool,
    genInput: config.genInput,
    planDecoder: config.planDecoder ?? DefaultPlan.decode,
  );
}

/// The default replanner input of the tools [planToolName] and
/// [respondToolName]: [PlanExecute.replannerPrompt] with the user's
/// messages, the plan as JSON and the steps done. Port of
/// `buildGenReplannerInputFn`.
@visibleForTesting
ExecutionModelInput defaultGenReplannerInput(
  String planToolName,
  String respondToolName,
) =>
    (ctx, input) => PlanExecute.replannerPrompt.format(
          {
            'plan': jsonEncode(input.plan.toJson()),
            'input': formatInput(input.userInput),
            'executed_steps': formatExecutedSteps(input.executedSteps),
            'plan_tool': planToolName,
            'respond_tool': respondToolName,
          },
          options: ChatTemplateOptions(runContext: ctx),
        );

/// The input of the replanner's chain (Go: `struct{}`).
final class _NoInput {
  const _NoInput();
}

/// The replanner. Port of eino's unexported `replanner`.
@internal
final class ReplannerAgent implements Agent {
  /// A replanner that asks [chatModel] (with both tools bound).
  ReplannerAgent({
    required this.chatModel,
    required this.planTool,
    required this.respondTool,
    required this.planDecoder,
    this.genInput,
  });

  /// The model, with the plan and respond tools bound.
  final BaseChatModel chatModel;

  /// The plan tool.
  final ToolInfo planTool;

  /// The respond tool.
  final ToolInfo respondTool;

  /// Builds the model input; `null` for the default.
  final ExecutionModelInput? genInput;

  /// Builds a revised plan.
  final PlanDecoder planDecoder;

  @override
  String get name => 'replanner';

  @override
  String get description => 'a replanner agent';

  /// Records the step the executor just did and builds the model input.
  /// Port of `replanner.genInput`; missing session values are eino's
  /// `impossible` panics.
  @visibleForTesting
  Future<List<Message>> genModelInput(RunContext ctx) async {
    if (!ctx.hasSessionValue(PlanExecute.executedStepSessionKey)) {
      throw StateError('impossible: execute result not found');
    }
    final executedStep =
        ctx.sessionValue(PlanExecute.executedStepSessionKey)! as String;
    if (!ctx.hasSessionValue(PlanExecute.planSessionKey)) {
      throw StateError('impossible: plan not found');
    }
    final plan = ctx.sessionValue(PlanExecute.planSessionKey)! as Plan;
    final executedSteps = [
      ...executedStepsOf(ctx),
      ExecutedStep(step: plan.firstStep(), result: executedStep),
    ];
    ctx.addSessionValue(PlanExecute.executedStepsSessionKey, executedSteps);
    if (!ctx.hasSessionValue(PlanExecute.userInputSessionKey)) {
      throw StateError('impossible: user input not found');
    }
    final input = ExecutionContext(
      userInput: userInputOf(ctx),
      plan: plan,
      executedSteps: executedSteps,
    );
    final build =
        genInput ?? defaultGenReplannerInput(planTool.name, respondTool.name);
    return build(ctx, input);
  }

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(_run(ctx, input, writer));
    return reader;
  }

  Future<void> _run(
    RunContext ctx,
    AgentInput input,
    StreamWriter<AgentEvent> writer,
  ) async {
    try {
      final chain = Chain<_NoInput, Object?>()
        ..appendLambda(
          Lambda.invokable((RunContext ctx, _NoInput _) => genModelInput(ctx)),
        )
        ..appendChatModel(chatModel)
        ..appendLambda(
          Lambda.collectable((RunContext ctx, StreamReader<Message> stream) async {
            if (input.enableStreaming) {
              final copies = stream.copy(2);
              writer.send(
                AgentEvent.fromMessage(
                  null,
                  stream: copies[0].convert(argToContent),
                  role: RoleType.assistant,
                ),
              );
              return concatMessageStream(copies[1]);
            }
            final message = await concatMessageStream(stream);
            final calls = message.toolCalls ?? const [];
            if (calls.isNotEmpty) {
              writer.send(
                AgentEvent.fromMessage(
                  Message.assistant(calls.first.function.arguments),
                  role: RoleType.assistant,
                ),
              );
            }
            return message;
          }),
        )
        ..appendLambda(
          Lambda.invokable((RunContext ctx, Message message) async {
            final calls = message.toolCalls ?? const [];
            if (calls.isEmpty) throw const ThreepioException('no tool call');
            final call = calls.first.function;
            // Answer: the loop ends.
            if (call.name == respondTool.name) {
              writer.send(
                AgentEvent(action: AgentAction(customizedAction: LoopBreak(name))),
              );
              return message;
            }
            // Replan.
            if (call.name != planTool.name) {
              throw ThreepioException('unexpected tool call: ${call.name}');
            }
            final plan = await decodePlan(ctx, planDecoder, call.arguments);
            ctx.addSessionValue(PlanExecute.planSessionKey, plan);
            return plan;
          }),
        );
      final runnable = await chain.compile(
        ctx,
        options: GraphCompileOptions(graphName: name),
      );
      final output = await runnable.stream(
        ctx,
        const _NoInput(),
        options: [
          CallOption.chatModel(
            const ChatModelOptions(toolChoice: ToolChoice.forced),
          ),
        ],
      );
      await drainStream(output);
      // The chain's failure is the agent's error event.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      writer.send(AgentEvent(error: error, stackTrace: stackTrace));
    } finally {
      await writer.close();
    }
  }

  @override
  String toString() => 'ReplannerAgent(${planTool.name}, ${respondTool.name})';
}
