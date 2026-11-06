// Cross-group smoke tests of the agentic path (P13 integration review): an
// `AgenticChatModelAgent` with one function tool, run by an `AgenticRunner`
// over the two agentic providers (`OpenAIResponsesModel`,
// `ClaudeAgenticModel`), each with a fake HTTP client that answers with
// recorded-shape JSON / server-sent events (the shapes of the providers'
// own fixtures). Each run asks for the tool first and answers second; the
// tests check the events, the tool result the second request sends back in
// the provider's wire shape, and an interrupt of the tool that is
// checkpointed (through the JSON form of the in-memory store) and resumed
// with `resumeWithParams`.
//
// Not a port: eino has no test that wires an eino-ext agentic provider into
// the agent. No test touches the network.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/threepio_core.dart'
    show
        ClaudeAgenticConfig,
        ClaudeAgenticModel,
        OpenAIResponsesConfig,
        OpenAIResponsesModel;

import 'agentic_fakes.dart';

/// The function tool of the runs: always sunny.
final class _WeatherTool extends InvokableTool {
  final List<String> calls = [];

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'get_weather',
        desc: 'The weather of a city.',
        params: const {},
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    calls.add(argumentsJson);
    return 'sunny';
  }
}

/// A fake provider API: records the request bodies and answers the n-th
/// request with `answers[n]`.
final class _FakeApi {
  _FakeApi(this.answers);

  final List<http.StreamedResponse Function()> answers;
  final List<Map<String, Object?>> requests = [];

  late final http.Client client = MockClient.streaming((request, body) async {
    requests.add(
      (jsonDecode(await body.bytesToString()) as Map).cast<String, Object?>(),
    );
    final index = requests.length - 1;
    if (index >= answers.length) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"error":{"message":"unexpected request"}}')),
        400,
        headers: {'content-type': 'application/json'},
      );
    }
    return answers[index]();
  });
}

http.StreamedResponse Function() _json(Map<String, Object?> body) =>
    () => http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(body))),
          200,
          headers: {'content-type': 'application/json'},
        );

http.StreamedResponse Function() _sse(List<String> events) =>
    () => http.StreamedResponse(
          Stream.fromIterable([for (final event in events) utf8.encode(event)]),
          200,
          headers: {'content-type': 'text/event-stream'},
        );

String _event(String type, Map<String, Object?> data) =>
    'event: $type\ndata: ${jsonEncode({'type': type, ...data})}\n\n';

// ---------------------------------------------------------------------------
// OpenAI Responses API
// ---------------------------------------------------------------------------

Map<String, Object?> _openAIResponse(
  String id,
  List<Map<String, Object?>> output, {
  String status = 'completed',
}) =>
    {
      'id': id,
      'object': 'response',
      'created_at': 1741476542,
      'status': status,
      'error': null,
      'incomplete_details': null,
      'model': 'gpt-5-2025-08-07',
      'output': output,
      'usage': {
        'input_tokens': 36,
        'input_tokens_details': {'cached_tokens': 0},
        'output_tokens': 20,
        'output_tokens_details': {'reasoning_tokens': 5},
        'total_tokens': 56,
      },
    };

Map<String, Object?> _openAIReasoning(String id) => {
      'type': 'reasoning',
      'id': id,
      'summary': [
        {'type': 'summary_text', 'text': 'The user wants the weather.'},
      ],
    };

Map<String, Object?> _openAIFunctionCall(
  String callId,
  String name,
  String arguments,
) =>
    {
      'type': 'function_call',
      'id': 'fc_$callId',
      'call_id': callId,
      'name': name,
      'arguments': arguments,
      'status': 'completed',
    };

Map<String, Object?> _openAIText(String text) => {
      'type': 'message',
      'id': 'msg_1',
      'status': 'completed',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': text, 'annotations': <Object?>[]},
      ],
    };

/// A response that asks for [name] with [arguments]: a reasoning item and
/// the function call.
http.StreamedResponse Function() _openAIToolCallAnswer(
  String callId,
  String name,
  String arguments, {
  required bool streaming,
}) {
  if (!streaming) {
    return _json(
      _openAIResponse('resp_1', [
        _openAIReasoning('rs_1'),
        _openAIFunctionCall(callId, name, arguments),
      ]),
    );
  }
  var seq = 0;
  String event(String type, Map<String, Object?> data) =>
      _event(type, {...data, 'sequence_number': seq++});
  final half = arguments.length ~/ 2;
  return _sse([
    event('response.created', {
      'response': _openAIResponse('resp_1', [], status: 'in_progress'),
    }),
    event('response.output_item.added', {
      'output_index': 0,
      'item': {'id': 'rs_1', 'type': 'reasoning', 'summary': <Object?>[]},
    }),
    event('response.reasoning_summary_text.delta', {
      'item_id': 'rs_1',
      'output_index': 0,
      'summary_index': 0,
      'delta': 'The user wants ',
    }),
    event('response.reasoning_summary_text.delta', {
      'item_id': 'rs_1',
      'output_index': 0,
      'summary_index': 0,
      'delta': 'the weather.',
    }),
    event('response.output_item.done', {
      'output_index': 0,
      'item': {..._openAIReasoning('rs_1'), 'status': 'completed'},
    }),
    event('response.output_item.added', {
      'output_index': 1,
      'item': {
        ..._openAIFunctionCall(callId, name, ''),
        'status': 'in_progress',
      },
    }),
    event('response.function_call_arguments.delta', {
      'item_id': 'fc_$callId',
      'output_index': 1,
      'delta': arguments.substring(0, half),
    }),
    event('response.function_call_arguments.delta', {
      'item_id': 'fc_$callId',
      'output_index': 1,
      'delta': arguments.substring(half),
    }),
    event('response.function_call_arguments.done', {
      'item_id': 'fc_$callId',
      'output_index': 1,
      'arguments': arguments,
    }),
    event('response.output_item.done', {
      'output_index': 1,
      'item': _openAIFunctionCall(callId, name, arguments),
    }),
    event('response.completed', {
      'response': _openAIResponse('resp_1', [
        _openAIReasoning('rs_1'),
        _openAIFunctionCall(callId, name, arguments),
      ]),
    }),
  ]);
}

/// A response that answers with [text], in two deltas when streaming.
http.StreamedResponse Function() _openAITextAnswer(
  String text, {
  required bool streaming,
}) {
  if (!streaming) return _json(_openAIResponse('resp_2', [_openAIText(text)]));
  var seq = 0;
  String event(String type, Map<String, Object?> data) =>
      _event(type, {...data, 'sequence_number': seq++});
  final half = text.length ~/ 2;
  final part = {'type': 'output_text', 'text': '', 'annotations': <Object?>[]};
  return _sse([
    event('response.created', {
      'response': _openAIResponse('resp_2', [], status: 'in_progress'),
    }),
    event('response.output_item.added', {
      'output_index': 0,
      'item': {
        'id': 'msg_1',
        'status': 'in_progress',
        'type': 'message',
        'role': 'assistant',
        'content': <Object?>[],
      },
    }),
    event('response.content_part.added', {
      'item_id': 'msg_1',
      'output_index': 0,
      'content_index': 0,
      'part': part,
    }),
    for (final delta in [text.substring(0, half), text.substring(half)])
      event('response.output_text.delta', {
        'item_id': 'msg_1',
        'output_index': 0,
        'content_index': 0,
        'delta': delta,
      }),
    event('response.output_text.done', {
      'item_id': 'msg_1',
      'output_index': 0,
      'content_index': 0,
      'text': text,
    }),
    event('response.content_part.done', {
      'item_id': 'msg_1',
      'output_index': 0,
      'content_index': 0,
      'part': {...part, 'text': text},
    }),
    event('response.output_item.done', {
      'output_index': 0,
      'item': _openAIText(text),
    }),
    event('response.completed', {
      'response': _openAIResponse('resp_2', [_openAIText(text)]),
    }),
  ]);
}

/// The input items of an OpenAI request.
List<Map<String, Object?>> _openAIInput(Map<String, Object?> request) =>
    (request['input']! as List).cast<Map<String, Object?>>();

/// Checks that [request] sends the call [callId] of [name] back and its
/// result [output] right after it.
void _expectOpenAIToolResultSent(
  Map<String, Object?> request, {
  required String callId,
  required String name,
  required String arguments,
  required String output,
}) {
  final input = _openAIInput(request);
  final call = input.indexWhere(
    (item) => item['type'] == 'function_call' && item['call_id'] == callId,
  );
  expect(call, isNot(-1), reason: 'the function call is sent back: $input');
  expect(input[call]['name'], name);
  expect(input[call]['arguments'], arguments);
  expect(input[call]['id'], 'fc_$callId');
  final result = input.indexWhere(
    (item) =>
        item['type'] == 'function_call_output' && item['call_id'] == callId,
  );
  expect(result, call + 1, reason: 'the output follows its call: $input');
  expect(input[result]['output'], [
    {'type': 'input_text', 'text': output},
  ]);
}

// ---------------------------------------------------------------------------
// Anthropic Messages API
// ---------------------------------------------------------------------------

const _claudeModel = 'claude-test-model';

Map<String, Object?> _claudeMessage(
  String id,
  List<Map<String, Object?>> content, {
  String? stopReason,
}) =>
    {
      'id': id,
      'type': 'message',
      'role': 'assistant',
      'model': _claudeModel,
      'content': content,
      'stop_reason': stopReason,
      'stop_sequence': null,
      'usage': {'input_tokens': 25, 'output_tokens': 10},
    };

/// A response that asks for [name] with [arguments] after a text block.
http.StreamedResponse Function() _claudeToolCallAnswer(
  String callId,
  String name,
  String arguments, {
  required bool streaming,
}) {
  if (!streaming) {
    return _json(
      _claudeMessage(
        'msg_1',
        [
          {'type': 'text', 'text': 'Let me check.'},
          {
            'type': 'tool_use',
            'id': callId,
            'name': name,
            'input': jsonDecode(arguments),
          },
        ],
        stopReason: 'tool_use',
      ),
    );
  }
  final half = arguments.length ~/ 2;
  return _sse([
    _event('message_start', {'message': _claudeMessage('msg_1', [])}),
    _event('content_block_start', {
      'index': 0,
      'content_block': {'type': 'text', 'text': ''},
    }),
    _event('ping', {}),
    _event('content_block_delta', {
      'index': 0,
      'delta': {'type': 'text_delta', 'text': 'Let me '},
    }),
    _event('content_block_delta', {
      'index': 0,
      'delta': {'type': 'text_delta', 'text': 'check.'},
    }),
    _event('content_block_stop', {'index': 0}),
    _event('content_block_start', {
      'index': 1,
      'content_block': {
        'type': 'tool_use',
        'id': callId,
        'name': name,
        'input': <String, Object?>{},
      },
    }),
    _event('content_block_delta', {
      'index': 1,
      'delta': {
        'type': 'input_json_delta',
        'partial_json': arguments.substring(0, half),
      },
    }),
    _event('content_block_delta', {
      'index': 1,
      'delta': {
        'type': 'input_json_delta',
        'partial_json': arguments.substring(half),
      },
    }),
    _event('content_block_stop', {'index': 1}),
    _event('message_delta', {
      'delta': {'stop_reason': 'tool_use', 'stop_sequence': null},
      'usage': {'output_tokens': 30},
    }),
    _event('message_stop', {}),
  ]);
}

/// A response that answers with [text], in two deltas when streaming.
http.StreamedResponse Function() _claudeTextAnswer(
  String text, {
  required bool streaming,
}) {
  if (!streaming) {
    return _json(
      _claudeMessage(
        'msg_2',
        [
          {'type': 'text', 'text': text},
        ],
        stopReason: 'end_turn',
      ),
    );
  }
  final half = text.length ~/ 2;
  return _sse([
    _event('message_start', {'message': _claudeMessage('msg_2', [])}),
    _event('content_block_start', {
      'index': 0,
      'content_block': {'type': 'text', 'text': ''},
    }),
    for (final delta in [text.substring(0, half), text.substring(half)])
      _event('content_block_delta', {
        'index': 0,
        'delta': {'type': 'text_delta', 'text': delta},
      }),
    _event('content_block_stop', {'index': 0}),
    _event('message_delta', {
      'delta': {'stop_reason': 'end_turn', 'stop_sequence': null},
      'usage': {'output_tokens': 12},
    }),
    _event('message_stop', {}),
  ]);
}

/// Checks that [request] sends the call [callId] back in the assistant turn
/// and its result [output] in the user turn after it.
void _expectClaudeToolResultSent(
  Map<String, Object?> request, {
  required String userText,
  required String callId,
  required String name,
  required Object? input,
  required String output,
}) {
  final messages = (request['messages']! as List).cast<Map<String, Object?>>();
  expect(messages.map((m) => m['role']), ['user', 'assistant', 'user']);
  expect(messages[0]['content'], [
    {'type': 'text', 'text': userText},
  ]);
  expect(messages[1]['content'], [
    {'type': 'text', 'text': 'Let me check.'},
    {'type': 'tool_use', 'id': callId, 'name': name, 'input': input},
  ]);
  expect(messages[2]['content'], [
    {
      'type': 'tool_result',
      'tool_use_id': callId,
      'content': [
        {'type': 'text', 'text': output},
      ],
    },
  ]);
}

// ---------------------------------------------------------------------------
// The runs
// ---------------------------------------------------------------------------

/// The provider-specific parts of a run.
final class _Provider {
  const _Provider({
    required this.name,
    required this.model,
    required this.toolCallAnswer,
    required this.textAnswer,
    required this.expectToolResultSent,
    required this.callId,
  });

  final String name;
  final AgenticModel Function(http.Client client) model;
  final http.StreamedResponse Function() Function(
    String callId,
    String name,
    String arguments, {
    required bool streaming,
  }) toolCallAnswer;
  final http.StreamedResponse Function() Function(
    String text, {
    required bool streaming,
  }) textAnswer;
  final void Function(
    Map<String, Object?> request, {
    required String userText,
    required String callId,
    required String name,
    required String arguments,
    required String output,
  }) expectToolResultSent;
  final String Function(String base) callId;
}

final _providers = [
  _Provider(
    name: 'OpenAIResponsesModel',
    model: (client) => OpenAIResponsesModel(
      config: const OpenAIResponsesConfig(apiKey: 'test', model: 'gpt-5'),
      httpClient: client,
    ),
    toolCallAnswer: _openAIToolCallAnswer,
    textAnswer: _openAITextAnswer,
    expectToolResultSent: (
      request, {
      required userText,
      required callId,
      required name,
      required arguments,
      required output,
    }) {
      final input = _openAIInput(request);
      expect(
        input.firstWhere((item) => item['role'] == 'user'),
        {'role': 'user', 'content': userText},
      );
      _expectOpenAIToolResultSent(
        request,
        callId: callId,
        name: name,
        arguments: arguments,
        output: output,
      );
    },
    callId: (base) => 'call_$base',
  ),
  _Provider(
    name: 'ClaudeAgenticModel',
    model: (client) => ClaudeAgenticModel(
      config: const ClaudeAgenticConfig(
        apiKey: 'test-key',
        model: _claudeModel,
        maxTokens: 1024,
      ),
      httpClient: client,
    ),
    toolCallAnswer: _claudeToolCallAnswer,
    textAnswer: _claudeTextAnswer,
    expectToolResultSent: (
      request, {
      required userText,
      required callId,
      required name,
      required arguments,
      required output,
    }) =>
        _expectClaudeToolResultSent(
      request,
      userText: userText,
      callId: callId,
      name: name,
      input: jsonDecode(arguments),
      output: output,
    ),
    callId: (base) => 'toolu_$base',
  ),
];

/// The messages of [events], streams joined; every event is free of errors.
Future<List<AgenticMessage>> _messagesOf(
  List<AgenticAgentEvent> events, {
  required bool streaming,
}) async {
  final messages = <AgenticMessage>[];
  for (final event in events) {
    expect(event.error, isNull);
    final variant = event.output?.messageOutput;
    if (variant == null) continue;
    if (variant.agenticRole == AgenticRoleType.assistant) {
      expect(variant.isStreaming, streaming);
    }
    messages.add(await variant.getMessage());
  }
  return messages;
}

FunctionToolCall _onlyCall(AgenticMessage message) =>
    message.contentBlocks.map((b) => b.functionToolCall).nonNulls.single;

void main() {
  final ctx = RunContext.background();
  const question = 'What is the weather in Paris?';
  const arguments = '{"city":"Paris"}';
  const answer = 'It is sunny in Paris.';

  for (final provider in _providers) {
    for (final streaming in [false, true]) {
      final mode = streaming ? 'streaming' : 'generate';

      test('${provider.name} ($mode): the agent calls the tool and answers',
          () async {
        final callId = provider.callId('1');
        final api = _FakeApi([
          provider.toolCallAnswer(
            callId,
            'get_weather',
            arguments,
            streaming: streaming,
          ),
          provider.textAnswer(answer, streaming: streaming),
        ]);
        final tool = _WeatherTool();
        final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
          name: 'weather_agent',
          description: 'Answers questions about the weather.',
          instruction: 'You answer questions about the weather.',
          model: provider.model(api.client),
          toolsConfig: ToolsConfig(
            toolsNode: ToolsNodeConfig(tools: [tool]),
          ),
        ));

        final events = await drainAgenticEvents(
          AgenticRunner(agent: agent, enableStreaming: streaming)
              .query(ctx, question),
        );
        expect(agenticEventRoleProblems(events), isEmpty);
        final messages = await _messagesOf(events, streaming: streaming);

        // The assistant's call, the tool's result, the answer.
        expect(messages, hasLength(3));
        expect(messages[0].role, AgenticRoleType.assistant);
        final call = _onlyCall(messages[0]);
        expect(call.callId, callId);
        expect(call.name, 'get_weather');
        expect(jsonDecode(call.arguments), {'city': 'Paris'});
        expect(messages[1].role, AgenticRoleType.user);
        final result = messages[1].contentBlocks.single.functionToolResult!;
        expect(result.callId, callId);
        expect(result.name, 'get_weather');
        expect((result.content.single.content as UserInputText).text, 'sunny');
        expect(messages[2].role, AgenticRoleType.assistant);
        expect(agenticTextContent(messages[2]), answer);
        expect(tool.calls.map(jsonDecode), [
          {'city': 'Paris'},
        ]);

        // The first request offers the tool; the second sends the call and
        // its result back in the provider's wire shape.
        expect(api.requests, hasLength(2));
        expect(
          jsonEncode(api.requests[0]['tools']),
          contains('"get_weather"'),
        );
        provider.expectToolResultSent(
          api.requests[1],
          userText: question,
          callId: callId,
          name: 'get_weather',
          arguments: arguments,
          output: 'sunny',
        );
      });

      test(
          '${provider.name} ($mode): an interrupt of the tool is checkpointed '
          'and resumed with resumeWithParams', () async {
        final callId = provider.callId('a');
        final api = _FakeApi([
          provider.toolCallAnswer(callId, 'approval', '{}', streaming: streaming),
          provider.textAnswer('Approved and done.', streaming: streaming),
        ]);
        final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
          name: 'approval_agent',
          description: 'Asks for approval.',
          model: provider.model(api.client),
          toolsConfig: ToolsConfig(
            toolsNode: ToolsNodeConfig(tools: [AgenticInterruptTool('approval')]),
          ),
        ));
        final store = InMemoryCheckpointStore();
        final runner = AgenticRunner(
          agent: agent,
          enableStreaming: streaming,
          checkpointStore: store,
        );

        final events1 = await drainAgenticEvents(
          runner.query(
            ctx,
            'Please approve.',
            options: [AgentRunOption.checkpointId('cp')],
          ),
        );
        expect(firstAgenticEventError(events1), isNull);
        final interrupted = findInterruptEvent(events1)!.action!.interrupted!;
        final rootCause =
            interrupted.interruptContexts.singleWhere((c) => c.isRootCause);
        expect(rootCause.info, 'need_approval');
        expect(await store.get('cp'), isNotNull);
        expect(api.requests, hasLength(1));
        final first = await _messagesOf(
          [
            for (final e in events1)
              if (e.output?.messageOutput != null) e,
          ],
          streaming: streaming,
        );
        expect(_onlyCall(first.first).callId, callId);

        final events2 = await drainAgenticEvents(
          await runner.resumeWithParams(
            ctx,
            'cp',
            ResumeParams(targets: {rootCause.id: 'yes'}),
          ),
        );
        expect(firstAgenticEventError(events2), isNull);
        expect(findInterruptEvent(events2), isNull);
        final messages = await _messagesOf(events2, streaming: streaming);
        expect(messages, hasLength(2));
        final result = messages[0].contentBlocks.single.functionToolResult!;
        expect(result.callId, callId);
        expect(
          (result.content.single.content as UserInputText).text,
          'approved:yes',
        );
        expect(agenticTextContent(messages[1]), 'Approved and done.');

        // The resumed run sends the checkpointed call and its result.
        expect(api.requests, hasLength(2));
        provider.expectToolResultSent(
          api.requests[1],
          userText: 'Please approve.',
          callId: callId,
          name: 'approval',
          arguments: '{}',
          output: 'approved:yes',
        );
      });
    }
  }
}
