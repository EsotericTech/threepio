// Mirror of doc/MIGRATION.md, legacy: Chain (after).
// ignore_for_file: avoid_print
import 'package:threepio_core/compose.dart';

Future<String> answerWithChain(BaseChatModel model, String question) async {
  final chain = Chain<Map<String, dynamic>, Message>()
    ..appendChatTemplate(
      ChatTemplate.fromMessages(FormatType.fString, [
        Message.system('You are a concise assistant.'),
        Message.user('{question}'),
      ]),
    )
    ..appendChatModel(model);
  final ctx = RunContext.background();
  final runnable = await chain.compile(ctx);
  final answer = await runnable.invoke(ctx, {'question': question});
  return answer.content;
}
