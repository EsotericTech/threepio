// Port of eino `compose/graph_test.go` (v0.9.22), the tests:
// TestSingleGraph, TestGraphWithImplementableType, TestNestedGraph,
// TestValidate, TestValidateMultiAnyValueBranch, TestAnyTypeWithKey,
// TestInputKey, TestInputKeyError, TestPregelEnd, TestGraphCompileCallback.
//
// Go's `map[string]any` is `Map<String, Object?>`, `any` is `Object?`. Error
// texts are compared with the Dart type names in place of Go's.
import 'package:test/test.dart';
import 'package:threepio_core/src/compose/stream_conversion.dart'
    show concatStreamReader;
import 'package:threepio_core/threepio_core.dart';

import '../support/log_capture.dart';

/// Go: `type chatModel struct{ msgs []*schema.Message }`.
final class _ChatModel extends BaseChatModel {
  _ChatModel(this.msgs);

  final List<Message> msgs;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      msgs[0];

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final (reader, writer) = pipe<Message>(capacity: msgs.length);
    msgs.forEach(writer.send);
    await writer.close();
    return reader;
  }
}

/// Go: `type person interface{ Say() string }`.
abstract interface class _Person {
  String say();
}

/// Go: `type doctor struct{ say string }`.
final class _Doctor implements _Person {
  const _Doctor(this._say);

  final String _say;

  @override
  String say() => _say;
}

/// Go: the interfaces `A`, `B` and `AB` of TestValidate.
abstract interface class _A {
  void a();
}

abstract interface class _B {
  void b();
}

abstract interface class _AB implements _A, _B {}

/// Go returns `nil` for these interfaces; Dart needs a value.
final class _AbImpl implements _AB {
  const _AbImpl();

  @override
  void a() {}

  @override
  void b() {}
}

/// Go: `type s struct{}`, the state of TestGraphCompileCallback.
final class _S {}

/// Go: `type cb struct{ gInfo *GraphInfo }`.
final class _Cb implements GraphCompileCallback {
  GraphInfo? gInfo;

  @override
  void onFinish(RunContext ctx, GraphInfo info) => gInfo = info;
}

/// Go: `assert.ErrorContains(t, err, text)` for an error of building a graph.
Matcher _buildErrorContaining(String text) => throwsA(
      isA<GraphBuildException>()
          .having((e) => e.toString(), 'toString()', contains(text)),
    );

/// Go: `strings.Contains(err.Error(), text)` for an error of running a graph.
Matcher _runErrorContaining(String text) => throwsA(
      isA<GraphRunException>()
          .having((e) => e.toString(), 'toString()', contains(text)),
    );

/// Go: `for { _, err = s.Recv(); if err == io.EOF { break } }`.
Future<List<T>> _recvAll<T>(StreamReader<T> reader) async {
  final chunks = <T>[];
  while (true) {
    try {
      chunks.add(await reader.recv());
    } on StreamEOFException {
      return chunks;
    }
  }
}

/// Go: `sr, sw := schema.Pipe[T](n); sw.Send(x, nil)…; sw.Close()`.
Future<StreamReader<T>> _pipeOf<T>(int capacity, List<T> chunks) async {
  final (reader, writer) = pipe<T>(capacity: capacity);
  chunks.forEach(writer.send);
  await writer.close();
  return reader;
}

Type _typeOf<T>() => T;

void main() {
  final ctx = RunContext.background();

  setUp(GlobalCallbacks.clear);
  tearDown(GlobalCallbacks.clear);

  test('TestSingleGraph', () async {
    const nodeOfModel = 'model';
    const nodeOfPrompt = 'prompt';

    final g = Graph<Map<String, Object?>, Message>();

    final pt = ChatTemplate.fromMessages(FormatType.fString, [
      Message.user("what's the weather in {location}?"),
    ]);
    g.addChatTemplateNode('prompt', pt);

    final cm = _ChatModel([Message.assistant('the weather is good')]);
    g
      ..addChatModelNode(
        nodeOfModel,
        cm,
        options: const NodeOptions(name: 'MockChatModel'),
      )
      ..addEdge(Graph.start, nodeOfPrompt)
      ..addEdge(nodeOfPrompt, nodeOfModel)
      ..addEdge(nodeOfModel, Graph.end);

    final r = await g.compile(
      RunContext.background(),
      options: const GraphCompileOptions(maxRunSteps: 10),
    );

    var input = <String, Object?>{'location': 'beijing'};
    await r.invoke(ctx, input);

    // stream
    var s = await r.stream(ctx, input);
    await concatStreamReader(s);

    // transform
    s = await r.transform(ctx, await _pipeOf(1, [input]));
    await concatStreamReader(s);

    // error test. Go's `assert.Errorf(t, err, "could not find key:
    // location")` only says that there is an error; the text it names is
    // the text of the Dart error as well.
    input = <String, Object?>{'wrong key': 1};
    const missing = 'could not find key: location';
    await expectLater(
      () => r.invoke(ctx, input),
      _runErrorContaining(missing),
    );
    await expectLater(
      () => r.stream(ctx, input),
      _runErrorContaining(missing),
    );
    final sr = await _pipeOf(1, [input]);
    await expectLater(
      () => r.transform(ctx, sr),
      _runErrorContaining(missing),
    );
  });

  test('TestGraphWithImplementableType', () async {
    const node1 = '1st';
    const node2 = '2nd';

    final g = Graph<String, String>()
      ..addLambdaNode(
        node1,
        Lambda<String, _Doctor>.invokable((ctx, input) => _Doctor(input)),
      )
      ..addLambdaNode(
        node2,
        Lambda<_Person, String>.invokable((ctx, input) => input.say()),
      )
      ..addEdge(Graph.start, node1)
      ..addEdge(node1, node2)
      ..addEdge(node2, Graph.end);

    final r = await g.compile(
      RunContext.background(),
      options: const GraphCompileOptions(maxRunSteps: 10),
    );

    await expectLater(
      () => r.invoke(
        ctx,
        'how are you',
        options: [CallOption.runtimeMaxSteps(1)],
      ),
      _runErrorContaining('exceeds max steps'),
    );
    await expectLater(
      () => r.invoke(
        ctx,
        'how are you',
        options: [CallOption.runtimeMaxSteps(1)],
      ),
      _runErrorContaining('exceeds max steps'),
    );

    final out = await r.invoke(ctx, 'how are you');
    expect(out, 'how are you');

    final outStream = await r.stream(ctx, "i'm fine");
    addTearDown(outStream.close);

    final say = await outStream.recv();
    expect(say, "i'm fine");
  });

  test('TestNestedGraph', () async {
    // In Go a callback that panics fails the test; here a hook that throws is
    // logged, so a logged warning fails the test.
    failOnLoggedWarnings('threepio.callbacks');

    const nodeOfLambda1 = 'lambda1';
    const nodeOfLambda2 = 'lambda2';
    const nodeOfSubGraph = 'sub_graph';
    const nodeOfModel = 'model';
    const nodeOfPrompt = 'prompt';

    final g = Graph<String, Message>();
    final sg = Graph<Map<String, Object?>, Message>();

    final l1 = Lambda<String, Map<String, Object?>>.invokable(
      (ctx, input) => <String, Object?>{'location': input},
    );

    // Go changes `input.Content` in place; a Dart message is immutable.
    final l2 = Lambda<Message, Message>.invokable(
      (ctx, input) =>
          input.copyWith(content: 'after lambda 2: ${input.content}'),
    );

    final pt = ChatTemplate.fromMessages(FormatType.fString, [
      Message.user("what's the weather in {location}?"),
    ]);
    sg.addChatTemplateNode('prompt', pt);

    final cm = _ChatModel([Message.assistant('the weather is good')]);
    sg
      ..addChatModelNode(
        nodeOfModel,
        cm,
        options: const NodeOptions(name: 'MockChatModel'),
      )
      ..addEdge(Graph.start, nodeOfPrompt)
      ..addEdge(nodeOfPrompt, nodeOfModel)
      ..addEdge(nodeOfModel, Graph.end);

    g
      ..addLambdaNode(
        nodeOfLambda1,
        l1,
        options: const NodeOptions(name: 'Lambda1'),
      )
      ..addGraphNode(
        nodeOfSubGraph,
        sg,
        options: const NodeOptions(name: 'SubGraphName'),
      )
      ..addLambdaNode(
        nodeOfLambda2,
        l2,
        options: const NodeOptions(name: 'Lambda2'),
      )
      ..addEdge(Graph.start, nodeOfLambda1)
      ..addEdge(nodeOfLambda1, nodeOfSubGraph)
      ..addEdge(nodeOfSubGraph, nodeOfLambda2)
      ..addEdge(nodeOfLambda2, Graph.end);

    final r = await g.compile(
      RunContext.background(),
      options: const GraphCompileOptions(
        maxRunSteps: 10,
        graphName: 'GraphName',
      ),
    );

    final ck = ContextKey<int>('depth');
    RunContext deeper(RunContext ctx) {
      var v = ctx.value(ck);
      if (v != null) v++;
      return ctx.withValue(ck, v ?? 0);
    }

    final cb = CallbackHandlerBuilder()
        .onStart((ctx, info, input) => deeper(ctx))
        .onStartWithStreamInput((ctx, info, input) async {
      await input.close();
      return deeper(ctx);
    }).build();

    // invoke
    await r.invoke(ctx, 'london', options: [CallOption.callbacks([cb])]);

    // stream
    final rs = await r.stream(
      ctx,
      'london',
      options: [CallOption.callbacks([cb])],
    );
    await _recvAll(rs);

    // collect
    await r.collect(
      ctx,
      await _pipeOf(5, ['london']),
      options: [CallOption.callbacks([cb])],
    );

    // transform
    final rt = await r.transform(
      ctx,
      await _pipeOf(5, ['london']),
      options: [CallOption.callbacks([cb])],
    );
    await _recvAll(rt);
  });

  group('TestValidate', () {
    test('unmatched nodes', () {
      final g = Graph<String, String>()
        ..addLambdaNode(
          '1',
          Lambda<String, String>.invokable((ctx, input) => ''),
        )
        ..addLambdaNode('2', Lambda<int, String>.invokable((ctx, input) => ''));

      expect(
        () => g.addEdge('1', '2'),
        _buildErrorContaining(
          "graph edge[1]-[2]: start node's output type[String] and end "
          "node's input type[int] mismatch",
        ),
      );
    });

    test('unmatched passthrough node', () {
      final g = Graph<String, String>()
        ..addLambdaNode(
          '1',
          Lambda<String, String>.invokable((ctx, input) => ''),
        )
        ..addPassthroughNode('2')
        ..addLambdaNode('3', Lambda<int, String>.invokable((ctx, input) => ''))
        ..addEdge('1', '2');

      expect(
        () => g.addEdge('2', '3'),
        _buildErrorContaining(
          "graph edge[2]-[3]: start node's output type[String] and end "
          "node's input type[int] mismatch",
        ),
      );
    });

    test('may matched passthrough', () async {
      final g2 = Graph<Object?, String>()
        ..addLambdaNode(
          '1',
          Lambda<Object?, Object?>.invokable((ctx, input) => input),
        )
        ..addPassthroughNode('2')
        ..addLambdaNode(
          '3',
          Lambda<int, String>.invokable((ctx, input) => input.toString()),
        )
        ..addEdge(Graph.start, '1')
        ..addEdge('2', '3')
        ..addEdge('1', '2')
        ..addEdge('3', Graph.end);
      final ru = await g2.compile(RunContext.background());

      // success
      final result = await ru.invoke(RunContext.background(), 1);
      expect(result, '1');

      // fail
      await expectLater(
        () => ru.invoke(RunContext.background(), '1'),
        _runErrorContaining('runtime type check'),
      );
    });

    test('unmatched graph type', () {
      final g = Graph<String, String>()
        ..addLambdaNode('1', Lambda<int, String>.invokable((ctx, input) => ''))
        ..addLambdaNode('2', Lambda<String, int>.invokable((ctx, input) => 0))
        ..addEdge('1', '2');

      expect(
        () => g.addEdge(Graph.start, '1'),
        _buildErrorContaining(
          "graph edge[start]-[1]: start node's output type[String] and end "
          "node's input type[int] mismatch",
        ),
      );
    });

    group('sub graph implement', () {
      final lA = Lambda<_A, String>.invokable((ctx, input) => '');
      final lB = Lambda<_B, String>.invokable((ctx, input) => '');
      final lAB = Lambda<String, _AB>.invokable((ctx, input) => const _AbImpl());

      test('a chain of interface types compiles', () async {
        final p = Parallel()
          ..addLambda('1', lA)
          ..addLambda('2', lB);
        final c = Chain<String, Map<String, Object?>>()
          ..appendLambda(lAB)
          ..appendParallel(p);
        await c.compile(RunContext.background());
      });

      test('error usage', () async {
        final p = Parallel()
          ..addLambda('1', lA)
          ..addLambda('2', lAB);
        final c = Chain<String, Map<String, Object?>>()..appendParallel(p);
        await expectLater(
          () => c.compile(RunContext.background()),
          _buildErrorContaining(
            'add parallel edge failed, from=start, to=node_0_parallel_0, '
            "err: graph edge[start]-[node_0_parallel_0]: start node's "
            "output type[String] and end node's input type[_A] mismatch",
          ),
        );
      });
    });

    test('graph output type check', () {
      final gg = Graph<String, _A>()
        ..addLambdaNode(
          'nodeA',
          Lambda<String, _A>.invokable((ctx, input) => const _AbImpl()),
        )
        ..addLambdaNode(
          'nodeA2',
          Lambda<String, _A>.invokable((ctx, input) => const _AbImpl()),
        )
        ..addLambdaNode(
          'nodeB',
          Lambda<String, _B>.invokable((ctx, input) => const _AbImpl()),
        )
        ..addEdge('nodeA', Graph.end);

      const mismatch =
          "graph edge[nodeB]-[end]: start node's output type[_B] and end "
          "node's input type[_A] mismatch";
      expect(
        () => gg.addEdge('nodeB', Graph.end),
        _buildErrorContaining(mismatch),
      );
      // The first build error sticks to the graph.
      expect(
        () => gg.addEdge('nodeA2', Graph.end),
        _buildErrorContaining(mismatch),
      );
    });

    test('any type', () async {
      final anyG = Graph<Object?, String>()
        ..addLambdaNode(
          'node1',
          Lambda<String, Object?>.invokable((ctx, input) => '${input}node1'),
        )
        ..addLambdaNode(
          'node2',
          Lambda<String, Object?>.invokable((ctx, input) => '${input}node2'),
        )
        ..addEdge(Graph.start, 'node1')
        ..addEdge('node1', 'node2')
        ..addEdge('node2', Graph.end);
      final r = await anyG.compile(RunContext.background());

      final result = await r.invoke(RunContext.background(), 'start');
      expect(result, 'startnode1node2');

      final streamResult = await r.stream(RunContext.background(), 'start');
      expect((await _recvAll(streamResult)).join(), 'startnode1node2');
    });

    test('any type runtime error', () async {
      final anyG = Graph<Object?, String>()
        ..addLambdaNode(
          'node1',
          Lambda<String, Object?>.invokable((ctx, input) => 123),
        )
        ..addLambdaNode(
          'node2',
          Lambda<String, Object?>.invokable((ctx, input) => '${input}node2'),
        )
        ..addEdge(Graph.start, 'node1')
        ..addEdge('node1', 'node2')
        ..addEdge('node2', Graph.end);
      final r = await anyG.compile(RunContext.background());

      await expectLater(
        () => r.invoke(RunContext.background(), 'start'),
        _runErrorContaining('runtime'),
      );
      await expectLater(
        () => r.stream(RunContext.background(), 'start'),
        _runErrorContaining('runtime'),
      );
    });

    /// The graph of the two "branch any type" sections; they differ in what
    /// `node1` returns.
    Graph<String, String> branchGraph(Object? Function(String input) node1) =>
        Graph<String, String>()
          ..addLambdaNode(
            'node1',
            Lambda<String, Object?>.invokable((ctx, input) => node1(input)),
          )
          ..addLambdaNode(
            'node2',
            Lambda<String, Object?>.invokable((ctx, input) => '${input}node2'),
          )
          ..addLambdaNode(
            'node3',
            Lambda<String, Object?>.invokable((ctx, input) => '${input}node3'),
          )
          ..addBranch(
            'node1',
            GraphBranch.single<String>(
              (ctx, input) => 'node2',
              {'node2', 'node3'},
            ),
          )
          ..addEdge(Graph.start, 'node1')
          ..addEdge('node2', Graph.end)
          ..addEdge('node3', Graph.end);

    test('branch any type: success', () async {
      final g = branchGraph((input) => '${input}node1');
      final rr = await g.compile(RunContext.background());

      final ret = await rr.invoke(RunContext.background(), 'start');
      expect(ret, 'startnode1node2');

      final streamResult = await rr.stream(RunContext.background(), 'start');
      expect(await concatStreamReader(streamResult), 'startnode1node2');
    });

    test('branch any type: fail', () async {
      final g = branchGraph((input) => 1 /* error type */);
      final rr = await g.compile(RunContext.background());

      await expectLater(
        () => rr.invoke(RunContext.background(), 'start'),
        _runErrorContaining('runtime'),
      );
      await expectLater(
        () => rr.stream(RunContext.background(), 'start'),
        _runErrorContaining('runtime'),
      );
    });
  });

  group('TestValidateMultiAnyValueBranch', () {
    /// The graph of both sections; they differ in the second branch.
    Graph<String, Map<String, Object?>> graphWith(GraphBranch second) {
      final g = Graph<String, Map<String, Object?>>()
        ..addLambdaNode(
          'node1',
          Lambda<String, Object?>.invokable((ctx, input) => '${input}node1'),
        );
      for (final key in ['node2', 'node3', 'node4', 'node5']) {
        g.addLambdaNode(
          key,
          Lambda<String, Map<String, Object?>>.invokable(
            (ctx, input) => <String, Object?>{key: true},
          ),
        );
      }
      return g
        ..addBranch(
          'node1',
          GraphBranch.single<String>(
            (ctx, input) => 'node2',
            {'node2', 'node3'},
          ),
        )
        ..addBranch('node1', second)
        ..addEdge(Graph.start, 'node1')
        ..addEdge('node2', Graph.end)
        ..addEdge('node3', Graph.end)
        ..addEdge('node4', Graph.end)
        ..addEdge('node5', Graph.end);
    }

    test('success', () async {
      final g = graphWith(
        GraphBranch.single<String>((ctx, input) => 'node4', {'node4', 'node5'}),
      );
      final rr = await g.compile(RunContext.background());

      var ret = await rr.invoke(RunContext.background(), 'start');
      expect(ret['node2'], isTrue);
      expect(ret['node4'], isTrue);

      final streamResult = await rr.stream(RunContext.background(), 'start');
      ret = await concatStreamReader(streamResult);
      expect(ret['node2'], isTrue);
      expect(ret['node4'], isTrue);
    });

    test('fail', () async {
      final g = graphWith(
        GraphBranch.single<int /* error type */ >(
          (ctx, input) => 'node4',
          {'node4', 'node5'},
        ),
      );
      final rr = await g.compile(RunContext.background());

      await expectLater(
        () => rr.invoke(RunContext.background(), 'start'),
        _runErrorContaining('runtime'),
      );
      await expectLater(
        () => rr.stream(RunContext.background(), 'start'),
        _runErrorContaining('runtime'),
      );
    });
  });

  test('TestAnyTypeWithKey', () async {
    final g = Graph<Object?, Map<String, Object?>>()
      ..addLambdaNode(
        'node1',
        Lambda<String, Object?>.invokable((ctx, input) => '${input}node1'),
        options: const NodeOptions(inputKey: 'node1'),
      )
      ..addLambdaNode(
        'node2',
        Lambda<String, Object?>.invokable((ctx, input) => '${input}node2'),
        options: const NodeOptions(outputKey: 'node2'),
      )
      ..addEdge(Graph.start, 'node1')
      ..addEdge('node1', 'node2')
      ..addEdge('node2', Graph.end);
    final r = await g.compile(RunContext.background());

    final result = await r.invoke(
      RunContext.background(),
      <String, Object?>{'node1': 'start'},
    );
    expect(result['node2'], 'startnode1node2');

    final streamResult = await r.stream(
      RunContext.background(),
      <String, Object?>{'node1': 'start'},
    );
    final ret = await concatStreamReader(streamResult);
    expect(ret['node2'], 'startnode1node2');
  });

  test('TestInputKey', () async {
    final g = Graph<Map<String, Object?>, Map<String, Object?>>();
    for (final key in ['1', '2', '3']) {
      g.addChatTemplateNode(
        key,
        ChatTemplate.fromMessages(
          FormatType.fString,
          [Message.user('{var$key}')],
        ),
        options: NodeOptions(outputKey: key, inputKey: key),
      );
    }
    g
      ..addEdge(Graph.start, '1')
      ..addEdge(Graph.start, '2')
      ..addEdge(Graph.start, '3')
      ..addEdge('1', Graph.end)
      ..addEdge('2', Graph.end)
      ..addEdge('3', Graph.end);
    final r = await g.compile(
      RunContext.background(),
      options: const GraphCompileOptions(maxRunSteps: 100),
    );

    var result = await r.invoke(ctx, <String, Object?>{
      '1': <String, Object?>{'var1': 'a'},
      '2': <String, Object?>{'var2': 'b'},
      '3': <String, Object?>{'var3': 'c'},
    });
    expect((result['1']! as List<Message>)[0].content, 'a');
    expect((result['2']! as List<Message>)[0].content, 'b');
    expect((result['3']! as List<Message>)[0].content, 'c');

    final sr = await _pipeOf<Map<String, Object?>>(10, [
      {
        '1': <String, Object?>{'var1': 'a'},
      },
      {
        '2': <String, Object?>{'var2': 'b'},
      },
      {
        '3': <String, Object?>{'var3': 'c'},
      },
    ]);
    final streamResult = await r.transform(ctx, sr);
    addTearDown(streamResult.close);

    result = <String, Object?>{};
    (await _recvAll(streamResult)).forEach(result.addAll);
    expect((result['1']! as List<Message>)[0].content, 'a');
    expect((result['2']! as List<Message>)[0].content, 'b');
    expect((result['3']! as List<Message>)[0].content, 'c');
  });

  test('TestInputKeyError', () async {
    final g = Graph<Map<String, Object?>, String>()
      ..addLambdaNode(
        'node1',
        Lambda<String, String>.invokable((ctx, input) => input),
        options: const NodeOptions(inputKey: 'node1'),
      )
      ..addEdge(Graph.start, 'node1')
      ..addEdge('node1', Graph.end);
    final r = await g.compile(ctx);

    // invoke
    await expectLater(
      () => r.invoke(ctx, <String, Object?>{'unknown': '123'}),
      _runErrorContaining('cannot find input key: node1'),
    );

    // transform
    final sr = await _pipeOf(1, [
      <String, Object?>{'unknown': '123'},
    ]);
    await expectLater(
      () => r.transform(ctx, sr),
      _runErrorContaining('stream reader is empty, concat fail'),
    );
  });

  test('TestPregelEnd', () async {
    final g = Graph<String, String>()
      ..addLambdaNode(
        'node1',
        Lambda<String, String>.invokable((ctx, input) => 'node1'),
      )
      ..addLambdaNode(
        'node2',
        Lambda<String, String>.invokable((ctx, input) => 'node2'),
      )
      ..addEdge(Graph.start, 'node1')
      ..addEdge('node1', Graph.end)
      ..addEdge('node1', 'node2')
      ..addEdge('node2', Graph.end);
    final runner = await g.compile(RunContext.background());

    final out = await runner.invoke(RunContext.background(), '');
    expect(out, 'node1');
  });

  group('TestGraphCompileCallback', () {
    const lambdaOpts = NodeOptions(name: 'lambda_1', inputKey: 'input_key');
    const lambdaOpts2 = NodeOptions(name: 'lambda_2');
    const lambdaOpts3 = NodeOptions(name: 'lambda_3', outputKey: 'lambda_3');
    const lambdaOpts4 = NodeOptions(name: 'lambda_4', outputKey: 'lambda_4');
    // Go: `var ssGraphCompileOpts []GraphCompileOption`, no options.
    const ssGraphCompileOpts = GraphCompileOptions();
    const ssGraphOpts = NodeOptions(compileOptions: ssGraphCompileOpts);
    const subGraphCompileOpts =
        GraphCompileOptions(maxRunSteps: 2, graphName: 'sub_graph');
    const subGraphOpts = NodeOptions(compileOptions: subGraphCompileOpts);

    late Lambda<String, String> lambda;
    late Lambda<String, String> lambda2;
    late Lambda<String, String> lambda3;
    late Lambda<String, String> lambda4;
    late GraphBranch branch;
    late Graph<String, String> subSubGraph;
    late Graph<String, String> subGraph;
    late _Cb c;
    late GraphCompileOptions opt;

    setUp(() async {
      final g = Graph<Map<String, Object?>, Map<String, Object?>>(
        localState: LocalState.of<_S>((ctx) => _S()),
      );

      lambda = Lambda<String, String>.invokable((ctx, input) => 'node1');
      g
        ..addLambdaNode('node1', lambda, options: lambdaOpts)
        ..addPassthroughNode('pass1')
        ..addPassthroughNode('pass2');

      branch = GraphBranch.single<String>(
        (ctx, input) => input,
        {'pass1', 'pass2'},
      );
      g
        ..addBranch('node1', branch)
        ..addEdge(Graph.start, 'node1');

      lambda2 = Lambda<String, String>.invokable((ctx, input) => 'node2');
      subSubGraph = Graph<String, String>()
        ..addLambdaNode('sub1', lambda2, options: lambdaOpts2)
        ..addEdge(Graph.start, 'sub1')
        ..addEdge('sub1', Graph.end);

      subGraph = Graph<String, String>()
        ..addGraphNode('sub_sub_1', subSubGraph, options: ssGraphOpts)
        ..addEdge(Graph.start, 'sub_sub_1')
        ..addEdge('sub_sub_1', Graph.end);

      g
        ..addGraphNode('sub_graph', subGraph, options: subGraphOpts)
        ..addEdge('pass1', 'sub_graph')
        ..addEdge('pass2', 'sub_graph');

      lambda3 = Lambda<String, String>.invokable((ctx, input) => 'node3');
      g.addLambdaNode('node3', lambda3, options: lambdaOpts3);

      lambda4 = Lambda<String, String>.invokable((ctx, input) => 'node4');
      g
        ..addLambdaNode('node4', lambda4, options: lambdaOpts4)
        ..addEdge('sub_graph', 'node3')
        ..addEdge('sub_graph', 'node4')
        ..addEdge('node3', Graph.end)
        ..addEdge('node4', Graph.end);

      c = _Cb();
      opt = GraphCompileOptions(
        compileCallbacks: [c],
        graphName: 'top_level',
      );
      await g.compile(RunContext.background(), options: opt);
    });

    // Go compares the info with one expected struct; here the same facts are
    // asserted field by field.
    test('graph compile callback', () {
      final info = c.gInfo!;

      // Go: `GenStateFn` and `NewGraphOptions`; the one option of the Dart
      // graph is its local state.
      final localState = info.localState;
      expect(localState, isNotNull);
      expect(localState!.create(RunContext.background()), isA<_S>());

      // The compile options: the callback is the one that was given, the
      // rest is equal.
      final actualCompileOptions = info.compileOptions!;
      expect(actualCompileOptions.compileCallbacks, hasLength(1));
      expect(actualCompileOptions.compileCallbacks[0], same(c));
      expect(actualCompileOptions.graphName, 'top_level');
      expect(actualCompileOptions.maxRunSteps, isNull);
      expect(actualCompileOptions.nodeTriggerMode, isNull);
      expect(actualCompileOptions.fanInMergeConfig, isEmpty);
      expect(actualCompileOptions.eagerExecutionDisabled, isFalse);
      expect(actualCompileOptions.checkpointStore, isNull);
      expect(actualCompileOptions.serializer, isNull);
      expect(actualCompileOptions.interruptBeforeNodes, isEmpty);
      expect(actualCompileOptions.interruptAfterNodes, isEmpty);

      // The branch.
      expect(info.branches.keys, ['node1']);
      expect(info.branches['node1'], hasLength(1));
      expect(info.branches['node1']![0].endNodes, branch.endNodes);
      expect(info.branches['node1']![0].endNodes, {'pass1', 'pass2'});
      expect(
        info.branches['node1']![0].inputType.type,
        branch.inputType.type,
      );
      expect(info.branches['node1']![0].inputType.type, String);

      // The graph itself.
      expect(info.name, 'top_level');
      expect(info.component, ComponentType.graph);
      expect(info.inputType, _typeOf<Map<String, Object?>>());
      expect(info.outputType, _typeOf<Map<String, Object?>>());
      expect(info.edges, {
        Graph.start: ['node1'],
        'pass1': ['sub_graph'],
        'pass2': ['sub_graph'],
        'sub_graph': ['node3', 'node4'],
        'node3': [Graph.end],
        'node4': [Graph.end],
      });
      expect(info.dataEdges, {
        Graph.start: ['node1'],
        'pass1': ['sub_graph'],
        'pass2': ['sub_graph'],
        'sub_graph': ['node3', 'node4'],
        'node3': [Graph.end],
        'node4': [Graph.end],
      });

      // The nodes.
      expect(
        info.nodes.keys,
        unorderedEquals(
          ['node1', 'pass1', 'pass2', 'sub_graph', 'node3', 'node4'],
        ),
      );

      final node1 = info.nodes['node1']!;
      expect(node1.component, ComponentType.lambda);
      expect(node1.isPassthrough, isFalse);
      expect(node1.instance, same(lambda));
      expect(node1.options, same(lambdaOpts));
      expect(node1.inputType, String);
      expect(node1.outputType, String);
      expect(node1.name, 'lambda_1');
      expect(node1.inputKey, 'input_key');
      expect(node1.outputKey, '');
      expect(node1.graphInfo, isNull);

      // Intended deviation: there is no passthrough component kind,
      // `isPassthrough` says it.
      for (final key in ['pass1', 'pass2']) {
        final pass = info.nodes[key]!;
        expect(pass.isPassthrough, isTrue, reason: key);
        expect(pass.instance, isNull, reason: key);
        expect(pass.inputType, String, reason: key);
        expect(pass.outputType, String, reason: key);
        expect(pass.name, '', reason: key);
        expect(pass.inputKey, '', reason: key);
        expect(pass.outputKey, '', reason: key);
        expect(pass.graphInfo, isNull, reason: key);
      }

      final node3 = info.nodes['node3']!;
      expect(node3.component, ComponentType.lambda);
      expect(node3.isPassthrough, isFalse);
      expect(node3.instance, same(lambda3));
      expect(node3.options, same(lambdaOpts3));
      expect(node3.inputType, String);
      expect(node3.outputType, String);
      expect(node3.name, 'lambda_3');
      expect(node3.inputKey, '');
      expect(node3.outputKey, 'lambda_3');
      expect(node3.graphInfo, isNull);

      final node4 = info.nodes['node4']!;
      expect(node4.component, ComponentType.lambda);
      expect(node4.isPassthrough, isFalse);
      expect(node4.instance, same(lambda4));
      expect(node4.options, same(lambdaOpts4));
      expect(node4.inputType, String);
      expect(node4.outputType, String);
      expect(node4.name, 'lambda_4');
      expect(node4.inputKey, '');
      expect(node4.outputKey, 'lambda_4');
      expect(node4.graphInfo, isNull);

      final subGraphNode = info.nodes['sub_graph']!;
      expect(subGraphNode.component, ComponentType.graph);
      expect(subGraphNode.isPassthrough, isFalse);
      expect(subGraphNode.instance, same(subGraph));
      expect(subGraphNode.options, same(subGraphOpts));
      expect(subGraphNode.inputType, String);
      expect(subGraphNode.outputType, String);
      expect(subGraphNode.name, '');
      expect(subGraphNode.inputKey, '');
      expect(subGraphNode.outputKey, '');

      // The nested graph.
      final sub = subGraphNode.graphInfo!;
      expect(sub.name, 'sub_graph');
      expect(sub.compileOptions?.maxRunSteps, 2);
      expect(sub.compileOptions?.graphName, 'sub_graph');
      expect(sub.inputType, String);
      expect(sub.outputType, String);
      expect(sub.localState, isNull);
      expect(sub.branches, isEmpty);
      expect(sub.edges, {
        Graph.start: ['sub_sub_1'],
        'sub_sub_1': [Graph.end],
      });
      expect(sub.dataEdges, {
        Graph.start: ['sub_sub_1'],
        'sub_sub_1': [Graph.end],
      });
      expect(sub.nodes.keys, ['sub_sub_1']);

      final subSubNode = sub.nodes['sub_sub_1']!;
      expect(subSubNode.component, ComponentType.graph);
      expect(subSubNode.isPassthrough, isFalse);
      expect(subSubNode.instance, same(subSubGraph));
      expect(subSubNode.options, same(ssGraphOpts));
      expect(subSubNode.inputType, String);
      expect(subSubNode.outputType, String);
      expect(subSubNode.name, '');
      expect(subSubNode.inputKey, '');
      expect(subSubNode.outputKey, '');

      // The graph nested in the nested graph.
      final subSub = subSubNode.graphInfo!;
      expect(subSub.name, '');
      expect(subSub.compileOptions?.maxRunSteps, isNull);
      expect(subSub.compileOptions?.graphName ?? '', '');
      expect(subSub.inputType, String);
      expect(subSub.outputType, String);
      expect(subSub.localState, isNull);
      expect(subSub.branches, isEmpty);
      expect(subSub.edges, {
        Graph.start: ['sub1'],
        'sub1': [Graph.end],
      });
      expect(subSub.dataEdges, {
        Graph.start: ['sub1'],
        'sub1': [Graph.end],
      });
      expect(subSub.nodes.keys, ['sub1']);

      final sub1 = subSub.nodes['sub1']!;
      expect(sub1.component, ComponentType.lambda);
      expect(sub1.isPassthrough, isFalse);
      expect(sub1.instance, same(lambda2));
      expect(sub1.options, same(lambdaOpts2));
      expect(sub1.inputType, String);
      expect(sub1.outputType, String);
      expect(sub1.name, 'lambda_2');
      expect(sub1.inputKey, '');
      expect(sub1.outputKey, '');
      expect(sub1.graphInfo, isNull);
    });

    // Go: `CompileOptions: subGraphCompileOpts` and `CompileOptions:
    // ssGraphCompileOpts` in the expected struct: the info of a nested graph
    // reports the compile options its node was added with, and nothing else.
    test(
      'graph compile callback: compile options of the nested graphs',
      () {
        final sub = c.gInfo!.nodes['sub_graph']!.graphInfo!;
        expect(sub.compileOptions?.maxRunSteps, 2);
        expect(sub.compileOptions?.graphName, 'sub_graph');
        expect(sub.compileOptions?.compileCallbacks ?? const [], isEmpty);

        final subSub = sub.nodes['sub_sub_1']!.graphInfo!;
        expect(subSub.compileOptions?.maxRunSteps, isNull);
        expect(subSub.compileOptions?.graphName ?? '', '');
        expect(subSub.compileOptions?.compileCallbacks ?? const [], isEmpty);
      },
    );
  });
}
