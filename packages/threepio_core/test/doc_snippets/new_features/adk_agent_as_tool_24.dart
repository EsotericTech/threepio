// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 2, "Wrapping Agents as Tools".
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

Future<void> agentAsTool(
  ToolCallingChatModel geminiModel,
  InvokableTool searchTool,
) async {
  // Create a specialized agent
  final factChecker = LegacyChatModelAgent(
    name: 'fact-checker',
    description: 'Verifies statements',
    model: geminiModel,
    toolRegistry: ToolRegistry(),
    systemPrompt: 'You verify facts and return true/false with explanation.',
  );

  // Wrap as a tool
  final factCheckTool = factChecker.asTool(
    toolName: 'verify_fact',
    toolDescription: 'Verify if a statement is factually correct',
    inputParameter: 'statement',
  );

  // Use in another agent
  final mainAgent = LegacyChatModelAgent(
    name: 'assistant',
    description: 'A general assistant',
    model: geminiModel,
    toolRegistry: ToolRegistry(tools: [factCheckTool, searchTool]),
  );

  final answer = await mainAgent.invoke([
    Message.user('Is the Great Wall of China visible from space?'),
  ]);
  print(answer.content);
}
