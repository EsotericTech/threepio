// Mirror of doc/MIGRATION.md, legacy: LLMChain (before).
// ignore_for_file: avoid_print
import 'package:threepio_core/legacy_chains.dart';
import 'package:threepio_core/threepio_core.dart';

Future<String> answerWithLLMChain(BaseChatModel model, String question) async {
  final chain = LLMChain(
    template: ChatTemplate.fromMessages(FormatType.fString, [
      Message.system('You are a concise assistant.'),
      Message.user('{question}'),
    ]),
    model: model,
    outputKey: 'answer',
  );
  final outputs = await chain.run({'question': question});
  return outputs['answer'] as String;
}
