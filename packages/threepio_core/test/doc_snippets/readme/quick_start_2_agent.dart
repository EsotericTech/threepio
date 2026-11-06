// Mirror of the README quick start "2. An agent: adk.ChatModelAgent and adk.Runner".
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:threepio_core/adk.dart' as adk;
import 'package:threepio_core/threepio_core.dart';

/// The input of the tool, decoded from the JSON arguments the model writes.
final class WeatherQuery {
  const WeatherQuery(this.city);

  factory WeatherQuery.fromJson(Map<String, Object?> json) =>
      WeatherQuery(json['city']! as String);

  final String city;
}

Future<void> main() async {
  final model = OpenAIChatModel(
    config: OpenAIConfig(apiKey: Platform.environment['OPENAI_API_KEY']!),
  );

  // A tool from a typed function (Eino `utils.InferTool`; without reflection
  // the parameters and the decoder are written out).
  final weather = FunctionTool<WeatherQuery, String>(
    name: 'get_weather',
    description: 'The current weather in a city',
    params: const ParamsOneOf.params({
      'city': ParameterInfo(type: DataType.string, desc: 'City name', required: true),
    }),
    fromJson: WeatherQuery.fromJson,
    invoke: (ctx, query, options) => 'Sunny and 21 °C in ${query.city}',
  );

  // Eino `adk.NewChatModelAgent`: the model calls tools in a loop until it
  // answers.
  final agent = adk.ChatModelAgent(adk.ChatModelAgentConfig(
    name: 'assistant',
    description: 'Answers questions about the weather',
    instruction: 'You are a helpful assistant. Use the tools you have.',
    model: model,
    toolsConfig: adk.ToolsConfig(
      toolsNode: adk.ToolsNodeConfig(tools: [weather]),
    ),
  ));

  // Eino `adk.NewRunner` + `Runner.Query`: a pull stream of AgentEvents.
  final runner = adk.Runner(agent: agent);
  final events = runner.query(RunContext.background(), 'Weather in Lisbon?');
  for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
    if (e.error != null) {
      print('error: ${e.error}');
      break;
    }
    final message = await adk.getMessageFromEvent(e);
    if (message == null) continue;
    if (message.toolCalls?.isNotEmpty ?? false) {
      print('[calls ${message.toolCalls!.map((c) => c.function.name).join(', ')}]');
    } else {
      print('${message.role.name}: ${message.content}');
    }
  }

  model.dispose();
}
