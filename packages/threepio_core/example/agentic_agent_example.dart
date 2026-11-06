// ignore_for_file: avoid_print

/// An agent on the agentic path: content blocks instead of `Message`s.
///
/// **Beta**, as upstream. The agentic path speaks the model's own protocol:
/// an `AgenticMessage` is a list of content blocks (reasoning, text,
/// function tool calls and results, server-side and MCP tool calls the model
/// makes itself), so nothing the provider returns has to be squeezed into
/// the classic `Message`. Keep `Message` (the default path: `ChatModelAgent`,
/// `Runner`) unless you need model-native agentic protocols.
///
/// The example runs an [AgenticChatModelAgent] over an
/// `OpenAIResponsesModel` (OpenAI's Responses API) with one function tool,
/// through an [AgenticRunner], and prints the content blocks of every event
/// ([getAgenticMessageFromEvent]). The other agentic provider is
/// `ClaudeAgenticModel` (Anthropic's Messages API); any `AgenticModel` can be
/// passed to [runAgenticAgentExample].
///
/// Eino counterpart: `adk.NewTypedChatModelAgent[*schema.AgenticMessage]`
/// and `adk.NewTypedRunner` over eino-ext
/// `components/model/agenticopenai` (`NewResponsesModel`); eino-examples
/// `adk/agentic/research_assistant`.
///
/// Run it (this example builds its own `OpenAIResponsesModel` instead of
/// using `exampleChatModel()`):
///
/// ```bash
/// OPENAI_API_KEY=... dart run example/agentic_agent_example.dart
/// # Optional: OPENAI_RESPONSES_MODEL (default gpt-5-mini),
/// # OPENAI_BASE_URL (default https://api.openai.com/v1).
///
/// # Without OPENAI_API_KEY, OpenRouter's Responses endpoint (beta) is used:
/// OPENROUTER_API_KEY=... dart run example/agentic_agent_example.dart
/// # Optional: OPENROUTER_RESPONSES_MODEL (default openai/gpt-4o-mini).
/// ```
library;

import 'dart:io';

import 'package:threepio_core/adk.dart';
import 'package:threepio_core/threepio_core.dart'
    show OpenAIResponsesConfig, OpenAIResponsesModel;

/// What the example asks the agent.
const agenticExampleQuestion = 'What is the weather in Paris right now?';

Future<void> main() async {
  final env = Platform.environment;
  final openAIKey = env['OPENAI_API_KEY'] ?? '';
  final openRouterKey = env['OPENROUTER_API_KEY'] ?? '';
  final OpenAIResponsesConfig config;
  if (openAIKey.isNotEmpty) {
    config = OpenAIResponsesConfig(
      apiKey: openAIKey,
      baseUrl: env['OPENAI_BASE_URL'] ?? '',
      model: env['OPENAI_RESPONSES_MODEL'] ?? 'gpt-5-mini',
    );
  } else if (openRouterKey.isNotEmpty) {
    // OpenRouter's Responses endpoint takes the same requests.
    config = OpenAIResponsesConfig(
      apiKey: openRouterKey,
      baseUrl: 'https://openrouter.ai/api/v1',
      model: env['OPENROUTER_RESPONSES_MODEL'] ?? 'openai/gpt-4o-mini',
    );
  } else {
    stderr.writeln(
      'Set OPENAI_API_KEY or OPENROUTER_API_KEY to run this example (see the '
      'header of example/agentic_agent_example.dart).',
    );
    return;
  }

  // Go: agenticopenai.NewResponsesModel(ctx, &agenticopenai.ResponsesConfig{…}).
  final model = OpenAIResponsesModel(config: config);
  try {
    final answer = await runAgenticAgentExample(
      RunContext.background(),
      model: model,
      question: agenticExampleQuestion,
    );
    print('\nAnswer: $answer');
  } finally {
    model.dispose();
  }
}

/// The function tool of the example: the weather of a city (always the
/// same, so the example needs no weather service).
FunctionTool<Map<String, Object?>, String> weatherTool() => FunctionTool(
      name: 'get_weather',
      description: 'The current weather in a city.',
      params: const ParamsOneOf.params({
        'city': ParameterInfo(
          type: DataType.string,
          desc: 'The name of the city, e.g. "Paris".',
          required: true,
        ),
      }),
      fromJson: (json) => json,
      invoke: (ctx, input, options) => 'Sunny, 18 °C in ${input['city']}.',
    );

/// Asks an [AgenticChatModelAgent] over [model] the [question], printing the
/// content blocks of every event, and returns the text of its last answer.
///
/// With [streaming] the model's answers arrive as chunks; the events are
/// printed once each is complete (`getAgenticMessageFromEvent` joins them).
Future<String> runAgenticAgentExample(
  RunContext ctx, {
  required AgenticModel model,
  required String question,
  bool streaming = false,
}) async {
  // The agent: the classic ToolsConfig, with an agentic model (Go:
  // adk.NewTypedChatModelAgent(ctx, &adk.TypedChatModelAgentConfig{…})).
  final agent = AgenticChatModelAgent(
    AgenticChatModelAgentConfig(
      name: 'weather_agent',
      description: 'Answers questions about the weather.',
      instruction: 'You answer questions about the weather. Use get_weather '
          'to look the weather up, then answer in one sentence.',
      model: model,
      toolsConfig: ToolsConfig(
        toolsNode: ToolsNodeConfig(tools: [weatherTool()]),
      ),
    ),
  );

  // The runner (Go: adk.NewTypedRunner[*schema.AgenticMessage]).
  final runner = AgenticRunner(agent: agent, enableStreaming: streaming);
  print('User: $question');
  final events = runner.query(ctx, question);

  var answer = '';
  for (var event = await events.nextOrNull();
      event != null;
      event = await events.nextOrNull()) {
    final error = event.error;
    if (error != null) {
      Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
    }
    // One event per model call (role assistant) and per tool result (role
    // user, with a function_tool_result block).
    final message = await getAgenticMessageFromEvent(event);
    if (message == null) continue;
    print('\n[${event.agentName}] ${message.role.value}:');
    final texts = <String>[];
    for (final block in message.contentBlocks) {
      print('  ${describeContentBlock(block)}');
      if (block.assistantGenText case final text?) texts.add(text.text);
    }
    if (message.role == AgenticRoleType.assistant && texts.isNotEmpty) {
      answer = texts.join();
    }
  }
  return answer;
}

/// A one-line description of [block]: its type (Go's wire name) and what it
/// carries.
String describeContentBlock(ContentBlock block) {
  final type = block.type.value;
  return switch (block.content) {
    Reasoning(:final text) =>
      '$type: ${text.isEmpty ? '(no summary)' : text}',
    AssistantGenText(:final text) => '$type: $text',
    FunctionToolCall(:final name, :final arguments, :final callId) =>
      '$type: $name($arguments) [$callId]',
    FunctionToolResult(:final name, :final content, :final callId) =>
      '$type: $name -> ${content.map(_resultText).join(' ')} [$callId]',
    ServerToolCall(:final name) => '$type: $name',
    ServerToolResult(:final name) => '$type: $name',
    AgenticMcpToolCall(:final serverLabel, :final name, :final arguments) =>
      '$type: $serverLabel/$name($arguments)',
    AgenticMcpToolResult(:final serverLabel, :final name, :final content) =>
      '$type: $serverLabel/$name -> $content',
    UserInputText(:final text) => '$type: $text',
    _ => type,
  };
}

String _resultText(FunctionToolResultContentBlock part) =>
    switch (part.content) {
      UserInputText(:final text) => text,
      final other => other.blockType.value,
    };
