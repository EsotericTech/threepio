/// The plan-execute-replan agent: a planner writes a plan, an executor does
/// its first step, a replanner revises the plan or answers, in a loop.
///
/// Port of eino `adk/prebuilt/planexecute` (`plan_execute.go`).
library;

import '../../../components/prompt/chat_template.dart';
import '../../../core/run_context.dart';
import '../../../schema/message.dart';
import '../../../schema/message_template.dart';
import '../../../schema/tool_info.dart';
import '../../eino/agent.dart';
import '../../eino/agent_action.dart';
import '../../eino/runner.dart';
import 'executor.dart';
import 'loop_runner.dart';
import 'plan.dart';
import 'planner.dart';
import 'replanner.dart';
import 'sequential_runner.dart';

/// The plan-execute-replan agent and its three parts.
///
/// Port of eino `planexecute.New`, `NewPlanner`, `NewExecutor` and
/// `NewReplanner`, with eino's tool infos, prompts and session keys:
///
/// ```dart
/// final agent = await PlanExecute.create(ctx, PlanExecuteLoopConfig(
///   planner: await PlanExecute.planner(ctx,
///       PlannerConfig(toolCallingChatModel: model)),
///   executor: await PlanExecute.executor(ctx, ExecutorConfig(
///       model: model,
///       toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)))),
///   replanner: await PlanExecute.replanner(ctx,
///       ReplannerConfig(chatModel: model)),
/// ));
/// final events = Runner(agent: agent).query(ctx, 'Plan a trip to Tokyo');
/// ```
///
/// The planner runs once and stores the plan; then, at most
/// `maxIterations` times, the executor does the plan's first step and the
/// replanner either answers (which ends the run) or stores a revised plan.
/// The parts talk through session values (the four keys below). The events
/// are those of the three agents, named `planner`, `executor` and
/// `replanner`. An interrupt inside the executor (a tool that asks for
/// approval) interrupts the whole agent, and `Runner.resume` continues it at
/// that point. The agent itself is named `plan_execute_replan`.
///
/// A custom replanner ends the loop by sending [breakLoopAction] (the
/// built-in one does so when it answers through the respond tool).
///
/// **Resume after a cancel of the whole run differs from Eino, on purpose.**
/// When a run started with `withCancel` is cancelled while the executor
/// works, `Runner.resume` continues the executor from its own checkpoint, in
/// the same round of the loop. Eino runs the executor again from the start
/// (and restarts the loop's count) at the top level, because its cancel
/// checkpoint drops the information its workflow agents resume from; behind
/// an `AgentTool` it resumes the executor as threepio does. Resuming also
/// keeps an executor's tool calls from being made twice.
///
/// Eino builds this from its workflow agents (`NewSequentialAgent`,
/// `NewLoopAgent`, `NewBreakLoopAction`), which it marks as not recommended;
/// they are not ported as API, only as the private runners of this agent.
/// [breakLoopAction] is the one piece of them that is public, because a
/// custom replanner needs it.
abstract final class PlanExecute {
  /// The session key of the messages the agent was started with
  /// (`List<Message>`). Port of `UserInputSessionKey`.
  static const userInputSessionKey = 'UserInput';

  /// The session key of the current [Plan]. Port of `PlanSessionKey`.
  static const planSessionKey = 'Plan';

  /// The session key of the executor's last answer (`String`). Port of
  /// `ExecutedStepSessionKey`.
  static const executedStepSessionKey = 'ExecutedStep';

  /// The session key of the steps done so far (`List<ExecutedStep>`). Port
  /// of `ExecutedStepsSessionKey`.
  static const executedStepsSessionKey = 'ExecutedSteps';

  /// The tool through which a model writes a plan. Port of `PlanToolInfo`.
  static final ToolInfo planToolInfo = ToolInfo.fromParams(
    name: 'plan',
    desc: _planToolDesc,
    params: const {
      'steps': ParameterInfo(
        type: DataType.array,
        elemInfo: ParameterInfo(type: DataType.string),
        desc: _planToolStepsDesc,
        required: true,
      ),
    },
  );

  /// The tool through which the replanner answers the user. Port of
  /// `RespondToolInfo`.
  static final ToolInfo respondToolInfo = ToolInfo.fromParams(
    name: 'respond',
    desc: _respondToolDesc,
    params: const {
      'response': ParameterInfo(
        type: DataType.string,
        desc: _respondToolResponseDesc,
        required: true,
      ),
    },
  );

  /// The planner's prompt; the variable `input` holds the user's messages.
  /// Port of `PlannerPrompt`.
  static final ChatTemplate plannerPrompt = ChatTemplate.fromMessages(
    FormatType.fString,
    [Message.system(_plannerSystem), const MessagesPlaceholder('input')],
  );

  /// The executor's prompt; variables `input`, `plan`, `executed_steps` and
  /// `step`. Port of `ExecutorPrompt`.
  static final ChatTemplate executorPrompt = ChatTemplate.fromMessages(
    FormatType.fString,
    [Message.system(_executorSystem), Message.user(_executorUser)],
  );

  /// The replanner's prompt; variables `input`, `plan`, `executed_steps`,
  /// `plan_tool` and `respond_tool`. Port of `ReplannerPrompt`.
  static final ChatTemplate replannerPrompt = ChatTemplate.fromMessages(
    FormatType.fString,
    [Message.system(_replannerSystem), Message.user(_replannerUser)],
  );

  /// The planner: writes the plan for the user's messages and stores it
  /// (and the messages) in the session. Port of `planexecute.NewPlanner`.
  ///
  /// Throws [ArgumentError] when [PlannerConfig] has no model.
  static Future<Agent> planner(RunContext ctx, PlannerConfig config) async =>
      newPlannerAgent(config);

  /// The executor: a `ChatModelAgent` that does the plan's first step with
  /// its tools and stores its answer in the session. Port of
  /// `planexecute.NewExecutor`.
  static Future<Agent> executor(RunContext ctx, ExecutorConfig config) async =>
      newExecutorAgent(config);

  /// The replanner: answers the user through the respond tool, which ends
  /// the loop, or stores a revised plan through the plan tool. Port of
  /// `planexecute.NewReplanner`.
  static Future<Agent> replanner(RunContext ctx, ReplannerConfig config) async =>
      newReplannerAgent(config);

  /// The action with which an agent in the loop, usually a custom
  /// replanner, ends the loop of a plan-execute agent.
  ///
  /// Port of eino `adk.NewBreakLoopAction`, which a replanner given to
  /// `planexecute.New` calls to finish. Send it as the last event of the
  /// agent's run, after its answer:
  ///
  /// ```dart
  /// writer.send(AgentEvent(action: PlanExecute.breakLoopAction(name)));
  /// ```
  ///
  /// The loop ends once that agent's run is over; no later agent of the
  /// round runs. The plan-execute agent does not pass the action on (Eino
  /// marks it done and forwards it): the caller sees the agent's answer as
  /// the last event, and an event that carried nothing but the action is
  /// dropped. [agentName] is the name of the agent that ends the loop
  /// (Eino's `BreakLoopAction.From`).
  ///
  /// The action means nothing outside a plan-execute agent.
  static AgentAction breakLoopAction(String agentName) =>
      AgentAction(customizedAction: LoopBreak(agentName));

  /// The plan-execute-replan agent of [config]: the planner once, then the
  /// executor and the replanner in a loop. Port of `planexecute.New`.
  ///
  /// The loop ends when an agent sends [breakLoopAction], or after
  /// [PlanExecuteLoopConfig.maxIterations] rounds.
  static Future<ResumableAgent> create(
    RunContext ctx,
    PlanExecuteLoopConfig config,
  ) async {
    ensurePlanExecuteTypesRegistered();
    final maxIterations = config.maxIterations <= 0 ? 10 : config.maxIterations;
    final loop = LoopRunner(
      name: 'execute_replan',
      subAgents: [config.executor, config.replanner],
      maxIterations: maxIterations,
    );
    return FlowWrappedAgent(
      SequentialRunner(
        name: 'plan_execute_replan',
        subAgents: [config.planner, loop],
      ),
    );
  }
}

/// The parts of a plan-execute-replan agent.
///
/// Port of eino `planexecute.Config`.
final class PlanExecuteLoopConfig {
  /// The configuration of an agent of [planner], [executor] and [replanner].
  const PlanExecuteLoopConfig({
    required this.planner,
    required this.executor,
    required this.replanner,
    this.maxIterations = 10,
  });

  /// The agent that writes the plan; usually [PlanExecute.planner].
  final Agent planner;

  /// The agent that does a step; usually [PlanExecute.executor].
  final Agent executor;

  /// The agent that revises the plan or answers; usually
  /// [PlanExecute.replanner].
  final Agent replanner;

  /// How many execute-replan rounds the agent may run; 10 when 0 or less.
  final int maxIterations;
}

// The prompts and tool descriptions, copied verbatim from eino
// `adk/prebuilt/planexecute/plan_execute.go` by a script.

const _planToolDesc = 'Plan with a list of steps to execute in order. Each step should be clear, actionable, and arranged in a logical sequence. The output will be used to guide the execution process.';

const _planToolStepsDesc = 'different steps to follow, should be in sorted order';

const _respondToolDesc = 'Generate a direct response to the user. Use this tool when you have all the information needed to provide a final answer.';

const _respondToolResponseDesc = 'The complete response to provide to the user';

const _plannerSystem = r'''
You are an expert planning agent. Given an objective, create a comprehensive step-by-step plan to achieve the objective.

## YOUR TASK
Analyze the objective and generate a strategic plan that breaks down the goal into manageable, executable steps.

## PLANNING REQUIREMENTS
Each step in your plan must be:
- **Specific and actionable**: Clear instructions that can be executed without ambiguity
- **Self-contained**: Include all necessary context, parameters, and requirements
- **Independently executable**: Can be performed by an agent without dependencies on other steps
- **Logically sequenced**: Arranged in optimal order for efficient execution
- **Objective-focused**: Directly contribute to achieving the main goal

## PLANNING GUIDELINES
- Eliminate redundant or unnecessary steps
- Include relevant constraints, parameters, and success criteria for each step
- Ensure the final step produces a complete answer or deliverable
- Anticipate potential challenges and include mitigation strategies
- Structure steps to build upon each other logically
- Provide sufficient detail for successful execution

## QUALITY CRITERIA
- Plan completeness: Does it address all aspects of the objective?
- Step clarity: Can each step be understood and executed independently?
- Logical flow: Do steps follow a sensible progression?
- Efficiency: Is this the most direct path to the objective?
- Adaptability: Can the plan handle unexpected results or changes?''';

const _executorSystem = 'You are a diligent and meticulous executor agent. Follow the given plan and execute your tasks carefully and thoroughly.';

const _executorUser = r'''
## OBJECTIVE
{input}
## Given the following plan:
{plan}
## COMPLETED STEPS & RESULTS
{executed_steps}
## Your task is to execute the first step, which is: 
{step}''';

const _replannerSystem = r'''
You are going to review the progress toward an objective. Analyze the current state and determine the optimal next action.

## YOUR TASK
Based on the progress above, you MUST choose exactly ONE action:

### Option 1: COMPLETE (if objective is fully achieved)
Call '{respond_tool}' with:
- A comprehensive final answer
- Clear conclusion summarizing how the objective was met
- Key insights from the execution process

### Option 2: CONTINUE (if more work is needed)
Call '{plan_tool}' with a revised plan that:
- Contains ONLY remaining steps (exclude completed ones)
- Incorporates lessons learned from executed steps
- Addresses any gaps or issues discovered
- Maintains logical step sequence

## PLANNING REQUIREMENTS
Each step in your plan must be:
- **Specific and actionable**: Clear instructions that can be executed without ambiguity
- **Self-contained**: Include all necessary context, parameters, and requirements
- **Independently executable**: Can be performed by an agent without dependencies on other steps
- **Logically sequenced**: Arranged in optimal order for efficient execution
- **Objective-focused**: Directly contribute to achieving the main goal

## PLANNING GUIDELINES
- Eliminate redundant or unnecessary steps
- Adapt strategy based on new information
- Include relevant constraints, parameters, and success criteria for each step

## DECISION CRITERIA
- Has the original objective been completely satisfied?
- Are there any remaining requirements or sub-goals?
- Do the results suggest a need for strategy adjustment?
- What specific actions are still required?''';

const _replannerUser = r'''
## OBJECTIVE
{input}

## ORIGINAL PLAN
{plan}

## COMPLETED STEPS & RESULTS
{executed_steps}''';
