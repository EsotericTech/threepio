// The public surface of interrupt, resume and checkpoints: the types and
// functions a caller and a component use, the checkpoint call options, the
// global compile callbacks, and what the libraries export.
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/compose.dart' as compose;
import 'package:threepio_core/io.dart' as io;
import 'package:threepio_core/legacy_graph.dart' as legacy;
import 'package:threepio_core/src/compose/interrupt.dart'
    show AddressedInterruptSignal, SubGraphInterrupt;
import 'package:threepio_core/threepio_core.dart';

final class _Failing implements CheckpointStore {
  _Failing({this.failGet = false, this.failSet = false});

  final bool failGet;
  final bool failSet;
  final Map<String, Uint8List> data = {};

  @override
  Future<Uint8List?> get(String key) async =>
      failGet ? throw StateError('store is down') : data[key];

  @override
  Future<void> set(String key, Uint8List value) async {
    if (failSet) throw StateError('store is full');
    data[key] = value;
  }
}

final class _Callback implements GraphCompileCallback {
  final List<String> names = [];

  @override
  void onFinish(RunContext ctx, GraphInfo info) => names.add(info.name);
}

final class _Foreign implements InterruptSignal {
  const _Foreign();
}

Lambda<String, String> _append(String suffix) =>
    Lambda<String, String>.invokable((ctx, input) => '$input$suffix');

Graph<String, String> _line(List<String> keys) {
  final graph = Graph<String, String>();
  var previous = Graph.start;
  for (final key in keys) {
    graph
      ..addLambdaNode(key, _append(key))
      ..addEdge(previous, key);
    previous = key;
  }
  return graph..addEdge(previous, Graph.end);
}

Future<GraphInterruptInfo> _interruptOf(Future<Object?> run) async {
  try {
    await run;
  } on GraphInterruptedException catch (interrupted) {
    return interrupted.info;
  }
  fail('expected an interrupt');
}

void main() {
  final ctx = RunContext.background();

  group('addresses', () {
    test('AddressSegmentType is an open set compared by name', () {
      expect(AddressSegmentType.node.name, 'node');
      expect(AddressSegmentType.tool.name, 'tool');
      expect(AddressSegmentType.runnable.name, 'runnable');
      expect(const AddressSegmentType('node'), AddressSegmentType.node);
      expect(
        const AddressSegmentType('node').hashCode,
        AddressSegmentType.node.hashCode,
      );
      expect(const AddressSegmentType('agent'), isNot(AddressSegmentType.node));
      expect('${const AddressSegmentType('agent')}', 'agent');
    });

    test('a segment and an address have a text form and a JSON form', () {
      const tool = AddressSegment(
        type: AddressSegmentType.tool,
        id: 'search',
        subId: 'call_1',
      );
      const node = AddressSegment(type: AddressSegmentType.node, id: 'tools');
      expect('$tool', 'tool:search:call_1');
      expect('$node', 'node:tools');
      expect(node.subId, isEmpty);
      expect(AddressSegment.fromJson(tool.toJson()), tool);
      expect(node.toJson(), {'type': 'node', 'id': 'tools'});
      expect(tool, isNot(node));
      expect(tool.hashCode, AddressSegment.fromJson(tool.toJson()).hashCode);

      final address = Address(const [node, tool]);
      expect('$address', 'node:tools;tool:search:call_1');
      expect(address.length, 2);
      expect(address.isEmpty, isFalse);
      expect(Address.fromJson(address.toJson()), address);
      expect(address.hashCode, Address.fromJson(address.toJson()).hashCode);
      expect(const Address.empty().isEmpty, isTrue);
      expect('${const Address.empty()}', '');
      expect(const Address.empty().append(node), Address(const [node]));
      expect(() => address.segments.add(node), throwsUnsupportedError);
    });

    test('isStrictPrefixOf: only an address that lies inside', () {
      const a = AddressSegment(type: AddressSegmentType.node, id: 'a');
      const b = AddressSegment(type: AddressSegmentType.node, id: 'b');
      final outer = Address(const [a]);
      expect(outer.isStrictPrefixOf(Address(const [a, b])), isTrue);
      expect(outer.isStrictPrefixOf(outer), isFalse);
      expect(outer.isStrictPrefixOf(Address(const [b, a])), isFalse);
      expect(const Address.empty().isStrictPrefixOf(outer), isTrue);
      expect(Address(const [a, b]).isStrictPrefixOf(outer), isFalse);
    });

    test('a context knows where it is', () {
      expect(ctx.currentAddress, const Address.empty());
      final inner = ctx
          .appendAddressSegment(AddressSegmentType.runnable, 'g')
          .appendAddressSegment(const AddressSegmentType('agent'), 'a');
      expect('${inner.currentAddress}', 'runnable:g;agent:a');
      // The original is untouched.
      expect(ctx.currentAddress.isEmpty, isTrue);
    });
  });

  group('interrupt, statefulInterrupt, compositeInterrupt', () {
    test('make a signal at the address of the context', () {
      final here = ctx.appendAddressSegment(AddressSegmentType.node, 'n');
      final plain = interrupt(here, 'info') as AddressedInterruptSignal;
      expect(plain, isA<InterruptSignal>());
      expect(plain.address, here.currentAddress);
      expect(plain.info, 'info');
      expect(plain.isRootCause, isTrue);
      expect(plain.state.state, isNull);
      expect(plain.subs, isEmpty);
      expect(plain.id, isNotEmpty);
      expect(plain.toString(), contains('Addr=node:n'));

      final stateful =
          statefulInterrupt(here, 'info', {'saved': 1}) as AddressedInterruptSignal;
      expect(stateful.state.state, {'saved': 1});
      expect(stateful.id, isNot(plain.id));
      expect(isInterrupt(plain), isTrue);
    });

    test('a composite interrupt holds the interrupts of its parts', () {
      final here = ctx.appendAddressSegment(AddressSegmentType.node, 'n');
      final part = interrupt(
        here.appendAddressSegment(AddressSegmentType.tool, 't'),
        'part',
      );
      final wrapped = ToolsNodeException('failed', cause: part);
      final composite =
          compositeInterrupt(here, 'whole', 'state', [wrapped]) as AddressedInterruptSignal;
      expect(composite.isRootCause, isFalse);
      expect(composite.info, 'whole');
      expect(composite.state.state, 'state');
      expect(composite.subs.single, same(part));
    });

    test('a composite interrupt without parts is a stateful interrupt', () {
      final signal =
          compositeInterrupt(ctx, 'i', 's', const []) as AddressedInterruptSignal;
      expect(signal.isRootCause, isTrue);
      expect(signal.state.state, 's');
    });

    test('a composite interrupt refuses what is not an interrupt', () {
      expect(
        () => compositeInterrupt(ctx, null, null, [StateError('no')]),
        throwsArgumentError,
      );
      expect(
        () => compositeInterrupt(ctx, null, null, [const _Foreign()]),
        throwsArgumentError,
      );
    });

    test('a composite interrupt takes the interrupt of a graph', () async {
      final inner = await (_line(['a', 'b'])).compile(
        ctx,
        options: const GraphCompileOptions(
          graphName: 'inner',
          interruptBeforeNodes: ['b'],
        ),
      );
      final here = ctx.appendAddressSegment(AddressSegmentType.node, 'outer');
      GraphInterruptedException? interrupted;
      try {
        await inner.invoke(here, 'x');
      } on GraphInterruptedException catch (error) {
        interrupted = error;
      }
      final composite = compositeInterrupt(here, null, null, [interrupted!])
          as AddressedInterruptSignal;
      expect(composite.subs.single.id, interrupted.interruptContexts.single.id);
      expect('${composite.subs.single.address}', 'node:outer;runnable:inner');
    });
  });

  group('GraphInterruptedException', () {
    test('is an interrupt signal and a threepio exception', () async {
      final runnable = await _line(['a', 'b']).compile(
        ctx,
        options: const GraphCompileOptions(interruptBeforeNodes: ['b']),
      );
      Object? caught;
      try {
        await runnable.invoke(ctx, 'x');
        // ignore: avoid_catches_without_on_clauses
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<GraphInterruptedException>());
      expect(caught, isA<InterruptSignal>());
      expect(caught, isA<ThreepioException>());
      expect(isInterrupt(caught), isTrue);
      final interrupted = caught! as GraphInterruptedException;
      expect(interrupted.interruptContexts, same(interrupted.info.interruptContexts));
      expect(interrupted.toString(), startsWith('GraphInterruptedException: '));
      expect(interrupted.message, contains('interrupt happened'));
      expect(interrupted.info.toString(), contains('beforeNodes: [b]'));
      expect(interrupted.interruptContexts.single.toString(), contains('InterruptCtx('));
    });

    test('extractInterruptInfo finds it, also as the cause of another error',
        () async {
      final runnable = await _line(['a', 'b']).compile(
        ctx,
        options: const GraphCompileOptions(interruptBeforeNodes: ['b']),
      );
      final info = await _interruptOf(runnable.invoke(ctx, 'x'));
      final interrupted = GraphInterruptedException(info);
      expect(extractInterruptInfo(interrupted), same(info));
      expect(
        extractInterruptInfo(ToolsNodeException('wrapped', cause: interrupted)),
        same(info),
      );
      expect(extractInterruptInfo(StateError('other')), isNull);
      expect(extractInterruptInfo(null), isNull);
      expect(extractInterruptInfo(interrupt(ctx, 'signal')), isNull);
    });

    test('the lists and maps of the info cannot be changed', () {
      final info = GraphInterruptInfo(beforeNodes: ['a']);
      expect(() => info.beforeNodes.add('b'), throwsUnsupportedError);
      expect(() => info.rerunNodesExtra['x'] = 1, throwsUnsupportedError);
      expect(() => info.subGraphs['x'] = info, throwsUnsupportedError);
      expect(info.afterNodes, isEmpty);
      expect(info.interruptContexts, isEmpty);
      expect(info.state, isNull);
    });
  });

  group('interrupts the engine did not make', () {
    test('leave the run as they are, and no checkpoint is written', () async {
      final store = InMemoryCheckpointStore();
      const signal = _Foreign();
      final graph = Graph<String, String>()
        ..addLambdaNode(
          'n',
          Lambda<String, String>.invokable((ctx, input) => throw signal),
        )
        ..addEdge(Graph.start, 'n')
        ..addEdge('n', Graph.end);
      final runnable = await graph.compile(
        ctx,
        options: GraphCompileOptions(checkpointStore: store),
      );
      await expectLater(
        runnable.invoke(ctx, 'x', options: [CallOption.checkpointId('id')]),
        throwsA(same(signal)),
      );
      expect(store.keys, isEmpty);
    });

    test('the interrupt of a graph that a node lets through is not wrapped',
        () async {
      final inner = await _line(['a', 'b']).compile(
        ctx,
        options: const GraphCompileOptions(interruptBeforeNodes: ['b']),
      );
      final outer = Graph<String, String>()
        ..addLambdaNode(
          'runs_inner',
          Lambda<String, String>.invokable((ctx, input) => inner.invoke(ctx, input)),
        )
        ..addEdge(Graph.start, 'runs_inner')
        ..addEdge('runs_inner', Graph.end);
      final runnable = await outer.compile(
        ctx,
        options: const GraphCompileOptions(graphName: 'outer'),
      );
      final info = await _interruptOf(runnable.invoke(ctx, 'x'));
      // It is the interrupt of the inner graph: the outer one has none.
      expect(info.beforeNodes, ['b']);
      expect(
        '${info.interruptContexts.single.address}',
        'runnable:outer;node:runs_inner;runnable:',
      );
    });
  });

  group('checkpoint call options', () {
    test('writeToCheckpointId: read one checkpoint, write another', () async {
      final store = InMemoryCheckpointStore();
      final runnable = await _line(['a', 'b', 'c']).compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: store,
          interruptBeforeNodes: const ['b', 'c'],
        ),
      );
      await _interruptOf(
        runnable.invoke(ctx, 'x', options: [CallOption.checkpointId('first')]),
      );
      expect(store.keys, ['first']);
      final firstBytes = await store.get('first');

      // Goes on from "first" and stops in front of c, into "second".
      final info = await _interruptOf(
        runnable.invoke(
          ctx,
          'ignored',
          options: [
            CallOption.checkpointId('first'),
            CallOption.writeToCheckpointId('second'),
          ],
        ),
      );
      expect(info.beforeNodes, ['c']);
      expect(store.keys, ['first', 'second']);
      expect(await store.get('first'), firstBytes);

      expect(
        await runnable.invoke(ctx, '', options: [CallOption.checkpointId('second')]),
        'xabc',
      );
      // "first" can be resumed again, it was not consumed.
      await _interruptOf(
        runnable.invoke(ctx, '', options: [CallOption.checkpointId('first')]),
      );
    });

    test('writeToCheckpointId alone stores without reading', () async {
      final store = InMemoryCheckpointStore();
      final runnable = await _line(['a', 'b']).compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: store,
          interruptBeforeNodes: const ['b'],
        ),
      );
      await _interruptOf(
        runnable.invoke(ctx, 'x', options: [CallOption.writeToCheckpointId('w')]),
      );
      expect(store.keys, ['w']);
    });

    test('forceNewRun starts over, wherever it is among the options', () async {
      final store = InMemoryCheckpointStore();
      final runnable = await _line(['a', 'b']).compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: store,
          interruptBeforeNodes: const ['b'],
        ),
      );
      await _interruptOf(
        runnable.invoke(ctx, 'one', options: [CallOption.checkpointId('id')]),
      );
      for (final options in [
        [CallOption.checkpointId('id'), CallOption.forceNewRun()],
        [CallOption.forceNewRun(), CallOption.checkpointId('id')],
      ]) {
        // A new run: it stops in front of b again instead of finishing.
        final info = await _interruptOf(
          runnable.invoke(ctx, 'two', options: options),
        );
        expect(info.beforeNodes, ['b']);
      }
      expect(
        await runnable.invoke(ctx, '', options: [CallOption.checkpointId('id')]),
        'twoab',
      );
    });

    test('a checkpoint id that has no checkpoint starts a new run', () async {
      final runnable = await _line(['a']).compile(
        ctx,
        options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
      );
      expect(
        await runnable.invoke(ctx, 'x', options: [CallOption.checkpointId('new')]),
        'xa',
      );
    });

    test('a store that fails to read fails the run', () async {
      final runnable = await _line(['a']).compile(
        ctx,
        options: GraphCompileOptions(checkpointStore: _Failing(failGet: true)),
      );
      await expectLater(
        runnable.invoke(ctx, 'x', options: [CallOption.checkpointId('id')]),
        throwsA(
          isA<GraphRunException>()
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('load checkpoint from store fail'),
                  contains('store is down'),
                ),
              )
              .having((e) => e.cause, 'cause', isStateError),
        ),
      );
    });

    test('a store that fails to write fails the run instead of interrupting',
        () async {
      final runnable = await _line(['a', 'b']).compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: _Failing(failSet: true),
          interruptBeforeNodes: const ['b'],
        ),
      );
      await expectLater(
        runnable.invoke(ctx, 'x', options: [CallOption.checkpointId('id')]),
        throwsA(
          isA<GraphRunException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('failed to set checkpoint'),
              contains('store is full'),
              contains('checkPointID: id'),
            ),
          ),
        ),
      );
    });

    test('bytes that are not a checkpoint fail the run', () async {
      final store = InMemoryCheckpointStore();
      await store.set('id', Uint8List.fromList('"just text"'.codeUnits));
      final runnable = await _line(['a']).compile(
        ctx,
        options: GraphCompileOptions(checkpointStore: store),
      );
      await expectLater(
        runnable.invoke(ctx, 'x', options: [CallOption.checkpointId('id')]),
        throwsA(
          isA<GraphRunException>().having(
            (e) => e.message,
            'message',
            contains('load checkpoint from store fail'),
          ),
        ),
      );
    });

    test('the state modifier is called for nested graphs with their path',
        () async {
      final inner = Graph<String, String>(
        localState: LocalState.of<Map<String, Object?>>((ctx) => {'who': 'inner'}),
      )
        ..addLambdaNode('i1', _append('i1'))
        ..addLambdaNode(
          'i2',
          _append('i2'),
          options: NodeOptions(
            statePreHandler: StateHandler.pre<String, Map<String, Object?>>(
              (ctx, input, state) => '$input(${state['note']})',
            ),
          ),
        )
        ..addEdge(Graph.start, 'i1')
        ..addEdge('i1', 'i2')
        ..addEdge('i2', Graph.end);
      final outer = Graph<String, String>(
        localState: LocalState.of<Map<String, Object?>>((ctx) => {'who': 'outer'}),
      )
        ..addGraphNode(
          'sub',
          inner,
          options: const NodeOptions(
            compileOptions: GraphCompileOptions(interruptBeforeNodes: ['i2']),
          ),
        )
        ..addEdge(Graph.start, 'sub')
        ..addEdge('sub', Graph.end);
      final runnable = await outer.compile(
        ctx,
        options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
      );
      await _interruptOf(
        runnable.invoke(ctx, 'x', options: [CallOption.checkpointId('id')]),
      );

      final seen = <String>[];
      final result = await runnable.invoke(
        ctx,
        '',
        options: [
          CallOption.checkpointId('id'),
          CallOption.stateModifier((ctx, path, state) {
            final map = state as Map<String, Object?>;
            seen.add('${path.path}:${map['who']}');
            map['note'] = 'modified';
          }),
        ],
      );
      expect(seen, ['[]:outer', '[sub]:inner']);
      expect(result, 'xi1(modified)i2');
    });

    test('a state modifier that throws fails the run', () async {
      final graph = Graph<String, String>(
        localState: LocalState.of<Map<String, Object?>>((ctx) => {}),
      )
        ..addLambdaNode('a', _append('a'))
        ..addLambdaNode('b', _append('b'))
        ..addEdge(Graph.start, 'a')
        ..addEdge('a', 'b')
        ..addEdge('b', Graph.end);
      final runnable = await graph.compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: InMemoryCheckpointStore(),
          interruptBeforeNodes: const ['b'],
        ),
      );
      await _interruptOf(
        runnable.invoke(ctx, 'x', options: [CallOption.checkpointId('id')]),
      );
      await expectLater(
        runnable.invoke(
          ctx,
          '',
          options: [
            CallOption.checkpointId('id'),
            CallOption.stateModifier((ctx, path, state) => throw StateError('no')),
          ],
        ),
        throwsA(
          isA<GraphRunException>()
              .having((e) => e.message, 'message', contains('state modifier fail')),
        ),
      );
    });

    test('checkpoint options do not travel into nested graphs', () async {
      // As in Eino, the graph that is called takes a checkpoint id whatever
      // the option is aimed at, and an option that is passed on into a
      // nested graph loses it (Option.deepCopy): the nested graph here has
      // no store and would refuse an id.
      final outer = Graph<String, String>()
        ..addGraphNode('sub', _line(['a']))
        ..addEdge(Graph.start, 'sub')
        ..addEdge('sub', Graph.end);
      final store = InMemoryCheckpointStore();
      final runnable = await outer.compile(
        ctx,
        options: GraphCompileOptions(checkpointStore: store),
      );
      final aimed = CallOption.checkpointId('id').designateNodeWithPath([
        NodePath(const ['sub', 'a']),
      ]);
      expect(await runnable.invoke(ctx, 'x', options: [aimed]), 'xa');

      final withoutStore = await (Graph<String, String>()
            ..addGraphNode('sub', _line(['a']))
            ..addEdge(Graph.start, 'sub')
            ..addEdge('sub', Graph.end))
          .compile(ctx);
      await expectLater(
        withoutStore.invoke(ctx, 'x', options: [aimed]),
        throwsA(
          isA<GraphRunException>()
              .having((e) => e.nodePath.path, 'nodePath', isEmpty)
              .having(
                (e) => e.message,
                'message',
                contains('have not set checkpoint store'),
              ),
        ),
      );
    });
  });

  group('an interrupt from outside', () {
    test('the handle says whether it was used, and works once', () {
      final (runCtx, interrupter) = ctx.withGraphInterrupt();
      expect(runCtx, isNot(same(ctx)));
      expect(interrupter.isInterrupted, isFalse);
      interrupter.interrupt();
      expect(interrupter.isInterrupted, isTrue);
      expect(interrupter.interrupt, throwsStateError);
    });

    test('before the run starts: the run stops behind its first nodes',
        () async {
      final runnable = await _line(['a', 'b']).compile(
        ctx,
        options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
      );
      final (runCtx, interrupter) = ctx.withGraphInterrupt();
      interrupter.interrupt();
      final info = await _interruptOf(
        runnable.invoke(runCtx, 'x', options: [CallOption.checkpointId('id')]),
      );
      expect(info.afterNodes, ['a']);
      expect(
        await runnable.invoke(ctx, '', options: [CallOption.checkpointId('id')]),
        'xab',
      );
    });

    test('a run that has ended is not affected, and no timer is left',
        () async {
      final runnable = await _line(['a']).compile(ctx);
      fakeAsync((async) {
        final (runCtx, interrupter) = ctx.withGraphInterrupt();
        String? result;
        runnable.invoke(runCtx, 'x').then((value) => result = value);
        async.flushMicrotasks();
        expect(result, 'xa');
        interrupter.interrupt(timeout: const Duration(hours: 1));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('with a timeout: nodes that finish in time are waited for', () {
      fakeAsync((async) {
        final graph = Graph<String, String>()
          ..addLambdaNode(
            'slow',
            Lambda<String, String>.invokable((ctx, input) async {
              await Future<void>.delayed(const Duration(seconds: 2));
              return '$input!';
            }),
          )
          ..addLambdaNode('next', _append('next'))
          ..addEdge(Graph.start, 'slow')
          ..addEdge('slow', 'next')
          ..addEdge('next', Graph.end);
        Runnable<String, String>? runnable;
        graph
            .compile(
              ctx,
              options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
            )
            .then((value) => runnable = value);
        async.flushMicrotasks();

        final (runCtx, interrupter) = ctx.withGraphInterrupt();
        GraphInterruptInfo? info;
        runnable!
            .invoke(runCtx, 'x', options: [CallOption.checkpointId('id')])
            .then<void>(
              (_) => fail('expected an interrupt'),
              onError: (Object error) =>
                  info = (error as GraphInterruptedException).info,
            );
        async.elapse(const Duration(seconds: 1));
        interrupter.interrupt(timeout: const Duration(seconds: 5));
        async.elapse(const Duration(milliseconds: 500));
        expect(info, isNull);
        async.elapse(const Duration(seconds: 1));
        // The node finished within the timeout: nothing runs again.
        expect(info!.afterNodes, ['slow']);
        expect(info!.rerunNodes, isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('with a timeout: a node that does not finish in time runs again', () {
      fakeAsync((async) {
        var runs = 0;
        final graph = Graph<String, String>()
          ..addLambdaNode(
            'slow',
            Lambda<String, String>.invokable((ctx, input) async {
              runs++;
              await Future<void>.delayed(const Duration(seconds: 10));
              return '$input!';
            }),
          )
          ..addEdge(Graph.start, 'slow')
          ..addEdge('slow', Graph.end);
        Runnable<String, String>? runnable;
        graph
            .compile(
              ctx,
              options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
            )
            .then((value) => runnable = value);
        async.flushMicrotasks();

        final (runCtx, interrupter) = ctx.withGraphInterrupt();
        GraphInterruptInfo? info;
        runnable!
            .invoke(runCtx, 'x', options: [CallOption.checkpointId('id')])
            .then<void>(
              (_) => fail('expected an interrupt'),
              onError: (Object error) =>
                  info = (error as GraphInterruptedException).info,
            );
        async.elapse(const Duration(seconds: 1));
        interrupter.interrupt(timeout: const Duration(seconds: 2));
        async.elapse(const Duration(seconds: 1));
        expect(info, isNull);
        async.elapse(const Duration(seconds: 1));
        expect(info!.rerunNodes, ['slow']);

        String? result;
        runnable!
            .invoke(ctx, '', options: [CallOption.checkpointId('id')])
            .then((value) => result = value);
        async.elapse(const Duration(seconds: 10));
        expect(result, 'x!');
        expect(runs, 2);
      });
    });
  });

  group('GraphCompileCallbacks', () {
    tearDown(GraphCompileCallbacks.clearGlobal);

    test('setGlobal replaces what was registered, as in Eino', () async {
      final first = _Callback();
      final second = _Callback();
      GraphCompileCallbacks.setGlobal([first]);
      expect(GraphCompileCallbacks.global, [first]);
      GraphCompileCallbacks.setGlobal([second]);
      expect(GraphCompileCallbacks.global, [second]);

      await _line(['a']).compile(
        ctx,
        options: const GraphCompileOptions(graphName: 'g'),
      );
      expect(first.names, isEmpty);
      expect(second.names, ['g']);
    });

    test('appendGlobal adds behind what is there', () async {
      final first = _Callback();
      final second = _Callback();
      final own = _Callback();
      GraphCompileCallbacks.setGlobal([first]);
      GraphCompileCallbacks.appendGlobal([second]);
      expect(GraphCompileCallbacks.global, [first, second]);

      await _line(['a']).compile(
        ctx,
        options: GraphCompileOptions(graphName: 'g', compileCallbacks: [own]),
      );
      expect(first.names, ['g']);
      expect(second.names, ['g']);
      expect(own.names, ['g']);
    });

    test('setGlobal with nothing removes all, and takes its own list', () {
      final callback = _Callback();
      GraphCompileCallbacks.setGlobal([callback]);
      // The list handed in may be the one that is replaced.
      GraphCompileCallbacks.setGlobal(GraphCompileCallbacks.global);
      expect(GraphCompileCallbacks.global, [callback]);
      GraphCompileCallbacks.setGlobal(const []);
      expect(GraphCompileCallbacks.global, isEmpty);
      expect(
        () => GraphCompileCallbacks.global.add(callback),
        throwsUnsupportedError,
      );
    });
  });

  group('errors', () {
    test('StreamCanceledException is a threepio exception', () {
      const canceled = StreamCanceledException();
      expect(canceled, isA<ThreepioException>());
      expect(canceled.message, 'stream canceled');
      expect('$canceled', 'StreamCanceledException: stream canceled');
      expect(
        const StreamCanceledException('cut').toString(),
        'StreamCanceledException: cut',
      );
    });

    test('StreamReadException says whether the stream was empty', () {
      expect(const StreamReadException.empty().isEmptyStream, isTrue);
      expect(const StreamReadException('failed').isEmptyStream, isFalse);
    });
  });

  group('the type registry, for values declared by an interface', () {
    test('hasSubtypeOf and withTypeOf', () {
      expect(TypeRegistry.hasSubtypeOf<Object>(), isTrue);
      expect(TypeRegistry.hasSubtypeOf<Message>(), isTrue);
      expect(TypeRegistry.hasSubtypeOf<_Callback>(), isFalse);
      expect(
        TypeRegistry.withTypeOf<Type>(Message.user('x'), <T>() => T),
        Message,
      );
      expect(TypeRegistry.withTypeOf<Type>(const _Foreign(), <T>() => T), isNull);
    });
  });

  group('what the libraries export', () {
    test('compose.dart has the interrupt, checkpoint and workflow API', () {
      expect(compose.interrupt, isA<Function>());
      expect(compose.statefulInterrupt, isA<Function>());
      expect(compose.compositeInterrupt, isA<Function>());
      expect(compose.extractInterruptInfo, isA<Function>());
      expect(compose.migrateCheckpointState, isA<Function>());
      expect(const compose.JsonCheckpointSerializer(), isA<compose.CheckpointSerializer>());
      expect(compose.Workflow<String, String>(), isA<compose.AnyGraph>());
      expect(compose.FieldMapping.toField('a'), isA<compose.FieldMapping>());
      expect(compose.GraphInterruptInfo(), isA<compose.GraphInterruptInfo>());
      expect(compose.BatchNode.segmentType.name, 'batch_process');
      expect(
        compose.getInterruptState<String>(ctx),
        (wasInterrupted: false, hasState: false, state: null),
      );
      expect(
        compose.getResumeContext<String>(ctx),
        (isResumeTarget: false, hasData: false, data: null),
      );
    });

    test('the umbrella has the same, and the engine types stay inside', () {
      expect(interrupt, same(compose.interrupt));
      expect(Workflow<String, String>(), isA<AnyGraph>());
      expect(const JsonCheckpointSerializer(), isA<CheckpointSerializer>());
      // Not exported: only reachable through src/.
      expect(interrupt(ctx, null), isA<AddressedInterruptSignal>());
      expect(SubGraphInterrupt, isNotNull);
    });

    test('io.dart has the file store of compose; the older one of the state '
        'graph is in legacy_graph.dart', () {
      expect(io.FileCheckpointStore, isNot(legacy.FileCheckpointStore));
      expect(legacy.JsonCheckpointSerializer, isNot(JsonCheckpointSerializer));
      expect(legacy.GraphInterruptException, isNot(GraphInterruptedException));
    });
  });
}
