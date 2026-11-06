// Mirror of doc/MIGRATION.md, legacy: adk.Runner (after).
// ignore_for_file: avoid_print
import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

Future<void> askAgent(ToolCallingChatModel model, BaseTool weather) async {
  final runner = adk.Runner(
    agent: adk.ChatModelAgent(
      adk.ChatModelAgentConfig(
        name: 'assistant',
        description: 'Answers questions about the weather',
        instruction: 'You are a helpful assistant.',
        model: model,
        toolsConfig: adk.ToolsConfig(
          toolsNode: adk.ToolsNodeConfig(tools: [weather]),
        ),
      ),
    ),
  );
  final events = runner.query(RunContext.background(), 'Weather in Lisbon?');
  for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
    if (e.error != null) {
      print('error: ${e.error}');
      break;
    }
    final message = await adk.getMessageFromEvent(e);
    // The final answer: an assistant message without tool calls (tool
    // results arrive as messages of their own).
    if (message != null &&
        message.role == RoleType.assistant &&
        (message.toolCalls?.isEmpty ?? true)) {
      print(message.content);
    }
  }
}
