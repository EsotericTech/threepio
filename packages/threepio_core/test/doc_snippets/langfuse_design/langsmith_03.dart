// Mirrors "LangSmith" of doc/LANGFUSE_DESIGN.md.
// ignore_for_file: avoid_print
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/compose.dart';

Future<void> langSmithExample(
  Runnable<String, Message> rag,
  String langSmithKey,
  String question,
) async {
  final langSmith = LangSmithHandler(LangSmithConfig(apiKey: langSmithKey));
  final traced = LangSmithTrace.set(
    RunContext.background().withHandlers([langSmith]),
    sessionName: 'support-bot',
    tags: ['rag'],
    metadata: {
      'metadata': {'tenant': 'acme'},
    },
  );
  final reply = await rag.invoke(traced, question);
  print(reply.content);
  await langSmith.shutdown(); // sends what is queued, closes its HTTP client
}
