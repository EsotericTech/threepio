// Behaviour of the graph engine that the ported Go tests do not pin: how
// failures are wrapped and ordered, what a failing observer does, and how
// the types of an inline lambda are found.
import 'package:logging/logging.dart';
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import '../support/log_capture.dart';

final class _Pause implements InterruptSignal {
  const _Pause();
}

final class _ThrowingCallback implements GraphCompileCallback {
  @override
  void onFinish(RunContext ctx, GraphInfo info) => throw StateError('observer');
}

/// A tool that runs a compiled graph and lets its failure pass.
final class _GraphTool extends InvokableTool {
  _GraphTool(this.inner);

  final Runnable<String, String> inner;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.function(name: 'inner', description: 'runs a graph');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) =>
      inner.invoke(ctx, argumentsJson);
}

final class _Recorder extends ComponentCallbackHandler {
  final List<String> names = [];

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    names.add(info.name);
    return ctx;
  }
}

void main() {
  final ctx = RunContext.background();

  Future<Runnable<String, String>> failing() => (Graph<String, String>()
        ..addLambdaNode(
          'bad',
          Lambda.invokable((ctx, String s) => throw const FormatException('no')),
        )
        ..addEdge(Graph.start, 'bad')
        ..addEdge('bad', Graph.end))
      .compile(ctx);

  group('failures', () {
    tearDown(ValuesMerge.reset);

    test('an error of any type between two steps fails the run as a '
        'GraphRunException', () async {
      // Not a ThreepioException: thrown by a merge function of the user.
      ValuesMerge.register<int>((values) => throw const FormatException('x'));
      final runnable = await (Graph<String, int>()
            ..addLambdaNode('a', Lambda.invokable((ctx, String s) => 1))
            ..addLambdaNode('b', Lambda.invokable((ctx, String s) => 2))
            ..addEdge(Graph.start, 'a')
            ..addEdge(Graph.start, 'b')
            ..addEdge('a', Graph.end)
            ..addEdge('b', Graph.end))
          .compile(ctx);

      await expectLater(
        runnable.invoke(ctx, 'x'),
        throwsA(
          isA<GraphRunException>()
              .having((e) => e.kind, 'kind', 'GraphRunError')
              .having(
                (e) => e.message,
                'message',
                allOf(
                  startsWith('failed to calculate next tasks: '),
                  contains('get value from ready channel[end] fail'),
                  contains('FormatException: x'),
                ),
              )
              .having(
                (e) => _rootCause(e),
                'root cause',
                isA<FormatException>(),
              ),
        ),
      );
    });

    test('a branch condition that throws an Error fails the run', () async {
      final runnable = await (Graph<String, String>()
            ..addLambdaNode('a', Lambda.invokable((ctx, String s) => s))
            ..addEdge(Graph.start, 'a')
            ..addBranch(
              'a',
              GraphBranch.single<String>(
                (ctx, s) => throw StateError('lost'),
                {Graph.end},
              ),
            ))
          .compile(ctx);

      await expectLater(
        runnable.invoke(ctx, 'x'),
        throwsA(
          isA<GraphRunException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('calculate next step fail, node: a'),
              contains('branch invoke run error'),
              contains('lost'),
            ),
          ),
        ),
      );
    });

    test('the failure of a graph run inside a tool keeps its path', () async {
      final tools = ToolsNode(
        ToolsNodeConfig(tools: [_GraphTool(await failing())]),
      );
      final outer = await (Chain<Message, List<Message>>()
            ..appendToolsNode(tools, options: const NodeOptions(key: 'tools')))
          .compile(ctx);

      await expectLater(
        outer.invoke(
          ctx,
          Message.assistant(
            '',
            toolCalls: const [
              ToolCall(
                id: '1',
                function: FunctionCall(name: 'inner', arguments: 'x'),
              ),
            ],
          ),
        ),
        throwsA(
          isA<NodeExecutionException>()
              // Through the tools node into the graph the tool ran.
              .having((e) => e.nodePath.path, 'path', ['tools', 'bad'])
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    });

    test('a lambda that wraps the failure of a nested run keeps its path',
        () async {
      final inner = await failing();
      final outer = await (Chain<String, String>()
            ..appendLambda(
              Lambda.invokable((ctx, String s) async {
                try {
                  return await inner.invoke(ctx, s);
                } on GraphRunException catch (error) {
                  throw ThreepioException('wrapped', cause: error);
                }
              }),
            ))
          .compile(ctx);

      await expectLater(
        outer.invoke(ctx, 'x'),
        throwsA(
          isA<NodeExecutionException>()
              .having((e) => e.nodePath.path, 'path', ['node_0', 'bad']),
        ),
      );
    });

    test('an ordinary failure comes before an interrupt of the same step',
        () async {
      Future<Runnable<String, Map<String, Object?>>> build({
        required bool failSecond,
      }) =>
          (Graph<String, Map<String, Object?>>()
                ..addLambdaNode(
                  'pause',
                  Lambda<String, String>.invokable(
                    (ctx, s) => throw const _Pause(),
                  ),
                  options: const NodeOptions(outputKey: 'p'),
                )
                ..addLambdaNode(
                  'fail',
                  Lambda<String, String>.invokable(
                    (ctx, s) => failSecond ? throw StateError('boom') : s,
                  ),
                  options: const NodeOptions(outputKey: 'f'),
                )
                ..addEdge(Graph.start, 'pause')
                ..addEdge(Graph.start, 'fail')
                ..addEdge('pause', Graph.end)
                ..addEdge('fail', Graph.end))
              .compile(ctx);

      await expectLater(
        (await build(failSecond: true)).invoke(ctx, 'x'),
        throwsA(
          isA<NodeExecutionException>()
              .having((e) => e.nodePath.path, 'path', ['fail']),
        ),
      );
      // Alone, the interrupt passes unwrapped.
      await expectLater(
        (await build(failSecond: false)).invoke(ctx, 'x'),
        throwsA(isA<_Pause>()),
      );
    });

    test('processState fails its future, it does not throw at the call',
        () async {
      final future = processState<List<String>>(ctx, (ctx, state) {});
      await expectLater(future, throwsStateError);
    });
  });

  group('observers', () {
    test('a compile callback that throws is logged and the graph compiles',
        () async {
      final records = captureLogs('threepio.compose');
      final graph = Graph<String, String>()
        ..addLambdaNode('a', Lambda.invokable((ctx, String s) => s))
        ..addEdge(Graph.start, 'a')
        ..addEdge('a', Graph.end);

      final runnable = await graph.compile(
        ctx,
        options: GraphCompileOptions(compileCallbacks: [_ThrowingCallback()]),
      );

      expect(await runnable.invoke(ctx, 'x'), 'x');
      expect(records, hasLength(1));
      expect(records.single.level, Level.WARNING);
      expect(records.single.message, contains('_ThrowingCallback'));
      expect(records.single.error, isA<StateError>());
    });

    test('a tools node run on its own takes the callbacks of the call',
        () async {
      final recorder = _Recorder();
      final inner = await (Chain<String, String>()
            ..appendLambda(Lambda.invokable((ctx, String s) => s)))
          .compile(ctx);
      final tools = ToolsNode(ToolsNodeConfig(tools: [_GraphTool(inner)]));

      await tools.invoke(
        ctx,
        Message.assistant(
          '',
          toolCalls: const [
            ToolCall(
              id: '1',
              function: FunctionCall(name: 'inner', arguments: 'x'),
            ),
          ],
        ),
        options: [
          CallOption.callbacks([recorder]).designateNode(['ignored']),
          CallOption.runtimeMaxSteps(3),
        ],
      );

      // The tool, and the graph it ran with the same context.
      expect(recorder.names.first, 'inner');
      expect(recorder.names, hasLength(greaterThan(1)));
    });
  });

  group('an inline lambda', () {
    test('gets its types from its function', () async {
      // No type arguments anywhere: String -> int -> String are found from
      // the parameter types, and the edges are checked with them.
      final runnable = await (Chain<String, String>()
            ..appendLambda(Lambda.invokable((ctx, String s) => s.length))
            ..appendParallel(
              Parallel()
                ..addLambda('double', Lambda.invokable((ctx, int i) => i * 2))
                ..addLambda('text', Lambda.invokable((ctx, int i) => '$i')),
            )
            ..appendLambda(
              Lambda.invokable(
                (ctx, Map<String, Object?> m) => '${m['double']}/${m['text']}',
              ),
            )
            ..appendBranch(
              ChainBranch.single<String>((ctx, s) => 'keep')
                ..addLambda('keep', Lambda.invokable((ctx, String s) => s))
                ..addLambda('drop', Lambda.invokable((ctx, String s) => '')),
            ))
          .compile(ctx);

      expect(await runnable.invoke(ctx, 'abc'), '6/3');
    });

    test('with typed functions that do not fit is a build error', () async {
      final graph = Graph<String, String>()
        ..addLambdaNode('a', Lambda.invokable((ctx, String s) => s.length));
      expect(
        () => graph
          ..addLambdaNode('b', Lambda.invokable((ctx, String s) => s))
          ..addEdge('a', 'b'),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            "graph edge[a]-[b]: start node's output type[int] and end node's "
                'input type[String] mismatch',
          ),
        ),
      );
    });
  });
}

Object? _rootCause(Object error) {
  Object? current = error;
  while (current is ThreepioException && current.cause != null) {
    current = current.cause;
  }
  return current;
}
