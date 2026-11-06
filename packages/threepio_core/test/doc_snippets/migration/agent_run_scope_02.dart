// Mirror of doc/MIGRATION.md, break 1: AgentRunScope.
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

Future<void> runWithScope(ChatModelAgent agent, List<Message> messages) async {
final reader = await agent.run(
  messages,
  // Before 0.9: context: RunContext(sessionId: 'chat-1'),
  context: AgentRunScope(sessionId: 'chat-1'),
);
await for (final event in reader.asStream()) {
  print(event.eventType);
}
}
