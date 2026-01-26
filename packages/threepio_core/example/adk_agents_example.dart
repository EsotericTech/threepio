// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

/// Agent Development Kit (ADK) example demonstrating:
/// 1. ChatModelAgent with ReAct pattern
/// 2. Event streaming and handling
/// 3. WorkflowAgent for multi-step processes
/// 4. SupervisorAgent for delegation
/// 5. Agent as Tool pattern
///
/// To run this example:
/// 1. Set GEMINI_API_KEY environment variable
/// 2. Run: dart run example/adk_agents_example.dart
Future<void> main() async {
  print('=== Agent Development Kit (ADK) Examples ===\n');

  final apiKey = Platform.environment['GEMINI_API_KEY'];
  if (apiKey == null) {
    print('Error: GEMINI_API_KEY must be set');
    exit(1);
  }

  final model = GeminiChatModel(
    config: GeminiConfig(apiKey: apiKey),
  );

  await chatModelAgentExample(model);
  await eventStreamingExample(model);
  await workflowAgentExample(model);
}

/// Example 1: ChatModelAgent with ReAct pattern
Future<void> chatModelAgentExample(GeminiChatModel model) async {
  print('1. ChatModelAgent (ReAct Pattern)...\n');

  // Create tools and registry
  final searchTool = _MockSearchTool();
  final calculatorTool = _CalculatorTool();

  final registry = ToolRegistry();
  registry.register(searchTool);
  registry.register(calculatorTool);

  // Create agent
  final agent = ChatModelAgent(
    name: 'research-assistant',
    description: 'An AI assistant that can search and calculate',
    model: model,
    toolRegistry: registry,
    systemPrompt: '''
You are a helpful research assistant. You have access to:
- search: Search for information on a topic
- calculate: Perform mathematical calculations

Always use tools when needed to provide accurate information.
''',
    config: const ChatModelAgentConfig(
      maxIterations: 5,
      maxToolCalls: 10,
      emitPartialOutputs: true,
    ),
  );

  // Run agent and get final result
  print('   User: What is 15% of 250?');

  final result = await agent.invoke([
    Message.user('What is 15% of 250?'),
  ]);

  print('   Agent: ${result.content}\n');
}

/// Example 2: Event streaming
Future<void> eventStreamingExample(GeminiChatModel model) async {
  print('2. Event Streaming...\n');

  final registry = ToolRegistry();
  registry.register(_CalculatorTool());

  final agent = ChatModelAgent(
    name: 'streaming-agent',
    description: 'An agent that demonstrates event streaming',
    model: model,
    toolRegistry: registry,
    config: const ChatModelAgentConfig(
      emitPartialOutputs: true,
    ),
  );

  print('   User: Calculate 123 + 456 and explain the result.\n');

  final reader = await agent.run([
    Message.user('Calculate 123 + 456 and explain the result.'),
  ]);

  try {
    while (true) {
      final event = await reader.recv();
      switch (event) {
        case AgentRunStartEvent():
          print('   [Event] Agent started (run: ${event.runId})');

        case AgentActionEvent(action: final action):
          if (action is ToolCallAction) {
            print('   [Event] Calling tool: ${action.toolName}');
            print('           Args: ${action.arguments}');
          }

        case ToolResultEvent(toolName: final name, result: final result):
          print('   [Event] Tool result from $name: $result');

        case AgentOutputEvent(message: final message, isPartial: final isPartial):
          if (!isPartial) {
            print('\n   [Final] ${message.content}');
          }

        case AgentRunEndEvent(tokenUsage: final usage):
          print('\n   [Event] Agent completed');
          if (usage != null) {
            print('           Tokens: ${usage.totalTokens}');
          }

        case AgentErrorEvent(error: final error):
          print('   [Error] $error');

        default:
          // Other events
          break;
      }
    }
  } on StreamEOFException {
    // Stream complete
  }
  await reader.close();

  print('');
}

/// Example 3: WorkflowAgent for multi-step processes
Future<void> workflowAgentExample(GeminiChatModel model) async {
  print('3. WorkflowAgent (Sequential Steps)...\n');

  // Create empty tool registry for agents that don't need tools
  final emptyRegistry = ToolRegistry();

  // Create specialized agents for each step
  final analyzerAgent = ChatModelAgent(
    name: 'analyzer',
    description: 'Analyzes user requests',
    model: model,
    toolRegistry: emptyRegistry,
    systemPrompt: 'You analyze user requests and extract key requirements. Be concise.',
  );

  final plannerAgent = ChatModelAgent(
    name: 'planner',
    description: 'Creates action plans',
    model: model,
    toolRegistry: emptyRegistry,
    systemPrompt: 'You create action plans based on analysis. List 3-5 steps.',
  );

  final summarizerAgent = ChatModelAgent(
    name: 'summarizer',
    description: 'Summarizes plans',
    model: model,
    toolRegistry: emptyRegistry,
    systemPrompt: 'You summarize plans into a brief executive summary.',
  );

  // Create workflow
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
    config: const WorkflowConfig(
      mode: WorkflowMode.sequential,
      stopOnFirstError: false,
    ),
  );

  print('   User: I want to learn machine learning in 3 months.\n');
  print('   Running 3-step workflow...\n');

  final reader = await workflow.run([
    Message.user('I want to learn machine learning in 3 months.'),
  ]);

  String currentStep = '';
  try {
    while (true) {
      final event = await reader.recv();
      if (event is AgentRunStartEvent) {
        if (event.agentName != currentStep) {
          currentStep = event.agentName;
          print('   --- Step: $currentStep ---');
        }
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
    await Future.delayed(const Duration(milliseconds: 100));

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

  double _evaluate(String expr) {
    // Remove spaces and handle basic operations
    expr = expr.replaceAll(' ', '');

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
