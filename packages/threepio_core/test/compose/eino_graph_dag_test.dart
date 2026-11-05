// Port of eino `compose/graph_test.go` (TestCheckAddEdge, TestStartWithEnd,
// TestContextCancel, TestDAGStart, TestBaseDAGBranch, TestMultiDAGBranch,
// TestCrossDAGBranch, TestNestedDAGBranch, TestHandlerTypeValidate,
// TestSetFanInMergeConfig_RealStreamNode, TestFindLoops, TestSkipBranch,
// TestGetStateInGraphCallback) and of `compose/dag_test.go` (TestDAG).
//
// Not ported, because the Go helpers they test were not ported:
// TestTransferTask, TestToString, TestPrintTasks, TestUniqueSlice.

import 'package:test/test.dart';
import 'package:threepio_core/src/compose/graph.dart' show findLoops;
import 'package:threepio_core/src/compose/task_manager.dart' show ChanCall;
import 'package:threepio_core/threepio_core.dart';

/// Go: `concatLambda`.
Lambda<String, String> _concatLambda(String s) =>
    Lambda<String, String>.invokable((ctx, input) => '$input$s');

/// Go: `mapLambda`.
Lambda<Map<String, String>, Map<String, String>> _mapLambda(
  String k,
  String v,
) =>
    Lambda<Map<String, String>, Map<String, String>>.invokable(
      (ctx, input) => {k: v},
    );

Lambda<String, String> _identity() =>
    Lambda<String, String>.invokable((ctx, input) => input);

/// Go's `for { chunk, err := sr.Recv(); if err == io.EOF { break } … }`,
/// bounded: everything but the end of the stream fails the test.
Future<List<T>> _recvAll<T>(StreamReader<T> reader, {int limit = 100}) async {
  final chunks = <T>[];
  for (var i = 0; i <= limit; i++) {
    try {
      chunks.add(await reader.recv());
    } on StreamEOFException {
      return chunks;
    }
  }
  fail('the stream did not end within $limit chunks');
}

Matcher _throwsBuildError(String text) => throwsA(
      isA<GraphBuildException>()
          .having((e) => e.message, 'message', contains(text)),
    );

/// Go: `normalizeLoops`. Every loop rotated so that it starts with its
/// smallest node, as a comma separated string; the strings sorted.
List<String> _normalizeLoops(List<List<String>> loops) {
  final result = <String>[];
  for (final loop in loops) {
    if (loop.isEmpty) continue;
    final normalized = [...loop];
    if (normalized.first != normalized.last) normalized.add(normalized.first);

    var minIdx = 0;
    for (var i = 1; i < normalized.length - 1; i++) {
      if (normalized[i].compareTo(normalized[minIdx]) < 0) minIdx = i;
    }

    final canonical = StringBuffer();
    for (var i = 0; i < normalized.length - 1; i++) {
      canonical
        ..write(normalized[(minIdx + i) % (normalized.length - 1)])
        ..write(',');
    }
    canonical.write(normalized[minIdx]);
    result.add(canonical.toString());
  }
  return result..sort();
}

/// Go builds `&chanCall{controls: …, writeToBranches: []*GraphBranch{{endNodes:
/// …}}}`. A Dart `GraphBranch` has no public constructor, so the branch that
/// only has end nodes is made with `GraphBranch.multi`.
ChanCall _call(
  List<String> controls, {
  List<Set<String>> branches = const [],
}) =>
    ChanCall(
      writeTo: const [],
      controls: controls,
      writeToBranches: [
        for (final ends in branches)
          GraphBranch.multi<String>((ctx, input) => ends, ends),
      ],
    );

/// Go: `state`.
final class _State {
  String a = '';
}

void main() {
  final ctx = RunContext.background();

  tearDown(ValuesMerge.reset);

  test('TestCheckAddEdge', () {
    final g = Graph<String, String>()
      ..addPassthroughNode('1')
      ..addPassthroughNode('2')
      ..addEdge('1', '2');
    // "add edge repeatedly haven't report error"
    expect(() => g.addEdge('1', '2'), throwsA(isA<GraphBuildException>()));
  });

  test('TestStartWithEnd', () async {
    final g = Graph<String, String>()
      ..addLambdaNode('1', _identity())
      ..addBranch(
        Graph.start,
        GraphBranch.single<String>(
          (ctx, input) => Graph.end,
          {'1', Graph.end},
        ),
      );
    final r = await g.compile(ctx);

    final (sr, sw) = pipe<String>(capacity: 1);
    sw.send('test');
    await sw.close();
    final result = await r.transform(ctx, sr);
    final chunks = await _recvAll(result);
    expect(chunks, everyElement('test'), reason: 'result is out of expect');
    expect(chunks, isNotEmpty);
  });

  test('TestContextCancel', () async {
    final g = Graph<String, String>()
      ..addLambdaNode('1', _identity())
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);
    final r = await g.compile(ctx);

    final token = CancelToken()..cancel();
    await expectLater(
      r.invoke(RunContext.background(cancelToken: token), 'test'),
      throwsA(
        isA<GraphRunException>()
            .having(
              (e) => e.toString(),
              'text',
              contains('context has been canceled'),
            )
            .having((e) => e.cause, 'cause', isA<CancelledException>()),
      ),
      reason: 'graph have not returned canceled error',
    );
  });

  test('TestDAGStart', () async {
    final g = Graph<Map<String, Object?>, Map<String, Object?>>()
      ..addLambdaNode(
        '1',
        Lambda<Map<String, Object?>, Map<String, Object?>>.invokable(
          (ctx, input) => {'1': '1'},
        ),
      )
      ..addLambdaNode(
        '2',
        Lambda<Map<String, Object?>, Map<String, Object?>>.invokable(
          (ctx, input) => input,
        ),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge(Graph.start, '2')
      ..addEdge('2', Graph.end);
    final r = await g.compile(
      ctx,
      options: const GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
      ),
    );
    expect(
      await r.invoke(ctx, {'start': 'start'}),
      {'start': 'start', '1': '1'},
    );
  });

  test('TestBaseDAGBranch', () async {
    final g = Graph<String, String>()
      ..addLambdaNode('1', _concatLambda('1'))
      ..addLambdaNode('2', _concatLambda('2'))
      ..addBranch(
        Graph.start,
        GraphBranch.single<String>(
          (ctx, input) => input.length > 3 ? '2' : '1',
          {'1', '2'},
        ),
      )
      ..addEdge('1', Graph.end)
      ..addEdge('2', Graph.end);

    final r = await g.compile(
      ctx,
      options: const GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
      ),
    );
    expect(await r.invoke(ctx, 'hi'), 'hi1');
  });

  test('TestMultiDAGBranch', () async {
    // Go merges the `map[string]string` outputs of the nodes 1 and 3 by
    // reflection. The Dart default merge gives a `Map<String, Object?>`
    // (intended deviation), so a graph that ends in a `Map<String, String>`
    // registers the merge of that type.
    ValuesMerge.register<Map<String, String>>(
      (maps) => {for (final map in maps) ...map},
    );

    final g = Graph<Map<String, String>, Map<String, String>>()
      ..addLambdaNode('1', _mapLambda('1', '1'))
      ..addLambdaNode('2', _mapLambda('2', '2'))
      ..addLambdaNode('3', _mapLambda('3', '3'))
      ..addLambdaNode('4', _mapLambda('4', '4'))
      ..addBranch(
        Graph.start,
        GraphBranch.single<Map<String, String>>(
          (ctx, input) => input['input']!.length > 3 ? '2' : '1',
          {'1', '2'},
        ),
      )
      ..addBranch(
        Graph.start,
        GraphBranch.single<Map<String, String>>(
          (ctx, input) => input['input']!.length > 3 ? '4' : '3',
          {'3', '4'},
        ),
      )
      ..addEdge('1', Graph.end)
      ..addEdge('2', Graph.end)
      ..addEdge('3', Graph.end)
      ..addEdge('4', Graph.end);

    final r = await g.compile(
      ctx,
      options: const GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
      ),
    );
    expect(await r.invoke(ctx, {'input': 'hi'}), {'1': '1', '3': '3'});
  });

  test('TestCrossDAGBranch', () async {
    // See TestMultiDAGBranch for the registration.
    ValuesMerge.register<Map<String, String>>(
      (maps) => {for (final map in maps) ...map},
    );

    final g = Graph<Map<String, String>, Map<String, String>>()
      ..addLambdaNode('1', _mapLambda('1', '1'))
      ..addLambdaNode('2', _mapLambda('2', '2'))
      ..addLambdaNode('3', _mapLambda('3', '3'))
      ..addBranch(
        Graph.start,
        GraphBranch.single<Map<String, String>>(
          (ctx, input) => input['input']!.length > 3 ? '2' : '1',
          {'1', '2'},
        ),
      )
      ..addBranch(
        Graph.start,
        GraphBranch.single<Map<String, String>>(
          (ctx, input) => input['input']!.length > 3 ? '3' : '2',
          {'2', '3'},
        ),
      )
      ..addEdge('1', Graph.end)
      ..addEdge('2', Graph.end)
      ..addEdge('3', Graph.end);

    final r = await g.compile(
      ctx,
      options: const GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
      ),
    );
    expect(await r.invoke(ctx, {'input': 'hi'}), {'1': '1', '2': '2'});
  });

  test('TestNestedDAGBranch', () async {
    final g = Graph<String, String>()
      ..addLambdaNode('1', _concatLambda('1'))
      ..addLambdaNode('2', _concatLambda('2'))
      ..addLambdaNode('3', _concatLambda('3'))
      ..addLambdaNode('4', _concatLambda('4'))
      ..addBranch(
        Graph.start,
        GraphBranch.single<String>(
          (ctx, input) => input.length > 3 ? '2' : '1',
          {'1', '2'},
        ),
      )
      ..addBranch(
        '2',
        GraphBranch.single<String>(
          (ctx, input) => input.length > 10 ? '4' : '3',
          {'3', '4'},
        ),
      )
      ..addEdge('1', Graph.end)
      ..addEdge('3', Graph.end)
      ..addEdge('4', Graph.end);

    final r = await g.compile(
      ctx,
      options: const GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
      ),
    );
    expect(await r.invoke(ctx, 'hello'), 'hello23');
    expect(await r.invoke(ctx, 'hi'), 'hi1');
    expect(await r.invoke(ctx, 'hellohello'), 'hellohello24');
  });

  group('TestHandlerTypeValidate', () {
    // Go resets `g.buildError = nil` after every failing case. In Dart the
    // first build error sticks to the graph, so every failing case gets a
    // graph of its own; the passing cases share one, as in Go.
    Graph<String, String> newGraph() => Graph<String, String>(
          localState: LocalState.of<String>((ctx) => ''),
        );

    StateHandler stringPre() =>
        StateHandler.pre<String, String>((ctx, input, state) => '');
    StateHandler stringPost() =>
        StateHandler.post<String, String>((ctx, output, state) => '');
    Lambda<int, int> intLambda() =>
        Lambda<int, int>.invokable((ctx, input) => 0);
    Lambda<String, String> stringLambda() =>
        Lambda<String, String>.invokable((ctx, input) => '');

    test('passthrough pre fail', () {
      expect(
        () => newGraph().addPassthroughNode(
          '1',
          options: NodeOptions(statePreHandler: stringPre()),
        ),
        _throwsBuildError("passthrough node[1]'s pre handler type isn't any"),
      );
    });

    test('passthrough pre fail with input key', () {
      expect(
        () => newGraph().addPassthroughNode(
          '1',
          options: NodeOptions(statePreHandler: stringPre(), inputKey: 'input'),
        ),
        _throwsBuildError(
          "node[1]'s pre handler type[String] is different from its input "
          'type[Map<String, Object?>]',
        ),
      );
    });

    test('passthrough post fail', () {
      expect(
        () => newGraph().addPassthroughNode(
          '1',
          options: NodeOptions(statePostHandler: stringPost()),
        ),
        _throwsBuildError("passthrough node[1]'s post handler type isn't any"),
      );
    });

    test('passthrough post fail with input key', () {
      expect(
        () => newGraph().addPassthroughNode(
          '1',
          options:
              NodeOptions(statePostHandler: stringPost(), inputKey: 'input'),
        ),
        _throwsBuildError("passthrough node[1]'s post handler type isn't any"),
      );
    });

    test('common node pre fail', () {
      expect(
        () => newGraph().addLambdaNode(
          '5',
          intLambda(),
          options: NodeOptions(statePreHandler: stringPre()),
        ),
        _throwsBuildError(
          "node[5]'s pre handler type[String] is different from its input "
          'type[int]',
        ),
      );
    });

    test('common node post fail', () {
      expect(
        () => newGraph().addLambdaNode(
          '5',
          intLambda(),
          options: NodeOptions(statePostHandler: stringPost()),
        ),
        _throwsBuildError(
          "node[5]'s post handler type[String] is different from its output "
          'type[int]',
        ),
      );
    });

    test('pre state fail', () {
      expect(
        () => newGraph().addLambdaNode(
          '7',
          stringLambda(),
          options: NodeOptions(
            statePreHandler:
                StateHandler.pre<String, int>((ctx, input, state) => ''),
          ),
        ),
        _throwsBuildError(
          "node[7]'s pre handler state type[int] is different from "
          'graph[String]',
        ),
      );
    });

    test('post state fail', () {
      expect(
        () => newGraph().addLambdaNode(
          '7',
          stringLambda(),
          options: NodeOptions(
            statePostHandler:
                StateHandler.post<String, int>((ctx, output, state) => ''),
          ),
        ),
        _throwsBuildError(
          "node[7]'s post handler state type[int] is different from "
          'graph[String]',
        ),
      );
    });

    test('the handlers that fit are accepted', () {
      final g = newGraph()
        // passthrough pre success
        ..addPassthroughNode(
          '1',
          options: NodeOptions(
            statePreHandler:
                StateHandler.pre<Object?, String>((ctx, input, state) => ''),
          ),
        )
        // passthrough pre success with input key
        ..addPassthroughNode(
          '2',
          options: NodeOptions(
            statePreHandler: StateHandler.pre<Map<String, Object?>, String>(
              (ctx, input, state) => <String, Object?>{},
            ),
            inputKey: 'input',
          ),
        )
        // passthrough post success
        ..addPassthroughNode(
          '3',
          options: NodeOptions(
            statePostHandler:
                StateHandler.post<Object?, String>((ctx, output, state) => ''),
          ),
        )
        // passthrough post success with output key
        ..addPassthroughNode(
          '4',
          options: NodeOptions(
            statePostHandler: StateHandler.post<Map<String, Object?>, String>(
              (ctx, output, state) => <String, Object?>{},
            ),
            outputKey: 'output',
          ),
        )
        // common node pre success
        ..addLambdaNode(
          '5',
          stringLambda(),
          options: NodeOptions(statePreHandler: stringPre()),
        )
        // common node post success
        ..addLambdaNode(
          '6',
          stringLambda(),
          options: NodeOptions(statePostHandler: stringPost()),
        )
        // common pre success with input key
        ..addLambdaNode(
          '7',
          stringLambda(),
          options: NodeOptions(
            statePreHandler: StateHandler.pre<Map<String, Object?>, String>(
              (ctx, input, state) => <String, Object?>{},
            ),
            inputKey: 'input',
          ),
        )
        // common post success with output key
        ..addLambdaNode(
          '8',
          stringLambda(),
          options: NodeOptions(
            statePostHandler: StateHandler.post<Map<String, Object?>, String>(
              (ctx, output, state) => <String, Object?>{},
            ),
            outputKey: 'output',
          ),
        );
      expect(
        g.info.nodes.keys,
        ['1', '2', '3', '4', '5', '6', '7', '8'],
      );
    });
  });

  group('TestSetFanInMergeConfig_RealStreamNode', () {
    for (final triggerMode in [
      NodeTriggerMode.anyPredecessor,
      NodeTriggerMode.allPredecessor,
    ]) {
      test(triggerMode.name, () async {
        // Two stream nodes that give streams of ints.
        final g = Graph<int, Map<String, Object?>>()
          ..addLambdaNode(
            's1',
            Lambda<int, int>.streamable((ctx, input) async {
              final (sr, sw) = pipe<int>(capacity: 2);
              sw
                ..send(input + 1)
                ..send(input + 2);
              await sw.close();
              return sr;
            }),
            options: const NodeOptions(outputKey: 's1'),
          )
          ..addLambdaNode(
            's2',
            Lambda<int, int>.streamable((ctx, input) async {
              final (sr, sw) = pipe<int>(capacity: 2);
              sw
                ..send(input + 10)
                ..send(input + 20);
              await sw.close();
              return sr;
            }),
            options: const NodeOptions(outputKey: 's2'),
          )
          // START -> s1, START -> s2, s1 -> END, s2 -> END
          ..addEdge(Graph.start, 's1')
          ..addEdge(Graph.start, 's2')
          ..addEdge('s1', Graph.end)
          ..addEdge('s2', Graph.end);

        final r = await g.compile(
          ctx,
          options: GraphCompileOptions(
            nodeTriggerMode: triggerMode,
            fanInMergeConfig: const {
              Graph.end: FanInMergeConfig(streamMergeWithSourceEof: true),
            },
          ),
        );

        // Run the graph in stream mode and look for the SourceEOF events.
        final sr = await r.stream(ctx, 1);

        final merged = <String, Set<int>>{};
        var sourceEofCount = 0;
        final sourceNames = <String>{};
        var ended = false;
        for (var i = 0; i < 100 && !ended; i++) {
          try {
            final m = await sr.recv();
            for (final MapEntry(:key, :value) in m.entries) {
              (merged[key] ??= {}).add(value! as int);
            }
          } on SourceEOFException catch (e) {
            sourceEofCount++;
            sourceNames.add(e.sourceName);
          } on StreamEOFException {
            ended = true;
          }
        }
        expect(ended, isTrue, reason: 'the merged stream did not end');

        // The merged map has both results.
        expect(merged, {
          's1': {2, 3},
          's2': {11, 21},
        });
        expect(
          sourceEofCount,
          2,
          reason: 'should receive SourceEOF for each input stream when '
              'StreamMergeWithSourceEOF is true',
        );
        expect(sourceNames, contains('s1'));
        expect(sourceNames, contains('s2'));
      });
    }
  });

  group('TestFindLoops', () {
    final tests = <({
      String name,
      List<String> startNodes,
      Map<String, ChanCall> chanCalls,
      List<List<String>> expected,
    })>[
      (
        name: 'Graph without cycles',
        startNodes: ['A'],
        chanCalls: {
          'A': _call(['B', 'C']),
          'B': _call(['D']),
          'C': _call(['E']),
          'D': _call([]),
          'E': _call([]),
        },
        expected: [],
      ),
      (
        name: 'Graph with self-loop',
        startNodes: ['A'],
        chanCalls: {
          'A': _call(['A', 'B']),
          'B': _call([]),
        },
        expected: [
          ['A', 'A'],
        ],
      ),
      (
        name: 'Graph with simple cycle',
        startNodes: ['A', 'B', 'C'],
        chanCalls: {
          'A': _call(['B']),
          'B': _call(['C']),
          'C': _call(['A']),
        },
        expected: [
          ['A', 'B', 'C', 'A'],
        ],
      ),
      (
        name: 'Graph with multiple cycles',
        startNodes: ['A', 'B', 'C', 'D', 'E', 'F'],
        chanCalls: {
          'A': _call(['B', 'D']),
          'B': _call(['C']),
          'C': _call(['B']),
          'D': _call(['E']),
          'E': _call(['F']),
          'F': _call(['D']),
        },
        expected: [
          ['B', 'C', 'B'],
          ['D', 'E', 'F', 'D'],
        ],
      ),
      (
        name: 'Graph with branch cycle',
        startNodes: ['A', 'C'],
        chanCalls: {
          'A': _call(
            ['B'],
            branches: [
              {'C'},
            ],
          ),
          'B': _call([]),
          'C': _call(['A']),
        },
        expected: [
          ['A', 'C', 'A'],
        ],
      ),
      (
        name: 'Empty graph',
        startNodes: [],
        chanCalls: {},
        expected: [],
      ),
    ];

    for (final tt in tests) {
      test(tt.name, () {
        final loops = findLoops(tt.startNodes, tt.chanCalls);

        expect(loops, hasLength(tt.expected.length));

        if (tt.expected.isNotEmpty) {
          expect(_normalizeLoops(loops), _normalizeLoops(tt.expected));
        }
      });
    }
  });

  group('TestSkipBranch', () {
    Graph<String, String> newGraph() => Graph<String, String>()
      ..addLambdaNode('1', _identity())
      ..addLambdaNode('2', _identity())
      ..addEdge(Graph.start, '1')
      ..addBranch(
        '1',
        GraphBranch.multi<String>((ctx, input) => <String>{}, {'2'}),
      )
      ..addEdge('2', Graph.end);

    const dag = GraphCompileOptions(
      nodeTriggerMode: NodeTriggerMode.allPredecessor,
    );

    test('a branch that chooses nothing leaves no task', () async {
      final r = await newGraph().compile(ctx, options: dag);
      await expectLater(
        r.invoke(ctx, 'input'),
        throwsA(
          isA<GraphRunException>().having(
            (e) => e.toString(),
            'text',
            contains(
              '[GraphRunError] no tasks to execute, last completed nodes: [1]',
            ),
          ),
        ),
      );
    });

    test('a node with another predecessor still runs', () async {
      final g = newGraph()..addEdge(Graph.start, '2');
      final r = await g.compile(ctx, options: dag);
      expect(await r.invoke(ctx, 'input'), 'input');
    });
  });

  test('TestGetStateInGraphCallback', () async {
    final states = <_State>[];
    final g = Graph<String, String>(
      localState: LocalState.of<_State>((ctx) {
        final state = _State();
        states.add(state);
        return state;
      }),
    )
      ..addLambdaNode('1', _identity())
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);
    final r = await g.compile(ctx);

    // Go: `testGraphStateCallbackHandler`. A hook that throws is logged and
    // not propagated, so the outcome of `processState` is recorded and
    // asserted here instead of inside the hook.
    final seen = <ComponentType>[];
    final failures = <Object>[];
    final handler = CallbackHandlerBuilder().onStart((ctx, info, input) async {
      seen.add(info.componentType);
      try {
        await processState<_State>(ctx, (ctx, s) {
          s.a = 'test';
        });
        // Whatever it throws is what the Go test asserts not to happen.
        // ignore: avoid_catches_without_on_clauses
      } catch (error) {
        failures.add(error);
      }
      return ctx;
    }).build();

    await r.invoke(ctx, 'input', options: [
      CallOption.callbacks([handler]),
    ]);

    expect(failures, isEmpty);
    expect(seen, contains(ComponentType.graph));
    expect(states.single.a, 'test');
  });

  group('TestDAG', () {
    test('success', () async {
      final g = Graph<String, String>()
        ..addLambdaNode(
          '1',
          _identity(),
          options: const NodeOptions(outputKey: '1'),
        )
        ..addLambdaNode(
          '2',
          _identity(),
          options: const NodeOptions(outputKey: '2'),
        )
        ..addLambdaNode(
          '3',
          Lambda<Map<String, Object?>, String>.invokable((ctx, input) {
            if (!input.containsKey('1')) {
              throw Exception('node 1 output fail: $input');
            }
            if (!input.containsKey('2')) {
              throw Exception('node 2 output fail: $input');
            }
            return (input['1']! as String) + (input['2']! as String);
          }),
        )
        ..addLambdaNode('4', _identity())
        ..addLambdaNode('5', _identity())
        ..addLambdaNode(
          '6',
          _identity(),
          options: const NodeOptions(outputKey: '6'),
        )
        ..addLambdaNode(
          '7',
          Lambda<Map<String, Object?>, String>.invokable((ctx, input) {
            if (!input.containsKey('1')) {
              throw Exception('7:node 1 output fail: $input');
            }
            if (!input.containsKey('6')) {
              throw Exception('7:node 6 output fail: $input');
            }
            return (input['1']! as String) + (input['6']! as String);
          }),
        )
        ..addEdge('1', '3')
        ..addEdge('2', '3')
        ..addEdge('3', '4')
        ..addEdge('4', '5')
        ..addEdge('4', '6')
        ..addEdge('6', '7')
        ..addEdge('1', '7')
        ..addEdge(Graph.start, '1')
        ..addEdge(Graph.start, '2')
        ..addEdge('7', Graph.end);

      final runner = await g.compile(
        ctx,
        options: const GraphCompileOptions(
          nodeTriggerMode: NodeTriggerMode.allPredecessor,
        ),
      );

      expect(
        await runner.invoke(ctx, 'hello'),
        'hellohellohello',
        reason: 'node7 fail',
      );
      expect(
        await runner.invoke(ctx, '1'),
        '111',
        reason: 'runner invoke fail',
      );

      final streamResult = await runner.stream(ctx, '1');
      addTearDown(streamResult.close);
      expect(
        (await _recvAll(streamResult)).join(),
        '111',
        reason: 'runner stream fail',
      );
    });

    test('loop', () async {
      final gg = Graph<String, Map<String, Object?>>()
        ..addLambdaNode(
          '1',
          _identity(),
          options: const NodeOptions(outputKey: '1'),
        )
        ..addLambdaNode(
          '2',
          Lambda<Map<String, Object?>, String>.invokable(
            (ctx, input) => input['1']! as String,
          ),
        )
        ..addLambdaNode(
          '3',
          _identity(),
          options: const NodeOptions(outputKey: '3'),
        )
        ..addEdge('1', '2')
        ..addEdge('2', '3')
        ..addEdge('3', '2')
        ..addEdge(Graph.start, '1')
        ..addEdge('3', Graph.end);

      const dag = GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
      );
      final throwsLoop = throwsA(
        isA<DagLoopException>().having(
          (e) => _normalizeLoops(e.loops),
          'loops',
          ['2,3,2'],
        ),
      );

      // "cannot validate loop". Go calls the unexported `gg.compile(ctx,
      // &graphCompileOptions{nodeTriggerMode: AllPredecessor})`: the engine
      // underneath the graph.
      await expectLater(gg.engine.compile(ctx, dag), throwsLoop);
      // The same through the public `compile`.
      await expectLater(gg.compile(ctx, options: dag), throwsLoop);
    });
  });
}
