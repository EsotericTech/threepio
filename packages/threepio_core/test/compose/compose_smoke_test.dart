import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

final class _Echo extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.function(
        name: 'echo',
        description: 'echoes',
      );

  @override
  Future<String> run(String argumentsJson) async => 'echo:$argumentsJson';
}

void main() {
  final ctx = RunContext.background();

  test('a graph runs in all four modes', () async {
    final graph = Graph<String, String>()
      ..addLambdaNode(
        'a',
        Lambda<String, String>.invokable((ctx, input) => '$input-a'),
      )
      ..addLambdaNode(
        'b',
        Lambda<String, String>.streamable(
          (ctx, input) => StreamReader.fromIterable(['$input-', 'b']),
        ),
      )
      ..addEdge(Graph.start, 'a')
      ..addEdge('a', 'b')
      ..addEdge('b', Graph.end);
    final runnable = await graph.compile(ctx);

    expect(await runnable.invoke(ctx, 'x'), 'x-a-b');
    expect(await (await runnable.stream(ctx, 'x')).collectAll(), ['x-a-', 'b']);
    expect(
      await runnable.collect(ctx, StreamReader.fromIterable(['x', 'y'])),
      'xy-a-b',
    );
    expect(
      await (await runnable.transform(ctx, StreamReader.fromIterable(['x'])))
          .collectAll(),
      ['x-a-', 'b'],
    );
  });

  test('a chain with a parallel and a branch', () async {
    final chain = Chain<String, String>()
      ..appendParallel(
        Parallel()
          ..addLambda(
            'upper',
            Lambda<String, String>.invokable((ctx, s) => s.toUpperCase()),
          )
          ..addLambda(
            'length',
            Lambda<String, int>.invokable((ctx, s) => s.length),
          ),
      )
      ..appendLambda(
        Lambda<Map<String, Object?>, String>.invokable(
          (ctx, m) => '${m['upper']}:${m['length']}',
        ),
      )
      ..appendBranch(
        ChainBranch.single<String>(
          (ctx, input) => input.length > 4 ? 'long' : 'short',
        )
          ..addLambda(
            'long',
            Lambda<String, String>.invokable((ctx, s) => 'long($s)'),
          )
          ..addLambda(
            'short',
            Lambda<String, String>.invokable((ctx, s) => 'short($s)'),
          ),
      );
    final runnable = await chain.compile(ctx);
    expect(await runnable.invoke(ctx, 'ab'), 'short(AB:2)');
    expect(await runnable.invoke(ctx, 'abc'), 'long(ABC:3)');
    expect(
      await (await runnable.stream(ctx, 'abc')).collectAll(),
      ['long(ABC:3)'],
    );
  });

  test('state handlers and processState', () async {
    final graph = Graph<String, String>(
      localState: LocalState.of<List<String>>((ctx) => []),
    )
      ..addLambdaNode(
        'a',
        Lambda<String, String>.invokable((ctx, input) async {
          await processState<List<String>>(ctx, (ctx, s) => s.add('in-a'));
          return '$input-a';
        }),
        options: NodeOptions(
          statePreHandler: StateHandler.pre<String, List<String>>(
            (ctx, input, state) {
              state.add('pre');
              return input;
            },
          ),
          statePostHandler: StateHandler.post<String, List<String>>(
            (ctx, output, state) => '$output-${state.join(',')}',
          ),
        ),
      )
      ..addEdge(Graph.start, 'a')
      ..addEdge('a', Graph.end);
    final runnable = await graph.compile(ctx);
    expect(await runnable.invoke(ctx, 'x'), 'x-a-pre,in-a');
    expect(await (await runnable.stream(ctx, 'x')).collectAll(), ['x-a-pre,in-a']);
  });

  test('a tools node runs and streams', () async {
    final node = await ToolsNode.create(ToolsNodeConfig(tools: [_Echo()]));
    final message = Message.assistant(
      '',
      toolCalls: const [
        ToolCall(id: '1', function: FunctionCall(name: 'echo', arguments: '{}')),
        ToolCall(id: '2', function: FunctionCall(name: 'echo', arguments: '[]')),
      ],
    );
    final out = await node.invoke(ctx, message);
    expect(out.map((m) => m.content), ['echo:{}', 'echo:[]']);
    expect(out.map((m) => m.toolCallId), ['1', '2']);

    final chunks = await (await node.stream(ctx, message)).collectAll();
    expect(chunks, hasLength(2));
    expect(
      concatMessageArray(chunks).map((m) => m.content),
      ['echo:{}', 'echo:[]'],
    );
  });

  test('cycles stop at the step limit', () async {
    final graph = Graph<int, int>()
      ..addLambdaNode('inc', Lambda<int, int>.invokable((ctx, i) => i + 1))
      ..addEdge(Graph.start, 'inc')
      ..addBranch(
        'inc',
        GraphBranch.single<int>(
          (ctx, i) => i < 3 ? 'inc' : Graph.end,
          {'inc', Graph.end},
        ),
      );
    final runnable = await graph.compile(ctx);
    expect(await runnable.invoke(ctx, 0), 3);

    final endless = Graph<int, int>()
      ..addLambdaNode('inc', Lambda<int, int>.invokable((ctx, i) => i + 1))
      ..addEdge(Graph.start, 'inc')
      ..addBranch(
        'inc',
        GraphBranch.single<int>((ctx, i) => 'inc', {'inc', Graph.end}),
      );
    final never = await endless.compile(
      ctx,
      options: const GraphCompileOptions(maxRunSteps: 5),
    );
    await expectLater(
      never.invoke(ctx, 0),
      throwsA(
        isA<GraphRunException>().having(
          (e) => ThreepioException.findCause<ExceedMaxStepsException>(e),
          'cause',
          isNotNull,
        ),
      ),
    );
  });
}
