// ignore_for_file: avoid_print

/// A chat template with variables and a history placeholder, a model call
/// that waits for the whole answer, and one that streams it.
///
/// Port of eino-examples `quickstart/chat` (`main.go`, `template.go`,
/// `generate.go`, `stream.go`). `openai.go` becomes `exampleChatModel()`
/// (OpenRouter, or OpenAI with `OPENAI_MODEL` where Go reads
/// `OPENAI_MODEL_NAME`); `ollama.go` and `EINO_CHAT_PROVIDER=ollama` are not
/// ported. The prompts are translated from Chinese.
///
/// * `createTemplate`: `ChatTemplate.fromMessages` (Go `prompt.FromMessages`)
///   with `FormatType.fString` variables and a `MessagesPlaceholder` (Go
///   `schema.MessagesPlaceholder`) for the conversation so far.
/// * `generate` and `stream`: `BaseChatModel.generate` / `stream` (Go
///   `Generate` / `Stream`).
/// * `templateChain` (not in the Go example): the same request as one
///   compose `Chain`, template → model, invoked and streamed.
///
/// Run it with an OpenRouter or OpenAI key (see `example/README.md`):
///
/// ```bash
/// OPENROUTER_API_KEY=... dart run example/eino_examples/quickstart_chat.dart
/// ```
library;

import 'package:threepio_core/compose.dart';

import '../support/example_model.dart';

/// The chat template. Go: `createTemplate`.
ChatTemplate createTemplate() {
  // A template whose variables use the FString syntax: {name}.
  return ChatTemplate.fromMessages(FormatType.fString, [
    // The system message template.
    Message.system(
      'You are a {role}. Answer in a {style} tone. Your goal is to help '
      'programmers stay positive and optimistic: give technical advice and '
      'care about their mental health too.',
    ),

    // The conversation so far goes here (nothing for a new conversation).
    const MessagesPlaceholder('chat_history', optional: true),

    // The user message template.
    Message.user('Question: {question}'),
  ]);
}

/// The variables of the template, with a made-up history of two turns.
Map<String, dynamic> exampleVariables() => {
      'role': 'programmer encourager',
      'style': 'positive, warm and professional',
      'question': 'My code keeps failing and I feel frustrated. What should '
          'I do?',
      // The conversation so far (two made-up turns in this example).
      'chat_history': [
        Message.user('Hello'),
        Message.assistant(
          "Hey! I'm your programmer encourager! Remember, every great "
          'programmer grows through debugging. How can I help you?',
        ),
        Message.user('I think the code I write is terrible'),
        Message.assistant(
          'Every programmer goes through this stage! What matters is that you '
          "keep learning and improving. Let's look at the code together: "
          "refactoring will make it better. Rome wasn't built in a day, and "
          'code quality grows with steady improvement.',
        ),
      ],
    };

/// The messages of the template for [exampleVariables]. Go:
/// `createMessagesFromTemplate`.
///
/// Go's `Format(ctx, vars)` takes a context; Dart's `format` takes the
/// variables, and a run context (for callbacks) goes in
/// `ChatTemplateOptions.runContext`.
Future<List<Message>> createMessagesFromTemplate() =>
    createTemplate().format(exampleVariables());

/// Asks [llm] to continue [input] and waits for the whole answer. Go:
/// `generate`.
Future<Message> generate(BaseChatModel llm, List<Message> input) =>
    llm.generate(input);

/// Asks [llm] to continue [input] and returns the answer as a stream of
/// chunks. Go: `stream`.
Future<StreamReader<Message>> stream(BaseChatModel llm, List<Message> input) =>
    llm.stream(input);

/// Prints the chunks of [sr] and closes it. Go: `reportStream`.
Future<void> reportStream(StreamReader<Message> sr) async {
  var i = 0;
  try {
    // Go: for { message, err := sr.Recv(); if err == io.EOF { return } }
    while (true) {
      final message = await sr.recv();
      print('message[$i]: ${message.toDisplayString()}');
      i++;
    }
  } on StreamEOFException {
    // The stream has ended.
  } finally {
    await sr.close();
  }
}

/// The quickstart: format the template, generate, stream. Go: `main`, after
/// the model is created.
Future<void> runQuickstartChat(BaseChatModel cm) async {
  // Create the messages from the template.
  print('===create messages===');
  final messages = await createMessagesFromTemplate();
  print('messages:');
  for (final message in messages) {
    print('  ${message.toDisplayString()}');
  }
  print('');

  print('===llm generate===');
  final result = await generate(cm, messages);
  print('result: ${result.toDisplayString()}\n');

  print('===llm stream generate===');
  final streamResult = await stream(cm, messages);
  await reportStream(streamResult);
}

/// The same request as one compose chain: the template, then the model.
/// Compiled, it is a runnable that takes the variables and gives the
/// answer, at once ([Runnable.invoke]) or in chunks ([Runnable.stream]).
///
/// Go: `compose.NewChain[map[string]any, *schema.Message]()`, then
/// `AppendChatTemplate`, `AppendChatModel`, `Compile`, `Invoke`, `Stream`.
Future<void> templateChain(
  ChatTemplate template,
  BaseChatModel model,
  Map<String, dynamic> variables,
) async {
  final ctx = RunContext.background();

  final chain = Chain<Map<String, dynamic>, Message>()
    ..appendChatTemplate(template)
    ..appendChatModel(model);
  final runnable = await chain.compile(ctx);

  // invoke: the whole answer at once.
  final answer = await runnable.invoke(ctx, variables);
  print('invoke: ${answer.content}');

  // stream: the answer in chunks, as the model writes them.
  final chunks = await runnable.stream(ctx, variables);
  await for (final chunk in chunks.asStream()) {
    print('chunk: ${chunk.content}');
  }
}

Future<void> main() async {
  // Create the llm. Go: createOpenAIChatModel (its EINO_CHAT_PROVIDER=ollama
  // switch is not ported). Go formats the messages first; here the model
  // comes first so that main can stop when no key is set.
  print('===create llm===');
  final cm = exampleChatModel();
  if (cm == null) return;
  print('create llm success\n');

  try {
    await runQuickstartChat(cm);

    print('\n===template → model chain===');
    await templateChain(createTemplate(), cm, exampleVariables());
  } finally {
    closeExampleModel(cm);
  }
}
