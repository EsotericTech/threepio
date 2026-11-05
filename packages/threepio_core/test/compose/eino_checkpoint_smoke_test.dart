// A first end-to-end pass over interrupt, checkpoint and resume, written
// while the engine was built. The ported Go tests are in the eino_* files.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';

final class _State {
  _State(this.a);
  factory _State.fromJson(Map<String, Object?> json) =>
      _State(json['a']! as String);
  String a;
  Map<String, Object?> toJson() => {'a': a};

  @override
  bool operator ==(Object other) => other is _State && other.a == a;

  @override
  int get hashCode => a.hashCode;

  @override
  String toString() => '_State($a)';
}

void main() {
  setUpAll(() {
    TypeRegistry.registerName<_State>(
      'smoke_state',
      fromJson: _State.fromJson,
      toJson: (state) => state.toJson(),
    );
  });

  final ctx = RunContext.background();

  test('TestSimpleCheckPoint', () async {
    final store = InMemoryCheckpointStore();
    final g = Graph<String, String>(
      localState: LocalState.of<_State>((ctx) => _State('')),
    )
      ..addLambdaNode('1', Lambda.invokable((ctx, String input) => '${input}1'))
      ..addLambdaNode(
        '2',
        Lambda.invokable((ctx, String input) => '${input}2'),
        options: NodeOptions(
          statePreHandler: StateHandler.pre<String, _State>(
            (ctx, input, state) => input + state.a,
          ),
        ),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge('2', Graph.end);
    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(
        nodeTriggerMode: NodeTriggerMode.allPredecessor,
        checkpointStore: store,
        interruptAfterNodes: const ['1'],
        interruptBeforeNodes: const ['2'],
        graphName: 'root',
      ),
    );

    GraphInterruptInfo? info;
    try {
      await r.invoke(ctx, 'start', options: [CallOption.checkpointId('1')]);
      fail('expected an interrupt');
    } on GraphInterruptedException catch (e) {
      info = e.info;
    }
    expect(info.state, _State(''));
    expect(info.beforeNodes, ['2']);
    expect(info.afterNodes, ['1']);
    expect(info.rerunNodesExtra, isEmpty);
    expect(info.subGraphs, isEmpty);
    expect(
      info.interruptContexts.single.equalsWithoutId(
        InterruptCtx(
          id: '',
          address: Address(const [
            AddressSegment(type: AddressSegmentType.runnable, id: 'root'),
          ]),
          info: _State(''),
          isRootCause: true,
        ),
      ),
      isTrue,
    );

    final resumeCtx =
        ctx.resumeWithData(info.interruptContexts.single.id, _State('state'));
    expect(
      await r.invoke(resumeCtx, 'start', options: [CallOption.checkpointId('1')]),
      'start1state2',
    );
  });

  test('a node interrupts and is resumed with data', () async {
    final store = InMemoryCheckpointStore();
    var runs = 0;
    final g = Graph<String, String>()
      ..addLambdaNode(
        'ask',
        Lambda.invokable((ctx, String input) {
          runs++;
          final previous = getInterruptState<String>(ctx);
          if (!previous.wasInterrupted) {
            throw statefulInterrupt(ctx, 'need approval', input);
          }
          final resumed = getResumeContext<String>(ctx);
          return '${previous.state}:${resumed.data}';
        }),
      )
      ..addEdge(Graph.start, 'ask')
      ..addEdge('ask', Graph.end);
    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: store, graphName: 'g'),
    );

    GraphInterruptInfo? info;
    try {
      await r.invoke(ctx, 'hello', options: [CallOption.checkpointId('cp')]);
      fail('expected an interrupt');
    } on GraphInterruptedException catch (e) {
      info = e.info;
    }
    expect(info.rerunNodes, ['ask']);
    expect(info.rerunNodesExtra, {'ask': 'need approval'});
    final point = info.interruptContexts.single;
    expect(point.address.toString(), 'runnable:g;node:ask');
    expect(point.info, 'need approval');
    expect(point.isRootCause, isTrue);
    expect(point.parent!.address.toString(), 'runnable:g');

    final out = await r.invoke(
      ctx.resumeWithData(point.id, 'yes'),
      'ignored',
      options: [CallOption.checkpointId('cp')],
    );
    expect(out, 'hello:yes');
    expect(runs, 2);
  });

  test('stream mode: interrupt before a node, resume', () async {
    final store = InMemoryCheckpointStore();
    final g = Graph<String, String>()
      ..addLambdaNode('1', Lambda.invokable((ctx, String input) => '${input}1'))
      ..addLambdaNode('2', Lambda.invokable((ctx, String input) => '${input}2'))
      ..addEdge(Graph.start, '1')
      ..addEdge('1', '2')
      ..addEdge('2', Graph.end);
    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(
        checkpointStore: store,
        interruptBeforeNodes: const ['2'],
      ),
    );
    await expectLater(
      r.stream(ctx, 'in', options: [CallOption.checkpointId('s')]),
      throwsA(isA<GraphInterruptedException>()),
    );
    final resumed =
        await r.stream(ctx, 'in', options: [CallOption.checkpointId('s')]);
    expect(await resumed.collectAll(), ['in12']);
  });

  test('TestSubGraph: a nested graph interrupts and resumes', () async {
    final sub = Graph<String, String>(
      localState: LocalState.of<_State>((ctx) => _State('')),
    )
      ..addLambdaNode('1', Lambda.invokable((ctx, String input) => '${input}1'))
      ..addLambdaNode(
        '2',
        Lambda.invokable((ctx, String input) => '${input}2'),
        options: NodeOptions(
          statePreHandler: StateHandler.pre<String, _State>(
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
        sub,
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

    for (final stream in [false, true]) {
      final id = stream ? 'stream' : 'invoke';
      GraphInterruptInfo? info;
      try {
        if (stream) {
          await r.stream(ctx, 'start', options: [CallOption.checkpointId(id)]);
        } else {
          await r.invoke(ctx, 'start', options: [CallOption.checkpointId(id)]);
        }
        fail('expected an interrupt');
      } on GraphInterruptedException catch (e) {
        info = e.info;
      }
      expect(info.subGraphs.keys, ['2']);
      expect(info.subGraphs['2']!.state, _State(''));
      expect(info.subGraphs['2']!.afterNodes, ['1']);
      final point = info.interruptContexts.single;
      expect(point.address.toString(), 'runnable:root;node:2');
      expect(point.info, _State(''));
      expect(point.parent!.address.toString(), 'runnable:root');

      final resumeCtx = ctx.resumeWithData(point.id, _State('state'));
      final String result;
      if (stream) {
        final reader = await r.stream(
          resumeCtx,
          'start',
          options: [CallOption.checkpointId(id)],
        );
        result = (await reader.collectAll()).join();
      } else {
        result = await r.invoke(
          resumeCtx,
          'start',
          options: [CallOption.checkpointId(id)],
        );
      }
      expect(result, 'start11state23');
    }
  });

  test('a tool interrupts; only that call runs again', () async {
    final calls = <String>[];
    final node = ToolsNode(
      ToolsNodeConfig(
        tools: [
          FunctionTool<Map<String, Object?>, String>.fromInfo(
            ToolInfo.function(name: 'plain', description: 'd'),
            fromJson: (json) => json,
            invoke: (ctx, args, _) {
              calls.add('plain');
              return 'done';
            },
          ),
          FunctionTool<Map<String, Object?>, String>.fromInfo(
            ToolInfo.function(name: 'ask', description: 'd'),
            fromJson: (json) => json,
            invoke: (ctx, args, _) {
              calls.add('ask');
              final resumed = getResumeContext<String>(ctx);
              if (!getInterruptState<Object>(ctx).wasInterrupted) {
                throw interrupt(ctx, 'approve?');
              }
              return 'approved:${resumed.data}';
            },
          ),
        ],
      ),
    );
    final g = Graph<Message, List<Message>>()
      ..addToolsNode('tools', node)
      ..addEdge(Graph.start, 'tools')
      ..addEdge('tools', Graph.end);
    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(
        checkpointStore: InMemoryCheckpointStore(),
        graphName: 'g',
      ),
    );
    final input = Message.assistant(
      '',
      toolCalls: const [
        ToolCall(id: 'c1', function: FunctionCall(name: 'plain', arguments: '{}')),
        ToolCall(id: 'c2', function: FunctionCall(name: 'ask', arguments: '{}')),
      ],
    );

    GraphInterruptInfo? info;
    try {
      await r.invoke(ctx, input, options: [CallOption.checkpointId('t')]);
      fail('expected an interrupt');
    } on GraphInterruptedException catch (e) {
      info = e.info;
    }
    expect(info.rerunNodes, ['tools']);
    final extra = info.rerunNodesExtra['tools']! as ToolsInterruptAndRerunExtra;
    expect(extra.rerunTools, ['c2']);
    expect(extra.executedTools, {'c1': 'done'});
    expect(extra.rerunExtraMap, {'c2': 'approve?'});
    final point = info.interruptContexts.single;
    expect(point.address.toString(), 'runnable:g;node:tools;tool:ask:c2');
    expect(point.info, 'approve?');

    final out = await r.invoke(
      ctx.resumeWithData(point.id, 'ok'),
      input,
      options: [CallOption.checkpointId('t')],
    );
    expect([for (final m in out) m.content], ['done', 'approved:ok']);
    expect(calls, ['plain', 'ask', 'ask']);
  });

  test('a workflow maps fields', () async {
    final wf = Workflow<Map<String, Object?>, Map<String, Object?>>();
    wf
        .addLambdaNode(
          'upper',
          Lambda.invokable((ctx, String s) => s.toUpperCase()),
        )
        .addInput(Graph.start, [FieldMapping.fromField('text')]);
    wf.addLambdaNode(
      'join',
      Lambda.invokable(
        (ctx, Map<String, Object?> input) =>
            '${input['a']}-${input['b']}-${input['c']}',
      ),
    )
      ..addInput('upper', [FieldMapping.toField('a')])
      ..addInput(Graph.start, [FieldMapping.mapFields('other', 'b')])
      ..setStaticValue(['c'], 'static');
    wf.end()
      ..addInput('join', [FieldMapping.toField('result')])
      ..addInputWithOptions(
        Graph.start,
        [FieldMapping.mapFieldPaths(['nested', 'x'], ['deep', 'x'])],
        noDirectDependency: true,
      );
    final r = await wf.compile(ctx);
    final input = {
      'text': 'hi',
      'other': 'o',
      'nested': {'x': 1},
    };
    expect(await r.invoke(ctx, input), {
      'result': 'HI-o-static',
      'deep': {'x': 1},
    });
    final stream = await r.stream(ctx, input);
    final merged = <String, Object?>{};
    (await stream.collectAll()).forEach(merged.addAll);
    expect(merged, {
      'result': 'HI-o-static',
      'deep': {'x': 1},
    });
  });

  test('an interrupt from outside stops the run and keeps the input', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final inputs = <String>[];
    final g = Graph<String, String>()
      ..addLambdaNode(
        'slow',
        Lambda.invokable((ctx, String input) async {
          inputs.add(input);
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
          return '$input!';
        }),
      )
      ..addEdge(Graph.start, 'slow')
      ..addEdge('slow', Graph.end);
    final r = await g.compile(
      ctx,
      options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
    );
    final (runCtx, interrupter) = ctx.withGraphInterrupt();
    final run = r.invoke(runCtx, 'in', options: [CallOption.checkpointId('x')]);
    final outcome = expectLater(
      run,
      throwsA(
        isA<GraphInterruptedException>()
            .having((e) => e.info.rerunNodes, 'rerunNodes', ['slow']),
      ),
    );
    await entered.future;
    interrupter.interrupt(timeout: Duration.zero);
    await outcome;
    release.complete();

    expect(
      await r.invoke(ctx, 'other', options: [CallOption.checkpointId('x')]),
      'in!',
    );
    expect(inputs, ['in', 'in']);
  });
}
