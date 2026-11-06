// Port of the eino-examples human-in-the-loop flow 6,
// `adk/human-in-the-loop/6_plan-execute-replan/` (main.go, agent.go, tools.go,
// README.md): a travel-planning plan-execute-replan agent whose `book_flight`
// and `book_hotel` tools are wrapped in a review-and-edit step
// (`InvokableReviewEditTool`, here `ReviewEditTool`).
//
// The example talks to a real model and reads the user's review from stdin;
// here three ScriptedChatModels (planner, executor, replanner, each with its
// own script) play the models and the test gives the review. The agent is
// rebuilt as agent.go builds it: `NewPlanner` with a tool-calling model,
// `NewExecutor` with the example's own executor prompt, `formatInput` (only
// the first message), numbered `formatExecutedSteps` and the four travel
// tools (same names, descriptions and deterministic outputs, including the
// FNV-1a `consistentHashing`), `NewReplanner` with the defaults, and
// `planexecute.New` with `MaxIterations: 20`. main.go's loop is driven by
// hand: Runner(enableStreaming, InMemoryCheckpointStore), checkpoint id
// `travel-plan-1`, interrupt at book_flight → approve ("ok"), interrupt at
// book_hotel → edited arguments, then the replanner's respond ends the run.
// Variants: the user rejects ("n" with a reason), and the main flow without
// streaming. Not ported: `rateLimitedModel` (a sleep before each model call,
// off unless RATE_LIMIT_DELAY_MS is set) and the printing of events.
//
// Intended deviations (P9 brief): the plan-execute agent's interrupt has no
// `WorkflowInterruptInfo` in `interrupted.data` (the points are read from
// `interruptContexts`, as main.go does); the loop's break action is stripped
// (the run ends after the replanner's respond event); main.go mutates
// `reInfo.ReviewResult`, Dart builds `info.withResult(...)` (immutable).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/plan.dart'
    show DefaultPlan;

import '../../support/scripted_chat_model.dart';

const _checkpointId = 'travel-plan-1';

// main.go's query, verbatim (the first line ends with a space).
const _query = 'Plan a 3-day trip to Tokyo starting from New York on 2025-10-15. \n'
    'I need to book flights and a hotel. Also recommend some must-see attractions.\n'
    'Today is 2025-09-01.';

// agent.go's executorPrompt, verbatim ("which is: " ends with a space).
const _executorSystem =
    'You are a diligent travel booking assistant. Follow the given plan and execute your tasks carefully.\n'
    'Execute each planning step by using available tools.\n'
    'For weather queries, use get_weather tool.\n'
    'For flight bookings, use book_flight tool - this will require user review before confirmation.\n'
    'For hotel bookings, use book_hotel tool - this will require user review before confirmation.\n'
    'For attraction research, use search_attractions tool.\n'
    'Provide detailed results for each task.';
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

/// agent.go `formatInput`: only the first message.
String _formatInput(List<Message> input) => input[0].content;

/// agent.go `formatExecutedSteps`: numbered, the result indented.
String _formatExecutedSteps(List<ExecutedStep> steps) {
  final sb = StringBuffer();
  for (var i = 0; i < steps.length; i++) {
    sb.write('## ${i + 1}. Step: ${steps[i].step}\n  Result: ${steps[i].result}\n\n');
  }
  return sb.toString();
}

// ---------------------------------------------------------------------------
// tools.go

/// tools.go `consistentHashing`: FNV-1a (32 bit) of [s], mapped to
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

String _str(Map<String, Object?> args, String key) => args[key] as String? ?? '';

int _int(Map<String, Object?> args, String key) => (args[key] as num?)?.toInt() ?? 0;

/// `get_weather`'s output for [args] (tools.go `NewWeatherTool`).
String _weather(Map<String, Object?> args) {
  final city = _str(args, 'city');
  final date = _str(args, 'date');
  const known = {
    'Tokyo': (22, 'Partly Cloudy'),
    'Beijing': (18, 'Sunny'),
    'Paris': (15, 'Rainy'),
    'New York': (12, 'Cloudy'),
  };
  final hit = known[city];
  if (hit != null) {
    return jsonEncode({'city': city, 'temperature': hit.$1, 'condition': hit.$2, 'date': date});
  }
  const conditions = ['Sunny', 'Cloudy', 'Rainy', 'Partly Cloudy'];
  final hashInput = city + date;
  return jsonEncode({
    'city': city,
    'temperature': _consistentHashing('${hashInput}temp', 10, 30),
    'condition': conditions[_consistentHashing('${hashInput}cond', 0, conditions.length - 1)],
    'date': date,
  });
}

/// `book_flight`'s output for [args] (tools.go `NewFlightBookingTool`).
String _flight(Map<String, Object?> args) {
  const airlines = ['Japan Airlines', 'ANA', 'United Airlines', 'Delta', 'Air China'];
  final from = _str(args, 'from');
  final to = _str(args, 'to');
  final date = _str(args, 'date');
  final hashInput = from + to + date;
  final airline = airlines[_consistentHashing('${hashInput}airline', 0, airlines.length - 1)];
  final depHour = _consistentHashing('${hashInput}dephour', 6, 20);
  final depMin = _consistentHashing('${hashInput}depmin', 0, 59);
  final duration = _consistentHashing('${hashInput}duration', 2, 14);
  final arrHour = (depHour + duration) % 24;
  return jsonEncode({
    'booking_id': 'FL-$date-${_consistentHashing('${hashInput}id', 10000, 99999)}',
    'airline': airline,
    'flight_no': '${airline.substring(0, 2)}${_consistentHashing('${hashInput}flightno', 100, 999)}',
    'from': from,
    'to': to,
    'date': date,
    'departure_time': '${_two(depHour)}:${_two(depMin)}',
    'arrival_time': '${_two(arrHour)}:${_two(depMin)}',
    'price': _consistentHashing('${hashInput}price', 300, 1500) * _int(args, 'passengers'),
    'status': 'confirmed',
  });
}

/// `book_hotel`'s output for [args] (tools.go `NewHotelBookingTool`).
String _hotel(Map<String, Object?> args) {
  const hotelNames = ['Grand Hyatt', 'Marriott', 'Hilton', 'Sheraton', 'Ritz-Carlton'];
  const amenities = [
    ['WiFi', 'Pool', 'Gym', 'Spa', 'Restaurant'],
    ['WiFi', 'Breakfast', 'Parking', 'Business Center'],
    ['WiFi', 'Pool', 'Restaurant', 'Bar', 'Concierge'],
  ];
  final city = _str(args, 'city');
  final checkIn = _str(args, 'check_in');
  final checkOut = _str(args, 'check_out');
  final roomType = _str(args, 'room_type');
  final hashInput = city + checkIn + checkOut;
  var pricePerNight = _consistentHashing('${hashInput}price', 100, 400);
  switch (roomType) {
    case 'deluxe':
      pricePerNight = (pricePerNight * 1.5).truncate();
    case 'suite':
      pricePerNight = pricePerNight * 2;
  }
  const nights = 3;
  return jsonEncode({
    'booking_id': 'HT-$checkIn-${_consistentHashing('${hashInput}id', 10000, 99999)}',
    'hotel_name': '$city ${hotelNames[_consistentHashing('${hashInput}hotel', 0, hotelNames.length - 1)]}',
    'city': city,
    'check_in': checkIn,
    'check_out': checkOut,
    'room_type': roomType,
    'price_per_night': pricePerNight,
    'total_price': pricePerNight * nights,
    'amenities': amenities[_consistentHashing('${hashInput}amenities', 0, amenities.length - 1)],
    'status': 'confirmed',
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
      'rating': rating,
      'open_hours': openHours,
      'ticket_price': ticketPrice,
      'category': category,
    };

/// `search_attractions`'s output for [args] (tools.go
/// `NewAttractionSearchTool`).
String _attractions(Map<String, Object?> args) {
  final city = _str(args, 'city');
  final category = _str(args, 'category');
  final byCity = {
    'Tokyo': [
      _attraction('Senso-ji Temple', 'Ancient Buddhist temple in Asakusa', 4.6, '6:00-17:00', 0, 'landmark'),
      _attraction('Tokyo Skytree', 'Tallest tower in Japan with observation decks', 4.5, '10:00-21:00', 2100, 'landmark'),
      _attraction('Meiji Shrine', 'Shinto shrine dedicated to Emperor Meiji', 4.7, '5:00-18:00', 0, 'landmark'),
      _attraction('Ueno Park', 'Large public park with museums and zoo', 4.4, '5:00-23:00', 0, 'park'),
    ],
    'Beijing': [
      _attraction('Forbidden City', 'Ancient imperial palace complex', 4.8, '8:30-17:00', 60, 'historic site'),
      _attraction('Great Wall', 'Historic fortification stretching thousands of miles', 4.9, '6:00-18:00', 45, 'landmark'),
      _attraction('Temple of Heaven', 'Imperial sacrificial altar', 4.6, '6:00-22:00', 35, 'park'),
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
  return jsonEncode({
    'attractions': [
      _attraction('$city Central Park', 'Popular city park', 4.3, '6:00-22:00', 0, 'park'),
      _attraction('$city National Museum', 'Major museum with local history', 4.5, '9:00-17:00', 15, 'museum'),
    ],
  });
}

/// A tools.go tool (`utils.InferTool` over a request struct): its name,
/// description, the request fields with their `jsonschema_description`, and
/// the deterministic output. Records the arguments of every call.
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

ParameterInfo _s(String desc) => ParameterInfo(type: DataType.string, desc: desc);
ParameterInfo _i(String desc) => ParameterInfo(type: DataType.integer, desc: desc);

/// The four travel tools of tools.go `GetAllTravelTools`, unwrapped.
final class _TravelTools {
  final weather = _TravelTool(
    'get_weather',
    'Get weather information for a specific city and date',
    {'city': _s('City name to get weather for'), 'date': _s('Date in YYYY-MM-DD format')},
    _weather,
  );
  final flight = _TravelTool(
    'book_flight',
    'Book a flight between cities. This requires user review before confirmation.',
    {
      'from': _s('Departure city'),
      'to': _s('Destination city'),
      'date': _s('Departure date in YYYY-MM-DD format'),
      'passengers': _i('Number of passengers'),
      'preferred_time': _s('Preferred departure time (morning/afternoon/evening)'),
    },
    _flight,
  );
  final hotel = _TravelTool(
    'book_hotel',
    'Book a hotel in a city. This requires user review before confirmation.',
    {
      'city': _s('City to book hotel in'),
      'check_in': _s('Check-in date in YYYY-MM-DD format'),
      'check_out': _s('Check-out date in YYYY-MM-DD format'),
      'guests': _i('Number of guests'),
      'room_type': _s('Room type preference (standard/deluxe/suite)'),
    },
    _hotel,
  );
  final attractions = _TravelTool(
    'search_attractions',
    'Search for tourist attractions in a city',
    {
      'city': _s('City to search attractions in'),
      'category': _s('Category of attractions (museum, park, landmark, etc.)'),
    },
    _attractions,
  );

  /// `GetAllTravelTools`: book_flight and book_hotel behind a review.
  List<BaseTool> get all => [weather, ReviewEditTool(flight), ReviewEditTool(hotel), attractions];
}

// ---------------------------------------------------------------------------
// agent.go

/// What the example's executor `GenInputFn` was called with, recorded by the
/// test (the example's function does not record; the recording changes
/// nothing).
final class _ExecutorInputs {
  final List<ExecutionContext> contexts = [];
  final List<Map<String, Object?>> sessionValues = [];
}

/// agent.go `NewTravelPlanningAgent` with the three scripted models.
Future<ResumableAgent> _travelPlanningAgent({
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

const _step1 = 'Book a flight from New York to Tokyo on 2025-10-15';
const _step2 = 'Book a hotel in Tokyo from 2025-10-15 to 2025-10-18';
const _step3 = 'Check the weather in Tokyo on 2025-10-15 and search for must-see attractions';

String _planJson(List<String> steps) => jsonEncode({'steps': steps});

const _flightArgs = '{"from":"New York","to":"Tokyo","date":"2025-10-15","passengers":1,'
    '"preferred_time":"morning"}';
const _hotelArgs = '{"city":"Tokyo","check_in":"2025-10-15","check_out":"2025-10-18","guests":1,'
    '"room_type":"standard"}';
// README.md: the user changes room_type from "standard" to "deluxe".
const _hotelArgsDeluxe = '{"city":"Tokyo","check_in":"2025-10-15","check_out":"2025-10-18",'
    '"guests":1,"room_type":"deluxe"}';
const _weatherArgs = '{"city":"Tokyo","date":"2025-10-15"}';
const _attractionsArgs = '{"city":"Tokyo","category":"landmark"}';

const _flightDone = 'The flight from New York to Tokyo on 2025-10-15 is booked and confirmed.';
const _hotelDone = 'A deluxe room in Tokyo is booked from 2025-10-15 to 2025-10-18.';
const _tourDone = 'Tokyo will be 22 degrees and partly cloudy. Must-see: Senso-ji Temple, '
    'Tokyo Skytree and Meiji Shrine.';
const _finalAnswer = 'Your 3-day Tokyo trip is ready: flight and deluxe hotel booked, '
    'and Senso-ji Temple, Tokyo Skytree and Meiji Shrine are waiting.';
final _respondArgs = jsonEncode({'response': _finalAnswer});

ScriptedChatModel _plannerModel() {
  final args = _planJson([_step1, _step2, _step3]);
  final half = args.length ~/ 2;
  return ScriptedChatModel([
    [
      toolCallDelta(0, id: 'plan_1', name: 'plan', args: args.substring(0, half)),
      toolCallDelta(0, args: args.substring(half)),
      finish('tool_calls'),
    ],
  ]);
}

ScriptedChatModel _executorModel() => ScriptedChatModel([
      [toolCallDelta(0, id: 'call_flight', name: 'book_flight', args: _flightArgs), finish('tool_calls')],
      [text('The flight from New York to Tokyo '), text('on 2025-10-15 is booked and confirmed.'), finish('stop')],
      [toolCallDelta(0, id: 'call_hotel', name: 'book_hotel', args: _hotelArgs), finish('tool_calls')],
      [text(_hotelDone), finish('stop')],
      [
        toolCallDelta(0, id: 'call_weather', name: 'get_weather', args: _weatherArgs),
        toolCallDelta(1, id: 'call_attractions', name: 'search_attractions', args: _attractionsArgs),
        finish('tool_calls'),
      ],
      [text(_tourDone), finish('stop')],
    ]);

ScriptedChatModel _replannerModel() => ScriptedChatModel([
      [toolCallDelta(0, id: 'replan_1', name: 'plan', args: _planJson([_step2, _step3])), finish('tool_calls')],
      [toolCallDelta(0, id: 'replan_2', name: 'plan', args: _planJson([_step3])), finish('tool_calls')],
      [toolCallDelta(0, id: 'respond_1', name: 'respond', args: _respondArgs), finish('tool_calls')],
    ]);

/// The executor's user message for [plan], [executedSteps] (formatted by the
/// example) and [step]: agent.go's prompt with `formatInput` = the query.
String _executorUser(List<String> plan, String executedSteps, String step) => '## OBJECTIVE\n'
    '$_query\n'
    '## Given the following plan:\n'
    '${_planJson(plan)}\n'
    '## COMPLETED STEPS & RESULTS\n'
    '$executedSteps\n'
    '## Your task is to execute the first step, which is: \n'
    '$step';

/// The replanner's user message (eino's default `ReplannerPrompt`, default
/// `formatInput` and `formatExecutedSteps`: the example keeps them).
String _replannerUser(List<String> plan, List<(String, String)> executed) => '## OBJECTIVE\n'
    '$_query\n'
    '\n\n## ORIGINAL PLAN\n'
    '${_planJson(plan)}\n'
    '\n## COMPLETED STEPS & RESULTS\n'
    '${executed.map((s) => 'Step: ${s.$1}\nResult: ${s.$2}\n\n').join()}';

// ---------------------------------------------------------------------------
// Event helpers

/// An output event, flattened (the tool calls as `id:name:arguments`,
/// joined by ` | `).
typedef _Out = ({
  String agent,
  RoleType? role,
  String content,
  String toolName,
  String toolCalls,
  bool streaming,
});

/// The output events of a run (checked to carry no error and no action but a
/// final interrupt, as main.go's `processEvents` expects) and the interrupt.
Future<(List<_Out>, AgentEvent?)> _process(StreamReader<AgentEvent> events) async {
  final all = await events.collectAll();
  expect(all.map((e) => e.error), everyElement(isNull), reason: '$all');
  expect(all, isNotEmpty);
  final outputs = <_Out>[];
  AgentEvent? interrupt;
  for (var i = 0; i < all.length; i++) {
    final event = all[i];
    if (event.action != null) {
      expect(event.action!.interrupted, isNotNull, reason: 'only an interrupt action reaches the caller: $event');
      expect(i, all.length - 1, reason: 'the interrupt is the last event');
      interrupt = event;
      continue;
    }
    final variant = event.output!.messageOutput!;
    final message = await variant.getMessage();
    outputs.add((
      agent: event.agentName,
      role: message.role,
      content: message.content,
      toolName: variant.toolName,
      toolCalls: [
        for (final c in message.toolCalls ?? const <ToolCall>[]) '${c.id}:${c.function.name}:${c.function.arguments}',
      ].join(' | '),
      streaming: variant.isStreaming,
    ));
  }
  return (outputs, interrupt);
}

_Out _assistant(String agent, String content, {required bool streaming, List<String> toolCalls = const []}) => (
      agent: agent,
      role: RoleType.assistant,
      content: content,
      toolName: '',
      toolCalls: toolCalls.join(' | '),
      streaming: streaming,
    );

/// A tool result event of the executor. Never streamed, also in a streaming
/// run: the tools are invokable, and eino wraps the invokable endpoint with
/// the event sender before turning it into a streamable one
/// (`compose.convTools`), so the event carries a message.
_Out _tool(String name, String content) => (
      agent: 'executor',
      role: RoleType.tool,
      content: content,
      toolName: name,
      toolCalls: '',
      streaming: false,
    );

/// Checks the review interrupt of [event] for [toolName] with [arguments]
/// (call [callId]) and returns its point.
InterruptCtx _expectReview(AgentEvent event, String toolName, String callId, String arguments) {
  expect(event.agentName, 'executor');
  final interrupted = event.action!.interrupted!;
  // No WorkflowInterruptInfo (P9 intended deviation).
  expect(interrupted.data, isNull);
  expect(interrupted.interruptContexts, hasLength(1));
  final point = interrupted.interruptContexts[0];
  expect(point.isRootCause, isTrue);
  expect(
    point.address.toString(),
    'agent:plan_execute_replan;agent:execute_replan;agent:executor;tool:$toolName:$callId',
  );
  expect(point.info, isA<ReviewEditInfo>());
  final info = point.info! as ReviewEditInfo;
  expect(info.toolName, toolName);
  expect(info.argumentsJson, arguments);
  expect(info.reviewResult, isNull);
  // The chain up to the root: the executor, the loop, the sequence.
  final parents = <String>[];
  for (var p = point.parent; p != null; p = p.parent) {
    expect(p.isRootCause, isFalse);
    parents.add(p.address.toString());
  }
  expect(parents, [
    'agent:plan_execute_replan;agent:execute_replan;agent:executor',
    'agent:plan_execute_replan;agent:execute_replan',
    'agent:plan_execute_replan',
  ]);
  expect(point.parent!.parent!.info, 'Loop workflow interrupted');
  expect(point.parent!.parent!.parent!.info, 'Sequential workflow interrupted');
  return point;
}

/// Resumes the run at [point] with [result] as main.go does
/// (`reInfo.ReviewResult = result`, `ResumeWithParams`).
Future<StreamReader<AgentEvent>> _review(Runner runner, InterruptCtx point, ReviewEditResult result) =>
    runner.resumeWithParams(
      RunContext.background(),
      _checkpointId,
      ResumeParams(targets: {point.id: (point.info! as ReviewEditInfo).withResult(result)}),
    );

List<(String, String)> _messages(ScriptedCall call) => [for (final m in call.messages) (m.role.name, m.content)];

void main() {
  for (final streaming in [true, false]) {
    group('6_plan-execute-replan (streaming: $streaming)', () {
      late ScriptedChatModel plannerModel;
      late ScriptedChatModel executorModel;
      late ScriptedChatModel replannerModel;
      late _TravelTools tools;
      late _ExecutorInputs inputs;
      late InMemoryCheckpointStore store;
      late Runner runner;

      Future<void> build(ScriptedChatModel executor, ScriptedChatModel replanner) async {
        plannerModel = _plannerModel();
        executorModel = executor;
        replannerModel = replanner;
        tools = _TravelTools();
        inputs = _ExecutorInputs();
        store = InMemoryCheckpointStore();
        runner = Runner(
          agent: await _travelPlanningAgent(
            plannerModel: plannerModel,
            executorModel: executorModel,
            replannerModel: replannerModel,
            tools: tools,
            inputs: inputs,
          ),
          enableStreaming: streaming,
          checkpointStore: store,
        );
      }

      /// The query until the review of book_flight; checks the planner, the
      /// executor's first input and the interrupt.
      Future<InterruptCtx> runUntilFlightReview() async {
        final (outputs, interrupt) = await _process(
          runner.query(RunContext.background(), _query, options: [AgentRunOption.checkpointId(_checkpointId)]),
        );
        expect(outputs, [
          _assistant('planner', _planJson([_step1, _step2, _step3]), streaming: streaming),
          _assistant('executor', '', toolCalls: ['call_flight:book_flight:$_flightArgs'], streaming: streaming),
        ]);
        expect(interrupt, isNotNull, reason: 'the run stops for the review of book_flight');
        final point = _expectReview(interrupt!, 'book_flight', 'call_flight', _flightArgs);
        expect(store.keys, [_checkpointId]);

        // The planner: eino's planner prompt, the plan tool, forced.
        expect(plannerModel.calls, hasLength(1));
        expect(plannerModel.calls[0].messages.last.content, _query);
        expect(plannerModel.calls[0].tools!.map((t) => t.name), ['plan']);
        expect(plannerModel.calls[0].options?.toolChoice, ToolChoice.forced);

        // The executor: the example's prompt with the plan JSON, no step yet.
        expect(executorModel.calls, hasLength(1));
        expect(_messages(executorModel.calls[0]), [
          ('system', _executorSystem),
          ('user', _executorUser([_step1, _step2, _step3], '', _step1)),
        ]);
        expect(
          executorModel.calls[0].options!.tools!.map((t) => '${t.name}: ${t.desc}'),
          [
            'get_weather: Get weather information for a specific city and date',
            'book_flight: Book a flight between cities. This requires user review before confirmation.',
            'book_hotel: Book a hotel in a city. This requires user review before confirmation.',
            'search_attractions: Search for tourist attractions in a city',
          ],
        );
        expect(inputs.contexts.single.userInput.map((m) => m.content), [_query]);
        expect(inputs.contexts.single.plan, DefaultPlan(const [_step1, _step2, _step3]));
        expect(inputs.contexts.single.executedSteps, isEmpty);
        expect(inputs.sessionValues.single.keys.toSet(), {PlanExecute.userInputSessionKey, PlanExecute.planSessionKey});
        expect(tools.flight.calls, isEmpty, reason: 'nothing is booked before the review');
        expect(replannerModel.calls, isEmpty);
        return point;
      }

      test('main flow: approve the flight, edit the hotel, the replanner responds', () async {
        await build(_executorModel(), _replannerModel());
        final flightPoint = await runUntilFlightReview();

        // "ok": the flight is booked as the model asked; the executor answers,
        // the replanner drops the step, the executor asks to book the hotel.
        final (afterFlight, hotelInterrupt) =
            await _process(await _review(runner, flightPoint, const ReviewEditResult(noNeedToEdit: true)));
        final flightResult = _flight(jsonDecode(_flightArgs) as Map<String, Object?>);
        expect(afterFlight, [
          _tool('book_flight', flightResult),
          _assistant('executor', _flightDone, streaming: streaming),
          _assistant('replanner', _planJson([_step2, _step3]), streaming: streaming),
          _assistant('executor', '', toolCalls: ['call_hotel:book_hotel:$_hotelArgs'], streaming: streaming),
        ]);
        expect(hotelInterrupt, isNotNull, reason: 'the run stops for the review of book_hotel');
        final hotelPoint = _expectReview(hotelInterrupt!, 'book_hotel', 'call_hotel', _hotelArgs);
        expect(hotelPoint.id, isNot(flightPoint.id));
        expect(tools.flight.calls, [_flightArgs]);
        expect(tools.hotel.calls, isEmpty);

        // The executor saw the booking; the replanner the step and its result.
        expect(executorModel.calls, hasLength(3));
        final second = executorModel.calls[1].messages;
        expect(second, hasLength(4));
        expect(second[2].toolCalls!.single.function.name, 'book_flight');
        expect((second[3].role, second[3].toolCallId, second[3].content), (RoleType.tool, 'call_flight', flightResult));
        expect(replannerModel.calls, hasLength(1));
        expect(replannerModel.calls[0].tools!.map((t) => t.name), ['plan', 'respond']);
        expect(replannerModel.calls[0].options?.toolChoice, ToolChoice.forced);
        expect(replannerModel.calls[0].messages, hasLength(2));
        expect(replannerModel.calls[0].messages[0].role, RoleType.system);
        expect(replannerModel.calls[0].messages[0].content, contains("Call 'respond' with"));
        expect(replannerModel.calls[0].messages[0].content, contains("Call 'plan' with"));
        expect(replannerModel.calls[0].messages[1].content, _replannerUser([_step1, _step2, _step3], [(_step1, _flightDone)]));
        // Round 2 of the executor: the revised plan, the numbered step done.
        expect(_messages(executorModel.calls[2]), [
          ('system', _executorSystem),
          ('user', _executorUser([_step2, _step3], '## 1. Step: $_step1\n  Result: $_flightDone\n\n', _step2)),
        ]);
        expect(inputs.sessionValues, hasLength(2));
        final round2 = inputs.sessionValues[1];
        expect((round2[PlanExecute.userInputSessionKey]! as List).cast<Message>().map((m) => m.content), [_query]);
        expect(round2[PlanExecute.planSessionKey], DefaultPlan(const [_step2, _step3]));
        expect(round2[PlanExecute.executedStepSessionKey], _flightDone);
        expect(round2[PlanExecute.executedStepsSessionKey], [const ExecutedStep(step: _step1, result: _flightDone)]);

        // Edited arguments: the hotel is booked as a deluxe room and the model
        // is told so; the rest of the plan runs; the replanner responds.
        final (afterHotel, end) = await _process(
          await _review(runner, hotelPoint, const ReviewEditResult(editedArgumentsJson: _hotelArgsDeluxe)),
        );
        final hotelResult = 'after presenting the tool call info to the user, the user explilcitly '
            'changed tool call arguments to $_hotelArgsDeluxe. Tool called, final result: '
            '${_hotel(jsonDecode(_hotelArgsDeluxe) as Map<String, Object?>)}';
        expect(afterHotel, [
          _tool('book_hotel', hotelResult),
          _assistant('executor', _hotelDone, streaming: streaming),
          _assistant('replanner', _planJson([_step3]), streaming: streaming),
          _assistant(
            'executor',
            '',
            toolCalls: [
              'call_weather:get_weather:$_weatherArgs',
              'call_attractions:search_attractions:$_attractionsArgs',
            ],
            streaming: streaming,
          ),
          _tool('get_weather', _weather(jsonDecode(_weatherArgs) as Map<String, Object?>)),
          _tool('search_attractions', _attractions(jsonDecode(_attractionsArgs) as Map<String, Object?>)),
          _assistant('executor', _tourDone, streaming: streaming),
          // The final respond event; the loop's break action is stripped.
          _assistant('replanner', _respondArgs, streaming: streaming),
        ]);
        expect(end, isNull, reason: 'the run ends after the respond');
        expect(afterHotel.last.content, '{"response":"$_finalAnswer"}');
        expect(PlanExecuteResponse.fromJson(jsonDecode(afterHotel.last.content) as Map<String, Object?>).response,
            _finalAnswer);
        expect(jsonDecode(hotelResult.split('final result: ').last), containsPair('room_type', 'deluxe'));
        expect(tools.hotel.calls, [_hotelArgsDeluxe]);
        expect(tools.weather.calls, [_weatherArgs]);
        expect(tools.attractions.calls, [_attractionsArgs]);

        // Every model call was used, none more.
        expect(plannerModel.calls, hasLength(1));
        expect(executorModel.calls, hasLength(6));
        expect(replannerModel.calls, hasLength(3));
        expect(inputs.contexts, hasLength(3), reason: 'a resumed executor does not build its input again');

        final fourth = executorModel.calls[3].messages;
        expect((fourth.last.role, fourth.last.toolCallId, fourth.last.content), (RoleType.tool, 'call_hotel', hotelResult));
        expect(_messages(executorModel.calls[4]), [
          ('system', _executorSystem),
          (
            'user',
            _executorUser(
              [_step3],
              '## 1. Step: $_step1\n  Result: $_flightDone\n\n## 2. Step: $_step2\n  Result: $_hotelDone\n\n',
              _step3,
            ),
          ),
        ]);
        final sixth = executorModel.calls[5].messages;
        expect([for (final m in sixth.skip(3)) (m.role, m.toolCallId)], [
          (RoleType.tool, 'call_weather'),
          (RoleType.tool, 'call_attractions'),
        ]);
        expect(replannerModel.calls[1].messages[1].content,
            _replannerUser([_step2, _step3], [(_step1, _flightDone), (_step2, _hotelDone)]));
        expect(replannerModel.calls[2].messages[1].content,
            _replannerUser([_step3], [(_step1, _flightDone), (_step2, _hotelDone), (_step3, _tourDone)]));

        final round3 = inputs.sessionValues[2];
        expect(round3[PlanExecute.planSessionKey], DefaultPlan(const [_step3]));
        expect(round3[PlanExecute.executedStepSessionKey], _hotelDone);
        expect(round3[PlanExecute.executedStepsSessionKey], [
          const ExecutedStep(step: _step1, result: _flightDone),
          const ExecutedStep(step: _step2, result: _hotelDone),
        ]);
      });

      test('reject the flight ("n" with a reason): the executor sees the rejection', () async {
        const reason = 'too expensive, I will book the flight myself';
        const rejected = 'The user rejected the flight booking: too expensive, they will book it themselves.';
        const answer = 'I did not book the flight, as you asked. Hotel and attractions can follow.';
        await build(
          ScriptedChatModel([
            [toolCallDelta(0, id: 'call_flight', name: 'book_flight', args: _flightArgs), finish('tool_calls')],
            [text(rejected), finish('stop')],
          ]),
          ScriptedChatModel([
            [
              toolCallDelta(0, id: 'respond_1', name: 'respond', args: jsonEncode({'response': answer})),
              finish('tool_calls'),
            ],
          ]),
        );
        final point = await runUntilFlightReview();

        final (outputs, end) = await _process(
          await _review(runner, point, const ReviewEditResult(disapproved: true, disapproveReason: reason)),
        );
        const toolResult = "tool 'book_flight' disapproved, reason: $reason";
        expect(outputs, [
          _tool('book_flight', toolResult),
          _assistant('executor', rejected, streaming: streaming),
          _assistant('replanner', jsonEncode({'response': answer}), streaming: streaming),
        ]);
        expect(end, isNull);
        expect(tools.flight.calls, isEmpty, reason: 'a rejected booking does not run');
        expect(executorModel.calls, hasLength(2));
        final last = executorModel.calls[1].messages.last;
        expect((last.role, last.toolCallId, last.content), (RoleType.tool, 'call_flight', toolResult));
        expect(replannerModel.calls.single.messages[1].content,
            _replannerUser([_step1, _step2, _step3], [(_step1, rejected)]));
      });
    });
  }
}
