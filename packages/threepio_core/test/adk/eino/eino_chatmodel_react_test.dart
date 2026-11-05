// Ports eino v0.9.22 `adk/chatmodel_test.go`, `adk/react_test.go` and
// `adk/agentic_react_test.go`.
//
// From chatmodel_test.go: TestChatModelAgentRun (the sub-tests that do not
// use the deprecated `Middlewares`), TestParallelReturnDirectlyToolCall.
// From react_test.go: TestReact.
// From agentic_react_test.go, with the classic `Message` agent instead of the
// agentic one (same behaviour): TestAgenticReact_BasicInvoke,
// TestAgenticReact_Stream, TestAgenticReact_MaxIterations,
// TestAgenticReact_MultiTurnToolCalling, TestAgenticReact_ReturnDirectly,
// TestAgenticReact_ChatModelAgent_ToolsReceiveArgs,
// TestAgenticReact_ChatModelAgent_NoTools,
// TestAgenticReact_NilInitInputReturnsError.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/event_senders.dart'
    show ModelWrapperConfig;
import 'package:threepio_core/src/adk/eino/react_graph.dart'
    show ReactConfig, ReactInput, newReactGraph;

typedef _StreamFn = Future<StreamReader<Message>> Function(
  List<Message> input,
  ChatModelOptions? options,
);

/// Port of eino's `mockModel.NewMockToolCallingChatModel`: a call without a
/// closure fails like an unexpected gomock call; the counters stand in for
/// gomock's `Times`. `withTools` returns the same model, as the Go tests'
/// `WithTools(gomock.Any()).Return(cm, nil)` does.
class _MockModel extends ToolCallingChatModel {
  _MockModel({this.onGenerate, this.onStream});

  Future<Message> Function(List<Message> input, ChatModelOptions? options)?
      onGenerate;
  _StreamFn? onStream;

  int generateCalls = 0;
  int streamCalls = 0;
  int withToolsCalls = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    generateCalls++;
    final fn = onGenerate;
    if (fn == null) throw StateError('unexpected call to Generate');
    return fn(input, options);
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    streamCalls++;
    final fn = onStream;
    if (fn == null) throw StateError('unexpected call to Stream');
    return fn(input, options);
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) {
    withToolsCalls++;
    return this;
  }
}

/// Port of eino's `sequentialAgenticModel` (classic messages): each call
/// answers with the next response; streaming sends it as one chunk.
class _SequentialModel extends BaseChatModel {
  _SequentialModel(this.responses);

  final List<Message> responses;
  int callCount = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final idx = callCount++;
    if (idx >= responses.length) {
      throw StateError(
        'sequentialAgenticModel: no more responses (call #$idx)',
      );
    }
    return responses[idx];
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

const _nameParams = {
  'name': ParameterInfo(
    type: DataType.string,
    desc: 'user name for testing',
    required: true,
  ),
};

String _nameOf(String argumentsJson) {
  final decoded = jsonDecode(argumentsJson);
  if (decoded is! Map) {
    throw FormatException('cannot unmarshal into fakeToolInputForTest', argumentsJson);
  }
  return '${decoded['name'] ?? ''}';
}

/// Port of eino's `fakeToolForTest`.
class _FakeTool extends InvokableTool {
  _FakeTool({required this.tarCount});

  final int tarCount;
  int curCount = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'test_tool',
        desc: 'test tool for unit testing',
        params: _nameParams,
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final name = _nameOf(argumentsJson);
    if (curCount >= tarCount) return '{"say": "bye"}';
    curCount++;
    return '{"say": "hello $name"}';
  }
}

/// Port of eino's `fakeStreamToolForTest`.
class _FakeStreamTool extends StreamableTool {
  _FakeStreamTool({required this.tarCount});

  final int tarCount;
  int curCount = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'test_stream_tool',
        desc: 'test stream tool for unit testing',
        params: _nameParams,
      );

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final name = _nameOf(argumentsJson);
    if (curCount >= tarCount) {
      return StreamReader.fromIterable(['{"say": "bye"}']);
    }
    curCount++;
    return StreamReader.fromIterable(['{"say": "hello $name"}']);
  }
}

/// Port of eino's `myTool`: Go sleeps `waitTime`; here the tool waits for
/// [wait] (a future the test controls) and then completes [done].
class _MyTool extends InvokableTool {
  _MyTool({required this.name, required this.desc, this.wait});

  final String name;
  final String desc;
  final Future<void>? wait;
  final Completer<void> done = Completer<void>();

  @override
  Future<ToolInfo> info() async =>
      ToolInfo(function: FunctionInfo(name: name, description: desc));

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    await wait;
    done.complete();
    return 'success';
  }
}

/// Port of eino's `agenticEchoTool`.
class _EchoTool extends InvokableTool {
  _EchoTool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo(function: FunctionInfo(name: name, description: 'echoes input'));

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      'echo:$argumentsJson';
}

/// Port of eino's `agenticArgCaptureTool`.
class _ArgCaptureTool extends InvokableTool {
  _ArgCaptureTool(this.name, this.onInvoke);

  final String name;
  final String Function(String args) onInvoke;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo(function: FunctionInfo(name: name, description: 'captures args'));

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      onInvoke(argumentsJson);
}

final _random = Random();

/// Port of eino's `randStrForTest`.
String _randStrForTest() {
  final seeds = 'test seed'.runes.toList();
  return String.fromCharCodes([
    for (var i = 0; i < 8; i++) seeds[_random.nextInt(seeds.length)],
  ]);
}

/// Port of eino's `agenticToolCallMsg` (classic message).
Message _toolCallMsg(String toolName, String callId, String args) =>
    Message.assistant(
      '',
      toolCalls: [
        ToolCall(
          id: callId,
          function: FunctionCall(name: toolName, arguments: args),
        ),
      ],
    );

/// An assistant message calling [toolName] once with a random id.
Message _helloToolCall(String content, String toolName, String hh) =>
    Message.assistant(
      content,
      toolCalls: [
        ToolCall(
          id: _randStrForTest(),
          function: FunctionCall(
            name: toolName,
            arguments: '{"name": "${_randStrForTest()}", "hh": "$hh"}',
          ),
        ),
      ],
    );

/// Port of eino's `newAgenticAgent` (classic agent).
ChatModelAgent _newAgent(String name, BaseChatModel model, List<BaseTool> tools) =>
    ChatModelAgent(
      ChatModelAgentConfig(
        name: name,
        description: 'test agentic agent',
        model: model,
        toolsConfig: tools.isEmpty
            ? const ToolsConfig()
            : ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)),
      ),
    );

/// Port of eino's `newAgenticRunner` (classic agent).
Runner _newRunner(String name, BaseChatModel model, List<BaseTool> tools) =>
    Runner(agent: _newAgent(name, model, tools));

/// The model of a ReAct graph built without an agent: Go's
/// `testModelWrapper` puts eino's `stateModelWrapper` (no handlers) around
/// the mock, which `ReactConfig.modelWrapperConfig` does here.
ReactConfig _reactConfig(
  BaseChatModel model,
  List<BaseTool> tools, {
  Set<String> toolsReturnDirectly = const {},
  int maxIterations = 0,
}) =>
    ReactConfig(
      model: model,
      modelWrapperConfig: ModelWrapperConfig(),
      toolsConfig: ToolsNodeConfig(tools: tools),
      toolsReturnDirectly: toolsReturnDirectly,
      maxIterations: maxIterations,
    );

const _compileOptions = GraphCompileOptions(maxRunSteps: 1000);

ReactInput _helloInput() => ReactInput(const [
      Message(
        role: RoleType.user,
        content: 'Use the test tool to say hello',
      ),
    ]);

void main() {
  group('TestChatModelAgentRun', () {
    test('BasicFunctionality', () async {
      final ctx = RunContext.background();
      final cm = _MockModel(
        onGenerate: (_, __) async =>
            Message.assistant('Hello, I am an AI assistant.'),
      );

      final agent = ChatModelAgent(
        ChatModelAgentConfig(
          name: 'TestAgent',
          description: 'Test agent for unit testing',
          instruction: 'You are a helpful assistant.',
          model: cm,
        ),
      );
      expect(agent, isNotNull);

      final iterator = agent.run(
        ctx,
        AgentInput(messages: [Message.user('Hello, who are you?')]),
      );
      expect(iterator, isNotNull);

      final event = await iterator.nextOrNull();
      expect(event, isNotNull);
      expect(event!.error, isNull);
      expect(event.output, isNotNull);
      expect(event.output!.messageOutput, isNotNull);

      final msg = event.output!.messageOutput!.message;
      expect(msg, isNotNull);
      expect(msg!.content, 'Hello, I am an AI assistant.');

      expect(await iterator.nextOrNull(), isNull);
      expect(cm.generateCalls, 1);
    });

    // BasicChatModelWithAgentMiddleware,
    // AfterChatModel_NoTools_ModifyDoesNotAffectEvent,
    // AfterChatModel_ReAct_ModifyAffectsFlow and
    // AfterChatModel_ReAct_AppendToolCall_AffectsFlow are not ported: they use
    // the deprecated `Middlewares` (AgentMiddleware), which is not ported.

    test('StreamOutput', () async {
      final ctx = RunContext.background();
      final cm = _MockModel(
        onStream: (_, __) async => StreamReader.fromIterable([
          Message.assistant('Hello'),
          Message.assistant(', I am'),
          Message.assistant(' an AI assistant.'),
        ]),
      );

      final agent = ChatModelAgent(
        ChatModelAgentConfig(
          name: 'TestAgent',
          description: 'Test agent for unit testing',
          instruction: 'You are a helpful assistant.',
          model: cm,
        ),
      );

      final iterator = agent.run(
        ctx,
        AgentInput(
          messages: [Message.user('Hello, who are you?')],
          enableStreaming: true,
        ),
      );

      final event = await iterator.nextOrNull();
      expect(event, isNotNull);
      expect(event!.error, isNull);
      expect(event.output, isNotNull);
      expect(event.output!.messageOutput, isNotNull);
      expect(event.output!.messageOutput!.isStreaming, isTrue);

      expect(await iterator.nextOrNull(), isNull);
      expect(cm.streamCalls, 1);
    });

    test('ErrorHandling', () async {
      final ctx = RunContext.background();
      final cm = _MockModel(
        onGenerate: (_, __) async => throw Exception('model error'),
      );

      final agent = ChatModelAgent(
        ChatModelAgentConfig(
          name: 'TestAgent',
          description: 'Test agent for unit testing',
          instruction: 'You are a helpful assistant.',
          model: cm,
        ),
      );

      final iterator = agent.run(
        ctx,
        AgentInput(messages: [Message.user('Hello, who are you?')]),
      );

      final event = await iterator.nextOrNull();
      expect(event, isNotNull);
      expect(event!.error, isNotNull);
      expect('${event.error}', contains('model error'));

      expect(await iterator.nextOrNull(), isNull);
      expect(cm.generateCalls, 1);
    });

    test('WithTools', () async {
      final ctx = RunContext.background();
      final fakeTool = _FakeTool(tarCount: 1);
      final info = await fakeTool.info();

      final responses = [
        Message.assistant(
          'Using tool',
          toolCalls: [
            ToolCall(
              id: 'tool-call-1',
              function: FunctionCall(
                name: info.name,
                arguments: '{"name": "test user"}',
              ),
            ),
          ],
        ),
        Message.assistant('Task completed'),
      ];
      final cm = _MockModel();
      cm.onGenerate = (_, __) async {
        final i = cm.generateCalls - 1;
        if (i >= responses.length) throw StateError('unexpected call to Generate');
        return responses[i];
      };

      final agent = ChatModelAgent(
        ChatModelAgentConfig(
          name: 'TestAgent',
          description: 'Test agent for unit testing',
          instruction: 'You are a helpful assistant.',
          model: cm,
          toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [fakeTool])),
        ),
      );

      final iterator = agent.run(
        ctx,
        AgentInput(messages: [Message.user('Use the test tool')]),
      );

      final event1 = await iterator.nextOrNull();
      expect(event1, isNotNull);
      expect(event1!.error, isNull);
      expect(event1.output, isNotNull);
      expect(event1.output!.messageOutput, isNotNull);
      expect(event1.output!.messageOutput!.role, RoleType.assistant);

      final event2 = await iterator.nextOrNull();
      expect(event2, isNotNull);
      expect(event2!.error, isNull);
      expect(event2.output, isNotNull);
      expect(event2.output!.messageOutput, isNotNull);
      expect(event2.output!.messageOutput!.role, RoleType.tool);

      final event3 = await iterator.nextOrNull();
      expect(event3, isNotNull);
      expect(event3!.error, isNull);
      expect(event3.output, isNotNull);
      expect(event3.output!.messageOutput, isNotNull);
      expect(event3.output!.messageOutput!.role, RoleType.assistant);

      expect(await iterator.nextOrNull(), isNull);
      expect(cm.generateCalls, 2);
    });

    // WrapToolCall_ToolMiddleware, WrapToolCall_MultipleMiddlewares_Order,
    // WrapToolCall_ModifyResult, WrapToolCall_StreamableMiddleware,
    // WrapToolCall_EnhancedInvokableMiddleware and
    // WrapToolCall_EnhancedStreamableMiddleware are not ported: they use the
    // deprecated `Middlewares` (AgentMiddleware.WrapToolCall), which is not
    // ported.
  });

  test('TestParallelReturnDirectlyToolCall', () async {
    final ctx = RunContext.background();
    final cm = _MockModel(
      onGenerate: (_, __) async => Message.assistant(
        "I'll exit with a final result",
        toolCalls: const [
          ToolCall(
            id: 'tool-call-1',
            function: FunctionCall(name: 'tool1', arguments: ''),
          ),
          ToolCall(
            id: 'tool-call-2',
            function: FunctionCall(name: 'tool2', arguments: ''),
          ),
          ToolCall(
            id: 'tool-call-3',
            function: FunctionCall(name: 'tool3', arguments: ''),
          ),
        ],
      ),
    );

    // Go: the tools sleep 1 ms, 10 ms and 100 ms, so the return-directly
    // tool1 finishes first and tool3 last; here each tool waits for the one
    // before it.
    final tool1 = _MyTool(name: 'tool1', desc: 'tool1');
    final tool2 = _MyTool(name: 'tool2', desc: 'tool2', wait: tool1.done.future);
    final tool3 = _MyTool(name: 'tool3', desc: 'tool3', wait: tool2.done.future);

    final agent = ChatModelAgent(
      ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent with Exit tool',
        instruction: 'You are a helpful assistant.',
        model: cm,
        toolsConfig: ToolsConfig(
          toolsNode: ToolsNodeConfig(tools: [tool1, tool2, tool3]),
          returnDirectly: const {'tool1'},
        ),
      ),
    );
    expect(agent, isNotNull);

    final r = Runner(agent: agent);
    final iter = r.query(ctx, '');
    var times = 0;
    for (var e = await iter.nextOrNull(); e != null; e = await iter.nextOrNull()) {
      if (times == 3) {
        expect(e.output!.messageOutput!.message!.toolName, 'tool1');
      }
      times++;
    }
    expect(times, 4);
    expect(cm.generateCalls, 1);
  });

  group('TestReact', () {
    test('NilInput', () async {
      final ctx = RunContext.background();
      final cm = _MockModel();

      final graph = await newReactGraph(
        ctx,
        ReactConfig(model: cm, toolsConfig: const ToolsNodeConfig(tools: [])),
      );
      final compiled = await graph.compile(ctx);

      await expectLater(
        compiled.invoke(ctx, null),
        throwsA(
          predicate((Object? e) => '$e'.contains('react: init input is nil')),
        ),
      );
    });

    test('Invoke', () async {
      final ctx = RunContext.background();
      final fakeTool = _FakeTool(tarCount: 3);
      final info = await fakeTool.info();

      var times = 0;
      final cm = _MockModel(
        onGenerate: (_, __) async {
          times++;
          if (times <= 2) return _helloToolCall('hello test', info.name, '123');
          return Message.assistant('bye');
        },
      );

      final graph = await newReactGraph(ctx, _reactConfig(cm, [fakeTool]));
      expect(graph, isNotNull);

      final compiled = await graph.compile(ctx, options: _compileOptions);
      expect(compiled, isNotNull);

      final result = await compiled.invoke(ctx, _helloInput());
      expect(result, isNotNull);
    });

    test('ToolsReturnDirectly', () async {
      final ctx = RunContext.background();
      final fakeTool = _FakeTool(tarCount: 3);
      final info = await fakeTool.info();

      var times = 0;
      final cm = _MockModel(
        onGenerate: (_, __) async {
          times++;
          if (times <= 2) return _helloToolCall('hello test', info.name, '123');
          return Message.assistant('bye');
        },
      );

      final graph = await newReactGraph(
        ctx,
        _reactConfig(cm, [fakeTool], toolsReturnDirectly: {info.name}),
      );
      expect(graph, isNotNull);

      final compiled = await graph.compile(ctx, options: _compileOptions);
      expect(compiled, isNotNull);

      final result = await compiled.invoke(ctx, _helloInput());
      expect(result, isNotNull);

      expect(result.role, RoleType.tool);
    });

    _StreamFn streamScript(_FakeTool fakeTool, _FakeStreamTool fakeStreamTool) {
      var times = 0;
      return (_, __) async {
        final info = await fakeTool.info();
        final streamInfo = await fakeStreamTool.info();
        times++;
        if (times <= 1) {
          return StreamReader.fromIterable(
            [_helloToolCall('hello test', info.name, 'tool')],
          );
        } else if (times == 2) {
          return StreamReader.fromIterable(
            [_helloToolCall('hello stream', streamInfo.name, 'stream tool')],
          );
        }
        return StreamReader.fromIterable([Message.assistant('bye')]);
      };
    }

    test('Stream', () async {
      final ctx = RunContext.background();
      final fakeTool = _FakeTool(tarCount: 3);
      final fakeStreamTool = _FakeStreamTool(tarCount: 3);

      final cm = _MockModel(onStream: streamScript(fakeTool, fakeStreamTool));

      final graph =
          await newReactGraph(ctx, _reactConfig(cm, [fakeTool, fakeStreamTool]));
      expect(graph, isNotNull);

      final compiled = await graph.compile(ctx, options: _compileOptions);
      expect(compiled, isNotNull);

      final outStream = await compiled.stream(ctx, _helloInput());
      expect(outStream, isNotNull);

      final msgs = await outStream.collectAll();

      expect(msgs, isNotEmpty);
    });

    test('StreamWithToolsReturnDirectly', () async {
      final ctx = RunContext.background();
      final fakeTool = _FakeTool(tarCount: 3);
      final fakeStreamTool = _FakeStreamTool(tarCount: 3);

      final cm = _MockModel(onStream: streamScript(fakeTool, fakeStreamTool));

      final streamInfo = await fakeStreamTool.info();

      final graph = await newReactGraph(
        ctx,
        _reactConfig(
          cm,
          [fakeTool, fakeStreamTool],
          toolsReturnDirectly: {streamInfo.name},
        ),
      );
      expect(graph, isNotNull);

      final compiled = await graph.compile(ctx, options: _compileOptions);
      expect(compiled, isNotNull);

      final outStream = await compiled.stream(ctx, _helloInput());
      expect(outStream, isNotNull);

      final msgs = <Message>[];
      for (var msg = await outStream.nextOrNull();
          msg != null;
          msg = await outStream.nextOrNull()) {
        expect(msg.role, RoleType.tool);
        msgs.add(msg);
      }
      await outStream.close();

      expect(msgs, isNotEmpty);
    });

    test('MaxIterations', () async {
      final ctx = RunContext.background();
      final fakeTool = _FakeTool(tarCount: 3);
      final info = await fakeTool.info();

      var times = 0;
      final cm = _MockModel(
        onGenerate: (_, __) async {
          times++;
          if (times <= 5) return _helloToolCall('hello test', info.name, '123');
          return Message.assistant('bye');
        },
      );

      // don't exceed max iterations
      var graph = await newReactGraph(
        ctx,
        _reactConfig(cm, [fakeTool], maxIterations: 6),
      );
      expect(graph, isNotNull);

      var compiled = await graph.compile(ctx, options: _compileOptions);
      expect(compiled, isNotNull);

      final result = await compiled.invoke(ctx, _helloInput());
      expect(result.content, 'bye');

      // reset chat model times counter
      times = 0;
      // exceed max iterations
      graph = await newReactGraph(
        ctx,
        _reactConfig(cm, [fakeTool], maxIterations: 5),
      );
      expect(graph, isNotNull);

      compiled = await graph.compile(ctx, options: _compileOptions);
      expect(compiled, isNotNull);

      Object? err;
      try {
        await compiled.invoke(ctx, _helloInput());
      } on Object catch (e) {
        err = e;
      }
      expect(err, isNotNull);
      expect(
        ThreepioException.findCause<ExceedMaxIterationsException>(err),
        isNotNull,
        reason: '$err',
      );
      expect('$err', contains(const ExceedMaxIterationsException().message));
    });
  });

  test('TestAgenticReact_BasicInvoke', () async {
    final ctx = RunContext.background();
    final mdl = _SequentialModel([
      _toolCallMsg('echo', 'call-1', '"hello"'),
      Message.assistant('done: echo result received'),
    ]);

    final runner =
        _newRunner('TestAgenticReact_BasicInvoke', mdl, [_EchoTool('echo')]);
    final events = await runner.query(ctx, 'test input').collectAll();
    final last = events.lastOrNull;

    expect(last, isNotNull);
    expect(last!.error, isNull);
    expect(last.output, isNotNull);
    expect(last.output!.messageOutput, isNotNull);
    expect(
      last.output!.messageOutput!.message!.content,
      'done: echo result received',
    );
    expect(mdl.callCount, 2);
  });

  test('TestAgenticReact_MultiTurnToolCalling', () async {
    final ctx = RunContext.background();
    final mdl = _SequentialModel([
      _toolCallMsg('echo', 'call-1', '"step1"'),
      _toolCallMsg('echo', 'call-2', '"step2"'),
      _toolCallMsg('echo', 'call-3', '"step3"'),
      Message.assistant('all done'),
    ]);

    final runner = _newRunner(
      'TestAgenticReact_MultiTurnToolCalling',
      mdl,
      [_EchoTool('echo')],
    );
    final events = await runner.query(ctx, 'do three steps').collectAll();
    final last = events.lastOrNull;

    expect(last, isNotNull);
    expect(last!.error, isNull);
    expect(last.output, isNotNull);
    expect(last.output!.messageOutput, isNotNull);
    expect(last.output!.messageOutput!.message!.content, 'all done');
    expect(mdl.callCount, 4);
  });

  test('TestAgenticReact_Stream', () async {
    final ctx = RunContext.background();
    final mdl = _SequentialModel([
      _toolCallMsg('echo', 'call-1', '"hello"'),
      Message.assistant('stream done'),
    ]);

    final agent = _newAgent('TestAgenticReact_Stream', mdl, [_EchoTool('echo')]);
    final runner = Runner(agent: agent, enableStreaming: true);

    final events = await runner.query(ctx, 'stream test').collectAll();

    var finalText = '';
    for (final ev in events) {
      final mo = ev.output?.messageOutput;
      if (mo != null) {
        try {
          final txt = (await mo.getMessage()).content;
          if (txt.isNotEmpty) finalText = txt;
          // Go ignores a failed GetMessage.
          // ignore: avoid_catches_without_on_clauses
        } catch (_) {}
      }
    }

    expect(finalText, 'stream done');
  });

  group('TestAgenticReact_MaxIterations', () {
    test('within_limit', () async {
      final ctx = RunContext.background();
      final mdl = _SequentialModel([
        _toolCallMsg('echo', 'c1', '"1"'),
        _toolCallMsg('echo', 'c2', '"2"'),
        Message.assistant('done within limit'),
      ]);

      final runner = _newRunner('within_limit', mdl, [_EchoTool('echo')]);
      final events = await runner.query(ctx, 'go').collectAll();
      final last = events.lastOrNull;

      expect(last, isNotNull);
      expect(last!.error, isNull);
      expect(last.output, isNotNull);
      expect(last.output!.messageOutput, isNotNull);
      expect(last.output!.messageOutput!.message!.content, 'done within limit');
    });

    test('exceeded', () async {
      final ctx = RunContext.background();
      final mdl = _SequentialModel([
        for (var i = 0; i < 25; i++) _toolCallMsg('echo', 'c$i', '"x"'),
      ]);
      final agent = ChatModelAgent(
        ChatModelAgentConfig(
          name: 'exceed-agent',
          description: 'test max iterations exceeded',
          model: mdl,
          maxIterations: 3,
          toolsConfig: ToolsConfig(
            toolsNode: ToolsNodeConfig(tools: [_EchoTool('echo')]),
          ),
        ),
      );

      final runner = Runner(agent: agent);
      final events = await runner.query(ctx, 'go').collectAll();
      final last = events.lastOrNull;

      expect(last, isNotNull);
      expect(last!.error, isNotNull);
      expect(
        ThreepioException.findCause<ExceedMaxIterationsException>(last.error),
        isNotNull,
        reason: '${last.error}',
      );
    });
  });

  group('TestAgenticReact_ReturnDirectly', () {
    late _SequentialModel mdl;
    late ChatModelAgent agent;

    setUpAll(() {
      mdl = _SequentialModel([
        // Model calls the return-directly tool.
        _toolCallMsg('direct', 'call-1', '"final answer"'),
      ]);
      agent = ChatModelAgent(
        ChatModelAgentConfig(
          name: 'TestAgenticReact_ReturnDirectly',
          description: 'test',
          model: mdl,
          toolsConfig: ToolsConfig(
            toolsNode: ToolsNodeConfig(tools: [_EchoTool('direct')]),
            returnDirectly: const {'direct'},
          ),
        ),
      );
    });

    test('Invoke', () async {
      final ctx = RunContext.background();
      mdl.callCount = 0;
      final runner = Runner(agent: agent);
      final events = await runner.query(ctx, 'test').collectAll();

      // Model should be called only once (for the tool call), not a second
      // time, because the tool is return-directly.
      expect(mdl.callCount, 1);

      final last = events.lastOrNull;
      expect(last, isNotNull);
      expect(last!.error, isNull);
      expect(last.output, isNotNull);
      expect(last.output!.messageOutput, isNotNull);

      final msg = last.output!.messageOutput!.message;
      expect(msg, isNotNull);
      // Go: the first content block is a FunctionToolResult of call-1.
      expect(msg!.role, RoleType.tool);
      expect(msg.toolCallId, 'call-1');
    });

    test('Stream', () async {
      final ctx = RunContext.background();
      mdl.callCount = 0;
      final runner = Runner(agent: agent, enableStreaming: true);
      final events = await runner.query(ctx, 'test').collectAll();

      expect(mdl.callCount, 1);

      final last = events.lastOrNull;
      expect(last, isNotNull);
      expect(last!.error, isNull);
      expect(last.output, isNotNull);
      expect(last.output!.messageOutput, isNotNull);

      final mo = last.output!.messageOutput!;
      if (mo.isStreaming) {
        Message? finalMsg;
        try {
          for (var chunk = await mo.messageStream!.nextOrNull();
              chunk != null;
              chunk = await mo.messageStream!.nextOrNull()) {
            finalMsg = chunk;
          }
          // Go stops at the first Recv error.
          // ignore: avoid_catches_without_on_clauses
        } catch (_) {}
        expect(finalMsg, isNotNull);
        expect(finalMsg!.role, RoleType.tool);
        expect(finalMsg.toolCallId, 'call-1');
      } else {
        final msg = mo.message;
        expect(msg, isNotNull);
        expect(msg!.role, RoleType.tool);
        expect(msg.toolCallId, 'call-1');
      }
    });
  });

  test('TestAgenticReact_NilInitInputReturnsError', () async {
    final ctx = RunContext.background();
    final mdl = _MockModel(
      onGenerate: (_, __) async => Message.assistant('unexpected'),
    );

    final graph = await newReactGraph(
      ctx,
      ReactConfig(model: mdl, toolsConfig: const ToolsNodeConfig(tools: [])),
    );
    final runnable = await graph.compile(ctx);

    // The classic graph's text (eino's agentic graph says "agentic react:
    // init input is nil").
    await expectLater(
      runnable.invoke(ctx, null),
      throwsA(
        predicate((Object? e) => '$e'.contains('react: init input is nil')),
      ),
    );
  });

  test('TestAgenticReact_ChatModelAgent_NoTools', () async {
    final ctx = RunContext.background();
    final mdl = _MockModel(
      onGenerate: (_, __) async => Message.assistant('no tools response'),
    );

    final runner = _newRunner('TestAgenticReact_ChatModelAgent_NoTools', mdl, []);
    final events = await runner.query(ctx, 'hello').collectAll();
    final last = events.lastOrNull;

    expect(last, isNotNull);
    expect(last!.error, isNull);
    expect(last.output, isNotNull);
    expect(last.output!.messageOutput, isNotNull);
    expect(last.output!.messageOutput!.message!.content, 'no tools response');
  });

  test('TestAgenticReact_ChatModelAgent_ToolsReceiveArgs', () async {
    final ctx = RunContext.background();
    var receivedArgs = '';
    final captureTool = _ArgCaptureTool('capture', (args) {
      receivedArgs = args;
      return 'captured';
    });

    final mdl = _SequentialModel([
      _toolCallMsg('capture', 'c1', '{"foo":"bar"}'),
      Message.assistant('done'),
    ]);

    final runner = _newRunner(
      'TestAgenticReact_ChatModelAgent_ToolsReceiveArgs',
      mdl,
      [captureTool],
    );
    await runner.query(ctx, 'call capture').collectAll();

    expect(receivedArgs, '{"foo":"bar"}');
  });
}
