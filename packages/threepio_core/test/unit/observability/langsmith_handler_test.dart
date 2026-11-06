// Port of eino-ext `callbacks/langsmith/langsmith_test.go`:
// TestNewLangsmithHandler, TestOnStart, TestOnEnd, TestOnError,
// TestOnStartWithStreamInput, TestOnEndWithStreamOutput. Go builds a
// `mockLangsmith` but never gives it to the handler (its handler sends to
// `http://test`); here the mock is a recording `LangSmithApi` that the handler
// is given, and the tests check what it received.
//
// Plus tests of the port: the POST and PATCH requests of a tree of runs
// through `MockClient` (ids, trace id, parent run id, dotted order, times,
// headers), run names and types, the model settings in the metadata,
// streamed input and output, errors, trace options, the order of the
// requests, flush and shutdown with fake time, HTTP failures that are logged
// and not thrown, and the handler registered in `GlobalCallbacks` or given
// to a run with `withHandlers`, driving a fake component through the
// functions of `component_callbacks.dart`. Expected bodies are derived from
// `langsmith.go` and the struct tags of `client.go`.
import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_client.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_flow_trace.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_handler.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_trace.dart';
import 'package:threepio_core/threepio_core.dart'
    show
        CancelToken,
        CancelledException,
        Message,
        ModelCallbackConfig,
        ModelCallbackInput,
        ModelCallbackOutput,
        StreamClosedException,
        StreamReader,
        TokenUsage,
        pipe;

import '../../support/log_capture.dart';

const _logger = 'threepio.observability.langsmith';
final _t0 = DateTime.utc(2025, 10, 10, 12, 34, 56, 123, 456);

/// The dotted-order time of [_t0] plus [seconds], with its microseconds
/// (Go writes `000000` there; see `langSmithDottedTime`).
String _stamp(int seconds) {
  final t = _t0.add(Duration(seconds: seconds));
  String two(int n) => '$n'.padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}T${two(t.hour)}'
      '${two(t.minute)}${two(t.second)}123456';
}

/// The JSON time of [_t0] plus [seconds].
String _time(int seconds) {
  final t = _t0.add(Duration(seconds: seconds));
  String two(int n) => '$n'.padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:'
      '${two(t.minute)}:${two(t.second)}.123456Z';
}

/// Runs [body] with a clock that starts at [_t0] and moves one second every
/// time it is read.
Future<T> _ticking<T>(Future<T> Function() body) {
  var now = _t0;
  return withClock(
    Clock(() {
      final current = now;
      now = now.add(const Duration(seconds: 1));
      return current;
    }),
    body,
  );
}

/// Run ids `run-1`, `run-2`, ...
String Function(RunContext) _ids([String prefix = 'run']) {
  var next = 0;
  return (_) => '$prefix-${++next}';
}

/// Go's `mockLangsmith`, recording what it is given. With [hold], every
/// request waits until [release] lets it go.
final class _Recorder implements LangSmithApi {
  final List<String> events = [];
  final Map<String, LangSmithRun> runs = {};
  final List<(String, LangSmithRunPatch)> patches = [];
  final List<RunContext> contexts = [];
  final List<Completer<void>> _held = [];
  bool hold = false;
  Exception? createError;

  LangSmithRun run(String id) => runs[id]!;

  Future<void> _wait() {
    final gate = Completer<void>();
    _held.add(gate);
    return gate.future;
  }

  LangSmithRunPatch patch(String id) =>
      patches.singleWhere((entry) => entry.$1 == id).$2;

  /// Lets the held requests go, oldest first.
  Future<void> release() async {
    hold = false;
    while (_held.isNotEmpty) {
      _held.removeAt(0).complete();
      await pumpEventQueue();
    }
  }

  @override
  Future<void> createRun(RunContext ctx, LangSmithRun run) async {
    events.add('POST ${run.id}');
    runs[run.id] = run;
    contexts.add(ctx);
    if (hold) await _wait();
    final error = createError;
    if (error != null) throw error;
  }

  @override
  Future<void> updateRun(
    RunContext ctx,
    String runId,
    LangSmithRunPatch patch,
  ) async {
    events.add('PATCH $runId');
    patches.add((runId, patch));
    contexts.add(ctx);
    if (hold) await _wait();
  }
}

final class _MockError implements Exception {
  const _MockError(this.message);
  final String message;

  @override
  String toString() => message;
}

final class _TrackingClient extends http.BaseClient {
  _TrackingClient(this._inner);
  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => closed = true;
}

/// A component that fires its own callbacks, as the doc of `onStart` shows.
final class _FakeTool {
  Future<String> call(RunContext callerCtx, String input) async {
    var ctx = ensureRunInfo(callerCtx, 'Fake', ComponentType.tool);
    ctx = await onStart(ctx, input);
    try {
      if (input == 'fail') throw StateError('tool failed');
      final output = input.toUpperCase();
      await onEnd(ctx, output);
      return output;
    } catch (error, stackTrace) {
      await onError(ctx, error, stackTrace);
      rethrow;
    }
  }
}

RunInfo _info(ComponentType type, {String name = '', String impl = ''}) =>
    RunInfo(name: name, type: impl, componentType: type);

const _model = RunInfo(
  name: '',
  type: 'OpenAI',
  componentType: ComponentType.chatModel,
);

/// Starts a component the way a graph or the component itself does.
Future<RunContext> _start(RunContext ctx, RunInfo info, Object? input) =>
    onStart(reuseHandlers(ctx, info), input);

({LangSmithHandler handler, _Recorder recorder}) _setup({
  String Function(RunContext)? runIdGen,
  int maxQueueSize = 2048,
}) {
  final recorder = _Recorder();
  final handler = LangSmithHandler(
    LangSmithConfig(
      apiKey: 'test-key',
      apiUrl: 'http://test',
      runIdGen: runIdGen ?? _ids(),
      maxQueueSize: maxQueueSize,
    ),
    client: recorder,
  );
  return (handler: handler, recorder: recorder);
}

Map<String, Object?> _body(http.Request request) =>
    jsonDecode(request.body) as Map<String, Object?>;

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('TestNewLangsmithHandler', () {
    test('creates a handler', () {
      final handler = LangSmithHandler(
        const LangSmithConfig(apiKey: 'test-key', apiUrl: 'http://test'),
      );
      expect(handler, isA<ComponentCallbackHandler>());
      expect(handler.config.apiUrl, 'http://test');
      expect(handler.config.timeout, const Duration(seconds: 10));
      expect(handler.failedRequests, 0);
      expect(handler.droppedRequests, 0);
    });

    test('a queue size that is not positive is refused', () {
      expect(
        () => LangSmithHandler(
          const LangSmithConfig(apiKey: 'test-key', maxQueueSize: 0),
        ),
        throwsArgumentError,
      );
    });
  });

  group('TestOnStart', () {
    test('creates the run of the component', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      // Go's `RunInfo{Component: "test"}`; an all-empty run info is the
      // Dart counterpart of Go's nil one, so the type is set.
      final info = _info(ComponentType.custom, impl: 'test');

      final newCtx = await _ticking(
        () async => handler.onStart(RunContext.background(), info, 'hello'),
      );
      expect(newCtx, isA<RunContext>());
      await handler.flush();

      expect(recorder.events, ['POST run-1']);
      final run = recorder.run('run-1');
      expect(run.inputs, {'input': '"hello"'});
      expect(run.name, 'testUnknown');
      expect(run.runType, LangSmithRunType.chain);
      expect(run.traceId, 'run-1');
      expect(run.parentRunId, isNull);
      expect(run.dottedOrder, '${_stamp(0)}Zrun-1');
      expect(run.startTime, _t0);
      expect(run.extra, {'metadata': <String, Object?>{}});

      final state = LangSmithTrace.stateOf(newCtx)!;
      expect(state.traceId, 'run-1');
      expect(state.parentRunId, 'run-1');
      expect(state.parentDottedOrder, '${_stamp(0)}Zrun-1');
      expect(state.metadata, {'metadata': <String, Object?>{}});
    });
  });

  group('TestOnEnd', () {
    test('updates the run of the state', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final ctx = LangSmithTrace.withState(
        RunContext.background(),
        const LangSmithState(parentRunId: 'run-123'),
      );

      final newCtx = await _ticking(
        () async => handler.onEnd(ctx, _info(ComponentType.lambda), 'world'),
      );
      expect(newCtx, same(ctx));
      await handler.flush();

      expect(recorder.events, ['PATCH run-123']);
      expect(recorder.patch('run-123').toJson(), {
        'end_time': _time(0),
        'outputs': {'output': '"world"'},
      });
    });
  });

  group('TestOnError', () {
    test('updates the run of the state with the error', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final ctx = LangSmithTrace.withState(
        RunContext.background(),
        const LangSmithState(parentRunId: 'run-123'),
      );

      final newCtx = await _ticking(
        () async => handler.onError(
          ctx,
          _info(ComponentType.lambda),
          const _MockError('mock error'),
          StackTrace.current,
        ),
      );
      expect(newCtx, same(ctx));
      await handler.flush();

      expect(recorder.events, ['PATCH run-123']);
      expect(recorder.patch('run-123').toJson(), {
        'end_time': _time(0),
        'error': 'mock error',
      });
    });
  });

  group('TestOnStartWithStreamInput', () {
    test('an empty stream creates a run without messages', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final (reader, writer) = pipe<Object?>(capacity: 1);
      await writer.close();

      final newCtx = await _ticking(
        () => handler.onStartWithStreamInput(
          RunContext.background(),
          _info(ComponentType.lambda, impl: 'test'),
          reader,
        ),
      );
      expect(LangSmithTrace.stateOf(newCtx)!.parentRunId, 'run-1');
      await handler.flush();

      expect(recorder.events, ['POST run-1']);
      final run = recorder.run('run-1');
      expect(run.inputs, {'stream_inputs': <Message>[]});
      expect(run.extra, {'metadata': <String, Object?>{}});
      expect(run.dottedOrder, '${_stamp(0)}Zrun-1');
    });
  });

  group('TestOnEndWithStreamOutput', () {
    test('an empty stream ends the run with an empty message', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final ctx = LangSmithTrace.withState(
        RunContext.background(),
        const LangSmithState(parentRunId: 'run-123'),
      );
      final (reader, writer) = pipe<Object?>(capacity: 1);
      await writer.close();

      final newCtx = await _ticking(() async {
        final next = await handler.onEndWithStreamOutput(
          ctx,
          _info(ComponentType.lambda),
          reader,
        );
        await handler.flush();
        return next;
      });
      expect(newCtx, same(ctx));

      expect(recorder.events, ['PATCH run-123']);
      expect(recorder.patch('run-123').toJson(), {
        'end_time': _time(0),
        'outputs': {
          'stream_outputs': {'role': '', 'content': ''},
        },
        'extra': {'metadata': <String, Object?>{}},
      });
    });
  });

  group('run tree', () {
    test('nested components are one trace of POST and PATCH requests',
        () async {
      failOnLoggedWarnings(_logger);
      final requests = <http.Request>[];
      final handler = LangSmithHandler(
        LangSmithConfig(
          apiKey: 'test-key',
          apiUrl: 'http://test',
          runIdGen: _ids(),
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response('{}', 200);
          }),
        ),
      );
      final base = LangSmithTrace.set(
        RunContext.background().withHandlers([handler]),
        sessionName: 'proj',
        tags: ['t1'],
      );

      await _ticking(() async {
        final graph = await _start(
          base,
          _info(ComponentType.graph, name: 'agent-graph', impl: 'Graph'),
          'question',
        );
        final model = await _start(
          graph,
          _model,
          ModelCallbackInput(
            messages: [Message.user('hi')],
            config: const ModelCallbackConfig(model: 'gpt-4o', maxTokens: 64),
          ),
        );
        await onEnd(
          model,
          ModelCallbackOutput(message: Message.assistant('hello')),
        );
        final tool = await _start(
          graph,
          _info(ComponentType.tool, name: 'search', impl: 'Fake'),
          '{"q":1}',
        );
        await onEnd(tool, 'result');
        await onEnd(graph, 'done');
      });
      await handler.flush();

      expect([for (final r in requests) '${r.method} ${r.url}'], [
        'POST http://test/runs',
        'POST http://test/runs',
        'PATCH http://test/runs/run-2',
        'POST http://test/runs',
        'PATCH http://test/runs/run-3',
        'PATCH http://test/runs/run-1',
      ]);
      for (final request in requests) {
        expect(request.headers['x-api-key'], 'test-key');
        expect(request.headers['content-type'], startsWith('application/json'));
      }

      expect(_body(requests[0]), {
        'id': 'run-1',
        'name': 'agent-graph',
        'run_type': 'chain',
        'start_time': _time(0),
        'inputs': {'input': '"question"'},
        'trace_id': 'run-1',
        'extra': {'metadata': <String, Object?>{}},
        'session_name': 'proj',
        'dotted_order': '${_stamp(0)}Zrun-1',
        'tags': ['t1'],
      });

      final model = _body(requests[1]);
      expect(model, {
        'id': 'run-2',
        'name': 'OpenAIChatModel',
        'run_type': 'llm',
        'start_time': _time(1),
        'inputs': {'input': isA<String>()},
        'parent_run_id': 'run-1',
        'trace_id': 'run-1',
        'extra': {
          'metadata': {
            'ls_model_name': 'gpt-4o',
            'ls_max_tokens': 64,
            'model_conf': {
              'Model': 'gpt-4o',
              'MaxTokens': 64,
              'Temperature': 0,
              'TopP': 0,
              'Stop': null,
            },
          },
        },
        'session_name': 'proj',
        'dotted_order': '${_stamp(0)}Zrun-1.${_stamp(1)}Zrun-2',
        'tags': ['t1'],
      });
      expect(jsonDecode((model['inputs']! as Map)['input']! as String), {
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
        'config': {'model': 'gpt-4o', 'maxTokens': 64},
      });

      final modelEnd = _body(requests[2]);
      expect(modelEnd.keys, ['end_time', 'outputs']);
      expect(modelEnd['end_time'], _time(2));
      expect(jsonDecode((modelEnd['outputs']! as Map)['output']! as String), {
        'message': {'role': 'assistant', 'content': 'hello'},
      });

      final tool = _body(requests[3]);
      expect(tool['run_type'], 'tool');
      expect(tool['name'], 'search');
      expect(tool['parent_run_id'], 'run-1');
      expect(tool['trace_id'], 'run-1');
      expect(tool['dotted_order'], '${_stamp(0)}Zrun-1.${_stamp(3)}Zrun-3');
      expect(tool['inputs'], {'input': r'"{\"q\":1}"'});

      expect(_body(requests[4]), {
        'end_time': _time(4),
        'outputs': {'output': '"result"'},
      });
      expect(_body(requests[5]), {
        'end_time': _time(5),
        'outputs': {'output': '"done"'},
      });
      await handler.shutdown();
    });

    test('run names and types per kind of component', () async {
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final cases = <(RunInfo, String, LangSmithRunType)>[
        (_model, 'OpenAIChatModel', LangSmithRunType.llm),
        (
          _info(ComponentType.tool, impl: 'Weather'),
          'WeatherTool',
          LangSmithRunType.tool,
        ),
        (
          _info(ComponentType.retriever, name: 'docs', impl: 'Qdrant'),
          'docs',
          LangSmithRunType.chain,
        ),
        (
          _info(ComponentType.embedder, impl: 'OpenAI'),
          'OpenAIEmbedding',
          LangSmithRunType.chain,
        ),
        (_info(ComponentType.lambda), 'Lambda', LangSmithRunType.chain),
        (
          _info(ComponentType.toolsNode, name: 'tools'),
          'tools',
          LangSmithRunType.chain,
        ),
      ];
      for (final (info, _, _) in cases) {
        await onEnd(await _start(base, info, 'x'), 'y');
      }
      await handler.flush();
      expect(
        [
          for (final id in ['run-1', 'run-2', 'run-3', 'run-4', 'run-5', 'run-6'])
            (recorder.run(id).name, recorder.run(id).runType),
        ],
        [for (final (_, name, type) in cases) (name, type)],
      );
      expect(
        recorder.runs.values.map((run) => run.parentRunId),
        everyElement(isNull),
        reason: 'siblings: each one a trace of its own',
      );
    });
  });

  group('model settings', () {
    test('a chat model input adds them next to the trace metadata, in a copy',
        () async {
      final (:handler, :recorder) = _setup();
      final inner = <String, Object?>{'env': 'test'};
      final base = LangSmithTrace.set(
        RunContext.background().withHandlers([handler]),
        metadata: {'metadata': inner, 'top': 1},
      );

      final model = await _start(
        base,
        _model,
        ModelCallbackInput(
          messages: [Message.user('hi')],
          config: const ModelCallbackConfig(
            model: 'gpt-4o-mini',
            maxTokens: 100,
            temperature: 0.2,
            stop: ['\n'],
          ),
        ),
      );
      await onEnd(model, ModelCallbackOutput(message: Message.assistant('x')));
      await onEnd(await _start(base, _info(ComponentType.lambda), 'a'), 'b');
      await handler.flush();

      expect(recorder.run('run-1').extra, {
        'metadata': {
          'env': 'test',
          'ls_model_name': 'gpt-4o-mini',
          'ls_max_tokens': 100,
          'model_conf': {
            'Model': 'gpt-4o-mini',
            'MaxTokens': 100,
            'Temperature': 0.2,
            'TopP': 0,
            'Stop': ['\n'],
          },
        },
        'top': 1,
      });
      expect(inner, {'env': 'test'}, reason: "the caller's map is not changed");
      expect(
        recorder.run('run-2').extra,
        {
          'metadata': {'env': 'test'},
          'top': 1,
        },
        reason: 'the next run does not inherit the settings (Go writes them '
            'into the shared map)',
      );
    });

    test('a plain list of messages carries no settings', () async {
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      await onEnd(
        await _start(base, _info(ComponentType.lambda), [Message.user('q')]),
        'a',
      );
      await handler.flush();
      expect(recorder.run('run-1').extra, {'metadata': <String, Object?>{}});
      expect(
        jsonDecode(recorder.run('run-1').inputs!['input']! as String),
        [
          {'role': 'user', 'content': 'q'},
        ],
      );
    });
  });

  group('streams', () {
    test('a streamed chat model input is recorded once the stream has ended',
        () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final (source, writer) = pipe<ModelCallbackInput>(capacity: 4);

      final (ctx, forComponent) = await onStartWithStreamInput(
        reuseHandlers(base, _model),
        source,
      );
      // The component returns before the handler has read its copy.
      await onEnd(ctx, ModelCallbackOutput(message: Message.assistant('ok')));
      await pumpEventQueue();
      expect(recorder.events, isEmpty, reason: 'the input is still coming');

      writer
        ..send(
          ModelCallbackInput(
            messages: [Message.user('Hel')],
            config: const ModelCallbackConfig(model: 'm'),
          ),
        )
        ..send(
          ModelCallbackInput(
            messages: [Message.user('lo')],
            extra: const {'k': 'v'},
          ),
        );
      await writer.close();
      expect(await forComponent.collectAll(), hasLength(2));
      await forComponent.close();
      await handler.flush();

      expect(recorder.events, ['POST run-1', 'PATCH run-1']);
      final run = recorder.run('run-1');
      expect(run.toJson()['inputs'], {
        'stream_inputs': [
          {'role': 'user', 'content': 'Hello'},
        ],
      });
      expect(run.extra, {
        'metadata': {
          'ls_model_name': 'm',
          'ls_max_tokens': 0,
          'model_conf': {
            'Model': 'm',
            'MaxTokens': 0,
            'Temperature': 0,
            'TopP': 0,
            'Stop': null,
          },
        },
        'k': 'v',
      });
    });

    test('a streamed chat model output ends the run with the joined message '
        'and its usage', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final base = LangSmithTrace.set(
        RunContext.background().withHandlers([handler]),
        metadata: {
          'metadata': {'env': 'test'},
        },
      );
      final ctx = await _start(
        base,
        _model,
        ModelCallbackInput(
          messages: [Message.user('hi')],
          config: const ModelCallbackConfig(model: 'gpt'),
        ),
      );
      final (_, forCaller) = await onEndWithStreamOutput(
        ctx,
        StreamReader.fromIterable([
          ModelCallbackOutput(message: Message.assistant('Hel')),
          ModelCallbackOutput(
            message: Message.assistant('lo'),
            tokenUsage: const TokenUsage(
              promptTokens: 3,
              completionTokens: 2,
              totalTokens: 5,
            ),
            extra: const {'finish': 'stop'},
          ),
        ]),
      );
      await forCaller.close();
      await handler.flush();

      final json = recorder.patch('run-1').toJson();
      expect(json['outputs'], {
        'stream_outputs': {'role': 'assistant', 'content': 'Hello'},
      });
      expect(json['extra'], {
        'metadata': {
          'env': 'test',
          'ls_model_name': 'gpt',
          'ls_max_tokens': 0,
          'model_conf': {
            'Model': 'gpt',
            'MaxTokens': 0,
            'Temperature': 0,
            'TopP': 0,
            'Stop': null,
          },
          'usage_metadata': {
            'input_tokens': 3,
            'output_tokens': 2,
            'total_tokens': 5,
          },
        },
        'finish': 'stop',
      });
    });

    test('a streamed output keeps what a streamed input added to the extra '
        'values (Go drops the extra values of the input)', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final (ctx, input) = await onStartWithStreamInput(
        reuseHandlers(base, _model),
        StreamReader.fromIterable([
          ModelCallbackInput(
            messages: [Message.user('q')],
            config: const ModelCallbackConfig(model: 'm'),
            extra: const {'k': 'v'},
          ),
        ]),
      );
      await input.close();
      final (_, output) = await onEndWithStreamOutput(
        ctx,
        StreamReader.fromIterable([
          ModelCallbackOutput(
            message: Message.assistant('a'),
            extra: const {'finish': 'stop'},
          ),
        ]),
      );
      await output.close();
      await handler.flush();

      final extra = recorder.patch('run-1').extra!;
      expect(extra['k'], 'v');
      expect(extra['finish'], 'stop');
      expect((extra['metadata']! as Map)['ls_model_name'], 'm');
    });

    test('the chunks of other streams are not recorded, as in Go', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final (ctx, input) = await onStartWithStreamInput(
        reuseHandlers(base, _info(ComponentType.lambda, name: 'echo')),
        StreamReader.fromIterable(['a', 'b']),
      );
      await input.close();
      final (_, output) =
          await onEndWithStreamOutput(ctx, StreamReader.fromIterable([1, 2]));
      await output.close();
      await handler.flush();

      expect(recorder.run('run-1').inputs, {'stream_inputs': <Message>[]});
      expect(recorder.patch('run-1').outputs, {
        'stream_outputs': {'role': '', 'content': ''},
      });
    });

    test('an error inside a stream is logged and what arrived is kept',
        () async {
      final logs = captureLogs(_logger);
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final (source, writer) = pipe<ModelCallbackOutput>(capacity: 4);

      final ctx = await _start(base, _model, [Message.user('Hi')]);
      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);
      writer
        ..send(ModelCallbackOutput(message: Message.assistant('partial')))
        ..sendError(const FormatException('bad chunk'));
      await writer.close();
      await forCaller.close();
      await handler.flush();

      const expected = '[langsmith] error receiving stream output: '
          'FormatException: bad chunk';
      expect(logs.map((r) => r.message), [expected]);
      expect(recorder.patch('run-1').outputs, {
        'stream_outputs': Message.assistant('partial'),
      });
    });

    test('chunks that cannot be joined still create and end the run',
        () async {
      final logs = captureLogs(_logger);
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      final (ctx, input) = await onStartWithStreamInput(
        reuseHandlers(base, _model),
        StreamReader.fromIterable([
          ModelCallbackInput(messages: [Message.user('a')]),
          ModelCallbackInput(messages: [Message.user('b'), Message.user('c')]),
        ]),
      );
      await input.close();
      final (_, output) = await onEndWithStreamOutput(
        ctx,
        StreamReader.fromIterable([
          ModelCallbackOutput(message: Message.assistant('a')),
          ModelCallbackOutput(message: Message.user('b')),
        ]),
      );
      await output.close();
      await handler.flush();

      expect(recorder.events, ['POST run-1', 'PATCH run-1']);
      expect(recorder.run('run-1').inputs, {'stream_inputs': <Message>[]});
      expect(recorder.patch('run-1').outputs, {
        'stream_outputs': {'role': '', 'content': ''},
      });
      expect(logs.map((r) => r.message), [
        startsWith(
          'extract stream model input error: concat messages failed: '
          'unexpected array length. Got 2, expected 1, runinfo: RunInfo(',
        ),
        startsWith(
          'extract stream model output error: concat message failed: cannot '
          "concat messages with different roles: 'assistant' 'user', runinfo:",
        ),
      ]);
    });

    test('the stream copy of a component with unknown run info is closed '
        'unread', () async {
      final (:handler, :recorder) = _setup();
      final input = StreamReader<Object?>.fromIterable([1]);
      final ctx = RunContext.background();
      expect(
        await handler.onStartWithStreamInput(ctx, RunInfo.unknown, input),
        same(ctx),
      );
      await expectLater(input.recv(), throwsA(isA<StreamClosedException>()));

      final output = StreamReader<Object?>.fromIterable([1]);
      expect(
        await handler.onEndWithStreamOutput(ctx, RunInfo.unknown, output),
        same(ctx),
      );
      await expectLater(output.recv(), throwsA(isA<StreamClosedException>()));

      // A known component without a state: nothing to end.
      final orphan = StreamReader<Object?>.fromIterable([1]);
      await handler.onEndWithStreamOutput(ctx, _model, orphan);
      await expectLater(orphan.recv(), throwsA(isA<StreamClosedException>()));
      await handler.flush();
      expect(recorder.events, isEmpty);
    });
  });

  group('errors', () {
    test('a failing component ends its run with the error', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      await _ticking(() async {
        final ctx = await _start(base, _info(ComponentType.lambda), 'in');
        await onError(ctx, StateError('boom'), StackTrace.current);
      });
      await handler.flush();

      expect(recorder.events, ['POST run-1', 'PATCH run-1']);
      expect(recorder.patch('run-1').toJson(), {
        'end_time': _time(1),
        'error': 'Bad state: boom',
      });
    });

    test('a cancelled component is still reported', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final token = CancelToken();
      final base =
          RunContext.background(cancelToken: token).withHandlers([handler]);

      final ctx = await _start(base, _info(ComponentType.lambda), 'in');
      token.cancel('stop');
      await onError(ctx, const CancelledException('stop'), StackTrace.current);
      await handler.flush();

      expect(recorder.events, ['POST run-1', 'PATCH run-1']);
      expect(recorder.patch('run-1').error, 'stop');
      expect(
        recorder.contexts.map((ctx) => ctx.cancelToken.isCancelled),
        everyElement(isFalse),
        reason: "the requests are not sent with the component's context",
      );
    });
  });

  group('trace options', () {
    test('a trace id is joined by the first run; the reference example goes '
        'to every run', () async {
      final (:handler, :recorder) = _setup();
      final base = LangSmithTrace.set(
        RunContext.background().withHandlers([handler]),
        traceId: 'trace-x',
        referenceExampleId: 'example-1',
      );

      await _ticking(() async {
        final outer = await _start(base, _info(ComponentType.graph), 'a');
        await onEnd(await _start(outer, _info(ComponentType.lambda), 'b'), 'c');
        await onEnd(outer, 'd');
      });
      await handler.flush();

      final root = recorder.run('run-1');
      expect(root.traceId, 'trace-x');
      expect(root.parentRunId, isNull);
      expect(root.dottedOrder, '${_stamp(0)}Zrun-1');
      expect(root.referenceExampleId, 'example-1');
      final child = recorder.run('run-2');
      expect(child.traceId, 'trace-x');
      expect(child.parentRunId, 'run-1');
      expect(child.referenceExampleId, 'example-1');
    });

    test('options set inside a run apply to the runs started there', () async {
      final (:handler, :recorder) = _setup();
      final base = LangSmithTrace.set(
        RunContext.background().withHandlers([handler]),
        sessionName: 'outer',
        tags: ['a'],
      );

      final outer = await _start(base, _info(ComponentType.graph), 1);
      final inner = await _start(
        LangSmithTrace.set(outer, sessionName: 'inner', tags: ['b']),
        _info(ComponentType.lambda),
        2,
      );
      await onEnd(inner, 3);
      await onEnd(outer, 4);
      await handler.flush();

      expect(recorder.run('run-1').sessionName, 'outer');
      expect(recorder.run('run-1').tags, ['a']);
      expect(recorder.run('run-2').sessionName, 'inner');
      expect(recorder.run('run-2').tags, ['b']);
      expect(recorder.run('run-2').parentRunId, 'run-1');
    });
  });

  group('ordering', () {
    test('a run is updated only after LangSmith has answered its creation',
        () async {
      final (:handler, :recorder) = _setup();
      recorder.hold = true;
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _info(ComponentType.lambda), 'in');
      await onEnd(ctx, 'out');
      await pumpEventQueue();
      expect(recorder.events, ['POST run-1']);

      await recorder.release();
      await handler.flush();
      expect(recorder.events, ['POST run-1', 'PATCH run-1']);
    });

    test('a run whose input is still streaming is created before its update '
        'and before the runs beneath it', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final (source, writer) = pipe<Object?>(capacity: 2);

      final (graph, forGraph) = await onStartWithStreamInput(
        reuseHandlers(base, _info(ComponentType.graph, name: 'g')),
        source,
      );
      final child = await _start(graph, _info(ComponentType.lambda), 'x');
      await onEnd(child, 'y');
      await onEnd(graph, 'z');
      await pumpEventQueue();
      expect(recorder.events, isEmpty);

      writer.send('chunk');
      await writer.close();
      await forGraph.collectAll();
      await forGraph.close();
      await handler.flush();

      // The guarantees: the parent is created first, and every run is
      // created before it is updated. The two updates may come in either
      // order.
      expect(recorder.events.sublist(0, 2), ['POST run-1', 'POST run-2']);
      expect(
        recorder.events.sublist(2),
        unorderedEquals(['PATCH run-1', 'PATCH run-2']),
      );
      expect(recorder.run('run-2').parentRunId, 'run-1');
    });

    test('the hooks return while LangSmith has not answered', () async {
      final (:handler, :recorder) = _setup();
      recorder.hold = true;
      final ctx = RunContext.background();
      // `onStart` and `onEnd` of the handler do not even return futures.
      final started = handler.onStart(ctx, _info(ComponentType.lambda), 1);
      expect(started, isA<RunContext>());
      expect(handler.onEnd(started, _info(ComponentType.lambda), 2), same(started));
      await recorder.release();
      await handler.flush();
      expect(recorder.events, ['POST run-1', 'PATCH run-1']);
    });
  });

  group('HTTP failures', () {
    test('are logged and counted; the next request is still sent', () async {
      final logs = captureLogs(_logger);
      final requests = <String>[];
      final handler = LangSmithHandler(
        LangSmithConfig(
          apiKey: 'test-key',
          apiUrl: 'http://test',
          runIdGen: _ids(),
          httpClient: MockClient((request) async {
            requests.add('${request.method} ${request.url.path}');
            return request.method == 'POST'
                ? http.Response('boom', 500, reasonPhrase: 'Internal Server Error')
                : http.Response('{}', 200);
          }),
        ),
      );
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _info(ComponentType.lambda), 'in');
      await onEnd(ctx, 'out');
      await handler.flush();

      expect(requests, ['POST /runs', 'PATCH /runs/run-1']);
      expect(handler.failedRequests, 1);
      expect(logs.single.level, Level.WARNING);
      expect(
        logs.single.message,
        '[langsmith] failed to create run: failed to create run, status: '
        '500 Internal Server Error, body: boom',
      );
    });

    test('a transport that throws is a failed request', () async {
      final logs = captureLogs(_logger);
      final (:handler, :recorder) = _setup();
      recorder.createError = const LangSmithException('unreachable');
      final base = RunContext.background().withHandlers([handler]);

      final ctx = await _start(base, _info(ComponentType.lambda), 'in');
      await onError(ctx, StateError('x'), StackTrace.current);
      await handler.flush();

      expect(handler.failedRequests, 1);
      expect(recorder.events, ['POST run-1', 'PATCH run-1']);
      expect(
        logs.map((r) => r.message),
        ['[langsmith] failed to create run: unreachable'],
      );
    });
  });

  group('flush and shutdown', () {
    test('flush waits for the streams and the requests', () async {
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final (source, writer) = pipe<Object?>(capacity: 2);
      final ctx = await _start(base, _model, [Message.user('q')]);
      final (_, forCaller) = await onEndWithStreamOutput(ctx, source);

      var flushed = false;
      unawaited(handler.flush().then((_) => flushed = true));
      await pumpEventQueue();
      expect(flushed, isFalse);
      expect(recorder.events, ['POST run-1']);

      writer.send(Message.assistant('a'));
      await writer.close();
      await forCaller.close();
      await pumpEventQueue();
      expect(flushed, isTrue);
      expect(recorder.events, ['POST run-1', 'PATCH run-1']);
    });

    test('shutdown sends what is queued; afterwards nothing is sent', () async {
      final tracking = _TrackingClient(
        MockClient((request) async => http.Response('{}', 200)),
      );
      final requests = <String>[];
      final handler = LangSmithHandler(
        LangSmithConfig(
          apiKey: 'test-key',
          apiUrl: 'http://test',
          runIdGen: _ids(),
          httpClient: MockClient((request) async {
            requests.add(request.method);
            return tracking.send(request).then(http.Response.fromStream);
          }),
        ),
      );
      final base = RunContext.background().withHandlers([handler]);
      await onEnd(await _start(base, _info(ComponentType.lambda), 1), 2);

      final shutdown = handler.shutdown();
      expect(handler.shutdown(), same(shutdown));
      await shutdown;
      expect(requests, ['POST', 'PATCH']);

      // A component after the shutdown still gets a state of its own, so
      // that its end does not end the run around it; nothing is sent.
      final late = await _start(base, _info(ComponentType.lambda), 3);
      expect(LangSmithTrace.stateOf(late)!.parentRunId, 'run-2');
      await onEnd(late, 4);
      final (lateStream, _) = await onStartWithStreamInput(
        reuseHandlers(base, _info(ComponentType.lambda)),
        StreamReader.fromIterable([1]),
      );
      final (_, rest) = await onEndWithStreamOutput(
        lateStream,
        StreamReader.fromIterable([2]),
      );
      await rest.close();
      await handler.flush();
      expect(requests, ['POST', 'PATCH']);
      expect(handler.droppedRequests, 4);
      expect(tracking.closed, isFalse, reason: "the caller's client");
    });

    test('with timeouts a LangSmith that does not answer is given up on', () {
      fakeAsync((async) {
        final logs = captureLogs(_logger);
        final handler = LangSmithHandler(
          LangSmithConfig(
            apiKey: 'test-key',
            apiUrl: 'http://test',
            runIdGen: _ids(),
            httpClient:
                MockClient((request) => Completer<http.Response>().future),
          ),
        );
        final base = RunContext.background().withHandlers([handler]);

        RunContext? ctx;
        unawaited(
          _start(base, _info(ComponentType.lambda), 'in').then((c) => ctx = c),
        );
        async.flushMicrotasks();
        expect(ctx, isNotNull, reason: 'the hook does not wait for LangSmith');
        unawaited(onEnd(ctx!, 'out'));
        async.flushMicrotasks();

        var flushed = false;
        unawaited(
          handler
              .flush(timeout: const Duration(seconds: 2))
              .then((_) => flushed = true),
        );
        async.elapse(const Duration(milliseconds: 1999));
        expect(flushed, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(flushed, isTrue);
        expect(
          logs.single.message,
          '[langsmith] stopped waiting for LangSmith; 2 request(s) not sent yet',
        );

        var shutDown = false;
        unawaited(
          handler
              .shutdown(timeout: const Duration(seconds: 1))
              .then((_) => shutDown = true),
        );
        async.elapse(const Duration(seconds: 1));
        expect(shutDown, isTrue);
        expect(handler.droppedRequests, 1, reason: 'the update never left');
        expect(
          logs.last.message,
          '[langsmith] shut down with 1 request(s) not sent',
        );

        // The request on its way was abandoned: when it times out (after
        // the configured 10 s) it counts as dropped, not as failed.
        async.elapse(const Duration(seconds: 10));
        expect(handler.failedRequests, 0);
        expect(handler.droppedRequests, 2);
        expect(logs, hasLength(3), reason: 'no warning for it');
      });
    });

    test('with a timeout a stream that never ends is given up on', () {
      fakeAsync((async) {
        final logs = captureLogs(_logger);
        final (:handler, :recorder) = _setup();
        final base = RunContext.background().withHandlers([handler]);
        final (source, _) = pipe<Object?>(capacity: 2);
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
        expect(recorder.events, ['POST run-1']);
        expect(
          logs.single.message,
          '[langsmith] stopped waiting for 1 stream(s) that have not ended; '
          'their runs may not be recorded',
        );
      });
    });

    test('a full queue drops requests and warns once', () async {
      final logs = captureLogs(_logger);
      final (:handler, :recorder) = _setup(maxQueueSize: 1);
      recorder.hold = true;
      final base = RunContext.background().withHandlers([handler]);

      final first = await _start(base, _info(ComponentType.lambda), 1);
      await pumpEventQueue(); // the creation is on its way, the queue empty
      await onEnd(first, 2); // queued
      final second = await _start(base, _info(ComponentType.lambda), 3);
      await onEnd(second, 4);

      expect(handler.droppedRequests, 2);
      const expected = '[langsmith] the queue is full (1 requests); '
          'dropping requests until it has room';
      expect(logs.map((r) => r.message), [expected]);
      await recorder.release();
      await handler.flush();
      expect(recorder.events, ['POST run-1', 'PATCH run-1']);

      // Once the queue has drained, the next overflow is reported again.
      recorder.hold = true;
      final third = await _start(base, _info(ComponentType.lambda), 5);
      await pumpEventQueue();
      await onEnd(third, 6);
      await onEnd(await _start(base, _info(ComponentType.lambda), 7), 8);
      expect(handler.droppedRequests, 4);
      expect(logs.map((r) => r.message), [expected, expected]);
      await recorder.release();
      await handler.flush();
      expect(recorder.events.sublist(2), ['POST run-3', 'PATCH run-3']);
    });

    test('once shutdown has started, callbacks create no new run; the end of '
        'a run created before and work begun before are finished', () async {
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);
      final (source, writer) = pipe<Object?>(capacity: 2);
      final streaming = await _start(base, _model, [Message.user('q')]);
      final plain = await _start(base, _info(ComponentType.lambda), 1);
      final (_, forCaller) = await onEndWithStreamOutput(streaming, source);
      await pumpEventQueue();

      var done = false;
      unawaited(handler.shutdown().then((_) => done = true));
      // The run of `plain` was created: its end is still sent, or it would
      // stay open in LangSmith for ever.
      await onEnd(plain, 2);
      // A run that starts now is not created, and its end not sent.
      final late = await _start(base, _info(ComponentType.lambda), 3);
      await onEnd(late, 4);
      await pumpEventQueue();
      expect(done, isFalse, reason: 'the stream is still being read');

      writer.send(Message.assistant('a'));
      await writer.close();
      await forCaller.close();
      await pumpEventQueue();

      expect(done, isTrue);
      expect(recorder.events, [
        'POST run-1',
        'POST run-2',
        'PATCH run-2',
        'PATCH run-1',
      ]);
      expect(handler.droppedRequests, 2);
      expect(handler.failedRequests, 0);
    });

    test('the update of a run whose creation was dropped is dropped too',
        () async {
      final logs = captureLogs(_logger);
      final (:handler, :recorder) = _setup(maxQueueSize: 1);
      recorder.hold = true;
      final base = RunContext.background().withHandlers([handler]);

      final first = await _start(base, _info(ComponentType.lambda), 1);
      await pumpEventQueue(); // the creation is on its way, the queue empty
      await onEnd(first, 2); // queued: the queue is full
      final second = await _start(base, _info(ComponentType.lambda), 3);
      await recorder.release();
      await handler.flush();

      // The queue has room again, but LangSmith never got the run.
      await onEnd(second, 4);
      final (_, rest) = await onEndWithStreamOutput(
        second,
        StreamReader.fromIterable([4]),
      );
      await rest.close();
      await handler.flush();

      expect(recorder.events, ['POST run-1', 'PATCH run-1']);
      expect(handler.droppedRequests, 3);
      expect(handler.failedRequests, 0);
      const expected = '[langsmith] the queue is full (1 requests); dropping '
          'requests until it has room';
      expect(logs.map((r) => r.message), [expected]);
    });
  });

  group('callbacks wiring', () {
    test('a handler in GlobalCallbacks records a component run without '
        'handlers of its own', () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      GlobalCallbacks.append([handler]);

      expect(await _FakeTool().call(RunContext.background(), 'hi'), 'HI');
      await handler.flush();

      expect(recorder.events, ['POST run-1', 'PATCH run-1']);
      final run = recorder.run('run-1');
      expect(run.name, 'FakeTool');
      expect(run.runType, LangSmithRunType.tool);
      expect(run.inputs, {'input': '"hi"'});
      expect(recorder.patch('run-1').outputs, {'output': '"HI"'});
    });

    test('a handler given with withHandlers records successes and failures',
        () async {
      failOnLoggedWarnings(_logger);
      final (:handler, :recorder) = _setup();
      final ctx = RunContext.background().withHandlers([handler]);

      await _FakeTool().call(ctx, 'ok');
      await expectLater(_FakeTool().call(ctx, 'fail'), throwsStateError);
      await handler.flush();

      expect(recorder.events, [
        'POST run-1',
        'PATCH run-1',
        'POST run-2',
        'PATCH run-2',
      ]);
      expect(recorder.patch('run-1').outputs, {'output': '"OK"'});
      expect(recorder.patch('run-2').error, 'Bad state: tool failed');
    });

    test('unknown run info and ends without a state are ignored', () async {
      final (:handler, :recorder) = _setup();
      final ctx = RunContext.background();
      expect(handler.onStart(ctx, RunInfo.unknown, 'x'), same(ctx));
      expect(handler.onEnd(ctx, RunInfo.unknown, 'x'), same(ctx));
      expect(
        handler.onError(ctx, RunInfo.unknown, StateError('x'), StackTrace.current),
        same(ctx),
      );
      expect(handler.onEnd(ctx, _model, 'x'), same(ctx));
      expect(
        handler.onError(ctx, _model, StateError('x'), StackTrace.current),
        same(ctx),
      );
      await handler.flush();
      expect(recorder.events, isEmpty);
    });

    test('two handlers each end their own run', () async {
      final (handler: first, recorder: firstRecorder) =
          _setup(runIdGen: _ids('a'));
      final (handler: second, recorder: secondRecorder) =
          _setup(runIdGen: _ids('b'));
      final base = RunContext.background().withHandlers([first, second]);

      await onEnd(await _start(base, _info(ComponentType.lambda), 1), 2);
      await first.flush();
      await second.flush();

      expect(firstRecorder.events, ['POST a-1', 'PATCH a-1']);
      expect(secondRecorder.events, ['POST b-1', 'PATCH b-1']);
      // They share the trace position, as in Go: the second handler starts
      // first, and the first records its run beneath the second's.
      expect(firstRecorder.run('a-1').parentRunId, 'b-1');
      expect(secondRecorder.run('b-1').parentRunId, isNull);
    });

    test('a run id generator that fails is replaced by random ids', () async {
      final logs = captureLogs(_logger);
      final (:handler, :recorder) =
          _setup(runIdGen: (_) => throw StateError('no ids'));
      final base = RunContext.background().withHandlers([handler]);

      await onEnd(await _start(base, _info(ComponentType.lambda), 1), 2);
      await handler.flush();

      final id = recorder.runs.keys.single;
      expect(id, hasLength(36));
      expect(recorder.events, ['POST $id', 'PATCH $id']);
      expect(logs.single.message, '[langsmith] runIdGen failed; using a random id');
    });

    test('a value that is not JSON is recorded as its text', () async {
      final logs = captureLogs(_logger);
      final (:handler, :recorder) = _setup();
      final base = RunContext.background().withHandlers([handler]);

      await onEnd(
        await _start(base, _info(ComponentType.lambda), _Unencodable()),
        2,
      );
      await handler.flush();

      expect(recorder.run('run-1').inputs, {'input': '"unencodable"'});
      expect(logs.single.message, startsWith('marshal input error, runinfo: '));
    });

    test('the state of a run is what a flow trace carries on', () async {
      final (:handler, :recorder) = _setup();
      final flow = LangSmithFlowTrace(
        const LangSmithConfig(apiKey: 'test-key'),
        client: recorder,
      );
      final base = RunContext.background().withHandlers([handler]);
      final ctx = await _start(base, _info(ComponentType.lambda), 1);

      final restored = flow.stringToSpan(flow.spanToString(ctx))!;
      expect(restored.parentRunId, 'run-1');
      expect(restored.traceId, 'run-1');
      expect(restored.metadata, {'metadata': <String, Object?>{}});
      await onEnd(ctx, 2);
      await handler.shutdown();
    });
  });
}

final class _Unencodable {
  Map<String, Object?> toJson() => throw StateError('no json');

  @override
  String toString() => 'unencodable';
}
