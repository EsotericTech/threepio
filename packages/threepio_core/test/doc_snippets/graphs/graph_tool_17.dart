// Mirrors "A graph as a tool" of doc/GRAPHS.md.
// #docregion tool
import 'package:threepio_core/adk.dart';

ChatModelAgent buildAgent(BaseChatModel model) {
  // Any graph, chain or workflow from String to String.
  final shout = Chain<String, String>()
    ..appendLambda(
      Lambda<String, String>.invokable((ctx, text) => text.toUpperCase()),
    );

  final tool = GraphTool.invokable<String, String>(
    name: 'shout',
    description: 'Repeats a text in capital letters',
    params: const ParamsOneOf.params({
      'text': ParameterInfo(type: DataType.string, required: true),
    }),
    fromJson: (arguments) => arguments['text']! as String,
    graph: shout,
  );

  return ChatModelAgent(
    ChatModelAgentConfig(
      name: 'assistant',
      description: 'Answers questions',
      instruction: 'Use the shout tool when asked to shout.',
      model: model,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
    ),
  );
}
// #enddocregion tool
