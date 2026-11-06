// Mirror of doc/NEW_FEATURES.md, section 1, "### Generation Options".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

Future<void> generationOptions(
  GeminiChatModel model,
  List<Message> messages,
) async {
  final response = await model.generate(
    messages,
    options: GeminiRequestOptions(
      topK: 40, // Top-K sampling
    ).toOptions(
      model: 'gemini-2.5-pro', // Override the default model
      temperature: 0.7, // Creativity (0.0 - 2.0)
      maxTokens: 1024, // Maximum output tokens
      topP: 0.95, // Nucleus sampling
      stop: ['END'], // Stop sequences
    ),
  );

  // Token usage
  final usage = response.responseMeta?.usage;
  print('Prompt tokens: ${usage?.promptTokens}');
  print('Completion tokens: ${usage?.completionTokens}');

  // Defaults of every call, the safety filter and thinking
  const tunedConfig = GeminiConfig(
    apiKey: 'your-api-key',
    temperature: 0.2,
    topK: 40,
    safetySettings: [
      GeminiSafetySetting(
        category: GeminiHarmCategory.harassment,
        threshold: GeminiHarmBlockThreshold.blockMediumAndAbove,
      ),
    ],
    // The thought summaries come back in Message.reasoningContent
    thinkingConfig: GeminiThinkingConfig(includeThoughts: true),
  );
  print(tunedConfig);
}
