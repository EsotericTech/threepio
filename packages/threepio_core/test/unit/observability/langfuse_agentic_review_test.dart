// Review tests of the agentic branches of `LangfuseHandler` (P13 review):
// * agentic messages are written even when they hold a value `toJson`
//   cannot encode (no JSON value, no registered type): the classic payloads
//   write such a value with its own `toJson` or its `toString()`, and so do
//   the agentic ones, instead of failing the observation and the trace;
// * the agent input is written with camel-case keys like every other Dart
//   payload, the resume information with its fields;
// * the handler lets go of its copy of the events when reading it fails;
// * next to other handlers (one of which throws) the handler reads only its
//   own copy of the events: the caller and the other handlers still get
//   every event and every chunk;
// * a ReAct run of an agentic agent with tools has the observations of the
//   same run of a classic agent (`Needed` and the collapsing of the agent's
//   machinery treat both alike, eino-ext `markActiveAgent`/`Needed`).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/callbacks.dart'
    show
        CallbackContext,
        ComponentCallbackHandler,
        GlobalCallbacks,
        LangfuseConfig,
        LangfuseHandler,
        OtlpSpan,
        OtlpStatusCode,
        RunInfo,
        SpanExporter,
        onEnd,
        onStart,
        reuseHandlers;

import '../../support/log_capture.dart';
import '../../support/scripted_chat_model.dart';

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

  OtlpSpan ofType(String type, String name) => spans.singleWhere(
        (span) =>
            span.name == name &&
            span.attributes['langfuse.observation.type'] == type,
      );
}

({LangfuseHandler handler, _MemoryExporter exporter}) _setup([
  LangfuseConfig config = const LangfuseConfig(),
]) {
  final exporter = _MemoryExporter();
  final handler = LangfuseHandler(config, exporter: exporter, random: Random(1));
  return (handler: handler, exporter: exporter);
}

RunInfo _info(ComponentType type, [String name = '']) =>
    RunInfo(name: name, type: '', componentType: type);

Future<RunContext> _start(RunContext ctx, RunInfo info, Object? input) =>
    onStart(reuseHandlers(ctx, info), input);

Object? _json(OtlpSpan span, String key) =>
    jsonDecode(span.attributes[key]! as String);

bool _failed(OtlpSpan span) =>
    span.status.code == OtlpStatusCode.error ||
    span.attributes['langfuse.observation.level'] == 'ERROR';

/// A value of no JSON type and no registered type, without `toJson`.
final class _Opaque {
  const _Opaque(this.label);

  final String label;

  @override
  String toString() => 'Opaque($label)';
}

/// A registered type that stands for a string, like the item ids the OpenAI
/// Responses model keeps in its block extras (Go: a named string type).
final class _ItemId {
  const _ItemId(this.value);

  final String value;

  @override
  String toString() => value;
}

/// A value whose `toJson` fails.
final class _Exploding {
  const _Exploding();

  Map<String, Object?> toJson() => throw StateError('cannot write');
}

AgenticMessage _assistant(String text, {Map<String, Object?>? blockExtra}) =>
    AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [ContentBlock(AssistantGenText(text: text), extra: blockExtra)],
    );

Map<String, Object?> _assistantJson(String text, {Map<String, Object?>? blockExtra}) => {
      'role': 'assistant',
      'content_blocks': [
        {
          'type': 'assistant_gen_text',
          'assistant_gen_text': {'text': text},
          if (blockExtra != null) 'extra': blockExtra,
        },
      ],
    };

Map<String, Object?> _userJson(String text, {Map<String, Object?>? extra}) => {
      'role': 'user',
      'content_blocks': [
        {
          'type': 'user_input_text',
          'user_input_text': {'text': text},
        },
      ],
      if (extra != null) 'extra': extra,
    };

/// Reads the events of an agentic agent it is given, joining every message.
final class _ReadingHandler extends ComponentCallbackHandler {
  final List<AgenticMessage> messages = [];
  Future<void>? reading;

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    final events = AgenticAgentCallbackOutput.from(output)?.events;
    if (events != null) {
      reading = () async {
        for (var event = await events.nextOrNull();
            event != null;
            event = await events.nextOrNull()) {
          final variant = event.output?.messageOutput;
          if (variant != null) messages.add(await variant.getMessage());
        }
      }();
    }
    return ctx;
  }
}

/// Throws when an agentic agent ends, without reading its copy of the events.
final class _ThrowingHandler extends ComponentCallbackHandler {
  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    if (info.componentType == ComponentType.agenticAgent) {
      throw StateError('handler bug');
    }
    return ctx;
  }
}

/// An agentic model that streams the same chunks for every call.
final class _StreamingAgenticModel implements AgenticModel {
  _StreamingAgenticModel(this.chunks);

  final List<AgenticMessage> chunks;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async =>
      concatAgenticMessages(chunks);

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable(chunks);
}

/// An agentic model that answers each call with the next of [responses].
final class _SequentialAgenticModel implements AgenticModel {
  _SequentialAgenticModel(this.responses);

  final List<AgenticMessage> responses;
  int _calls = 0;

  @override
  Future<AgenticMessage> generate(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async =>
      responses[_calls++];

  @override
  Future<StreamReader<AgenticMessage>> stream(
    List<AgenticMessage> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([responses[_calls++]]);
}

final class _EchoTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async =>
      ToolInfo.fromParams(name: 'echo', desc: 'echoes its input', params: const {});

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      'echo:$argumentsJson';
}

AgenticMessage _chunk(String text) => AgenticMessage(
      role: AgenticRoleType.assistant,
      contentBlocks: [
        ContentBlock(
          AssistantGenText(text: text),
          streamingMeta: const StreamingMeta(index: 0),
        ),
      ],
    );

String _textOf(AgenticMessage message) => [
      for (final block in message.contentBlocks) block.assistantGenText?.text ?? '',
    ].join();

void main() {
  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  group('values toJson cannot encode', () {
    setUp(() => failOnLoggedWarnings('threepio.callbacks'));

    test('in the extras of a generation are written as the classic payloads '
        'write them', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final traceCtx = handler.startTrace(base, name: 'root');

      final ctx = await _start(
        traceCtx,
        _info(ComponentType.agenticModel, 'model'),
        AgenticModelCallbackInput(
          messages: [
            AgenticMessage.user('Hi').copyWith(extra: const {'trace': _Opaque('in')}),
          ],
        ),
      );
      await onEnd(
        ctx,
        AgenticModelCallbackOutput(
          message: _assistant('Hello', blockExtra: const {'at': _Opaque('block')}),
        ),
      );
      handler.endTrace(traceCtx);
      await handler.flush();

      final span = exporter.named('model');
      expect(_failed(span), isFalse);
      expect(handler.losses, isEmpty);
      expect(_json(span, 'langfuse.observation.input'), [
        _userJson('Hi', extra: {'trace': 'Opaque(in)'}),
      ]);
      expect(
        _json(span, 'langfuse.observation.output'),
        _assistantJson('Hello', blockExtra: {'at': 'Opaque(block)'}),
      );
      expect(_failed(exporter.named('root')), isFalse);
    });

    test('elsewhere in a message leave the message written as its text',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final message = AgenticMessage(
        role: AgenticRoleType.assistant,
        contentBlocks: [
          ContentBlock(
            AssistantGenText(text: 'Hello', extension: const _Opaque('ext')),
          ),
        ],
      );

      final ctx = await _start(base, _info(ComponentType.agenticModel, 'model'), null);
      await onEnd(ctx, AgenticModelCallbackOutput(message: message));
      await handler.flush();

      final span = exporter.named('model');
      expect(_failed(span), isFalse);
      expect(handler.losses, isEmpty);
      expect(_json(span, 'langfuse.observation.output'), '$message');
    });

    test('in the messages of an agentic agent are written too', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final traceCtx = handler.startTrace(base, name: 'root');

      final agentCtx = await _start(
        traceCtx,
        _info(ComponentType.agenticAgent, 'agent'),
        AgenticAgentCallbackInput(
          input: AgenticAgentInput(
            messages: [
              AgenticMessage.user('Hi').copyWith(extra: const {'k': _Opaque('input')}),
            ],
          ),
        ),
      );
      await onEnd(
        agentCtx,
        AgenticAgentCallbackOutput(
          StreamReader.fromIterable([
            AgenticAgentEvent.fromMessage(
              _assistant('Hello', blockExtra: const {'k': _Opaque('output')}),
            ),
          ]),
        ),
      );
      handler.endTrace(traceCtx);
      await handler.flush();

      final span = exporter.named('agent');
      expect(_failed(span), isFalse);
      expect(handler.losses, isEmpty);
      expect(_json(span, 'langfuse.observation.input'), {
        'input': {
          'messages': [
            _userJson('Hi', extra: {'k': 'Opaque(input)'}),
          ],
          'enableStreaming': false,
        },
      });
      expect(_json(span, 'langfuse.observation.output'), {
        'messages': _assistantJson('Hello', blockExtra: {'k': 'Opaque(output)'}),
      });
      expect(_failed(exporter.named('root')), isFalse);
    });

    test('in the messages of a plain node payload are written too', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final input = _assistant('call', blockExtra: const {'k': _Opaque('a')});

      final ctx =
          await _start(base, _info(ComponentType.agenticToolsNode, 'tools'), input);
      await onEnd(ctx, [AgenticMessage.user('result').copyWith(extra: const {'k': _Opaque('b')})]);
      await handler.flush();

      final span = exporter.named('tools');
      expect(_failed(span), isFalse);
      expect(
        _json(span, 'langfuse.observation.input'),
        _assistantJson('call', blockExtra: {'k': 'Opaque(a)'}),
      );
      expect(_json(span, 'langfuse.observation.output'), [
        _userJson('result', extra: {'k': 'Opaque(b)'}),
      ]);
    });

    test('of a registered type in an extra are written as Go writes them, '
        'not with the tag of a checkpoint', () async {
      TypeRegistry.registerName<_ItemId>(
        'langfuse_agentic_review_item_id',
        fromJson: (json) => _ItemId(json['value']! as String),
        toJson: (id) => {'value': id.value},
      );
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final message = _assistant('Hello', blockExtra: const {'item_id': _ItemId('msg_1')})
          .copyWith(extra: const {'response': _ItemId('resp_1'), 'n': 1});
      expect(
        ((message.toJson()['content_blocks']! as List).single as Map)['extra'],
        {
          'item_id': {
            r'$type': 'langfuse_agentic_review_item_id',
            r'$value': {'value': 'msg_1'},
          },
        },
        reason: 'what a checkpoint keeps',
      );

      final ctx = await _start(base, _info(ComponentType.agenticModel, 'model'), null);
      await onEnd(ctx, AgenticModelCallbackOutput(message: message));
      await handler.flush();

      expect(_json(exporter.named('model'), 'langfuse.observation.output'), {
        ..._assistantJson('Hello', blockExtra: {'item_id': 'msg_1'}),
        'extra': {'response': 'resp_1', 'n': 1},
      });
    });

    test('a toJson that fails is a serialization failure, as for a classic '
        'payload', () async {
      final logs = captureLogs('threepio.observability.langfuse');
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _info(ComponentType.agenticModel, 'model'), null);
      await onEnd(
        ctx,
        AgenticModelCallbackOutput(
          message: _assistant('Hello').copyWith(extra: const {'x': _Exploding()}),
          config: const AgenticModelCallbackConfig(model: 'm'),
          tokenUsage: const TokenUsage(promptTokens: 2, completionTokens: 1, totalTokens: 3),
        ),
      );
      await handler.flush();

      final span = exporter.named('model');
      expect(_failed(span), isTrue);
      expect(span.status.message, startsWith('serialize langfuse.observation.output'));
      expect(handler.losses, {LangfuseHandler.payloadSerialization: 1});
      expect(span.attributes['langfuse.observation.model.name'], 'm', reason: 'the rest is still written');
      expect(span.attributes['gen_ai.usage.input_tokens'], 2);
      expect(
        [for (final record in logs) record.message],
        isNot(contains('langfuse callback failed')),
        reason: 'reported as a loss, not as a failure of the handler',
      );
    });
  });

  group('agent input', () {
    setUp(() => failOnLoggedWarnings('threepio.callbacks'));

    test('a resumed agentic agent shows what it resumes with', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final agentCtx = await _start(
        base,
        _info(ComponentType.agenticAgent, 'agent'),
        const AgenticAgentCallbackInput(
          resumeInfo: ResumeInfo(
            enableStreaming: true,
            wasInterrupted: true,
            interruptState: {'step': 2},
            isResumeTarget: true,
            resumeData: 'approved',
          ),
        ),
      );
      await onEnd(agentCtx, 'done');
      await handler.flush();

      expect(_json(exporter.named('agent'), 'langfuse.observation.input'), {
        'resumeInfo': {
          'enableStreaming': true,
          'wasInterrupted': true,
          'interruptState': {'step': 2},
          'isResumeTarget': true,
          'resumeData': 'approved',
        },
      });
    });
  });

  group('the events of an agentic agent', () {
    test('are let go of when reading them fails', () async {
      failOnLoggedWarnings('threepio.callbacks');
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final agentCtx = await _start(base, _info(ComponentType.agenticAgent, 'agent'), null);
      final (events, writer) = pipe<AgenticAgentEvent>();
      await onEnd(agentCtx, AgenticAgentCallbackOutput(events));
      writer
        ..send(AgenticAgentEvent.fromMessage(_assistant('partial')))
        ..sendError(StateError('broken event source'));
      await handler.flush();

      final span = exporter.named('agent');
      expect(_failed(span), isTrue);
      expect(span.status.message, 'agent output: Bad state: broken event source');
      expect(
        _json(span, 'langfuse.observation.output'),
        {'messages': _assistantJson('partial')},
      );
      expect(writer.isClosed, isTrue, reason: 'the handler closed its copy');
    });

    test('next to other handlers, one of which throws, are only the '
        "handler's own copy", () async {
      final logs = captureLogs('threepio.callbacks');
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(collapseAgentInternalSpans: true),
      );
      final reader = _ReadingHandler();
      final model = _StreamingAgenticModel([_chunk('Hel'), _chunk('lo'), _chunk('!')]);
      final agent = AgenticChatModelAgent(
        AgenticChatModelAgentConfig(name: 'assistant', model: model),
      );
      final ctx = handler.startTrace(
        RunContext.background().withHandlers([_ThrowingHandler(), reader, handler]),
        name: 'run',
      );

      final events = await AgenticRunner(agent: agent, enableStreaming: true)
          .query(ctx, 'hi')
          .collectAll();
      final chunks = <AgenticMessage>[];
      for (final event in events) {
        final stream = event.output?.messageOutput?.messageStream;
        if (stream != null) chunks.addAll(await stream.collectAll());
      }
      await reader.reading;
      handler.endTrace(ctx);
      await handler.flush();

      expect(events.map((event) => event.error), everyElement(isNull));
      expect(chunks.map(_textOf), ['Hel', 'lo', '!'], reason: 'the caller gets every chunk');
      expect(reader.messages.map(_textOf), ['Hello!'], reason: 'so does another handler');
      final agentSpan = exporter.ofType('agent', 'assistant');
      expect(_failed(agentSpan), isFalse);
      final output = _json(agentSpan, 'langfuse.observation.output')! as Map;
      final blocks = (output['messages']! as Map)['content_blocks']! as List<Object?>;
      expect(
        [for (final block in blocks) ((block! as Map)['assistant_gen_text']! as Map)['text']],
        ['Hello!'],
      );
      expect(
        [
          for (final record in logs)
            if (record.level >= Level.WARNING) '${record.error}',
        ],
        ['Bad state: handler bug'],
        reason: 'the failing handler is logged and the run goes on',
      );
    });
  });

  test('a ReAct run with tools has the observations of a classic agent', () async {
    failOnLoggedWarnings('threepio.callbacks');
    Future<List<(String, String, String)>> observe(
      Future<void> Function(RunContext ctx) run,
    ) async {
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(collapseAgentInternalSpans: true),
      );
      final ctx = handler.startTrace(
        RunContext.background().withHandlers([handler]),
        name: 'run',
      );
      await run(ctx);
      handler.endTrace(ctx);
      await handler.flush();
      final byId = {for (final span in exporter.spans) span.spanId: span};
      return [
        for (final span in exporter.spans)
          (
            span.name,
            span.attributes['langfuse.observation.type']! as String,
            byId[span.parentSpanId]?.name ?? '-',
          ),
      ];
    }

    final classic = await observe((ctx) async {
      final agent = ChatModelAgent(
        ChatModelAgentConfig(
          name: 'assistant',
          model: ScriptedChatModel([
            [toolCallDelta(0, id: 'call_1', name: 'echo', args: '{"x":1}'), finish('tool_calls')],
            [text('done'), finish('stop')],
          ]),
          toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [_EchoTool()])),
        ),
      );
      final events = await Runner(agent: agent).query(ctx, 'hi').collectAll();
      expect(events.map((event) => event.error), everyElement(isNull));
    });
    final agentic = await observe((ctx) async {
      final agent = AgenticChatModelAgent(
        AgenticChatModelAgentConfig(
          name: 'assistant',
          model: _SequentialAgenticModel([
            AgenticMessage(
              role: AgenticRoleType.assistant,
              contentBlocks: [
                ContentBlock(
                  FunctionToolCall(callId: 'call_1', name: 'echo', arguments: '{"x":1}'),
                ),
              ],
            ),
            _assistant('done'),
          ]),
          toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [_EchoTool()])),
        ),
      );
      final events = await AgenticRunner(agent: agent).query(ctx, 'hi').collectAll();
      expect(events.map((event) => event.error), everyElement(isNull));
    });

    expect(agentic, classic);
    expect(agentic.map((span) => span.$2), containsAll(['agent', 'generation', 'tool']));
  });
}
