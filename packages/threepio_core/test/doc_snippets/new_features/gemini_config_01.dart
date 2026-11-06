// Mirror of doc/NEW_FEATURES.md, section 1, "### Configuration".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

void geminiConfiguration() {
  // Basic configuration
  const config = GeminiConfig(
    apiKey: 'your-api-key',
    defaultModel: 'gemini-2.5-pro', // default: gemini-2.5-flash
    timeout: Duration(seconds: 60), // default: 120 seconds
  );

  // Or from the environment: GEMINI_API_KEY or GOOGLE_API_KEY (required),
  // GEMINI_BASE_URL and GEMINI_MODEL (optional). Throws a
  // GeminiConfigException when neither key is set.
  final configFromEnv = GeminiConfig.fromEnvironment();

  // Create the chat model
  final model = GeminiChatModel(config: config);
  print(configFromEnv);
  model.dispose();
}
