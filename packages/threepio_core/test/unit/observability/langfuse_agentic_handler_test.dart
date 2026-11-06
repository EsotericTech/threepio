// `LangfuseHandler` and the agentic path: the observations of agentic
// models, agentic chat templates and agentic agents (port of the agentic
// branches of eino-ext `callbacks/langfuse/v2/handler.go`: `observationType`,
// `isGeneration`, `markActiveAgent`, `startSpan`, `endAgentOutput`,
// `collectAgenticMessages`).
//
// Ported Go tests (eino-ext `callbacks/langfuse/v2`), each run for the classic
// and the agentic agent as Go runs them:
// * `TestAgentRootOutputPriority` (agent_root_output_test.go), all 7 cases ×
//   both components.
// * `TestAgentRootOutputIgnoresNestedAgent`, also with agentic agents.
// * `TestAgentErrorScopeEventForms` (agent_error_scope_test.go), typed and
//   untyped × 3 terminal errors.
// * `TestCallbackPanicFinalizesTerminalCollectors` (callback_panic_test.go),
//   the "agent" and "agentic" cases, adapted: Dart has no panics to recover
//   from, so the payload that cannot be written is a `toJson` that throws.
//   The Dart port records that as a serialization failure of the
//   observation (`payload_serialization_failures`), not as Go's
//   `eino_callback_panic` diagnostic; for an outermost agent that also
//   makes the root fail, where Go's panic diagnostic leaves the root alone.
//   The classic port behaves the same, which the test checks too.
// The other Go tests of the package do not touch the agentic branches.
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/callbacks.dart'
    show
        CallbackContext,
        CallbackTiming,
        GlobalCallbacks,
        LangfuseConfig,
        LangfuseHandler,
        OtlpSpan,
        OtlpStatusCode,
        RunInfo,
        SpanExporter,
        onEnd,
        onEndWithStreamOutput,
        onError,
        onStart,
        onStartWithStreamInput,
        reuseHandlers;

import '../../support/log_capture.dart';

final class _MemoryExporter implements SpanExporter {
  final List<OtlpSpan> spans = [];

  @override
  bool add(OtlpSpan span) {
    spans.add(span);
    return true;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> shutdown() async {}

  OtlpSpan named(String name) => spans.singleWhere((span) => span.name == name);

  List<String> get names => [for (final span in spans) span.name];
}

/// A clock that advances one millisecond every time it is read.
DateTime Function() _tickingClock() {
  var now = DateTime.utc(2026, 11, 6, 12);
  return () {
    final current = now;
    now = now.add(const Duration(milliseconds: 1));
    return current;
  };
}

({LangfuseHandler handler, _MemoryExporter exporter}) _setup([
  LangfuseConfig config = const LangfuseConfig(),
]) {
  final exporter = _MemoryExporter();
  final handler = LangfuseHandler(
    config,
    exporter: exporter,
    random: Random(1),
    clock: _tickingClock(),
  );
  return (handler: handler, exporter: exporter);
}

RunInfo _info(ComponentType type, [String name = '', String implementation = '']) =>
    RunInfo(name: name, type: implementation, componentType: type);

const _agenticModel = RunInfo(
  name: '',
  type: 'OpenAIResponses',
  componentType: ComponentType.agenticModel,
);

/// Runs a component the way a graph or the component itself does.
Future<RunContext> _start(RunContext ctx, RunInfo info, Object? input) =>
    onStart(reuseHandlers(ctx, info), input);

Object? _attr(OtlpSpan span, String key) => span.attributes[key];

Object? _json(OtlpSpan span, String key) =>
    jsonDecode(span.attributes[key]! as String);

bool _failed(OtlpSpan span) =>
    span.status.code == OtlpStatusCode.error &&
    span.attributes['langfuse.observation.level'] == 'ERROR';

/// A text chunk of a streamed assistant message, at streaming [index].
AgenticMessage _textChunk(String text, {int index = 0, TokenUsage? usage}) =>
    AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        ContentBlock(
          AssistantGenText(text: text),
          streamingMeta: StreamingMeta(index: index),
        ),
      ],
      responseMeta: usage == null ? null : AgenticResponseMeta(tokenUsage: usage),
    );

/// A complete assistant message with one text block.
AgenticMessage _assistant(String text) => AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [ContentBlock(AssistantGenText(text: text))],
    );

/// Go's JSON of `schema.AgenticMessage` for [_assistant].
Map<String, Object?> _assistantJson(String text) => {
      'role': 'assistant',
      'content_blocks': [
        {
          'type': 'assistant_gen_text',
          'assistant_gen_text': {'text': text},
        },
      ],
    };

Map<String, Object?> _userJson(String role, String text) => {
      'role': role,
      'content_blocks': [
        {
          'type': 'user_input_text',
          'user_input_text': {'text': text},
        },
      ],
    };

final class _Unencodable {
  Map<String, Object?> toJson() => throw StateError('no json');
}

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('observation types', () {
    // Port of `observationType` (handler.go:624-641).
    test('agentic components get the observation of their classic counterpart',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      const kinds = {
        ComponentType.agenticAgent: 'agent',
        ComponentType.agenticModel: 'generation',
        ComponentType.agenticChatTemplate: 'chain',
        ComponentType.agenticToolsNode: 'span',
      };

      for (final type in kinds.keys) {
        await onEnd(await _start(base, _info(type, type.name), null), null);
      }

      expect(
        {
          for (final span in exporter.spans)
            span.name: _attr(span, 'langfuse.observation.type'),
        },
        {for (final entry in kinds.entries) entry.key.name: entry.value},
      );
      expect(
        _attr(exporter.named('agenticModel'), 'langfuse.observation.metadata.eino_component'),
        'AgenticModel',
      );
    });

    test('an agentic model without a node name is named after its type', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      await onEnd(await _start(base, _agenticModel, null), null);

      expect(exporter.names, ['OpenAIResponsesAgenticModel']);
    });
  });

  group('agentic generation', () {
    test('shows the agentic messages, the model, its parameters and the usage',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      const config = AgenticModelCallbackConfig(
        model: 'gpt-5.1',
        maxTokens: 256,
        temperature: 0.2,
        topP: 0.9,
      );

      final ctx = await _start(
        base,
        _agenticModel,
        AgenticModelCallbackInput(
          messages: [AgenticMessage.system('Be brief.'), AgenticMessage.user('Hi')],
          config: config,
          extra: const {'attempt': 2, 'route': 'primary'},
        ),
      );
      await onEnd(
        ctx,
        AgenticModelCallbackOutput(
          message: _assistant('Hello!'),
          config: config,
          tokenUsage: const TokenUsage(
            promptTokens: 12,
            completionTokens: 5,
            totalTokens: 17,
            promptTokenDetails: PromptTokenDetails(cachedTokens: 4),
            completionTokenDetails: CompletionTokenDetails(reasoningTokens: 2),
          ),
          extra: const {'finish': 'stop'},
        ),
      );

      final span = exporter.spans.single;
      expect(_attr(span, 'langfuse.observation.type'), 'generation');
      expect(_json(span, 'langfuse.observation.input'), [
        _userJson('system', 'Be brief.'),
        _userJson('user', 'Hi'),
      ]);
      expect(_json(span, 'langfuse.observation.output'), _assistantJson('Hello!'));
      expect(_attr(span, 'langfuse.observation.model.name'), 'gpt-5.1');
      expect(_json(span, 'langfuse.observation.model.parameters'), {
        'max_tokens': 256,
        'temperature': 0.2,
        'top_p': 0.9,
      });
      expect(_attr(span, 'langfuse.observation.metadata.attempt'), '2');
      expect(_attr(span, 'langfuse.observation.metadata.route'), 'primary');
      expect(_attr(span, 'langfuse.observation.metadata.finish'), 'stop');
      expect(_attr(span, 'gen_ai.usage.input_tokens'), 12);
      expect(_attr(span, 'gen_ai.usage.output_tokens'), 5);
      expect(_attr(span, 'gen_ai.usage.cache_read.input_tokens'), 4);
      expect(_attr(span, 'gen_ai.usage.reasoning.output_tokens'), 2);
      expect(
        span.attributes.keys,
        isNot(contains('langfuse.observation.completion_start_time')),
      );
      expect(span.status.code, OtlpStatusCode.unset);
    });

    test('takes the plain messages of a node, and the usage of the response meta',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _agenticModel, [AgenticMessage.user('Hi')]);
      await onEnd(
        ctx,
        _assistant('Hello!').copyWith(
          responseMeta: const AgenticResponseMeta(
            tokenUsage: TokenUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5),
          ),
        ),
      );

      final span = exporter.spans.single;
      expect(_json(span, 'langfuse.observation.input'), [_userJson('user', 'Hi')]);
      final output = _json(span, 'langfuse.observation.output')! as Map;
      expect(output['content_blocks'], _assistantJson('Hello!')['content_blocks']);
      expect(output['response_meta'], isA<Map<Object?, Object?>>());
      expect(_attr(span, 'gen_ai.usage.input_tokens'), 3);
      expect(_attr(span, 'gen_ai.usage.output_tokens'), 2);
      expect(
        span.attributes.keys,
        isNot(contains('gen_ai.usage.cache_read.input_tokens')),
        reason: 'zero counters are left out',
      );
    });

    test('a streamed answer is joined by streaming index and timed from its '
        'first chunk', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      AgenticModelCallbackOutput call(String arguments, {String id = '', String name = ''}) =>
          AgenticModelCallbackOutput(
            message: AgenticMessage(
              role: AgenticRoleType.assistant,
              contentBlocks: [
                ContentBlock(
                  FunctionToolCall(callId: id, name: name, arguments: arguments),
                  streamingMeta: const StreamingMeta(index: 1),
                ),
              ],
            ),
          );

      final ctx = await _start(base, _agenticModel, [AgenticMessage.user('Hi')]);
      final (source, writer) = pipe<AgenticModelCallbackOutput>(capacity: 8);
      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);
      expect(exporter.spans, isEmpty, reason: 'the stream is still open');

      writer
        ..send(AgenticModelCallbackOutput(message: _textChunk('Hel')))
        ..send(call('{"q":', id: 'call_1', name: 'search'))
        ..send(AgenticModelCallbackOutput(message: _textChunk('lo')))
        ..send(
          AgenticModelCallbackOutput(
            message: call('1}').message!.copyWith(
                  responseMeta: const AgenticResponseMeta(
                    tokenUsage: TokenUsage(
                      promptTokens: 6,
                      completionTokens: 2,
                      totalTokens: 8,
                    ),
                  ),
                ),
            config: const AgenticModelCallbackConfig(model: 'streamed-model'),
          ),
        );
      await writer.close();
      expect(await forCaller.collectAll(), hasLength(4), reason: 'the caller gets every chunk');
      await forCaller.close();
      await handler.flush();

      final span = exporter.spans.single;
      final output = _json(span, 'langfuse.observation.output')! as Map;
      expect(output['content_blocks'], [
        {
          'type': 'assistant_gen_text',
          'assistant_gen_text': {'text': 'Hello'},
        },
        {
          'type': 'function_tool_call',
          'function_tool_call': {
            'call_id': 'call_1',
            'name': 'search',
            'arguments': '{"q":1}',
          },
        },
      ]);
      expect(_attr(span, 'langfuse.observation.model.name'), 'streamed-model');
      expect(_attr(span, 'gen_ai.usage.input_tokens'), 6);
      expect(_attr(span, 'gen_ai.usage.output_tokens'), 2);
      final firstChunk = DateTime.parse(
        _attr(span, 'langfuse.observation.completion_start_time')! as String,
      );
      expect(firstChunk.isUtc, isTrue);
      expect(firstChunk.isAfter(span.startTime), isTrue);
      expect(firstChunk.isBefore(span.endTime), isTrue);
    });

    test('a streamed input is joined position by position', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final (ctx, forModel) = await onStartWithStreamInput(
        reuseHandlers(base, _agenticModel),
        StreamReader<Object?>.fromIterable([
          AgenticModelCallbackInput(messages: [_textChunk('Hel')]),
          AgenticModelCallbackInput(
            messages: [_textChunk('lo')],
            config: const AgenticModelCallbackConfig(model: 'm'),
          ),
        ]),
      );
      await forModel.collectAll();
      await forModel.close();
      await onEnd(ctx, _assistant('ok'));
      await handler.flush();

      final span = exporter.spans.single;
      expect(_json(span, 'langfuse.observation.input'), [_assistantJson('Hello')]);
      expect(_attr(span, 'langfuse.observation.model.name'), 'm');
    });

    test('chunks that cannot be joined make the observation fail', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final output = await _start(base, _info(ComponentType.agenticModel, 'out'), null);
      final (_, forCaller) = await onEndWithStreamOutput(
        output,
        StreamReader<Object?>.fromIterable([
          _textChunk('a'),
          AgenticMessage(
            role: AgenticRoleType.user,
            contentBlocks: [
              ContentBlock(
                const UserInputText(text: 'b'),
                streamingMeta: const StreamingMeta(index: 0),
              ),
            ],
          ),
        ]),
      );
      await forCaller.close();

      final (input, forModel) = await onStartWithStreamInput(
        reuseHandlers(base, _info(ComponentType.agenticModel, 'in')),
        StreamReader<Object?>.fromIterable([
          [_textChunk('a')],
          [_textChunk('b'), _textChunk('c')],
        ]),
      );
      await forModel.close();
      await onEnd(input, _assistant('ok'));
      await handler.flush();

      final out = exporter.named('out');
      expect(_failed(out), isTrue);
      expect(out.status.message, startsWith('model output: '));
      expect(out.attributes.keys, isNot(contains('langfuse.observation.output')));
      final inSpan = exporter.named('in');
      expect(_failed(inSpan), isTrue);
      expect(inSpan.status.message, startsWith('model input: '));
      expect(inSpan.attributes.keys, isNot(contains('langfuse.observation.input')));
    });

    test('a payload that is not an agentic model payload is shown as it is',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _agenticModel, {'prompt': 'raw'});
      await onEnd(ctx, 'raw answer');

      final span = exporter.spans.single;
      expect(_json(span, 'langfuse.observation.input'), {'prompt': 'raw'});
      expect(_json(span, 'langfuse.observation.output'), 'raw answer');
    });

    test('a payload without messages is written with its fields', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      const config = AgenticModelCallbackConfig(model: 'm', maxTokens: 8);

      final ctx = await _start(
        base,
        _agenticModel,
        const AgenticModelCallbackInput(messages: [], config: config),
      );
      await onEnd(
        ctx,
        const AgenticModelCallbackOutput(
          config: config,
          tokenUsage: TokenUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2),
        ),
      );

      final span = exporter.spans.single;
      expect(_json(span, 'langfuse.observation.input'), {
        'messages': <Object?>[],
        'config': {'model': 'm', 'maxTokens': 8},
      });
      final output = _json(span, 'langfuse.observation.output')! as Map;
      expect(output['config'], {'model': 'm', 'maxTokens': 8});
      expect(output['tokenUsage'], isA<Map<Object?, Object?>>());
      expect(_attr(span, 'langfuse.observation.model.name'), 'm');
      expect(_json(span, 'langfuse.observation.model.parameters'), {'max_tokens': 8});
      expect(_attr(span, 'gen_ai.usage.input_tokens'), 1);
    });

    test('a failed agentic model stream outside an agent gives the root its '
        'partial message and fails it', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'root');
      final ctx = await _start(traceCtx, _info(ComponentType.agenticModel, 'provider'), null);
      final (source, writer) = pipe<AgenticModelCallbackOutput>(capacity: 2);
      writer
        ..send(AgenticModelCallbackOutput(message: _assistant('failed partial')))
        ..sendError(StateError('attempt failed'));
      await writer.close();
      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);
      await forCaller.close();
      handler.endTrace(traceCtx);
      await handler.flush();

      expect(_failed(exporter.named('provider')), isTrue);
      final root = exporter.named('root');
      expect(_failed(root), isTrue);
      expect(_json(root, 'langfuse.observation.output'), _assistantJson('failed partial'));
    });
  });

  group('agentic chat template', () {
    test('shows the variables and the rendered agentic messages', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(
        base,
        _info(ComponentType.agenticChatTemplate, 'prompt'),
        const AgenticPromptCallbackInput(variables: {'q': 'Hi'}, extra: {'v': 1}),
      );
      await onEnd(ctx, AgenticPromptCallbackOutput(result: [AgenticMessage.user('Hi')]));

      final span = exporter.spans.single;
      expect(_attr(span, 'langfuse.observation.type'), 'chain');
      expect(_json(span, 'langfuse.observation.input'), {
        'variables': {'q': 'Hi'},
        'extra': {'v': 1},
      });
      expect(_json(span, 'langfuse.observation.output'), {
        'result': [_userJson('user', 'Hi')],
      });
    });

    test('the plain payloads of a graph node are shown as they are', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(
        base,
        _info(ComponentType.agenticChatTemplate, 'prompt'),
        {'q': 'Hi'},
      );
      await onEnd(ctx, [AgenticMessage.user('Hi')]);

      final span = exporter.spans.single;
      expect(_json(span, 'langfuse.observation.input'), {'q': 'Hi'});
      expect(_json(span, 'langfuse.observation.output'), [_userJson('user', 'Hi')]);
    });
  });

  group('agentic agents', () {
    final agent = _info(ComponentType.agenticAgent, 'assistant', 'AgenticChatModel');

    test('the observation ends with the messages and custom outputs of its events',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'run');
      final agentCtx = await _start(
        traceCtx,
        agent,
        AgenticAgentCallbackInput(
          input: AgenticAgentInput(messages: [AgenticMessage.user('hi')]),
        ),
      );
      final (events, writer) = pipe<AgenticAgentEvent>(capacity: 8);
      await onEnd(agentCtx, AgenticAgentCallbackOutput(events));
      writer
        ..send(AgenticAgentEvent.fromMessage(_assistant('Hello')))
        ..send(
          AgenticAgentEvent.fromMessage(
            null,
            stream: StreamReader.fromIterable([_textChunk(' wor'), _textChunk('ld')]),
          ),
        )
        ..send(
          const AgenticAgentEvent(
            output: AgenticAgentOutput(customizedOutput: {'step': 1}),
          ),
        )
        ..send(const AgenticAgentEvent());
      expect(exporter.spans, isEmpty, reason: 'the events have not ended');
      await writer.close();
      await handler.flush();
      handler.endTrace(traceCtx);

      final span = exporter.named('assistant');
      expect(_attr(span, 'langfuse.observation.type'), 'agent');
      expect(_json(span, 'langfuse.observation.input'), {
        'input': {
          'messages': [_userJson('user', 'hi')],
          'enableStreaming': false,
        },
      });
      final output = _json(span, 'langfuse.observation.output');
      expect(output, {
        'messages': [_assistantJson('Hello'), _assistantJson(' world')],
        'customized': {'step': 1},
      });
      expect(span.status.code, OtlpStatusCode.unset);
      expect(
        _json(exporter.named('run'), 'langfuse.observation.output'),
        output,
        reason: 'the outermost agent gives the root its output',
      );
    });

    test('one message is written as it is, not as a list', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final agentCtx = await _start(base, agent, null);
      await onEnd(
        agentCtx,
        AgenticAgentCallbackOutput(
          StreamReader.fromIterable([AgenticAgentEvent.fromMessage(_assistant('done'))]),
        ),
      );
      await handler.flush();

      expect(
        _json(exporter.named('assistant'), 'langfuse.observation.output'),
        {'messages': _assistantJson('done')},
      );
    });

    test('a retried model stream is a retry notification, not a failure', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final retry = WillRetryException(
        errorText: 'stream reset',
        rejectReason: {'code': 'invalid_output'},
      );

      final agentCtx = await _start(base, agent, null);
      await onEnd(
        agentCtx,
        AgenticAgentCallbackOutput(
          StreamReader.fromIterable([
            AgenticAgentEvent(error: retry),
            AgenticAgentEvent.fromMessage(_assistant('Hello')),
          ]),
        ),
      );
      await handler.flush();

      final span = exporter.named('assistant');
      expect(span.status.code, OtlpStatusCode.unset);
      expect(_attr(span, 'langfuse.observation.metadata.eino_retry_event_count'), 1);
      expect(_json(span, 'langfuse.observation.metadata.eino_retry_events'), [
        {
          'operation': 'agent output',
          'attempt': 0,
          'error': 'stream reset',
          'reject_reason': {'code': 'invalid_output'},
        },
      ]);
      expect(
        _json(span, 'langfuse.observation.output'),
        {'messages': _assistantJson('Hello')},
      );
    });

    test('an output that is not an event stream is written as it is', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'run');
      final agentCtx = await _start(traceCtx, agent, 'question');
      await onEnd(agentCtx, 'answer');
      handler.endTrace(traceCtx);

      expect(_json(exporter.named('assistant'), 'langfuse.observation.output'), 'answer');
      expect(_json(exporter.named('run'), 'langfuse.observation.output'), 'answer');
    });

    test('an agentic agent answers for the failures of what it calls', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'run');
      final agentCtx = await _start(traceCtx, agent, null);
      final modelCtx =
          await _start(agentCtx, _info(ComponentType.agenticModel, 'model'), null);
      await onError(modelCtx, StateError('try again'), StackTrace.current);
      await handler.flush();
      await onEnd(agentCtx, 'recovered answer');
      handler.endTrace(traceCtx);

      expect(_failed(exporter.named('model')), isTrue);
      expect(exporter.named('assistant').status.code, OtlpStatusCode.unset);
      expect(exporter.named('run').status.code, OtlpStatusCode.unset);
      expect(exporter.named('model').parentSpanId, exporter.named('assistant').spanId);

      // A failing outermost agentic agent fails the root.
      final failing = handler.startTrace(base, name: 'run2');
      final failingAgent = await _start(failing, _info(ComponentType.agenticAgent, 'a2'), null);
      await onError(failingAgent, StateError('out of retries'), StackTrace.current);
      await handler.flush();
      handler.endTrace(failing);
      expect(_failed(exporter.named('run2')), isTrue);
    });

    test('with collapsing, the machinery of an agentic agent gets no spans',
        () async {
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(collapseAgentInternalSpans: true),
      );
      final base = RunContext.background().withHandlers([handler]);

      final agentCtx = await _start(base, agent, null);
      var ctx = await _start(agentCtx, _info(ComponentType.chain, 'assistant'), 1);
      ctx = await _start(ctx, _info(ComponentType.graph, 'ReAct'), 1);
      ctx = await _start(ctx, _info(ComponentType.lambda, 'Init'), 1);
      ctx = await _start(ctx, _info(ComponentType.lambda), 1);
      final named = await _start(ctx, _info(ComponentType.lambda, 'rewrite'), 1);
      final tools = await _start(ctx, _info(ComponentType.agenticToolsNode, 'ToolNode'), 1);
      final model = await _start(ctx, _agenticModel, [AgenticMessage.user('q')]);
      await onEnd(model, _assistant('a'));
      await onEnd(tools, 2);
      await onEnd(named, 2);
      await onEnd(ctx, 2);
      await onEnd(agentCtx, 'a');

      expect(
        exporter.names,
        ['OpenAIResponsesAgenticModel', 'ToolNode', 'rewrite', 'assistant'],
      );
      final agentSpan = exporter.named('assistant');
      expect(_attr(agentSpan, 'langfuse.observation.type'), 'agent');
      for (final name in ['OpenAIResponsesAgenticModel', 'ToolNode', 'rewrite']) {
        expect(exporter.named(name).parentSpanId, agentSpan.spanId);
      }
      expect(
        handler.needed(base, _info(ComponentType.graph, 'ReAct'), CallbackTiming.onStart),
        isTrue,
        reason: 'outside the agent the graph is an ordinary component',
      );
    });

    // Port of TestAgentRootOutputPriority (agent_root_output_test.go).
    group('root output priority', () {
      final cases = [
        (name: 'late child', agentOutput: 'done', explicit: '', want: '"done"', childFirst: false, cancel: false, noAgent: false),
        (name: 'early child', agentOutput: 'done', explicit: '', want: '"done"', childFirst: true, cancel: false, noAgent: false),
        (name: 'explicit', agentOutput: 'done', explicit: 'application result', want: 'application result', childFirst: false, cancel: false, noAgent: false),
        (name: 'explicit survives cancellation', agentOutput: 'done', explicit: 'application result', want: 'application result', childFirst: false, cancel: true, noAgent: false),
        (name: 'context end', agentOutput: 'done', explicit: '', want: '"done"', childFirst: false, cancel: true, noAgent: false),
        (name: 'empty agent output', agentOutput: '', explicit: '', want: '', childFirst: false, cancel: false, noAgent: false),
        (name: 'standalone fallback', agentOutput: '', explicit: '', want: '{"role":"assistant","content":"failed partial"}', childFirst: false, cancel: false, noAgent: true),
      ];
      for (final component in [ComponentType.agent, ComponentType.agenticAgent]) {
        for (final tc in cases) {
          test('${component.einoName}/${tc.name}', () async {
            final (:handler, :exporter) = _setup(
              const LangfuseConfig(collapseAgentInternalSpans: true),
            );
            final token = CancelToken();
            final base =
                RunContext.background(cancelToken: token).withHandlers([handler]);
            final ctx = handler.startTrace(base, name: 'root');
            final info = _info(component, 'agent');
            var agentCtx = ctx;
            if (!tc.noAgent) agentCtx = await _start(ctx, info, null);
            final modelCtx = await _start(
              agentCtx,
              _info(ComponentType.chatModel, 'provider'),
              const ModelCallbackInput(messages: []),
            );
            Future<void> finishChild() async {
              final (source, writer) = pipe<Object?>(capacity: 2);
              writer
                ..send(ModelCallbackOutput(message: Message.assistant('failed partial')))
                ..sendError(StateError('attempt failed'));
              await writer.close();
              final (_, forCaller) = await onEndWithStreamOutput(modelCtx, source);
              await forCaller.close();
              await handler.flush();
            }

            if (tc.childFirst) await finishChild();
            if (!tc.noAgent) {
              if (tc.agentOutput.isEmpty) {
                // A genuinely empty agent result, not a JSON empty string.
                await onEnd(
                  agentCtx,
                  component == ComponentType.agent
                      ? AgentCallbackOutput(StreamReader<AgentEvent>.fromIterable(const []))
                      : AgenticAgentCallbackOutput(
                          StreamReader<AgenticAgentEvent>.fromIterable(const []),
                        ),
                );
              } else {
                await onEnd(agentCtx, tc.agentOutput);
              }
              await handler.flush();
            }
            if (!tc.cancel || tc.explicit.isNotEmpty) {
              handler.endTrace(ctx, tc.explicit);
            }
            if (tc.cancel) {
              token.cancel();
              await pumpEventQueue();
            }
            if (!tc.childFirst) await finishChild();
            await handler.flush();

            final root = exporter.named('root');
            final output = _attr(root, 'langfuse.observation.output');
            if (tc.want.isEmpty) {
              expect(output, isNull);
            } else if (tc.noAgent) {
              expect(jsonDecode(output! as String), jsonDecode(tc.want));
            } else {
              expect(output, tc.want);
            }
            expect(_failed(root), tc.noAgent);
            expect(_failed(exporter.named('provider')), isTrue);
          });
        }
      }
    });

    // Port of TestAgentRootOutputIgnoresNestedAgent, with every combination
    // of classic and agentic agents.
    for (final outerType in [ComponentType.agent, ComponentType.agenticAgent]) {
      for (final innerType in [ComponentType.agent, ComponentType.agenticAgent]) {
        test('the root ignores a nested agent '
            '(${outerType.einoName} around ${innerType.einoName})', () async {
          final (:handler, :exporter) = _setup(
            const LangfuseConfig(collapseAgentInternalSpans: true),
          );
          final base = RunContext.background().withHandlers([handler]);
          final ctx = handler.startTrace(base, name: 'root');
          final outerCtx = await _start(ctx, _info(outerType, 'outer'), null);
          final innerCtx = await _start(outerCtx, _info(innerType, 'inner'), null);
          await onEnd(outerCtx, 'done');
          handler.endTrace(ctx);
          await onError(innerCtx, StateError('handled child failure'), StackTrace.current);
          await handler.flush();

          final root = exporter.named('root');
          expect(_attr(root, 'langfuse.observation.output'), '"done"');
          expect(_failed(root), isFalse);
          expect(_failed(exporter.named('inner')), isTrue);
        });
      }
    }

    // Port of TestAgentErrorScopeEventForms (agent_error_scope_test.go).
    for (final typed in [false, true]) {
      for (final terminal in <Object?>[
        null,
        StateError('budget limit'),
        const ExceedMaxIterationsException(),
      ]) {
        test('event forms: typed=$typed, terminal=$terminal', () async {
          final (:handler, :exporter) = _setup();
          final base = RunContext.background().withHandlers([handler]);
          final ctx = handler.startTrace(base, name: 'root');
          final info = _info(typed ? ComponentType.agenticAgent : ComponentType.agent, 'agent');
          final agentCtx = await _start(ctx, info, null);
          final retryError = ThreepioException(
            'wrapped: retry',
            cause: WillRetryException(errorText: 'retry', retryAttempt: 1),
          );
          if (typed) {
            final (events, sender) = pipe<AgenticAgentEvent>(capacity: 8);
            await onEnd(agentCtx, AgenticAgentCallbackOutput(events));
            sender.send(AgenticAgentEvent(error: retryError));
            final (stream, writer) = pipe<AgenticMessage>(capacity: 1);
            writer.sendError(retryError);
            await writer.close();
            sender.send(AgenticAgentEvent.fromMessage(null, stream: stream));
            if (terminal != null) sender.send(AgenticAgentEvent(error: terminal));
            await sender.close();
          } else {
            final (events, sender) = pipe<AgentEvent>(capacity: 8);
            await onEnd(agentCtx, AgentCallbackOutput(events));
            sender.send(AgentEvent(error: retryError));
            final (stream, writer) = pipe<Message>(capacity: 1);
            writer.sendError(retryError);
            await writer.close();
            sender.send(
              AgentEvent(output: AgentOutput(messageOutput: MessageVariant.stream(stream))),
            );
            if (terminal != null) sender.send(AgentEvent(error: terminal));
            await sender.close();
          }
          handler.endTrace(ctx);
          await handler.flush();

          expect(_failed(exporter.named('root')), terminal != null);
          final span = exporter.named('agent');
          expect(_failed(span), terminal != null);
          final retries =
              _json(span, 'langfuse.observation.metadata.eino_retry_events')! as List<Object?>;
          expect(retries, hasLength(2));
          final first = retries[0]! as Map;
          final second = retries[1]! as Map;
          expect(first['operation'], 'agent output');
          expect(second['operation'], 'agent message');
          expect(first['attempt'], 1);
          expect(second['attempt'], 1);
        });
      }
    }

    // Port of the "agent" and "agentic" cases of
    // TestCallbackPanicFinalizesTerminalCollectors (callback_panic_test.go);
    // see the header for how it is adapted.
    for (final component in [ComponentType.agent, ComponentType.agenticAgent]) {
      test('${component.einoName}: an output that cannot be written still ends '
          'the observation, once', () async {
        final (:handler, :exporter) = _setup(
          const LangfuseConfig(collapseAgentInternalSpans: true),
        );
        final base = RunContext.background().withHandlers([handler]);
        final ctx = handler.startTrace(base, name: 'root');
        final childCtx = await _start(ctx, _info(component, 'child'), null);
        Object output() => component == ComponentType.agent
            ? AgentCallbackOutput(
                StreamReader.fromIterable([
                  AgentEvent(output: AgentOutput(customizedOutput: _Unencodable())),
                ]),
              )
            : AgenticAgentCallbackOutput(
                StreamReader.fromIterable([
                  AgenticAgentEvent(
                    output: AgenticAgentOutput(customizedOutput: _Unencodable()),
                  ),
                ]),
              );
        await onEnd(childCtx, output());
        handler.endTrace(ctx, 'application result');
        await handler.flush();

        expect(exporter.spans, hasLength(2));
        final child = exporter.named('child');
        expect(_failed(child), isTrue);
        expect(child.status.message, startsWith('serialize langfuse.observation.output'));
        expect(child.events, isNotEmpty, reason: 'the exception is recorded');
        expect(handler.losses, {LangfuseHandler.payloadSerialization: 1});
        final root = exporter.named('root');
        expect(_attr(root, 'langfuse.observation.output'), 'application result');
        // Go leaves the root alone for a recovered panic; the Dart port has a
        // serialization failure of the outermost agent instead, which fails
        // the root, for the classic agent as for the agentic one.
        expect(_failed(root), isTrue);

        // A second end callback does not export the span again.
        await onEnd(childCtx, output());
        await handler.flush();
        expect(exporter.spans, hasLength(2));
      });
    }
  });
}
