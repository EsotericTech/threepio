// Mirror of a ```dart block of doc/NEW_FEATURES.md (see
// test/unit/docs/doc_snippets_test.dart): the block is copied verbatim; the
// lines around it declare what it uses.
// Section 2, "Error Handling".
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

Future<void> errorHandling(BaseAgent agent, List<Message> messages) async {
  final reader = await agent.run(messages);

  await for (final event in reader.asStream()) {
    if (event is AgentErrorEvent) {
      // isRecoverable: the agent goes on (a plan-execute agent replans)
      final outcome = event.isRecoverable ? 'Recovered' : 'Failed';
      print('$outcome: ${event.error}');
    }
  }
}
