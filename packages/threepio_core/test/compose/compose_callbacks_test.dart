// Callbacks injection: what a graph fires around its nodes and around
// itself, which handlers hear what, and what the tools node fires per tool.
// Behaviour of eino `compose/utils.go` (`initGraphCallbacks`,
// `initNodeCallbacks`, `runWithCallbacks`) and `graph_run.go`.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart' show ensureRunInfo, onEnd, onStart;
import 'package:threepio_core/threepio_core.dart';

import '../support/log_capture.dart';

/// Records every callback as `timing kind name[/type]: payload`.
final class _Recorder extends ComponentCallbackHandler {
  _Recorder([this.label = '']);

  final String label;
  final List<String> events = [];
  final List<Future<void>> streams = [];

  String _who(RunInfo info) {
    final type = info.type.isEmpty ? '' : '/${info.type}';
    return '$label${info.componentType.name} "${info.name}"$type';
  }

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    events.add('start ${_who(info)}: $input');
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    events.add('end ${_who(info)}: $output');
    return ctx;
  }

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    events.add('error ${_who(info)}: ${error.runtimeType}');
    return ctx;
  }

  @override
  RunContext onStartWithStreamInput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> input,
  ) {
    streams.add(
      input.collectAll().then(
            (chunks) => events.add('stream-start ${_who(info)}: $chunks'),
          ),
    );
    return ctx;
  }

  @override
  RunContext onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) {
    streams.add(
      output.collectAll().then(
            (chunks) => events.add('stream-end ${_who(info)}: $chunks'),
          ),
    );
    return ctx;
  }

  Future<void> get settled => Future.wait(streams);
}

/// A component that fires its own callbacks.
final class _SelfReporting extends BaseChatModel
    implements CallbackAwareComponent, TypedComponent {
  @override
  bool get isCallbacksEnabled => true;

  @override
  String get componentTypeName => 'SelfReporting';

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    var ctx = ensureRunInfo(
      options!.runContext!,
      componentTypeName,
      ComponentType.chatModel,
    );
    ctx = await onStart(ctx, 'own input');
    await onEnd(ctx, 'own output');
    return Message.assistant('hi');
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

final class _Shout extends InvokableTool {
  @override
  Future<ToolInfo> info() async =>
      ToolInfo.function(name: 'shout', description: 'shouts');

  @override
  Future<String> run(String argumentsJson) async => argumentsJson.toUpperCase();
}

Lambda<String, String> _append(String suffix, {String type = ''}) =>
    Lambda<String, String>.invokable(
      (ctx, input) => '$input$suffix',
      options: LambdaOptions(type: type),
    );

void main() {
  final ctx = RunContext.background();

  setUp(() {
    GlobalCallbacks.clear();
    // A hook that throws is logged, not thrown: make that fail the test.
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  Future<Runnable<String, String>> twoNodes() => (Graph<String, String>()
        ..addLambdaNode(
          'a',
          _append('-a', type: 'Appender'),
          options: const NodeOptions(name: 'first'),
        )
        ..addLambdaNode('b', _append('-b'))
        ..addEdge(Graph.start, 'a')
        ..addEdge('a', 'b')
        ..addEdge('b', Graph.end))
      .compile(ctx, options: const GraphCompileOptions(graphName: 'G'));

  test('a handler of the call hears the graph and every node, in order',
      () async {
    final recorder = _Recorder();
    final runnable = await twoNodes();

    await runnable.invoke(
      ctx,
      'x',
      options: [
        CallOption.callbacks([recorder]),
      ],
    );

    expect(recorder.events, [
      'start graph "G": x',
      'start lambda "first"/Appender: x',
      'end lambda "first"/Appender: x-a',
      'start lambda "": x-a',
      'end lambda "": x-a-b',
      'end graph "G": x-a-b',
    ]);
  });

  test('a handler designated at a node hears only that node', () async {
    final onA = _Recorder();
    final everywhere = _Recorder();
    final runnable = await twoNodes();

    await runnable.invoke(
      ctx,
      'x',
      options: [
        CallOption.callbacks([onA]).designateNode(['a']),
        CallOption.callbacks([everywhere]),
      ],
    );

    expect(onA.events, [
      'start lambda "first"/Appender: x',
      'end lambda "first"/Appender: x-a',
    ]);
    expect(everywhere.events, hasLength(6));
  });

  test('handlers of the context and global handlers hear the run', () async {
    final global = _Recorder('global ');
    final fromContext = _Recorder('context ');
    GlobalCallbacks.append([global]);
    final runnable = await twoNodes();

    await runnable.invoke(ctx.withHandlers([fromContext]), 'x');

    expect(global.events, hasLength(6));
    expect(fromContext.events, hasLength(6));
    expect(global.events.first, 'start global graph "G": x');
    expect(fromContext.events.last, 'end context graph "G": x-a-b');
  });

  test('without handlers nothing is fired and the run is the same', () async {
    final runnable = await twoNodes();
    expect(await runnable.invoke(ctx, 'x'), 'x-a-b');
  });

  test('what a start hook puts into the context reaches the end hook',
      () async {
    final key = ContextKey<String>('session');
    final seen = <String?>[];
    final handler = CallbackHandlerBuilder()
        .onStart((ctx, info, input) => ctx.withValue(key, 'from ${info.name}'))
        .onEnd((ctx, info, output) {
      seen.add(ctx.value(key));
      return ctx;
    }).build();
    final runnable = await twoNodes();

    await runnable.invoke(
      ctx,
      'x',
      options: [
        CallOption.callbacks([handler]).designateNode(['a']),
      ],
    );

    expect(seen, ['from first']);
  });

  test('a stream run fires the stream timings for the graph', () async {
    final recorder = _Recorder();
    final runnable = await twoNodes();

    final output = await runnable.transform(
      ctx,
      StreamReader.fromIterable(['x', 'y']),
      options: [
        CallOption.callbacks([recorder]),
      ],
    );
    expect(await output.collectAll(), ['xy-a-b']);
    await recorder.settled;

    expect(
      recorder.events,
      containsAll([
        'stream-start graph "G": [x, y]',
        // An invokable lambda gets the joined chunks.
        'start lambda "first"/Appender: xy',
        'end lambda "first"/Appender: xy-a',
        'stream-end graph "G": [xy-a-b]',
      ]),
    );
  });

  test('a transformable lambda fires the stream timings itself', () async {
    final recorder = _Recorder();
    final runnable = await (Chain<String, String>()
          ..appendLambda(
            Lambda<String, String>.transformable(
              (ctx, input) => input.convert((chunk) => chunk.toUpperCase()),
            ),
            options: const NodeOptions(name: 'upper'),
          ))
        .compile(ctx);

    final output = await runnable.stream(
      ctx,
      'x',
      options: [
        CallOption.callbacks([recorder]),
      ],
    );
    expect(await output.collectAll(), ['X']);
    await recorder.settled;

    expect(
      recorder.events,
      containsAll([
        // As in Eino, a graph that is asked for a stream runs on a stream:
        // its input is reported as a stream of one chunk.
        'stream-start chain "": [x]',
        'stream-start lambda "upper": [x]',
        'stream-end lambda "upper": [X]',
        'stream-end chain "": [X]',
      ]),
    );
  });

  test('a failing node is reported for the node and for the graph', () async {
    final recorder = _Recorder();
    final runnable = await (Graph<String, String>()
          ..addLambdaNode(
            'bad',
            Lambda<String, String>.invokable(
              (ctx, input) => throw const FormatException('no'),
            ),
          )
          ..addEdge(Graph.start, 'bad')
          ..addEdge('bad', Graph.end))
        .compile(ctx, options: const GraphCompileOptions(graphName: 'G'));

    await expectLater(
      runnable.invoke(
        ctx,
        'x',
        options: [
          CallOption.callbacks([recorder]),
        ],
      ),
      throwsA(isA<NodeExecutionException>()),
    );

    expect(recorder.events, [
      'start graph "G": x',
      'start lambda "": x',
      'error lambda "": FormatException',
      'error graph "G": NodeExecutionException',
    ]);
  });

  test('a nested graph reports under the name of its node', () async {
    final recorder = _Recorder();
    final inner = Graph<String, String>()
      ..addLambdaNode('in', _append('-in'))
      ..addEdge(Graph.start, 'in')
      ..addEdge('in', Graph.end);
    final runnable = await (Graph<String, String>()
          ..addGraphNode(
            'sub',
            inner,
            options: const NodeOptions(name: 'inner graph'),
          )
          ..addEdge(Graph.start, 'sub')
          ..addEdge('sub', Graph.end))
        .compile(ctx, options: const GraphCompileOptions(graphName: 'outer'));

    await runnable.invoke(
      ctx,
      'x',
      options: [
        CallOption.callbacks([recorder]),
      ],
    );

    expect(recorder.events, [
      'start graph "outer": x',
      'start graph "inner graph": x',
      'start lambda "": x',
      'end lambda "": x-in',
      'end graph "inner graph": x-in',
      'end graph "outer": x-in',
    ]);
  });

  test('a handler designated by path hears a node of a nested graph',
      () async {
    final recorder = _Recorder();
    final inner = Graph<String, String>()
      ..addLambdaNode('in', _append('-in'))
      ..addLambdaNode('in2', _append('-in2'))
      ..addEdge(Graph.start, 'in')
      ..addEdge('in', 'in2')
      ..addEdge('in2', Graph.end);
    final runnable = await (Graph<String, String>()
          ..addGraphNode('sub', inner)
          ..addEdge(Graph.start, 'sub')
          ..addEdge('sub', Graph.end))
        .compile(ctx);

    await runnable.invoke(
      ctx,
      'x',
      options: [
        CallOption.callbacks([recorder]).designateNodeWithPath([
          NodePath(const ['sub', 'in2']),
        ]),
      ],
    );

    expect(recorder.events, [
      'start lambda "": x-in',
      'end lambda "": x-in-in2',
    ]);
  });

  test('a component that fires its own callbacks is not wrapped', () async {
    final recorder = _Recorder();
    final runnable = await (Chain<List<Message>, Message>()
          ..appendChatModel(
            _SelfReporting(),
            options: const NodeOptions(name: 'model'),
          ))
        .compile(ctx);

    await runnable.invoke(
      ctx,
      [Message.user('hello')],
      options: [
        CallOption.callbacks([recorder]),
      ],
    );

    // One start and one end for the model, with the payloads the component
    // chose, under the run info of the node.
    expect(
      recorder.events.where((event) => event.contains('chatModel')),
      [
        'start chatModel "model"/SelfReporting: own input',
        'end chatModel "model"/SelfReporting: own output',
      ],
    );
  });

  test('a lambda with callbacks enabled is not wrapped either', () async {
    final recorder = _Recorder();
    final runnable = await (Chain<String, String>()
          ..appendLambda(
            Lambda<String, String>.invokable(
              (ctx, input) => input,
              options: const LambdaOptions(callbacksEnabled: true),
            ),
          ))
        .compile(ctx);

    await runnable.invoke(
      ctx,
      'x',
      options: [
        CallOption.callbacks([recorder]),
      ],
    );

    expect(recorder.events, ['start chain "": x', 'end chain "": x']);
  });

  test('a passthrough node fires nothing', () async {
    final recorder = _Recorder();
    final runnable = await (Chain<String, String>()..appendPassthrough())
        .compile(ctx);

    await runnable.invoke(
      ctx,
      'x',
      options: [
        CallOption.callbacks([recorder]),
      ],
    );

    expect(recorder.events, ['start chain "": x', 'end chain "": x']);
  });

  test('the tools node fires callbacks per tool', () async {
    final recorder = _Recorder();
    final node = await ToolsNode.create(ToolsNodeConfig(tools: [_Shout()]));
    final message = Message.assistant(
      '',
      toolCalls: const [
        ToolCall(
          id: 'c1',
          function: FunctionCall(name: 'shout', arguments: 'abc'),
        ),
      ],
    );

    await node.invoke(ctx.withHandlers([recorder]), message);
    expect(recorder.events, [
      'start tool "shout"/Shout: abc',
      'end tool "shout"/Shout: ABC',
    ]);

    recorder.events.clear();
    final stream = await node.stream(ctx.withHandlers([recorder]), message);
    await stream.collectAll();
    await recorder.settled;
    expect(recorder.events, [
      'start tool "shout"/Shout: abc',
      'end tool "shout"/Shout: ABC',
    ]);
  });

  test('in a graph the tools node is reported around its tools', () async {
    final recorder = _Recorder();
    final node = ToolsNode(ToolsNodeConfig(tools: [_Shout()]));
    final runnable = await (Chain<Message, List<Message>>()
          ..appendToolsNode(node, options: const NodeOptions(name: 'tools')))
        .compile(ctx);

    await runnable.invoke(
      ctx,
      Message.assistant(
        '',
        toolCalls: const [
          ToolCall(
            id: 'c1',
            function: FunctionCall(name: 'shout', arguments: 'abc'),
          ),
        ],
      ),
      options: [
        CallOption.callbacks([recorder]),
      ],
    );

    expect(
      recorder.events.map((event) => event.split(':').first).toList(),
      [
        'start chain ""',
        'start toolsNode "tools"',
        'start tool "shout"/Shout',
        'end tool "shout"/Shout',
        'end toolsNode "tools"',
        'end chain ""',
      ],
    );
  });
}
