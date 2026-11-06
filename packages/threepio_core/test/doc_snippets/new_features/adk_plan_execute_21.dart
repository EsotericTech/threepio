// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 2, "PlanExecuteAgent".
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

Future<void> planExecute(
  BaseChatModel geminiModel,
  BaseAgent searchAgent,
  BaseAgent analyzeAgent,
  BaseAgent summaryAgent,
) async {
  final planAgent = PlanExecuteAgent(
    name: 'plan-execute-agent',
    description: 'Plans a task, then runs each step with an executor',
    plannerModel: geminiModel, // any BaseChatModel
    executors: {
      'search': searchAgent,
      'analyze': analyzeAgent,
      'summarize': summaryAgent,
    },
    // Replans after a failed step by default (replanOnError)
    config: const PlanExecuteConfig(
      maxReplanAttempts: 2,
      maxStepsPerPlan: 5,
    ),
  );

  final reader = await planAgent.run([
    Message.user('Research and summarize the top 3 AI trends of 2024'),
  ]);

  await for (final event in reader.asStream()) {
    switch (event) {
      case AgentStateUpdateEvent(:final stateName, :final newValue):
        print('$stateName: $newValue'); // phase: planning, current_step: step_1, …
      case AgentActionEvent(action: ThinkAction(:final thought)):
        print(thought); // "Created plan with 3 steps: …"
      case AgentOutputEvent(:final message):
        print('Step result: ${message.content}');
      case AgentRunEndEvent(:final outputMessage):
        print('Result: ${outputMessage.content}');
      case _:
        break;
    }
  }
}
