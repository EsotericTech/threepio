// Runs the compose examples offline: `example/graph_react_example.dart`,
// `example/workflow_example.dart` and, from `example/eino_examples/`,
// `quickstart_chat.dart`, `quickstart_todoagent.dart` and
// `compose_graph_state.dart`.
//
// A ScriptedChatModel plays the model, a MockClient plays DuckDuckGo, and
// prints are captured. Each test checks what the example promises: the ReAct
// graph calls the scripted tools, keeps the history in its state and ends
// with the scripted answer, also when streamed; the workflow's mapped fields
// arrive in the prompt and in its output; the templates render the
// variables and the history; the todo agent runs its four tools and reports
// to the global handler; the state graph prints what the Go program prints.
// No timers, no network, no files.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart'
    show CallbackHandlerBuilder, GlobalCallbacks;
import 'package:threepio_core/compose.dart';

import '../../../example/eino_examples/compose_graph_state.dart'
    as state_graph;
import '../../../example/eino_examples/quickstart_chat.dart'
    as quickstart_chat;
import '../../../example/eino_examples/quickstart_todoagent.dart'
    as todoagent;
import '../../../example/graph_react_example.dart' as graph_react;
import '../../../example/workflow_example.dart' as workflow;
import '../../support/scripted_chat_model.dart';

/// Runs [body] and returns its result with the lines it printed (a print
/// with line breaks counts as several lines).
Future<(T, List<String>)> _capture<T>(Future<T> Function() body) async {
  final out = <String>[];
  final result = await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => out.addAll(line.split('\n')),
    ),
  );
  return (result, out);
}

final _ctx = RunContext.background();

bool _hasToolCalls(Message message) => message.toolCalls?.isNotEmpty ?? false;

void main() {
  group('graph_react_example', () {
    /// One ReAct run: the weather of [city], then clothes for [celsius],
    /// then [answer] in chunks. The first tool call arrives after some text,
    /// so the branch must read past the first chunk.
    List<List<Message>> run(
      String city,
      int celsius,
      List<String> answer, {
      required String idPrefix,
    }) =>
        [
          [
            text('Let me check the weather. '),
            toolCallDelta(
              0,
              id: '${idPrefix}_1',
              name: 'get_weather',
              args: '{"city":"$city"}',
            ),
            finish('tool_calls'),
          ],
          [
            toolCallDelta(
              0,
              id: '${idPrefix}_2',
              name: 'recommend_clothing',
              args: '{"temperature_c":$celsius}',
            ),
            finish('tool_calls'),
          ],
          [for (final piece in answer) text(piece), finish('stop')],
        ];

    test('runReActExample: invoke and stream loop through both tools',
        () async {
      final model = ScriptedChatModel([
        ...run('Paris', 12, ['Wear a jacket ', 'and take an umbrella.'],
            idPrefix: 'paris'),
        ...run('Cairo', 31, ['A t-shirt ', 'and sunscreen.'],
            idPrefix: 'cairo'),
      ]);

      final (_, out) =
          await _capture(() => graph_react.runReActExample(model));

      // The graph is drawn: model, tools, the branch and the loop.
      expect(out, contains('graph TD'));
      expect(out, contains('  start_node --> chat'));
      expect(out, contains('  tools --> chat'));
      expect(out, contains('  chat_branch_0 --> tools'));
      expect(out, contains('  chat_branch_0 --> end_node'));

      // invoke prints the whole answer; stream prints the chunks of the last
      // turn only, then the joined answer.
      final invokeAt = out.indexOf('=== invoke ===');
      final streamAt = out.indexOf('=== stream ===');
      expect(invokeAt, greaterThan(0));
      expect(out[invokeAt + 1], 'Wear a jacket and take an umbrella.');
      expect(out.sublist(streamAt + 1), [
        '  chunk[0]: A t-shirt ',
        '  chunk[1]: and sunscreen.',
        '  chunk[2]: ',
        'A t-shirt and sunscreen.',
      ]);

      // Six model calls, each with the tools bound.
      expect(model.calls, hasLength(6));
      for (final call in model.calls) {
        expect(call.tools?.map((tool) => tool.name),
            ['get_weather', 'recommend_clothing']);
      }

      // The state keeps the history: each call sees everything before it.
      final third = model.calls[2].messages;
      expect(third.map((m) => m.role), [
        RoleType.user,
        RoleType.assistant,
        RoleType.tool,
        RoleType.assistant,
        RoleType.tool,
      ]);
      expect(third[0].content, 'What should I wear in Paris today?');
      expect(third[1].toolCalls!.single.function.name, 'get_weather');
      expect(third[1].toolCalls!.single.function.arguments,
          '{"city":"Paris"}');
      expect(third[2].toolCallId, 'paris_1');
      expect(third[2].toolName, 'get_weather');
      expect(
        jsonDecode(third[2].content),
        {'city': 'Paris', 'temperature_c': 12, 'conditions': 'light rain'},
      );
      expect(third[3].toolCalls!.single.function.arguments,
          '{"temperature_c":12}');
      expect(third[4].toolCallId, 'paris_2');
      expect(third[4].content,
          'a light jacket or a sweater, and an umbrella if it rains');

      // The streamed run starts with a fresh state.
      final sixth = model.calls[5].messages;
      expect(sixth, hasLength(5));
      expect(sixth.first.content, 'What should I wear in Cairo today?');
      expect(sixth.last.content, 'a t-shirt, light trousers and sunscreen');
    });

    test('ask and askStreaming return the answer', () async {
      final model = ScriptedChatModel([
        ...run('Paris', 12, ['Bring ', 'a coat.'], idPrefix: 'a'),
        ...run('Paris', 12, ['Bring ', 'a coat.'], idPrefix: 'b'),
      ]);
      final graph = await graph_react.newReActGraph(
        _ctx,
        model,
        [graph_react.newWeatherTool(), graph_react.newClothingTool()],
      );
      final agent = await graph_react.compileReActAgent(_ctx, graph);

      final answer = await graph_react.ask(_ctx, agent, 'Paris?');
      expect(answer.role, RoleType.assistant);
      expect(answer.content, 'Bring a coat.');
      expect(_hasToolCalls(answer), isFalse);

      final (chunks, out) = await _capture(
        () => graph_react.askStreaming(_ctx, agent, 'Paris?'),
      );
      expect(chunks.map((c) => c.content), ['Bring ', 'a coat.', '']);
      expect(out, ['  chunk[0]: Bring ', '  chunk[1]: a coat.', '  chunk[2]: ']);
    });

    test('a model that keeps calling tools hits maxRunSteps', () async {
      final model = ScriptedChatModel([
        for (var i = 0; i < 10; i++)
          [
            toolCallDelta(
              0,
              id: 'loop_$i',
              name: 'get_weather',
              args: '{"city":"Paris"}',
            ),
          ],
      ]);
      final graph = await graph_react.newReActGraph(
        _ctx,
        model,
        [graph_react.newWeatherTool()],
      );
      final agent =
          await graph_react.compileReActAgent(_ctx, graph, maxRunSteps: 4);

      await expectLater(
        graph_react.ask(_ctx, agent, 'Paris?'),
        throwsA(
          isA<GraphRunException>().having(
            (e) => ThreepioException.findCause<ExceedMaxStepsException>(e),
            'the step limit',
            isNotNull,
          ),
        ),
      );
      // Four steps: model, tools, model, tools.
      expect(model.calls, hasLength(2));
    });

    test('the tools answer as the model expects', () async {
      final weather = graph_react.newWeatherTool();
      expect((await weather.info()).name, 'get_weather');
      expect(
        await weather.invokableRun(_ctx, '{"city":"cairo"}'),
        '{"city":"cairo","temperature_c":31,"conditions":"sunny"}',
      );
      expect(
        await weather.invokableRun(_ctx, '{"city":"Oslo"}'),
        '{"city":"Oslo","error":"no weather data"}',
      );

      final clothing = graph_react.newClothingTool();
      expect(
        await clothing.invokableRun(_ctx, '{"temperature_c":4}'),
        'a warm coat, a scarf and gloves',
      );
      expect(
        await clothing.invokableRun(_ctx, '{"temperature_c":19.5}'),
        'a light jacket or a sweater, and an umbrella if it rains',
      );
      expect(
        await clothing.invokableRun(_ctx, '{"temperature_c":20}'),
        'a t-shirt, light trousers and sunscreen',
      );
    });
  });

  group('workflow_example', () {
    test('runWorkflowExample: mapped fields reach the prompt and the output',
        () async {
      final model = ScriptedChatModel([
        [text('Isolates do not share memory; '), text('they pass messages.')],
      ]);

      final (result, out) =
          await _capture(() => workflow.runWorkflowExample(model));

      // END gets the model's content as `answer` and the keyword list,
      // whole, from the keywords node.
      expect(result, {
        'answer': 'Isolates do not share memory; they pass messages.',
        'keywords': ['isolates', 'share', 'memory'],
      });
      expect(out, [
        'question: How do Dart isolates share memory?',
        'keywords: [isolates, share, memory]',
        'answer:   Isolates do not share memory; they pass messages.',
      ]);

      // The fan-in: the template got the keywords (joined by the custom
      // extractor), the budget (6 words × 10), the question from START and
      // the static language.
      final messages = model.calls.single.messages;
      expect(messages.map((m) => m.role), [RoleType.system, RoleType.user]);
      expect(
        messages[0].content,
        'Answer in English, in at most 60 words. '
        'Use these keywords: isolates, share, memory.',
      );
      expect(messages[1].content, 'How do Dart isolates share memory?');
    });

    test('the budget is clamped and the question is passed on', () async {
      final model = ScriptedChatModel([
        [text('Rayleigh scattering.')],
      ]);
      final (result, _) = await _capture(
        () => workflow.runWorkflowExample(model, question: 'Why blue?'),
      );
      expect(result, {'answer': 'Rayleigh scattering.', 'keywords': <String>[]});
      expect(
        model.calls.single.messages.first.content,
        'Answer in English, in at most 30 words. Use these keywords: .',
      );
    });

    test('an empty question stops at the check: nothing behind it runs',
        () async {
      final model = ScriptedChatModel([]);
      final started = <ComponentType>[];
      final handler = CallbackHandlerBuilder().onStart((ctx, info, input) {
        started.add(info.componentType);
        return ctx;
      }).build();

      final runnable = await workflow.newAnswerWorkflow(model).compile(_ctx);
      await expectLater(
        runnable.invoke(
          _ctx,
          {'question': '  '},
          options: [
            CallOption.callbacks([handler]),
          ],
        ),
        throwsA(
          predicate(
            (Object e) =>
                '$e'.contains('must not be empty') &&
                '$e'.contains('node path: [check]'),
          ),
        ),
      );
      // The workflow and one lambda (the check) started; the two lambdas
      // that depend on it (control only) never did, nor did the model.
      expect(started, [ComponentType.workflow, ComponentType.lambda]);
      expect(model.calls, isEmpty);
    });
  });

  group('quickstart_chat', () {
    const question =
        'Question: My code keeps failing and I feel frustrated. What should I '
        'do?';

    test('createMessagesFromTemplate fills the variables and the history',
        () async {
      final messages = await quickstart_chat.createMessagesFromTemplate();

      expect(messages.map((m) => m.role), [
        RoleType.system,
        RoleType.user,
        RoleType.assistant,
        RoleType.user,
        RoleType.assistant,
        RoleType.user,
      ]);
      expect(
        messages.first.content,
        startsWith(
          'You are a programmer encourager. Answer in a positive, warm and '
          'professional tone.',
        ),
      );
      expect(messages[1].content, 'Hello');
      expect(messages[3].content, 'I think the code I write is terrible');
      expect(messages.last.content, question);
    });

    test('the history placeholder is optional', () async {
      final variables = quickstart_chat.exampleVariables()
        ..remove('chat_history');
      final messages = await quickstart_chat.createTemplate().format(variables);
      expect(messages.map((m) => m.role), [RoleType.system, RoleType.user]);
      expect(messages.last.content, question);
    });

    test('runQuickstartChat: generate, then stream', () async {
      final model = ScriptedChatModel([
        [text('Take a break, '), text('then read the error.')],
        [text('Breathe. '), text('Then debug.')],
      ]);

      final (_, out) =
          await _capture(() => quickstart_chat.runQuickstartChat(model));

      expect(out.first, '===create messages===');
      expect(out[1], 'messages:');
      expect(out.sublist(2, 8).map((line) => line.split(':').first), [
        '  system',
        '  user',
        '  assistant',
        '  user',
        '  assistant',
        '  user',
      ]);
      expect(out.sublist(8), [
        '',
        '===llm generate===',
        'result: assistant: Take a break, then read the error.',
        '',
        '===llm stream generate===',
        'message[0]: assistant: Breathe. ',
        'message[1]: assistant: Then debug.',
      ]);

      // Both calls got the six formatted messages.
      expect(model.calls, hasLength(2));
      for (final call in model.calls) {
        expect(call.messages, hasLength(6));
        expect(call.messages.last.content, question);
      }
    });

    test('reportStream prints every chunk and closes the stream', () async {
      final reader = StreamReader<Message>.fromIterable([text('a'), text('b')]);
      final (_, out) =
          await _capture(() => quickstart_chat.reportStream(reader));
      expect(out, ['message[0]: assistant: a', 'message[1]: assistant: b']);
      await expectLater(reader.recv(), throwsA(isA<StreamClosedException>()));
    });

    test('templateChain: template → model, invoked and streamed', () async {
      final model = ScriptedChatModel([
        [text('You are doing '), text('fine.')],
        [text('Keep '), text('going.')],
      ]);

      final (_, out) = await _capture(
        () => quickstart_chat.templateChain(
          quickstart_chat.createTemplate(),
          model,
          quickstart_chat.exampleVariables(),
        ),
      );

      expect(out, [
        'invoke: You are doing fine.',
        'chunk: Keep ',
        'chunk: going.',
      ]);
      expect(model.calls, hasLength(2));
      for (final call in model.calls) {
        expect(call.messages.map((m) => m.role).first, RoleType.system);
        expect(call.messages.last.content, question);
      }
    });
  });

  group('quickstart_todoagent', () {
    // A DuckDuckGo result page with one hit and no next page.
    final searchHit = [
      '<html><body><div id="links" class="results">',
      '<div class="result results_links results_links_deep web-result ">',
      '<h2 class="result__title"><a class="result__a" ',
      'href="https://github.com/cloudwego/eino">GitHub - cloudwego/eino</a>',
      '</h2><a class="result__snippet" ',
      'href="https://github.com/cloudwego/eino">Eino is a framework.</a>',
      '</div></div></body></html>',
    ].join();

    test('runTodoAgent: four tools, one chain, the global handler logs',
        () async {
      // Global callbacks are process-wide: put back what was there.
      final saved = GlobalCallbacks.handlers;
      addTearDown(() {
        GlobalCallbacks.clear();
        GlobalCallbacks.append(saved);
      });
      GlobalCallbacks.append([todoagent.newLogHandler()]);

      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(utf8.encode(searchHit), 200);
      });
      final searchTool =
          DuckDuckGoSearchTool(DuckDuckGoConfig(httpClient: client));

      final model = ScriptedChatModel([
        [
          toolCallDelta(0,
              id: 'c0', name: 'add_todo', args: '{"content":"Learn Eino"}'),
          toolCallDelta(1,
              id: 'c1', name: 'update_todo', args: '{"id":"1","done":true}'),
          toolCallDelta(2,
              id: 'c2', name: 'list_todo', args: '{"finished":false}'),
          toolCallDelta(3,
              id: 'c3',
              name: 'duckduckgo_text_search',
              args: '{"query":"cloudwego/eino"}'),
          finish('tool_calls'),
        ],
      ]);

      final (resp, out) =
          await _capture(() => todoagent.runTodoAgent(model, searchTool));

      // The chain's output: one tool message per call, in call order.
      expect(resp.map((m) => m.role), List.filled(4, RoleType.tool));
      expect(resp.map((m) => m.toolCallId), ['c0', 'c1', 'c2', 'c3']);
      expect(resp[0].content, '{"msg": "add todo success"}');
      expect(resp[1].content, '{"msg": "update todo success"}');
      expect(resp[2].content, contains('Eino project presentation'));
      expect(
        jsonDecode(resp[3].content),
        {
          'message': 'Found 1 results successfully.',
          'results': [
            {
              'title': 'GitHub - cloudwego/eino',
              'url': 'https://github.com/cloudwego/eino',
              'summary': 'Eino is a framework.',
            },
          ],
        },
      );

      // The model: all four tools bound, the temperature call option.
      final call = model.calls.single;
      expect(call.tools?.map((t) => t.name),
          ['add_todo', 'update_todo', 'list_todo', 'duckduckgo_text_search']);
      expect(call.options?.temperature, 0.7);
      expect(call.messages.single.content, contains('cloudwego/eino'));

      // The search went to the fake DuckDuckGo.
      expect(requests, hasLength(1));
      expect(requests.single.bodyFields['q'], 'cloudwego/eino');

      // The tools ran with the decoded arguments.
      expect(out, contains('invoke tool add_todo: '
          '{Content:Learn Eino StartAt:null Deadline:null}'));
      expect(out, contains('invoke tool update_todo: {ID:1 Content:null '
          'StartedAt:null Deadline:null Done:true}'));
      expect(out, contains('invoke tool list_todo: {"finished":false}'));

      // The global handler saw the chain, the model, the tools node and each
      // tool; the chain first and last.
      final callbacks =
          out.where((line) => line.startsWith('[callback]')).toList();
      expect(callbacks.first, '[callback] start Chain ');
      expect(callbacks.last, '[callback] end Chain ');
      expect(callbacks, containsAllInOrder([
        '[callback] start ChatModel chat_model',
        '[callback] end ChatModel chat_model',
        '[callback] start ToolsNode tools',
        '[callback] end ToolsNode tools',
      ]));
      for (final tool in [
        'add_todo',
        'update_todo',
        'list_todo',
        'duckduckgo_text_search',
      ]) {
        expect(callbacks, contains('[callback] start Tool $tool'));
        expect(callbacks, contains('[callback] end Tool $tool'));
      }
      expect(callbacks.where((line) => line.contains('error')), isEmpty);

      // The messages are printed as in Go.
      expect(out, contains('message 0: tool: {"msg": "add todo success"}'));
      expect(out.where((line) => line.startsWith('message ')), hasLength(4));
    });

    test('the tools describe themselves as the Go tools do', () async {
      final add = await todoagent.getAddTodoTool().info();
      expect(add.name, 'add_todo');
      expect(add.function.parameters?.required, ['content']);
      expect(add.function.parameters?.properties.keys,
          containsAll(['content', 'started_at', 'deadline']));

      final update = await todoagent.newUpdateTodoTool().info();
      expect(update.name, 'update_todo');
      expect(update.function.parametersJsonSchema?['required'], ['id']);
      expect(
        update.function.parametersJsonSchema?['additionalProperties'],
        false,
      );

      final list = todoagent.ListTodoTool();
      expect((await list.info()).name, 'list_todo');
      final (answer, out) =
          await _capture(() => list.invokableRun(_ctx, '{}'));
      expect(jsonDecode(answer), contains('todos'));
      expect(out, ['invoke tool list_todo: {}']);
    });
  });

  group('compose_graph_state', () {
    const expectedOutput = [
      '=== Input: "The quick brown fox jumps over the lazy dog" ===',
      '',
      '  [State] round incremented to 1',
      '  [State] history saved, total 1 entries',
      '  [Branch] round=1, quality=5/10',
      '  [Branch] → translate',
      '  [State] round incremented to 2',
      '  [State] history saved, total 2 entries',
      '  [Branch] round=2, quality=7/10',
      '  [Branch] → END',
      '',
      '=== Final Result ===',
      ...expectedResultLines,
    ];

    test('runStateGraph prints what the Go program prints', () async {
      final (result, out) = await _capture(state_graph.runStateGraph);

      // Round 2 already reaches quality 7: its review output holds the
      // round-1 entry of the history, so "[reviewed]" appears twice.
      expect(result, expectedResultLines.join('\n'));
      expect(out, expectedOutput);
    });

    test('every run starts with a fresh state', () async {
      final runnable = await state_graph.buildGraph(_ctx);
      final (first, firstOut) =
          await _capture(() => runnable.invoke(_ctx, 'one'));
      final (second, secondOut) =
          await _capture(() => runnable.invoke(_ctx, 'two'));

      expect(second, first);
      expect(secondOut, firstOut);
      expect(secondOut.first, '  [State] round incremented to 1');
    });

    test('the branch ends the loop at round 3 at the latest', () async {
      // Two reviews are always enough here, so call the condition directly
      // with a state that is already at round 3 and a low quality.
      final graph = Graph<String, String>(
        localState: LocalState.of<state_graph.TranslateState>(
          (ctx) => state_graph.TranslateState()..round = 3,
        ),
      )
        ..addLambdaNode(
          'decide',
          Lambda.invokable(
            (ctx, String input) => state_graph.qualityBranch(ctx, input),
          ),
        )
        ..addEdge(Graph.start, 'decide')
        ..addEdge('decide', Graph.end);
      final runnable = await graph.compile(_ctx);

      final (next, out) = await _capture(
        () => runnable.invoke(_ctx, 'never reviewed'),
      );
      expect(next, Graph.end);
      expect(out, ['  [Branch] round=3, quality=5/10', '  [Branch] → END']);
    });
  });
}

/// The final result of the Go program, line by line.
const expectedResultLines = [
  '[Round 2 translation]',
  '',
  'Previous translations:',
  '[Round 1 translation]',
  '  快速的棕色狐狸跳过了懒狗 [reviewed]',
  '  快速的棕色狐狸跳过了懒狗 [reviewed]',
];
