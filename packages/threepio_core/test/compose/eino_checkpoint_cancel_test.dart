// Port of eino `compose/checkpoint_test.go` (v0.9.22), from `TestCancelInterrupt`
// (line 1417) to the end of the file: interrupts from outside
// (`WithGraphInterrupt`), the input a cut-off node gets back, and the
// conversion of streams when a checkpoint is written.
//
// Timing. The Go tests sleep on the wall clock and interrupt from a goroutine.
// Here either the same time line runs on a fake clock (`TestCancelInterrupt`,
// whose interrupts have a grace period), or the node waits at a `_Sleep` the
// test controls: the test interrupts when the node has gone to sleep, which is
// what Go's `time.Sleep(100 * time.Millisecond)` before `cancel(...)` is for.
//
// Go reaches into unexported code in some tests. Where the Dart port keeps
// that code private, the test goes through the public way to it and says so.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/src/compose/checkpoint.dart';
import 'package:threepio_core/src/compose/graph_interrupt.dart';
import 'package:threepio_core/src/compose/interrupt.dart';
import 'package:threepio_core/src/compose/stream_conversion.dart';
import 'package:threepio_core/src/compose/type_ref.dart';

final _ctx = RunContext.background();

/// Go `testPersistRerunInputState`.
final class _PersistRerunInputState {
  _PersistRerunInputState(this.prefix);

  factory _PersistRerunInputState.fromJson(Map<String, Object?> json) =>
      _PersistRerunInputState(json['prefix']! as String);

  final String prefix;

  Map<String, Object?> toJson() => {'prefix': prefix};
}

/// Go `longRunningToolInput`.
final class _LongRunningToolInput {
  _LongRunningToolInput.fromJson(Map<String, Object?> json)
      : input = json['input']! as String;

  final String input;
}

/// Go `checkpointTestTool`: decodes the arguments, calls the function and
/// encodes what it returns as JSON.
final class _CheckpointTestTool<I, O> extends InvokableTool {
  _CheckpointTestTool(this._info, this._fromJson, this._fn);

  final ToolInfo _info;
  final I Function(Map<String, Object?> json) _fromJson;
  final FutureOr<O> Function(RunContext ctx, I input) _fn;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final input = _fromJson(jsonDecode(argumentsJson) as Map<String, Object?>);
    return jsonEncode(await _fn(ctx, input));
  }
}

/// Stands in for a `time.Sleep` that outlasts the interrupt of a test: the
/// node waits here until the test ends the sleep. A sleep also ends when the
/// test is over, so that a node the test gave up does not hang.
final class _Sleep {
  _Sleep() {
    addTearDown(wake);
  }

  final _started = Completer<void>();
  final _over = Completer<void>();

  /// Completes when a node has gone to sleep.
  Future<void> get started => _started.future;

  /// Called by the node: sleeps until [wake].
  Future<void> call() {
    if (!_started.isCompleted) _started.complete();
    return _over.future;
  }

  /// Ends the sleep, for the node that sleeps and for every later one.
  void wake() {
    if (!_over.isCompleted) _over.complete();
  }
}

/// The interrupt [run] ends with.
///
/// Go: `info, ok := ExtractInterruptInfo(err)` with `assert.True(t, ok)`.
Future<GraphInterruptInfo> _interruptOf(Future<Object?> run) async {
  final Object? result;
  try {
    result = await run;
  } on Object catch (error) {
    final info = extractInterruptInfo(error);
    if (info == null) fail('expected an interrupt error, got: $error');
    return info;
  }
  fail('expected an interrupt error, the run returned: $result');
}

/// Starts [run] under a context that can be interrupted, interrupts it
/// without grace as soon as a node sleeps at [sleep], and returns the
/// interrupt the run ends with.
///
/// Go:
/// ```go
/// canceledCtx, cancel := WithGraphInterrupt(ctx)
/// go func() {
///     time.Sleep(100 * time.Millisecond)
///     cancel(WithGraphInterruptTimeout(0))
/// }()
/// _, err = r.Invoke(canceledCtx, …)
/// info, ok := ExtractInterruptInfo(err)
/// ```
Future<GraphInterruptInfo> _interruptWhileAsleep(
  _Sleep sleep,
  Future<Object?> Function(RunContext canceledCtx) run,
) async {
  final (canceledCtx, cancel) = _ctx.withGraphInterrupt();
  final interrupted = _interruptOf(run(canceledCtx));
  // A run that ends before a node sleeps fails the test here.
  await Future.any<void>([sleep.started, interrupted]);
  cancel.interrupt(timeout: Duration.zero);
  return interrupted;
}

/// Runs [body] on a fake clock and lets a minute of it pass, in which [body]
/// has to finish. What [body] throws fails the test.
void _onFakeClock(Future<void> Function() body) {
  fakeAsync((async) {
    var finished = false;
    Object? error;
    StackTrace? stackTrace;
    body().then(
      (_) => finished = true,
      onError: (Object e, StackTrace s) {
        error = e;
        stackTrace = s;
      },
    );
    async.elapse(const Duration(minutes: 1));
    final failure = error;
    if (failure != null) Error.throwWithStackTrace(failure, stackTrace!);
    expect(
      finished,
      isTrue,
      reason: 'the test body did not finish within a minute of fake time',
    );
  });
}

/// A context whose runs are interrupted [after] that much (fake) time, with
/// the grace period [timeout]. Call it on the fake clock.
///
/// Go:
/// ```go
/// canceledCtx, cancel := WithGraphInterrupt(ctx)
/// go func() {
///     time.Sleep(after)
///     cancel(WithGraphInterruptTimeout(timeout))
/// }()
/// ```
RunContext _interruptAfter(Duration after, {Duration? timeout}) {
  final (canceledCtx, cancel) = _ctx.withGraphInterrupt();
  Timer(after, () => cancel.interrupt(timeout: timeout));
  return canceledCtx;
}

/// Go `time.Sleep(3 * time.Second)` in a node, on the fake clock.
Future<void> _sleepThreeSeconds() =>
    Future<void>.delayed(const Duration(seconds: 3));

/// Go `require.ErrorContains(t, err, text)`.
Matcher _throwsErrorContaining(String text) => throwsA(
      predicate<Object>(
        (error) => error.toString().contains(text),
        'an error that says "$text"',
      ),
    );

void main() {
  setUpAll(() {
    TypeRegistry.registerName<_PersistRerunInputState>(
      'eino_checkpoint_cancel_test.persist_rerun_input_state',
      fromJson: _PersistRerunInputState.fromJson,
      toJson: (state) => state.toJson(),
    );
  });

  group('TestCancelInterrupt', () {
    // Go runs the phases of a graph one after the other in one test, each
    // with a checkpoint id of its own. Here every phase is a test, so that
    // one failure does not hide the others; the phases of a graph share the
    // compiled graph and its store, as in Go.
    const halfASecond = Duration(milliseconds: 500);
    const anHour = Duration(hours: 1);

    Future<Runnable<String, String>> compileChain({required bool dag}) {
      final g = Graph<String, String>()
        ..addLambdaNode(
          '1',
          Lambda<String, String>.invokable((ctx, input) async {
            await _sleepThreeSeconds();
            return '${input}1';
          }),
        )
        ..addLambdaNode(
          '2',
          Lambda<String, String>.invokable((ctx, input) => '${input}2'),
        )
        ..addEdge(Graph.start, '1')
        ..addEdge('1', '2')
        ..addEdge('2', Graph.end);
      return g.compile(
        _ctx,
        options: GraphCompileOptions(
          nodeTriggerMode: dag ? NodeTriggerMode.allPredecessor : null,
          checkpointStore: InMemoryCheckpointStore(),
        ),
      );
    }

    for (final dag in [false, true]) {
      group(dag ? 'dag' : 'pregel', () {
        late final Runnable<String, String> r;
        setUpAll(() async => r = await compileChain(dag: dag));

        test('interrupt after nodes', () {
          _onFakeClock(() async {
            final canceledCtx = _interruptAfter(halfASecond, timeout: anHour);
            final info = await _interruptOf(
              r.invoke(
                canceledCtx,
                'input',
                options: [CallOption.checkpointId('1')],
              ),
            );
            expect(info.afterNodes, ['1']);
            final result = await r.invoke(
              _ctx,
              'input',
              options: [CallOption.checkpointId('1')],
            );
            expect(result, 'input12');
          });
        });

        test('infinite timeout', () {
          _onFakeClock(() async {
            final canceledCtx = _interruptAfter(halfASecond);
            final info = await _interruptOf(
              r.invoke(
                canceledCtx,
                'input',
                options: [CallOption.checkpointId('2')],
              ),
            );
            expect(info.afterNodes, ['1']);
            final result = await r.invoke(
              _ctx,
              'input',
              options: [CallOption.checkpointId('2')],
            );
            expect(result, 'input12');
          });
        });

        // The input of a node that is cut off is kept: the node runs again
        // with it.
        test('interrupt rerun nodes', () {
          _onFakeClock(() async {
            final canceledCtx = _interruptAfter(
              dag ? const Duration(milliseconds: 300) : halfASecond,
              timeout: Duration.zero,
            );
            final info = await _interruptOf(
              r.invoke(
                canceledCtx,
                'input',
                options: [CallOption.checkpointId('3')],
              ),
            );
            expect(info.rerunNodes, ['1']);
            final result = await r.invoke(
              _ctx,
              'input',
              options: [CallOption.checkpointId('3')],
            );
            expect(result, 'input12');
          });
        });
      });
    }

    group('dag multi canceled nodes', () {
      late final Runnable<String, Map<String, Object?>> rr;
      setUpAll(() async {
        final gg = Graph<String, Map<String, Object?>>()
          ..addLambdaNode(
            '1',
            Lambda<String, String>.invokable((ctx, input) => '${input}1'),
          )
          ..addLambdaNode(
            '2',
            Lambda<String, String>.invokable((ctx, input) async {
              await _sleepThreeSeconds();
              return '${input}2';
            }),
            options: const NodeOptions(outputKey: '2'),
          )
          ..addLambdaNode(
            '3',
            Lambda<String, String>.invokable((ctx, input) async {
              await _sleepThreeSeconds();
              return '${input}3';
            }),
            options: const NodeOptions(outputKey: '3'),
          )
          ..addLambdaNode(
            '4',
            Lambda<Map<String, Object?>, Map<String, Object?>>.invokable(
              (ctx, input) => input,
            ),
          )
          ..addEdge(Graph.start, '1')
          ..addEdge('1', '2')
          ..addEdge('1', '3')
          ..addEdge('2', '4')
          ..addEdge('3', '4')
          ..addEdge('4', Graph.end);
        rr = await gg.compile(
          _ctx,
          options: GraphCompileOptions(
            nodeTriggerMode: NodeTriggerMode.allPredecessor,
            checkpointStore: InMemoryCheckpointStore(),
          ),
        );
      });

      test('interrupt after nodes', () {
        _onFakeClock(() async {
          final canceledCtx = _interruptAfter(halfASecond, timeout: anHour);
          final info = await _interruptOf(
            rr.invoke(
              canceledCtx,
              'input',
              options: [CallOption.checkpointId('1')],
            ),
          );
          expect(info.afterNodes, hasLength(2));
          final result = await rr.invoke(
            _ctx,
            'input',
            options: [CallOption.checkpointId('1')],
          );
          expect(result, {'2': 'input12', '3': 'input13'});
        });
      });

      test('interrupt rerun nodes', () {
        _onFakeClock(() async {
          final canceledCtx =
              _interruptAfter(halfASecond, timeout: Duration.zero);
          final info = await _interruptOf(
            rr.invoke(
              canceledCtx,
              'input',
              options: [CallOption.checkpointId('2')],
            ),
          );
          expect(info.rerunNodes, hasLength(2));
          final result = await rr.invoke(
            _ctx,
            'input',
            options: [CallOption.checkpointId('2')],
          );
          expect(result, {'2': 'input12', '3': 'input13'});
        });
      });
    });
  });

  test('TestPersistRerunInputNonStream', () async {
    final store = InMemoryCheckpointStore();
    var receivedInput = '';
    var callCount = 0;
    final sleep = _Sleep();

    final g = Graph<String, String>()
      ..addLambdaNode(
        '1',
        Lambda<String, String>.invokable((ctx, input) async {
          callCount++;
          final currentCount = callCount;
          receivedInput = input;

          if (currentCount == 1) await sleep();
          return '${input}_processed';
        }),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);
    final r = await g.compile(
      _ctx,
      options: GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
        checkpointStore: store,
      ),
    );

    final info = await _interruptWhileAsleep(
      sleep,
      (canceledCtx) => r.invoke(
        canceledCtx,
        'test_input',
        options: [CallOption.checkpointId('cp1')],
      ),
    );
    expect(info.rerunNodes, ['1']);
    expect(receivedInput, 'test_input');

    final result =
        await r.invoke(_ctx, '', options: [CallOption.checkpointId('cp1')]);
    expect(result, 'test_input_processed');
    expect(receivedInput, 'test_input');
    expect(callCount, 2);

    sleep.wake();
    await pumpEventQueue();
  });

  test('TestPersistRerunInputStream', () async {
    final store = InMemoryCheckpointStore();
    var receivedInput = '';
    var callCount = 0;
    final sleep = _Sleep();

    final g = Graph<String, String>()
      ..addLambdaNode(
        '1',
        Lambda<String, String>.transformable((ctx, input) async {
          callCount++;
          final currentCount = callCount;

          final sb = StringBuffer();
          while (true) {
            try {
              sb.write(await input.recv());
            } on StreamEOFException {
              break;
            }
          }
          receivedInput = sb.toString();

          if (currentCount == 1) await sleep();
          return StreamReader.fromIterable(['${sb}_processed']);
        }),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);
    final r = await g.compile(
      _ctx,
      options: GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
        checkpointStore: store,
      ),
    );

    final inputStream =
        StreamReader.fromIterable(['chunk1', 'chunk2', 'chunk3']);
    final info = await _interruptWhileAsleep(
      sleep,
      (canceledCtx) => r.transform(
        canceledCtx,
        inputStream,
        options: [CallOption.checkpointId('cp1')],
      ),
    );
    expect(info.rerunNodes, ['1']);
    expect(receivedInput, 'chunk1chunk2chunk3');

    final emptyInputStream = StreamReader<String>.fromIterable(const []);
    final resultStream = await r.transform(
      _ctx,
      emptyInputStream,
      options: [CallOption.checkpointId('cp1')],
    );
    final result = (await resultStream.collectAll()).join();

    expect(result, 'chunk1chunk2chunk3_processed');
    expect(receivedInput, 'chunk1chunk2chunk3');
    expect(callCount, 2);

    sleep.wake();
    await pumpEventQueue();
  });

  test('TestPersistRerunInputWithPreHandler', () async {
    final store = InMemoryCheckpointStore();
    var receivedInput = '';
    var callCount = 0;
    final sleep = _Sleep();

    final g = Graph<String, String>(
      localState: LocalState.of<_PersistRerunInputState>(
        (ctx) => _PersistRerunInputState('prefix_'),
      ),
    )
      ..addLambdaNode(
        '1',
        Lambda<String, String>.invokable((ctx, input) async {
          callCount++;
          final currentCount = callCount;
          receivedInput = input;

          if (currentCount == 1) await sleep();
          return '${input}_processed';
        }),
        options: NodeOptions(
          statePreHandler: StateHandler.pre<String, _PersistRerunInputState>(
            (ctx, input, state) => state.prefix + input,
          ),
        ),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);
    final r = await g.compile(
      _ctx,
      options: GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
        checkpointStore: store,
      ),
    );

    final info = await _interruptWhileAsleep(
      sleep,
      (canceledCtx) => r.invoke(
        canceledCtx,
        'test_input',
        options: [CallOption.checkpointId('cp1')],
      ),
    );
    expect(info.rerunNodes, ['1']);
    expect(receivedInput, 'prefix_test_input');

    final result =
        await r.invoke(_ctx, '', options: [CallOption.checkpointId('cp1')]);
    expect(result, 'prefix_test_input_processed');
    expect(receivedInput, 'prefix_test_input');
    expect(callCount, 2);

    sleep.wake();
    await pumpEventQueue();
  });

  // Intended deviation 1 does not show here: `String` has an empty value, so
  // the node that interrupted itself runs again with '' as in Go.
  test('TestPersistRerunInputBackwardCompatibility', () async {
    final store = InMemoryCheckpointStore();
    var receivedInput = '';
    var callCount = 0;

    final g = Graph<String, String>()
      ..addLambdaNode(
        '1',
        Lambda<String, String>.invokable((ctx, input) {
          callCount++;
          receivedInput = input;
          if (input.isNotEmpty) {
            throw statefulInterrupt(ctx, 'interrupt', input);
          }

          final restoredInput = getInterruptState<String>(ctx).state ?? '';
          return '${restoredInput}_processed';
        }),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);
    final r = await g.compile(
      _ctx,
      options: GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
        checkpointStore: store,
      ),
    );

    final info = await _interruptOf(
      r.invoke(_ctx, 'test_input', options: [CallOption.checkpointId('cp1')]),
    );
    expect(info.rerunNodes, ['1']);
    expect(receivedInput, 'test_input');

    final result =
        await r.invoke(_ctx, '', options: [CallOption.checkpointId('cp1')]);
    expect(result, 'test_input_processed');
    expect(receivedInput, '');
    expect(callCount, 2);
  });

  test('TestPersistRerunInputSubGraph', () async {
    final store = InMemoryCheckpointStore();
    var receivedInput = '';
    var callCount = 0;
    final sleep = _Sleep();

    final subG = Graph<String, String>()
      ..addLambdaNode(
        'sub1',
        Lambda<String, String>.invokable((ctx, input) async {
          callCount++;
          final currentCount = callCount;
          receivedInput = input;

          if (currentCount == 1) await sleep();
          return '${input}_sub_processed';
        }),
      )
      ..addEdge(Graph.start, 'sub1')
      ..addEdge('sub1', Graph.end);

    final g = Graph<String, String>()
      ..addLambdaNode(
        '1',
        Lambda<String, String>.invokable((ctx, input) => '${input}_main'),
      )
      ..addGraphNode('2', subG)
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge('2', Graph.end);
    final r = await g.compile(
      _ctx,
      options: GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
        checkpointStore: store,
      ),
    );

    final info = await _interruptWhileAsleep(
      sleep,
      (canceledCtx) => r.invoke(
        canceledCtx,
        'test',
        options: [CallOption.checkpointId('cp1')],
      ),
    );
    if (info.subGraphs.isNotEmpty) {
      expect(info.subGraphs, contains('2'));
      final subInfo = info.subGraphs['2']!;
      expect(subInfo.rerunNodes, ['sub1']);
    } else {
      expect(info.rerunNodes, ['2']);
    }
    expect(receivedInput, 'test_main');

    final result =
        await r.invoke(_ctx, '', options: [CallOption.checkpointId('cp1')]);
    expect(result, 'test_main_sub_processed');
    expect(receivedInput, 'test_main');
    expect(callCount, 2);

    sleep.wake();
    await pumpEventQueue();
  });

  test('TestStreamingSubGraphReinterruptPreservesNestedCheckpoint', () async {
    final store = InMemoryCheckpointStore();
    var sideEffectCount = 0;

    final interruptingNode = Lambda<String, String>.streamable((ctx, input) {
      final previous = getInterruptState<String>(ctx);
      if (!previous.wasInterrupted) {
        throw statefulInterrupt(
          ctx,
          'first approval',
          'awaiting_first_approval',
        );
      }
      if (!previous.hasState) throw Exception('missing interrupt state');

      switch (previous.state) {
        case 'awaiting_first_approval':
          final (reader, writer) = pipe<String>(capacity: 1);
          // Go: a goroutine sends the interrupt as the error of the stream
          // and closes it.
          scheduleMicrotask(() async {
            writer.sendError(
              statefulInterrupt(
                ctx,
                'second approval',
                'awaiting_second_approval',
              ),
            );
            await writer.close();
          });
          return reader;
        case 'awaiting_second_approval':
          sideEffectCount++;
          return StreamReader.fromIterable(['done']);
        default:
          throw Exception('unexpected interrupt state "${previous.state}"');
      }
    });

    final inner = Graph<String, String>()
      ..addLambdaNode('ToolNode', interruptingNode)
      ..addLambdaNode(
        'ConsumeToolOutput',
        Lambda<String, String>.collectable(
          (ctx, input) => concatStreamReader(input),
        ),
      )
      ..addEdge(Graph.start, 'ToolNode')
      ..addEdge('ToolNode', 'ConsumeToolOutput')
      ..addEdge('ConsumeToolOutput', Graph.end);

    final outer = Graph<String, String>()
      ..addGraphNode('node_1', inner)
      ..addEdge(Graph.start, 'node_1')
      ..addEdge('node_1', Graph.end);

    final runnable = await outer.compile(
      _ctx,
      options: GraphCompileOptions(checkpointStore: store),
    );
    final options = [CallOption.checkpointId('stream-reinterrupt')];

    var info =
        await _interruptOf(runnable.stream(_ctx, 'input', options: options));
    expect(info.subGraphs, contains('node_1'));
    final firstId = info.interruptContexts[0].id;

    var resumeCtx = _ctx.resumeWithData(firstId, 'approved_1');
    info = await _interruptOf(runnable.stream(resumeCtx, '', options: options));
    expect(info.subGraphs, contains('node_1'));
    expect(info.rerunNodes, isNot(contains('node_1')));
    expect(info.subGraphs['node_1']!.rerunNodes, contains('ToolNode'));
    final secondId = info.interruptContexts[0].id;

    resumeCtx = _ctx.resumeWithData(secondId, 'approved_2');
    final output = await runnable.stream(resumeCtx, '', options: options);
    final result = await concatStreamReader(output);
    expect(result, 'done');
    expect(sideEffectCount, 1);
  });

  test('TestCheckpointConvertsPendingStartStream', () async {
    final graph = Graph<Map<String, Object?>, Map<String, Object?>>()
      ..addLambdaNode(
        'interrupt',
        Lambda<Map<String, Object?>, Map<String, Object?>>.invokable(
          (ctx, _) {
            final interrupted = getInterruptState<String>(ctx).wasInterrupted;
            if (interrupted) return {'right': 'done'};
            throw statefulInterrupt(ctx, 'pause', 'state');
          },
        ),
      )
      ..addLambdaNode(
        'join',
        Lambda<Map<String, Object?>, Map<String, Object?>>.invokable(
          (ctx, input) => input,
        ),
      )
      ..addEdge(Graph.start, 'interrupt')
      ..addEdge(Graph.start, 'join')
      ..addEdge('interrupt', 'join')
      ..addEdge('join', Graph.end);

    final runnable = await graph.compile(
      _ctx,
      options: GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
        checkpointStore: InMemoryCheckpointStore(),
      ),
    );
    final options = [CallOption.checkpointId('pending-start')];

    // Go `require.NotPanics`: a Dart run that broke down would throw
    // something that is no interrupt, which `_interruptOf` reports.
    await _interruptOf(
      runnable.stream(_ctx, {'left': 'input'}, options: options),
    );

    // Go passes a nil map; the run goes on from the checkpoint and does not
    // read its input.
    final output = await runnable.stream(_ctx, {}, options: options);
    final result = await concatStreamReader(output);
    expect(result, {'left': 'input', 'right': 'done'});
  });

  // Go's `convert` and `restore` work on one map of values. Their Dart ports
  // are private to `CheckPointer`; the values are handed to them as the
  // inputs of a checkpoint.
  group('TestCheckpointConversionValidation', () {
    CheckPointer pointerFor(Map<String, TypeRef<Object?>?> inputTypes) =>
        CheckPointer(inputTypes: inputTypes, outputTypes: const {});

    test('non-stream conversion is a no-op', () async {
      final pointer = pointerFor(const {});
      final empty = GraphCheckpoint();
      await pointer.convertCheckpoint(empty, null, isStream: false);
      pointer.restoreCheckpoint(empty, isStream: false);

      // Nor is a value looked at that the conversion of streams refuses.
      final checkpoint = GraphCheckpoint(inputs: {'node': 'input'});
      await pointer.convertCheckpoint(checkpoint, null, isStream: false);
      pointer.restoreCheckpoint(checkpoint, isStream: false);
      expect(checkpoint.inputs, {'node': 'input'});
    });

    test('unregistered node', () async {
      final pointer = pointerFor(const {});
      await expectLater(
        pointer.convertCheckpoint(
          GraphCheckpoint(inputs: {'node': 'input'}),
          null,
          isStream: true,
        ),
        _throwsErrorContaining('node[node] have not been registered'),
      );
      expect(
        () => pointer.restoreCheckpoint(
          GraphCheckpoint(inputs: {'node': 'input'}),
          isStream: true,
        ),
        _throwsErrorContaining('node[node] have not been registered'),
      );
    });

    test('missing converter', () async {
      // Go: `streamConvertPair{}`, a pair without functions.
      final pointer = pointerFor(const {'node': null});
      final stream = StreamReader.fromIterable(['input']);
      addTearDown(stream.close);
      await expectLater(
        pointer.convertCheckpoint(
          GraphCheckpoint(inputs: {'node': stream}),
          null,
          isStream: true,
        ),
        _throwsErrorContaining('node[node] has no stream converter'),
      );
      expect(
        () => pointer.restoreCheckpoint(
          GraphCheckpoint(inputs: {'node': 'input'}),
          isStream: true,
        ),
        _throwsErrorContaining('node[node] has no stream converter'),
      );
    });

    test('invalid value', () async {
      // Go: `defaultStreamConvertPair[string]()`.
      final pointer = pointerFor(const {'node': TypeRef<String>()});
      await expectLater(
        pointer.convertCheckpoint(
          GraphCheckpoint(inputs: {'node': 'input'}),
          null,
          isStream: true,
        ),
        _throwsErrorContaining("value of [node] isn't stream"),
      );
      expect(
        () => pointer.restoreCheckpoint(
          GraphCheckpoint(inputs: {'node': 1}),
          isStream: true,
        ),
        _throwsErrorContaining('cannot convert value[int]'),
      );
    });
  });

  test('TestCheckpointStreamConversionIgnoresOnlyRecordedInterrupt', () async {
    final recordedErr = statefulInterrupt(_ctx, 'recorded', 'state');
    final recordedSignal =
        ThreepioException.findCause<AddressedInterruptSignal>(recordedErr)!;
    final (id2Addr, id2State) = signalToPersistenceMaps(recordedSignal);

    Future<(GraphCheckpoint, CheckPointer)> newCheckpoint(
      Object streamErr,
    ) async {
      final (reader, writer) = pipe<String>(capacity: 2);
      writer
        ..send('partial')
        ..sendError(streamErr);
      await writer.close();
      return (
        GraphCheckpoint(
          inputs: {'node': reader},
          interruptId2Address: id2Addr,
          interruptId2State: id2State,
        ),
        CheckPointer(
          inputTypes: const {'node': TypeRef<String>()},
          outputTypes: const {},
        ),
      );
    }

    var (cp, pointer) = await newCheckpoint(recordedErr);
    await pointer.convertCheckpoint(cp, recordedSignal, isStream: true);
    expect(cp.inputs['node'], 'partial');

    (cp, pointer) = await newCheckpoint(
      SubGraphInterrupt(
        info: GraphInterruptInfo(),
        checkpoint: GraphCheckpoint(),
        signal: recordedSignal,
      ),
    );
    await pointer.convertCheckpoint(cp, recordedSignal, isStream: true);
    expect(cp.inputs['node'], 'partial');

    // Go `core.ErrStreamCanceled`.
    const streamCanceled = StreamCanceledException();
    (cp, pointer) = await newCheckpoint(streamCanceled);
    await expectLater(
      pointer.convertCheckpoint(cp, recordedSignal, isStream: true),
      _throwsErrorContaining(streamCanceled.message),
    );

    (cp, pointer) = await newCheckpoint(Exception('ordinary stream failure'));
    await expectLater(
      pointer.convertCheckpoint(cp, recordedSignal, isStream: true),
      _throwsErrorContaining('ordinary stream failure'),
    );
  });

  test('TestAttack_CheckpointStreamConversionRejectsUnrecordedInterrupt',
      () async {
    final recordedErr = statefulInterrupt(_ctx, 'recorded', 'recorded-state');
    final recordedSignal =
        ThreepioException.findCause<AddressedInterruptSignal>(recordedErr)!;
    final (id2Addr, id2State) = signalToPersistenceMaps(recordedSignal);

    final unrecordedErr =
        statefulInterrupt(_ctx, 'unrecorded', 'unrecorded-state');
    final (reader, writer) = pipe<String>(capacity: 1);
    writer.sendError(unrecordedErr);
    await writer.close();
    final cp = GraphCheckpoint(
      inputs: {'node': reader},
      interruptId2Address: id2Addr,
      interruptId2State: id2State,
    );
    final pointer = CheckPointer(
      inputTypes: const {'node': TypeRef<String>()},
      outputTypes: const {},
    );

    await expectLater(
      pointer.convertCheckpoint(cp, recordedSignal, isStream: true),
      // Go: `IsInterruptRerunError(err)`.
      throwsA(predicate<Object>(isInterrupt, 'an interrupt')),
    );
  });

  test(
      'TestAttack_CheckpointStreamConversionRejectsUnrecordedStreamCancellation',
      () async {
    const streamCanceled = StreamCanceledException();
    final (reader, writer) = pipe<String>(capacity: 1);
    writer.sendError(streamCanceled);
    await writer.close();
    final cp = GraphCheckpoint(inputs: {'node': reader});
    final pointer = CheckPointer(
      inputTypes: const {'node': TypeRef<String>()},
      outputTypes: const {},
    );

    await expectLater(
      pointer.convertCheckpoint(cp, null, isStream: true),
      _throwsErrorContaining(streamCanceled.message),
    );
  });

  test('TestCheckpointToolStreamCancellationRerunsProducerOnce', () async {
    final input = Message.assistant(
      '',
      toolCalls: const [
        ToolCall(
          id: 'call-stream',
          function: FunctionCall(name: 'wait', arguments: '{"input":"work"}'),
        ),
      ],
    );
    // Go: a `toolsInterruptAndRerunState`. Its Dart port is private to the
    // tools node; the conversion only carries the state along, so a map with
    // the same content stands in for it.
    final state = <String, Object?>{
      'input': input,
      'executed_tools': {'call-stable': 'stable tool'},
      'rerun_tools': ['call-stream'],
    };
    final toolSignal = AddressedInterruptSignal(
      id: 'tool-stream',
      address: Address(const [
        AddressSegment(type: AddressSegmentType.node, id: 'tools'),
      ]),
      isRootCause: true,
      state: InterruptState(state: state),
    );
    final rootSignal =
        AddressedInterruptSignal(id: 'root', address: const Address.empty());
    final (id2Addr, id2State) = signalToPersistenceMaps(rootSignal);

    final inputs = <String, Object?>{};
    final inputTypes = <String, TypeRef<Object?>?>{};
    for (final consumer in ['consumer-a', 'consumer-b']) {
      final (reader, writer) = pipe<String>(capacity: 2);
      writer
        ..send('partial')
        // Go: `&toolStreamCheckpointError{…}`.
        ..sendError(
          ToolStreamCheckpointSignal(
            nodeKey: 'tools',
            input: input,
            signal: toolSignal,
          ),
        );
      await writer.close();
      inputs[consumer] = reader;
      inputTypes[consumer] = const TypeRef<String>();
    }
    final cp = GraphCheckpoint(
      inputs: inputs,
      rerunNodes: ['consumer-a', 'consumer-b'],
      interruptId2Address: id2Addr,
      interruptId2State: id2State,
    );
    final pointer =
        CheckPointer(inputTypes: inputTypes, outputTypes: const {});

    await pointer.convertCheckpoint(cp, rootSignal, isStream: true);
    expect(cp.rerunNodes, ['tools']);
    expect(cp.inputs, {'tools': input});
    expect(rootSignal.subs, hasLength(1));
    expect(rootSignal.subs[0], same(toolSignal));
    expect(cp.interruptId2Address[toolSignal.id], toolSignal.address);
    expect(cp.interruptId2State[toolSignal.id]!.state, same(state));
  });

  // Go calls the unexported `runner.interruptOriginNodeKey` with a task and
  // an address. Its Dart port (`GraphRunner._interruptOriginNodeKey`) is
  // private, so the cases run through a graph: the node `node_1` of the graph
  // `root` ends with an interrupt that was raised at the address of the case,
  // and the node the graph lists to run again is what the function answered.
  // The graph also has a node `ToolNode`, as the runner of the Go test.
  group('TestAttack_InterruptOriginUsesCurrentGraphBoundary', () {
    final rootCtx =
        _ctx.appendAddressSegment(AddressSegmentType.runnable, 'root');

    /// Runs the graph whose `node_1` interrupts at the address [raisedAt]
    /// gives for the context of its task.
    Future<GraphInterruptInfo> interruptRaisedAt(
      RunContext Function(RunContext taskCtx) raisedAt,
    ) async {
      final g = Graph<String, String>()
        ..addLambdaNode(
          'node_1',
          Lambda<String, String>.invokable((ctx, input) {
            expect(ctx.currentAddress.toString(), 'runnable:root;node:node_1');
            throw interrupt(raisedAt(ctx), 'origin');
          }),
        )
        ..addLambdaNode(
          'ToolNode',
          Lambda<String, String>.invokable((ctx, input) => input),
        )
        ..addEdge(Graph.start, 'node_1')
        ..addEdge('node_1', 'ToolNode')
        ..addEdge('ToolNode', Graph.end);
      final r = await g.compile(
        _ctx,
        options: const GraphCompileOptions(graphName: 'root'),
      );
      return _interruptOf(r.invoke(_ctx, 'input'));
    }

    test('selects node at current graph boundary', () async {
      final info = await interruptRaisedAt(
        (taskCtx) => taskCtx
            .appendAddressSegment(AddressSegmentType.node, 'ToolNode')
            .appendAddressSegment(AddressSegmentType.tool, 'permission'),
      );
      expect(
        info.interruptContexts.single.address.toString(),
        'runnable:root;node:node_1;node:ToolNode;tool:permission',
      );
      expect(info.rerunNodes, ['node_1']);
    });

    test('falls back when address belongs to another graph', () async {
      final info = await interruptRaisedAt(
        (taskCtx) => _ctx
            .appendAddressSegment(AddressSegmentType.runnable, 'other')
            .appendAddressSegment(AddressSegmentType.node, 'ToolNode'),
      );
      expect(
        info.interruptContexts.single.address.toString(),
        'runnable:other;node:ToolNode',
      );
      expect(info.rerunNodes, ['node_1']);
    });

    // Go: a task whose context has no address, and a nil interrupt address.
    // A task of a Dart graph always has an address; the interrupt without an
    // address is the half of the case that can happen.
    test('falls back when task has no execution address', () async {
      final info = await interruptRaisedAt((taskCtx) => _ctx);
      expect(info.interruptContexts.single.address.isEmpty, isTrue);
      expect(info.rerunNodes, ['node_1']);
    });

    test('falls back when addressed node is not in current graph', () async {
      final info = await interruptRaisedAt(
        (taskCtx) =>
            rootCtx.appendAddressSegment(AddressSegmentType.node, 'missing'),
      );
      expect(
        info.interruptContexts.single.address.toString(),
        'runnable:root;node:missing',
      );
      expect(info.rerunNodes, ['node_1']);
    });
  });

  test('TestAttack_FanOutLateInterruptIsDeduplicated', () async {
    final producer = Lambda<String, String>.streamable((ctx, _) async {
      final interruptErr = statefulInterrupt(ctx, 'approval', 'state');
      final (reader, writer) = pipe<String>(capacity: 1);
      writer.sendError(interruptErr);
      await writer.close();
      return reader;
    });
    Future<String> consumer(RunContext ctx, StreamReader<String> input) =>
        concatStreamReader(input);

    final graph = Graph<String, String>()
      ..addLambdaNode('ToolNode', producer)
      ..addLambdaNode(
        'consumer_a',
        Lambda<String, String>.collectable(consumer),
      )
      ..addLambdaNode(
        'consumer_b',
        Lambda<String, String>.collectable(consumer),
      )
      ..addEdge(Graph.start, 'ToolNode')
      ..addEdge('ToolNode', 'consumer_a')
      ..addEdge('ToolNode', 'consumer_b')
      ..addEdge('consumer_a', Graph.end)
      ..addEdge('consumer_b', Graph.end);

    final runnable = await graph.compile(
      _ctx,
      options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
    );
    final info = await _interruptOf(
      runnable.stream(
        _ctx,
        'input',
        options: [CallOption.checkpointId('fan-out-interrupt')],
      ),
    );
    expect(info.rerunNodes, ['ToolNode']);
    expect(info.interruptContexts, hasLength(1));
  });

  test('TestAttack_EmptyIDInterruptSignalsRemainDistinct', () {
    final first =
        AddressedInterruptSignal(id: '', address: const Address.empty());
    final second =
        AddressedInterruptSignal(id: '', address: const Address.empty());
    final tempInfo = InterruptTempInfo()
      ..appendSignal(first)
      ..appendSignal(second)
      ..appendSignal(first);

    expect(tempInfo.signals, [same(first), same(second)]);
  });

  test('TestRestoreRejectsInputlessSubGraphRerunCheckpoint', () async {
    const rejected = 'invalid checkpoint: subgraph node "nested" is marked for '
        'rerun without a nested checkpoint or persisted input';
    // Go: `(&serialization.InternalSerializer{}).Marshal(&checkpoint{…})`.
    const serializer = JsonCheckpointSerializer();
    final store = InMemoryCheckpointStore();
    var childExecuted = false;

    final child = Graph<String, String>()
      ..addLambdaNode(
        'child',
        Lambda<String, String>.invokable((ctx, input) {
          childExecuted = true;
          return input;
        }),
      )
      ..addEdge(Graph.start, 'child')
      ..addEdge('child', Graph.end);

    final parent = Graph<String, String>()
      ..addGraphNode('nested', child)
      ..addEdge(Graph.start, 'nested')
      ..addEdge('nested', Graph.end);

    final runnable = await parent.compile(
      _ctx,
      options: GraphCompileOptions(checkpointStore: store),
    );

    var data = serializer.serialize(
      GraphCheckpoint(inputs: {}, rerunNodes: ['nested'], subGraphs: {}),
    );
    await store.set('malformed', data);

    await expectLater(
      runnable.invoke(
        _ctx,
        '',
        options: [CallOption.checkpointId('malformed')],
      ),
      _throwsErrorContaining(rejected),
    );
    expect(childExecuted, isFalse);

    final nestedStore = InMemoryCheckpointStore();
    final middle = Graph<String, String>()
      ..addGraphNode('nested', child)
      ..addEdge(Graph.start, 'nested')
      ..addEdge('nested', Graph.end);

    final root = Graph<String, String>()
      ..addGraphNode('middle', middle)
      ..addEdge(Graph.start, 'middle')
      ..addEdge('middle', Graph.end);

    final nestedRunnable = await root.compile(
      _ctx,
      options: GraphCompileOptions(checkpointStore: nestedStore),
    );
    data = serializer.serialize(
      GraphCheckpoint(
        inputs: {},
        rerunNodes: ['middle'],
        subGraphs: {
          'middle': GraphCheckpoint(
            inputs: {},
            rerunNodes: ['nested'],
            subGraphs: {},
          ),
        },
      ),
    );
    await nestedStore.set('nested-malformed', data);

    await expectLater(
      nestedRunnable.invoke(
        _ctx,
        '',
        options: [CallOption.checkpointId('nested-malformed')],
      ),
      _throwsErrorContaining(rejected),
    );
    expect(childExecuted, isFalse);
  });

  test('TestToolsNodeWithExternalGraphInterrupt', () async {
    final store = InMemoryCheckpointStore();
    var callCount = 0;
    final sleep = _Sleep();

    final longRunningToolInfo = ToolInfo.fromParams(
      name: 'long_running_tool',
      desc: 'A tool that takes a long time to run',
      params: const {
        'input': ParameterInfo(type: DataType.string, desc: 'input'),
      },
    );

    final longRunningTool = _CheckpointTestTool<_LongRunningToolInput, String>(
      longRunningToolInfo,
      _LongRunningToolInput.fromJson,
      (ctx, input) async {
        callCount++;
        final currentCount = callCount;

        if (currentCount == 1) await sleep();
        return 'result_${input.input}';
      },
    );

    final toolsNode =
        await ToolsNode.create(ToolsNodeConfig(tools: [longRunningTool]));

    final g = Graph<Message, List<Message>>()
      ..addToolsNode('tools', toolsNode)
      ..addEdge(Graph.start, 'tools')
      ..addEdge('tools', Graph.end);
    final r = await g.compile(
      _ctx,
      options: GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
        checkpointStore: store,
      ),
    );

    final inputMsg = Message.assistant(
      '',
      toolCalls: const [
        ToolCall(
          id: 'call_1',
          // The default, written out as in Go.
          // ignore: avoid_redundant_argument_values
          type: 'function',
          function: FunctionCall(
            name: 'long_running_tool',
            arguments: '{"input": "test"}',
          ),
        ),
      ],
    );

    final info = await _interruptWhileAsleep(
      sleep,
      (canceledCtx) => r.invoke(
        canceledCtx,
        inputMsg,
        options: [CallOption.checkpointId('cp1')],
      ),
    );
    expect(info.rerunNodes, ['tools']);

    // Go resumes with `&schema.Message{}`. The run goes on from the
    // checkpoint and does not read its input.
    final result = await r.invoke(
      _ctx,
      Message.user(''),
      options: [CallOption.checkpointId('cp1')],
    );
    expect(result, hasLength(1));
    expect(result[0].content, '"result_test"');
    expect(callCount, 2);

    sleep.wake();
    await pumpEventQueue();
  });
}
