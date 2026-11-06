// Mirrors "LangSmith" of doc/CALLBACKS.md.
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';

Future<Message> langSmithRun(
  Runnable<String, Message> runnable,
  String question,
  String apiKey,
) async {
  // #docregion langsmith
  final langSmith = LangSmithHandler(
    LangSmithConfig(apiKey: apiKey), // 'lsv2_...'
  );

  // The project, tags and metadata of the runs of this context.
  final ctx = LangSmithTrace.set(
    RunContext.background().withHandlers([langSmith]),
    sessionName: 'support-bot',
    tags: ['production'],
  );
  final answer = await runnable.invoke(ctx, question);

  await langSmith.shutdown(); // sends what is queued, closes the client
  // #enddocregion langsmith
  return answer;
}

Future<void> flowTrace(
  LangSmithConfig config,
  Runnable<String, Message> runnable,
) async {
  // #docregion flow
  // Several runs (or processes) in one trace.
  final flow = LangSmithFlowTrace(config);
  final (ctx, spanId) = await flow.startSpan(
    LangSmithTrace.set(RunContext.background(), sessionName: 'support-bot'),
    'conversation',
  );
  try {
    await runnable.invoke(ctx, 'first question');
    await runnable.invoke(ctx, 'second question');
  } finally {
    await flow.finishSpan(ctx, spanId);
  }
  // #enddocregion flow
}
