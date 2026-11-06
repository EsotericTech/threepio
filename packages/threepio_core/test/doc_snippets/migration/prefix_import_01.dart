// Mirror of doc/MIGRATION.md, "Libraries": adk.dart with a prefix.
// ignore_for_file: avoid_print
import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// Builds both agents called `ChatModelAgent`.
void bothAgents(ToolCallingChatModel model) {
  // The umbrella's ChatModelAgent: the Kortney runtime.
  final kortney = ChatModelAgent(
    ChatModelAgentConfig(name: 'assistant', model: model),
  );

  // The Eino-shaped ChatModelAgent of adk.dart (Go `adk.NewChatModelAgent`).
  final agent = adk.ChatModelAgent(
    adk.ChatModelAgentConfig(
      name: 'assistant',
      description: 'Answers questions',
      model: model,
    ),
  );

  print('${kortney.name} and ${agent.name}');
}
