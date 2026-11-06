// Mirror of doc/NEW_FEATURES.md, section 1, "### Tool Choice Control".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'package:threepio_core/threepio_core.dart';

Future<void> toolChoice(
  ToolCallingChatModel modelWithTools,
  List<Message> messages,
) async {
  // Force tool use
  final response = await modelWithTools.generate(
    messages,
    options: const ChatModelOptions(
      toolChoice: ToolChoice.forced, // ANY - must use a tool
    ),
  );

  // Force one particular tool
  final response2 = await modelWithTools.generate(
    messages,
    options: const ChatModelOptions(
      toolChoice: ToolChoice.forced,
      allowedToolNames: ['get_weather'], // must be a bound tool
    ),
  );

  // Allow but don't require tools (the default with bound tools)
  final response3 = await modelWithTools.generate(
    messages,
    options: const ChatModelOptions(
      toolChoice: ToolChoice.allowed, // AUTO - model decides
    ),
  );

  // Disable tools
  final response4 = await modelWithTools.generate(
    messages,
    options: const ChatModelOptions(
      toolChoice: ToolChoice.forbidden, // NONE - no tool use
    ),
  );
  print([response, response2, response3, response4]);
}
