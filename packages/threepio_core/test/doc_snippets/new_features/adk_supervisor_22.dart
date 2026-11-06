// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 2, "SupervisorAgent".
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

import 'adk_react_agent_20.dart';

Future<void> supervisor(ToolCallingChatModel geminiModel) async {
  // Create tool registries for workers
  final researchRegistry = ToolRegistry();
  researchRegistry.register(SearchTool());

  final emptyRegistry = ToolRegistry(); // For agents without tools

  // Create worker agents
  final researchWorker = LegacyChatModelAgent(
    name: 'researcher',
    description: 'A research specialist',
    model: geminiModel,
    toolRegistry: researchRegistry,
    systemPrompt: 'You are a research specialist.',
  );

  final writerWorker = LegacyChatModelAgent(
    name: 'writer',
    description: 'A professional writer',
    model: geminiModel,
    toolRegistry: emptyRegistry,
    systemPrompt: 'You are a professional writer.',
  );

  // Create supervisor
  final supervisor = SupervisorAgent(
    name: 'project-manager',
    description: 'Coordinates research and writing',
    model: geminiModel,
    workers: {
      'researcher': researchWorker,
      'writer': writerWorker,
    },
    systemPrompt: '''
  You are a project manager. Delegate tasks to your team:
  - researcher: for finding information
  - writer: for creating content
  ''',
    // allowDirectResponse and trackHistory are on by default
    config: const SupervisorConfig(
      maxDelegations: 5,
    ),
  );

  final result = await supervisor.invoke([
    Message.user('Create a blog post about renewable energy'),
  ]);
  print(result.content);
}
