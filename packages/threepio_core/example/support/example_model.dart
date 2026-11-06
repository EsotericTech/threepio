import 'dart:io';

import 'package:threepio_core/threepio_core.dart';

/// The chat model the examples talk to, chosen from the environment.
///
/// * `OPENROUTER_API_KEY` set: an [OpenRouterChatModel]; the model is
///   `OPENROUTER_MODEL` (default `openai/gpt-4o-mini`).
/// * otherwise `OPENAI_API_KEY` set: an [OpenAIChatModel]; the model is
///   `OPENAI_MODEL` (default `gpt-4o-mini`), the endpoint `OPENAI_BASE_URL`
///   (default the OpenAI API), so any OpenAI-compatible server works.
///
/// A variable that is set but empty counts as unset. Returns `null`, after
/// saying what is missing on stderr, when neither key is set. Close the model
/// with [closeExampleModel] when done.
ToolCallingChatModel? exampleChatModel() {
  final openRouterKey = _setting('OPENROUTER_API_KEY');
  if (openRouterKey != null) {
    return OpenRouterChatModel(
      config: OpenRouterConfig(
        apiKey: openRouterKey,
        defaultModel: _setting('OPENROUTER_MODEL') ?? 'openai/gpt-4o-mini',
      ),
    );
  }

  final openAIKey = _setting('OPENAI_API_KEY');
  if (openAIKey != null) {
    return OpenAIChatModel(
      config: OpenAIConfig(
        apiKey: openAIKey,
        baseUrl: _setting('OPENAI_BASE_URL') ?? 'https://api.openai.com/v1',
        defaultModel: _setting('OPENAI_MODEL') ?? 'gpt-4o-mini',
      ),
    );
  }

  stderr.writeln(
    'Set OPENROUTER_API_KEY or OPENAI_API_KEY to run this example '
    '(see example/README.md).',
  );
  return null;
}

/// The environment variable [name], or `null` when it is unset or empty.
String? _setting(String name) {
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? null : value;
}

/// Closes the HTTP client of a model made by [exampleChatModel]. The copies
/// `withTools` made share it, so they are closed too.
void closeExampleModel(BaseChatModel model) {
  if (model is OpenRouterChatModel) {
    model.dispose();
  } else if (model is OpenAIChatModel) {
    model.dispose();
  }
}
