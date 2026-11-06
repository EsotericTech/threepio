// Mirrors the quick start of doc/GRAPHS.md.
// #docregion quick
import 'package:threepio_core/compose.dart';

Future<Message> explain(
  RunContext ctx,
  BaseChatModel model,
  String topic,
) async {
  final template = ChatTemplate.fromMessages(FormatType.fString, [
    Message.system('You explain programming topics in two sentences.'),
    Message.user('Explain {topic}.'),
  ]);
  final chain = Chain<Map<String, dynamic>, Message>()
    ..appendChatTemplate(template)
    ..appendChatModel(model);
  final runnable = await chain.compile(ctx);
  return runnable.invoke(ctx, {'topic': topic});
}
// #enddocregion quick
