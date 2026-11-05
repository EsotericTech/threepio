// `LangfuseHandler`: the spans it produces for the callbacks of a run. The
// spans go to an exporter that keeps them in a list; one group checks the
// HTTP request of the real transport against a fake client.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/streaming.dart';
import 'package:threepio_core/threepio_core.dart'
    show OpenRouterChatModel, OpenRouterConfig;

import '../../support/log_capture.dart';

final class _MemoryExporter implements SpanExporter {
  final List<OtlpSpan> spans = [];
  int flushes = 0;
  int shutdowns = 0;
  bool accepting = true;

  @override
  bool add(OtlpSpan span) {
    if (!accepting) return false;
    spans.add(span);
    return true;
  }

  @override
  Future<void> flush() async => flushes++;

  @override
  Future<void> shutdown() async => shutdowns++;

  OtlpSpan named(String name) => spans.singleWhere((span) => span.name == name);

  List<String> get names => [for (final span in spans) span.name];
}

/// A clock that advances one millisecond every time it is read.
DateTime Function() _tickingClock() {
  var now = DateTime.utc(2026, 11, 5, 12);
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

const _model = RunInfo(
  name: '',
  type: 'OpenRouter',
  componentType: ComponentType.chatModel,
);

/// Runs a component the way a graph or the component itself does.
Future<RunContext> _start(RunContext ctx, RunInfo info, Object? input) =>
    onStart(reuseHandlers(ctx, info), input);

Object? _attr(OtlpSpan span, String key) => span.attributes[key];

Object? _json(OtlpSpan span, String key) =>
    jsonDecode(span.attributes[key]! as String);

final class _ThrowingExporter implements SpanExporter {
  @override
  bool add(OtlpSpan span) => throw StateError('exporter bug');

  @override
  Future<void> flush() async => throw StateError('exporter bug');

  @override
  Future<void> shutdown() async => throw StateError('exporter bug');
}

final class _HangingExporter implements SpanExporter {
  @override
  bool add(OtlpSpan span) => true;

  @override
  Future<void> flush() => Completer<void>().future;

  @override
  Future<void> shutdown() => Completer<void>().future;
}

final class _Pause implements InterruptSignal {
  @override
  String toString() => 'paused for approval';
}

final class _Unencodable {
  Map<String, Object?> toJson() => throw StateError('no json');
}

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('span tree', () {
    test('components nest under the trace root and under each other', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(
        base,
        name: 'answer-question',
        userId: 'user-1',
        sessionId: 'session-9',
        input: 'What is the weather?',
        tags: const ['weather'],
      );
      final graphCtx = await _start(
        traceCtx,
        _info(ComponentType.graph, 'agent-graph', 'Graph'),
        'What is the weather?',
      );
      final modelCtx = await _start(graphCtx, _model, [Message.user('hi')]);
      await onEnd(modelCtx, Message.assistant('calling the tool'));
      final toolCtx = await _start(
        graphCtx,
        _info(ComponentType.tool, 'get_weather', 'GetWeather'),
        '{"city":"Oslo"}',
      );
      await onEnd(toolCtx, 'sunny');
      await onEnd(graphCtx, 'It is sunny.');
      expect(exporter.names, ['OpenRouterChatModel', 'get_weather', 'agent-graph']);

      handler.endTrace(traceCtx, 'It is sunny.');
      expect(exporter.names.last, 'answer-question');

      final root = exporter.named('answer-question');
      final graph = exporter.named('agent-graph');
      final model = exporter.named('OpenRouterChatModel');
      final tool = exporter.named('get_weather');

      expect(root.parentSpanId, isNull);
      expect(graph.parentSpanId, root.spanId);
      expect(model.parentSpanId, graph.spanId);
      expect(tool.parentSpanId, graph.spanId);
      expect({for (final span in exporter.spans) span.traceId}, hasLength(1));
      expect({for (final span in exporter.spans) span.spanId}, hasLength(4));
      expect(isValidTraceId(root.traceId), isTrue);

      expect(_attr(root, 'langfuse.observation.type'), 'span');
      expect(_attr(graph, 'langfuse.observation.type'), 'span');
      expect(_attr(model, 'langfuse.observation.type'), 'generation');
      expect(_attr(tool, 'langfuse.observation.type'), 'tool');

      expect(_attr(root, 'langfuse.observation.input'), 'What is the weather?');
      expect(_attr(root, 'langfuse.observation.output'), 'It is sunny.');
      expect(_attr(tool, 'langfuse.observation.metadata.eino_component'), 'Tool');
      expect(_attr(tool, 'langfuse.observation.metadata.eino_type'), 'GetWeather');
      expect(_attr(tool, 'langfuse.observation.input'), '"{\\"city\\":\\"Oslo\\"}"');
      expect(_json(tool, 'langfuse.observation.output'), 'sunny');

      // Langfuse reads the user, the session and the tags of an observation
      // from the observation itself.
      for (final span in exporter.spans) {
        expect(_attr(span, 'langfuse.trace.name'), 'answer-question');
        expect(_attr(span, 'langfuse.user.id'), 'user-1');
        expect(_attr(span, 'langfuse.session.id'), 'session-9');
        expect(_attr(span, 'langfuse.trace.tags'), ['weather']);
        expect(span.endTime.isAfter(span.startTime), isTrue);
        expect(span.status.code, OtlpStatusCode.unset);
      }
    });

    test('each kind of component gets its kind of observation', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      const kinds = {
        ComponentType.agent: 'agent',
        ComponentType.chatModel: 'generation',
        ComponentType.embedder: 'embedding',
        ComponentType.retriever: 'retriever',
        ComponentType.tool: 'tool',
        ComponentType.promptTemplate: 'chain',
        ComponentType.graph: 'span',
        ComponentType.chain: 'span',
        ComponentType.lambda: 'span',
        ComponentType.indexer: 'span',
        ComponentType.toolsNode: 'span',
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
    });

    test('a span is named after the node, else after the implementation',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      for (final info in [
        _info(ComponentType.chatModel, 'summarise', 'OpenAI'),
        _info(ComponentType.chatModel, '', 'OpenAI'),
        _info(ComponentType.retriever),
      ]) {
        await onEnd(await _start(base, info, null), null);
      }
      expect(exporter.names, ['summarise', 'OpenAIChatModel', 'Retriever']);
    });

    test('without a trace every top-level component starts its own', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final outer = await _start(base, _info(ComponentType.chain, 'outer'), 'in');
      final inner = await _start(outer, _info(ComponentType.tool, 'inner'), 'x');
      await onEnd(inner, 'y');
      await onEnd(outer, 'out');
      await onEnd(await _start(base, _info(ComponentType.chain, 'other'), 1), 2);

      final outerSpan = exporter.named('outer');
      expect(outerSpan.parentSpanId, isNull);
      expect(exporter.named('inner').parentSpanId, outerSpan.spanId);
      expect(exporter.named('inner').traceId, outerSpan.traceId);
      expect(exporter.named('other').traceId, isNot(outerSpan.traceId));
      expect(outerSpan.attributes.keys, isNot(contains('langfuse.trace.name')));
    });

    test('callbacks without a run info, or without a start, are ignored',
        () async {
      final (:handler, :exporter) = _setup();
      final ctx = RunContext.background();

      expect(handler.onStart(ctx, RunInfo.unknown, 'x'), same(ctx));
      expect(handler.onEnd(ctx, _model, 'never started'), same(ctx));
      expect(handler.onError(ctx, _model, 'e', StackTrace.empty), same(ctx));
      final (reader, writer) = pipe<Object?>();
      expect(await handler.onEndWithStreamOutput(ctx, _model, reader), same(ctx));
      expect(writer.send(1), isTrue, reason: 'the copy was closed');
      final (input, inputWriter) = pipe<Object?>();
      expect(
        await handler.onStartWithStreamInput(ctx, RunInfo.unknown, input),
        same(ctx),
      );
      expect(inputWriter.send(1), isTrue);

      expect(exporter.spans, isEmpty);
    });
  });

  group('generation', () {
    test('shows the messages, the model, its parameters and the token usage',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      const config = ModelCallbackConfig(
        model: 'z-ai/glm-5.3',
        temperature: 0.2,
        maxTokens: 256,
        topP: 0.9,
        stop: ['END'],
      );

      final ctx = await _start(
        base,
        _model,
        ModelCallbackInput(
          messages: [Message.system('Be brief.'), Message.user('Hi')],
          config: config,
          extra: const {'attempt': 2, 'route': 'primary'},
        ),
      );
      await onEnd(
        ctx,
        ModelCallbackOutput(
          message: Message.assistant('Hello!'),
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
      expect(_json(span, 'langfuse.observation.input'), [
        {'role': 'system', 'content': 'Be brief.'},
        {'role': 'user', 'content': 'Hi'},
      ]);
      expect(
        _json(span, 'langfuse.observation.output'),
        {'role': 'assistant', 'content': 'Hello!'},
      );
      expect(_attr(span, 'langfuse.observation.model.name'), 'z-ai/glm-5.3');
      expect(_json(span, 'langfuse.observation.model.parameters'), {
        'max_tokens': 256,
        'stop': ['END'],
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
    });

    test('takes the plain input and output of a node as well', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _model, [Message.user('Hi')]);
      await onEnd(
        ctx,
        Message.assistant('Hello!').copyWith(
          responseMeta: const ResponseMeta(
            usage: TokenUsage(promptTokens: 3, completionTokens: 2, totalTokens: 5),
          ),
        ),
      );

      final span = exporter.spans.single;
      expect(_json(span, 'langfuse.observation.input'), [
        {'role': 'user', 'content': 'Hi'},
      ]);
      expect(
        (_json(span, 'langfuse.observation.output')! as Map)['content'],
        'Hello!',
      );
      expect(_attr(span, 'gen_ai.usage.input_tokens'), 3);
      expect(_attr(span, 'gen_ai.usage.output_tokens'), 2);
      expect(
        span.attributes.keys,
        isNot(contains('gen_ai.usage.cache_read.input_tokens')),
        reason: 'zero counters are left out',
      );
    });

    test('token details never exceed the totals they are part of', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _model, [Message.user('Hi')]);
      await onEnd(
        ctx,
        ModelCallbackOutput(
          message: Message.assistant('x'),
          tokenUsage: const TokenUsage(
            promptTokens: 10,
            completionTokens: 4,
            totalTokens: 14,
            promptTokenDetails: PromptTokenDetails(cachedTokens: 99),
            completionTokenDetails: CompletionTokenDetails(reasoningTokens: 99),
          ),
        ),
      );

      final span = exporter.spans.single;
      expect(_attr(span, 'gen_ai.usage.cache_read.input_tokens'), 10);
      expect(_attr(span, 'gen_ai.usage.reasoning.output_tokens'), 4);
    });

    test('a parameter JSON has no literal for does not lose the span', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(
        base,
        _model,
        ModelCallbackInput(
          messages: [Message.user('Hi')],
          config: const ModelCallbackConfig(model: 'm', temperature: double.nan),
        ),
      );
      await onEnd(ctx, Message.assistant('x'));

      final span = exporter.spans.single;
      expect(
        _json(span, 'langfuse.observation.model.parameters'),
        {'temperature': 'NaN'},
      );
      expect(span.status.code, OtlpStatusCode.unset);
    });

    test('a payload that is not a model payload is shown as it is', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _model, {'prompt': 'raw'});
      await onEnd(ctx, 'raw answer');

      final span = exporter.spans.single;
      expect(_json(span, 'langfuse.observation.input'), {'prompt': 'raw'});
      expect(_json(span, 'langfuse.observation.output'), 'raw answer');
    });

    test('a streamed answer is joined and timed from its first chunk', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _model, [Message.user('Hi')]);
      final (source, writer) = pipe<ModelCallbackOutput>(capacity: 8);
      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);
      expect(exporter.spans, isEmpty, reason: 'the stream is still open');

      writer
        ..send(ModelCallbackOutput(message: Message.assistant('Hel')))
        ..send(
          ModelCallbackOutput(
            message: Message.assistant('lo').copyWith(
              responseMeta: const ResponseMeta(
                finishReason: 'stop',
                usage: TokenUsage(
                  promptTokens: 6,
                  completionTokens: 2,
                  totalTokens: 8,
                ),
              ),
            ),
            config: const ModelCallbackConfig(model: 'streamed-model'),
          ),
        );
      await writer.close();
      expect((await forCaller.collectAll()).map((c) => c.message!.content), ['Hel', 'lo']);
      await forCaller.close();
      await handler.flush();

      final span = exporter.spans.single;
      final output = _json(span, 'langfuse.observation.output')! as Map;
      expect(output['content'], 'Hello');
      expect(_attr(span, 'langfuse.observation.model.name'), 'streamed-model');
      expect(_attr(span, 'gen_ai.usage.input_tokens'), 6);
      final firstChunk = DateTime.parse(
        _attr(span, 'langfuse.observation.completion_start_time')! as String,
      );
      expect(firstChunk.isUtc, isTrue);
      expect(firstChunk.isAfter(span.startTime), isTrue);
      expect(firstChunk.isBefore(span.endTime), isTrue);
      expect(exporter.flushes, 1);
    });

    test('chunks that do not quite agree are still shown', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      ToolCall fragment(String id, String arguments) => ToolCall(
            id: id,
            index: 0,
            function: FunctionCall(name: 'search', arguments: arguments),
          );

      final ctx = await _start(base, _model, [Message.user('Hi')]);
      final (_, forCaller) = await onEndWithStreamOutput(
        ctx,
        StreamReader.fromIterable([
          Message.assistant('', toolCalls: [fragment('call_a', '{"q":')]),
          Message.assistant('', toolCalls: [fragment('call_b', '1}')]),
        ]),
      );
      await forCaller.close();
      await handler.flush();

      final span = exporter.spans.single;
      final call = ((_json(span, 'langfuse.observation.output')! as Map)['toolCalls']
              as List)
          .single as Map;
      expect(call['id'], 'call_a');
      expect((call['function'] as Map)['arguments'], '{"q":1}');
      expect(span.status.code, OtlpStatusCode.unset);
    });
  });

  group('streams', () {
    test('a span whose input is a stream waits for it before it ends',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final (source, writer) = pipe<String>(capacity: 4);

      final (ctx, forComponent) = await onStartWithStreamInput(
        reuseHandlers(base, _info(ComponentType.lambda, 'joiner')),
        source,
      );
      // The component returns before the handler has read its copy.
      await onEnd(ctx, 'ab');
      await pumpEventQueue();
      expect(exporter.spans, isEmpty, reason: 'the input is still coming');

      writer
        ..send('a')
        ..send('b');
      await writer.close();
      expect(await forComponent.collectAll(), ['a', 'b']);
      await forComponent.close();
      await handler.flush();

      final span = exporter.named('joiner');
      expect(_json(span, 'langfuse.observation.input'), ['a', 'b']);
      expect(_json(span, 'langfuse.observation.output'), 'ab');
    });

    test('several values of a stream become a list', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final (ctx, input) = await onStartWithStreamInput(
        reuseHandlers(base, _info(ComponentType.lambda, 'echo')),
        StreamReader.fromIterable(['a', 'b']),
      );
      await input.close();
      await handler.flush();
      final (_, output) =
          await onEndWithStreamOutput(ctx, StreamReader.fromIterable([1, 2, 3]));
      await output.close();
      await handler.flush();

      final span = exporter.named('echo');
      expect(_json(span, 'langfuse.observation.input'), ['a', 'b']);
      expect(_json(span, 'langfuse.observation.output'), [1, 2, 3]);
    });

    test('an error inside a stream marks the observation as failed', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final (source, writer) = pipe<Message>(capacity: 4);

      final ctx = await _start(base, _model, [Message.user('Hi')]);
      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);
      writer
        ..send(Message.assistant('partial'))
        ..sendError(const FormatException('bad chunk'));
      await writer.close();
      await forCaller.close();
      await handler.flush();

      final span = exporter.spans.single;
      expect(span.status.code, OtlpStatusCode.error);
      expect(span.status.message, startsWith('stream output: FormatException: bad chunk'));
      expect(_attr(span, 'langfuse.observation.level'), 'ERROR');
      expect(
        (_json(span, 'langfuse.observation.output')! as Map)['content'],
        'partial',
        reason: 'what arrived before the error is kept',
      );
    });

    test('the trace root waits for a stream that is still being read', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final (source, writer) = pipe<Message>(capacity: 4);

      final traceCtx = handler.startTrace(base, name: 'chat');
      final ctx = await _start(traceCtx, _model, [Message.user('Hi')]);
      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);
      handler.endTrace(traceCtx);
      await pumpEventQueue();
      expect(exporter.spans, isEmpty);

      writer.send(Message.assistant('done'));
      await writer.close();
      await forCaller.close();
      await handler.flush();

      expect(exporter.names, ['OpenRouterChatModel', 'chat']);
      expect(
        (_json(exporter.named('chat'), 'langfuse.observation.output')! as Map)['content'],
        'done',
        reason: 'without an explicit output the root shows the last one',
      );
    });
  });

  group('errors', () {
    test('a failed component is an ERROR observation and fails the root',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'run');
      final ctx = await _start(traceCtx, _info(ComponentType.tool, 'search'), '{}');
      await onError(ctx, StateError('index is gone'), StackTrace.current);
      await handler.flush();
      handler.endTrace(traceCtx);

      final tool = exporter.named('search');
      const message = 'callback: Bad state: index is gone';
      expect(tool.status.code, OtlpStatusCode.error);
      expect(tool.status.message, message);
      expect(_attr(tool, 'langfuse.observation.level'), 'ERROR');
      expect(_attr(tool, 'langfuse.observation.status_message'), message);
      expect(_attr(tool, 'langfuse.observation.metadata.eino_callback_error'), message);
      expect(
        _json(tool, 'langfuse.observation.output'),
        {'error': 'Bad state: index is gone'},
      );
      final event = tool.events.single;
      expect(event.name, 'exception');
      expect(event.attributes['exception.type'], 'StateError');
      expect(event.attributes['exception.message'], 'Bad state: index is gone');

      final root = exporter.named('run');
      expect(root.status.code, OtlpStatusCode.error);
      expect(_attr(root, 'langfuse.observation.level'), 'ERROR');
      expect(_attr(root, 'langfuse.observation.status_message'), message);
      expect(
        _json(root, 'langfuse.observation.output'),
        {'error': 'Bad state: index is gone'},
      );
    });

    test('a cancelled component is not an error', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'run');
      final ctx = await _start(traceCtx, _model, [Message.user('Hi')]);
      await onError(
        ctx,
        const CancelledException('user pressed stop'),
        StackTrace.current,
      );
      final plain = await _start(traceCtx, _info(ComponentType.tool, 'slow'), '{}');
      await onError(plain, const CancelledException(), StackTrace.current);
      await handler.flush();
      handler.endTrace(traceCtx);

      final model = exporter.named('OpenRouterChatModel');
      expect(model.status.code, OtlpStatusCode.unset);
      expect(model.events, isEmpty);
      expect(model.attributes.keys, isNot(contains('langfuse.observation.level')));
      expect(
        _attr(model, 'langfuse.observation.status_message'),
        'callback: cancelled: user pressed stop',
      );
      expect(
        _attr(model, 'langfuse.observation.metadata.eino_callback_cancelled'),
        'true',
      );
      expect(
        _attr(model, 'langfuse.observation.metadata.eino_cancellation_cause'),
        'user pressed stop',
      );
      expect(
        _json(model, 'langfuse.observation.output'),
        {'cause': 'user pressed stop', 'status': 'cancelled'},
      );

      final slow = exporter.named('slow');
      expect(_attr(slow, 'langfuse.observation.status_message'), 'callback: cancelled');
      expect(
        _json(slow, 'langfuse.observation.output'),
        {'cause': 'cancelled', 'status': 'cancelled'},
      );

      final root = exporter.named('run');
      expect(root.status.code, OtlpStatusCode.unset);
      expect(
        _attr(root, 'langfuse.observation.metadata.eino_callback_cancelled'),
        'true',
      );
    });

    test('an interrupt is not an error either', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'run');
      final ctx = await _start(traceCtx, _info(ComponentType.tool, 'approve'), '{}');
      await onError(ctx, _Pause(), StackTrace.current);
      final wrapped = await _start(traceCtx, _info(ComponentType.graph, 'g'), 1);
      await onError(
        wrapped,
        ThreepioException('node failed', cause: _Pause()),
        StackTrace.current,
      );
      await handler.flush();
      handler.endTrace(traceCtx);

      final tool = exporter.named('approve');
      expect(tool.status.code, OtlpStatusCode.unset);
      expect(
        _attr(tool, 'langfuse.observation.status_message'),
        'callback: interrupted',
      );
      expect(
        _attr(tool, 'langfuse.observation.metadata.eino_callback_interrupted'),
        'true',
      );
      expect(
        _attr(tool, 'langfuse.observation.metadata.eino_interrupt_cause'),
        'paused for approval',
      );
      expect(
        _json(tool, 'langfuse.observation.output'),
        {'cause': 'paused for approval', 'status': 'interrupted'},
      );
      expect(
        _attr(exporter.named('g'), 'langfuse.observation.status_message'),
        'callback: interrupted',
        reason: 'a wrapped interrupt is recognised',
      );
      expect(exporter.named('run').status.code, OtlpStatusCode.unset);
    });

    test('a payload that cannot be written as JSON is a recorded loss',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final ctx =
          await _start(base, _info(ComponentType.lambda, 'odd'), _Unencodable());
      await onEnd(ctx, 'fine');

      final span = exporter.single;
      expect(span.attributes.keys, isNot(contains('langfuse.observation.input')));
      expect(_json(span, 'langfuse.observation.output'), 'fine');
      expect(span.status.code, OtlpStatusCode.error);
      expect(
        span.status.message,
        startsWith('serialize langfuse.observation.input'),
      );
      expect(handler.losses, {LangfuseHandler.payloadSerialization: 1});
    });
  });

  group('agents', () {
    final agent = _info(ComponentType.agent, 'assistant', 'ChatModel');

    test('an agent answers for the failures of what it calls', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'run');
      final agentCtx = await _start(traceCtx, agent, 'question');
      final toolCtx = await _start(agentCtx, _info(ComponentType.tool, 'flaky'), '{}');
      await onError(toolCtx, StateError('try again'), StackTrace.current);
      await handler.flush();
      await onEnd(agentCtx, 'recovered answer');
      handler.endTrace(traceCtx);

      expect(exporter.named('flaky').status.code, OtlpStatusCode.error);
      expect(exporter.named('assistant').status.code, OtlpStatusCode.unset);
      final root = exporter.named('run');
      expect(root.status.code, OtlpStatusCode.unset);
      expect(_json(root, 'langfuse.observation.output'), 'recovered answer');
    });

    test('a failing outermost agent fails the root', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'run');
      final agentCtx = await _start(traceCtx, agent, 'question');
      await onError(agentCtx, StateError('out of retries'), StackTrace.current);
      await handler.flush();
      handler.endTrace(traceCtx);

      expect(exporter.named('run').status.code, OtlpStatusCode.error);
    });

    test('the root shows the outermost agent, whatever ends after it', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'run');
      final outer = await _start(traceCtx, agent, 'question');
      final inner = await _start(
        outer,
        _info(ComponentType.agent, 'researcher', 'ChatModel'),
        'sub-question',
      );
      final tool = await _start(inner, _info(ComponentType.tool, 'late'), '{}');
      await onEnd(inner, 'inner answer');
      await onEnd(outer, 'outer answer');
      await onEnd(tool, 'late tool result');
      handler.endTrace(traceCtx);

      expect(
        _json(exporter.named('run'), 'langfuse.observation.output'),
        'outer answer',
      );
      expect(exporter.named('researcher').parentSpanId, exporter.named('assistant').spanId);
    });

    test('with collapsing, the machinery of an agent gets no spans', () async {
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(collapseAgentInternalSpans: true),
      );
      final base = RunContext.background().withHandlers([handler]);

      // Outside an agent these are ordinary components.
      for (final info in [
        _info(ComponentType.graph, 'ReAct'),
        _info(ComponentType.lambda, 'Init'),
        _info(ComponentType.lambda),
      ]) {
        await onEnd(await _start(base, info, null), null);
      }
      expect(exporter.names, ['ReAct', 'Init', 'Lambda']);
      exporter.spans.clear();

      final agentCtx = await _start(base, agent, 'question');
      var ctx = await _start(agentCtx, _info(ComponentType.chain, 'assistant'), 1);
      ctx = await _start(ctx, _info(ComponentType.graph, 'ReAct'), 1);
      ctx = await _start(ctx, _info(ComponentType.lambda, 'Init'), 1);
      ctx = await _start(ctx, _info(ComponentType.lambda), 1);
      ctx = await _start(ctx, _info(ComponentType.lambda, 'Lambda'), 1);
      final named = await _start(ctx, _info(ComponentType.lambda, 'rewrite'), 1);
      final other = await _start(ctx, _info(ComponentType.chain, 'other-chain'), 1);
      final model = await _start(ctx, _model, [Message.user('q')]);
      await onEnd(model, Message.assistant('a'));
      await onEnd(other, 2);
      await onEnd(named, 2);
      await onEnd(ctx, 2);
      await onEnd(agentCtx, 'a');

      expect(
        exporter.names,
        ['OpenRouterChatModel', 'other-chain', 'rewrite', 'assistant'],
      );
      final agentSpan = exporter.named('assistant');
      expect(_attr(agentSpan, 'langfuse.observation.type'), 'agent');
      for (final name in ['OpenRouterChatModel', 'other-chain', 'rewrite']) {
        expect(exporter.named(name).parentSpanId, agentSpan.spanId);
      }
    });

    test('without collapsing every component has its span', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final agentCtx = await _start(base, agent, 'question');
      final chain =
          await _start(agentCtx, _info(ComponentType.chain, 'assistant'), 1);
      final graph = await _start(chain, _info(ComponentType.graph, 'ReAct'), 1);
      await onEnd(graph, 2);
      await onEnd(chain, 2);
      await onEnd(agentCtx, 'a');

      expect(exporter.names, ['ReAct', 'assistant', 'assistant']);
      expect(
        handler.needed(agentCtx, _info(ComponentType.graph, 'ReAct'), CallbackTiming.onStart),
        isTrue,
      );
    });
  });

  group('traces', () {
    test('the options of startTrace override the settings; tags add up',
        () async {
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(
          name: 'default-name',
          userId: 'default-user',
          sessionId: 'default-session',
          environment: 'production',
          release: 'r1',
          version: 'v1',
          tags: ['app'],
          public: true,
        ),
      );
      final base = RunContext.background();

      handler
        ..endTrace(handler.startTrace(base))
        ..endTrace(
          handler.startTrace(
            base,
            name: 'named',
            userId: 'u2',
            sessionId: 's2',
            environment: 'staging',
            release: 'r2',
            version: 'v2',
            tags: const ['beta'],
            public: false,
            observationType: LangfuseObservationType.agent,
          ),
        );

      final defaults = exporter.named('default-name');
      expect(defaults.attributes, {
        'langfuse.observation.type': 'span',
        'langfuse.trace.name': 'default-name',
        'langfuse.user.id': 'default-user',
        'langfuse.session.id': 'default-session',
        'langfuse.release': 'r1',
        'langfuse.environment': 'production',
        'langfuse.version': 'v1',
        'langfuse.trace.tags': ['app'],
        'langfuse.trace.public': true,
      });

      final named = exporter.named('named');
      expect(named.attributes, {
        'langfuse.observation.type': 'agent',
        'langfuse.trace.name': 'named',
        'langfuse.user.id': 'u2',
        'langfuse.session.id': 's2',
        'langfuse.release': 'r2',
        'langfuse.environment': 'staging',
        'langfuse.version': 'v2',
        'langfuse.trace.tags': ['app', 'beta'],
      });
    });

    test('a trace without a name is called threepio-trace', () {
      final (:handler, :exporter) = _setup();
      handler.endTrace(handler.startTrace(RunContext.background()));
      expect(exporter.names, ['threepio-trace']);
      expect(exporter.spans.single.attributes, {
        'langfuse.observation.type': 'span',
        'langfuse.trace.name': 'threepio-trace',
      });
    });

    test('metadata is written per key, strings as they are, the rest as JSON',
        () {
      final (:handler, :exporter) = _setup();
      handler.endTrace(
        handler.startTrace(
          RunContext.background(),
          metadata: {
            'plan': 'pro',
            'limits': {'rpm': 60},
            'a.b': 1,
            ' ': true,
            'constructor': 'x',
            'broken': _Unencodable(),
          },
        ),
      );

      final attributes = exporter.spans.single.attributes;
      expect(attributes['langfuse.trace.metadata.plan'], 'pro');
      expect(attributes['langfuse.trace.metadata.limits'], '{"rpm":60}');
      expect(attributes['langfuse.trace.metadata.a_b'], '1');
      expect(attributes['langfuse.trace.metadata._'], 'true');
      expect(attributes['langfuse.trace.metadata._constructor'], 'x');
      expect(attributes.keys, isNot(contains('langfuse.trace.metadata.broken')));
      expect(handler.losses, {LangfuseHandler.metadataSerialization: 1});
    });

    test('a valid id becomes the trace id; anything else is ignored', () {
      final (:handler, :exporter) = _setup();
      final wanted = 'ABCDEF0123456789' * 2;

      handler
        ..endTrace(handler.startTrace(RunContext.background(), id: wanted, name: 'a'))
        ..endTrace(handler.startTrace(RunContext.background(), id: 'nope', name: 'b'));

      expect(exporter.named('a').traceId, wanted.toLowerCase());
      expect(isValidTraceId(exporter.named('b').traceId), isTrue);
      expect(exporter.named('b').traceId, isNot('nope'));
    });

    test('a trace started inside another keeps its trace id and is a new root',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final outer = handler.startTrace(base, name: 'outer');
      final step = await _start(outer, _info(ComponentType.chain, 'step'), 1);
      final inner = handler.startTrace(step, name: 'inner');
      handler.endTrace(inner);
      await onEnd(step, 2);
      handler.endTrace(outer);

      expect(exporter.named('inner').traceId, exporter.named('outer').traceId);
      expect(exporter.named('inner').parentSpanId, isNull);
    });

    test('endTrace is safe to call twice and without a trace', () {
      final (:handler, :exporter) = _setup();
      final ctx = handler.startTrace(RunContext.background(), name: 't');

      handler
        ..endTrace(ctx, 'first')
        ..endTrace(ctx, 'second')
        ..endTrace(RunContext.background(), 'no trace here');

      expect(exporter.names, ['t']);
      expect(_attr(exporter.spans.single, 'langfuse.observation.output'), 'first');
    });

    test('a component that starts after endTrace is not part of the trace',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final traceCtx = handler.startTrace(base, name: 't', userId: 'u');

      handler.endTrace(traceCtx);
      await onEnd(await _start(traceCtx, _info(ComponentType.tool, 'late'), 1), 2);

      expect(exporter.names, ['t', 'late']);
      expect(
        exporter.named('late').attributes.keys,
        isNot(contains('langfuse.user.id')),
      );
    });

    test('cancelling the context ends the trace once its components are done',
        () async {
      final (:handler, :exporter) = _setup();
      final token = CancelToken();
      final base =
          RunContext.background(cancelToken: token).withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'cancelled-run');
      final ctx = await _start(traceCtx, _info(ComponentType.tool, 'slow'), 1);
      token.cancel('window closed');
      await pumpEventQueue();
      expect(exporter.spans, isEmpty, reason: 'the tool is still running');

      await onEnd(ctx, 'too late');
      final root = exporter.named('cancelled-run');
      expect(
        _json(root, 'langfuse.observation.output'),
        {'cause': 'window closed', 'status': 'cancelled'},
      );
      expect(
        _attr(root, 'langfuse.observation.status_message'),
        'trace context: cancelled: window closed',
      );
      expect(
        _attr(root, 'langfuse.observation.metadata.eino_cancellation_cause'),
        'window closed',
      );
      expect(root.status.code, OtlpStatusCode.unset);
    });

    test('a cancel without a reason just ends the trace', () async {
      final (:handler, :exporter) = _setup();
      final token = CancelToken();
      handler.startTrace(RunContext.background(cancelToken: token), name: 't');

      token.cancel();
      await pumpEventQueue();

      expect(exporter.spans.single.attributes, {
        'langfuse.observation.type': 'span',
        'langfuse.trace.name': 't',
      });
    });

    test('an ended trace lets go of the cancel token of its context', () async {
      final (:handler, :exporter) = _setup();
      final token = CancelToken();
      final ctx =
          handler.startTrace(RunContext.background(cancelToken: token), name: 't');

      handler.endTrace(ctx, 'done');
      await pumpEventQueue();
      token.cancel('later');
      await pumpEventQueue();

      expect(exporter.spans, hasLength(1));
      expect(_attr(exporter.spans.single, 'langfuse.observation.output'), 'done');
    });

    test('what endTrace is given wins over everything else', () async {
      final (:handler, :exporter) = _setup();
      final token = CancelToken();
      final base =
          RunContext.background(cancelToken: token).withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 't');
      final agentCtx =
          await _start(traceCtx, _info(ComponentType.agent, 'agent'), 'q');
      token.cancel('stop');
      await pumpEventQueue();
      handler.endTrace(traceCtx, 'explicit');
      await onEnd(agentCtx, 'agent answer');

      expect(_attr(exporter.named('t'), 'langfuse.observation.output'), 'explicit');
    });
  });

  group('masking and limits', () {
    test('the mask sees inputs, outputs and metadata before they leave',
        () async {
      final (:handler, :exporter) = _setup(
        LangfuseConfig(
          mask: (value) => value.replaceAll(RegExp(r'sk-\w+'), '[key]'),
        ),
      );
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(
        base,
        name: 't',
        input: 'use sk-abc123',
        metadata: const {'note': 'key sk-zzz'},
      );
      final ctx = await _start(
        traceCtx,
        _model,
        ModelCallbackInput(
          messages: [Message.user('my key is sk-secret1')],
          extra: const {'header': 'Bearer sk-secret2'},
        ),
      );
      await onEnd(ctx, Message.assistant('I will not repeat sk-secret1'));
      handler.endTrace(traceCtx, 'done with sk-abc123');

      final everything =
          jsonEncode([for (final span in exporter.spans) span.attributes]);
      expect(everything, isNot(contains('sk-')));
      expect(everything, contains('[key]'));
      expect(
        _attr(exporter.named('t'), 'langfuse.observation.input'),
        'use [key]',
      );
      expect(
        _attr(exporter.named('t'), 'langfuse.trace.metadata.note'),
        'key [key]',
      );
    });

    test('a value the mask fails on is left out, and the span still ends',
        () async {
      final logs = captureLogs('threepio.observability.langfuse');
      final (:handler, :exporter) = _setup(
        LangfuseConfig(
          mask: (value) =>
              value.contains('boom') ? throw StateError('mask bug') : value,
        ),
      );
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 't', input: 'boom');
      final ctx = await _start(traceCtx, _info(ComponentType.tool, 'tool'), 'boom');
      await onEnd(ctx, 'fine');
      handler.endTrace(traceCtx);

      final tool = exporter.named('tool');
      expect(tool.attributes.keys, isNot(contains('langfuse.observation.input')));
      expect(_json(tool, 'langfuse.observation.output'), 'fine');
      expect(
        exporter.named('t').attributes.keys,
        isNot(contains('langfuse.observation.input')),
      );
      expect(handler.losses, {LangfuseHandler.maskFailed: 2});
      expect(logs.map((r) => r.message).toSet(), {'The Langfuse mask function failed'});
    });

    test('the mask sees the error message of a failed component too', () async {
      final (:handler, :exporter) = _setup(
        LangfuseConfig(mask: (value) => value.replaceAll('hunter2', '[pw]')),
      );
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 't');
      final ctx = await _start(traceCtx, _info(ComponentType.tool, 'login'), '{}');
      await onError(
        ctx,
        StateError('wrong password hunter2'),
        StackTrace.current,
      );
      await handler.flush();
      handler.endTrace(traceCtx);

      for (final span in exporter.spans) {
        final everything = jsonEncode(span.toJson());
        expect(everything, isNot(contains('hunter2')), reason: span.name);
        expect(everything, contains('[pw]'), reason: span.name);
        expect(span.status.message, 'callback: Bad state: wrong password [pw]');
      }
      expect(
        exporter.named('login').events.single.attributes['exception.message'],
        'Bad state: wrong password [pw]',
      );
    });

    test('a value over the limit is cut and stays valid JSON', () async {
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(maxAttributeValueLength: 120),
      );
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _info(ComponentType.tool, 'big'), 'x' * 500);
      await onEnd(ctx, 'short');

      final span = exporter.spans.single;
      final input = _attr(span, 'langfuse.observation.input')! as String;
      expect(input.length, lessThanOrEqualTo(120));
      final preview = jsonDecode(input) as Map;
      expect(preview['truncated'], isTrue);
      expect(preview['original_length'], 502);
      expect(preview['preview'], contains('...[truncated]...'));
      expect(_json(span, 'langfuse.observation.output'), 'short');
      expect(handler.losses, {LangfuseHandler.valueLimit: 1});
    });

    test('a negative limit means no limit', () async {
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(
          maxAttributeValueLength: -1,
          maxSpanAttributeLength: -1,
        ),
      );
      final base = RunContext.background().withHandlers([handler]);

      final ctx =
          await _start(base, _info(ComponentType.tool, 'big'), 'x' * 2000000);
      await onEnd(ctx, 'y');

      final input = _attr(exporter.spans.single, 'langfuse.observation.input')! as String;
      expect(input.length, 2000002);
      expect(handler.losses, isEmpty);
    });

    test('a span stops taking attributes when its budget is used up', () async {
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(maxSpanAttributeLength: 300),
      );
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _info(ComponentType.tool, 'big'), 'x' * 400);
      await onEnd(ctx, 'y' * 400);

      final span = exporter.spans.single;
      final written = span.attributes.entries
          .fold<int>(0, (sum, e) => sum + e.key.length + '${e.value}'.length);
      expect(written, lessThanOrEqualTo(300));
      expect(_attr(span, 'langfuse.observation.type'), 'tool');
      final input = _attr(span, 'langfuse.observation.input')! as String;
      expect((jsonDecode(input) as Map)['truncated'], isTrue);
      // What is left of the budget after the input does not hold a preview
      // of the output; an empty JSON object says that there was one.
      expect(_attr(span, 'langfuse.observation.output'), '{}');
      expect(handler.losses[LangfuseHandler.spanAttributeBudget], 2);
    });

    test('nothing at all is written once the budget is gone', () async {
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(maxSpanAttributeLength: 80),
      );
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _info(ComponentType.tool, 'big'), 'input');
      await onEnd(ctx, 'output');

      expect(exporter.spans.single.attributes.keys, [
        'langfuse.observation.type',
        'langfuse.observation.metadata.eino_component',
      ]);
      expect(handler.losses[LangfuseHandler.spanAttributeBudget], 2);
    });

    test('the first attributes of a span are fitted into the budget too', () {
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(maxSpanAttributeLength: 90),
      );

      handler.endTrace(
        handler.startTrace(
          RunContext.background(),
          name: 'n',
          userId: 'u',
          input: 'i' * 300,
          tags: const ['a-tag-that-does-not-fit-any-more'],
        ),
      );

      final attributes = exporter.spans.single.attributes;
      expect(attributes['langfuse.observation.type'], 'span');
      expect(attributes['langfuse.trace.name'], 'n');
      expect(attributes['langfuse.user.id'], 'u');
      expect(attributes.keys, isNot(contains('langfuse.trace.tags')));
      expect(handler.losses[LangfuseHandler.spanAttributeBudget], greaterThan(0));
    });
  });

  group('sampling', () {
    test('a trace is exported whole or not at all', () async {
      final (:handler, :exporter) = _setup(const LangfuseConfig(sampleRate: 0.5));
      final base = RunContext.background().withHandlers([handler]);
      final keptId = '${'0' * 31}1';
      final droppedId = '${'0' * 16}${'f' * 16}';

      for (final id in [keptId, droppedId]) {
        final traceCtx = handler.startTrace(base, id: id, name: 'trace-$id');
        final ctx = await _start(traceCtx, _info(ComponentType.tool, 'tool-$id'), 1);
        await onEnd(ctx, 2);
        handler.endTrace(traceCtx);
      }

      expect(exporter.names, ['tool-$keptId', 'trace-$keptId']);
      expect(handler.losses, {LangfuseHandler.sampledOut: 2});
    });

    test('0 and 1 both export everything', () {
      for (final rate in [0.0, 1.0]) {
        final (:handler, :exporter) = _setup(LangfuseConfig(sampleRate: rate));
        handler.endTrace(
          handler.startTrace(
            RunContext.background(),
            id: '${'0' * 16}${'f' * 16}',
          ),
        );
        expect(exporter.spans, hasLength(1));
      }
    });
  });

  group('flush and shutdown', () {
    test('shutdown closes open traces and flushes an exporter it was given',
        () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final traceCtx = handler.startTrace(base, name: 'open');
      final ctx = await _start(traceCtx, _info(ComponentType.tool, 'done'), 1);
      await onEnd(ctx, 'tool output');

      await handler.shutdown();

      expect(exporter.names, ['done', 'open']);
      expect(_json(exporter.named('open'), 'langfuse.observation.output'), 'tool output');
      expect(exporter.flushes, 1);
      expect(exporter.shutdowns, 0, reason: 'the exporter is the caller\'s');

      // What ends afterwards is not exported, and no stream is read.
      final late = await _start(base, _info(ComponentType.tool, 'late'), 1);
      await onEnd(late, 2);
      final (reader, writer) = pipe<Object?>();
      final (_, rest) = await onStartWithStreamInput(
        reuseHandlers(base, _info(ComponentType.lambda, 'late-stream')),
        reader,
      );
      await rest.close();
      expect(writer.send(1), isTrue);
      expect(exporter.names, ['done', 'open']);
      expect(handler.losses, {LangfuseHandler.afterShutdown: 1});
    });

    test('a component that starts while the handler shuts down has its own '
        'observation', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final agentCtx =
          await _start(base, _info(ComponentType.agent, 'agent'), 'question');

      // A stream that is still open keeps the shutdown waiting.
      final (source, writer) = pipe<Message>(capacity: 2);
      final streaming = await _start(agentCtx, _model, [Message.user('q')]);
      final (_, forCaller) = await onEndWithStreamOutput(streaming, source);
      final shutdown = handler.shutdown();
      await pumpEventQueue();

      // The agent goes on: a tool starts and ends, then one fails, then the
      // agent itself ends. None of them may end another one's observation.
      final toolCtx = await _start(agentCtx, _info(ComponentType.tool, 'tool'), '{}');
      await onEnd(toolCtx, 'tool result');
      final failing =
          await _start(agentCtx, _info(ComponentType.tool, 'failing'), '{}');
      await onError(failing, StateError('nope'), StackTrace.current);
      final (lateStream, lateWriter) = pipe<Message>();
      final lateModel = await _start(agentCtx, _model, [Message.user('again')]);
      final (_, lateRest) = await onEndWithStreamOutput(lateModel, lateStream);
      await lateRest.close();
      expect(
        lateWriter.send(Message.assistant('x')),
        isTrue,
        reason: 'the handler does not read a new stream while shutting down',
      );
      await onEnd(agentCtx, 'agent answer');

      writer.send(Message.assistant('streamed'));
      await writer.close();
      await forCaller.close();
      await shutdown;

      expect(
        exporter.names,
        ['tool', 'failing', 'OpenRouterChatModel', 'agent', 'OpenRouterChatModel'],
      );
      expect(_json(exporter.named('tool'), 'langfuse.observation.output'), 'tool result');
      expect(exporter.named('failing').status.code, OtlpStatusCode.error);
      final agent = exporter.named('agent');
      expect(_attr(agent, 'langfuse.observation.type'), 'agent');
      expect(_json(agent, 'langfuse.observation.output'), 'agent answer');
      expect(_json(agent, 'langfuse.observation.input'), 'question');
      for (final name in ['tool', 'failing']) {
        expect(exporter.named(name).parentSpanId, agent.spanId);
      }
    });

    test('an exporter that throws does not reach the run or endTrace',
        () async {
      final logs = captureLogs('threepio.observability.langfuse');
      final handler = LangfuseHandler(
        const LangfuseConfig(),
        exporter: _ThrowingExporter(),
        random: Random(1),
      );
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 't');
      final ctx = await _start(traceCtx, _info(ComponentType.tool, 'tool'), 1);
      await onEnd(ctx, 2);
      expect(() => handler.endTrace(traceCtx, 'done'), returnsNormally);
      await handler.shutdown();

      expect(handler.losses[LangfuseHandler.exporterRefused], 2);
      expect(
        logs.map((r) => r.message),
        containsAll([
          'langfuse exporter failed to take a span',
          'langfuse exporter failed to flush',
        ]),
      );
    });

    test('with a timeout an exporter that does not answer is given up on', () {
      fakeAsync((async) {
        final logs = captureLogs('threepio.observability.langfuse');
        final handler = LangfuseHandler(
          const LangfuseConfig(),
          exporter: _HangingExporter(),
          random: Random(1),
        );
        var flushed = false;
        var shutDown = false;

        unawaited(
          handler
              .flush(timeout: const Duration(seconds: 2))
              .then((_) => flushed = true),
        );
        async.elapse(const Duration(seconds: 2));
        expect(flushed, isTrue);

        unawaited(
          handler
              .shutdown(timeout: const Duration(seconds: 3))
              .then((_) => shutDown = true),
        );
        async.elapse(const Duration(milliseconds: 2999));
        expect(shutDown, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(shutDown, isTrue);
        expect(
          logs.map((r) => r.message),
          everyElement(contains('stopped waiting for the exporter to flush')),
        );
        expect(logs, hasLength(2));
      });
    });

    test('the timeout of shutdown reaches the built-in exporter', () {
      fakeAsync((async) {
        captureLogs('threepio.observability');
        var requests = 0;
        final handler = LangfuseHandler(
          const LangfuseConfig(
            host: 'https://lf.example.com',
            publicKey: 'pk',
            secretKey: 'sk',
            timeout: Duration(minutes: 10),
          ),
          httpClient: MockClient((request) {
            requests++;
            return Completer<http.Response>().future;
          }),
          random: Random(1),
        );
        var done = false;

        handler.endTrace(handler.startTrace(RunContext.background(), name: 't'));
        unawaited(
          handler
              .shutdown(timeout: const Duration(seconds: 2))
              .then((_) => done = true),
        );
        async.elapse(const Duration(milliseconds: 1999));
        expect(done, isFalse);
        async.elapse(const Duration(milliseconds: 1));

        expect(done, isTrue);
        expect(requests, 1);
      });
    });

    test('flush waits for the streams that are still being read', () async {
      final (:handler, :exporter) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final (source, writer) = pipe<Message>(capacity: 2);
      final ctx = await _start(base, _model, [Message.user('q')]);
      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);

      var flushed = false;
      unawaited(handler.flush().then((_) => flushed = true));
      await pumpEventQueue();
      expect(flushed, isFalse);

      writer.send(Message.assistant('a'));
      await writer.close();
      await forCaller.close();
      await pumpEventQueue();
      expect(flushed, isTrue);
      expect(exporter.spans, hasLength(1));
    });

    test('with a timeout a stream that never ends is given up on', () {
      fakeAsync((async) {
        final logs = captureLogs('threepio.observability.langfuse');
        final (:handler, :exporter) = _setup();
        final base = RunContext.background().withHandlers([handler]);
        final (source, _) = pipe<Message>(capacity: 2);
        var done = false;

        unawaited(() async {
          final ctx = await _start(base, _model, [Message.user('q')]);
          await onEndWithStreamOutput(ctx, source);
          await handler.shutdown(timeout: const Duration(seconds: 2));
          done = true;
        }());
        async.elapse(const Duration(milliseconds: 1999));
        expect(done, isFalse);
        async.elapse(const Duration(milliseconds: 1));

        expect(done, isTrue);
        expect(exporter.spans, isEmpty);
        expect(logs.single.level, Level.WARNING);
        expect(logs.single.message, contains('stopped waiting for 1 stream(s)'));
      });
    });

    test('losses are reported once, as one warning', () async {
      final logs = captureLogs('threepio.observability.langfuse');
      final (:handler, :exporter) = _setup(
        const LangfuseConfig(maxAttributeValueLength: 10),
      );
      final base = RunContext.background().withHandlers([handler]);
      exporter.accepting = false;

      final ctx = await _start(base, _info(ComponentType.tool, 't'), 'x' * 50);
      await onEnd(ctx, 'y' * 50);
      await handler.flush();
      await handler.flush();

      expect(handler.losses, {
        LangfuseHandler.valueLimit: 2,
        LangfuseHandler.exporterRefused: 1,
      });
      expect(logs.map((r) => r.message), [
        'langfuse callback discarded telemetry since the previous report: '
            'exporter_refused_spans=1 value_limit_truncations=2',
      ]);
    });
  });

  group('transport', () {
    test('spans are posted to the OTLP endpoint of Langfuse', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      });
      final handler = LangfuseHandler(
        const LangfuseConfig(
          host: 'https://cloud.langfuse.com/',
          publicKey: 'pk-lf-1',
          secretKey: 'sk-lf-2',
          serviceName: 'kortshut',
        ),
        httpClient: client,
        random: Random(2),
      );
      final base = RunContext.background().withHandlers([handler]);

      final traceCtx = handler.startTrace(base, name: 'http-trace');
      final ctx = await _start(traceCtx, _model, [Message.user('Hi')]);
      await onEnd(ctx, Message.assistant('Hello'));
      handler.endTrace(traceCtx, 'Hello');
      await handler.shutdown();

      final request = requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://cloud.langfuse.com/api/public/otel/v1/traces',
      );
      expect(
        request.headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('pk-lf-1:sk-lf-2'))}',
      );
      expect(request.headers['x-langfuse-ingestion-version'], '4');
      expect(request.headers['content-type'], startsWith('application/json'));

      final body = jsonDecode(request.body) as Map<String, Object?>;
      final resourceSpans = (body['resourceSpans']! as List).single as Map;
      final resource = {
        for (final entry in (resourceSpans['resource'] as Map)['attributes'] as List)
          (entry as Map)['key']: (entry['value'] as Map).values.single,
      };
      expect(resource, {
        'service.name': 'kortshut',
        'telemetry.sdk.name': 'threepio_core',
        'telemetry.sdk.language': 'dart',
      });
      final scopeSpans = (resourceSpans['scopeSpans'] as List).single as Map;
      expect(scopeSpans['scope'], {
        'name': LangfuseHandler.instrumentationName,
        'version': LangfuseHandler.instrumentationVersion,
      });
      final spans = scopeSpans['spans'] as List;
      expect(
        [for (final span in spans) (span as Map)['name']],
        ['OpenRouterChatModel', 'http-trace'],
      );
      expect((spans.first as Map)['parentSpanId'], (spans.last as Map)['spanId']);
    });

    test('a real model call ends up as a generation', () async {
      final (:handler, :exporter) = _setup();
      GlobalCallbacks.append([handler]);
      final model = OpenRouterChatModel(
        config: const OpenRouterConfig(apiKey: 'k', defaultModel: 'z-ai/glm-5.3'),
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'id': 'gen-1',
              'choices': [
                {
                  'index': 0,
                  'message': {'role': 'assistant', 'content': 'Hello!'},
                  'finish_reason': 'stop',
                },
              ],
              'usage': {
                'prompt_tokens': 9,
                'completion_tokens': 2,
                'total_tokens': 11,
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      final traceCtx = handler.startTrace(RunContext.background(), name: 'chat');
      await model.generate(
        [Message.user('Hi')],
        options: ChatModelOptions(runContext: traceCtx, temperature: 0.3),
      );
      handler.endTrace(traceCtx);

      final generation = exporter.named('OpenRouterChatModel');
      expect(generation.parentSpanId, exporter.named('chat').spanId);
      expect(_attr(generation, 'langfuse.observation.type'), 'generation');
      expect(_attr(generation, 'langfuse.observation.model.name'), 'z-ai/glm-5.3');
      expect(
        _json(generation, 'langfuse.observation.model.parameters'),
        {'temperature': 0.3},
      );
      expect(_attr(generation, 'gen_ai.usage.input_tokens'), 9);
      expect(_attr(generation, 'gen_ai.usage.output_tokens'), 2);
      expect(
        (_json(generation, 'langfuse.observation.output')! as Map)['content'],
        'Hello!',
      );
    });
  });

  group('settings', () {
    test('the trace endpoint is derived from the host', () {
      const expected = 'https://lf.example.com/api/public/otel/v1/traces';
      for (final host in [
        'https://lf.example.com',
        'https://lf.example.com/',
        '  https://lf.example.com//  ',
        'https://lf.example.com/api/public/otel',
        'https://lf.example.com/api/public/otel/v1/traces',
      ]) {
        expect('${LangfuseConfig.traceEndpoint(host)}', expected, reason: host);
      }
      expect(
        '${LangfuseConfig.traceEndpoint('http://localhost:3000/langfuse')}',
        'http://localhost:3000/langfuse/api/public/otel/v1/traces',
      );
    });

    test('a host that is not a URL is refused', () {
      for (final host in ['', '   ', 'cloud.langfuse.com', '/api/public/otel']) {
        expect(
          () => LangfuseConfig.traceEndpoint(host),
          throwsArgumentError,
          reason: host,
        );
      }
    });

    test('without an exporter the host and both keys are required', () {
      expect(() => LangfuseHandler(const LangfuseConfig()), throwsArgumentError);
      expect(
        () => LangfuseHandler(
          const LangfuseConfig(host: 'https://lf.example.com', publicKey: 'pk'),
        ),
        throwsArgumentError,
      );
      expect(
        () => LangfuseHandler(
          const LangfuseConfig(host: 'https://lf.example.com', secretKey: 'sk'),
        ),
        throwsArgumentError,
      );
      expect(
        LangfuseHandler(
          const LangfuseConfig(
            host: 'https://lf.example.com',
            publicKey: 'pk',
            secretKey: 'sk',
            maxQueueSize: 100,
          ),
        ),
        isA<ComponentCallbackHandler>(),
        reason: 'the batch size follows a small queue',
      );
    });

    test('the sample rate has to be between 0 and 1', () {
      for (final rate in [-0.5, 1.5, double.nan]) {
        expect(
          () => LangfuseHandler(
            LangfuseConfig(sampleRate: rate),
            exporter: _MemoryExporter(),
          ),
          throwsArgumentError,
        );
      }
    });

    test('defaults', () {
      const config = LangfuseConfig();
      expect(config.serviceName, 'threepio-langfuse');
      expect(config.timeout, const Duration(seconds: 10));
      expect(config.sampleRate, 1);
      expect(config.maxQueueSize, 2048);
      expect(config.maxExportBatchSize, isNull);
      expect(config.batchTimeout, const Duration(seconds: 5));
      expect(config.maxAttributeValueLength, 1000000);
      expect(config.maxSpanAttributeLength, 4000000);
      expect(config.collapseAgentInternalSpans, isFalse);
      expect(config.public, isFalse);
      expect(config.tags, isEmpty);
    });

    test('the observation types are the strings Langfuse knows', () {
      expect(
        [for (final type in LangfuseObservationType.values) type.name],
        [
          'event',
          'span',
          'generation',
          'agent',
          'tool',
          'chain',
          'retriever',
          'evaluator',
          'embedding',
          'guardrail',
        ],
      );
    });
  });
}

extension on _MemoryExporter {
  OtlpSpan get single => spans.single;
}
