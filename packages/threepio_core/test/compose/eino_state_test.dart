// Port of eino `compose/state_test.go`.
//
// Not ported (checkpoints and interrupts are not part of P4):
// TestNestedGraphStateAfterResume, TestLambdaNestedGraphStateAfterResume.

import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/src/compose/local_state.dart'
    show withInternalState;
import 'package:threepio_core/src/compose/stream_conversion.dart'
    show concatStreamReader;
import 'package:threepio_core/threepio_core.dart';

/// Go: `type midStr string`, a type of its own between two nodes.
final class _MidStr {
  const _MidStr(this.value);
  final String value;
}

/// Go: `testState{ms []string}` of TestStateGraphWithEdge.
final class _MessagesState {
  final List<String> ms = [];
}

/// Go: `testStruct{UserID int64}` of TestStateGraphUtils.
final class _UserState {
  _UserState(this.userId);
  final int userId;
}

/// Go: `testState{Field1, Field2 string}` of TestStateChain / TestStreamState.
final class _FieldState {
  String field1 = '';
  String field2 = '';
}

/// Go: `NestedOuterState`.
final class _NestedOuterState {
  _NestedOuterState({required this.value, required this.counter});
  String value;
  int counter;
}

/// Go: `NestedInnerState`.
final class _NestedInnerState {
  _NestedInnerState({required this.value});
  String value;
}

/// Go: `CommonState` of TestNestedGraphStateShadowing.
final class _CommonState {
  _CommonState(this.value);
  String value;
}

Iterable<String> _fields(String text) =>
    text.split(RegExp(r'\s+')).where((field) => field.isNotEmpty);

void main() {
  final ctx = RunContext.background();

  test('TestStateGraphWithEdge', () async {
    const nodeOfL1 = 'invokable';
    const nodeOfL2 = 'streamable';
    const nodeOfL3 = 'transformable';
    const expected =
        'TransformableLambda: StreamableLambda: InvokableLambda: how are you ';

    // What the last post handler finds in the state, once per run.
    final lengthsAtTheEnd = <int>[];

    final l1 = Lambda<String, _MidStr>.invokable(
      (ctx, input) => _MidStr('InvokableLambda: $input'),
    );

    final l2 = Lambda<_MidStr, String>.streamable((ctx, input) {
      final outStr = 'StreamableLambda: ${input.value}';
      final (reader, writer) = pipe<String>(capacity: outStr.runes.length);
      unawaited(() async {
        for (final field in _fields(outStr)) {
          await writer.sendAsync('$field ');
        }
        await writer.close();
      }());
      return reader;
    });

    final l3 = Lambda<String, String>.transformable((ctx, input) {
      const prefix = 'TransformableLambda: ';
      final (reader, writer) = pipe<String>(capacity: 20);
      unawaited(() async {
        for (final field in _fields(prefix)) {
          await writer.sendAsync('$field ');
        }
        try {
          while (true) {
            final String chunk;
            try {
              chunk = await input.recv();
            } on StreamEOFException {
              break;
              // Go sends the error of the input on and stops.
              // ignore: avoid_catches_without_on_clauses
            } catch (error, stackTrace) {
              writer.sendError(error, stackTrace);
              break;
            }
            await writer.sendAsync(chunk);
          }
        } finally {
          await input.close();
          await writer.close();
        }
      }());
      return reader;
    });

    final sg = Graph<String, String>(
      localState: LocalState.of<_MessagesState>((ctx) => _MessagesState()),
    )
      ..addLambdaNode(
        nodeOfL1,
        l1,
        options: NodeOptions(
          statePreHandler: StateHandler.pre<String, _MessagesState>(
            (ctx, input, state) {
              state.ms.add(input);
              return input;
            },
          ),
          statePostHandler: StateHandler.post<_MidStr, _MessagesState>(
            (ctx, out, state) {
              state.ms.add(out.value);
              return out;
            },
          ),
        ),
      )
      ..addLambdaNode(
        nodeOfL2,
        l2,
        options: NodeOptions(
          statePostHandler: StateHandler.post<String, _MessagesState>(
            (ctx, out, state) {
              state.ms.add(out);
              return out;
            },
          ),
        ),
      )
      ..addLambdaNode(
        nodeOfL3,
        l3,
        options: NodeOptions(
          statePostHandler: StateHandler.post<String, _MessagesState>(
            (ctx, out, state) {
              state.ms.add(out);
              // Go: assert.Len(t, state.ms, 4) inside the handler.
              lengthsAtTheEnd.add(state.ms.length);
              return out;
            },
          ),
        ),
      )
      ..addEdge(Graph.start, nodeOfL1)
      ..addEdge(nodeOfL1, nodeOfL2)
      ..addEdge(nodeOfL2, nodeOfL3)
      ..addEdge(nodeOfL3, Graph.end);

    final run = await sg.compile(ctx);

    expect(await run.invoke(ctx, 'how are you'), expected);
    expect(lengthsAtTheEnd, [4]);

    var stream = await run.stream(ctx, 'how are you');
    expect(await concatStreamReader(stream), expected);
    expect(lengthsAtTheEnd, [4, 4]);

    final (reader, writer) = pipe<String>(capacity: 1);
    writer.send('how are you');
    await writer.close();

    stream = await run.transform(ctx, reader);
    expect(await concatStreamReader(stream), expected);
    expect(lengthsAtTheEnd, [4, 4, 4]);
  });

  group('TestStateGraphUtils', () {
    test('getState_success', () async {
      final stateCtx = withInternalState(
        RunContext.background(),
        _UserState(10),
      );

      int? userId;
      await processState<_UserState>(stateCtx, (_, state) {
        userId = state.userId;
      });
      expect(userId, 10);
    });

    // Go puts an internalState whose state is nil into the context and gets
    // "cannot find state with type: … current state type: <nil>". A state is
    // never null in Dart, so the nearest case is a context without a state,
    // which Go answers with "have not set state".
    test('getState_nil', () async {
      await expectLater(
        () => processState<_UserState>(RunContext.background(), (_, state) {}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('get state from context fail: have not set state'),
          ),
        ),
      );
    });

    test('getState_type_error', () async {
      final stateCtx = withInternalState(
        RunContext.background(),
        _UserState(10),
      );

      await expectLater(
        () => processState<String>(stateCtx, (_, state) {}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(
              'cannot find state with type: String in states chain, '
              'current state type: _UserState',
            ),
          ),
        ),
      );
    });
  });

  test('TestStateChain', () async {
    final sc = Chain<String, String>(
      localState: LocalState.of<_FieldState>((ctx) => _FieldState()),
    )
      ..appendLambda(
        Lambda<String, String>.invokable((ctx, input) async {
          await processState<_FieldState>(ctx, (_, state) {
            state.field1 = 'node1';
          });
          return input;
        }),
        options: NodeOptions(
          statePostHandler: StateHandler.post<String, _FieldState>(
            (ctx, out, state) {
              state.field2 = 'node2';
              return out;
            },
          ),
        ),
      )
      ..appendLambda(
        Lambda<String, String>.invokable((ctx, input) => input),
        options: NodeOptions(
          statePreHandler: StateHandler.pre<String, _FieldState>(
            (ctx, input, state) => input + state.field1 + state.field2,
          ),
        ),
      );

    final r = await sc.compile(ctx);
    expect(await r.invoke(ctx, 'start'), 'startnode1node2');
  });

  test('TestStreamState', () async {
    final s = _FieldState()..field1 = '1';
    final g = Graph<String, String>(
      localState: LocalState.of<_FieldState>((ctx) => s),
    )
      ..addLambdaNode(
        '1',
        Lambda<String, String>.transformable((ctx, input) => input),
        options: NodeOptions(
          streamStatePreHandler: StateHandler.streamPre<String, _FieldState>(
            (ctx, input, state) async {
              final (reader, writer) = pipe<String>(capacity: 5);
              for (var i = 0; i < 5; i++) {
                writer.send(state.field1);
              }
              await writer.close();
              return reader;
            },
          ),
          streamStatePostHandler: StateHandler.streamPost<String, _FieldState>(
            (ctx, input, state) async {
              final ss = input.copy(2);
              while (true) {
                try {
                  state.field1 += await ss[0].recv();
                } on StreamEOFException {
                  return ss[1];
                }
              }
            },
          ),
        ),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);

    final r = await g.compile(ctx);

    // As in Go, nothing is ever sent into the input: the pre handler replaces
    // it.
    final (input, inputWriter) = pipe<String>(capacity: 1);
    addTearDown(inputWriter.close);

    final streamResult = await r.transform(ctx, input);
    expect(s.field1, '111111');
    for (var i = 0; i < 5; i++) {
      expect(await streamResult.recv(), '1');
    }
    await expectLater(
      streamResult.recv(),
      throwsA(isA<StreamEOFException>()),
    );
    await streamResult.close();
  });

  // Nested Graph State Tests

  test('TestNestedGraphStateAccess', () async {
    // The inner graph can access the state of the outer graph.
    Future<String> innerNode(RunContext ctx, String input) async {
      var outerValue = '';
      await processState<_NestedOuterState>(ctx, (_, s) {
        outerValue = s.value;
      });

      var innerValue = '';
      await processState<_NestedInnerState>(ctx, (_, s) {
        innerValue = s.value;
      });

      return '${input}_inner=${innerValue}_outer=$outerValue';
    }

    final innerGraph = Graph<String, String>(
      localState: LocalState.of<_NestedInnerState>(
        (ctx) => _NestedInnerState(value: 'inner'),
      ),
    )
      ..addLambdaNode('inner_node', Lambda<String, String>.invokable(innerNode))
      ..addEdge(Graph.start, 'inner_node')
      ..addEdge('inner_node', Graph.end);

    final outerGraph = Graph<String, String>(
      localState: LocalState.of<_NestedOuterState>(
        (ctx) => _NestedOuterState(value: 'outer', counter: 0),
      ),
    )
      ..addGraphNode('inner_graph', innerGraph)
      ..addEdge(Graph.start, 'inner_graph')
      ..addEdge('inner_graph', Graph.end);

    final r = await outerGraph.compile(ctx);
    expect(await r.invoke(ctx, 'start'), 'start_inner=inner_outer=outer');
  });

  test('TestNestedGraphStateShadowing', () async {
    // The inner state shadows the outer state of the same type (lexical
    // scoping).
    Future<String> innerNode(RunContext ctx, String input) async {
      var value = '';
      await processState<_CommonState>(ctx, (_, s) {
        // "inner", because the inner state shadows the outer one.
        value = s.value;
      });
      return '${input}_$value';
    }

    final innerGraph = Graph<String, String>(
      localState: LocalState.of<_CommonState>((ctx) => _CommonState('inner')),
    )
      ..addLambdaNode('inner_node', Lambda<String, String>.invokable(innerNode))
      ..addEdge(Graph.start, 'inner_node')
      ..addEdge('inner_node', Graph.end);

    final outerGraph = Graph<String, String>(
      localState: LocalState.of<_CommonState>((ctx) => _CommonState('outer')),
    )
      ..addGraphNode('inner_graph', innerGraph)
      ..addEdge(Graph.start, 'inner_graph')
      ..addEdge('inner_graph', Graph.end);

    final r = await outerGraph.compile(ctx);
    expect(await r.invoke(ctx, 'start'), 'start_inner');
  });

  test('TestLambdaNestedGraphStateAccess', () async {
    // An inner graph that a lambda invokes can access the state of the outer
    // graph: outer graph -> lambda node -> inner graph.
    Future<String> innerNode(RunContext ctx, String input) async {
      var outerValue = '';
      var outerCounter = 0;
      await processState<_NestedOuterState>(ctx, (_, s) {
        outerValue = s.value;
        outerCounter = s.counter;
      });

      var innerValue = '';
      await processState<_NestedInnerState>(ctx, (_, s) {
        innerValue = s.value;
      });

      return '${input}_inner=${innerValue}_outer=${outerValue}_$outerCounter';
    }

    final innerGraph = Graph<String, String>(
      localState: LocalState.of<_NestedInnerState>(
        (ctx) => _NestedInnerState(value: 'inner'),
      ),
    )
      ..addLambdaNode('inner_node', Lambda<String, String>.invokable(innerNode))
      ..addEdge(Graph.start, 'inner_node')
      ..addEdge('inner_node', Graph.end);

    // The inner graph is a runnable of its own.
    final innerRunnable = await innerGraph.compile(ctx);

    // The state travels in the context the lambda passes on.
    final lambdaNode = Lambda<String, String>.invokable(innerRunnable.invoke);

    final outerGraph = Graph<String, String>(
      localState: LocalState.of<_NestedOuterState>(
        (ctx) => _NestedOuterState(value: 'outer', counter: 100),
      ),
    )
      ..addLambdaNode('lambda_with_graph', lambdaNode)
      ..addEdge(Graph.start, 'lambda_with_graph')
      ..addEdge('lambda_with_graph', Graph.end);

    final r = await outerGraph.compile(ctx);
    expect(
      await r.invoke(ctx, 'start'),
      'start_inner=inner_outer=outer_100',
    );
  });

  test('TestNestedGraphStateConcurrency', () async {
    // Concurrent access to the parent state and to the child state takes
    // turns per state. Go proves that with the race detector; here a lost
    // update would show in the counter.
    late _NestedOuterState outerState;
    var innerVisits = 0;

    Future<String> innerNode(RunContext ctx, String input) async {
      await Future.wait([
        // Ten tasks that change the outer state.
        for (var i = 0; i < 10; i++)
          processState<_NestedOuterState>(ctx, (_, s) async {
            // processState keeps the state of the parent to this function
            // until it has finished.
            final current = s.counter;
            await Future<void>.delayed(const Duration(milliseconds: 1));
            s.counter = current + 1;
          }),
        // Ten tasks that use the inner state.
        for (var i = 0; i < 10; i++)
          processState<_NestedInnerState>(ctx, (_, s) {
            innerVisits++;
          }),
      ]);
      return input;
    }

    final innerGraph = Graph<String, String>(
      localState: LocalState.of<_NestedInnerState>(
        (ctx) => _NestedInnerState(value: 'inner'),
      ),
    )
      ..addLambdaNode('inner_node', Lambda<String, String>.invokable(innerNode))
      ..addEdge(Graph.start, 'inner_node')
      ..addEdge('inner_node', Graph.end);

    final outerGraph = Graph<String, String>(
      localState: LocalState.of<_NestedOuterState>(
        (ctx) => outerState = _NestedOuterState(value: 'outer', counter: 0),
      ),
    )
      ..addGraphNode('inner_graph', innerGraph)
      ..addEdge(Graph.start, 'inner_graph')
      ..addEdge('inner_graph', Graph.end);

    final r = await outerGraph.compile(ctx);
    expect(await r.invoke(ctx, 'start'), 'start');

    expect(outerState.counter, 10);
    expect(innerVisits, 10);
  });
}
