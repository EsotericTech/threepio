// Port of eino `compose/chain_test.go` and `compose/chain_branch_test.go`
// (v0.9.22).
//
// The gomock mocks of the Go tests (MockChatModel, MockEmbedder, MockIndexer,
// MockRetriever, MockLoader, MockTransformer) and `mockIntentChatModel` of
// `tool_node_test.go` are the hand-written fakes below. Go reads the build
// error of a chain or a parallel from a private field (`c.err`, `p.err`);
// a Dart `Chain` throws it from `compile`, a `Parallel` shows it as `error`.
//
// Lines marked "Dart extra" assert more than the Go test does. Where Go only
// checks that building fails, the text Go's source gives the error is checked
// as well, so that a test cannot pass for the wrong reason.

import 'package:test/test.dart';
import 'package:threepio_core/src/compose/stream_conversion.dart'
    show concatStreamReader;
import 'package:threepio_core/threepio_core.dart';

typedef _Kvs = Map<String, Object?>;

const _toolNameOfUserCompany = 'user_company';
const _toolIdOfUserCompany = 'call_TRZhlagwBS0LpWbWPeZOvIXc';
const _toolNameOfUserSalary = 'user_salary';
const _toolIdOfUserSalary = 'call_AqfoRW6fuF98k0o7696k2nzm';
const _intentArguments =
    '{"name": "zhangsan", "email": "zhangsan@bytedance.com"}';

/// Go: `mockIntentChatModel` (tool_node_test.go). Records what it was asked.
final class _IntentChatModel extends BaseChatModel {
  final List<List<Message>> inputs = [];

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    inputs.add(input);
    return Message.assistant(
      '',
      toolCalls: const [
        ToolCall(
          id: _toolIdOfUserCompany,
          function: FunctionCall(
            name: _toolNameOfUserCompany,
            arguments: _intentArguments,
          ),
        ),
        ToolCall(
          id: _toolIdOfUserSalary,
          function: FunctionCall(
            name: _toolNameOfUserSalary,
            arguments: _intentArguments,
          ),
        ),
      ],
    );
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    inputs.add(input);
    return StreamReader.fromIterable([
      Message.assistant(
        '',
        toolCalls: const [
          ToolCall(
            id: _toolIdOfUserCompany,
            function: FunctionCall(
              name: _toolNameOfUserCompany,
              arguments: _intentArguments,
            ),
          ),
        ],
      ),
      Message.assistant(
        '',
        toolCalls: const [
          ToolCall(
            id: _toolIdOfUserSalary,
            function: FunctionCall(
              name: _toolNameOfUserSalary,
              arguments: _intentArguments,
            ),
          ),
        ],
      ),
    ]);
  }
}

/// Go: `model.NewMockChatModel`.
final class _FakeChatModel extends BaseChatModel {
  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      Message.assistant('fake');

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([Message.assistant('fake')]);
}

/// Go: `embedding.NewMockEmbedder`.
final class _FakeEmbedder extends Embedder {
  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async =>
      [
        for (final text in texts) [text.length.toDouble()],
      ];
}

/// Go: `retriever.NewMockRetriever`.
final class _FakeRetriever extends Retriever {
  @override
  Future<List<Document>> retrieve(
    String query, {
    RetrieverOptions? options,
  }) async =>
      [Document(content: query)];
}

/// Go: `indexer.NewMockIndexer`.
final class _FakeIndexer implements Indexer {
  @override
  Future<List<String>> store(
    RunContext ctx,
    List<Document> docs, {
    IndexerOptions? options,
  }) async =>
      [for (var i = 0; i < docs.length; i++) 'id$i'];
}

/// Go: `document.NewMockLoader`.
final class _FakeLoader implements Loader {
  @override
  Future<List<Document>> load(
    RunContext ctx,
    DocumentSource source, {
    LoaderOptions? options,
  }) async =>
      [Document(content: source.uri)];
}

/// Go: `document.NewMockTransformer`.
final class _FakeTransformer extends DocumentTransformer {
  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async =>
      documents;
}

final class _EchoTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.function(
        name: 'echo',
        description: 'echoes its arguments',
      );

  @override
  Future<String> run(String argumentsJson) async => 'echo:$argumentsJson';
}

/// Go: `FakeLambdaOptions`, `FakeLambdaOption`, `FakeWithLambdaInfo`.
final class _FakeLambdaOptions {
  String info = '';
}

typedef _FakeLambdaOption = void Function(_FakeLambdaOptions options);

_FakeLambdaOption _fakeWithLambdaInfo(String info) => (options) {
      options.info = info;
    };

String _infoOf(List<_FakeLambdaOption> options) {
  final applied = _FakeLambdaOptions();
  for (final apply in options) {
    apply(applied);
  }
  return applied.info;
}

/// A lambda that hands its map on, as most lambdas of the Go tests do.
Lambda<_Kvs, _Kvs> _pass([void Function(_Kvs kvs)? tap]) =>
    Lambda<_Kvs, _Kvs>.invokable((ctx, kvs) {
      tap?.call(kvs);
      return kvs;
    });

ChatTemplate _rolePlayTemplate() => ChatTemplate.fromMessages(
      FormatType.fString,
      [Message.system('You are a {role}.'), Message.user('{input}')],
    );

Matcher _buildError([String? text]) {
  final matcher = isA<GraphBuildException>();
  return throwsA(
    text == null
        ? matcher
        : matcher.having((e) => e.toString(), 'toString()', contains(text)),
  );
}

Matcher _runError(String text) => throwsA(
      isA<GraphRunException>()
          .having((e) => e.toString(), 'toString()', contains(text)),
    );

/// A node failed with the `fake error` of the Go tests, and the error names
/// the node [key].
Matcher _fakeErrorAt(String key) => throwsA(
      isA<NodeExecutionException>()
          .having((e) => e.toString(), 'toString()', contains(key))
          .having((e) => e.nodePath.path, 'nodePath.path', [key])
          .having((e) => '${e.cause}', 'cause', contains('fake error')),
    );

void main() {
  final ctx = RunContext.background();

  // ---------------------------------------------------------------- chain_test.go

  test('TestChain', () async {
    final model = _IntentChatModel();

    // Go picks the branch with rand.Intn(2). Here the branches take turns, so
    // that two runs cover both.
    var runs = 0;
    String branchCond(RunContext ctx, _Kvs input) =>
        (runs++).isEven ? 'b1' : 'b2';

    final b1 = _pass((kvs) => kvs['role'] = 'cat');
    final b2 = _pass((kvs) => kvs['role'] = 'dog');

    final parallel = Parallel()
      ..addLambda(
        'role',
        Lambda<_Kvs, String>.invokable((ctx, kvs) {
          var role = kvs['role']! as String;
          if (role.isEmpty) role = 'bird';
          return role;
        }),
      )
      ..addLambda(
        'input',
        Lambda<_Kvs, String>.invokable((ctx, kvs) => '你的叫声是怎样的？'),
      );

    final rolePlayChain = Chain<_Kvs, Message>()
      ..appendChatTemplate(_rolePlayTemplate())
      ..appendChatModel(model);

    final chain = Chain<_Kvs, String>()
      ..appendLambda(_pass())
      ..appendBranch(
        ChainBranch.single<_Kvs>(branchCond)
          ..addLambda('b1', b1)
          ..addLambda('b2', b2),
      )
      ..appendPassthrough()
      ..appendParallel(parallel)
      ..appendGraph(rolePlayChain)
      ..appendLambda(Lambda<Message, String>.invokable((ctx, m) => m.content));

    final r = await chain.compile(ctx);

    final out = await r.invoke(ctx, <String, Object?>{});
    // Dart extra: what the mock was asked and what came out.
    expect(out, '');
    expect(model.inputs.single.map((m) => m.content), [
      'You are a cat.',
      '你的叫声是怎样的？',
    ]);

    // Dart extra: the other branch.
    expect(await r.invoke(ctx, <String, Object?>{}), '');
    expect(model.inputs.last.first.content, 'You are a dog.');
  });

  test('TestChainWithException', () async {
    final chain = Chain<_Kvs, String>()
      ..appendLambda(_pass())
      ..appendLambda(_pass(), options: const NodeOptions(key: 'xlam'));

    // items with parallels
    final parallel = Parallel()
      ..addLambda('hello', Lambda<_Kvs, String>.invokable((ctx, kvs) => 'world'))
      ..addLambda('world', Lambda<_Kvs, String>.invokable((ctx, kvs) => 'hello'));

    // sequence items
    final nchain = Chain<_Kvs, _Kvs>()
      ..appendLambda(_pass())
      ..appendLambda(_pass());

    var runs = 0;
    String branchCond(RunContext ctx, _Kvs input) =>
        (runs++).isEven ? 'b1' : 'b2';

    final b1 = _pass((kvs) => kvs['role'] = 'cat');
    final b2 = _pass();

    // sequence with branch
    chain.appendBranch(
      ChainBranch.single<_Kvs>(branchCond)
        ..addLambda('b1', b1)
        ..addLambda('b2', b2),
    );

    // parallel with sequence
    parallel.addGraph('test_sequence', nchain);

    // parallel with parallel
    final npara = Parallel()
      ..addLambda('test_parallel1', _pass())
      ..addLambda('test_parallel2', _pass());

    // parallel with graph
    final ngraph = Chain<_Kvs, _Kvs>()
      ..appendLambda(_pass())
      ..appendLambda(_pass());
    final nc = Chain<_Kvs, _Kvs>()..appendGraph(ngraph);
    parallel.addGraph('test_graph', nc);

    chain.appendPassthrough();

    // sequence with parallel
    chain.appendParallel(npara);

    _Kvs? last;
    chain
      ..appendGraph(nchain)
      ..appendParallel(parallel)
      ..appendLambda(
        Lambda<_Kvs, String>.invokable((ctx, kvs) {
          last = kvs;
          return 'hello last';
        }),
      );

    final r = await chain.compile(ctx);
    final out = await r.invoke(ctx, <String, Object?>{'test': 'test'});
    // Dart extra: the values. Go only checks that there is no error.
    expect(out, 'hello last');
    expect(
      last!.keys,
      unorderedEquals(['hello', 'world', 'test_sequence', 'test_graph']),
    );
    expect(last!['hello'], 'world');
    expect(last!['world'], 'hello');
    expect(
      (last!['test_sequence']! as Map).keys,
      unorderedEquals(['test_parallel1', 'test_parallel2']),
    );
  });

  test('TestEmptyList', () async {
    // no nodes in chain
    await expectLater(
      Chain<_Kvs, _Kvs>().compile(ctx),
      _buildError('pre node keys not set, number of nodes in chain= 0'),
    );

    // no nodes in parallel
    final parallel = Parallel();
    await expectLater(
      (Chain<_Kvs, _Kvs>()..appendParallel(parallel)).compile(ctx),
      _buildError('append parallel invalid, not enough nodes, count = 0'),
    );

    // no nodes in sequence
    final emptyChain = Chain<_Kvs, _Kvs>();
    final chain = Chain<_Kvs, _Kvs>()
      ..appendParallel(parallel)
      ..appendGraph(emptyChain)
      ..appendLambda(_pass());
    await expectLater(
      chain.compile(ctx),
      _buildError('append parallel invalid, not enough nodes, count = 0'),
    );
  });

  test('TestChainList', () async {
    final chain = Chain<_Kvs, _Kvs>()..appendLambda(_pass());

    // parallel
    final parallel = Parallel()..addLambda('test_parallel1', _pass());

    // seq in parallel
    final nchain = Chain<_Kvs, _Kvs>()
      ..appendLambda(_pass())
      ..appendLambda(_pass());

    // seq in seq
    final nchainInChain = Chain<_Kvs, _Kvs>()
      ..appendLambda(_pass())
      ..appendLambda(_pass());

    nchain.appendGraph(nchainInChain);
    parallel.addGraph('test_seq_in_parallel', nchain);
    chain.appendParallel(parallel);

    final r = await chain.compile(ctx);
    final out = await r.invoke(ctx, <String, Object?>{'test': 'test'});
    // Dart extra: the value.
    expect(out, {
      'test_parallel1': {'test': 'test'},
      'test_seq_in_parallel': {'test': 'test'},
    });
  });

  test('TestChainSingleNode', () async {
    final chain = Chain<_Kvs, _Kvs>()..appendLambda(_pass());

    // single Node in chain (prepare for parallel)
    final singleNodeChain = Chain<_Kvs, _Kvs>()..appendLambda(_pass());

    // add parallel
    final parallel = Parallel()
      ..addLambda('test_parallel1_lambda', _pass())
      ..addGraph('test_parallel2_chain', singleNodeChain);

    chain.appendParallel(parallel);
    final r = await chain.compile(ctx);

    final out = await r.invoke(ctx, <String, Object?>{'test': 'test'});
    // Dart extra: the value.
    expect(out, {
      'test_parallel1_lambda': {'test': 'test'},
      'test_parallel2_chain': {'test': 'test'},
    });
  });

  test('TestParallelModels', () async {
    final model = _IntentChatModel();
    final chain = Chain<_Kvs, _Kvs>();
    final chatSuite = Chain<_Kvs, String>()
      ..appendChatTemplate(_rolePlayTemplate())
      ..appendChatModel(model)
      ..appendLambda(
        Lambda<Message, String>.invokable((ctx, msg) => msg.content),
      );

    final parallel = Parallel()
      ..addGraph('time001', chatSuite)
      ..addGraph('time002', chatSuite)
      ..addGraph('time003', chatSuite);

    chain
      ..appendLambda(_pass())
      ..appendParallel(parallel);

    final r = await chain.compile(ctx);

    final out = await r.invoke(
      ctx,
      <String, Object?>{'role': 'cat', 'input': '你怎么叫的？'},
    );
    // Dart extra: the value and the three calls of the model.
    expect(out, {'time001': '', 'time002': '', 'time003': ''});
    expect(model.inputs, hasLength(3));
    for (final input in model.inputs) {
      expect(input.map((m) => m.content), ['You are a cat.', '你怎么叫的？']);
    }
  });

  group('TestChainMultiNodes', () {
    test('test embedding Node', () async {
      final chain = Chain<List<String>, List<List<double>>>()
        ..appendEmbedding(_FakeEmbedder());
      final r = await chain.compile(ctx);
      expect(r, isNotNull);
      // Dart extra: the node runs.
      expect(await r.invoke(ctx, ['a', 'bcd']), [
        [1.0],
        [3.0],
      ]);
    });

    test('test retriever Node', () async {
      final chain = Chain<String, List<Document>>()
        ..appendRetriever(_FakeRetriever());
      final r = await chain.compile(ctx);
      expect(r, isNotNull);
      // Dart extra: the node runs.
      expect((await r.invoke(ctx, 'query')).single.content, 'query');
    });

    test('test chat model', () async {
      final chain = Chain<List<Message>, Message>()
        ..appendChatModel(_IntentChatModel());
      final r = await chain.compile(ctx);
      expect(r, isNotNull);
      // Dart extra: the node runs.
      final answer = await r.invoke(ctx, [Message.user('hi')]);
      expect(answer.toolCalls!.map((call) => call.id), [
        _toolIdOfUserCompany,
        _toolIdOfUserSalary,
      ]);
    });

    test('test chat template', () async {
      final chain = Chain<_Kvs, List<Message>>()
        ..appendChatTemplate(
          const ChatTemplate.fromMessages(FormatType.fString, []),
        );
      final r = await chain.compile(ctx);
      expect(r, isNotNull);
      // Dart extra: the node runs.
      expect(await r.invoke(ctx, <String, Object?>{}), isEmpty);
    });

    test('test lambda', () async {
      final chain = Chain<_Kvs, _Kvs>()..appendLambda(_pass());
      final r = await chain.compile(ctx);
      expect(r, isNotNull);
      // Dart extra: the node runs.
      expect(await r.invoke(ctx, <String, Object?>{'a': 1}), {'a': 1});
    });

    test('test indexer', () async {
      final chain = Chain<List<Document>, List<String>>()
        ..appendIndexer(_FakeIndexer());
      final r = await chain.compile(ctx);
      expect(r, isNotNull);
      // Dart extra: the node runs.
      expect(
        await r.invoke(ctx, const [
          Document(content: 'a'),
          Document(content: 'b'),
        ]),
        ['id0', 'id1'],
      );
    });

    test('test parallel', () async {
      // one node
      var chain = Chain<_Kvs, _Kvs>()
        ..appendParallel(Parallel()..addLambda('test_parallel', _pass()));
      await expectLater(
        chain.compile(ctx),
        _buildError('not enough nodes, count = 1'),
      );

      // the same output key twice
      chain = Chain<_Kvs, _Kvs>()
        ..appendParallel(
          Parallel()
            ..addLambda('test_parallel', _pass())
            ..addLambda('test_parallel', _pass()),
        );
      await expectLater(
        chain.compile(ctx),
        _buildError('duplicate output key= test_parallel'),
      );

      // two nodes
      chain = Chain<_Kvs, _Kvs>()
        ..appendParallel(
          Parallel()
            ..addLambda('test_parallel', _pass())
            ..addLambda('test_parallel1', _pass()),
        );
      expect(await chain.compile(ctx), isNotNull);

      // a parallel behind a parallel
      chain = Chain<_Kvs, _Kvs>()
        ..appendParallel(
          Parallel()
            ..addLambda('test_parallel', _pass())
            ..addLambda('test_parallel1', _pass()),
        )
        ..appendParallel(
          Parallel()
            ..addLambda('test_parallel', _pass())
            ..addLambda('test_parallel1', _pass()),
        );
      await expectLater(
        chain.compile(ctx),
        _buildError('append parallel invalid, multiple previous nodes'),
      );
    });

    test('test tools Node', () async {
      final chain = Chain<_Kvs, _Kvs>();
      final toolsNode = await ToolsNode.create(const ToolsNodeConfig(tools: []));
      chain.appendToolsNode(toolsNode);
      // Dart extra: Go does not look at the chain again. A tools node takes a
      // Message, so it does not fit behind the map this chain starts with.
      await expectLater(chain.compile(ctx), _buildError('mismatch'));

      // Dart extra: a tools node with a tool, in a chain of its types.
      final typed = Chain<Message, List<Message>>()
        ..appendToolsNode(
          await ToolsNode.create(ToolsNodeConfig(tools: [_EchoTool()])),
        );
      final r = await typed.compile(ctx);
      final out = await r.invoke(
        ctx,
        Message.assistant(
          '',
          toolCalls: const [
            ToolCall(
              id: '1',
              function: FunctionCall(name: 'echo', arguments: '{}'),
            ),
          ],
        ),
      );
      expect(out.single.content, 'echo:{}');
      expect(out.single.toolCallId, '1');
    });

    test('test chain with compile option', () async {
      final chain = Chain<_Kvs, _Kvs>()..appendLambda(_pass());
      final r = await chain.compile(
        ctx,
        options: const GraphCompileOptions(maxRunSteps: 10),
      );
      expect(r, isNotNull);
    });

    group('test chain return type', () {
      test('test chain any output type', () async {
        final chain = Chain<_Kvs, _Kvs>()
          ..appendLambda(Lambda<_Kvs, Object?>.invokable((ctx, kvs) => 1));
        expect(await chain.compile(ctx), isNotNull);
      });

      test('test chain error output type', () async {
        final chain = Chain<_Kvs, _Kvs>()
          ..appendLambda(Lambda<_Kvs, String>.invokable((ctx, kvs) => '123'));
        await expectLater(chain.compile(ctx), _buildError('mismatch'));
      });

      test('test chain error input type', () async {
        final chain = Chain<_Kvs, _Kvs>()
          ..appendLambda(
            Lambda<String, _Kvs>.invokable((ctx, input) => <String, Object?>{}),
          );
        await expectLater(chain.compile(ctx), _buildError('mismatch'));
      });
    });
  });

  test('TestParallelMultiNodes', () async {
    final p = Parallel()
      ..addLambda('lambda', _pass())
      ..addGraph('graph', Chain<_Kvs, _Kvs>())
      ..addIndexer('indexer', _FakeIndexer())
      ..addLoader('loader', _FakeLoader())
      ..addDocumentTransformer('document transformer', _FakeTransformer())
      ..addRetriever('retriever', _FakeRetriever())
      ..addChatModel('chatmodel', _FakeChatModel())
      ..addChatTemplate(
        'chatTemplate',
        ChatTemplate.fromMessages(
          FormatType.fString,
          [Message.system('hello')],
        ),
      )
      ..addEmbedding('embedding', _FakeEmbedder())
      ..addPassthrough('passthrough');
    final toolsNode = await ToolsNode.create(const ToolsNodeConfig(tools: []));
    p.addToolsNode('tools', toolsNode);

    expect(p.nodes.length, greaterThan(6));
    // Dart extra: all eleven are there, each under its output key.
    expect(p.error, isNull);
    expect(p.nodes.map((node) => node.nodeInfo.outputKey), [
      'lambda',
      'graph',
      'indexer',
      'loader',
      'document transformer',
      'retriever',
      'chatmodel',
      'chatTemplate',
      'embedding',
      'passthrough',
      'tools',
    ]);

    final duplicate = Parallel()
      ..addIndexer('key', _FakeIndexer())
      ..addLoader('key', _FakeLoader())
      ..addRetriever('r', _FakeRetriever());
    expect(duplicate.error, isNotNull);
    // Dart extra: nothing is added after the first mistake.
    expect(duplicate.nodes, hasLength(1));

    // Not ported: `p.addNode("k", nil, nil)` and a node without nodeInfo. A
    // Dart node is never null and always has its info.
  });

  group('TestChainWithNodeKey', () {
    test('test normal chain with node key option', () async {
      final chain = Chain<_Kvs, _Kvs>()
        ..appendLambda(_pass(), options: const NodeOptions(key: 'lambda_01'));

      final b = ChainBranch.single<_Kvs>((ctx, input) => 'lambda_02')
        ..addLambda(
          'lambda_02',
          Lambda.invokableWithOption<_Kvs, _Kvs, _FakeLambdaOption>(
            (ctx, kvs, options) {
              kvs['lambda_02'] = _infoOf(options);
              return kvs;
            },
          ),
          options: const NodeOptions(key: 'lambda_02'),
        )
        ..addLambda(
          'lambda_03',
          Lambda.invokableWithOption<_Kvs, _Kvs, _FakeLambdaOption>(
            (ctx, kvs, options) {
              kvs['lambda_03'] = _infoOf(options);
              return kvs;
            },
          ),
          options: const NodeOptions(key: 'lambda_03'),
        );

      chain
        ..appendBranch(b)
        ..appendPassthrough();

      final p = Parallel()
        ..addLambda(
          'lambda_02',
          Lambda<_Kvs, String>.invokable(
            (ctx, kvs) => kvs['lambda_02']! as String,
          ),
        )
        ..addLambda(
          'lambda_04',
          Lambda.invokableWithOption<_Kvs, String, _FakeLambdaOption>(
            (ctx, kvs, options) => _infoOf(options),
          ),
          options: const NodeOptions(key: 'lambda_04'),
        )
        ..addLambda(
          'lambda_05',
          Lambda.invokableWithOption<_Kvs, String, _FakeLambdaOption>(
            (ctx, kvs, options) => _infoOf(options),
          ),
          options: const NodeOptions(key: 'lambda_05'),
        );
      chain
        ..appendParallel(p)
        ..appendLambda(
          Lambda.invokableWithOption<_Kvs, _Kvs, _FakeLambdaOption>(
            (ctx, kvs, options) {
              kvs['lambda_06'] = _infoOf(options);
              return kvs;
            },
          ),
          options: const NodeOptions(key: 'lambda_06'),
        );

      final r = await chain.compile(ctx);

      CallOption info(String text) =>
          CallOption.lambda<_FakeLambdaOption>([_fakeWithLambdaInfo(text)]);
      final res = await r.invoke(
        ctx,
        <String, Object?>{},
        options: [
          info('normal'),
          info('info_lambda_02').designateNode(['lambda_02']), // branch
          info('info_lambda_03').designateNode(['lambda_03']), // branch (won't run)
          info('info_lambda_05').designateNode(['lambda_05']), // parallel
        ],
      );

      // transmit option with designateNode
      expect(res['lambda_02'], 'info_lambda_02');
      expect(res['lambda_05'], 'info_lambda_05');
      // without designateNode, using default option
      expect(res['lambda_06'], 'normal');
      // Dart extra
      expect(res['lambda_04'], 'normal');
      expect(res.containsKey('lambda_03'), isFalse);
    });

    group('test chain with node key option and error with correct error info',
        () {
      test('compile error of chain', () async {
        final chain = Chain<_Kvs, _Kvs>()
          ..appendLambda(
            Lambda<_Kvs, String>.invokable((ctx, kvs) => '123'),
            options: const NodeOptions(key: 'lambda_01'),
          );
        await expectLater(chain.compile(ctx), _buildError('edge[lambda_01]'));
      });

      group('compile error of branch', () {
        test('without node key', () async {
          final chain = Chain<_Kvs, _Kvs>()
            ..appendLambda(
              _pass(),
              options: const NodeOptions(key: 'lambda_01'),
            )
            ..appendBranch(
              ChainBranch.single<_Kvs>((ctx, input) => 'lambda_02')
                ..addLambda('lambda_02', _pass())
                ..addLambda(
                  'lambda_03',
                  Lambda<_Kvs, String>.invokable((ctx, kvs) => ''),
                ),
            );
          // with no node key option, will use default node key
          await expectLater(
            chain.compile(ctx),
            _buildError('edge[node_1_branch_lambda_03]'),
          );
        });

        test('with node key', () async {
          final chain = Chain<_Kvs, _Kvs>()
            ..appendLambda(
              _pass(),
              options: const NodeOptions(key: 'lambda_01'),
            )
            ..appendBranch(
              ChainBranch.single<_Kvs>((ctx, input) => 'lambda_02')
                ..addLambda(
                  'lambda_02',
                  _pass(),
                  options: const NodeOptions(key: 'lambda_02'),
                )
                ..addLambda(
                  'lambda_03',
                  Lambda<_Kvs, String>.invokable((ctx, kvs) => '123'),
                  options: const NodeOptions(key: 'key_of_lambda_03'),
                ),
            );
          await expectLater(
            chain.compile(ctx),
            _buildError('edge[key_of_lambda_03]'),
          );
        });
      });

      group('compile error of parallel', () {
        test('without node key', () async {
          final chain = Chain<_Kvs, _Kvs>()
            ..appendLambda(
              _pass(),
              options: const NodeOptions(key: 'lambda_01'),
            )
            ..appendParallel(
              Parallel()
                ..addLambda('lambda_02', _pass())
                ..addLambda(
                  'lambda_03',
                  Lambda<String, String>.invokable((ctx, v) => ''),
                ),
            );
          // with no node key option, will use default node key
          await expectLater(
            chain.compile(ctx),
            _buildError('to=node_1_parallel_1'),
          );
        });

        test('with node key', () async {
          final chain = Chain<_Kvs, _Kvs>()
            ..appendLambda(
              _pass(),
              options: const NodeOptions(key: 'lambda_01'),
            )
            ..appendParallel(
              Parallel()
                ..addLambda(
                  'lambda_02',
                  _pass(),
                  options: const NodeOptions(key: 'lambda_02'),
                )
                ..addLambda(
                  'lambda_03',
                  Lambda<String, String>.invokable((ctx, v) => ''),
                  options: const NodeOptions(key: 'key_of_lambda_03'),
                ),
            );
          await expectLater(
            chain.compile(ctx),
            _buildError('to=key_of_lambda_03'),
          );
        });
      });

      group('invoke error', () {
        Lambda<_Kvs, _Kvs> failing() => Lambda<_Kvs, _Kvs>.invokable(
              (ctx, kvs) => throw Exception('fake error'),
            );
        Lambda<_Kvs, _Kvs> empty() => Lambda<_Kvs, _Kvs>.invokable(
              (ctx, kvs) => <String, Object?>{},
            );

        test('branch with out node key', () async {
          final chain = Chain<_Kvs, _Kvs>()
            ..appendBranch(
              ChainBranch.single<_Kvs>((ctx, input) => 'lambda_01')
                ..addLambda('lambda_01', failing())
                ..addLambda('lambda_02', empty()),
            );
          final c = await chain.compile(ctx);
          // with no node key option, will use default node key
          await expectLater(
            c.invoke(ctx, <String, Object?>{}),
            _fakeErrorAt('node_0_branch_lambda_01'),
          );
        });

        test('branch with node key', () async {
          final chain = Chain<_Kvs, _Kvs>()
            ..appendBranch(
              ChainBranch.single<_Kvs>((ctx, input) => 'lambda_01')
                ..addLambda(
                  'lambda_01',
                  failing(),
                  options: const NodeOptions(key: 'key_of_lambda_01'),
                )
                ..addLambda('lambda_02', empty()),
            );
          final c = await chain.compile(ctx);
          await expectLater(
            c.invoke(ctx, <String, Object?>{}),
            _fakeErrorAt('key_of_lambda_01'),
          );
        });

        test('parallel with out node key', () async {
          final chain = Chain<_Kvs, _Kvs>()
            ..appendParallel(
              Parallel()
                ..addLambda('lambda_01', failing())
                ..addLambda('lambda_02', empty()),
            );
          final c = await chain.compile(ctx);
          // with no node key option, will use default node key
          await expectLater(
            c.invoke(ctx, <String, Object?>{}),
            _fakeErrorAt('node_0_parallel_0'),
          );
        });

        test('parallel with node key', () async {
          final chain = Chain<_Kvs, _Kvs>()
            ..appendParallel(
              Parallel()
                ..addLambda(
                  'lambda_01',
                  failing(),
                  options: const NodeOptions(key: 'key_of_lambda_01'),
                )
                ..addLambda('lambda_02', empty()),
            );
          final c = await chain.compile(ctx);
          await expectLater(
            c.invoke(ctx, <String, Object?>{}),
            _fakeErrorAt('key_of_lambda_01'),
          );
        });
      });
    });
  });

  // --------------------------------------------------------- chain_branch_test.go

  group('TestChainBranch', () {
    String cond(RunContext ctx, String input) => switch (input) {
          'one' => 'one_key',
          'two' => 'two_key',
          'three' => 'three_key',
          _ => throw Exception('invalid input= $input'),
        };

    Lambda<String, String> twice() =>
        Lambda<String, String>.invokable((ctx, input) => input + input);
    Lambda<String, String> thrice() =>
        Lambda<String, String>.invokable((ctx, input) => input + input + input);

    /// Go: a streamable lambda that sends the whitespace-separated fields of
    /// its input from a goroutine. The pipe has room for all of them, so the
    /// sends do not wait here either.
    Lambda<String, String> fields() =>
        Lambda<String, String>.streamable((ctx, input) async {
          final (reader, writer) = pipe<String>(capacity: input.runes.length);
          for (final field in input.split(RegExp(r'\s+'))) {
            if (field.isNotEmpty) writer.send(field);
          }
          await writer.close();
          return reader;
        });

    /// Go: a collectable lambda that joins the chunks and repeats the result.
    Lambda<String, String> joined({required int times}) =>
        Lambda<String, String>.collectable((ctx, input) async {
          final output = StringBuffer();
          try {
            while (true) {
              try {
                output.write(await input.recv());
              } on StreamEOFException {
                break;
              }
            }
          } finally {
            await input.close();
          }
          return output.toString() * times;
        });

    test('nested chain', () async {
      final inner = Chain<String, String>()
        ..appendBranch(
          ChainBranch.single<String>(cond)
            ..addLambda('one_key', twice())
            ..addLambda('two_key', thrice()),
        )
        ..appendParallel(
          Parallel()
            ..addLambda('one_key', twice())
            ..addLambda('two_key', thrice()),
        );

      final outer = Chain<String, String>()..appendGraph(inner);
      await expectLater(
        outer.compile(ctx),
        _buildError('append parallel invalid, multiple previous nodes'),
      );
    });

    test('bad param', () async {
      // Not ported: `AppendBranch(nil)` and `NewChainBranch[string](nil)`. A
      // Dart branch and its condition are never null.

      // one node
      var c = Chain<String, String>()
        ..appendBranch(
          ChainBranch.single<String>(cond)
            ..addChatTemplate(
              'template',
              ChatTemplate.fromMessages(
                FormatType.fString,
                [Message.system('hello')],
              ),
            ),
        );
      await expectLater(
        c.compile(ctx),
        _buildError('append branch invalid, nodeList length = 1'),
      );

      // the same key twice
      c = Chain<String, String>()
        ..appendBranch(
          ChainBranch.single<String>(cond)
            ..addChatTemplate(
              '1',
              const ChatTemplate.fromMessages(FormatType.fString, []),
            )
            ..addChatTemplate(
              '1',
              const ChatTemplate.fromMessages(FormatType.fString, []),
            ),
        );
      await expectLater(
        c.compile(ctx),
        _buildError('duplicate branch node key= 1'),
      );
    });

    test('different Node types in branch', () async {
      final c = Chain<String, String>()
        ..appendBranch(
          ChainBranch.single<String>(cond)
            ..addChatTemplate(
              't',
              const ChatTemplate.fromMessages(FormatType.fString, []),
            )
            ..addGraph('c', Chain<String, String>()),
        );
      await expectLater(
        c.compile(ctx),
        _buildError('chain append branch failed'),
      );
    });

    test('type mismatch', () async {
      final c = Chain<int, String>()
        ..appendBranch(
          ChainBranch.single<String>(cond)
            ..addLambda(
              'one_key',
              Lambda<int, String>.invokable((ctx, input) => '$input'),
            )
            ..addLambda(
              'two_key',
              Lambda<int, String>.invokable((ctx, input) => '$input'),
            ),
        );
      await expectLater(
        c.compile(ctx),
        _buildError('chain append branch failed'),
      );
    });

    test('invoke', () async {
      final c = Chain<String, String>()
        ..appendBranch(
          ChainBranch.single<String>(cond)
            ..addLambda('one_key', twice())
            ..addLambda('two_key', thrice()),
        )
        ..appendLambda(twice());
      final compiledChain = await c.compile(ctx);

      expect(await compiledChain.invoke(ctx, 'two'), 'twotwotwotwotwotwo');

      // the condition names a node the branch does not have
      await expectLater(
        compiledChain.invoke(ctx, 'three'),
        _runError('branch invocation returns unintended end node: three_key'),
      );

      // the condition fails
      await expectLater(
        compiledChain.invoke(ctx, 'four'),
        _runError('invalid input= four'),
      );
    });

    test('fake stream', () async {
      final c = Chain<String, String>()
        ..appendLambda(fields())
        ..appendBranch(
          ChainBranch.single<String>(cond)
            ..addLambda('one_key', joined(times: 2))
            ..addLambda('two_key', joined(times: 3)),
        );
      final compiledChain = await c.compile(ctx);

      expect(await compiledChain.invoke(ctx, 'one'), 'oneone');
    });

    test('real stream', () async {
      Future<String> streamCon(RunContext ctx, StreamReader<String> sr) async {
        try {
          final msg = await sr.recv();
          return switch (msg) {
            'one' => 'one_key',
            'two' => 'two_key',
            'three' => 'three_key',
            _ => throw Exception('invalid input= $msg'),
          };
        } finally {
          await sr.close();
        }
      }

      final c = Chain<String, String>()
        ..appendLambda(fields())
        ..appendBranch(
          ChainBranch.stream<String>(streamCon)
            ..addLambda('one_key', joined(times: 2))
            ..addLambda('two_key', joined(times: 3)),
        );
      final compiledChain = await c.compile(ctx);

      final out = await compiledChain.stream(ctx, 'one size fit all');
      expect(await concatStreamReader(out), 'onesizefitallonesizefitall');
    });
  });

  /// The body TestChainMultiBranch and TestStreamChainMultiBranch share.
  Future<void> expectBothBranchesRun(ChainBranch branch) async {
    final emptyLambda =
        Lambda<String, String>.invokable((ctx, input) => input);

    final r = await (Chain<String, _Kvs>()
          ..appendBranch(
            branch
              ..addLambda(
                '1',
                emptyLambda,
                options: const NodeOptions(outputKey: '1'),
              )
              ..addLambda(
                '2',
                emptyLambda,
                options: const NodeOptions(outputKey: '2'),
              )
              ..addLambda(
                '3',
                emptyLambda,
                options: const NodeOptions(outputKey: '3'),
              ),
          ))
        .compile(ctx);

    expect(await r.invoke(ctx, 'start'), {'1': 'start', '2': 'start'});

    final streamResult = await r.stream(ctx, 'start');
    final result = <String, Object?>{};
    while (true) {
      final _Kvs chunk;
      try {
        chunk = await streamResult.recv();
      } on StreamEOFException {
        break;
      }
      result.addAll(chunk);
    }
    expect(result, {'1': 'start', '2': 'start'});
  }

  test('TestChainMultiBranch', () async {
    await expectBothBranchesRun(
      ChainBranch.multi<String>((ctx, input) => {'1', '2'}),
    );
  });

  test('TestStreamChainMultiBranch', () async {
    await expectBothBranchesRun(
      // As in Go, the condition neither reads nor closes its stream.
      ChainBranch.streamMulti<String>((ctx, input) => {'1', '2'}),
    );
  });
}
