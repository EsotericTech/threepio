// Handlers written for the older, map-based callback API (the shape of the
// consumer's `JobStatusCallbackHandler` and `ActionLoggingHandler`) taking
// part in a run of the new kind through `LegacyCallbackHandlerAdapter`, and
// the older API itself after its deprecation.
// The older API is what this file is about.
// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart' as callbacks;
import 'package:threepio_core/threepio_core.dart';

import '../support/log_capture.dart';

/// The shape of the application's `JobStatusCallbackHandler`: it keeps
/// timings in the map it is handed, treats the first start (an empty map) as
/// the start of the job, and reports the end of the top-level component.
class _JobStatusHandler extends BaseCallbackHandler {
  final List<String> status = [];

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    if (info.name == 'ActionGraph' || context.isEmpty) {
      status.add('running: ${input.data}');
    }
    context['current_node'] = info.name;
    context['started'] = (context['started'] as int? ?? 0) + 1;
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    context['last_node'] = context['current_node'];
    if (info.name == 'ActionGraph') status.add('completed: ${output.data}');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) async {
    status.add('failed: $error');
    context['error'] = error.toString();
    context['failed_node'] = info.name;
    return context;
  }
}

/// The shape of `ActionLoggingHandler`: a second handler that reads what the
/// first one left in the map.
class _LoggingHandler extends BaseCallbackHandler {
  final List<String> lines = [];

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    lines.add('start ${info.name} (${info.componentType.name}) '
        'job=${context['job_id']} node=${context['current_node']}');
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    lines.add('end ${info.name} last=${context['last_node']}');
    return context;
  }
}

/// Implements the interface directly and replaces the map instead of
/// changing it.
class _ReplacingHandler implements CallbackHandler {
  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async =>
      {...context, 'replaced': true};

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async =>
      {...context, 'ended': output.data};

  @override
  Future<Map<String, dynamic>> onError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) async =>
      context;

  @override
  Future<Map<String, dynamic>> onStartWithStreamInput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> input,
  ) async =>
      context;

  @override
  Future<Map<String, dynamic>> onEndWithStreamOutput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> output,
  ) async =>
      context;
}

/// Listens to the streams it is given.
class _StreamListener extends BaseCallbackHandler {
  final List<dynamic> inputs = [];
  final List<dynamic> outputs = [];
  final Completer<void> outputDone = Completer<void>();

  @override
  Future<Map<String, dynamic>> onStartWithStreamInput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> input,
  ) async {
    inputs.addAll(await input.toList());
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEndWithStreamOutput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> output,
  ) async {
    output.listen(outputs.add, onDone: outputDone.complete);
    return context;
  }
}

const _graph = RunInfo(
  name: 'ActionGraph',
  type: 'StateGraph',
  componentType: ComponentType.chain,
);
const _node = RunInfo(
  name: 'llm_node',
  type: 'GraphNode',
  componentType: ComponentType.chain,
);

void main() {
  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  group('LegacyCallbackHandlerAdapter', () {
    test('a job-status handler follows a graph and its node', () async {
      failOnLoggedWarnings('threepio.callbacks');
      final job = _JobStatusHandler();
      final base = RunContext.background()
          .withHandlers([LegacyCallbackHandlerAdapter(job)]);

      final graphCtx =
          await callbacks.onStart(reuseHandlers(base, _graph), 'text in');
      final nodeCtx =
          await callbacks.onStart(reuseHandlers(graphCtx, _node), 'prompt');
      final afterNode = await callbacks.onEnd(nodeCtx, 'answer');
      final afterGraph = await callbacks.onEnd(graphCtx, 'text out');

      expect(job.status, ['running: text in', 'completed: text out']);

      // The node saw what the graph's start hook left and added to it ...
      final nodeMap = LegacyCallbackHandlerAdapter.legacyContextOf(afterNode)!;
      expect(nodeMap['started'], 2);
      expect(nodeMap['current_node'], 'llm_node');
      expect(nodeMap['last_node'], 'llm_node');

      // ... and the graph's end hook sees the graph's own map, not the
      // node's: like a context, the map only flows inwards.
      final graphMap = LegacyCallbackHandlerAdapter.legacyContextOf(afterGraph)!;
      expect(graphMap['started'], 1);
      expect(graphMap['current_node'], 'ActionGraph');
      expect(graphMap['last_node'], 'ActionGraph');
      expect(LegacyCallbackHandlerAdapter.legacyContextOf(base), isNull);
    });

    test('components that run next to each other do not share a map', () async {
      failOnLoggedWarnings('threepio.callbacks');
      final job = _JobStatusHandler();
      final base = RunContext.background()
          .withHandlers([LegacyCallbackHandlerAdapter(job)]);
      final graphCtx = await callbacks.onStart(reuseHandlers(base, _graph), 'in');
      RunInfo tool(String name) =>
          RunInfo(name: name, type: 'T', componentType: ComponentType.tool);

      // Two tool calls in parallel: both start before either ends.
      final first = await callbacks.onStart(reuseHandlers(graphCtx, tool('a')), 1);
      final second = await callbacks.onStart(reuseHandlers(graphCtx, tool('b')), 2);
      final firstEnd = await callbacks.onEnd(first, 'x');
      final secondEnd = await callbacks.onEnd(second, 'y');

      expect(
        LegacyCallbackHandlerAdapter.legacyContextOf(firstEnd)!['last_node'],
        'a',
      );
      expect(
        LegacyCallbackHandlerAdapter.legacyContextOf(secondEnd)!['last_node'],
        'b',
      );
      expect(
        LegacyCallbackHandlerAdapter.legacyContextOf(graphCtx)!['current_node'],
        'ActionGraph',
        reason: 'the map of the graph was not changed under it',
      );
    });

    test('a model call arrives the way the providers used to report it',
        () async {
      final seen = <Object?>[];
      final base = RunContext.background()
          .withHandlers([LegacyCallbackHandlerAdapter(_Probe(seen))]);
      final messages = [Message.user('hi')];
      final answer = Message.assistant('hello');
      const config = ModelCallbackConfig(model: 'z-ai/glm-5.3');
      final input = ModelCallbackInput(messages: messages, config: config);
      final output = ModelCallbackOutput(message: answer, config: config);

      final ctx = await callbacks.onStart(
        ensureRunInfo(base, 'OpenRouter', ComponentType.chatModel),
        input,
      );
      await callbacks.onEnd(ctx, output);

      final (startInfo, startData, startMetadata) =
          seen[0]! as (RunInfo, Object?, Object?);
      expect(startInfo.name, 'OpenRouterChatModel');
      expect(startInfo.type, 'OpenRouter');
      expect(startInfo.metadata, {'model': 'z-ai/glm-5.3'});
      expect(startData, same(messages));
      expect(startMetadata, {'payload': input});

      final (endInfo, endData, endMetadata) =
          seen[1]! as (RunInfo, Object?, Object?);
      expect(endInfo.name, 'OpenRouterChatModel');
      expect(endData, same(answer));
      expect(endMetadata, {'payload': output});
    });

    test('the other typed payloads arrive as their plain value', () async {
      final seen = <Object?>[];
      final handler = LegacyCallbackHandlerAdapter(_Probe(seen));
      final ctx = RunContext.background();
      const doc = Document(id: 'd', content: 'text');
      const source = DocumentSource(uri: 'file:///a');
      final toolResult = ToolResult.text('rich');

      final inputs = <Object, Object?>{
        const PromptCallbackInput(variables: {'k': 'v'}): {'k': 'v'},
        const ToolCallbackInput(argumentsJson: '{}'): '{}',
        const EmbeddingCallbackInput(texts: ['a']): ['a'],
        const RetrieverCallbackInput(query: 'q'): 'q',
        const IndexerCallbackInput(docs: [doc]): [doc],
        const LoaderCallbackInput(source: source): source,
        const TransformerCallbackInput(input: [doc]): [doc],
      };
      final outputs = <Object, Object?>{
        PromptCallbackOutput(result: [Message.user('m')]): [Message.user('m')],
        const ToolCallbackOutput(response: 'done'): 'done',
        ToolCallbackOutput(toolOutput: toolResult): toolResult,
        const EmbeddingCallbackOutput(embeddings: [
          [0.5],
        ]): [
          [0.5],
        ],
        const RetrieverCallbackOutput(docs: [doc]): [doc],
        const IndexerCallbackOutput(ids: ['1']): ['1'],
        const LoaderCallbackOutput(docs: [doc]): [doc],
        const TransformerCallbackOutput(output: [doc]): [doc],
      };

      for (final MapEntry(key: payload, value: plain) in inputs.entries) {
        seen.clear();
        await handler.onStart(ctx, _node, payload);
        final (_, data, metadata) = seen.single! as (RunInfo, Object?, Object?);
        expect(data, plain, reason: '${payload.runtimeType}');
        expect(metadata, {'payload': payload});
      }
      for (final MapEntry(key: payload, value: plain) in outputs.entries) {
        seen.clear();
        await handler.onEnd(ctx, _node, payload);
        final (_, data, metadata) = seen.single! as (RunInfo, Object?, Object?);
        expect(data, plain, reason: '${payload.runtimeType}');
        expect(metadata, {'payload': payload});
      }
    });

    test('the chunks of a model stream arrive as messages', () async {
      failOnLoggedWarnings('threepio.callbacks');
      final listener = _StreamListener();
      final base = RunContext.background()
          .withHandlers([LegacyCallbackHandlerAdapter(listener)]);
      final ctx = await callbacks.onStart(reuseHandlers(base, _node), 'in');

      final (_, output) = await callbacks.onEndWithStreamOutput(
        ctx,
        StreamReader.fromIterable([
          ModelCallbackOutput(message: Message.assistant('a')),
          ModelCallbackOutput(message: Message.assistant('b')),
        ]),
      );
      await output.close();
      await listener.outputDone.future;

      expect(listener.outputs.map((m) => (m as Message).content), ['a', 'b']);
    });

    test('a handler that makes the stream a broadcast stream keeps its copy',
        () async {
      failOnLoggedWarnings('threepio.callbacks');
      final handler = _BroadcastListener();
      final base = RunContext.background()
          .withHandlers([LegacyCallbackHandlerAdapter(handler)]);
      final ctx = await callbacks.onStart(reuseHandlers(base, _node), 'in');
      final (source, writer) = pipe<int>(capacity: 4);

      final (_, output) = await callbacks.onEndWithStreamOutput(ctx, source);
      writer
        ..send(1)
        ..send(2);
      await writer.close();
      await output.close();
      await handler.done.future;

      expect(handler.items, [1, 2]);
    });

    test('the error hook gets the error and the map of the start hook',
        () async {
      final job = _JobStatusHandler();
      final base = RunContext.background()
          .withHandlers([LegacyCallbackHandlerAdapter(job)]);
      final ctx = await callbacks.onStart(reuseHandlers(base, _node), 'in');

      final after =
          await callbacks.onError(ctx, StateError('no model'), StackTrace.current);

      expect(job.status.last, 'failed: Bad state: no model');
      final map = LegacyCallbackHandlerAdapter.legacyContextOf(after)!;
      expect(map['failed_node'], 'llm_node');
      expect(map['current_node'], 'llm_node');
    });

    test('adapted handlers share one map, like the handlers of a manager',
        () async {
      failOnLoggedWarnings('threepio.callbacks');
      final job = _JobStatusHandler();
      final logging = _LoggingHandler();
      // On start the last handler runs first, so the job handler is last.
      final seeded = LegacyCallbackHandlerAdapter.withLegacyContext(
        RunContext.background(),
        {'job_id': 'job-7'},
      );
      final base = seeded.withHandlers([
        LegacyCallbackHandlerAdapter(logging),
        LegacyCallbackHandlerAdapter(job),
      ]);

      final ctx = await callbacks.onStart(reuseHandlers(base, _graph), 'in');
      await callbacks.onEnd(ctx, 'out');

      expect(logging.lines, [
        'start ActionGraph (chain) job=job-7 node=ActionGraph',
        'end ActionGraph last=null',
      ]);
      expect(job.status, ['running: in', 'completed: out']);
      expect(
        LegacyCallbackHandlerAdapter.legacyContextOf(ctx),
        containsPair('job_id', 'job-7'),
      );
    });

    test('a handler that returns a new map replaces the map', () async {
      final base = RunContext.background()
          .withHandlers([LegacyCallbackHandlerAdapter(_ReplacingHandler())]);

      final started = await callbacks.onStart(reuseHandlers(base, _node), 1);
      expect(
        LegacyCallbackHandlerAdapter.legacyContextOf(started),
        {'replaced': true},
      );
      final ended = await callbacks.onEnd(started, 'out');
      expect(
        LegacyCallbackHandlerAdapter.legacyContextOf(ended),
        {'replaced': true, 'ended': 'out'},
      );
      expect(
        LegacyCallbackHandlerAdapter.legacyContextOf(started),
        {'replaced': true},
        reason: 'the earlier context still has the earlier map',
      );
    });

    test('payloads arrive wrapped, with the run info of the new API', () async {
      final seen = <Object?>[];
      final handler = LegacyCallbackHandlerAdapter(_Probe(seen));
      final ctx = RunContext.background();

      await handler.onStart(ctx, _node, 'in');
      await handler.onEnd(ctx, _node, 42);

      expect(seen, [
        (_node, 'in', null),
        (_node, 42, null),
      ]);
      expect(handler.legacy, isA<_Probe>());
    });

    test('a handler that listens to a stream gets every item', () async {
      failOnLoggedWarnings('threepio.callbacks');
      final listener = _StreamListener();
      final base = RunContext.background()
          .withHandlers([LegacyCallbackHandlerAdapter(listener)]);

      final (started, input) = await callbacks.onStartWithStreamInput(
        reuseHandlers(base, _node),
        StreamReader.fromIterable([1, 2, 3]),
      );
      expect(await input.collectAll(), [1, 2, 3]);
      expect(listener.inputs, [1, 2, 3]);

      final (source, writer) = pipe<String>(capacity: 4);
      final (_, output) = await callbacks.onEndWithStreamOutput(started, source);
      writer
        ..send('a')
        ..send('b');
      await writer.close();
      expect(await output.collectAll(), ['a', 'b']);
      await output.close();
      await listener.outputDone.future;
      expect(listener.outputs, ['a', 'b']);
    });

    test('a stream nobody listens to is closed when the hook returns',
        () async {
      failOnLoggedWarnings('threepio.callbacks');
      // The default stream hooks of the older API pass the stream on as the
      // payload of the plain hook and never read it.
      final seen = <Object?>[];
      final base = RunContext.background()
          .withHandlers([LegacyCallbackHandlerAdapter(_Probe(seen))]);
      final (source, writer) = pipe<int>();

      final (_, output) = await callbacks.onEndWithStreamOutput(
        reuseHandlers(base, _node),
        source,
      );
      expect(seen.single, isA<(RunInfo, Object?, Object?)>());
      expect((seen.single! as (RunInfo, Object?, Object?)).$2, isA<Stream<dynamic>>());

      expect(writer.send(1), isFalse);
      await output.close();
      expect(writer.send(2), isTrue, reason: 'the unread copy was closed too');
    });

    test('a legacy handler that throws does not fail the run', () async {
      final logs = captureLogs('threepio.callbacks');
      final base = RunContext.background()
          .withHandlers([LegacyCallbackHandlerAdapter(_Exploding())]);

      final ctx = await callbacks.onStart(reuseHandlers(base, _node), 'in');
      expect(LegacyCallbackHandlerAdapter.legacyContextOf(ctx), isNull);
      expect(logs.single.level, Level.WARNING);
      expect(logs.single.message, contains('LegacyCallbackHandlerAdapter'));
    });

    test('the shipped legacy handlers work under the new chain', () async {
      failOnLoggedWarnings('threepio.callbacks');
      final metrics = MetricsHandler();
      final tracing = TracingHandler();
      final base = RunContext.background().withHandlers([
        const LegacyCallbackHandlerAdapter(LoggingHandler(verbose: true)),
        LegacyCallbackHandlerAdapter(metrics),
        LegacyCallbackHandlerAdapter(tracing),
      ]);

      final ctx = await callbacks.onStart(reuseHandlers(base, _node), 'in');
      await callbacks.onEnd(ctx, 'out');

      expect(metrics.metrics.single.componentName, 'llm_node');
      expect(metrics.metrics.single.isSuccess, isTrue);
      expect(tracing.events, hasLength(2));
    });
  });

  group('the older API after its deprecation', () {
    test('a CallbackManager still threads the map through its handlers',
        () async {
      final job = _JobStatusHandler();
      final logging = _LoggingHandler();
      final manager = CallbackManager([job, logging]);

      var context = <String, dynamic>{};
      context = await manager.triggerStart(context, _graph, const CallbackInput('in'));
      context =
          await manager.triggerEnd(context, _graph, const CallbackOutput('out'));
      context = await manager.triggerError(
        context,
        _node,
        StateError('late'),
        StackTrace.current,
      );

      expect(job.status, ['running: in', 'completed: out', 'failed: Bad state: late']);
      expect(logging.lines.first, contains('node=ActionGraph'));
      expect(context['failed_node'], 'llm_node');
    });

    test('a handler that throws is logged, not printed, and skipped', () async {
      final logs = captureLogs('threepio.callbacks');
      final job = _JobStatusHandler();
      final manager = CallbackManager([_Exploding(), job]);

      final context =
          await manager.triggerStart({}, _graph, const CallbackInput('in'));

      expect(job.status, ['running: in']);
      expect(context['started'], 1);
      expect(logs.single.level, Level.WARNING);
      expect(logs.single.message, 'Callback handler _Exploding failed in onStart');
      expect(logs.single.error, isStateError);
    });

    test('the global handlers of the two APIs are separate lists', () async {
      final legacy = _JobStatusHandler();
      CallbackManager.addGlobalHandler(legacy);
      addTearDown(CallbackManager.clearGlobalHandlers);

      expect(GlobalCallbacks.handlers, isEmpty);
      expect(CallbackManager().handlers, [legacy]);
      expect(
        initCallbacks(RunContext.background(), _node).hasCallbacks,
        isFalse,
      );
    });

    test('LoggingHandler writes to package:logging', () async {
      final logs = captureLogs('threepio.callbacks.logging');
      const handler = LoggingHandler(prefix: '[T]');

      await handler.onStart({}, _node, const CallbackInput('in'));
      await handler.onEnd({}, _node, const CallbackOutput('out'));

      expect(logs.map((r) => r.message), ['[T] START: llm_node', '[T] END: llm_node']);
      expect(logs.map((r) => r.level).toSet(), {Level.INFO});
    });

    test('MetricsHandler and TracingHandler summaries go to package:logging',
        () async {
      final metricLogs = captureLogs('threepio.callbacks.metrics');
      final traceLogs = captureLogs('threepio.callbacks.tracing');
      final metrics = MetricsHandler();
      final tracing = TracingHandler();

      var context = await metrics.onStart({}, _node, const CallbackInput('in'));
      await metrics.onEnd(context, _node, const CallbackOutput('out'));
      context = await tracing.onStart({}, _node, const CallbackInput('in'));
      await tracing.onEnd(context, _node, const CallbackOutput('out'));
      metrics.printSummary();
      tracing.printTrace();

      expect(metricLogs.first.message, '=== Execution Metrics Summary ===');
      expect(metricLogs.map((r) => r.message), contains('Total executions: 1'));
      expect(traceLogs.first.message, '=== Execution Trace ===');
    });
  });
}

class _Probe extends BaseCallbackHandler {
  _Probe(this.seen);

  final List<Object?> seen;

  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    seen.add((info, input.data as Object?, input.metadata as Object?));
    return context;
  }

  @override
  Future<Map<String, dynamic>> onEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    seen.add((info, output.data as Object?, output.metadata as Object?));
    return context;
  }
}

/// Listens through `asBroadcastStream`, and only after its hook returned.
class _BroadcastListener extends BaseCallbackHandler {
  final List<dynamic> items = [];
  final Completer<void> done = Completer<void>();

  @override
  Future<Map<String, dynamic>> onEndWithStreamOutput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> output,
  ) async {
    final broadcast = output.asBroadcastStream();
    scheduleMicrotask(
      () => broadcast.listen(items.add, onDone: done.complete),
    );
    return context;
  }
}

class _Exploding extends BaseCallbackHandler {
  @override
  Future<Map<String, dynamic>> onStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async =>
      throw StateError('handler bug');
}
