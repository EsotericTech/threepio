// Mirrors "Call options" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

Future<Message> callOptions(
  RunContext ctx,
  Runnable<String, Message> runnable,
  ComponentCallbackHandler logger,
) async {
  // #docregion options
  final answer = await runnable.invoke(
    ctx,
    'Summarize the meeting notes',
    options: [
      // Every chat model node of the graph, nested graphs included.
      CallOption.chatModel(const ChatModelOptions(temperature: 0)),
      // Only the node 'summarize'. Go: WithChatModelOption(...).DesignateNode.
      CallOption.chatModel(const ChatModelOptions(model: 'small-model'))
          .designateNode(['summarize']),
      // The node 'model' of the graph that is the node 'review'.
      CallOption.chatModel(const ChatModelOptions(maxTokens: 200))
          .designateNodeWithPath([
        NodePath(const ['review', 'model']),
      ]),
      // Handlers for this run; aimed at a node, they hear that node and
      // what runs inside it.
      CallOption.callbacks([logger]),
      // A step limit for this run instead of the compiled one.
      CallOption.runtimeMaxSteps(30),
    ],
  );
  // #enddocregion options
  return answer;
}
