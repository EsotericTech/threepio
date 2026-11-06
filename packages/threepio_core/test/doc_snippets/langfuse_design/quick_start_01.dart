// Mirrors the quick start and the configuration of doc/LANGFUSE_DESIGN.md.
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';

Future<Message> quickStart(
  Runnable<String, Message> rag,
  String publicKey,
  String secretKey,
  String question,
) async {
  final langfuse = LangfuseHandler(
    LangfuseConfig(
      host: 'https://cloud.langfuse.com',
      publicKey: publicKey,
      secretKey: secretKey,
      environment: 'staging',
      release: '1.4.0',
    ),
  );
  GlobalCallbacks.append([langfuse]); // or ctx.withHandlers([langfuse]) per run

  final ctx = langfuse.startTrace(
    RunContext.background(),
    name: 'answer-question',
    userId: 'user-123',
    sessionId: 'conversation-456',
    input: question,
    tags: ['rag'],
  );
  final answer = await rag.invoke(ctx, question);
  langfuse.endTrace(ctx, answer.content);

  await langfuse.shutdown(); // before the application exits
  return answer;
}

LangfuseConfig configuration(String publicKey, String secretKey) {
  final config = LangfuseConfig(
    host: 'https://langfuse.internal.example.com',
    publicKey: publicKey,
    secretKey: secretKey,
    sampleRate: 0.25, // a quarter of the traces
    collapseAgentInternalSpans: true,
    maxAttributeValueLength: 20000,
    batchTimeout: const Duration(seconds: 2),
    retry: const OtlpRetryConfig(maxElapsedTime: Duration(seconds: 30)),
    mask: (value) => value.replaceAll(RegExp(r'\b\d{16}\b'), '[card number]'),
  );
  return config;
}
