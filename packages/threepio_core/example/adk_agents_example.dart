// ignore_for_file: avoid_print

/// The agent runtime of the umbrella library (the Kortney runtime),
/// demonstrating:
/// 1. ChatModelAgent run through a Runner (model + tools loop)
/// 2. Event streaming and handling
/// 3. WorkflowAgent for multi-step processes (legacy agents)
///
/// This example uses the `ChatModelAgent`, `Runner` and agent events that
/// `package:threepio_core/threepio_core.dart` exports, and the older
/// `LegacyChatModelAgent` and `WorkflowAgent`. They stay for the apps built
/// on them; since 0.9 the umbrella's `ChatModelAgent` runs on the
/// Eino-shaped engine of `package:threepio_core/adk.dart`. **New code uses
/// `adk.dart` directly** (its `ChatModelAgent`, `Runner`, `AgentTool`,
/// interrupts and checkpoints): see `hitl_approval_example.dart`,
/// `deep_agent_example.dart` and `mcp_tools_example.dart`.
///
/// No Eino counterpart: this is the umbrella's Kortney runtime; its
/// Eino-shaped successor is `adk.dart` (Go `adk`).
///
/// To run this example:
///
/// ```bash
/// GEMINI_API_KEY=... dart run example/adk_agents_example.dart
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

Future<void> main() async {
  print('=== Agent Development Kit (ADK) Examples ===\n');

  final apiKey = Platform.environment['GEMINI_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('Set GEMINI_API_KEY to run this example.');
    return;
  }

  final model = GeminiChatModel(
    config: GeminiConfig(apiKey: apiKey),
  );

  try {
    await chatModelAgentExample(model);
    await eventStreamingExample(model);
    await workflowAgentExample(model);
  } finally {
    model.dispose();
  }
}

/// Example 1: ChatModelAgent run through a Runner
Future<void> chatModelAgentExample(GeminiChatModel model) async {
  print('1. ChatModelAgent (model + tools loop)...\n');

  final agent = ChatModelAgent(
    ChatModelAgentConfig(
      name: 'research-assistant',
      description: 'An AI assistant that can search and calculate',
      model: model,
      tools: [_MockSearchTool(), _CalculatorTool()],
      instruction: '''
You are a helpful research assistant. You have access to:
- search: Search for information on a topic
- calculate: Perform mathematical calculations

Always use tools when needed to provide accurate information.
''',
      maxIterations: 5,
    ),
  );

  // Run the agent and wait for the final result
  print('   User: What is 15% of 250?');

  final handle = await Runner(agent: agent).run([
    Message.user('What is 15% of 250?'),
  ]);
  final result = await handle.result;

  print('   Agent: ${result.finalMessage?.content ?? result.error}\n');
}

/// Example 2: Event streaming
Future<void> eventStreamingExample(GeminiChatModel model) async {
  print('2. Event Streaming...\n');

  final agent = ChatModelAgent(
    ChatModelAgentConfig(
      name: 'streaming-agent',
      description: 'An agent that demonstrates event streaming',
      model: model,
      tools: [_CalculatorTool()],
    ),
  );

  print('   User: Calculate 123 + 456 and explain the result.\n');

  final handle = await Runner(agent: agent).run([
    Message.user('Calculate 123 + 456 and explain the result.'),
  ]);

  await for (final event in handle.events) {
    switch (event) {
      case AgentRunStartEvent():
        print('   [Event] Agent started (run: ${event.runId})');

      case AgentActionEvent(action: ToolCallAction(:final toolName, :final arguments)):
        print('   [Event] Calling tool: $toolName');
        print('           Args: $arguments');

      case ToolResultEvent(toolName: final name, result: final result):
        print('   [Event] Tool result from $name: $result');

      case AgentOutputEvent(message: final message, isPartial: false):
        print('\n   [Final] ${message.content}');

      case AgentUsageEvent(usage: final usage):
        print('   [Event] Tokens: ${usage.totalTokens}');

      case AgentRunEndEvent():
        print('\n   [Event] Agent completed');

      case AgentErrorEvent(error: final error):
        print('   [Error] $error');

      default:
        // Other events
        break;
    }
  }

  print('');
}

/// Example 3: WorkflowAgent for multi-step processes
Future<void> workflowAgentExample(GeminiChatModel model) async {
  print('3. WorkflowAgent (Sequential Steps)...\n');

  // WorkflowAgent composes the legacy BaseAgent implementations.
  // Create empty tool registry for agents that don't need tools
  final emptyRegistry = ToolRegistry();

  // Create specialized agents for each step
  final analyzerAgent = LegacyChatModelAgent(
    name: 'analyzer',
    description: 'Analyzes user requests',
    model: model,
    toolRegistry: emptyRegistry,
    systemPrompt: 'You analyze user requests and extract key requirements. Be concise.',
  );

  final plannerAgent = LegacyChatModelAgent(
    name: 'planner',
    description: 'Creates action plans',
    model: model,
    toolRegistry: emptyRegistry,
    systemPrompt: 'You create action plans based on analysis. List 3-5 steps.',
  );

  final summarizerAgent = LegacyChatModelAgent(
    name: 'summarizer',
    description: 'Summarizes plans',
    model: model,
    toolRegistry: emptyRegistry,
    systemPrompt: 'You summarize plans into a brief executive summary.',
  );

  // Create workflow. The default WorkflowConfig runs the steps one after
  // another (WorkflowMode.sequential); a failed step ends the workflow with a
  // WorkflowException.
  final workflow = WorkflowAgent(
    name: 'planning-workflow',
    description: 'A workflow that analyzes, plans, and summarizes',
    steps: [
      WorkflowStep(
        name: 'analyze',
        agent: analyzerAgent,
        inputTransform: (messages) => [
          Message.user('Analyze this request: ${messages.last.content}'),
        ],
      ),
      WorkflowStep(
        name: 'plan',
        agent: plannerAgent,
        inputTransform: (messages) => [
          Message.user('Create a plan based on: ${messages.last.content}'),
        ],
      ),
      WorkflowStep(
        name: 'summarize',
        agent: summarizerAgent,
        inputTransform: (messages) => [
          Message.user('Summarize this plan: ${messages.last.content}'),
        ],
      ),
    ],
  );

  print('   User: I want to learn machine learning in 3 months.\n');
  print('   Running 3-step workflow...\n');

  final reader = await workflow.run([
    Message.user('I want to learn machine learning in 3 months.'),
  ]);

  try {
    while (true) {
      final event = await reader.recv();
      // The workflow reports each step it starts as a state update.
      if (event is AgentStateUpdateEvent && event.stateName == 'current_step') {
        print('   --- Step: ${event.newValue} ---');
      } else if (event is AgentOutputEvent && !event.isPartial) {
        print('   ${_truncate(event.message.content, 100)}\n');
      }
    }
  } on StreamEOFException {
    // Stream complete
  }
  await reader.close();
}

/// Mock search tool for demonstration
class _MockSearchTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo.simple(
      name: 'search',
      description: 'Search for information on a topic',
      properties: {
        'query': JSONSchemaProperty.string(description: 'Search query'),
      },
      required: ['query'],
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final query = args['query'] as String;

    // Simulate search delay
    await Future<void>.delayed(const Duration(milliseconds: 100));

    return jsonEncode({
      'query': query,
      'results': [
        {'title': 'Result 1', 'snippet': 'Information about $query...'},
        {'title': 'Result 2', 'snippet': 'More details on $query...'},
      ],
    });
  }
}

/// Calculator tool
class _CalculatorTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo.simple(
      name: 'calculate',
      description: 'Perform mathematical calculations',
      properties: {
        'expression': JSONSchemaProperty.string(
          description: 'Math expression like "5 + 3" or "10 * 2"',
        ),
      },
      required: ['expression'],
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final expr = args['expression'] as String;

    // Parse and evaluate
    try {
      // Simple evaluation for basic expressions
      final result = _evaluate(expr);
      return result.toString();
    } catch (e) {
      return 'Error: Could not evaluate "$expr"';
    }
  }

  double _evaluate(String expression) {
    // Remove spaces and handle basic operations
    final expr = expression.replaceAll(' ', '');

    // Handle percentage
    if (expr.contains('%')) {
      final percentMatch = RegExp(r'(\d+(?:\.\d+)?)%\s*(?:of)?\s*(\d+(?:\.\d+)?)');
      final match = percentMatch.firstMatch(expr);
      if (match != null) {
        final percent = double.parse(match.group(1)!);
        final value = double.parse(match.group(2)!);
        return (percent / 100) * value;
      }
    }

    // Handle basic operations
    for (final op in ['+', '-', '*', '/']) {
      if (expr.contains(op)) {
        final parts = expr.split(op);
        if (parts.length == 2) {
          final a = double.parse(parts[0]);
          final b = double.parse(parts[1]);
          switch (op) {
            case '+':
              return a + b;
            case '-':
              return a - b;
            case '*':
              return a * b;
            case '/':
              return a / b;
          }
        }
      }
    }

    return double.parse(expr);
  }
}

String _truncate(String text, int maxLength) {
  final cleaned = text.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.length <= maxLength) return cleaned;
  return '${cleaned.substring(0, maxLength)}...';
}
