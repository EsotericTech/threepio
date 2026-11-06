// Mirrors the ReAct graph of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

// #docregion react
/// The conversation so far, kept per run.
final class Conversation {
  final List<Message> messages = [];
}

Future<Runnable<List<Message>, Message>> buildReAct(
  RunContext ctx,
  ToolCallingChatModel model,
  List<BaseTool> tools,
) async {
  final toolInfos = [for (final tool in tools) await tool.info()];
  final toolsNode = await ToolsNode.create(ToolsNodeConfig(tools: tools));

  final graph = Graph<List<Message>, Message>(
    localState: LocalState.of<Conversation>((ctx) => Conversation()),
  )
    ..addChatModelNode(
      'model',
      model.withTools(toolInfos),
      options: NodeOptions(
        // The model sees the whole conversation, not only the new messages.
        statePreHandler: StateHandler.pre<List<Message>, Conversation>(
          (ctx, input, state) {
            state.messages.addAll(input);
            return List.of(state.messages);
          },
        ),
        statePostHandler: StateHandler.post<Message, Conversation>(
          (ctx, output, state) {
            state.messages.add(output);
            return output;
          },
        ),
      ),
    )
    // Message with tool calls -> List<Message> (one tool message per call).
    ..addToolsNode('tools', toolsNode)
    ..addEdge(Graph.start, 'model')
    // Go: compose.NewGraphBranch.
    ..addBranch(
      'model',
      GraphBranch.single<Message>(
        (ctx, message) =>
            (message.toolCalls?.isNotEmpty ?? false) ? 'tools' : Graph.end,
        {'tools', Graph.end},
      ),
    )
    ..addEdge('tools', 'model');

  return graph.compile(
    ctx,
    options: const GraphCompileOptions(graphName: 'react', maxRunSteps: 20),
  );
}
// #enddocregion react
