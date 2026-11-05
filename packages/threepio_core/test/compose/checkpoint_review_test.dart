// What an independent review of the checkpoint engine found. Each test
// failed before its fix.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/src/compose/graph_interrupt.dart';
import 'package:threepio_core/src/compose/task_manager.dart';

Future<GraphInterruptInfo> _interruptOf(Future<Object?> run) async {
  try {
    await run;
  } on GraphInterruptedException catch (interrupted) {
    return interrupted.info;
  }
  fail('expected an interrupt');
}

final class _Pair implements FieldAddressable {
  const _Pair({this.left = '', this.right = ''});

  final String left;
  final String right;

  @override
  Object? getField(String name) => switch (name) {
        'left' => left,
        'right' => right,
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };

  @override
  _Pair withField(String name, Object? value) => switch (name) {
        'left' => _Pair(left: value! as String, right: right),
        'right' => _Pair(left: left, right: value! as String),
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };
}

void main() {
  setUpAll(() {
    FieldAddressable.registerBlank<_Pair>(() => const _Pair());
  });

  final ctx = RunContext.background();

  group('typed values in the checkpoint of a nested graph', () {
    Future<Runnable<String, int>> build(CheckpointStore store) {
      final inner = Graph<String, int>()
        ..addLambdaNode(
          'split',
          Lambda.invokable((ctx, String input) => input.split(',')),
        )
        ..addLambdaNode(
          'count',
          Lambda.invokable((ctx, List<String> parts) => parts.length),
        )
        ..addEdge(Graph.start, 'split')
        ..addEdge('split', 'count')
        ..addEdge('count', Graph.end);
      final outer = Graph<String, int>()
        ..addGraphNode(
          'sub',
          inner,
          options: const NodeOptions(
            compileOptions: GraphCompileOptions(interruptBeforeNodes: ['count']),
          ),
        )
        ..addEdge(Graph.start, 'sub')
        ..addEdge('sub', Graph.end);
      return outer.compile(
        ctx,
        options: GraphCompileOptions(checkpointStore: store),
      );
    }

    test('a List<String> input of a nested node comes back typed (invoke)',
        () async {
      final runnable = await build(InMemoryCheckpointStore());
      await _interruptOf(
        runnable.invoke(ctx, 'a,b,c', options: [CallOption.checkpointId('id')]),
      );
      expect(
        await runnable.invoke(ctx, '', options: [CallOption.checkpointId('id')]),
        3,
      );
    });

    test('and in a streaming run', () async {
      final runnable = await build(InMemoryCheckpointStore());
      await _interruptOf(
        runnable.stream(ctx, 'a,b', options: [CallOption.checkpointId('id')]),
      );
      final stream = await runnable.stream(
        ctx,
        '',
        options: [CallOption.checkpointId('id')],
      );
      expect(await stream.collectAll(), [2]);
    });
  });

  group('a graph that is compiled more than once', () {
    Workflow<Map<String, Object?>, String> mapped() {
      final workflow = Workflow<Map<String, Object?>, String>();
      workflow
          .addLambdaNode(
            'join',
            Lambda.invokable((ctx, _Pair pair) => '${pair.left}+${pair.right}'),
          )
          .addInput(Graph.start, [
        FieldMapping.mapFields('a', 'left'),
        FieldMapping.mapFields('b', 'right'),
      ]);
      workflow.end().addInput('join');
      return workflow;
    }

    test('assembles the input of a mapped node once per run', () async {
      final workflow = mapped();
      final first = await workflow.compile(ctx);
      final second = await workflow.compile(ctx);
      const input = {'a': 'x', 'b': 'y'};
      expect(await first.invoke(ctx, input), 'x+y');
      expect(await second.invoke(ctx, input), 'x+y');
      final third = await workflow.compile(ctx);
      expect(await third.invoke(ctx, input), 'x+y');
      expect(await first.invoke(ctx, input), 'x+y');
    });

    test('a batch node runs a workflow with field mappings again and again',
        () async {
      final node = BatchNode<Map<String, Object?>, String>(innerTask: mapped());
      const inputs = [
        {'a': '1', 'b': '2'},
        {'a': '3', 'b': '4'},
      ];
      expect(await node.invoke(ctx, inputs), ['1+2', '3+4']);
      expect(await node.invoke(ctx, inputs), ['1+2', '3+4']);
    });

    test('static values are merged once', () async {
      final workflow = Workflow<Map<String, Object?>, Map<String, Object?>>();
      workflow
          .addLambdaNode(
            'n',
            Lambda.invokable((ctx, Map<String, Object?> input) => input),
          )
          .addInput(Graph.start, [FieldMapping.mapFields('a', 'a')])
          .setStaticValue(['fixed'], 1);
      workflow.end().addInput('n');
      final first = await workflow.compile(ctx);
      final second = await workflow.compile(ctx);
      expect(await first.invoke(ctx, {'a': 'x'}), {'a': 'x', 'fixed': 1});
      expect(await second.invoke(ctx, {'a': 'x'}), {'a': 'x', 'fixed': 1});
    });
  });

  group('a node finishes behind an interrupt node while another interrupts',
      () {
    // Eager run: `a` (interrupt-after) finishes first and its output is
    // passed on; then `c`, which runs beside it, interrupts. The output of
    // `a` must not be passed on a second time: in a streaming run it is a
    // stream that was handed over already.
    Future<(Runnable<String, Map<String, Object?>>, Completer<void>)> build({
      required List<String> seen,
    }) async {
      final release = Completer<void>();
      final workflow = Workflow<String, Map<String, Object?>>();
      workflow
          .addLambdaNode('a', Lambda.invokable((ctx, String s) => '$s-a'))
          .addInput(Graph.start);
      workflow
          .addLambdaNode(
            'c',
            Lambda.invokable((ctx, String s) async {
              if (!getInterruptState<Object>(ctx).wasInterrupted) {
                await release.future;
                throw interrupt(ctx, 'c waits');
              }
              return '$s-c';
            }),
          )
          .addInput(Graph.start);
      for (final key in ['b1', 'b2']) {
        workflow
            .addLambdaNode(
              key,
              Lambda.invokable((ctx, String s) {
                seen.add('$key:$s');
                return '$s-$key';
              }),
            )
            .addInput('a');
      }
      workflow.end()
        ..addInput('b1', [FieldMapping.toField('b1')])
        ..addInput('b2', [FieldMapping.toField('b2')])
        ..addInput('c', [FieldMapping.toField('c')]);
      final runnable = await workflow.compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: InMemoryCheckpointStore(),
          interruptAfterNodes: const ['a'],
        ),
      );
      return (runnable, release);
    }

    for (final streaming in [false, true]) {
      test(streaming ? 'stream' : 'invoke', () async {
        final seen = <String>[];
        final (runnable, release) = await build(seen: seen);
        final options = [CallOption.checkpointId('id')];

        final Future<Object?> first = streaming
            ? runnable.stream(ctx, 'in', options: options)
            : runnable.invoke(ctx, 'in', options: options);
        final outcome = _interruptOf(first);
        // `a` finishes; then `c` is let go and interrupts.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        release.complete();
        final info = await outcome;
        expect(info.afterNodes, ['a']);
        expect(info.rerunNodes, ['c']);
        expect(seen, isEmpty);

        final point = info.interruptContexts.single;
        final Map<String, Object?> result;
        if (streaming) {
          final stream = await runnable.stream(
            ctx.resume([point.id]),
            '',
            options: options,
          );
          result = {};
          (await stream.collectAll()).forEach(result.addAll);
        } else {
          result = await runnable.invoke(
            ctx.resume([point.id]),
            '',
            options: options,
          );
        }
        // `c` is a String node: run again, it gets the empty value of its
        // input type, as in Eino.
        expect(result, {'b1': 'in-a-b1', 'b2': 'in-a-b2', 'c': '-c'});
        expect(seen, unorderedEquals(['b1:in-a', 'b2:in-a']));
      });
    }
  });

  group('a state modifier of a resumed run', () {
    test('does not reach a graph that a node of the run runs on its own',
        () async {
      // The inner graph is resumed from its own store, without a modifier:
      // the modifier of the outer run must not be applied to its state, as
      // in Eino (setStateModifier overwrites with nil).
      final innerStore = InMemoryCheckpointStore();
      final inner = await (Graph<String, String>(
        localState: LocalState.of<Map<String, Object?>>((ctx) => {'who': 'inner'}),
      )
            ..addLambdaNode('a', Lambda.invokable((ctx, String s) => '$s-a'))
            ..addLambdaNode(
              'b',
              Lambda.invokable((ctx, String s) async {
                var who = '';
                await processState<Map<String, Object?>>(
                  ctx,
                  (ctx, state) => who = '${state['who']}',
                );
                return '$s-b($who)';
              }),
            )
            ..addEdge(Graph.start, 'a')
            ..addEdge('a', 'b')
            ..addEdge('b', Graph.end))
          .compile(
        ctx,
        options: GraphCompileOptions(
          graphName: 'inner',
          checkpointStore: innerStore,
          interruptBeforeNodes: const ['b'],
        ),
      );
      final outerStore = InMemoryCheckpointStore();
      final outer = await (Graph<String, String>(
        localState: LocalState.of<Map<String, Object?>>((ctx) => {'who': 'outer'}),
      )
            ..addLambdaNode(
              'runs_inner',
              Lambda<String, String>.invokable((ctx, input) async {
                try {
                  return await inner.invoke(
                    ctx,
                    input,
                    options: [CallOption.checkpointId('inner')],
                  );
                } on GraphInterruptedException catch (interrupted) {
                  throw compositeInterrupt(ctx, null, null, [interrupted]);
                }
              }),
            )
            ..addEdge(Graph.start, 'runs_inner')
            ..addEdge('runs_inner', Graph.end))
          .compile(
        ctx,
        options: GraphCompileOptions(
          graphName: 'outer',
          checkpointStore: outerStore,
        ),
      );
      await _interruptOf(
        outer.invoke(ctx, 'x', options: [CallOption.checkpointId('outer')]),
      );

      final modified = <String>[];
      expect(
        await outer.invoke(
          ctx,
          '',
          options: [
            CallOption.checkpointId('outer'),
            CallOption.stateModifier((ctx, path, state) {
              final map = state as Map<String, Object?>;
              modified.add('${map['who']}');
              map['who'] = 'modified';
            }),
          ],
        ),
        'x-a-b(inner)',
      );
      expect(modified, ['outer']);
    });
  });

  group('GraphCancelSignal', () {
    test('wakes what registered, until it is removed', () {
      final signal = GraphCancelSignal();
      var woken = 0;
      void wake() => woken++;
      signal.addWaker(wake);
      signal.trigger(Duration.zero);
      // Triggered, and expired at once.
      expect(woken, 2);
      signal.removeWaker(wake);
      expect(signal.isExpired, isTrue);
    });

    test('a task manager lets go of the signal when it is disposed', () {
      final signal = GraphCancelSignal();
      final manager = TaskManager(
        runWrapper: runnableInvoke,
        options: const [],
        needAll: true,
        cancel: signal,
      )..dispose();
      signal.trigger(null);
      expect(manager.cancel, same(signal));
    });
  });

  group('WorkflowNode.setStaticValue', () {
    test('a second value for the same path replaces the first', () async {
      final workflow = Workflow<String, Map<String, Object?>>();
      workflow
          .addLambdaNode(
            'n',
            Lambda.invokable((ctx, Map<String, Object?> input) => input),
          )
          .addDependency(Graph.start)
          .setStaticValue(['a', 'b'], 'first')
          .setStaticValue(['a', 'b'], 'second');
      workflow.end().addInput('n');
      final runnable = await workflow.compile(ctx);
      expect(await runnable.invoke(ctx, 'x'), {
        'a': {'b': 'second'},
      });
    });
  });
}
