/// Advanced Agent Development Kit for Threepio.
///
/// Provides enhanced agent patterns with event streaming, multi-agent
/// coordination, and workflow orchestration.
///
/// ## Key Components
///
/// ### Agents
/// - [ChatModelAgent]: Enhanced ReAct agent with event streaming
/// - [WorkflowAgent]: Sequential, loop, or parallel step execution
/// - [PlanExecuteAgent]: Planning phase followed by execution
/// - [SupervisorAgent]: Multi-agent coordination and delegation
///
/// ### Events
/// - [AgentEvent]: Base class for all agent events
/// - [AgentOutputEvent]: Agent produces output
/// - [AgentActionEvent]: Agent takes an action
/// - [ToolResultEvent]: Tool execution completes
/// - [AgentTransferEvent]: Control transfers between agents
///
/// ### Actions
/// - [AgentAction]: Base class for all actions
/// - [ToolCallAction]: Call a tool
/// - [TransferToAgentAction]: Transfer to another agent
/// - [FinishAction]: Complete execution
///
/// ### Tools
/// - [AgentTool]: Wrap an agent as a tool for composition
///
/// ## Example Usage
///
/// ```dart
/// // Create a chat model agent with event streaming
/// final agent = ChatModelAgent(
///   name: 'assistant',
///   description: 'A helpful assistant',
///   model: chatModel,
///   toolRegistry: registry,
/// );
///
/// // Stream events
/// final stream = await agent.run([Message.user('Hello!')]);
/// await for (final event in stream.asStream()) {
///   switch (event) {
///     case AgentOutputEvent(:final message):
///       print('Output: ${message.content}');
///     case AgentActionEvent(:final action):
///       print('Action: ${action.description}');
///     case ToolResultEvent(:final result):
///       print('Tool result: $result');
///   }
/// }
///
/// // Or use simple invocation
/// final result = await agent.invoke([Message.user('Hello!')]);
/// print(result.content);
/// ```
///
/// ```dart
/// // Create a workflow with multiple steps
/// final workflow = WorkflowAgent(
///   name: 'pipeline',
///   description: 'Research and summarize pipeline',
///   steps: [
///     WorkflowStep(name: 'research', agent: researchAgent),
///     WorkflowStep(name: 'summarize', agent: summaryAgent),
///   ],
///   config: WorkflowConfig(mode: WorkflowMode.sequential),
/// );
/// ```
///
/// ```dart
/// // Create a supervisor to coordinate multiple agents
/// final supervisor = SupervisorAgent(
///   name: 'coordinator',
///   description: 'Coordinates research tasks',
///   model: gpt4,
///   workers: {
///     'researcher': researchAgent,
///     'writer': writerAgent,
///   },
/// );
/// ```
library;

// Core
export 'core/agent_exception.dart' hide MaxIterationsExceededException;
export 'core/base_agent.dart';

// Events
export 'events/agent_action.dart';
export 'events/agent_event.dart' hide TokenUsage;

// Agents
export 'agents/chat_model_agent.dart';
export 'agents/workflow_agent.dart';
export 'agents/plan_execute_agent.dart';
export 'agents/supervisor_agent.dart';

// Tools
export 'tools/agent_tool.dart';
