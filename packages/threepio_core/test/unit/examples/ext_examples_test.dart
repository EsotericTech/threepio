// Runs the eino-ext examples offline (agent X3 of P14):
//
// * example/mcp_tools_example.dart against the in-memory fake MCP server
//   (test/support/fake_mcp_server.dart), with a ScriptedChatModel that calls
//   one MCP tool;
// * example/agentic_agent_example.dart with an OpenAIResponsesModel whose
//   HTTP client is a MockClient answering in the Responses API's JSON, and
//   with a scripted agentic model in streaming mode;
// * example/checkpoint_example.dart (legacy StateGraph checkpoints, needs no
//   model), whose human-in-the-loop part resumes a run.
//
// Not a port. No network, no real timer over 50 ms.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/threepio_core.dart'
    show OpenAIResponsesConfig, OpenAIResponsesModel;

import '../../../example/agentic_agent_example.dart' as agentic;
import '../../../example/checkpoint_example.dart' as checkpoint;
import '../../../example/mcp_tools_example.dart' as mcp;
import '../../support/fake_mcp_server.dart';
import '../../support/scripted_chat_model.dart';

/// Runs [body] and collects what it prints into [out].
Future<T> _capture<T>(List<String> out, Future<T> Function() body) =>
    runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => out.add(line),
      ),
    );

// ---------------------------------------------------------------------------
// OpenAI Responses API answers (the shapes of the provider's own fixtures)
// ---------------------------------------------------------------------------

Map<String, Object?> _response(String id, List<Map<String, Object?>> output) =>
    {
      'id': id,
      'object': 'response',
      'created_at': 1741476542,
      'status': 'completed',
      'error': null,
      'incomplete_details': null,
      'model': 'gpt-5-mini-2025-08-07',
      'output': output,
      'usage': {
        'input_tokens': 36,
        'input_tokens_details': {'cached_tokens': 0},
        'output_tokens': 20,
        'output_tokens_details': {'reasoning_tokens': 5},
        'total_tokens': 56,
      },
    };

final _toolCallAnswer = _response('resp_1', [
  {
    'type': 'reasoning',
    'id': 'rs_1',
    'summary': [
      {'type': 'summary_text', 'text': 'The user wants the weather.'},
    ],
  },
  {
    'type': 'function_call',
    'id': 'fc_call_1',
    'call_id': 'call_1',
    'name': 'get_weather',
    'arguments': '{"city":"Paris"}',
    'status': 'completed',
  },
]);

final _textAnswer = _response('resp_2', [
  {
    'type': 'message',
    'id': 'msg_1',
    'status': 'completed',
    'role': 'assistant',
    'content': [
      {
        'type': 'output_text',
        'text': 'It is sunny and 18 °C in Paris.',
        'annotations': <Object?>[],
      },
    ],
  },
]);

/// An agentic model that answers each call with the next of [answers]; a
/// stream sends the answer as one chunk.
final class _ScriptedAgenticModel implements AgenticModel {
  _ScriptedAgenticModel(this.answers);

  final List<AgenticMessage> answers;
  final List<List<AgenticMessage>> inputs = [];
  int streamCalls = 0;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    inputs.add(List.of(input));
    return answers[inputs.length - 1];
  }

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async {
    streamCalls++;
    return StreamReader.fromIterable([await generate(input, options: options)]);
  }
}

void main() {
  final ctx = RunContext.background();

  group('mcp_tools_example', () {
    test('the agent calls a tool of the MCP server and answers with its '
        'result; the client is closed', () async {
      final server = FakeMcpServer(
        tools: [
          FakeTool.text(
            'echo',
            (arguments) => 'Echo: ${arguments['message']}',
            description: 'Echoes the message back.',
            inputSchema: const {
              'type': 'object',
              'properties': {
                'message': {'type': 'string'},
              },
              'required': ['message'],
            },
          ),
          FakeTool.text(
            'add',
            (arguments) =>
                '${(arguments['a']! as num) + (arguments['b']! as num)}',
            description: 'Adds two numbers.',
          ),
        ],
      );
      final transport = FakeInMemoryTransport(server);
      final model = ScriptedChatModel([
        [
          toolCallDelta(0, id: 'call_1', name: 'echo', args: '{"message":'),
          toolCallDelta(0, args: '"hello from threepio"}'),
          finish('tool_calls'),
        ],
        [
          text('The tool returned '),
          text('"Echo: hello from threepio".'),
          finish('stop'),
        ],
      ]);

      final out = <String>[];
      final answer = await _capture(
        out,
        () => mcp.runMcpToolsExample(
          ctx,
          model: model,
          transport: transport,
          question: mcp.mcpExampleQuestion,
        ),
      );

      expect(answer, 'The tool returned "Echo: hello from threepio".');

      // The server listed its tools and ran echo once, with the arguments
      // the model wrote.
      expect(server.receivedOf('tools/list'), hasLength(1));
      final calls = server.receivedOf('tools/call');
      expect(calls, hasLength(1));
      expect(calls.single.params['name'], 'echo');
      expect(calls.single.params['arguments'], {
        'message': 'hello from threepio',
      });

      // The model was offered both MCP tools, and its second call carried
      // the tool's result.
      expect(model.calls, hasLength(2));
      expect(model.calls.first.tools!.map((info) => info.name), [
        'echo',
        'add',
      ]);
      expect(model.allCalls.first.last.content, mcp.mcpExampleQuestion);
      // An MCP tool runs in its multimodal form: the result's text block is
      // a text part of the tool message.
      final toolMessage = model.allCalls[1].last;
      expect(toolMessage.role, RoleType.tool);
      expect(toolMessage.toolCallId, 'call_1');
      expect(toolMessage.content, isEmpty);
      expect(toolMessage.userInputMultiContent, [
        MessageInputPart.text('Echo: hello from threepio'),
      ]);
      expect(mcp.toolResultText(toolMessage), 'Echo: hello from threepio');

      // What the example printed.
      expect(out, [
        'Connected to fake (protocol $mcpLatestProtocolVersion)',
        'MCP tools: echo, add',
        '\nUser: ${mcp.mcpExampleQuestion}',
        'Tool call: echo({"message":"hello from threepio"})',
        'Tool result (echo): Echo: hello from threepio',
      ]);

      // The example closed the client, and with it the transport.
      expect(transport.closed, isTrue);
    });

    test('toolNames keeps only the named tools of the server', () async {
      final server = FakeMcpServer(
        tools: [
          FakeTool.text('echo', (arguments) => 'echoed'),
          FakeTool.text('add', (arguments) => '3'),
        ],
      );
      final transport = FakeInMemoryTransport(server);
      final model = ScriptedChatModel([
        [text('No tool needed.'), finish('stop')],
      ]);

      final out = <String>[];
      final answer = await _capture(
        out,
        () => mcp.runMcpToolsExample(
          ctx,
          model: model,
          transport: transport,
          question: 'Hi',
          toolNames: ['add'],
        ),
      );

      expect(answer, 'No tool needed.');
      expect(model.calls.single.tools!.map((info) => info.name), ['add']);
      expect(out, contains('MCP tools: add'));
      expect(server.receivedOf('tools/call'), isEmpty);
      expect(transport.closed, isTrue);
    });

    test('the client is closed when the run fails', () async {
      final server = FakeMcpServer(
        tools: [FakeTool.text('echo', (arguments) => 'echoed')],
      );
      final transport = FakeInMemoryTransport(server);
      final model = ScriptedChatModel.turns([
        ScriptedTurn.failure(StateError('model down')),
      ]);

      await expectLater(
        _capture(
          <String>[],
          () => mcp.runMcpToolsExample(
            ctx,
            model: model,
            transport: transport,
            question: 'Hi',
          ),
        ),
        throwsA(
          predicate((Object? error) => '$error'.contains('model down')),
        ),
      );
      expect(transport.closed, isTrue);
    });
  });

  group('agentic_agent_example', () {
    test('OpenAIResponsesModel (MockClient): the agent calls get_weather, '
        'sends the result back and answers; the blocks are printed', () async {
      final requests = <Map<String, Object?>>[];
      final answers = [_toolCallAnswer, _textAnswer];
      final client = MockClient((request) async {
        requests.add(
          (jsonDecode(request.body) as Map).cast<String, Object?>(),
        );
        final index = requests.length - 1;
        if (index >= answers.length) {
          return http.Response('{"error":{"message":"unexpected"}}', 400);
        }
        return http.Response(
          jsonEncode(answers[index]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final model = OpenAIResponsesModel(
        config: const OpenAIResponsesConfig(apiKey: 'test', model: 'gpt-5-mini'),
        httpClient: client,
      );
      addTearDown(model.dispose);

      final out = <String>[];
      final answer = await _capture(
        out,
        () => agentic.runAgenticAgentExample(
          ctx,
          model: model,
          question: agentic.agenticExampleQuestion,
        ),
      );

      expect(answer, 'It is sunny and 18 °C in Paris.');

      // Two requests: the first offers the tool, the second sends the call
      // and the tool's result back.
      expect(requests, hasLength(2));
      expect(requests[0]['model'], 'gpt-5-mini');
      final tools = (requests[0]['tools']! as List).cast<Map<String, Object?>>();
      expect(tools.map((tool) => tool['name']), ['get_weather']);
      final input = (requests[1]['input']! as List).cast<Map<String, Object?>>();
      final call = input.singleWhere((item) => item['type'] == 'function_call');
      expect(call['call_id'], 'call_1');
      expect(call['arguments'], '{"city":"Paris"}');
      final output =
          input.singleWhere((item) => item['type'] == 'function_call_output');
      expect(output['call_id'], 'call_1');
      expect(output['output'], [
        {'type': 'input_text', 'text': 'Sunny, 18 °C in Paris.'},
      ]);

      // The content blocks of the three events.
      expect(out, [
        'User: ${agentic.agenticExampleQuestion}',
        '\n[weather_agent] assistant:',
        '  reasoning: The user wants the weather.',
        '  function_tool_call: get_weather({"city":"Paris"}) [call_1]',
        '\n[weather_agent] user:',
        '  function_tool_result: get_weather -> Sunny, 18 °C in Paris. [call_1]',
        '\n[weather_agent] assistant:',
        '  assistant_gen_text: It is sunny and 18 °C in Paris.',
      ]);
    });

    test('with streaming, any AgenticModel works the same way', () async {
      final model = _ScriptedAgenticModel([
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [
            ContentBlock(
              const FunctionToolCall(
                callId: 'c1',
                name: 'get_weather',
                arguments: '{"city":"Oslo"}',
              ),
            ),
          ],
        ),
        AgenticMessage(
          role: AgenticRoleType.assistant,
          contentBlocks: [
            ContentBlock(const AssistantGenText(text: 'Sunny in Oslo.')),
          ],
        ),
      ]);

      final out = <String>[];
      final answer = await _capture(
        out,
        () => agentic.runAgenticAgentExample(
          ctx,
          model: model,
          question: 'Weather in Oslo?',
          streaming: true,
        ),
      );

      expect(answer, 'Sunny in Oslo.');
      expect(model.streamCalls, 2);
      // The second call carries the call and its result.
      final result = model.inputs[1]
          .expand((message) => message.contentBlocks)
          .map((block) => block.functionToolResult)
          .nonNulls
          .single;
      expect(result.callId, 'c1');
      expect(
        (result.content.single.content as UserInputText).text,
        'Sunny, 18 °C in Oslo.',
      );
      expect(
        out,
        containsAllInOrder([
          '  function_tool_call: get_weather({"city":"Oslo"}) [c1]',
          '  function_tool_result: get_weather -> Sunny, 18 °C in Oslo. [c1]',
          '  assistant_gen_text: Sunny in Oslo.',
        ]),
      );
    });

    test('describeContentBlock names server and MCP tool blocks', () {
      expect(
        agentic.describeContentBlock(
          ContentBlock(const ServerToolCall(name: 'web_search')),
        ),
        'server_tool_call: web_search',
      );
      expect(
        agentic.describeContentBlock(
          ContentBlock(
            const AgenticMcpToolCall(
              serverLabel: 'docs',
              name: 'search',
              arguments: '{}',
            ),
          ),
        ),
        'mcp_tool_call: docs/search({})',
      );
      expect(
        agentic.describeContentBlock(ContentBlock(const Reasoning())),
        'reasoning: (no summary)',
      );
    });
  });

  group('checkpoint_example (legacy StateGraph)', () {
    test('every node of the basic graph is checkpointed', () async {
      final out = <String>[];
      await _capture(out, checkpoint.basicCheckpointExample);

      expect(
        out,
        containsAllInOrder([
          '   [Node] Fetching data...',
          '   [Node] Processing data...',
          '   [Node] Saving results...',
          '\n   Final state: saved=true',
          '   Checkpoints saved: 3\n',
        ]),
      );
    });

    test('the human-in-the-loop run pauses and resumes with the approval',
        () async {
      final out = <String>[];
      await _capture(out, checkpoint.humanInTheLoopExample);

      expect(out, contains('   [Interrupt] Paused at: human_review'));
      expect(
        out,
        contains(
          '   [Interrupt] Question: Approve '
          '"AI-generated content that needs review"?',
        ),
      );
      expect(
        out,
        containsAllInOrder([
          '   [Node] Generating content...',
          '\n   Simulating human approval...\n',
          '   [Node] Publishing content...',
          '\n   Final state: approved=true, published=true',
        ]),
      );
      expect(out, isNot(contains('   [Node] Revising content...')));
    });

    test('checkpoint management lists, counts, deletes and clears', () async {
      final out = <String>[];
      await _capture(out, checkpoint.checkpointManagementExample);

      expect(out, contains('   Total checkpoints: 5'));
      expect(out.where((line) => line.startsWith('   Latest checkpoint: node_')),
          hasLength(1));
      expect(out.where((line) => line.startsWith('     - node_')), hasLength(3));
      expect(out, contains('   Count for thread-1: 5'));
      expect(out, contains('   Deleted oldest checkpoint'));
      expect(out, contains('   After clear: 0 checkpoints\n'));
    });
  });
}
