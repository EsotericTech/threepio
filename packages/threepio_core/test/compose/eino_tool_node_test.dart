// Port of eino `compose/tool_node_test.go` (v0.9.22).
//
// Not ported, because they need interrupts, reruns and checkpoints, which
// arrive with the next phase: TestToolRerun and
// TestAttack_EnhancedToolStreamCancellationTracksCompletedCalls.
//
// The groups named `ToolsNode: …` are not Go tests. They pin behaviour of
// eino `compose/tool_node.go` that the Go test file leaves untested.
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

const _toolNameOfUserCompany = 'user_company';
const _toolIdOfUserCompany = 'call_TRZhlagwBS0LpWbWPeZOvIXc';

const _toolNameOfUserSalary = 'user_salary';
const _toolIdOfUserSalary = 'call_AqfoRW6fuF98k0o7696k2nzm';

typedef _Json = Map<String, Object?>;

/// Go `newTool`: decodes the arguments, calls the function and encodes what
/// it returns as JSON.
final class _FnTool extends InvokableTool {
  _FnTool(this._info, this._fn);

  final ToolInfo _info;
  final FutureOr<Object?> Function(RunContext ctx, _Json request) _fn;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final request = jsonDecode(argumentsJson) as _Json;
    return jsonEncode(await _fn(ctx, request));
  }
}

/// Go `newStreamableTool`: like [_FnTool], every chunk encoded on its own.
final class _StreamFnTool extends StreamableTool {
  _StreamFnTool(this._info, this._fn);

  final ToolInfo _info;
  final FutureOr<StreamReader<Object?>> Function(RunContext ctx, _Json request)
      _fn;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final request = jsonDecode(argumentsJson) as _Json;
    final chunks = await _fn(ctx, request);
    return chunks.convert<String>((chunk) => jsonEncode(chunk));
  }
}

/// Go `enhancedInvokableTool`.
final class _EnhancedInvokable implements EnhancedInvokableTool {
  _EnhancedInvokable(this._info, this._fn);

  final ToolInfo _info;
  final FutureOr<ToolResult> Function(
    RunContext ctx,
    ToolArgument input,
    ToolOptions? options,
  ) _fn;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      _fn(ctx, argument, options);
}

/// Go `enhancedStreamableTool`.
final class _EnhancedStreamable implements EnhancedStreamableTool {
  _EnhancedStreamable(this._info, this._fn);

  final ToolInfo _info;
  final FutureOr<StreamReader<ToolResult>> Function(
    RunContext ctx,
    ToolArgument input,
    ToolOptions? options,
  ) _fn;

  @override
  Future<ToolInfo> info() async => _info;

  @override
  Future<StreamReader<ToolResult>> enhancedStreamableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      _fn(ctx, argument, options);
}

/// An invokable tool made of a function that gets everything the tool gets.
final class _Invokable extends InvokableTool {
  _Invokable(this.name, this._run);

  final String name;
  final FutureOr<String> Function(
    RunContext ctx,
    String arguments,
    ToolOptions? options,
  ) _run;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      _run(ctx, argumentsJson, options);
}

/// The streaming counterpart of [_Invokable].
final class _Streamable extends StreamableTool {
  _Streamable(this.name, this._run);

  final String name;
  final FutureOr<StreamReader<String>> Function(
    RunContext ctx,
    String arguments,
    ToolOptions? options,
  ) _run;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      _run(ctx, argumentsJson, options);
}

/// Go `queryUserCompany`.
_Json _queryUserCompany(RunContext ctx, _Json request) {
  final callId = toolCallIdOf(ctx);
  if (callId != _toolIdOfUserCompany) {
    throw StateError('invalid tool call id= $callId');
  }
  return {
    'user_id': '${request['name']}-${request['email']}',
    'gender': 'male',
    'company': 'bytedance',
    'position': 'CEO',
  };
}

/// Go `queryUserSalary`.
Future<StreamReader<Object?>> _queryUserSalary(
  RunContext ctx,
  _Json request,
) async {
  final callId = toolCallIdOf(ctx);
  if (callId != _toolIdOfUserSalary) {
    throw StateError('invalid tool call id= $callId');
  }
  final (reader, writer) = pipe<Object?>(capacity: 10);
  for (final salary in [5000, 3000, 2000]) {
    writer.send({
      'user_id': '${request['name']}-${request['email']}',
      'salary': salary,
    });
  }
  await writer.close();
  return reader;
}

const _zhangsan = '{"name": "zhangsan", "email": "zhangsan@bytedance.com"}';

const _companyCall = ToolCall(
  id: _toolIdOfUserCompany,
  function: FunctionCall(name: _toolNameOfUserCompany, arguments: _zhangsan),
);

const _salaryCall = ToolCall(
  id: _toolIdOfUserSalary,
  function: FunctionCall(name: _toolNameOfUserSalary, arguments: _zhangsan),
);

/// Go `mockIntentChatModel`.
final class _MockIntentChatModel extends BaseChatModel {
  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      Message.assistant('', toolCalls: const [_companyCall, _salaryCall]);

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final (reader, writer) = pipe<Message>(capacity: 2);
    writer
      ..send(Message.assistant('', toolCalls: const [_companyCall]))
      ..send(Message.assistant('', toolCalls: const [_salaryCall]));
    await writer.close();
    return reader;
  }
}

/// Go `mockToolOptions`.
final class _MockToolOptions {
  const _MockToolOptions({this.age = 0});

  final int age;
}

/// Go `WithAge`.
ToolOptions _withAge(int age) =>
    ToolOptions(extensions: [_MockToolOptions(age: age)]);

/// Go `mockTool`: invokable and streamable, it echoes the name it is given
/// and the age from its options.
final class _MockTool extends InvokableTool implements StreamableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'mock_tool',
        desc: 'mock tool',
        params: const {
          'name': ParameterInfo(
            type: DataType.string,
            desc: 'name',
            required: true,
          ),
        },
      );

  static String _echo(String argumentsJson, ToolOptions? options) {
    final age = options?.extension<_MockToolOptions>()?.age ?? 0;
    final request = jsonDecode(argumentsJson) as _Json;
    return jsonEncode({'echo': '${request['name']}: $age'});
  }

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      _echo(argumentsJson, options);

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final (reader, writer) = pipe<String>(capacity: 1);
    // Go sends from a goroutine, one character per chunk.
    unawaited(() async {
      try {
        final output = _echo(argumentsJson, options);
        for (var i = 0; i < output.length; i++) {
          await writer.sendAsync(output[i]);
        }
      } on FormatException catch (error) {
        writer.sendError(error);
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }

  @override
  Future<StreamReader<String>> streamRun(String argumentsJson) =>
      streamableRun(RunContext.background(), argumentsJson);
}

/// Go `myTool3`: invokable, and run once per run of the node.
final class _MyTool3 extends InvokableTool {
  int times = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'tool3');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    expect(times, 0);
    times++;
    return 'tool3 input: $argumentsJson';
  }
}

/// Go `myTool4`: streamable, and run once per run of the node.
final class _MyTool4 extends StreamableTool {
  int times = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'tool4');

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    expect(times, 0);
    times++;
    return StreamReader.fromIterable(['tool4 input: ', argumentsJson]);
  }
}

/// A tool that offers both the plain and the enhanced contract.
final class _BothContracts extends InvokableTool
    implements EnhancedInvokableTool {
  int plainCalls = 0;
  int enhancedCalls = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'both');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    plainCalls++;
    return 'plain: $argumentsJson';
  }

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async {
    enhancedCalls++;
    return ToolResult.text('enhanced: ${argument.text}');
  }
}

/// A tool that cannot be run in any way.
final class _InfoOnly implements BaseTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'info_only');
}

/// A tool that cannot say what it is.
final class _NoInfo extends InvokableTool {
  @override
  Future<ToolInfo> info() async => throw StateError('no info today');

  @override
  Future<String> run(String argumentsJson) async => 'never';
}

/// What a tool throws to pause the run.
final class _Pause implements InterruptSignal {
  const _Pause(this.reason);

  final String reason;

  @override
  String toString() => '_Pause($reason)';
}

/// An assistant message with one tool call per `(id, name, arguments)`.
Message _calls(List<(String, String, String)> calls) => Message.assistant(
      '',
      toolCalls: [
        for (final (id, name, arguments) in calls)
          ToolCall(
            id: id,
            function: FunctionCall(name: name, arguments: arguments),
          ),
      ],
    );

/// Go `findMsgByToolCallID`.
Message? _findMsgByToolCallId(List<Message> msgs, String toolCallId) {
  for (final msg in msgs) {
    if (msg.toolCallId == toolCallId) return msg;
  }
  return null;
}

/// Reads [reader] to its end and closes it. The loop is bounded: a stream
/// that does not end fails the test instead of hanging it.
Future<List<T>> _readAll<T>(StreamReader<T> reader, {int limit = 500}) async {
  final chunks = <T>[];
  try {
    for (var i = 0; i <= limit; i++) {
      try {
        chunks.add(await reader.recv());
      } on StreamEOFException {
        return chunks;
      }
    }
    fail('the stream did not end within $limit chunks');
  } finally {
    await reader.close();
  }
}

/// The text of the first input part of [message], where an enhanced tool
/// puts its result.
String? _firstPartText(Message message) =>
    message.userInputMultiContent?.first.text;

Matcher _toolsNodeFailure({
  Object? message,
  Object? toolName,
  Object? callId,
  Object? cause,
}) {
  var matcher = isA<ToolsNodeException>();
  if (message != null) {
    matcher = matcher.having((e) => e.message, 'message', message);
  }
  if (toolName != null) {
    matcher = matcher.having((e) => e.toolName, 'toolName', toolName);
  }
  if (callId != null) {
    matcher = matcher.having((e) => e.callId, 'callId', callId);
  }
  if (cause != null) {
    matcher = matcher.having((e) => e.cause, 'cause', cause);
  }
  return matcher;
}

void main() {
  final ctx = RunContext.background();

  group('TestToolsNode', () {
    final userCompanyToolInfo = ToolInfo.fromParams(
      name: _toolNameOfUserCompany,
      desc: "Query user's company and position information based on user's "
          'name and email',
      params: const {
        'name': ParameterInfo(type: DataType.string, desc: "User's name"),
        'email': ParameterInfo(type: DataType.string, desc: "User's email"),
      },
    );

    final userSalaryToolInfo = ToolInfo.fromParams(
      name: _toolNameOfUserSalary,
      desc: "Query user's salary information based on user's name and email",
      params: const {
        'name': ParameterInfo(type: DataType.string, desc: "User's name"),
        'email': ParameterInfo(type: DataType.string, desc: "User's email"),
      },
    );

    const userId = 'zhangsan-zhangsan@bytedance.com';
    const companyJson = {
      'user_id': userId,
      'gender': 'male',
      'company': 'bytedance',
      'position': 'CEO',
    };

    test('success', () async {
      const nodeOfTools = 'tools';
      const nodeOfModel = 'model';
      final g = Graph<List<Message>, List<Message>>()
        ..addChatModelNode(nodeOfModel, _MockIntentChatModel());

      final ui = _FnTool(userCompanyToolInfo, _queryUserCompany);
      final us = _StreamFnTool(userSalaryToolInfo, _queryUserSalary);

      final toolsNode =
          await ToolsNode.create(ToolsNodeConfig(tools: [ui, us]));

      g
        ..addToolsNode(nodeOfTools, toolsNode)
        ..addEdge(Graph.start, nodeOfModel)
        ..addEdge(nodeOfModel, nodeOfTools)
        ..addEdge(nodeOfTools, Graph.end);

      final r = await g.compile(ctx);

      final out = await r.invoke(ctx, <Message>[]);

      var msg = _findMsgByToolCallId(out, _toolIdOfUserCompany)!;
      expect(msg.toolCallId, _toolIdOfUserCompany);
      expect(jsonDecode(msg.content), companyJson);

      msg = _findMsgByToolCallId(out, _toolIdOfUserSalary)!;
      expect(msg.toolCallId, _toolIdOfUserSalary);
      expect(
        msg.content,
        contains(
          '{"user_id":"$userId","salary":5000}'
          '{"user_id":"$userId","salary":3000}'
          '{"user_id":"$userId","salary":2000}',
        ),
      );

      // The Go loop looks its messages up in `out`, the result of Invoke, so
      // all it pins about a chunk is its length. Here the chunk itself is
      // checked, for what the Go test says it expects. Intended deviation:
      // the entry of the tool a chunk does not come from is an empty tool
      // message where Go has nil.
      var userSalaryTimes = 0;
      void checkChunk(List<Message> msgs) {
        expect(msgs, hasLength(2));
        expect(msgs.map((m) => m.role), everyElement(RoleType.tool));
        expect(
          msgs.map((m) => m.toolCallId),
          [_toolIdOfUserCompany, _toolIdOfUserSalary],
        );
        final company = msgs[0];
        final salary = msgs[1];
        if (company.content.isNotEmpty) {
          expect(salary.content, isEmpty);
          expect(jsonDecode(company.content), companyJson);
        } else {
          expect(
            jsonDecode(salary.content),
            {
              'user_id': userId,
              'salary': [5000, 3000, 2000][userSalaryTimes],
            },
          );
          userSalaryTimes++;
        }
      }

      // 测试流式调用
      var reader = await r.stream(ctx, <Message>[]);
      addTearDown(reader.close);
      var loops = 0;

      final arrMsgs = <List<Message>>[];
      for (; loops < 10; loops++) {
        final List<Message> msgs;
        try {
          msgs = await reader.recv();
        } on StreamEOFException {
          break;
        }
        arrMsgs.add(msgs);
        checkChunk(msgs);
      }

      expect(loops, 4);
      expect(userSalaryTimes, 3);

      final msgs = concatMessageArray(arrMsgs);
      expect(_findMsgByToolCallId(msgs, _toolIdOfUserCompany), isNotNull);
      expect(_findMsgByToolCallId(msgs, _toolIdOfUserSalary), isNotNull);
      // Joined, the chunks are what Invoke returned.
      expect(msgs, out);

      final (sr, sw) = pipe<List<Message>>(capacity: 2);
      sw
        ..send([Message.user('hi, how are you')])
        ..send([Message.user("i'm fine'")]);
      await sw.close();

      reader = await r.transform(ctx, sr);
      addTearDown(reader.close);

      loops = 0;
      userSalaryTimes = 0;

      for (; loops < 10; loops++) {
        final List<Message> msgs;
        try {
          msgs = await reader.recv();
        } on StreamEOFException {
          break;
        }
        checkChunk(msgs);
      }

      expect(loops, 4);
      expect(userSalaryTimes, 3);
    });

    test('order_consistency', () async {
      // Create a ToolsNode with multiple tools
      final ui = _FnTool(userCompanyToolInfo, _queryUserCompany);
      // Go hands the stream function to `newTool`, which then marshals the
      // reader itself. Here the invokable salary tool returns the chunks.
      final us = _FnTool(
        userSalaryToolInfo,
        (ctx, request) async =>
            _readAll(await _queryUserSalary(ctx, request)),
      );

      final toolsNode =
          await ToolsNode.create(ToolsNodeConfig(tools: [ui, us]));

      // Create an input message with multiple tool calls in a specific order
      final input = Message.assistant(
        '',
        toolCalls: const [_salaryCall, _companyCall],
      );

      // Invoke the ToolsNode
      final output = await toolsNode.invokeTools(ctx, input);

      // Verify the order of output messages matches the order of input tool calls
      expect(output, hasLength(2));
      expect(output[0].toolCallId, _toolIdOfUserSalary);
      expect(output[1].toolCallId, _toolIdOfUserCompany);

      // Test with Stream method as well
      final streamer = await toolsNode.streamTools(ctx, input);

      // Collect all stream outputs
      final streamOutputs = await _readAll(streamer);
      expect(streamOutputs, isNotEmpty);

      // Verify each chunk maintains the correct order. (Go skips the nil
      // entries; here every entry is a tool message of its call.)
      for (final chunk in streamOutputs) {
        expect(chunk, hasLength(2));
        expect(chunk[0].toolCallId, _toolIdOfUserSalary);
        expect(chunk[1].toolCallId, _toolIdOfUserCompany);
      }

      // Concatenate all stream outputs and verify final result
      final concatenated = concatMessageArray(streamOutputs);
      expect(concatenated, hasLength(2));
      expect(concatenated[0].toolCallId, _toolIdOfUserSalary);
      expect(concatenated[1].toolCallId, _toolIdOfUserCompany);
    });

    test('success, as a chain (Chain.appendToolsNode)', () async {
      final toolsNode = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _FnTool(userCompanyToolInfo, _queryUserCompany),
            _StreamFnTool(userSalaryToolInfo, _queryUserSalary),
          ],
        ),
      );
      final chain = Chain<List<Message>, List<Message>>()
        ..appendChatModel(_MockIntentChatModel())
        ..appendToolsNode(toolsNode);
      final r = await chain.compile(ctx);

      final out = await r.invoke(ctx, <Message>[]);
      expect(
        out.map((m) => m.toolCallId),
        [_toolIdOfUserCompany, _toolIdOfUserSalary],
      );
      expect(jsonDecode(out[0].content), companyJson);

      final chunks = await _readAll(await r.stream(ctx, <Message>[]));
      expect(chunks, hasLength(4));
      expect(concatMessageArray(chunks), out);
    });
  });

  group('TestToolsNodeOptions', () {
    final input = _calls([
      (_toolIdOfUserCompany, 'mock_tool', '{"name": "jack"}'),
    ]);

    test('tool_option', () async {
      final g = Graph<Message, List<Message>>();

      final mt = _MockTool();

      final tn = await ToolsNode.create(ToolsNodeConfig(tools: [mt]));

      g
        ..addToolsNode('tools', tn)
        ..addEdge(Graph.start, 'tools')
        ..addEdge('tools', Graph.end);

      final r = await g.compile(ctx);

      final out = await r.invoke(
        ctx,
        input,
        options: [
          CallOption.toolsNode(ToolsNodeOptions(toolOptions: _withAge(10))),
        ],
      );
      expect(out, hasLength(1));
      expect(jsonDecode(out[0].content), {'echo': 'jack: 10'});

      final outStream = await r.stream(
        ctx,
        input,
        options: [
          CallOption.toolsNode(ToolsNodeOptions(toolOptions: _withAge(10))),
        ],
      );
      final outMessages = await _readAll(outStream);
      // The tool streams its answer one character at a time.
      expect(outMessages.length, greaterThan(1));

      final msgs = concatMessageArray(outMessages);

      expect(msgs, hasLength(1));
      expect(jsonDecode(msgs[0].content), {'echo': 'jack: 10'});
    });

    test('tool_list', () async {
      final g = Graph<Message, List<Message>>();

      final mt = _MockTool();

      final tn = await ToolsNode.create(const ToolsNodeConfig(tools: []));

      g
        ..addToolsNode('tools', tn)
        ..addEdge(Graph.start, 'tools')
        ..addEdge('tools', Graph.end);

      final r = await g.compile(ctx);

      final out = await r.invoke(
        ctx,
        input,
        options: [
          CallOption.toolsNode(
            ToolsNodeOptions(toolList: [mt], toolOptions: _withAge(10)),
          ),
        ],
      );
      expect(out, hasLength(1));
      expect(jsonDecode(out[0].content), {'echo': 'jack: 10'});

      final outStream = await r.stream(
        ctx,
        input,
        options: [
          CallOption.toolsNode(
            ToolsNodeOptions(toolList: [mt], toolOptions: _withAge(10)),
          ),
        ],
      );
      final outMessages = await _readAll(outStream);

      final msgs = concatMessageArray(outMessages);

      expect(msgs, hasLength(1));
      expect(jsonDecode(msgs[0].content), {'echo': 'jack: 10'});
    });
  });

  test('TestUnknownTool', () async {
    final tn = await ToolsNode.create(
      ToolsNodeConfig(
        tools: const [],
        unknownToolsHandler: (ctx, name, input) => 'unknown',
      ),
    );

    final input = _calls([('1', 'unknown1', 'arg1'), ('2', 'unknown2', 'arg2')]);

    final expected = [
      Message.tool(content: 'unknown', toolCallId: '1', toolName: 'unknown1'),
      Message.tool(content: 'unknown', toolCallId: '2', toolName: 'unknown2'),
    ];

    var result = await tn.invokeTools(ctx, input);
    expect(result, expected);

    final chunks = await _readAll(await tn.streamTools(ctx, input));
    // Go takes the entries of a chunk that are not nil. Intended deviation:
    // here the other entries are empty tool messages.
    final picked = List<Message?>.filled(2, null);
    for (final chunk in chunks) {
      expect(chunk, hasLength(2));
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i].content.isNotEmpty) {
          picked[i] = chunk[i];
        } else {
          expect(
            chunk[i],
            Message.tool(
              content: '',
              toolCallId: expected[i].toolCallId!,
              toolName: expected[i].toolName,
            ),
          );
        }
      }
    }
    expect(picked, expected);
    result = concatMessageArray(chunks);
    expect(result, expected);
  });

  test('TestToolMiddleware', () async {
    final t3 = _MyTool3();
    final t4 = _MyTool4();
    final tn = await ToolsNode.create(
      ToolsNodeConfig(
        tools: [t3, t4],
        toolCallMiddlewares: [
          ToolMiddleware(
            invokable: (endpoint) => (ctx, input) async {
              await endpoint(ctx, input);
              return const ToolCallOutput('middleware1');
            },
          ),
          ToolMiddleware(
            streamable: (endpoint) => (ctx, input) async {
              await endpoint(ctx, input);
              return StreamToolCallOutput(
                StreamReader.fromIterable(['middleware2']),
              );
            },
          ),
        ],
      ),
    );

    final input = _calls([('1', 'tool3', ''), ('2', 'tool4', '')]);

    var messages = await tn.invokeTools(ctx, input);
    expect(messages, hasLength(2));
    expect(messages[0].content, 'middleware1');
    expect(messages[1].content, 'middleware2');
    expect([t3.times, t4.times], [1, 1]);

    // reset t3 t4
    t3.times = 0;
    t4.times = 0;
    final messageArray = await _readAll(await tn.streamTools(ctx, input));
    messages = concatMessageArray(messageArray);
    expect(messages, hasLength(2));
    expect(messages[0].content, 'middleware1');
    expect(messages[1].content, 'middleware2');
    expect([t3.times, t4.times], [1, 1]);
  });

  group('TestEnhancedToolNode', () {
    late ToolsNode toolNode;

    setUp(() async {
      final enhancedInvokable = _EnhancedInvokable(
        ToolInfo.function(
          name: 'enhanced_invokable_tool',
          description: 'test enhanced invokable tool',
        ),
        (ctx, input, options) => ToolResult([
          ToolOutputPart(
            type: ToolPartType.text,
            text: 'invokable result: ${input.text}',
          ),
        ]),
      );

      final enhancedStreamable = _EnhancedStreamable(
        ToolInfo.function(
          name: 'enhanced_streamable_tool',
          description: 'test enhanced streamable tool',
        ),
        (ctx, input, options) => StreamReader.fromIterable([
          ToolResult([
            ToolOutputPart(
              type: ToolPartType.text,
              text: 'stream part 1: ${input.text}',
            ),
          ]),
          const ToolResult([
            ToolOutputPart(type: ToolPartType.text, text: ' stream part 2'),
          ]),
        ]),
      );

      toolNode = await ToolsNode.create(
        ToolsNodeConfig(tools: [enhancedInvokable, enhancedStreamable]),
      );
    });

    test('enhanced invokable tool', () async {
      final input = _calls([('call1', 'enhanced_invokable_tool', 'test input')]);

      final output = await toolNode.invokeTools(ctx, input);
      expect(output, hasLength(1));
      expect(output[0].role, RoleType.tool);
      expect(output[0].toolCallId, 'call1');
      // Go `ToolsNode.Invoke`: the result is in the input parts of an
      // otherwise empty tool message.
      expect(output[0].toolName, 'enhanced_invokable_tool');
      expect(output[0].content, isEmpty);
      expect(_firstPartText(output[0]), 'invokable result: test input');
    });

    test('enhanced streamable tool', () async {
      final input =
          _calls([('call2', 'enhanced_streamable_tool', 'test stream')]);

      final streamReader = await toolNode.streamTools(ctx, input);

      final messages = <Message>[
        for (final chunk in await _readAll(streamReader)) ...chunk,
      ];
      final message = concatMessages(messages);
      expect(messages, hasLength(2));
      expect(messages[0].role, RoleType.tool);
      expect(messages[0].toolCallId, 'call2');
      expect(_firstPartText(message), contains('stream part'));
      expect(_firstPartText(messages[0]), 'stream part 1: test stream');
      expect(_firstPartText(messages[1]), ' stream part 2');
    });
  });

  group('TestEnhancedToolConversion', () {
    test('enhanced invokable auto-converts to streamable', () async {
      final enhancedInvokable = _EnhancedInvokable(
        ToolInfo.function(
          name: 'enhanced_only_invokable',
          description: 'test enhanced invokable only',
        ),
        (ctx, input, options) => ToolResult([
          ToolOutputPart(
            type: ToolPartType.text,
            text: 'enhanced: ${input.text}',
          ),
        ]),
      );

      final toolNode =
          await ToolsNode.create(ToolsNodeConfig(tools: [enhancedInvokable]));

      final input = _calls([('call1', 'enhanced_only_invokable', 'test')]);

      final streamReader = await toolNode.streamTools(ctx, input);

      final messages = <Message>[
        for (final chunk in await _readAll(streamReader)) ...chunk,
      ];
      expect(messages, hasLength(1));
      expect(_firstPartText(messages[0]), 'enhanced: test');
    });
  });

  group('TestEnhancedToolMiddleware', () {
    var invokableMiddlewareCalled = false;
    var streamableMiddlewareCalled = false;
    late ToolsNode toolNode;

    setUp(() async {
      final enhancedInvokable = _EnhancedInvokable(
        ToolInfo.function(
          name: 'enhanced_tool_with_middleware',
          description: 'test enhanced tool with middleware',
        ),
        (ctx, input, options) => const ToolResult([
          ToolOutputPart(type: ToolPartType.text, text: 'result'),
        ]),
      );

      toolNode = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [enhancedInvokable],
          toolCallMiddlewares: [
            ToolMiddleware(
              enhancedInvokable: (next) => (ctx, input) {
                invokableMiddlewareCalled = true;
                return next(ctx, input);
              },
              enhancedStreamable: (next) => (ctx, input) {
                streamableMiddlewareCalled = true;
                return next(ctx, input);
              },
            ),
          ],
        ),
      );
    });

    test('enhanced invokable middleware', () async {
      invokableMiddlewareCalled = false;
      final input =
          _calls([('call1', 'enhanced_tool_with_middleware', 'test')]);

      await toolNode.invokeTools(ctx, input);
      expect(invokableMiddlewareCalled, isTrue);
    });

    test('enhanced streamable middleware', () async {
      invokableMiddlewareCalled = false;
      streamableMiddlewareCalled = false;
      final input =
          _calls([('call2', 'enhanced_tool_with_middleware', 'test')]);

      final streamReader = await toolNode.streamTools(ctx, input);
      await _readAll(streamReader);
      // The tool is only invokable: its stream is made from the invokable
      // endpoint, so the streamable part of the middleware never runs.
      expect(streamableMiddlewareCalled, isFalse);
      expect(invokableMiddlewareCalled, isTrue);
    });
  });

  group('TestEnhancedToolPriority', () {
    test('enhanced tool is used when available', () async {
      final enhancedInvokable = _EnhancedInvokable(
        ToolInfo.function(
          name: 'test_tool',
          description: 'test tool with both enhanced and regular',
        ),
        (ctx, input, options) => const ToolResult([
          ToolOutputPart(type: ToolPartType.text, text: 'enhanced result'),
        ]),
      );

      final toolNode =
          await ToolsNode.create(ToolsNodeConfig(tools: [enhancedInvokable]));

      final input = _calls([('call1', 'test_tool', 'test')]);

      final output = await toolNode.invokeTools(ctx, input);
      expect(output, hasLength(1));
      expect(_firstPartText(output[0]), contains('enhanced result'));
    });

    // The Go tool only has the enhanced form. This one really has both.
    test('a tool with the plain and the enhanced contract is run enhanced',
        () async {
      final tool = _BothContracts();
      final used = <String>[];
      final toolNode = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [tool],
          toolCallMiddlewares: [
            ToolMiddleware(
              invokable: (next) => (ctx, input) {
                used.add('invokable');
                return next(ctx, input);
              },
              streamable: (next) => (ctx, input) {
                used.add('streamable');
                return next(ctx, input);
              },
              enhancedInvokable: (next) => (ctx, input) {
                used.add('enhancedInvokable');
                return next(ctx, input);
              },
              enhancedStreamable: (next) => (ctx, input) {
                used.add('enhancedStreamable');
                return next(ctx, input);
              },
            ),
          ],
        ),
      );
      final input = _calls([('call1', 'both', 'x')]);

      final output = await toolNode.invokeTools(ctx, input);
      expect(output, hasLength(1));
      expect(output[0].content, isEmpty);
      expect(_firstPartText(output[0]), 'enhanced: x');
      expect([tool.plainCalls, tool.enhancedCalls], [0, 1]);
      expect(used, ['enhancedInvokable']);

      used.clear();
      final chunks = await _readAll(await toolNode.streamTools(ctx, input));
      expect(chunks, hasLength(1));
      expect(chunks.single.single.content, isEmpty);
      expect(_firstPartText(chunks.single.single), 'enhanced: x');
      expect([tool.plainCalls, tool.enhancedCalls], [0, 2]);
      expect(used, ['enhancedInvokable']);
    });
  });

  group('ToolsNode: execution order', () {
    late List<String> events;

    setUp(() => events = []);

    /// A tool that lets the event loop turn between its start and its end.
    _Invokable slow(String name) => _Invokable(name, (ctx, arguments, _) async {
          events.add('$name:start');
          await Future<void>.delayed(Duration.zero);
          events.add('$name:end');
          return name;
        });

    _Streamable slowStream(String name) =>
        _Streamable(name, (ctx, arguments, _) async {
          events.add('$name:start');
          await Future<void>.delayed(Duration.zero);
          events.add('$name:end');
          return StreamReader.fromIterable([name]);
        });

    final input = _calls([('1', 'a', ''), ('2', 'b', ''), ('3', 'c', '')]);
    const starts = {'a:start', 'b:start', 'c:start'};
    const ends = {'a:end', 'b:end', 'c:end'};

    test('by default the calls run side by side, results in call order',
        () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(tools: [slow('a'), slowStream('b'), slow('c')]),
      );

      final out = await node.invokeTools(ctx, input);
      expect(events, hasLength(6));
      expect(events.take(3).toSet(), starts);
      expect(events.skip(3).toSet(), ends);
      expect(out.map((m) => m.content), ['a', 'b', 'c']);
      expect(out.map((m) => m.toolCallId), ['1', '2', '3']);
      expect(out.map((m) => m.toolName), ['a', 'b', 'c']);

      events.clear();
      final chunks = await _readAll(await node.streamTools(ctx, input));
      expect(events, hasLength(6));
      expect(events.take(3).toSet(), starts);
      expect(events.skip(3).toSet(), ends);
      expect(concatMessageArray(chunks).map((m) => m.content), ['a', 'b', 'c']);
    });

    test('executeSequentially runs them one after the other, in call order',
        () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [slow('c'), slowStream('b'), slow('a')],
          executeSequentially: true,
        ),
      );
      const inOrder = [
        'a:start',
        'a:end',
        'b:start',
        'b:end',
        'c:start',
        'c:end',
      ];

      final out = await node.invokeTools(ctx, input);
      expect(events, inOrder);
      expect(out.map((m) => m.content), ['a', 'b', 'c']);

      events.clear();
      final chunks = await _readAll(await node.streamTools(ctx, input));
      expect(events, inOrder);
      expect(concatMessageArray(chunks).map((m) => m.content), ['a', 'b', 'c']);
    });

    test('sequentially, a failed call does not keep the later ones from '
        'running, and the first failure is reported', () async {
      final boom = Exception('boom');
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('a', (ctx, arguments, _) {
              events.add('a');
              throw boom;
            }),
            _Invokable('b', (ctx, arguments, _) {
              events.add('b');
              throw Exception('second');
            }),
            slow('c'),
          ],
          executeSequentially: true,
        ),
      );

      await expectLater(
        node.invokeTools(ctx, input),
        throwsA(
          _toolsNodeFailure(
            message: allOf(
              startsWith('failed to invoke tool[name:a id:1]: '),
              contains('boom'),
            ),
            toolName: 'a',
            callId: '1',
            cause: same(boom),
          ),
        ),
      );
      expect(events, ['a', 'b', 'c:start', 'c:end']);

      events.clear();
      await expectLater(
        node.streamTools(ctx, input),
        throwsA(
          _toolsNodeFailure(
            message: allOf(
              startsWith('failed to stream tool call 1: '),
              contains('boom'),
            ),
            toolName: 'a',
            callId: '1',
            cause: same(boom),
          ),
        ),
      );
      expect(events, ['a', 'b', 'c:start', 'c:end']);
    });

    test('side by side, the failure reported is that of the first failed '
        'call of the message, not of the first to fail', () async {
      final late = Exception('late');
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('a', (ctx, arguments, _) async {
              events.add('a:start');
              await Future<void>.delayed(Duration.zero);
              events.add('a:fails');
              throw late;
            }),
            _Invokable('b', (ctx, arguments, _) {
              events.add('b:fails');
              throw Exception('early');
            }),
            slow('c'),
          ],
        ),
      );

      await expectLater(
        node.invokeTools(ctx, input),
        throwsA(_toolsNodeFailure(toolName: 'a', callId: '1', cause: same(late))),
      );
      expect(events.indexOf('b:fails'), lessThan(events.indexOf('a:fails')));
      expect(events, contains('c:end'));
    });

    test('two calls with the same id each get their result', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [_Invokable('echo', (ctx, arguments, _) => arguments)],
        ),
      );
      final twice = _calls([('same', 'echo', 'one'), ('same', 'echo', 'two')]);

      final out = await node.invokeTools(ctx, twice);
      expect(out.map((m) => m.content), ['one', 'two']);
      expect(out.map((m) => m.toolCallId), ['same', 'same']);

      final chunks = await _readAll(await node.streamTools(ctx, twice));
      expect(chunks, hasLength(2));
      expect(concatMessageArray(chunks), out);
    });
  });

  group('ToolsNode: middlewares', () {
    test('the first middleware is the outermost', () async {
      final events = <String>[];
      ToolMiddleware named(String name) => ToolMiddleware(
            invokable: (next) => (ctx, input) async {
              events.add('$name in');
              final output = await next(ctx, input);
              events.add('$name out');
              return output;
            },
            streamable: (next) => (ctx, input) async {
              events.add('$name in');
              final output = await next(ctx, input);
              events.add('$name out');
              return output;
            },
          );
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('inv', (ctx, arguments, _) {
              events.add('tool');
              return 'r';
            }),
            _Streamable('str', (ctx, arguments, _) {
              events.add('tool');
              return StreamReader.fromIterable(['r']);
            }),
          ],
          toolCallMiddlewares: [named('first'), named('second')],
        ),
      );
      const order = ['first in', 'second in', 'tool', 'second out', 'first out'];

      for (final name in ['inv', 'str']) {
        events.clear();
        await node.invokeTools(ctx, _calls([('1', name, '')]));
        expect(events, order, reason: '$name, invoked');

        events.clear();
        await _readAll(await node.streamTools(ctx, _calls([('1', name, '')])));
        expect(events, order, reason: '$name, streamed');
      }
    });

    test('a middleware can change the arguments and the result', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('inv', (ctx, arguments, _) => 'tool($arguments)'),
            _Streamable(
              'str',
              (ctx, arguments, _) =>
                  StreamReader.fromIterable(['tool(', arguments, ')']),
            ),
            _EnhancedInvokable(
              ToolInfo.function(name: 'einv'),
              (ctx, input, _) => ToolResult.text('tool(${input.text})'),
            ),
          ],
          toolCallMiddlewares: [
            ToolMiddleware(
              invokable: (next) => (ctx, input) async {
                final output = await next(
                  ctx,
                  input.copyWith(arguments: '[${input.arguments}]'),
                );
                return ToolCallOutput('<${output.result}>');
              },
              streamable: (next) => (ctx, input) async {
                final output = await next(
                  ctx,
                  input.copyWith(arguments: '[${input.arguments}]'),
                );
                return StreamToolCallOutput(
                  output.result.convert<String>((chunk) => chunk.toUpperCase()),
                );
              },
              enhancedInvokable: (next) => (ctx, input) async {
                final output = await next(
                  ctx,
                  input.copyWith(arguments: '[${input.arguments}]'),
                );
                return EnhancedToolCallOutput(
                  ToolResult([
                    ...output.result.parts,
                    ToolOutputPart.text('+1'),
                  ]),
                );
              },
            ),
          ],
        ),
      );
      final input =
          _calls([('1', 'inv', 'a'), ('2', 'str', 'b'), ('3', 'einv', 'c')]);

      final out = await node.invokeTools(ctx, input);
      expect(out[0].content, '<tool([a])>');
      expect(out[1].content, 'TOOL([B])');
      expect(
        out[2].userInputMultiContent?.map((part) => part.text),
        ['tool([c])', '+1'],
      );
      // The message keeps the call as the model made it.
      expect(out.map((m) => m.toolName), ['inv', 'str', 'einv']);
      expect(out.map((m) => m.toolCallId), ['1', '2', '3']);

      final joined =
          concatMessageArray(await _readAll(await node.streamTools(ctx, input)));
      expect(joined[0].content, '<tool([a])>');
      expect(joined[1].content, 'TOOL([B])');
    });

    test('the middlewares also wrap the tools of a call option', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: const [],
          toolCallMiddlewares: [
            ToolMiddleware(
              invokable: (next) => (ctx, input) async =>
                  ToolCallOutput('<${(await next(ctx, input)).result}>'),
            ),
          ],
        ),
      );
      final options = ToolsNodeOptions(
        toolList: [_Invokable('late', (ctx, arguments, _) => 'late')],
      );
      final input = _calls([('1', 'late', '')]);

      final out = await node.invokeTools(ctx, input, options: options);
      expect(out.single.content, '<late>');
      final chunks =
          await _readAll(await node.streamTools(ctx, input, options: options));
      expect(concatMessageArray(chunks), out);

      // The tool list of one call is gone with the call.
      await expectLater(
        node.invokeTools(ctx, input),
        throwsA(
          _toolsNodeFailure(message: 'tool late not found in toolsNode indexes'),
        ),
      );
    });
  });

  group('ToolsNode: unknown tools', () {
    test('the handler gets the name and the arguments as the model wrote '
        'them, and its answer takes the place of the call', () async {
      final asked = <String>[];
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [_Invokable('echo', (ctx, arguments, _) => arguments)],
          unknownToolsHandler: (ctx, name, input) async {
            asked.add('$name($input)');
            await Future<void>.delayed(Duration.zero);
            return 'there is no tool $name';
          },
        ),
      );
      final input = _calls([
        ('1', 'nope', 'not json'),
        ('2', 'echo', 'known'),
        ('3', 'neither', ''),
      ]);
      final expected = [
        Message.tool(
          content: 'there is no tool nope',
          toolCallId: '1',
          toolName: 'nope',
        ),
        Message.tool(content: 'known', toolCallId: '2', toolName: 'echo'),
        Message.tool(
          content: 'there is no tool neither',
          toolCallId: '3',
          toolName: 'neither',
        ),
      ];

      expect(await node.invokeTools(ctx, input), expected);
      expect(asked, unorderedEquals(['nope(not json)', 'neither()']));

      final chunks = await _readAll(await node.streamTools(ctx, input));
      expect(chunks, hasLength(3));
      expect(concatMessageArray(chunks), expected);
    });

    test('a handler that throws fails the node like a tool that throws',
        () async {
      final lost = Exception('lost');
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: const [],
          unknownToolsHandler: (ctx, name, input) => throw lost,
        ),
      );
      final input = _calls([('7', 'nope', '')]);

      await expectLater(
        node.invokeTools(ctx, input),
        throwsA(
          _toolsNodeFailure(
            message: startsWith('failed to invoke tool[name:nope id:7]: '),
            toolName: 'nope',
            callId: '7',
            cause: same(lost),
          ),
        ),
      );
      await expectLater(
        node.streamTools(ctx, input),
        throwsA(
          _toolsNodeFailure(
            message: startsWith('failed to stream tool call 7: '),
            callId: '7',
            cause: same(lost),
          ),
        ),
      );
    });

    test('of two tools with one name the later one is called', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('dup', (ctx, arguments, _) => 'first'),
            _Invokable('dup', (ctx, arguments, _) => 'second'),
          ],
        ),
      );

      final out = await node.invokeTools(ctx, _calls([('1', 'dup', '')]));
      expect(out.single.content, 'second');
    });
  });

  group('ToolsNode: toolArgumentsHandler', () {
    test('rewrites the arguments of every call before the tool runs',
        () async {
      final handled = <String>[];
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('echo', (ctx, arguments, _) => 'echo $arguments'),
            _Streamable(
              'stream',
              (ctx, arguments, _) =>
                  StreamReader.fromIterable(['stream ', arguments]),
            ),
            _EnhancedInvokable(
              ToolInfo.function(name: 'enhanced'),
              (ctx, input, _) => ToolResult.text('enhanced ${input.text}'),
            ),
          ],
          toolArgumentsHandler: (ctx, name, arguments) async {
            // The handler runs before the call: it has no tool call id.
            handled.add('$name $arguments ${toolCallIdOf(ctx)}');
            await Future<void>.delayed(Duration.zero);
            return '<$arguments>';
          },
        ),
      );
      final input = _calls([
        ('1', 'echo', '{"x":1}'),
        ('2', 'stream', 'two'),
        ('3', 'enhanced', ''),
      ]);
      const seen = ['echo {"x":1} null', 'stream two null', 'enhanced  null'];

      final out = await node.invokeTools(ctx, input);
      expect(handled, seen);
      expect(out[0].content, 'echo <{"x":1}>');
      expect(out[1].content, 'stream <two>');
      expect(_firstPartText(out[2]), 'enhanced <>');

      handled.clear();
      final chunks = await _readAll(await node.streamTools(ctx, input));
      expect(handled, seen);
      final joined = concatMessageArray(chunks);
      expect(joined[0].content, 'echo <{"x":1}>');
      expect(joined[1].content, 'stream <two>');
      expect(_firstPartText(joined[2]), 'enhanced <>');
    });

    test('a handler that throws fails the node before any tool runs',
        () async {
      var toolRuns = 0;
      final refused = Exception('refused');
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('echo', (ctx, arguments, _) {
              toolRuns++;
              return arguments;
            }),
          ],
          toolArgumentsHandler: (ctx, name, arguments) =>
              arguments == 'bad' ? throw refused : arguments,
        ),
      );
      final input = _calls([('1', 'echo', 'good'), ('2', 'echo', 'bad')]);
      final failure = _toolsNodeFailure(
        message: allOf(
          startsWith(
            'failed to executed tool[name:echo arguments:bad] arguments '
            'handler: ',
          ),
          contains('refused'),
        ),
        toolName: 'echo',
        callId: '2',
        cause: same(refused),
      );

      await expectLater(node.invokeTools(ctx, input), throwsA(failure));
      await expectLater(node.streamTools(ctx, input), throwsA(failure));
      expect(toolRuns, 0);
    });

    test('is not asked about calls of unknown tools', () async {
      final handled = <String>[];
      final unknown = <String>[];
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [_Invokable('echo', (ctx, arguments, _) => arguments)],
          toolArgumentsHandler: (ctx, name, arguments) {
            handled.add(name);
            return '<$arguments>';
          },
          unknownToolsHandler: (ctx, name, input) {
            unknown.add('$name $input');
            return 'no such tool';
          },
        ),
      );

      final out = await node.invokeTools(
        ctx,
        _calls([('1', 'echo', 'a'), ('2', 'nope', 'b')]),
      );
      expect(out.map((m) => m.content), ['<a>', 'no such tool']);
      expect(handled, ['echo']);
      expect(unknown, ['nope b']);
    });
  });

  group('ToolsNode: toolCallIdOf', () {
    test('is null outside a tool call', () {
      expect(toolCallIdOf(RunContext.background()), isNull);
    });

    test('a tool, the middlewares around it and the unknown tools handler '
        'see the id of their call', () async {
      final seen = <String>[];
      void note(String who, RunContext ctx) =>
          seen.add('$who ${toolCallIdOf(ctx)}');

      final node = await ToolsNode.create(
        ToolsNodeConfig(
          executeSequentially: true,
          tools: [
            _Invokable('inv', (ctx, arguments, _) {
              note('tool inv', ctx);
              return 'r';
            }),
            _Streamable('str', (ctx, arguments, _) {
              note('tool str', ctx);
              return StreamReader.fromIterable(['r']);
            }),
            _EnhancedInvokable(ToolInfo.function(name: 'einv'),
                (ctx, input, _) {
              note('tool einv', ctx);
              return ToolResult.text('r');
            }),
            _EnhancedStreamable(ToolInfo.function(name: 'estr'),
                (ctx, input, _) {
              note('tool estr', ctx);
              return StreamReader.fromIterable([ToolResult.text('r')]);
            }),
          ],
          unknownToolsHandler: (ctx, name, input) {
            note('unknown $name', ctx);
            return 'r';
          },
          toolCallMiddlewares: [
            ToolMiddleware(
              invokable: (next) => (ctx, input) {
                note('invokable ${input.name} ${input.callId}', ctx);
                return next(ctx, input);
              },
              streamable: (next) => (ctx, input) {
                note('streamable ${input.name} ${input.callId}', ctx);
                return next(ctx, input);
              },
              enhancedInvokable: (next) => (ctx, input) {
                note('enhancedInvokable ${input.name} ${input.callId}', ctx);
                return next(ctx, input);
              },
              enhancedStreamable: (next) => (ctx, input) {
                note('enhancedStreamable ${input.name} ${input.callId}', ctx);
                return next(ctx, input);
              },
            ),
          ],
        ),
      );
      final input = _calls([
        ('c1', 'inv', ''),
        ('c2', 'str', ''),
        ('c3', 'einv', ''),
        ('c4', 'estr', ''),
        ('c5', 'nope', ''),
      ]);
      // A middleware part sees the calls of the tools that have its form; the
      // unknown tools handler is not behind the middlewares.
      const expected = [
        'invokable inv c1 c1',
        'tool inv c1',
        'streamable str c2 c2',
        'tool str c2',
        'enhancedInvokable einv c3 c3',
        'tool einv c3',
        'enhancedStreamable estr c4 c4',
        'tool estr c4',
        'unknown nope c5',
      ];

      await node.invokeTools(ctx, input);
      expect(seen, expected);

      seen.clear();
      await _readAll(await node.streamTools(ctx, input));
      expect(seen, expected);

      // The context of the caller is left as it was.
      expect(toolCallIdOf(ctx), isNull);
    });
  });

  group('ToolsNode: tool options', () {
    late List<String> seen;
    late ToolsNode node;

    String age(ToolOptions? options) =>
        '${options?.extension<_MockToolOptions>()?.age}';

    setUp(() async {
      seen = [];
      node = await ToolsNode.create(
        ToolsNodeConfig(
          executeSequentially: true,
          tools: [
            _Invokable('inv', (ctx, arguments, options) {
              seen.add('inv ${age(options)}');
              return 'r';
            }),
            _Streamable('str', (ctx, arguments, options) {
              seen.add('str ${age(options)}');
              return StreamReader.fromIterable(['r']);
            }),
            _EnhancedInvokable(ToolInfo.function(name: 'einv'),
                (ctx, input, options) {
              seen.add('einv ${age(options)}');
              return ToolResult.text('r');
            }),
            _EnhancedStreamable(ToolInfo.function(name: 'estr'),
                (ctx, input, options) {
              seen.add('estr ${age(options)}');
              return StreamReader.fromIterable([ToolResult.text('r')]);
            }),
          ],
          toolCallMiddlewares: [
            ToolMiddleware(
              invokable: (next) => (ctx, input) {
                seen.add('middleware ${age(input.callOptions)}');
                return next(ctx, input);
              },
            ),
          ],
        ),
      );
    });

    final input = _calls([
      ('1', 'inv', ''),
      ('2', 'str', ''),
      ('3', 'einv', ''),
      ('4', 'estr', ''),
    ]);

    List<String> all(Object? age) =>
        ['middleware $age', 'inv $age', 'str $age', 'einv $age', 'estr $age'];

    test('ToolsNodeOptions.toolOptions reach every kind of tool', () async {
      await node.invokeTools(
        ctx,
        input,
        options: ToolsNodeOptions(toolOptions: _withAge(10)),
      );
      expect(seen, all(10));

      seen.clear();
      await _readAll(
        await node.streamTools(
          ctx,
          input,
          options: ToolsNodeOptions(toolOptions: _withAge(11)),
        ),
      );
      expect(seen, all(11));
    });

    test('without options a tool gets none', () async {
      await node.invokeTools(ctx, input);
      expect(seen, all(null));

      seen.clear();
      await _readAll(await node.stream(ctx, input));
      expect(seen, all(null));
    });

    test('CallOption.tool reaches the tools of a node run as a Runnable',
        () async {
      await node.invoke(ctx, input, options: [CallOption.tool(_withAge(12))]);
      expect(seen, all(12));

      seen.clear();
      await _readAll(
        await node.stream(ctx, input, options: [CallOption.tool(_withAge(13))]),
      );
      expect(seen, all(13));
    });

    test('the tool options of several call options are added up', () async {
      await node.invoke(
        ctx,
        input,
        options: [
          CallOption.tool(const ToolOptions(extensions: ['first'])),
          CallOption.toolsNode(ToolsNodeOptions(toolOptions: _withAge(14))),
        ],
      );
      expect(seen, all(14));

      String? word;
      final wordy = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('inv', (ctx, arguments, options) {
              word = options?.extension<String>();
              return age(options);
            }),
          ],
        ),
      );
      final out = await wordy.invoke(
        ctx,
        _calls([('1', 'inv', '')]),
        options: [
          CallOption.tool(const ToolOptions(extensions: ['first'])),
          CallOption.toolsNode(ToolsNodeOptions(toolOptions: _withAge(14))),
        ],
      );
      expect(out.single.content, '14');
      expect(word, 'first');
    });

    test('CallOption.tool reaches the tools of a node in a graph and in a '
        'chain', () async {
      final graph = Graph<Message, List<Message>>()
        ..addToolsNode('tools', node)
        ..addEdge(Graph.start, 'tools')
        ..addEdge('tools', Graph.end);
      final r = await graph.compile(ctx);

      await r.invoke(ctx, input, options: [CallOption.tool(_withAge(15))]);
      expect(seen, all(15));

      seen.clear();
      await _readAll(
        await r.stream(
          ctx,
          input,
          options: [
            CallOption.tool(_withAge(16)).designateNode(['tools']),
          ],
        ),
      );
      expect(seen, all(16));

      final chain = Chain<Message, List<Message>>()..appendToolsNode(node);
      final c = await chain.compile(ctx);

      seen.clear();
      await c.invoke(ctx, input, options: [CallOption.tool(_withAge(17))]);
      expect(seen, all(17));

      seen.clear();
      await _readAll(
        await c.stream(ctx, input, options: [CallOption.tool(_withAge(18))]),
      );
      expect(seen, all(18));
    });
  });

  group('ToolsNode: tool contracts', () {
    test('a tool that only streams can be invoked: its chunks are joined',
        () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Streamable(
              'stream',
              (ctx, arguments, _) =>
                  StreamReader.fromIterable(['a', 'b', arguments]),
            ),
            _EnhancedStreamable(
              ToolInfo.function(name: 'estream'),
              (ctx, input, _) => StreamReader.fromIterable([
                ToolResult.text('a'),
                ToolResult.text('b'),
                ToolResult.text(input.text),
              ]),
            ),
          ],
        ),
      );
      final input = _calls([('1', 'stream', 'c'), ('2', 'estream', 'c')]);

      final out = await node.invokeTools(ctx, input);
      expect(out[0].content, 'abc');
      expect(out[1].content, isEmpty);
      // The text parts of the chunks become one part (Go `ConcatToolResults`).
      expect(out[1].userInputMultiContent, hasLength(1));
      expect(_firstPartText(out[1]), 'abc');

      // Streamed, every chunk of the tool is a chunk of the node.
      final chunks = await _readAll(await node.streamTools(ctx, input));
      expect(chunks, hasLength(6));
      expect(
        [for (final chunk in chunks) chunk[0].content].join(),
        'abc',
      );
      expect(
        [
          for (final chunk in chunks)
            if (chunk[1].userInputMultiContent != null) _firstPartText(chunk[1]),
        ],
        ['a', 'b', 'c'],
      );
    });

    test('a tool that is only invokable can be streamed: one chunk', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('inv', (ctx, arguments, _) => 'result of $arguments'),
          ],
        ),
      );
      final input = _calls([('1', 'inv', 'x')]);

      final chunks = await _readAll(await node.streamTools(ctx, input));
      expect(chunks, [
        [
          Message.tool(
            content: 'result of x',
            toolCallId: '1',
            toolName: 'inv',
          ),
        ],
      ]);
      expect(await node.invokeTools(ctx, input), chunks.single);
    });

    test('an error inside the stream of a tool reaches the reader of the '
        'node', () async {
      final broken = Exception('broken pipe');
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Streamable('stream', (ctx, arguments, _) async {
              final (reader, writer) = pipe<String>(capacity: 2);
              writer
                ..send('a')
                ..sendError(broken);
              await writer.close();
              return reader;
            }),
          ],
        ),
      );
      final input = _calls([('1', 'stream', '')]);

      final reader = await node.streamTools(ctx, input);
      addTearDown(reader.close);
      expect((await reader.recv()).single.content, 'a');
      await expectLater(reader.recv(), throwsA(same(broken)));
      await expectLater(reader.recv(), throwsA(isA<StreamEOFException>()));
    });

    test('a tool that cannot be run in any way is refused', () async {
      await expectLater(
        ToolsNode.create(ToolsNodeConfig(tools: [_InfoOnly()])),
        throwsA(
          _toolsNodeFailure(
            message: 'tool info_only is not invokable, streamable, enhanced '
                'invokable or enhanced streamable',
          ),
        ),
      );
    });

    test('a tool whose info() fails is refused, with its position', () async {
      await expectLater(
        ToolsNode.create(
          ToolsNodeConfig(
            tools: [_Invokable('ok', (ctx, arguments, _) => ''), _NoInfo()],
          ),
        ),
        throwsA(
          _toolsNodeFailure(
            message: allOf(
              startsWith('(NewToolNode) failed to get tool info at idx= 1: '),
              contains('no info today'),
            ),
            cause: isA<StateError>(),
          ),
        ),
      );
    });

    test('the plain constructor checks the configuration on first use',
        () async {
      final node = ToolsNode(ToolsNodeConfig(tools: [_InfoOnly()]));
      final input = _calls([('1', 'info_only', '')]);
      final failure = _toolsNodeFailure(
        message: contains('tool info_only is not invokable'),
      );

      await expectLater(node.invokeTools(ctx, input), throwsA(failure));
      await expectLater(node.streamTools(ctx, input), throwsA(failure));
    });

    test('a bad tool list in the call options fails that call', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [_Invokable('ok', (ctx, arguments, _) => 'fine')],
        ),
      );
      final input = _calls([('1', 'ok', '')]);
      final failure = _toolsNodeFailure(
        message: allOf(
          startsWith('failed to convert tool list from call option: '),
          contains('tool info_only is not invokable'),
        ),
      );
      final options = ToolsNodeOptions(toolList: [_InfoOnly()]);

      await expectLater(
        node.invokeTools(ctx, input, options: options),
        throwsA(failure),
      );
      await expectLater(
        node.streamTools(ctx, input, options: options),
        throwsA(failure),
      );
      // The node itself is as it was.
      expect((await node.invokeTools(ctx, input)).single.content, 'fine');
    });

    test('collect and transform take the message as a stream', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [_Invokable('echo', (ctx, arguments, _) => arguments)],
        ),
      );
      final input = _calls([('1', 'echo', 'x')]);

      final collected =
          await node.collect(ctx, StreamReader.fromIterable([input]));
      expect(collected.single.content, 'x');

      final chunks = await _readAll(
        await node.transform(ctx, StreamReader.fromIterable([input])),
      );
      expect(concatMessageArray(chunks), collected);
    });
  });

  group('ToolsNode: input message', () {
    late ToolsNode node;

    setUp(() async {
      node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [_Invokable('echo', (ctx, arguments, _) => arguments)],
        ),
      );
    });

    test('a message that is not an assistant message is refused', () async {
      for (final (message, role) in [
        (Message.user('hi'), 'user'),
        (Message.system('hi'), 'system'),
        (Message.tool(content: 'hi', toolCallId: '1'), 'tool'),
      ]) {
        final failure = _toolsNodeFailure(
          message: 'expected message role is Assistant, got $role',
        );
        await expectLater(node.invokeTools(ctx, message), throwsA(failure));
        await expectLater(node.streamTools(ctx, message), throwsA(failure));
        await expectLater(node.invoke(ctx, message), throwsA(failure));
        await expectLater(node.stream(ctx, message), throwsA(failure));
      }
    });

    test('an assistant message without tool calls is refused', () async {
      final failure =
          _toolsNodeFailure(message: 'no tool call found in input message');
      for (final message in [
        Message.assistant('just text'),
        Message.assistant('', toolCalls: const []),
      ]) {
        await expectLater(node.invokeTools(ctx, message), throwsA(failure));
        await expectLater(node.streamTools(ctx, message), throwsA(failure));
      }
    });

    test('a call of a tool the node does not have is refused when there is '
        'no unknown tools handler', () async {
      var runs = 0;
      final counting = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('echo', (ctx, arguments, _) {
              runs++;
              return arguments;
            }),
          ],
        ),
      );
      final input = _calls([('1', 'echo', ''), ('2', 'nope', '')]);
      final failure = _toolsNodeFailure(
        message: 'tool nope not found in toolsNode indexes',
        toolName: 'nope',
        callId: '2',
      );

      await expectLater(counting.invokeTools(ctx, input), throwsA(failure));
      await expectLater(counting.streamTools(ctx, input), throwsA(failure));
      // No call of the message is run.
      expect(runs, 0);
    });

    test('in a graph the failure is that of the node', () async {
      final graph = Graph<Message, List<Message>>()
        ..addToolsNode('tools', node)
        ..addEdge(Graph.start, 'tools')
        ..addEdge('tools', Graph.end);
      final r = await graph.compile(ctx);
      final failure = isA<NodeExecutionException>()
          .having((e) => e.nodePath.path, 'nodePath', ['tools'])
          .having(
            (e) => e.cause,
            'cause',
            _toolsNodeFailure(
              message: 'expected message role is Assistant, got user',
            ),
          )
          .having(
            (e) => e.toString(),
            'text',
            contains('expected message role is Assistant, got user'),
          );

      await expectLater(r.invoke(ctx, Message.user('hi')), throwsA(failure));
      await expectLater(r.stream(ctx, Message.user('hi')), throwsA(failure));
    });
  });

  group('ToolsNode: interrupts', () {
    const signal = _Pause('ask the user');
    late List<String> ran;

    setUp(() => ran = []);

    Future<ToolsNode> nodeWith(BaseTool pausing) => ToolsNode.create(
          ToolsNodeConfig(
            tools: [
              _Invokable('before', (ctx, arguments, _) {
                ran.add('before');
                return 'before';
              }),
              pausing,
              _Streamable('after', (ctx, arguments, _) {
                ran.add('after');
                return StreamReader.fromIterable(['after']);
              }),
            ],
            // A middleware that does not catch lets it pass.
            toolCallMiddlewares: [
              ToolMiddleware(
                invokable: (next) => (ctx, input) => next(ctx, input),
                streamable: (next) => (ctx, input) => next(ctx, input),
                enhancedInvokable: (next) => (ctx, input) => next(ctx, input),
                enhancedStreamable: (next) => (ctx, input) => next(ctx, input),
              ),
            ],
          ),
        );

    final input = _calls([
      ('1', 'before', ''),
      ('2', 'pause', ''),
      ('3', 'after', ''),
    ]);

    final pausingTools = <String, BaseTool Function(Object thrown)>{
      'an invokable tool': (thrown) =>
          _Invokable('pause', (ctx, arguments, _) => throw thrown),
      'a streamable tool': (thrown) =>
          _Streamable('pause', (ctx, arguments, _) => throw thrown),
      'an enhanced invokable tool': (thrown) => _EnhancedInvokable(
            ToolInfo.function(name: 'pause'),
            (ctx, input, _) => throw thrown,
          ),
      'an enhanced streamable tool': (thrown) => _EnhancedStreamable(
            ToolInfo.function(name: 'pause'),
            (ctx, input, _) => throw thrown,
          ),
    };

    for (final MapEntry(key: kind, value: make) in pausingTools.entries) {
      test('thrown by $kind, the signal leaves the node as it is', () async {
        expect(isInterrupt(signal), isTrue);
        final node = await nodeWith(make(signal));

        await expectLater(node.invokeTools(ctx, input), throwsA(same(signal)));
        // The other calls of the message are run all the same.
        expect(ran, unorderedEquals(['before', 'after']));

        ran.clear();
        await expectLater(node.streamTools(ctx, input), throwsA(same(signal)));
        expect(ran, unorderedEquals(['before', 'after']));

        await expectLater(node.invoke(ctx, input), throwsA(same(signal)));
        await expectLater(node.stream(ctx, input), throwsA(same(signal)));
      });
    }

    test('a signal that arrives wrapped in another error passes as well',
        () async {
      const wrapped = ThreepioException('nested agent paused', cause: signal);
      expect(isInterrupt(wrapped), isTrue);
      final node = await nodeWith(
        _Invokable('pause', (ctx, arguments, _) => throw wrapped),
      );

      await expectLater(node.invokeTools(ctx, input), throwsA(same(wrapped)));
      await expectLater(node.streamTools(ctx, input), throwsA(same(wrapped)));
    });

    test('a failure of another call is reported instead, wherever it is in '
        'the message', () async {
      final boom = Exception('boom');
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('pause', (ctx, arguments, _) => throw signal),
            _Invokable('fail', (ctx, arguments, _) => throw boom),
          ],
        ),
      );

      for (final order in [
        [('1', 'pause', ''), ('2', 'fail', '')],
        [('2', 'fail', ''), ('1', 'pause', '')],
      ]) {
        final failure =
            _toolsNodeFailure(toolName: 'fail', callId: '2', cause: same(boom));
        await expectLater(
          node.invokeTools(ctx, _calls(order)),
          throwsA(failure),
        );
        await expectLater(
          node.streamTools(ctx, _calls(order)),
          throwsA(failure),
        );
      }
    });

    test('thrown by the arguments handler, the signal passes', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [_Invokable('echo', (ctx, arguments, _) => arguments)],
          toolArgumentsHandler: (ctx, name, arguments) => throw signal,
        ),
      );
      final input = _calls([('1', 'echo', '')]);

      await expectLater(node.invokeTools(ctx, input), throwsA(same(signal)));
      await expectLater(node.streamTools(ctx, input), throwsA(same(signal)));
    });

    test('in a graph the signal is still an interrupt', () async {
      final node = await nodeWith(
        _Invokable('pause', (ctx, arguments, _) => throw signal),
      );
      final graph = Graph<Message, List<Message>>()
        ..addToolsNode('tools', node)
        ..addEdge(Graph.start, 'tools')
        ..addEdge('tools', Graph.end);
      final r = await graph.compile(ctx);

      await expectLater(
        r.invoke(ctx, input),
        throwsA(predicate(isInterrupt, 'is an interrupt')),
      );
      await expectLater(
        r.stream(ctx, input),
        throwsA(predicate(isInterrupt, 'is an interrupt')),
      );
    });
  });
}
