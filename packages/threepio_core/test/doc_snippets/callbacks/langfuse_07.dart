// Mirrors "Langfuse" of doc/CALLBACKS.md.
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';

Future<Message> langfuseRun(
  Runnable<String, Message> runnable,
  String question, {
  required String publicKey,
  required String secretKey,
}) async {
  // #docregion langfuse
  final langfuse = LangfuseHandler(
    LangfuseConfig(
      host: 'https://cloud.langfuse.com',
      publicKey: publicKey, // 'pk-lf-...'
      secretKey: secretKey, // 'sk-lf-...'
    ),
  );
  GlobalCallbacks.append([langfuse]);

  // One trace per request; the components of the run appear beneath it.
  final ctx = langfuse.startTrace(
    RunContext.background(),
    name: 'answer-question',
    userId: 'user-123',
    sessionId: 'conversation-456',
    input: question,
  );
  final answer = await runnable.invoke(ctx, question);
  langfuse.endTrace(ctx, answer.content);

  await langfuse.shutdown(); // before the application exits
  // #enddocregion langfuse
  return answer;
}
