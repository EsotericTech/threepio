// Port of eino-ext `callbacks/langsmith/flow_trace_test.go`: TestNewFlowTrace,
// TestFlowTrace_StartSpan, TestFlowTrace_FinishSpan, TestFlowTrace_SpanToString,
// TestFlowTrace_StringToSpan, TestFlowTrace_Integration, with Go's expected
// values. Go's `mockLangsmith` is a recording `LangSmithApi` here, and the
// tests also check what it was given (the run tree fields Go only builds).
// Plus tests of the port: the request of `startSpan` through `MockClient`,
// failures, cancellation, and a handler recording beneath a span.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_client.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_flow_trace.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_handler.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_trace.dart';
import 'package:threepio_core/threepio_core.dart'
    show CancelToken, CancelledException, ThreepioFormatException;

import '../../support/log_capture.dart';

final _now = DateTime.utc(2025, 10, 10, 12, 34, 56, 123, 456);
// The dotted-order time of [_now], with its microseconds (Go writes `000000`
// there; see `langSmithDottedTime`).
const _stamp = '20251010T123456123456';

/// Go's `mockLangsmith`, recording what it is given.
final class _Recorder implements LangSmithApi {
  final List<LangSmithRun> runs = [];
  final List<(String, LangSmithRunPatch)> patches = [];
  final List<String> events = [];
  Exception? createError;
  Exception? updateError;

  @override
  Future<void> createRun(RunContext ctx, LangSmithRun run) async {
    events.add('POST ${run.id}');
    runs.add(run);
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
    final error = updateError;
    if (error != null) throw error;
  }
}

LangSmithConfig _config(String runId) =>
    LangSmithConfig(apiKey: 'test-key', runIdGen: (_) => runId);

Future<T> _fixedTime<T>(Future<T> Function() body) =>
    withClock(Clock.fixed(_now), body);

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  test('TestNewFlowTrace', () async {
    final recorder = _Recorder();
    final flow = LangSmithFlowTrace(
      const LangSmithConfig(apiKey: 'test-key', apiUrl: 'http://test.com'),
      client: recorder,
    );
    expect(flow.config.apiKey, 'test-key');

    // Without a generator, run ids are random UUIDs.
    final (_, runId) = await flow.startSpan(RunContext.background(), 'span');
    expect(
      runId,
      matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
    );
  });

  group('TestFlowTrace_StartSpan', () {
    test('basic span creation', () async {
      final recorder = _Recorder();
      final flow = LangSmithFlowTrace(_config('test-run-id'), client: recorder);

      final (newCtx, runId) = await _fixedTime(
        () => flow.startSpan(RunContext.background(), 'test-span'),
      );
      expect(runId, 'test-run-id');
      expect(LangSmithTrace.stateOf(newCtx), isNotNull);
      expect(recorder.events, ['POST test-run-id']);

      final run = recorder.runs.single;
      expect(run.name, 'test-span');
      expect(run.runType, LangSmithRunType.chain);
      expect(run.traceId, 'test-run-id', reason: 'a new trace');
      expect(run.parentRunId, isNull);
      expect(run.dottedOrder, '${_stamp}Ztest-run-id');
      expect(run.startTime, _now);
      expect(run.inputs, isNull);
      expect(run.extra, {'metadata': <String, Object?>{}});
    });

    test('with trace options', () async {
      final recorder = _Recorder();
      final flow = LangSmithFlowTrace(_config('test-run-id'), client: recorder);
      final ctx = LangSmithTrace.set(
        RunContext.background(),
        sessionName: 'test-project',
        referenceExampleId: 'example-123',
        tags: ['tag1', 'tag2'],
      );
      const state = LangSmithState(
        traceId: 'parent-trace-id',
        parentRunId: 'parent-run-id',
        parentDottedOrder: 'parent.dotted.order',
      );

      final (newCtx, runId) = await _fixedTime(
        () => flow.startSpan(ctx, 'span-with-options', state: state),
      );
      expect(runId, 'test-run-id');
      expect(recorder.events, ['POST test-run-id']);

      final run = recorder.runs.single;
      expect(run.traceId, 'parent-trace-id');
      expect(run.parentRunId, 'parent-run-id');
      expect(run.dottedOrder, 'parent.dotted.order.${_stamp}Ztest-run-id');
      expect(run.sessionName, 'test-project');
      expect(run.referenceExampleId, 'example-123');
      expect(run.tags, ['tag1', 'tag2']);

      final next = LangSmithTrace.stateOf(newCtx)!;
      expect(next.traceId, 'parent-trace-id');
      expect(next.parentRunId, 'test-run-id');
      expect(next.parentDottedOrder, 'parent.dotted.order.${_stamp}Ztest-run-id');
      expect(next.metadata, isNull, reason: 'Go keeps no metadata in it');
      expect(next.tags, isNull);
    });

    test('empty state', () async {
      final recorder = _Recorder();
      final flow = LangSmithFlowTrace(_config('test-run-id'), client: recorder);

      final (_, runId) = await flow.startSpan(
        RunContext.background(),
        'empty-state',
        state: const LangSmithState(),
      );
      expect(runId, 'test-run-id');
      expect(recorder.events, ['POST test-run-id']);
      expect(recorder.runs.single.traceId, 'test-run-id');
    });
  });

  test('TestFlowTrace_FinishSpan', () async {
    final recorder = _Recorder();
    final flow = LangSmithFlowTrace(_config('x'), client: recorder);
    final ctx = LangSmithTrace.withState(
      RunContext.background(),
      const LangSmithState(parentRunId: 'run-123'),
    );

    await _fixedTime(() => flow.finishSpan(ctx, 'run-123'));
    expect(recorder.events, ['PATCH run-123']);
    final (_, patch) = recorder.patches.single;
    expect(patch.toJson(), {'end_time': '2025-10-10T12:34:56.123456Z'});
  });

  group('TestFlowTrace_SpanToString', () {
    final flow = LangSmithFlowTrace(_config('x'), client: _Recorder());

    test('empty state', () {
      expect(flow.spanToString(RunContext.background()), isEmpty);
    });

    test('valid state', () {
      final ctx = LangSmithTrace.withState(
        RunContext.background(),
        const LangSmithState(
          traceId: 'test-trace-id',
          parentRunId: 'test-parent-id',
          parentDottedOrder: 'test.dotted.order',
          metadata: {'key': 'value'},
          tags: ['tag1', 'tag2'],
        ),
      );
      final text = flow.spanToString(ctx);
      expect(text, contains('test-trace-id'));
      expect(text, contains('test-parent-id'));
      expect(text, contains('test.dotted.order'));
      expect(
        text,
        '{"trace_id":"test-trace-id","parent_run_id":"test-parent-id",'
        '"parent_dotted_order":"test.dotted.order","metadata":{},'
        '"tags":["tag1","tag2"],"marshal_metadata":{"key":"value"}}',
      );
    });

    test('metadata that cannot be written is an error', () {
      final ctx = LangSmithTrace.withState(
        RunContext.background(),
        LangSmithState(metadata: {'bad': _Unencodable()}),
      );
      expect(
        () => flow.spanToString(ctx),
        throwsA(isA<LangSmithException>()),
      );
    });
  });

  group('TestFlowTrace_StringToSpan', () {
    final flow = LangSmithFlowTrace(_config('x'), client: _Recorder());

    test('empty string', () {
      expect(flow.stringToSpan(''), isNull);
    });

    test('valid JSON', () {
      final state = flow.stringToSpan(
        '{"trace_id":"test-trace","parent_run_id":"test-parent",'
        '"parent_dotted_order":"test.order","marshal_metadata":{"key":"value"},'
        '"tags":["tag1","tag2"]}',
      )!;
      expect(state.traceId, 'test-trace');
      expect(state.parentRunId, 'test-parent');
      expect(state.parentDottedOrder, 'test.order');
      expect(state.metadata, isNotNull);
      expect(state.metadata!['key'], 'value');
      expect(state.tags, ['tag1', 'tag2']);
    });

    test('invalid JSON', () {
      expect(
        () => flow.stringToSpan('invalid json'),
        throwsA(isA<ThreepioFormatException>()),
      );
    });

    test('JSON that is not an object', () {
      expect(
        () => flow.stringToSpan('[1]'),
        throwsA(isA<ThreepioFormatException>()),
      );
    });
  });

  test('TestFlowTrace_Integration', () async {
    final recorder = _Recorder();
    final flow =
        LangSmithFlowTrace(_config('integration-test-id'), client: recorder);
    final ctx = LangSmithTrace.set(
      RunContext.background(),
      sessionName: 'integration-project',
      tags: ['integration'],
    );

    final (newCtx, runId) = await flow.startSpan(ctx, 'integration-span');
    expect(runId, 'integration-test-id');

    final state = LangSmithTrace.stateOf(newCtx)!;
    expect(state.traceId, 'integration-test-id');

    final text = flow.spanToString(newCtx);
    expect(text, isNotEmpty);

    final restored = flow.stringToSpan(text)!;
    expect(restored.traceId, state.traceId);
    expect(restored.parentRunId, state.parentRunId);
    expect(restored.parentDottedOrder, state.parentDottedOrder);

    await flow.finishSpan(newCtx, runId);
    expect(recorder.events, ['POST integration-test-id', 'PATCH integration-test-id']);
    expect(recorder.runs.single.sessionName, 'integration-project');
    expect(recorder.runs.single.tags, ['integration']);
  });

  group('port', () {
    test('startSpan posts the run; inputs is null as in Go', () async {
      final requests = <http.Request>[];
      final flow = LangSmithFlowTrace(
        LangSmithConfig(
          apiKey: 'test-key',
          apiUrl: 'http://test',
          runIdGen: (_) => 'span-1',
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response('{}', 200);
          }),
        ),
      );

      final (ctx, id) = await _fixedTime(
        () => flow.startSpan(
          LangSmithTrace.set(
            RunContext.background(),
            metadata: {
              'metadata': {'cid': 'c1'},
            },
          ),
          'flow',
        ),
      );
      await _fixedTime(() => flow.finishSpan(ctx, id));
      flow.close();

      expect([for (final r in requests) '${r.method} ${r.url}'], [
        'POST http://test/runs',
        'PATCH http://test/runs/span-1',
      ]);
      expect(requests.first.headers['x-api-key'], 'test-key');
      expect(jsonDecode(requests.first.body), {
        'id': 'span-1',
        'name': 'flow',
        'run_type': 'chain',
        'start_time': '2025-10-10T12:34:56.123456Z',
        'inputs': null,
        'trace_id': 'span-1',
        'extra': {
          'metadata': {'cid': 'c1'},
        },
        'dotted_order': '${_stamp}Zspan-1',
      });
      expect(jsonDecode(requests.last.body), {
        'end_time': '2025-10-10T12:34:56.123456Z',
      });
    });

    test('a span that LangSmith does not create is an error', () async {
      final recorder = _Recorder()
        ..createError = const LangSmithException('failed to create run');
      final flow = LangSmithFlowTrace(_config('s'), client: recorder);
      await expectLater(
        flow.startSpan(RunContext.background(), 'span'),
        throwsA(isA<LangSmithException>()),
      );
    });

    test('a failure to finish a span is logged, not thrown', () async {
      final logs = captureLogs('threepio.observability.langsmith');
      final recorder = _Recorder()
        ..updateError = const LangSmithException('failed to update run');
      final flow = LangSmithFlowTrace(_config('s'), client: recorder);

      await flow.finishSpan(RunContext.background(), 'run-1');
      const expected = '[langsmith] failed to FinishSpan: failed to update run';
      expect(logs.map((r) => r.message), [expected]);
    });

    test('a cancelled context cancels both calls', () async {
      final flow = LangSmithFlowTrace(
        LangSmithConfig(
          apiKey: 'test-key',
          apiUrl: 'http://test',
          httpClient: MockClient((request) async => http.Response('{}', 200)),
        ),
      );
      final ctx = RunContext.background(cancelToken: CancelToken()..cancel());
      await expectLater(
        flow.startSpan(ctx, 'span'),
        throwsA(isA<CancelledException>()),
      );
      await expectLater(
        flow.finishSpan(ctx, 'run-1'),
        throwsA(isA<CancelledException>()),
      );
    });

    test('without a state a span starts its own trace, as in Go', () async {
      final recorder = _Recorder();
      final flow = LangSmithFlowTrace(_config('child'), client: recorder);
      final inTrace = LangSmithTrace.withState(
        LangSmithTrace.set(RunContext.background(), traceId: 'ignored'),
        const LangSmithState(traceId: 'outer', parentRunId: 'outer-run'),
      );

      await flow.startSpan(inTrace, 'span');
      final run = recorder.runs.single;
      expect(run.traceId, 'child');
      expect(run.parentRunId, isNull);

      await flow.startSpan(
        inTrace,
        'nested',
        state: LangSmithTrace.stateOf(inTrace),
      );
      expect(recorder.runs.last.traceId, 'outer');
      expect(recorder.runs.last.parentRunId, 'outer-run');
    });

    test('a handler records the components beneath the span', () async {
      final recorder = _Recorder();
      var next = 0;
      final config = LangSmithConfig(
        apiKey: 'test-key',
        runIdGen: (_) => 'run-${++next}',
      );
      final flow = LangSmithFlowTrace(config, client: recorder);
      final handler = LangSmithHandler(config, client: recorder);

      await _fixedTime(() async {
        final (spanCtx, spanId) = await flow.startSpan(
          RunContext.background().withHandlers([handler]),
          'conversation',
        );
        final ctx = await onStart(
          reuseHandlers(
            spanCtx,
            const RunInfo(
              name: 'step',
              type: 'Lambda',
              componentType: ComponentType.lambda,
            ),
          ),
          'input',
        );
        await onEnd(ctx, 'output');
        await handler.flush();
        await flow.finishSpan(spanCtx, spanId);
      });

      expect(recorder.events, [
        'POST run-1',
        'POST run-2',
        'PATCH run-2',
        'PATCH run-1',
      ]);
      final step = recorder.runs.last;
      expect(step.name, 'step');
      expect(step.parentRunId, 'run-1');
      expect(step.traceId, 'run-1');
      expect(step.dottedOrder, '${_stamp}Zrun-1.${_stamp}Zrun-2');

      // The text of the span, read in another process, continues the trace.
      final carried = flow.spanToString(
        LangSmithTrace.withState(
          RunContext.background(),
          LangSmithState(
            traceId: step.traceId,
            parentRunId: step.id,
            parentDottedOrder: step.dottedOrder,
          ),
        ),
      );
      final state = flow.stringToSpan(carried);
      final (_, remoteId) = await _fixedTime(
        () => flow.startSpan(RunContext.background(), 'remote', state: state),
      );
      expect(remoteId, 'run-3');
      expect(recorder.runs.last.parentRunId, 'run-2');
      expect(
        recorder.runs.last.dottedOrder,
        '${_stamp}Zrun-1.${_stamp}Zrun-2.${_stamp}Zrun-3',
      );
      await handler.shutdown();
    });
  });
}

final class _Unencodable {
  Map<String, Object?> toJson() => throw StateError('no json');
}
