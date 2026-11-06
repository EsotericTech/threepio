// Mirror of doc/MIGRATION.md, legacy: LangfuseHandler.
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

Future<void> tracedAnswer(
  BaseChatModel model,
  String publicKey,
  String secretKey,
) async {
  final langfuse = LangfuseHandler(
    LangfuseConfig(
      host: 'https://cloud.langfuse.com',
      publicKey: publicKey,
      secretKey: secretKey,
    ),
  );
  final ctx = langfuse.startTrace(
    RunContext.background().withHandlers([langfuse]),
    name: 'answer-question',
    input: 'What is a DAG?',
  );
  final answer = await model.generate(
    [Message.user('What is a DAG?')],
    options: ChatModelOptions(runContext: ctx),
  );
  langfuse.endTrace(ctx, answer.content);
  await langfuse.shutdown(); // before the application exits
}
