// Port of the eino-examples flow `adk/multiagent/plan-execute-replan/`
// (plan-execute-replan.go, agent/agent.go, tools/travel_tools.go,
// tools/ask_for_clarification.go): a travel-research plan-execute-replan
// agent run to its final answer.
//
// The example talks to a real model; here three ScriptedChatModels (planner,
// executor, replanner, each with its own script) play the models. The agent
// is rebuilt as agent/agent.go builds it: `NewPlanner` with a tool-calling
// model, `NewExecutor` with the example's own executor prompt, `formatInput`
// (only the first message), numbered `formatExecutedSteps` and the five tools
// of `tools.GetAllTravelTools` (same names, descriptions and deterministic
// outputs, including the FNV-1a `consistentHashing`), `NewReplanAgent` with
// the defaults, `planexecute.New` with `MaxIterations: 20`, and a Runner
// without streaming or checkpoint store, as main does. main's loop keeps the
// message of the last event with output; so does the test.
//
// `ask_for_clarification` does not interrupt: the example's tool prints the
// question and blocks on stdin until the user types an answer, which becomes
// the tool's result. The Dart tool blocks on a Completer the test completes
// with the user's answer once the question was asked, so there is no
// interrupt/resume to port. Not ported: the CozeLoop tracing
// (`trace.AppendCozeLoopCallbackIfConfigured`, off unless configured), the
// final 5 s sleep for spans, and the printing of events.
//
// Intended deviation (P9 brief): the loop's break action is stripped (the run
// ends after the replanner's respond event, no event with a `LoopBreak`).
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/plan.dart'
    show DefaultPlan;

import '../../support/scripted_chat_model.dart';

// plan-execute-replan.go's query, verbatim.
const _query = 'Plan a 3-day trip to Beijing in Next Month. I need flights from New York, '
    'hotel recommendations, and must-see attractions.\n'
    'Today is 2025-09-09.';

// agent/agent.go's executorPrompt, verbatim (the clarification line ends with
// a quote, "which is: " with a space).
const _executorSystem =
    'You are a diligent and meticulous travel research executor, Follow the given plan and execute your tasks carefully and thoroughly.\n'
    'Execute each planning step by using available tools.\n'
    'For weather queries, use get_weather tool.\n'
    'For flight searches, use search_flights tool.\n'
    'For hotel searches, use search_hotels tool.\n'
    'For attraction research, use search_attractions tool.\n'
    "For user's clarification, use ask_for_clarification tool. In summary, repeat the questions and results to confirm with the user, try to avoid disturbing users'\n"
    'Provide detailed results for each task.\n'
    'Cloud Call multiple tools to get the final result.';
const _executorUserTemplate = '## OBJECTIVE\n'
    '{input}\n'
    '## Given the following plan:\n'
    '{plan}\n'
    '## COMPLETED STEPS & RESULTS\n'
    '{executed_steps}\n'
    '## Your task is to execute the first step, which is: \n'
    '{step}';

final _executorPrompt = ChatTemplate.fromMessages(FormatType.fString, [
  Message.system(_executorSystem),
  Message.user(_executorUserTemplate),
]);

/// agent/agent.go `formatInput`: only the first message.
String _formatInput(List<Message> input) => input[0].content;

/// agent/agent.go `formatExecutedSteps`: numbered, the result indented.
String _formatExecutedSteps(List<ExecutedStep> steps) {
  final sb = StringBuffer();
  for (var i = 0; i < steps.length; i++) {
    sb.write('## ${i + 1}. Step: ${steps[i].step}\n  Result: ${steps[i].result}\n\n');
  }
  return sb.toString();
}

// ---------------------------------------------------------------------------
// tools/travel_tools.go

/// travel_tools.go `consistentHashing`: FNV-1a (32 bit) of [s], mapped to
/// [min]..[max].
int _consistentHashing(String s, int min, int max) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(s)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return min + hash % (max - min + 1);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// A Go `float64` as Go's JSON writes it: an integral value without `.0`.
num _goFloat(double v) => v == v.truncateToDouble() ? v.toInt() : v;

String _str(Map<String, Object?> args, String key) => args[key] as String? ?? '';

/// `get_weather`'s output (travel_tools.go `NewWeatherTool`).
String _weather(Map<String, Object?> args) {
  final city = _str(args, 'city');
  final date = _str(args, 'date');
  if (city.isEmpty) {
    return jsonEncode({'city': '', 'temperature': 0, 'condition': '', 'date': '', 'error': 'City is required'});
  }
  const known = {
    'Beijing': (15, 'Sunny'),
    'Shanghai': (20, 'Cloudy'),
    'Tokyo': (18, 'Rainy'),
    'Paris': (12, 'Overcast'),
    'New York': (8, 'Snow'),
  };
  final hit = known[city];
  if (hit != null) {
    return jsonEncode({'city': city, 'temperature': hit.$1, 'condition': hit.$2, 'date': date});
  }
  const conditions = ['Sunny', 'Cloudy', 'Rainy', 'Overcast'];
  final hashInput = city + date;
  return jsonEncode({
    'city': city,
    'temperature': _consistentHashing('${hashInput}temp', 5, 35),
    'condition': conditions[_consistentHashing('${hashInput}cond', 0, conditions.length - 1)],
    'date': date,
  });
}

/// `search_flights`'s output (travel_tools.go `NewFlightSearchTool`).
String _flights(Map<String, Object?> args) {
  final from = _str(args, 'from');
  final to = _str(args, 'to');
  final date = _str(args, 'date');
  if (from.isEmpty || to.isEmpty) {
    return jsonEncode({'flights': null, 'error': 'From and To cities are required'});
  }
  const airlines = ['Air China', 'China Eastern', 'China Southern', 'United Airlines', 'Delta'];
  final hashInput = from + to + date;
  final flights = <Map<String, Object?>>[];
  for (var i = 0; i < 3; i++) {
    final flightHash = '$hashInput$i';
    final airline = airlines[_consistentHashing('${flightHash}airline', 0, airlines.length - 1)];
    final depHour = _consistentHashing('${flightHash}dephour', 0, 23);
    final depMin = _consistentHashing('${flightHash}depmin', 0, 59);
    final arrHour = _consistentHashing('${flightHash}arrhour', 0, 23);
    final arrMin = _consistentHashing('${flightHash}arrmin', 0, 59);
    final depTotal = depHour * 60 + depMin;
    var arrTotal = arrHour * 60 + arrMin;
    if (arrTotal <= depTotal) arrTotal += 24 * 60;
    final duration = arrTotal - depTotal;
    flights.add({
      'airline': airline,
      'flight_no': '${airline.substring(0, 2)}${_consistentHashing('${flightHash}flightno', 1000, 9999)}',
      'departure': '${_two(depHour)}:${_two(depMin)}',
      'arrival': '${_two(arrHour)}:${_two(arrMin)}',
      'price': _consistentHashing('${flightHash}price', 500, 2500),
      'duration': '${duration ~/ 60}h ${duration % 60}m',
    });
  }
  return jsonEncode({'flights': flights});
}

/// `search_hotels`'s output (travel_tools.go `NewHotelSearchTool`).
String _hotels(Map<String, Object?> args) {
  final city = _str(args, 'city');
  if (city.isEmpty) return jsonEncode({'hotels': null, 'error': 'City is required'});
  const hotelNames = ['Grand Hotel', 'City Center Inn', 'Luxury Resort', 'Budget Lodge', 'Business Hotel'];
  const amenities = [
    ['WiFi', 'Pool', 'Gym', 'Spa'],
    ['WiFi', 'Breakfast', 'Parking'],
    ['WiFi', 'Pool', 'Restaurant', 'Bar', 'Concierge'],
    ['WiFi', 'Breakfast'],
    ['WiFi', 'Business Center', 'Meeting Rooms'],
  ];
  final hashInput = city + _str(args, 'check_in') + _str(args, 'check_out');
  return jsonEncode({
    'hotels': [
      for (var i = 0; i < 4; i++)
        {
          'name': '$city ${hotelNames[_consistentHashing('$hashInput${i}name', 0, hotelNames.length - 1)]}',
          'rating': _goFloat(_consistentHashing('$hashInput${i}rating', 20, 50) / 10.0),
          'price': _consistentHashing('$hashInput${i}price', 50, 350),
          'location': '$city Downtown',
          'amenities': amenities[_consistentHashing('$hashInput${i}amenities', 0, amenities.length - 1)],
        },
    ],
  });
}

Map<String, Object?> _attraction(
  String name,
  String description,
  double rating,
  String openHours,
  int ticketPrice,
  String category,
) =>
    {
      'name': name,
      'description': description,
      'rating': _goFloat(rating),
      'open_hours': openHours,
      'ticket_price': ticketPrice,
      'category': category,
    };

/// `search_attractions`'s output (travel_tools.go
/// `NewAttractionSearchTool`).
String _attractions(Map<String, Object?> args) {
  final city = _str(args, 'city');
  final category = _str(args, 'category');
  if (city.isEmpty) return jsonEncode({'attractions': null, 'error': 'City is required'});
  final byCity = {
    'Beijing': [
      _attraction('Forbidden City', 'Ancient imperial palace', 4.8, '8:30-17:00', 60, 'historic site'),
      _attraction('Great Wall', 'Historic fortification', 4.9, '6:00-18:00', 45, 'landmark'),
      _attraction('Temple of Heaven', 'Imperial sacrificial altar', 4.6, '6:00-22:00', 35, 'park'),
    ],
    'Paris': [
      _attraction('Eiffel Tower', 'Iconic iron lattice tower', 4.7, '9:30-23:45', 25, 'landmark'),
      _attraction('Louvre Museum', "World's largest art museum", 4.8, '9:00-18:00', 17, 'museum'),
      _attraction('Notre-Dame Cathedral', 'Medieval Catholic cathedral', 4.5, '8:00-18:45', 0, 'landmark'),
    ],
    'Tokyo': [
      _attraction('Senso-ji Temple', 'Ancient Buddhist temple', 4.4, '6:00-17:00', 0, 'landmark'),
      _attraction('Tokyo National Museum', 'Largest collection of cultural artifacts', 4.3, '9:30-17:00', 1000, 'museum'),
      _attraction('Ueno Park', 'Large public park with museums', 4.2, '5:00-23:00', 0, 'park'),
    ],
  };
  final attractions = byCity[city];
  if (attractions != null) {
    if (category.isNotEmpty) {
      final filtered = [for (final a in attractions) if (a['category'] == category) a];
      // Go's nil slice of no match marshals as null.
      return jsonEncode({'attractions': filtered.isEmpty ? null : filtered});
    }
    return jsonEncode({'attractions': attractions});
  }
  const names = ['Central Museum', 'City Park', 'Historic Square', 'Art Gallery', 'Cultural Center'];
  const categories = ['museum', 'park', 'landmark', 'historic site', 'cultural'];
  final hashInput = city + category;
  return jsonEncode({
    'attractions': [
      for (var i = 0; i < 3; i++)
        {
          'name': '$city ${names[_consistentHashing('$hashInput${i}name', 0, names.length - 1)]}',
          'description': 'Popular tourist attraction',
          'rating': _goFloat(_consistentHashing('$hashInput${i}rating', 30, 50) / 10.0),
          'open_hours': '9:00-17:00',
          'ticket_price': _consistentHashing('$hashInput${i}price', 0, 50),
          'category': categories[_consistentHashing('$hashInput${i}category', 0, categories.length - 1)],
        },
    ],
  });
}

/// A travel_tools.go tool (`utils.InferTool` over a request struct): its
/// name, description, the request fields with their `jsonschema_description`
/// and the deterministic output. Records the arguments of every call.
final class _TravelTool extends InvokableTool {
  _TravelTool(this.toolName, this.desc, this.params, this.output);

  final String toolName;
  final String desc;
  final Map<String, ParameterInfo> params;
  final String Function(Map<String, Object?> args) output;

  /// The arguments of every call, as JSON.
  final List<String> calls = [];

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: toolName, desc: desc, params: params);

  @override
  Future<String> invokableRun(RunContext ctx, String argumentsJson, {ToolOptions? options}) async {
    calls.add(argumentsJson);
    return output(jsonDecode(argumentsJson) as Map<String, Object?>);
  }
}

/// tools/ask_for_clarification.go: prints the question and returns what the
/// user types (`utils.InferOptionableTool`; a string result is returned
/// as is). The user's typing is [answer], which the test completes; [asked]
/// completes with the question when the tool blocks.
final class _AskForClarification extends InvokableTool {
  final Completer<String> asked = Completer();
  final Completer<String> answer = Completer();

  /// The arguments of every call, as JSON.
  final List<String> calls = [];

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'ask_for_clarification',
        desc: "Call this tool when the user's request is ambiguous or lacks the necessary information to "
            'proceed. Use it to ask a follow-up question to get the details you need, such as the '
            "book's genre, before you can use other tools effectively.",
        params: const {
          'question': ParameterInfo(
            type: DataType.string,
            desc: 'The specific question you want to ask the user to get the missing information',
          ),
        },
      );

  @override
  Future<String> invokableRun(RunContext ctx, String argumentsJson, {ToolOptions? options}) async {
    calls.add(argumentsJson);
    final input = jsonDecode(argumentsJson) as Map<String, Object?>;
    asked.complete(_str(input, 'question'));
    return answer.future;
  }
}

ParameterInfo _s(String desc) => ParameterInfo(type: DataType.string, desc: desc);
ParameterInfo _i(String desc) => ParameterInfo(type: DataType.integer, desc: desc);

/// The five tools of tools.go `GetAllTravelTools`.
final class _TravelTools {
  final weather = _TravelTool(
    'get_weather',
    'Get weather information for a specific city and date',
    {'city': _s('City name to get weather for'), 'date': _s('Date in YYYY-MM-DD format (optional)')},
    _weather,
  );
  final flights = _TravelTool(
    'search_flights',
    'Search for flights between cities',
    {
      'from': _s('Departure city'),
      'to': _s('Destination city'),
      'date': _s('Departure date in YYYY-MM-DD format'),
      'passengers': _i('Number of passengers'),
    },
    _flights,
  );
  final hotels = _TravelTool(
    'search_hotels',
    'Search for hotels in a city',
    {
      'city': _s('City to search hotels in'),
      'check_in': _s('Check-in date in YYYY-MM-DD format'),
      'check_out': _s('Check-out date in YYYY-MM-DD format'),
      'guests': _i('Number of guests'),
    },
    _hotels,
  );
  final attractions = _TravelTool(
    'search_attractions',
    'Search for tourist attractions in a city',
    {
      'city': _s('City to search attractions in'),
      'category': _s('Category of attractions (museum, park, landmark, historic site, etc.)'),
    },
    _attractions,
  );
  final ask = _AskForClarification();

  List<BaseTool> get all => [weather, flights, hotels, attractions, ask];
}

// ---------------------------------------------------------------------------
// agent/agent.go and main

/// What the example's executor `GenInputFn` was called with, recorded by the
/// test (the recording changes nothing).
final class _ExecutorInputs {
  final List<ExecutionContext> contexts = [];
  final List<Map<String, Object?>> sessionValues = [];
}

/// main's `planexecute.New` over agent.go's `NewPlanner`, `NewExecutor` and
/// `NewReplanAgent`, with the three scripted models.
Future<ResumableAgent> _entryAgent({
  required ScriptedChatModel plannerModel,
  required ScriptedChatModel executorModel,
  required ScriptedChatModel replannerModel,
  required _TravelTools tools,
  required _ExecutorInputs inputs,
}) async {
  final ctx = RunContext.background();
  final planAgent = await PlanExecute.planner(ctx, PlannerConfig(toolCallingChatModel: plannerModel));
  final executeAgent = await PlanExecute.executor(
    ctx,
    ExecutorConfig(
      model: executorModel,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools.all)),
      genInput: (ctx, input) async {
        inputs.contexts.add(input);
        inputs.sessionValues.add(ctx.sessionValues);
        final planContent = jsonEncode(input.plan.toJson());
        final firstStep = input.plan.firstStep();
        return _executorPrompt.format(
          {
            'input': _formatInput(input.userInput),
            'plan': planContent,
            'executed_steps': _formatExecutedSteps(input.executedSteps),
            'step': firstStep,
          },
          options: ChatTemplateOptions(runContext: ctx),
        );
      },
    ),
  );
  final replanAgent = await PlanExecute.replanner(ctx, ReplannerConfig(chatModel: replannerModel));
  return PlanExecute.create(
    ctx,
    PlanExecuteLoopConfig(
      planner: planAgent,
      executor: executeAgent,
      replanner: replanAgent,
      maxIterations: 20,
    ),
  );
}

// ---------------------------------------------------------------------------
// The scripted run

const _step1 = 'Ask the user for the exact travel dates next month and the number of travelers';
const _step2 = 'Search flights from New York to Beijing and hotels in Beijing for the confirmed dates';
const _step3 = 'Research must-see attractions in Beijing and the weather during the stay';

String _planJson(List<String> steps) => jsonEncode({'steps': steps});

const _question = 'Which dates in October 2025 will you travel, and how many travelers?';
const _userAnswer = 'From 2025-10-10 to 2025-10-13, just me.';
const _askArgs = '{"question":"$_question"}';
const _flightsArgs = '{"from":"New York","to":"Beijing","date":"2025-10-10","passengers":1}';
const _hotelsArgs = '{"city":"Beijing","check_in":"2025-10-10","check_out":"2025-10-13","guests":1}';
const _attractionsArgs = '{"city":"Beijing"}';
const _weatherArgs = '{"city":"Beijing","date":"2025-10-10"}';

const _clarified = 'The user travels alone from 2025-10-10 to 2025-10-13.';
const _searched = 'Found three flights from New York to Beijing on 2025-10-10 and four hotels in Beijing.';
const _researched = 'Beijing will be sunny at 15 degrees; must-see: Forbidden City, Great Wall, '
    'Temple of Heaven.';
const _finalAnswer = 'Your 3-day Beijing trip (2025-10-10 to 2025-10-13): fly from New York, stay '
    'downtown, and visit the Forbidden City, the Great Wall and the Temple of Heaven.';
final _respondArgs = jsonEncode({'response': _finalAnswer});

/// The executor's user message: agent.go's prompt with `formatInput` = the
/// query and the example's numbered steps.
String _executorUser(List<String> plan, String executedSteps, String step) => '## OBJECTIVE\n'
    '$_query\n'
    '## Given the following plan:\n'
    '${_planJson(plan)}\n'
    '## COMPLETED STEPS & RESULTS\n'
    '$executedSteps\n'
    '## Your task is to execute the first step, which is: \n'
    '$step';

/// The replanner's user message: eino's default `ReplannerPrompt`,
/// `formatInput` and `formatExecutedSteps` (NewReplanAgent keeps them).
String _replannerUser(List<String> plan, List<(String, String)> executed) => '## OBJECTIVE\n'
    '$_query\n'
    '\n\n## ORIGINAL PLAN\n'
    '${_planJson(plan)}\n'
    '\n## COMPLETED STEPS & RESULTS\n'
    '${executed.map((s) => 'Step: ${s.$1}\nResult: ${s.$2}\n\n').join()}';

/// An output event, flattened (the tool calls as `id:name:arguments`,
/// joined by ` | `).
typedef _Out = ({String agent, RoleType? role, String content, String toolName, String toolCalls});

_Out _assistant(String agent, String content, [List<String> toolCalls = const []]) =>
    (agent: agent, role: RoleType.assistant, content: content, toolName: '', toolCalls: toolCalls.join(' | '));

_Out _tool(String name, String content) =>
    (agent: 'executor', role: RoleType.tool, content: content, toolName: name, toolCalls: '');

List<(String, String)> _messages(ScriptedCall call) => [for (final m in call.messages) (m.role.name, m.content)];

void main() {
  group('multiagent/plan-execute-replan', () {
    late ScriptedChatModel plannerModel;
    late ScriptedChatModel executorModel;
    late ScriptedChatModel replannerModel;
    late _TravelTools tools;
    late _ExecutorInputs inputs;
    late Runner runner;

    setUp(() async {
      plannerModel = ScriptedChatModel([
        [toolCallDelta(0, id: 'plan_1', name: 'plan', args: _planJson([_step1, _step2, _step3])), finish('tool_calls')],
      ]);
      executorModel = ScriptedChatModel([
        [toolCallDelta(0, id: 'call_ask', name: 'ask_for_clarification', args: _askArgs), finish('tool_calls')],
        [text(_clarified), finish('stop')],
        [
          toolCallDelta(0, id: 'call_flights', name: 'search_flights', args: _flightsArgs),
          toolCallDelta(1, id: 'call_hotels', name: 'search_hotels', args: _hotelsArgs),
          finish('tool_calls'),
        ],
        [text(_searched), finish('stop')],
        [
          toolCallDelta(0, id: 'call_attractions', name: 'search_attractions', args: _attractionsArgs),
          toolCallDelta(1, id: 'call_weather', name: 'get_weather', args: _weatherArgs),
          finish('tool_calls'),
        ],
        [text(_researched), finish('stop')],
      ]);
      replannerModel = ScriptedChatModel([
        [toolCallDelta(0, id: 'replan_1', name: 'plan', args: _planJson([_step2, _step3])), finish('tool_calls')],
        [toolCallDelta(0, id: 'replan_2', name: 'plan', args: _planJson([_step3])), finish('tool_calls')],
        [toolCallDelta(0, id: 'respond_1', name: 'respond', args: _respondArgs), finish('tool_calls')],
      ]);
      tools = _TravelTools();
      inputs = _ExecutorInputs();
      // main: `adk.NewRunner(ctx, adk.RunnerConfig{Agent: entryAgent})`.
      runner = Runner(
        agent: await _entryAgent(
          plannerModel: plannerModel,
          executorModel: executorModel,
          replannerModel: replannerModel,
          tools: tools,
          inputs: inputs,
        ),
      );
    });

    test('main: plan, ask for clarification, research, respond', () async {
      // main's loop: every event, and the message of the last one with output.
      final events = <AgentEvent>[];
      Message? lastMessage;
      final done = () async {
        final iter = runner.query(RunContext.background(), _query);
        for (var event = await iter.nextOrNull(); event != null; event = await iter.nextOrNull()) {
          events.add(event);
          if (event.output != null) lastMessage = await getMessageFromEvent(event);
        }
      }();

      // The executor's first step asks the user; the tool blocks on "stdin".
      final question = await Future.any([
        tools.ask.asked.future,
        done.then<String>((_) => throw StateError('the run ended without asking: $events')),
      ]);
      expect(question, _question);
      expect(executorModel.calls, hasLength(1), reason: 'the run waits for the answer');
      expect(replannerModel.calls, isEmpty);
      tools.ask.answer.complete(_userAnswer);
      await done;

      expect(events.map((e) => e.error), everyElement(isNull), reason: '$events');
      expect(events.map((e) => e.action), everyElement(isNull), reason: 'no interrupt, no break action reaches main');
      final outputs = <_Out>[
        for (final event in events)
          await () async {
            final variant = event.output!.messageOutput!;
            expect(variant.isStreaming, isFalse, reason: 'the runner does not stream');
            final m = await variant.getMessage();
            return (
              agent: event.agentName,
              role: m.role,
              content: m.content,
              toolName: variant.toolName,
              toolCalls: [
                for (final c in m.toolCalls ?? const <ToolCall>[]) '${c.id}:${c.function.name}:${c.function.arguments}',
              ].join(' | '),
            );
          }(),
      ];
      expect(outputs, [
        _assistant('planner', _planJson([_step1, _step2, _step3])),
        _assistant('executor', '', ['call_ask:ask_for_clarification:$_askArgs']),
        _tool('ask_for_clarification', _userAnswer),
        _assistant('executor', _clarified),
        _assistant('replanner', _planJson([_step2, _step3])),
        _assistant('executor', '', [
          'call_flights:search_flights:$_flightsArgs',
          'call_hotels:search_hotels:$_hotelsArgs',
        ]),
        _tool('search_flights', _flights(jsonDecode(_flightsArgs) as Map<String, Object?>)),
        _tool('search_hotels', _hotels(jsonDecode(_hotelsArgs) as Map<String, Object?>)),
        _assistant('executor', _searched),
        _assistant('replanner', _planJson([_step3])),
        _assistant('executor', '', [
          'call_attractions:search_attractions:$_attractionsArgs',
          'call_weather:get_weather:$_weatherArgs',
        ]),
        _tool('search_attractions', _attractions(jsonDecode(_attractionsArgs) as Map<String, Object?>)),
        _tool('get_weather', _weather(jsonDecode(_weatherArgs) as Map<String, Object?>)),
        _assistant('executor', _researched),
        // The respond event ends the run (the loop's break action is stripped).
        _assistant('replanner', _respondArgs),
      ]);

      // The final answer, as main's lastMessage.
      expect(lastMessage!.role, RoleType.assistant);
      expect(lastMessage!.content, _respondArgs);
      expect(PlanExecuteResponse.fromJson(jsonDecode(lastMessage!.content) as Map<String, Object?>).response,
          _finalAnswer);

      // The tools ran with the model's arguments; the user's answer was the
      // result of the clarification.
      expect(tools.ask.calls, [_askArgs]);
      expect(tools.flights.calls, [_flightsArgs]);
      expect(tools.hotels.calls, [_hotelsArgs]);
      expect(tools.attractions.calls, [_attractionsArgs]);
      expect(tools.weather.calls, [_weatherArgs]);
      expect(jsonDecode(outputs[6].content), containsPair('flights', hasLength(3)));
      expect(jsonDecode(outputs[7].content), containsPair('hotels', hasLength(4)));
      expect(outputs[12].toolName, 'get_weather');
      expect(outputs[12].content, '{"city":"Beijing","temperature":15,"condition":"Sunny","date":"2025-10-10"}');

      // The planner: eino's planner prompt with the query, the plan tool,
      // forced.
      expect(plannerModel.calls, hasLength(1));
      expect(plannerModel.calls[0].messages.map((m) => m.role), [RoleType.system, RoleType.user]);
      expect(plannerModel.calls[0].messages[1].content, _query);
      expect(plannerModel.calls[0].tools!.map((t) => t.name), ['plan']);
      expect(plannerModel.calls[0].options?.toolChoice, ToolChoice.forced);

      // The executor: the example's prompt — the plan JSON, the numbered steps
      // done, the step to do — and its five tools.
      expect(executorModel.calls, hasLength(6));
      expect(
        executorModel.calls[0].options!.tools!.map((t) => t.name),
        ['get_weather', 'search_flights', 'search_hotels', 'search_attractions', 'ask_for_clarification'],
      );
      expect(executorModel.calls[0].options!.tools!.last.desc, startsWith("Call this tool when the user's request"));
      expect(_messages(executorModel.calls[0]), [
        ('system', _executorSystem),
        ('user', _executorUser([_step1, _step2, _step3], '', _step1)),
      ]);
      final clarification = executorModel.calls[1].messages.last;
      expect((clarification.role, clarification.toolCallId, clarification.content),
          (RoleType.tool, 'call_ask', _userAnswer));
      expect(_messages(executorModel.calls[2]), [
        ('system', _executorSystem),
        ('user', _executorUser([_step2, _step3], '## 1. Step: $_step1\n  Result: $_clarified\n\n', _step2)),
      ]);
      expect([for (final m in executorModel.calls[3].messages.skip(3)) (m.role, m.toolCallId)], [
        (RoleType.tool, 'call_flights'),
        (RoleType.tool, 'call_hotels'),
      ]);
      expect(_messages(executorModel.calls[4]), [
        ('system', _executorSystem),
        (
          'user',
          _executorUser(
            [_step3],
            '## 1. Step: $_step1\n  Result: $_clarified\n\n## 2. Step: $_step2\n  Result: $_searched\n\n',
            _step3,
          ),
        ),
      ]);
      expect([for (final m in executorModel.calls[5].messages.skip(3)) (m.role, m.toolCallId)], [
        (RoleType.tool, 'call_attractions'),
        (RoleType.tool, 'call_weather'),
      ]);

      // The replanner: the plan it revises and the steps done so far.
      expect(replannerModel.calls, hasLength(3));
      for (final call in replannerModel.calls) {
        expect(call.tools!.map((t) => t.name), ['plan', 'respond']);
        expect(call.options?.toolChoice, ToolChoice.forced);
        expect(call.messages, hasLength(2));
        expect(call.messages[0].content, contains("Call 'respond' with"));
      }
      expect(replannerModel.calls[0].messages[1].content,
          _replannerUser([_step1, _step2, _step3], [(_step1, _clarified)]));
      expect(replannerModel.calls[1].messages[1].content,
          _replannerUser([_step2, _step3], [(_step1, _clarified), (_step2, _searched)]));
      expect(replannerModel.calls[2].messages[1].content,
          _replannerUser([_step3], [(_step1, _clarified), (_step2, _searched), (_step3, _researched)]));

      // The session the executor saw in each round.
      expect(inputs.contexts.map((c) => c.plan), [
        DefaultPlan(const [_step1, _step2, _step3]),
        DefaultPlan(const [_step2, _step3]),
        DefaultPlan(const [_step3]),
      ]);
      expect(inputs.contexts.map((c) => c.userInput.single.content), everyElement(_query));
      expect(inputs.sessionValues[0].keys.toSet(), {PlanExecute.userInputSessionKey, PlanExecute.planSessionKey});
      expect(inputs.sessionValues[2][PlanExecute.executedStepSessionKey], _searched);
      expect(inputs.sessionValues[2][PlanExecute.executedStepsSessionKey], const [
        ExecutedStep(step: _step1, result: _clarified),
        ExecutedStep(step: _step2, result: _searched),
      ]);
    });
  });
}
