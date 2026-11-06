// Mirror of the README quick start "1. A template and a model in a chain".
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

Future<void> main() async {
  final model = OpenAIChatModel(
    config: OpenAIConfig(apiKey: Platform.environment['OPENAI_API_KEY']!),
  );

  // A chat template (Eino `prompt.FromMessages`): f-string variables and a
  // placeholder for earlier messages.
  final template = ChatTemplate.fromMessages(FormatType.fString, [
    Message.system('You are a {role}.'),
    const MessagesPlaceholder('history', optional: true),
    Message.user('{question}'),
  ]);

  // template → model, compiled into a Runnable (Eino `compose.NewChain`).
  final chain = Chain<Map<String, dynamic>, Message>()
    ..appendChatTemplate(template)
    ..appendChatModel(model);
  final ctx = RunContext.background();
  final runnable = await chain.compile(ctx);

  final variables = {'role': 'concise assistant', 'question': 'What is a DAG?'};
  final answer = await runnable.invoke(ctx, variables);
  print(answer.content);

  // The same runnable streams; chunks arrive as the model writes them.
  final chunks = await runnable.stream(ctx, variables);
  for (var c = await chunks.nextOrNull(); c != null; c = await chunks.nextOrNull()) {
    stdout.write(c.content);
  }

  model.dispose();
}
