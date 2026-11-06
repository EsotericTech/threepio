// Mirror of doc/MIGRATION.md, legacy: the agents of adk.dart.
// ignore_for_file: avoid_print
import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// Plan, execute, replan (Go `planexecute.New`).
Future<adk.Agent> planExecuteAgent(
  ToolCallingChatModel model,
  List<BaseTool> tools,
) async {
  final ctx = RunContext.background();
  return adk.PlanExecute.create(
    ctx,
    adk.PlanExecuteLoopConfig(
      planner: await adk.PlanExecute.planner(
        ctx,
        adk.PlannerConfig(toolCallingChatModel: model),
      ),
      executor: await adk.PlanExecute.executor(
        ctx,
        adk.ExecutorConfig(
          model: model,
          toolsConfig: adk.ToolsConfig(
            toolsNode: adk.ToolsNodeConfig(tools: tools),
          ),
        ),
      ),
      replanner: await adk.PlanExecute.replanner(
        ctx,
        adk.ReplannerConfig(chatModel: model),
      ),
    ),
  );
}

/// A coordinator that hands work to a researcher, two ways.
Future<List<adk.Agent>> coordinators(
  ToolCallingChatModel model,
  adk.Agent researcher,
) async {
  // A deep agent delegates to its sub-agents (Go `deep.New`).
  final deep = await adk.DeepAgent.create(
    RunContext.background(),
    adk.DeepAgentConfig(
      chatModel: model,
      name: 'coordinator',
      description: 'Plans the work and delegates research',
      subAgents: [researcher],
    ),
  );

  // A chat model agent calls the researcher as a tool (Go `adk.NewAgentTool`).
  final withTool = adk.ChatModelAgent(
    adk.ChatModelAgentConfig(
      name: 'coordinator',
      description: 'Answers with the help of a researcher',
      model: model,
      toolsConfig: adk.ToolsConfig(
        toolsNode: adk.ToolsNodeConfig(tools: [adk.AgentTool(researcher)]),
      ),
    ),
  );
  return [deep, withTool];
}
