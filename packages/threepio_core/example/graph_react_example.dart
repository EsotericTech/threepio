// ignore_for_file: avoid_print

/// A ReAct agent built by hand from a compose [Graph]: the model calls tools
/// until it can answer.
///
/// It has the shape of Eino's `flow/agent/react` (`react.NewAgent`, file
/// `eino/flow/agent/react/react.go`), written out step by step:
///
/// * a graph with a local state (`LocalState.of`, Go
///   `compose.WithGenLocalState`) that keeps the message history of a run;
/// * state pre-handlers (`StateHandler.pre`, Go `compose.WithStatePreHandler`)
///   that add what arrives at the model and at the tools node to that
///   history;
/// * a chat model node, the model bound to the tools with `withTools` (Go
///   `ToolCallingChatModel.WithTools`);
/// * a branch behind the model (`GraphBranch.stream`, Go
///   `compose.NewStreamGraphBranch`): tool calls go to the `ToolsNode`, whose
///   results go back to the model; an answer without tool calls ends the run;
/// * tools made from typed functions with `FunctionTool` (Go
///   `utils.InferTool`);
/// * the compiled graph run with `invoke` and with `stream`, a step limit
///   (`GraphCompileOptions.maxRunSteps`, Go `compose.WithMaxRunSteps`), and
///   the graph drawn with `toMermaid()`.
///
/// threepio does not port `flow/agent/react` itself: as Eino recommends, a
/// ready-made agent is the ADK's `ChatModelAgent` (`adk.dart`). This example
/// shows what such an agent is made of.
///
/// Run it with an OpenRouter or OpenAI key (see `example/README.md`):
///
/// ```bash
/// OPENROUTER_API_KEY=... dart run example/graph_react_example.dart
/// ```
library;

import 'package:threepio_core/compose.dart';

import 'support/example_model.dart';

/// The key of the chat model node (Go: `nodeKeyModel`).
const nodeKeyModel = 'chat';

/// The key of the tools node (Go: `nodeKeyTools`).
const nodeKeyTools = 'tools';

/// The state of one run: the conversation so far.
///
/// Go: the `state` struct of `flow/agent/react`, without its `ReturnDirectlyToolCallID`.
final class ReActState {
  /// The messages the model has been given and has written, in order.
  final List<Message> messages = [];
}

/// The arguments of `get_weather`.
///
/// Go's `utils.InferTool` reads the parameters from the struct tags of such
/// a type. Dart has no reflection: [newWeatherTool] gives the parameters and
/// this `fromJson` explicitly.
final class WeatherQuery {
  /// The weather of [city].
  const WeatherQuery({required this.city});

  /// Reads the arguments the model wrote.
  factory WeatherQuery.fromJson(Map<String, Object?> json) =>
      WeatherQuery(city: json['city']! as String);

  /// The city to look up.
  final String city;
}

/// Made-up weather data, so that the example needs no weather service.
const _weather = {
  'paris': (temperature: 12, conditions: 'light rain'),
  'cairo': (temperature: 31, conditions: 'sunny'),
};

/// A tool that looks up the weather of a city. Go: `utils.InferTool`.
FunctionTool<WeatherQuery, Map<String, Object?>> newWeatherTool() =>
    FunctionTool<WeatherQuery, Map<String, Object?>>(
      name: 'get_weather',
      description: 'The current weather in a city',
      params: const ParamsOneOf.params({
        'city': ParameterInfo(
          type: DataType.string,
          desc: 'The name of the city, for example "Paris"',
          required: true,
        ),
      }),
      fromJson: WeatherQuery.fromJson,
      // What the function returns is sent to the model as JSON.
      invoke: (ctx, query, options) {
        final weather = _weather[query.city.toLowerCase()];
        if (weather == null) {
          return {'city': query.city, 'error': 'no weather data'};
        }
        return {
          'city': query.city,
          'temperature_c': weather.temperature,
          'conditions': weather.conditions,
        };
      },
    );

/// A tool that recommends clothes for a temperature. Its input is a plain
/// `double`: the input type of a [FunctionTool] can be anything `fromJson`
/// builds.
FunctionTool<double, String> newClothingTool() => FunctionTool<double, String>(
      name: 'recommend_clothing',
      description: 'What to wear at a temperature in degrees Celsius',
      params: const ParamsOneOf.params({
        'temperature_c': ParameterInfo(
          type: DataType.number,
          desc: 'The temperature in degrees Celsius',
          required: true,
        ),
      }),
      fromJson: (json) => (json['temperature_c']! as num).toDouble(),
      // A String result is sent to the model as it is.
      invoke: (ctx, celsius, options) => switch (celsius) {
        < 10 => 'a warm coat, a scarf and gloves',
        < 20 => 'a light jacket or a sweater, and an umbrella if it rains',
        _ => 'a t-shirt, light trousers and sunscreen',
      },
    );

/// Decides where the run goes after the model: to the tools when the model
/// called any, otherwise to the end.
///
/// Go: `modelPostBranchCondition` with a custom `StreamToolCallChecker`. A
/// stream condition sees the model's output as it arrives. Some models write
/// text before their tool calls, so it reads until it finds a chunk with tool
/// calls or the stream ends. A stream condition must close the stream it is
/// given.
///
/// The price: for an answer without tool calls it reads the whole answer,
/// and the graph hands the answer on only once the branch has chosen, so a
/// streamed run delivers the final answer after the model has finished it.
/// Eino's default checker (`firstChunkStreamToolCallChecker`) decides at the
/// first chunk with content instead: the answer streams live, but tool calls
/// written after text are missed.
Future<String> routeAfterModel(
  RunContext ctx,
  StreamReader<Message> output,
) async {
  try {
    await for (final chunk in output.asStream()) {
      if (chunk.toolCalls?.isNotEmpty ?? false) return nodeKeyTools;
    }
    return Graph.end;
  } finally {
    await output.close();
  }
}

/// The ReAct graph for [model] and [tools], not compiled yet.
///
/// Go: the body of `react.NewAgent` without its options and extras: no
/// message modifier or rewriter, no tools that return directly (the
/// `direct_return` node, the branch behind the tools node and
/// `ReturnDirectlyToolCallID`), no tool-result senders, and no resume path
/// for an interrupted tools node (`toolsNodePreHandle`'s `nil` input).
Future<Graph<List<Message>, Message>> newReActGraph(
  RunContext ctx,
  ToolCallingChatModel model,
  List<BaseTool> tools,
) async {
  // Go: genToolInfos and agent.ChatModelWithTools. withTools returns a copy
  // of the model with the tools bound; the model itself is not changed.
  final toolInfos = [for (final tool in tools) await tool.info()];
  final chatModel = model.withTools(toolInfos);

  // Go: compose.NewToolNode. create asks every tool for its info now, so a
  // broken tool is reported here rather than on the first call.
  final toolsNode = await ToolsNode.create(
    ToolsNodeConfig(tools: tools),
    ctx: ctx,
  );

  return Graph<List<Message>, Message>(
    // Go: compose.WithGenLocalState. A new ReActState for every run.
    localState: LocalState.of<ReActState>((ctx) => ReActState()),
  )
    ..addChatModelNode(
      nodeKeyModel,
      chatModel,
      options: NodeOptions(
        name: 'ChatModel',
        // Go: modelPreHandle. What arrives (the user's messages, later the
        // tool results) joins the history, and the model gets all of it.
        statePreHandler: StateHandler.pre<List<Message>, ReActState>(
          (ctx, input, state) {
            state.messages.addAll(input);
            return List.of(state.messages);
          },
        ),
      ),
    )
    ..addToolsNode(
      nodeKeyTools,
      toolsNode,
      options: NodeOptions(
        name: 'Tools',
        // Go: toolsNodePreHandle. The assistant message with the tool calls
        // joins the history before the tools run.
        statePreHandler: StateHandler.pre<Message, ReActState>(
          (ctx, input, state) {
            state.messages.add(input);
            return input;
          },
        ),
      ),
    )
    ..addEdge(Graph.start, nodeKeyModel)
    ..addBranch(
      nodeKeyModel,
      GraphBranch.stream<Message>(routeAfterModel, {nodeKeyTools, Graph.end}),
    )
    // The loop: the tool results go back to the model.
    ..addEdge(nodeKeyTools, nodeKeyModel);
}

/// Compiles the ReAct graph.
///
/// Every model call and every tools call is a step. A model that keeps
/// calling tools fails the run after [maxRunSteps] steps with a
/// `GraphRunException` whose cause is an `ExceedMaxStepsException` (Go:
/// `compose.ErrExceedMaxSteps`). Eino's ReAct agent allows the number of
/// nodes plus ten, which is 12 here.
Future<Runnable<List<Message>, Message>> compileReActAgent(
  RunContext ctx,
  Graph<List<Message>, Message> graph, {
  int maxRunSteps = 12,
}) =>
    graph.compile(
      ctx,
      options: GraphCompileOptions(
        graphName: 'ReActAgent',
        maxRunSteps: maxRunSteps,
      ),
    );

/// Asks [agent] a [question] and waits for the whole answer. Go:
/// `Runnable.Invoke` (`Agent.Generate`).
Future<Message> ask(
  RunContext ctx,
  Runnable<List<Message>, Message> agent,
  String question,
) =>
    agent.invoke(ctx, [Message.user(question)]);

/// Asks [agent] a [question] and prints the answer chunk by chunk. Go:
/// `Runnable.Stream` (`Agent.Stream`). Returns the chunks.
///
/// Only the last model turn reaches the output: the turns with tool calls
/// went to the tools node. Because [routeAfterModel] reads that turn to its
/// end before it chooses END, its chunks arrive once the model has finished
/// writing it.
Future<List<Message>> askStreaming(
  RunContext ctx,
  Runnable<List<Message>, Message> agent,
  String question,
) async {
  final reader = await agent.stream(ctx, [Message.user(question)]);
  final chunks = <Message>[];
  // asStream closes the reader when the loop ends.
  await for (final chunk in reader.asStream()) {
    print('  chunk[${chunks.length}]: ${chunk.content}');
    chunks.add(chunk);
  }
  return chunks;
}

/// Builds the agent with the two tools of this file, draws it, and asks it
/// two questions: once with `invoke`, once with `stream`.
Future<void> runReActExample(ToolCallingChatModel model) async {
  final ctx = RunContext.background();

  final graph = await newReActGraph(
    ctx,
    model,
    [newWeatherTool(), newClothingTool()],
  );

  print('=== The graph (Mermaid) ===');
  print(graph.toMermaid());

  final agent = await compileReActAgent(ctx, graph);

  print('\n=== invoke ===');
  final answer = await ask(ctx, agent, 'What should I wear in Paris today?');
  print(answer.content);

  print('\n=== stream ===');
  final chunks = await askStreaming(
    ctx,
    agent,
    'What should I wear in Cairo today?',
  );
  print(concatMessages(chunks).content);
}

Future<void> main() async {
  final model = exampleChatModel();
  if (model == null) return;
  try {
    await runReActExample(model);
  } finally {
    closeExampleModel(model);
  }
}
