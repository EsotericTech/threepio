// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 2, "Agent Run Context".
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

Future<void> runContext(
  BaseAgent agent,
  List<Message> messages, {
  required bool userCancelledRequest,
}) async {
  final context = AgentRunContext(
    runId: 'run-123',
    metadata: {'user_id': 'user-456'},
    onEvent: (event) {
      // LegacyChatModelAgent reports its start and end events here
      print('Event: ${event.eventType}');
    },
    shouldCancel: () {
      // Polled between steps; when and how often depends on the agent
      return userCancelledRequest;
    },
  );

  final result = await agent.invoke(messages, context: context);
  print(result.content);
}
