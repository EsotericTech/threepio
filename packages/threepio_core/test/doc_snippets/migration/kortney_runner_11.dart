// Mirror of doc/MIGRATION.md, legacy: the Kortney runner (before).
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

Future<void> askKortney(ToolCallingChatModel model, BaseTool weather) async {
  final runner = Runner(
    agent: ChatModelAgent(
      ChatModelAgentConfig(
        name: 'assistant',
        instruction: 'You are a helpful assistant.',
        model: model,
        tools: [weather],
      ),
    ),
  );
  final handle = await runner.run(
    [Message.user('Weather in Lisbon?')],
    sessionId: 'chat-1',
  );
  await for (final event in handle.events) {
    if (event is AgentOutputEvent && !event.isPartial) {
      print(event.message.content);
    }
  }
  final result = await handle.result;
  print('${result.messages.length} messages to keep');
}
