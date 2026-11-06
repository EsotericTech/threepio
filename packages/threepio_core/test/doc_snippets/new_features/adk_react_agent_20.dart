// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 2, "LegacyChatModelAgent (ReAct Pattern)".
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'package:threepio_core/threepio_core.dart';

/// Stands in for the application's search backend.
Future<String> performSearch(String query) async => 'Results for $query';

// A tool the agent can call.
class SearchTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.simple(
        name: 'search',
        description: 'Search the web for information',
        properties: {
          'query': JSONSchemaProperty.string(description: 'Search query'),
        },
        required: ['query'],
      );

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;
    final query = args['query'] as String;
    return performSearch(query); // your search backend
  }
}

Future<void> runResearchAgent(ToolCallingChatModel geminiModel) async {
  final registry = ToolRegistry();
  registry.register(SearchTool());

  final agent = LegacyChatModelAgent(
    name: 'research-agent',
    description: 'An agent that researches topics',
    model: geminiModel,
    toolRegistry: registry,
    systemPrompt: 'You are a helpful research assistant.',
    // Defaults: 10 iterations, 50 tool calls, partial outputs on
    config: const LegacyChatModelAgentConfig(
      maxIterations: 5,
      maxToolCalls: 20,
    ),
  );

  // Run with event streaming
  final reader = await agent.run([
    Message.user('Research the latest developments in quantum computing'),
  ]);

  try {
    while (true) {
      final event = await reader.recv();
      switch (event) {
        case AgentRunStartEvent():
          print('Agent started');
        case AgentActionEvent(action: ToolCallAction(:final toolName)):
          print('Calling tool: $toolName');
        case ToolResultEvent(:final result):
          print('Tool result: $result');
        case AgentOutputEvent(:final message, isPartial: true):
          stdout.write(message.content); // partial output
        case AgentOutputEvent(:final message):
          print('Final answer: ${message.content}');
        case AgentErrorEvent(:final error):
          print('Error: $error');
        case AgentRunEndEvent():
          print('Agent completed');
        case _:
          break;
      }
    }
  } on StreamEOFException {
    // Stream complete
  } finally {
    await reader.close();
  }

  // Or get the final result directly
  final result = await agent.invoke([
    Message.user('What is 2 + 2?'),
  ]);
  print(result.content);
}
