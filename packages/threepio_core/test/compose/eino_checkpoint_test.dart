// Port of eino `compose/checkpoint_test.go`, lines 1-1416: from the top of the
// file to `TestPreHandlerInterrupt`. The tests from `TestCancelInterrupt` on
// are ported in another file. `TestRunnableInvokeAcceptsNilForPointerInput`
// is ported with the lambda tests.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/src/compose/checkpoint.dart'
    show CheckPointer, GraphCheckpoint;

/// Go `testStruct`.
final class _TestStruct {
  _TestStruct(this.a);

  factory _TestStruct.fromJson(Map<String, Object?> json) =>
      _TestStruct(json['a']! as String);

  String a;

  Map<String, Object?> toJson() => {'a': a};

  @override
  bool operator ==(Object other) => other is _TestStruct && other.a == a;

  @override
  int get hashCode => a.hashCode;

  @override
  String toString() => '_TestStruct($a)';
}

/// Go `state` of `TestPreHandlerInterrupt`: a struct without fields.
final class _EmptyState {
  const _EmptyState();

  @override
  bool operator ==(Object other) => other is _EmptyState;

  @override
  int get hashCode => 0;
}

/// Go `myInterface`.
abstract interface class _MyInterface {
  void a();
}

/// Go `testGraphCallback`: counts the callbacks of graphs.
final class _GraphCallback extends ComponentCallbackHandler {
  int onStartTimes = 0;
  int onEndTimes = 0;
  int onStreamStartTimes = 0;
  int onStreamEndTimes = 0;
  int onErrorTimes = 0;

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    if (info.componentType == ComponentType.graph) onStartTimes++;
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    if (info.componentType == ComponentType.graph) onEndTimes++;
    return ctx;
  }

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    if (info.componentType == ComponentType.graph) onErrorTimes++;
    return ctx;
  }

  @override
  Future<RunContext> onStartWithStreamInput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> input,
  ) async {
    await input.close();
    if (info.componentType == ComponentType.graph) onStreamStartTimes++;
    return ctx;
  }

  @override
  Future<RunContext> onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) async {
    await output.close();
    if (info.componentType == ComponentType.graph) onStreamEndTimes++;
    return ctx;
  }
}

/// Go `failStore`: a store no run may touch.
final class _FailStore implements CheckpointStore {
  final List<String> calls = [];

  @override
  Future<Uint8List?> get(String key) async {
    calls.add('get $key');
    throw StateError('cannot call store');
  }

  @override
  Future<void> set(String key, Uint8List value) async {
    calls.add('set $key');
    throw StateError('cannot call store');
  }
}

/// Stands in for Go's `checkpointGobSerializer`: a serializer of the test's
/// own. There is no gob in Dart, so it wraps the JSON serializer (intended
/// deviation 6) and counts its calls.
final class _WrappingSerializer implements CheckpointSerializer {
  static const _json = JsonCheckpointSerializer();

  int serialized = 0;
  int deserialized = 0;

  @override
  Uint8List serialize(Object? value) {
    serialized++;
    return _json.serialize(value);
  }

  @override
  Object? deserialize(Uint8List bytes) {
    deserialized++;
    return _json.deserialize(bytes);
  }
}

/// The address `runnable:root` followed by a node segment for each of
/// [nodes].
Address _root([List<String> nodes = const []]) => Address([
      const AddressSegment(type: AddressSegmentType.runnable, id: 'root'),
      for (final node in nodes)
        AddressSegment(type: AddressSegmentType.node, id: node),
    ]);

/// Go `ExtractInterruptInfo(err)` with `ok == true` asserted: the interrupt
/// info [run] fails with.
Future<GraphInterruptInfo> _interruptOf(Future<Object?> run) async {
  Object? thrown;
  try {
    await run;
  } on Object catch (error) {
    thrown = error;
  }
  expect(thrown, isNotNull, reason: 'the run was not interrupted');
  final info = extractInterruptInfo(thrown);
  expect(info, isNotNull, reason: 'not an interrupt: $thrown');
  return info!;
}

/// Everything [info] says, as maps and lists, so that it compares the way
/// Go's `assert.Equal` compares an `*InterruptInfo`: field by field, the
/// nested infos included.
Map<String, Object?> _describe(GraphInterruptInfo info) => {
      'state': info.state,
      'beforeNodes': info.beforeNodes,
      'afterNodes': info.afterNodes,
      'rerunNodes': info.rerunNodes,
      'rerunNodesExtra': info.rerunNodesExtra,
      'subGraphs': _describeAll(info.subGraphs),
      'interruptContexts': info.interruptContexts,
    };

Map<String, Object?> _describeAll(Map<String, GraphInterruptInfo> infos) => {
      for (final MapEntry(:key, :value) in infos.entries) key: _describe(value),
    };

/// What [_describe] gives for the Go literal `&InterruptInfo{…}` with the
/// given fields: the fields Go leaves nil are empty.
Map<String, Object?> _info({
  Object? state,
  List<String> beforeNodes = const [],
  List<String> afterNodes = const [],
  Map<String, Object?> subGraphs = const {},
}) =>
    {
      'state': state,
      'beforeNodes': beforeNodes,
      'afterNodes': afterNodes,
      'rerunNodes': const <String>[],
      'rerunNodesExtra': const <String, Object?>{},
      'subGraphs': subGraphs,
      'interruptContexts': const <InterruptCtx>[],
    };

/// Go `assert.True(t, actual.EqualsWithoutID(expected))`.
void _expectPoint(InterruptCtx actual, InterruptCtx expected) {
  String chain(InterruptCtx? point) =>
      point == null ? 'nil' : '$point <- ${chain(point.parent)}';
  expect(
    actual.equalsWithoutId(expected),
    isTrue,
    reason: 'got ${chain(actual)}, expected ${chain(expected)}',
  );
}

/// Reads [reader] to its end, as the Go tests do with `Recv` until `io.EOF`,
/// and joins the chunks.
Future<String> _concat(StreamReader<String> reader) async {
  final result = StringBuffer();
  while (true) {
    try {
      result.write(await reader.recv());
    } on StreamEOFException {
      break;
    }
  }
  return result.toString();
}

LocalState _testState() =>
    LocalState.of<_TestStruct>((ctx) => _TestStruct(''));

void main() {
  setUpAll(() {
    TypeRegistry.registerName<_TestStruct>(
      'eino_checkpoint_test.testStruct',
      fromJson: _TestStruct.fromJson,
      toJson: (value) => value.toJson(),
    );
    TypeRegistry.registerName<_EmptyState>(
      'eino_checkpoint_test.TestPreHandlerInterrupt_state',
      fromJson: (json) => const _EmptyState(),
      toJson: (value) => const {},
    );
  });

  final ctx = RunContext.background();

  test('TestCheckpointGobSerializerNormalizesTypedNilInput', () async {
    // Dart has no typed nil: the port pins what is left of the Go test, that
    // an input which is null is still in the checkpoint, as null, after it
    // went through a serializer of the caller's own.
    final store = InMemoryCheckpointStore();
    final serializer = _WrappingSerializer();
    final cpr = CheckPointer(
      inputTypes: const {},
      outputTypes: const {},
      store: store,
      serializer: serializer,
    );
    final cp = GraphCheckpoint(
      channels: {},
      inputs: {'node': null},
      skipPreHandler: {},
    );

    await cpr.set('cp', cp);

    final got = await cpr.get('cp');
    expect(got, isNotNull);
    expect(got!.inputs.containsKey('node'), isTrue);
    expect(got.inputs['node'], isNull);
    expect(serializer.serialized, 1);
    expect(serializer.deserialized, 1);
  });

  group('TestSimpleCheckPoint', () {
    Future<Runnable<String, String>> compile() {
      final store = InMemoryCheckpointStore();
      final g = Graph<String, String>(localState: _testState())
        ..addLambdaNode(
          '1',
          Lambda.invokable((ctx, String input) => '${input}1'),
        )
        ..addLambdaNode(
          '2',
          Lambda.invokable((ctx, String input) => '${input}2'),
          options: NodeOptions(
            statePreHandler: StateHandler.pre<String, _TestStruct>(
              (ctx, input, state) => input + state.a,
            ),
          ),
        )
        ..addEdge(Graph.start, '1')
        ..addEdge('1', '2')
        ..addEdge('2', Graph.end);
      return g.compile(
        ctx,
        options: GraphCompileOptions(
          nodeTriggerMode: NodeTriggerMode.allPredecessor,
          checkpointStore: store,
          interruptAfterNodes: const ['1'],
          interruptBeforeNodes: const ['2'],
          graphName: 'root',
        ),
      );
    }

    void expectInterrupt(GraphInterruptInfo info) {
      expect(info.state, _TestStruct(''));
      expect(info.beforeNodes, ['2']);
      expect(info.afterNodes, ['1']);
      expect(info.rerunNodesExtra, isEmpty);
      expect(info.subGraphs, isEmpty);
      _expectPoint(
        info.interruptContexts[0],
        InterruptCtx(
          id: '',
          address: _root(),
          info: _TestStruct(''),
          isRootCause: true,
        ),
      );
    }

    test('invoke', () async {
      final r = await compile();

      final info = await _interruptOf(
        r.invoke(ctx, 'start', options: [CallOption.checkpointId('1')]),
      );
      expectInterrupt(info);

      final rCtx = ctx.resumeWithData(
        info.interruptContexts[0].id,
        _TestStruct('state'),
      );
      final result = await r.invoke(
        rCtx,
        'start',
        options: [CallOption.checkpointId('1')],
      );
      expect(result, 'start1state2');
    });

    // This half is commented out in the Go test. It is ported as a live
    // test.
    test('stream', () async {
      final r = await compile();

      final info = await _interruptOf(
        r.stream(ctx, 'start', options: [CallOption.checkpointId('2')]),
      );
      expectInterrupt(info);

      final rCtx = ctx.resumeWithData(
        info.interruptContexts[0].id,
        _TestStruct('state'),
      );
      final streamResult = await r.stream(
        rCtx,
        'start',
        options: [CallOption.checkpointId('2')],
      );
      expect(await _concat(streamResult), 'start1state2');
    });
  });

  // Go spells the name `TestCustomStructInAn2y`.
  test('TestCustomStructInAn2y (TestCustomStructInAny)', () async {
    final store = InMemoryCheckpointStore();
    final g = Graph<String, String>(localState: _testState())
      ..addLambdaNode(
        '1',
        Lambda.invokable((ctx, String input) => _TestStruct('${input}1')),
        options: const NodeOptions(outputKey: '1'),
      )
      ..addLambdaNode(
        '2',
        Lambda.invokable(
          (ctx, Map<String, Object?> input) =>
              '${(input['1']! as _TestStruct).a}2',
        ),
        options: NodeOptions(
          statePreHandler: StateHandler.pre<Map<String, Object?>, _TestStruct>(
            (ctx, input, state) {
              (input['1']! as _TestStruct).a += state.a;
              return input;
            },
          ),
        ),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge('2', Graph.end);

    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(
        checkpointStore: store,
        interruptAfterNodes: const ['1'],
        graphName: 'root',
      ),
    );

    void expectInterrupt(GraphInterruptInfo info) {
      expect(info.state, _TestStruct(''));
      expect(info.afterNodes, ['1']);
      expect(info.rerunNodesExtra, isEmpty);
      expect(info.subGraphs, isEmpty);
      _expectPoint(
        info.interruptContexts[0],
        InterruptCtx(
          id: '',
          address: _root(),
          info: _TestStruct(''),
          isRootCause: true,
        ),
      );
    }

    var info = await _interruptOf(
      r.invoke(ctx, 'start', options: [CallOption.checkpointId('1')]),
    );
    expectInterrupt(info);
    var rCtx = ctx.resumeWithData(
      info.interruptContexts[0].id,
      _TestStruct('state'),
    );
    final result = await r.invoke(
      rCtx,
      'start',
      options: [CallOption.checkpointId('1')],
    );
    expect(result, 'start1state2');

    info = await _interruptOf(
      r.stream(ctx, 'start', options: [CallOption.checkpointId('2')]),
    );
    expectInterrupt(info);

    rCtx = ctx.resumeWithData(
      info.interruptContexts[0].id,
      _TestStruct('state'),
    );
    final streamResult = await r.stream(
      rCtx,
      'start',
      options: [CallOption.checkpointId('2')],
    );
    expect(await _concat(streamResult), 'start1state2');
  });

  test('TestSubGraph', () async {
    final subG = Graph<String, String>(localState: _testState())
      ..addLambdaNode('1', Lambda.invokable((ctx, String input) => '${input}1'))
      ..addLambdaNode(
        '2',
        Lambda.invokable((ctx, String input) => '${input}2'),
        options: NodeOptions(
          statePreHandler: StateHandler.pre<String, _TestStruct>(
            (ctx, input, state) => input + state.a,
          ),
        ),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge('2', Graph.end);

    final g = Graph<String, String>()
      ..addLambdaNode('1', Lambda.invokable((ctx, String input) => '${input}1'))
      ..addGraphNode(
        '2',
        subG,
        options: const NodeOptions(
          compileOptions: GraphCompileOptions(interruptAfterNodes: ['1']),
        ),
      )
      ..addLambdaNode('3', Lambda.invokable((ctx, String input) => '${input}3'))
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge('2', '3')
      ..addEdge('3', Graph.end);

    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(
        checkpointStore: InMemoryCheckpointStore(),
        graphName: 'root',
      ),
    );

    void expectInterrupt(GraphInterruptInfo info) {
      expect(_describeAll(info.subGraphs), {
        '2': _info(state: _TestStruct(''), afterNodes: ['1']),
      });
      _expectPoint(
        info.interruptContexts[0],
        InterruptCtx(
          id: '',
          address: _root(['2']),
          info: _TestStruct(''),
          isRootCause: true,
          parent: InterruptCtx(id: '', address: _root()),
        ),
      );
    }

    var info = await _interruptOf(
      r.invoke(ctx, 'start', options: [CallOption.checkpointId('1')]),
    );
    expectInterrupt(info);

    var rCtx = ctx.resumeWithData(
      info.interruptContexts[0].id,
      _TestStruct('state'),
    );
    final result = await r.invoke(
      rCtx,
      'start',
      options: [CallOption.checkpointId('1')],
    );
    expect(result, 'start11state23');

    info = await _interruptOf(
      r.stream(ctx, 'start', options: [CallOption.checkpointId('2')]),
    );
    expectInterrupt(info);

    rCtx = ctx.resumeWithData(
      info.interruptContexts[0].id,
      _TestStruct('state'),
    );
    final streamResult = await r.stream(
      rCtx,
      'start',
      options: [CallOption.checkpointId('2')],
    );
    expect(await _concat(streamResult), 'start11state23');
  });

  group('TestNestedSubGraph', () {
    // The Go test compiles the same graph twice: in the default mode and as a
    // DAG.
    late Graph<String, String> g;

    setUpAll(() {
      final sSubG = Graph<String, String>(localState: _testState())
        ..addLambdaNode(
          '1',
          Lambda.invokable((ctx, String input) => '${input}1'),
        )
        ..addLambdaNode(
          '2',
          Lambda.invokable((ctx, String input) => '${input}2'),
          options: NodeOptions(
            statePreHandler: StateHandler.pre<String, _TestStruct>(
              (ctx, input, state) => input + state.a,
            ),
          ),
        )
        ..addEdge(Graph.start, '1')
        ..addEdge('1', '2')
        ..addEdge('2', Graph.end);

      final subG = Graph<String, String>(localState: _testState())
        ..addLambdaNode(
          '1',
          Lambda.invokable((ctx, String input) => '${input}1'),
        )
        ..addGraphNode(
          '2',
          sSubG,
          options: NodeOptions(
            compileOptions:
                const GraphCompileOptions(interruptAfterNodes: ['1']),
            statePreHandler: StateHandler.pre<String, _TestStruct>(
              (ctx, input, state) => input + state.a,
            ),
            outputKey: '2',
          ),
        )
        ..addLambdaNode(
          '3',
          Lambda.invokable((ctx, String input) => '${input}3'),
          options: const NodeOptions(outputKey: '3'),
        )
        ..addLambdaNode(
          '4',
          Lambda.invokable(
            (ctx, Map<String, Object?> input) =>
                '${input['2']! as String}4\n'
                '${input['3']! as String}4\n'
                '${input['state']! as String}4\n',
          ),
          options: NodeOptions(
            statePreHandler:
                StateHandler.pre<Map<String, Object?>, _TestStruct>(
              (ctx, input, state) {
                input['state'] = state.a;
                return input;
              },
            ),
          ),
        )
        ..addEdge(Graph.start, '1')
        ..addEdge('1', '2')
        ..addEdge('1', '3')
        ..addEdge('3', '4')
        ..addEdge('2', '4')
        ..addEdge('4', Graph.end);

      g = Graph<String, String>()
        ..addLambdaNode(
          '1',
          Lambda.invokable((ctx, String input) => '${input}1'),
        )
        ..addGraphNode(
          '2',
          subG,
          options: const NodeOptions(
            compileOptions: GraphCompileOptions(
              interruptAfterNodes: ['1', '3'],
              interruptBeforeNodes: ['4'],
            ),
          ),
        )
        ..addLambdaNode(
          '3',
          Lambda.invokable((ctx, String input) => '${input}3'),
        )
        ..addEdge(Graph.start, '1')
        ..addEdge('1', '2')
        ..addEdge('2', '3')
        ..addEdge('3', Graph.end);
    });

    /// One pass of the Go test over [r]: three interrupts, each resumed with
    /// a state, then the result. The Go test spells it out four times
    /// (invoke and stream, in both modes).
    Future<void> pass(
      Runnable<String, String> r,
      String checkpointId, {
      required bool stream,
      _GraphCallback? callback,
    }) async {
      final options = [
        CallOption.checkpointId(checkpointId),
        if (callback != null) CallOption.callbacks([callback]),
      ];
      Future<Object?> run(RunContext runCtx) => stream
          ? r.stream(runCtx, 'start', options: options)
          : r.invoke(runCtx, 'start', options: options);

      // The graph "2" stops behind its node "1".
      var info = await _interruptOf(run(ctx));
      expect(_describeAll(info.subGraphs), {
        '2': _info(state: _TestStruct(''), afterNodes: ['1']),
      });
      _expectPoint(
        info.interruptContexts[0],
        InterruptCtx(
          id: '',
          address: _root(['2']),
          info: _TestStruct(''),
          isRootCause: true,
          parent: InterruptCtx(id: '', address: _root()),
        ),
      );

      // Resumed with a state, it stops behind its node "3", and the graph
      // "2" inside it behind its node "1".
      var rCtx = ctx.resumeWithData(
        info.interruptContexts[0].id,
        _TestStruct('state'),
      );
      info = await _interruptOf(run(rCtx));
      expect(_describeAll(info.subGraphs), {
        '2': _info(
          state: _TestStruct('state'),
          afterNodes: ['3'],
          subGraphs: {
            '2': _info(state: _TestStruct(''), afterNodes: ['1']),
          },
        ),
      });
      _expectPoint(
        info.interruptContexts[0],
        InterruptCtx(
          id: '',
          address: _root(['2', '2']),
          info: _TestStruct(''),
          isRootCause: true,
          parent: InterruptCtx(
            id: '',
            address: _root(['2']),
            info: _TestStruct('state'),
            parent: InterruptCtx(id: 'runnable:root', address: _root()),
          ),
        ),
      );

      // The inner graph resumed, the outer one stops in front of its node
      // "4".
      rCtx = ctx.resumeWithData(
        info.interruptContexts[0].id,
        _TestStruct('state'),
      );
      info = await _interruptOf(run(rCtx));
      expect(_describeAll(info.subGraphs), {
        '2': _info(state: _TestStruct('state'), beforeNodes: ['4']),
      });
      _expectPoint(
        info.interruptContexts[0],
        InterruptCtx(
          id: '',
          address: _root(['2']),
          info: _TestStruct('state'),
          isRootCause: true,
          parent: InterruptCtx(id: '', address: _root()),
        ),
      );

      rCtx = ctx.resumeWithData(
        info.interruptContexts[0].id,
        _TestStruct('state2'),
      );
      final String result;
      if (stream) {
        result = await _concat(
          await r.stream(rCtx, 'start', options: options),
        );
      } else {
        result = await r.invoke(rCtx, 'start', options: options);
      }
      expect(result, 'start11state1state24\nstart1134\nstate24\n3');
    }

    test('invoke, stream and the callbacks of the graphs', () async {
      final r = await g.compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: InMemoryCheckpointStore(),
          graphName: 'root',
        ),
      );

      final tGCB = _GraphCallback();
      await pass(r, '1', stream: false, callback: tGCB);
      await pass(r, '2', stream: true, callback: tGCB);

      // Go's comments, kept: the arithmetic does not add up, the numbers do.
      // Per pass the root graph starts 4 times, the graph "2" 4 times and the
      // graph inside it twice; 3 graphs end; 7 runs of a graph are
      // interrupted.
      expect(tGCB.onStartTimes, 10); // 3+sSubG*1*3+subG*2*2+g*0
      expect(tGCB.onEndTimes, 3); // success*3
      expect(tGCB.onStreamStartTimes, 10); // 3+sSubG*1*3+subG*2*2+g*0
      expect(tGCB.onStreamEndTimes, 3); // success*3
      expect(tGCB.onErrorTimes, 14); // 2*(sSubG*1*3+subG*2*2+g*0)
    });

    test('dag: invoke and stream', () async {
      final r = await g.compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: InMemoryCheckpointStore(),
          nodeTriggerMode: NodeTriggerMode.allPredecessor,
          graphName: 'root',
        ),
      );

      await pass(r, '1', stream: false);
      await pass(r, '2', stream: true);
    });
  });

  test('TestDAGInterrupt', () async {
    // Go lets the nodes sleep 100 ms and 200 ms; the same order with timers
    // short enough for the test suite.
    final g = Graph<String, Map<String, Object?>>()
      ..addLambdaNode(
        '1',
        Lambda.invokable((ctx, String input) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return input;
        }),
        options: const NodeOptions(outputKey: '1'),
      )
      ..addLambdaNode(
        '2',
        Lambda.invokable((ctx, String input) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return input;
        }),
        options: const NodeOptions(outputKey: '2'),
      )
      ..addPassthroughNode('3')
      ..addEdge(Graph.start, '1')
      ..addEdge(Graph.start, '2')
      ..addEdge('1', '3')
      ..addEdge('2', '3')
      ..addEdge('3', Graph.end);

    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(
        checkpointStore: InMemoryCheckpointStore(),
        interruptAfterNodes: const ['1', '2'],
      ),
    );

    final info = await _interruptOf(
      r.invoke(ctx, 'input', options: [CallOption.checkpointId('1')]),
    );
    expect(info.afterNodes, ['1', '2']);

    final result = await r.invoke(
      ctx,
      '',
      options: [CallOption.checkpointId('1')],
    );
    expect(result, {'1': 'input', '2': 'input'});
  });

  test('TestRerunNodeInterrupt', () async {
    final g = Graph<String, String>(localState: _testState());

    var times = 0;
    g
      ..addLambdaNode(
        '1',
        Lambda.invokable((ctx, String input) {
          try {
            if (times.isEven) {
              // Go: NewInterruptAndRerunErr("test extra").
              throw interrupt(ctx, 'test extra');
            }
            return input;
          } finally {
            times++;
          }
        }),
        options: NodeOptions(
          statePreHandler: StateHandler.pre<String, _TestStruct>(
            (ctx, input, state) => state.a,
          ),
        ),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);

    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
    );

    var info = await _interruptOf(
      r.invoke(ctx, 'input', options: [CallOption.checkpointId('1')]),
    );
    expect(info.rerunNodes, ['1']);

    final result = await r.invoke(
      ctx,
      '',
      options: [
        CallOption.checkpointId('1'),
        CallOption.stateModifier((ctx, path, state) {
          (state as _TestStruct).a = 'state';
        }),
      ],
    );
    expect(result, 'state');

    info = await _interruptOf(
      r.stream(ctx, 'input', options: [CallOption.checkpointId('2')]),
    );
    expect(info.rerunNodes, ['1']);
    expect(info.rerunNodesExtra['1'], 'test extra');

    final streamResult = await r.stream(
      ctx,
      '',
      options: [
        CallOption.checkpointId('2'),
        CallOption.stateModifier((ctx, path, state) {
          (state as _TestStruct).a = 'state';
        }),
      ],
    );
    expect(await streamResult.recv(), 'state');
    await expectLater(
      streamResult.recv(),
      throwsA(isA<StreamEOFException>()),
    );
  });

  test('TestInterfaceResume', () async {
    // A Go interface value can be nil: the input type is nullable.
    final g = Graph<_MyInterface?, String>();
    var times = 0;
    g
      ..addLambdaNode(
        '1',
        Lambda.invokable((ctx, _MyInterface? input) {
          if (times == 0) {
            times++;
            // Go: NewInterruptAndRerunErr("test extra").
            throw interrupt(ctx, 'test extra');
          }
          return 'success';
        }),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);

    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
    );

    final info = await _interruptOf(
      r.invoke(ctx, null, options: [CallOption.checkpointId('1')]),
    );
    expect(info.rerunNodes, ['1']);
    final result = await r.invoke(
      ctx,
      null,
      options: [CallOption.checkpointId('1')],
    );
    expect(result, 'success');
  });

  test('TestEarlyFailCallback', () async {
    final g = Graph<String, String>()
      ..addLambdaNode('1', Lambda.invokable((ctx, String input) => input))
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);

    final r = await g.compile(
      ctx,
      options: const GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
      ),
    );
    final tGCB = _GraphCallback();
    // A DAG takes no step limit: the run fails before its first step. Go
    // ignores what the call returns.
    try {
      await r.invoke(
        ctx,
        '',
        options: [
          CallOption.callbacks([tGCB]),
          CallOption.runtimeMaxSteps(1),
        ],
      );
    } on Object catch (_) {}
    expect(tGCB.onStartTimes, 1);
    expect(tGCB.onErrorTimes, 1);
    expect(tGCB.onEndTimes, 0);
  });

  test('TestGraphStartInterrupt', () async {
    final subG = Graph<String, String>()
      ..addLambdaNode(
        '1',
        Lambda.invokable((ctx, String input) => '${input}sub1'),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);

    final g = Graph<String, String>()
      ..addLambdaNode('1', Lambda.invokable((ctx, String input) => '${input}1'))
      ..addGraphNode(
        '2',
        subG,
        options: const NodeOptions(
          compileOptions: GraphCompileOptions(interruptBeforeNodes: ['1']),
        ),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge('2', Graph.end);

    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
    );

    final info = await _interruptOf(
      r.invoke(ctx, 'input', options: [CallOption.checkpointId('1')]),
    );
    expect(info.subGraphs['2']!.beforeNodes, ['1']);
    final result = await r.invoke(
      ctx,
      '',
      options: [CallOption.checkpointId('1')],
    );
    expect(result, 'input1sub1');
  });

  test('TestWithForceNewRun', () async {
    final g = Graph<String, String>()
      ..addLambdaNode('1', Lambda.invokable((ctx, String input) => '${input}1'))
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);
    final store = _FailStore();
    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: store),
    );
    final result = await r.invoke(
      ctx,
      'input',
      options: [CallOption.checkpointId('1'), CallOption.forceNewRun()],
    );
    expect(result, 'input1');
    // Go's store fails the test when it is called.
    expect(store.calls, isEmpty);
  });

  test('TestPreHandlerInterrupt', () async {
    final g = Graph<String, String>(
      localState: LocalState.of<_EmptyState>((ctx) => const _EmptyState()),
    );
    var times = 0;
    g
      ..addLambdaNode(
        '1',
        Lambda.invokable((ctx, String input) => '${input}1'),
        options: NodeOptions(
          statePreHandler: StateHandler.pre<String, _EmptyState>(
            (ctx, input, state) {
              if (times == 0) {
                times++;
                // Go: NewInterruptAndRerunErr("").
                throw interrupt(ctx, '');
              }
              return input;
            },
          ),
        ),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);

    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
    );
    final info = await _interruptOf(
      r.invoke(ctx, 'input', options: [CallOption.checkpointId('1')]),
    );
    expect(info.rerunNodes, ['1']);
    // The node runs again with the empty value of its input type, as in Go.
    final result = await r.invoke(
      ctx,
      '',
      options: [CallOption.checkpointId('1')],
    );
    expect(result, '1');
  });
}
