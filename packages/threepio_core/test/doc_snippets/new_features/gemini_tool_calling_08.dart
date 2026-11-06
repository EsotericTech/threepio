// Mirror of doc/NEW_FEATURES.md, section 1, "### Tool/Function Calling".
// Keep in step with the document: test/unit/docs/doc_snippets_test.dart
// checks that the block below appears here unchanged.
// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:threepio_core/threepio_core.dart';

Future<void> toolCalling(GeminiChatModel model) async {
  // Define tools
  final weatherTool = ToolInfo.simple(
    name: 'get_weather',
    description: 'Get the current weather for a location',
    properties: {
      'location': JSONSchemaProperty.string(
        description: 'City name, e.g., "San Francisco"',
      ),
      'unit': JSONSchemaProperty.string(
        description: 'Temperature unit',
        enumValues: ['celsius', 'fahrenheit'],
      ),
    },
    required: ['location'],
  );

  // Bind tools to model (the tool choice becomes ToolChoice.allowed)
  final modelWithTools = model.withTools([weatherTool]);

  // Generate - model may request tool calls
  final question = Message.user('What is the weather in Tokyo?');
  final response = await modelWithTools.generate([question]);

  // Check if model wants to call tools
  final toolCalls = response.toolCalls ?? <ToolCall>[];
  if (toolCalls.isNotEmpty) {
    final toolResults = <Message>[];
    for (final toolCall in toolCalls) {
      print('Tool: ${toolCall.function.name}');
      print('Arguments: ${toolCall.function.arguments}');

      // Execute the tool (call your weather service here)
      final args =
          jsonDecode(toolCall.function.arguments) as Map<String, Object?>;
      final result = {'location': args['location'], 'temperature': 18};

      toolResults.add(
        Message.tool(
          content: jsonEncode(result),
          toolCallId: toolCall.id,
          toolName: toolCall.function.name, // Gemini matches results by name
        ),
      );
    }

    // Continue the conversation with one result per tool call
    final finalResponse = await modelWithTools.generate([
      question,
      response, // Assistant message with tool calls
      ...toolResults,
    ]);

    print(finalResponse.content);
  }
}
