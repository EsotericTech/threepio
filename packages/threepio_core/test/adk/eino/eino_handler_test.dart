// Port of eino v0.9.22 adk/handler_test.go and adk/wrappers_test.go (classic
// messages only).
//
// From handler_test.go: TestRunLocalValueFunctions, TestHandlerExecutionOrder,
// TestHandlerErrorPropagation, TestMessageRewriteHandlers,
// TestModelWrapperHandlers, TestToolCallWrapperHandlers,
// TestToolContextInWrappers.
// From wrappers_test.go: TestEnhancedToolArgumentsPropagation,
// TestEnhancedToolResultPropagation, TestEventSenderToolHandler.
//
// Not ported: TestHandlerExecutionOrder/MiddlewaresBeforeHandlers (it needs the
// deprecated `Middlewares`/`AgentMiddleware`, which is not ported).
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/event_senders.dart'
    show handlersToToolMiddlewares;

// ---------------------------------------------------------------------------
// Fakes (Go: gomock MockToolCallingChatModel and the test tools/handlers).
// ---------------------------------------------------------------------------

typedef _GenerateFn = Future<Message> Function(
  List<Message> input,
  ChatModelOptions? options,
);
typedef _StreamFn = Future<StreamReader<Message>> Function(
  List<Message> input,
  ChatModelOptions? options,
);

/// Port of `mockModel.NewMockToolCallingChatModel`: every `EXPECT()...Times(1)`
/// is one entry of [generate] / [stream], answered in order; a call beyond the
/// script throws (gomock's "unexpected call"). `WithTools` returns the model.
class _MockModel extends ToolCallingChatModel {
  _MockModel({
    List<_GenerateFn> generate = const [],
    List<_StreamFn> stream = const [],
  })  : _generate = generate,
        _stream = stream;

  final List<_GenerateFn> _generate;
  final List<_StreamFn> _stream;
  int generateCalls = 0;
  int streamCalls = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final i = generateCalls++;
    if (i >= _generate.length) {
      throw StateError('unexpected Generate call #${i + 1}');
    }
    return _generate[i](input, options);
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final i = streamCalls++;
    if (i >= _stream.length) {
      throw StateError('unexpected Stream call #${i + 1}');
    }
    return _stream[i](input, options);
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

_GenerateFn _returns(Message message) => (_, _) async => message;

_StreamFn _streams(List<Message> chunks) =>
    (_, _) async => StreamReader.fromIterable(chunks);

Message _toolCallMessage(String content, String id, String name, String args) =>
    Message.assistant(
      content,
      toolCalls: [
        ToolCall(id: id, function: FunctionCall(name: name, arguments: args)),
      ],
    );

/// Port of `assert.AnError`.
class _AnError implements Exception {
  const _AnError();

  @override
  String toString() =>
      'assert.AnError general error for testing';
}

/// Port of `namedTool`.
class _NamedTool extends InvokableTool {
  _NamedTool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.function(name: name, description: '$name description');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      '$name result';
}

/// Port of `streamingNamedTool`.
class _StreamingNamedTool extends InvokableTool implements StreamableTool {
  _StreamingNamedTool(this.name);

  final String name;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.function(name: name, description: '$name description');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      '$name result';

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      StreamReader.fromIterable(['$name stream result']);

  @override
  Future<StreamReader<String>> streamRun(String argumentsJson) =>
      streamableRun(RunContext.background(), argumentsJson);
}

/// Port of `testInstructionHandler`.
class _InstructionHandler extends ChatModelAgentMiddleware {
  const _InstructionHandler(this.text);

  final String text;

  @override
  (RunContext, ChatModelAgentContext) beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) {
    if (agent.instruction.isEmpty) {
      agent.instruction = text;
    } else if (text.isNotEmpty) {
      agent.instruction = '${agent.instruction}\n$text';
    }
    return (ctx, agent);
  }
}

/// Port of `testInstructionFuncHandler`.
class _InstructionFuncHandler extends ChatModelAgentMiddleware {
  const _InstructionFuncHandler(this.fn);

  final FutureOr<(RunContext, String)> Function(
    RunContext ctx,
    String instruction,
  ) fn;

  @override
  Future<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) async {
    final (newCtx, newInstruction) = await fn(ctx, agent.instruction);
    agent.instruction = newInstruction;
    return (newCtx, agent);
  }
}

typedef _StateHook = FutureOr<(RunContext, ChatModelAgentState)> Function(
  RunContext ctx,
  ChatModelAgentState state,
  ModelContext model,
);

/// Port of `testBeforeModelRewriteStateHandler`.
class _BeforeModelRewriteState extends ChatModelAgentMiddleware {
  const _BeforeModelRewriteState(this.fn);

  final _StateHook fn;

  @override
  FutureOr<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) =>
      fn(ctx, state, model);
}

/// Port of `testAfterModelRewriteStateHandler`.
class _AfterModelRewriteState extends ChatModelAgentMiddleware {
  const _AfterModelRewriteState(this.fn);

  final _StateHook fn;

  @override
  FutureOr<(RunContext, ChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) =>
      fn(ctx, state, model);
}

/// Port of `testToolWrapperHandler`.
class _ToolWrapperHandler extends ChatModelAgentMiddleware {
  const _ToolWrapperHandler({this.wrapInvokable, this.wrapStreamable});

  final InvokableToolCallEndpoint Function(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  )? wrapInvokable;
  final StreamableToolCallEndpoint Function(
    RunContext ctx,
    StreamableToolCallEndpoint next,
    ToolContext tool,
  )? wrapStreamable;

  @override
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      wrapInvokable?.call(ctx, next, tool) ?? next;

  @override
  StreamableToolCallEndpoint wrapStreamableToolCall(
    RunContext ctx,
    StreamableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      wrapStreamable?.call(ctx, next, tool) ?? next;
}

/// Port of `testModelWrapperHandler`.
class _ModelWrapperHandler extends ChatModelAgentMiddleware {
  const _ModelWrapperHandler(this.fn);

  final BaseChatModel Function(
    RunContext ctx,
    BaseChatModel model,
    ModelContext context,
  ) fn;

  @override
  BaseChatModel wrapModel(
    RunContext ctx,
    BaseChatModel model,
    ModelContext context,
  ) =>
      fn(ctx, model, context);
}

/// Port of `newTestInvokableToolCallWrapper`.
InvokableToolCallEndpoint Function(
  RunContext,
  InvokableToolCallEndpoint,
  ToolContext,
) _invokableWrapper(void Function()? before, void Function()? after) =>
    (_, endpoint, _) => (ctx, args, options) async {
          before?.call();
          try {
            return await endpoint(ctx, args, options);
          } finally {
            after?.call();
          }
        };

/// Port of `newResultModifyingInvokableToolCallWrapper`.
InvokableToolCallEndpoint Function(
  RunContext,
  InvokableToolCallEndpoint,
  ToolContext,
) _resultModifyingWrapper(String Function(String) modify) =>
    (_, endpoint, _) => (ctx, args, options) async =>
        modify(await endpoint(ctx, args, options));

/// Port of `newTestStreamableToolCallWrapper`.
StreamableToolCallEndpoint Function(
  RunContext,
  StreamableToolCallEndpoint,
  ToolContext,
) _streamableWrapper(void Function()? before, void Function()? after) =>
    (_, endpoint, _) => (ctx, args, options) async {
          before?.call();
          try {
            return await endpoint(ctx, args, options);
          } finally {
            after?.call();
          }
        };

/// Port of `testWrappedModel`.
class _TestWrappedModel extends BaseChatModel {
  _TestWrappedModel(this.inner, this.before, this.after);

  final BaseChatModel inner;
  final void Function()? before;
  final void Function()? after;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    before?.call();
    try {
      return await inner.generate(input, options: options);
    } finally {
      after?.call();
    }
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    before?.call();
    try {
      return await inner.stream(input, options: options);
    } finally {
      after?.call();
    }
  }
}

/// Port of `newTestModelWrapperFn`.
BaseChatModel Function(RunContext, BaseChatModel, ModelContext)
    _modelWrapperFn(void Function()? before, void Function()? after) =>
        (_, model, _) => _TestWrappedModel(model, before, after);

// --- wrappers_test.go fakes ---

/// Port of `testEnhancedToolWrapperHandler`.
class _EnhancedToolWrapperHandler extends ChatModelAgentMiddleware {
  const _EnhancedToolWrapperHandler({this.wrapEnhancedInvokable});

  final EnhancedInvokableToolCallEndpoint Function(
    RunContext ctx,
    EnhancedInvokableToolCallEndpoint next,
    ToolContext tool,
  )? wrapEnhancedInvokable;

  @override
  EnhancedInvokableToolCallEndpoint wrapEnhancedInvokableToolCall(
    RunContext ctx,
    EnhancedInvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      wrapEnhancedInvokable?.call(ctx, next, tool) ?? next;
}

/// Port of `mockToolCallingModel`: a tool call on the first call, then "done".
class _MockToolCallingModel extends ToolCallingChatModel {
  _MockToolCallingModel(this.toolCallName);

  final String toolCallName;
  int generateCalls = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    generateCalls++;
    if (generateCalls == 1) {
      return _toolCallMessage(
        'calling tool',
        'tc-1',
        toolCallName,
        '{"input":"test"}',
      );
    }
    return Message.assistant('done');
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

ToolInfo _testToolInfo(String name) => ToolInfo.fromParams(
      name: name,
      desc: 'test tool',
      params: const {
        'input': ParameterInfo(
          type: DataType.string,
          desc: 'input',
          required: true,
        ),
      },
    );

/// Port of `invokableTestTool`.
class _InvokableTestTool extends InvokableTool {
  _InvokableTestTool(this.name, this.result);

  final String name;
  final String result;

  @override
  Future<ToolInfo> info() async => _testToolInfo(name);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      result;
}

/// Port of `streamableTestTool`.
class _StreamableTestTool extends StreamableTool {
  _StreamableTestTool(this.name, this.result);

  final String name;
  final String result;

  @override
  Future<ToolInfo> info() async => _testToolInfo(name);

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      StreamReader.fromIterable([result]);
}

/// Port of `enhancedInvokableTestTool`.
class _EnhancedInvokableTestTool implements EnhancedInvokableTool {
  _EnhancedInvokableTestTool(this.name, this.result);

  final String name;
  final String result;

  @override
  Future<ToolInfo> info() async => _testToolInfo(name);

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      ToolResult([ToolOutputPart.text(result)]);
}

/// Port of `enhancedStreamableTestTool`.
class _EnhancedStreamableTestTool implements EnhancedStreamableTool {
  _EnhancedStreamableTestTool(this.name, this.result);

  final String name;
  final String result;

  @override
  Future<ToolInfo> info() async => _testToolInfo(name);

  @override
  Future<StreamReader<ToolResult>> enhancedStreamableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      StreamReader.fromIterable([
        ToolResult([ToolOutputPart.text(result)]),
      ]);
}

/// Port of `invokableResultModifier`.
class _InvokableResultModifier extends ChatModelAgentMiddleware {
  const _InvokableResultModifier(this.modifiedResult);

  final String modifiedResult;

  @override
  InvokableToolCallEndpoint wrapInvokableToolCall(
    RunContext ctx,
    InvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, args, options) async {
        await next(ctx, args, options);
        return modifiedResult;
      };
}

/// Port of `streamableResultModifier`.
class _StreamableResultModifier extends ChatModelAgentMiddleware {
  const _StreamableResultModifier(this.modifiedResult);

  final String modifiedResult;

  @override
  StreamableToolCallEndpoint wrapStreamableToolCall(
    RunContext ctx,
    StreamableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, args, options) async {
        final sr = await next(ctx, args, options);
        await sr.close();
        return StreamReader.fromIterable([modifiedResult]);
      };
}

/// Port of `enhancedInvokableResultModifier`.
class _EnhancedInvokableResultModifier extends ChatModelAgentMiddleware {
  const _EnhancedInvokableResultModifier(this.modifiedResult);

  final String modifiedResult;

  @override
  EnhancedInvokableToolCallEndpoint wrapEnhancedInvokableToolCall(
    RunContext ctx,
    EnhancedInvokableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, argument, options) async {
        await next(ctx, argument, options);
        return ToolResult([ToolOutputPart.text(modifiedResult)]);
      };
}

/// Port of `enhancedStreamableResultModifier`.
class _EnhancedStreamableResultModifier extends ChatModelAgentMiddleware {
  const _EnhancedStreamableResultModifier(this.modifiedResult);

  final String modifiedResult;

  @override
  EnhancedStreamableToolCallEndpoint wrapEnhancedStreamableToolCall(
    RunContext ctx,
    EnhancedStreamableToolCallEndpoint next,
    ToolContext tool,
  ) =>
      (ctx, argument, options) async {
        final sr = await next(ctx, argument, options);
        await sr.close();
        return StreamReader.fromIterable([
          ToolResult([ToolOutputPart.text(modifiedResult)]),
        ]);
      };
}

/// Port of `collectToolEvents`.
Future<List<AgentEvent>> _collectToolEvents(StreamReader<AgentEvent> it) async {
  final toolEvents = <AgentEvent>[];
  for (var ev = await it.nextOrNull(); ev != null; ev = await it.nextOrNull()) {
    final mo = ev.output?.messageOutput;
    if (mo == null) continue;
    final message = mo.message;
    if (message != null && message.role == RoleType.tool) {
      toolEvents.add(ev);
      continue;
    }
    if (mo.isStreaming && mo.role == RoleType.tool && mo.messageStream != null) {
      toolEvents.add(ev);
    }
  }
  return toolEvents;
}

void _addTexts(List<String> contents, Message message) {
  if (message.content.isNotEmpty) {
    contents.add(message.content);
  } else {
    for (final part in message.userInputMultiContent ?? const <MessageInputPart>[]) {
      final text = part.text;
      if (text != null && text.isNotEmpty) contents.add(text);
    }
  }
}

/// Port of `collectToolContent`.
Future<List<String>> _collectToolContent(List<AgentEvent> events) async {
  final contents = <String>[];
  for (final ev in events) {
    final mo = ev.output!.messageOutput!;
    final message = mo.message;
    if (!mo.isStreaming && message != null) {
      _addTexts(contents, message);
      continue;
    }
    final stream = mo.messageStream;
    if (mo.isStreaming && stream != null) {
      final msgs = <Message>[];
      while (true) {
        Message? msg;
        try {
          msg = await stream.nextOrNull();
          // Go: any Recv error ends the loop.
          // ignore: avoid_catches_without_on_clauses
        } catch (_) {
          break;
        }
        if (msg == null) break;
        msgs.add(msg);
      }
      if (msgs.isNotEmpty) {
        try {
          _addTexts(contents, concatMessages(msgs));
          // Go: a concat error is ignored.
          // ignore: avoid_catches_without_on_clauses
        } catch (_) {}
      }
    }
  }
  return contents;
}

Future<void> _drain(StreamReader<AgentEvent> events) async {
  while (await events.nextOrNull() != null) {}
}

AgentInput _input(String text) => AgentInput(messages: [Message.user(text)]);

void main() {
  final ctx = RunContext.background();

  group('TestRunLocalValueFunctions', () {
    test('SetAndGetRunLocalValue', () async {
      Object? capturedValue;
      Object? setError;
      final cm = _MockModel(generate: [_returns(Message.assistant('response'))]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        handlers: [
          _BeforeModelRewriteState((ctx, state, _) {
            try {
              ctx.setRunLocalValue('test_key', 'test_value');
              // Recorded and asserted outside the hook.
              // ignore: avoid_catches_without_on_clauses
            } catch (e) {
              setError = e;
            }
            return (ctx, state);
          }),
          _AfterModelRewriteState((ctx, state, _) {
            capturedValue = ctx.runLocalValue('test_key');
            return (ctx, state);
          }),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(setError, isNull);
      // Go also asserts `found`; Dart's runLocalValue returns null when the key
      // is missing, so a non-null value is the "found" check.
      expect(capturedValue, 'test_value', reason: 'Value should match what was set');
      expect(cm.generateCalls, 1);
    });

    test('DeleteRunLocalValue', () async {
      Object? valueAfterDelete = 'sentinel';
      Object? hookError;
      final cm = _MockModel(generate: [_returns(Message.assistant('response'))]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        handlers: [
          _BeforeModelRewriteState((ctx, state, _) {
            try {
              ctx
                ..setRunLocalValue('delete_key', 'delete_value')
                ..deleteRunLocalValue('delete_key');
              // ignore: avoid_catches_without_on_clauses
            } catch (e) {
              hookError = e;
            }
            return (ctx, state);
          }),
          _AfterModelRewriteState((ctx, state, _) {
            valueAfterDelete = ctx.runLocalValue('delete_key');
            return (ctx, state);
          }),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(hookError, isNull);
      expect(valueAfterDelete, isNull, reason: 'Value should be nil after deletion');
      expect(cm.generateCalls, 1);
    });

    test('GetNonExistentKey', () async {
      Object? capturedValue = 'sentinel';
      final cm = _MockModel(generate: [_returns(Message.assistant('response'))]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        handlers: [
          _BeforeModelRewriteState((ctx, state, _) {
            capturedValue = ctx.runLocalValue('non_existent_key');
            return (ctx, state);
          }),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(capturedValue, isNull, reason: 'Non-existent key should return nil value');
      expect(cm.generateCalls, 1);
    });

    // Go calls the internal `checkGobEncodability`; Dart checks that a value
    // can be written to a (JSON) checkpoint inside `setRunLocalValue`, so the
    // check is exercised through it, inside a run. The hints name the Dart
    // equivalents: TypeRegistry.registerName for schema.RegisterName, the
    // RunContext for context.WithValue.
    test('RunLocalValueGobEncodabilityCheck', () async {
      Object? unregisteredError;
      final primitiveErrors = <Object>[];
      final cm = _MockModel(generate: [_returns(Message.assistant('response'))]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        handlers: [
          _BeforeModelRewriteState((ctx, state, _) {
            try {
              ctx.setRunLocalValue('key', const _UnregisteredType('hello'));
              // ignore: avoid_catches_without_on_clauses
            } catch (e) {
              unregisteredError = e;
            }
            for (final value in <Object>['hello', 42, true, 3.14]) {
              try {
                ctx.setRunLocalValue('key', value);
                // ignore: avoid_catches_without_on_clauses
              } catch (e) {
                primitiveErrors.add(e);
              }
            }
            return (ctx, state);
          }),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(unregisteredError, isNotNull);
      final text = '$unregisteredError';
      expect(text, contains('cannot be written to a checkpoint'));
      expect(text, contains('TypeRegistry.registerName'));
      expect(text, contains('RunContext'));
      expect(text, contains('_UnregisteredType'));
      expect(primitiveErrors, isEmpty);
    });

    // Go names the functions SetRunLocalValue/GetRunLocalValue/
    // DeleteRunLocalValue; the Dart messages name the Dart members.
    test('RunLocalValueOutsideContext', () {
      expect(
        () => ctx.setRunLocalValue('key', 'value'),
        throwsA(predicate((e) => '$e'.contains('setRunLocalValue failed'))),
      );
      expect(
        () => ctx.runLocalValue('key'),
        throwsA(predicate((e) => '$e'.contains('runLocalValue failed'))),
      );
      expect(
        () => ctx.deleteRunLocalValue('key'),
        throwsA(predicate((e) => '$e'.contains('deleteRunLocalValue failed'))),
      );
    });

    test('RunLocalValuePersistsAcrossModelCalls', () async {
      final testTool = _NamedTool('test_tool');
      final info = await testTool.info();
      Object? firstCallValue;
      Object? secondCallValue;
      var callCount = 0;

      final cm = _MockModel(generate: [
        _returns(_toolCallMessage('Using tool', 'call1', info.function.name, '{}')),
        _returns(Message.assistant('done')),
      ]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [testTool])),
        handlers: [
          _BeforeModelRewriteState((ctx, state, _) {
            callCount++;
            if (callCount == 1) {
              ctx.setRunLocalValue('persist_key', 'persist_value');
              firstCallValue = ctx.runLocalValue('persist_key');
            } else {
              secondCallValue = ctx.runLocalValue('persist_key');
            }
            return (ctx, state);
          }),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(firstCallValue, 'persist_value', reason: 'First call should set value');
      expect(secondCallValue, 'persist_value', reason: 'Value should persist to second model call');
      expect(cm.generateCalls, 2);
    });
  });

  group('TestHandlerExecutionOrder', () {
    test('MultipleInstructionHandlersPipeline', () async {
      var capturedInstruction = '';
      final cm = _MockModel(generate: [
        (msgs, _) async {
          if (msgs.isNotEmpty && msgs[0].role == RoleType.system) {
            capturedInstruction = msgs[0].content;
          }
          return Message.assistant('response');
        },
      ]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        instruction: 'Base instruction.',
        model: cm,
        handlers: [
          const _InstructionHandler('Handler 1 addition.'),
          const _InstructionHandler('Handler 2 addition.'),
          _InstructionFuncHandler(
            (ctx, instruction) => (ctx, '$instruction\nHandler 3 dynamic.'),
          ),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(capturedInstruction, contains('Base instruction.'));
      expect(capturedInstruction, contains('Handler 1 addition.'));
      expect(capturedInstruction, contains('Handler 2 addition.'));
      expect(capturedInstruction, contains('Handler 3 dynamic.'));
      expect(cm.generateCalls, 1);
    });

    // MiddlewaresBeforeHandlers: not ported (deprecated Middlewares).
  });

  group('TestHandlerErrorPropagation', () {
    test('BeforeModelRewriteStateErrorStopsRun', () async {
      final cm = _MockModel();
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        handlers: [
          _BeforeModelRewriteState((ctx, state, _) => throw const _AnError()),
        ],
      ));

      Object? gotErr;
      final events = agent.run(ctx, _input('test'));
      for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
        if (e.error != null) gotErr = e.error;
      }

      expect(gotErr, isNotNull);
      expect(cm.generateCalls, 0);
    });

    test('AfterModelRewriteStateErrorStopsRun', () async {
      final cm = _MockModel(generate: [_returns(Message.assistant('response'))]);
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        handlers: [
          _AfterModelRewriteState((ctx, state, _) => throw const _AnError()),
        ],
      ));

      Object? gotErr;
      final events = agent.run(ctx, _input('test'));
      for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
        if (e.error != null) gotErr = e.error;
      }

      expect(gotErr, isNotNull);
      expect(cm.generateCalls, 1);
    });

    test('MultipleHandlersFirstErrorStops', () async {
      var secondHandlerCalled = false;
      final cm = _MockModel();
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        handlers: [
          _BeforeModelRewriteState((ctx, state, _) => throw const _AnError()),
          _BeforeModelRewriteState((ctx, state, _) {
            secondHandlerCalled = true;
            return (ctx, state);
          }),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(secondHandlerCalled, isFalse,
          reason: 'Second handler should not be called after first handler error');
      expect(cm.generateCalls, 0);
    });
  });

  group('TestMessageRewriteHandlers', () {
    test('BeforeModelRewriteStatePipeline', () async {
      var capturedMsgCount = 0;
      final cm = _MockModel(generate: [
        (msgs, _) async {
          capturedMsgCount = msgs.length;
          return Message.assistant('response');
        },
      ]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        instruction: 'instruction',
        model: cm,
        handlers: [
          _BeforeModelRewriteState((ctx, state, _) {
            state.messages = [...state.messages, Message.user('injected1')];
            return (ctx, state);
          }),
          _BeforeModelRewriteState((ctx, state, _) {
            state.messages = [...state.messages, Message.user('injected2')];
            return (ctx, state);
          }),
        ],
      ));

      await _drain(agent.run(ctx, _input('original')));

      expect(capturedMsgCount, 4);
      expect(cm.generateCalls, 1);
    });

    test('AfterModelRewriteState', () async {
      var afterCalled = false;
      var messageCount = 0;
      RoleType? lastRole;
      final cm = _MockModel(generate: [_returns(Message.assistant('response'))]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        handlers: [
          _AfterModelRewriteState((ctx, state, _) {
            afterCalled = true;
            messageCount = state.messages.length;
            if (state.messages.isNotEmpty) lastRole = state.messages.last.role;
            return (ctx, state);
          }),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(afterCalled, isTrue);
      expect(messageCount, greaterThan(0));
      expect(lastRole, RoleType.assistant);
      expect(cm.generateCalls, 1);
    });
  });

  group('TestModelWrapperHandlers', () {
    test('MultipleModelWrappersPipeline', () async {
      final callOrder = <String>[];
      final cm = _MockModel(generate: [_returns(Message.assistant('response'))]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        handlers: [
          _ModelWrapperHandler(_modelWrapperFn(
            () => callOrder.add('wrapper1-before'),
            () => callOrder.add('wrapper1-after'),
          )),
          _ModelWrapperHandler(_modelWrapperFn(
            () => callOrder.add('wrapper2-before'),
            () => callOrder.add('wrapper2-after'),
          )),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(callOrder, ['wrapper1-before', 'wrapper2-before', 'wrapper2-after', 'wrapper1-after']);
      expect(cm.generateCalls, 1);
    });

    test('ModelWrapperBeforeAfterCallOrder', () async {
      final callOrder = <String>[];
      final cm = _MockModel(generate: [
        (_, _) async {
          callOrder.add('model-generate');
          return Message.assistant('original response');
        },
      ]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        handlers: [
          _ModelWrapperHandler(_modelWrapperFn(
            () => callOrder.add('wrapper-before'),
            () => callOrder.add('wrapper-after'),
          )),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(callOrder, ['wrapper-before', 'model-generate', 'wrapper-after']);
      expect(cm.generateCalls, 1);
    });

    test('ModelWrapperWithTools', () async {
      final testTool = _NamedTool('test_tool');
      final info = await testTool.info();
      final callOrder = <String>[];
      final cm = _MockModel(generate: [
        (_, _) async {
          callOrder.add('model-call');
          return _toolCallMessage('Using tool', 'call1', info.function.name, '{}');
        },
        (_, _) async {
          callOrder.add('model-call');
          return Message.assistant('done');
        },
      ]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [testTool])),
        handlers: [
          _ModelWrapperHandler(_modelWrapperFn(
            () => callOrder.add('wrapper-before'),
            () => callOrder.add('wrapper-after'),
          )),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(callOrder, [
        'wrapper-before', 'model-call', 'wrapper-after',
        'wrapper-before', 'model-call', 'wrapper-after',
      ]);
      expect(cm.generateCalls, 2);
    });
  });

  group('TestToolCallWrapperHandlers', () {
    test('MultipleToolWrappersPipeline', () async {
      final testTool = _NamedTool('test_tool');
      final info = await testTool.info();
      final callOrder = <String>[];
      final cm = _MockModel(generate: [
        _returns(_toolCallMessage('Using tool', 'call1', info.function.name, '{}')),
        _returns(Message.assistant('done')),
      ]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [testTool])),
        handlers: [
          _ToolWrapperHandler(
            wrapInvokable: _invokableWrapper(
              () => callOrder.add('wrapper1-before'),
              () => callOrder.add('wrapper1-after'),
            ),
          ),
          _ToolWrapperHandler(
            wrapInvokable: _invokableWrapper(
              () => callOrder.add('wrapper2-before'),
              () => callOrder.add('wrapper2-after'),
            ),
          ),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(callOrder, ['wrapper1-before', 'wrapper2-before', 'wrapper2-after', 'wrapper1-after']);
      expect(cm.generateCalls, 2);
    });

    test('StreamingToolWrappersPipeline', () async {
      final testTool = _StreamingNamedTool('streaming_tool');
      final info = await testTool.info();
      final callOrder = <String>[];
      final cm = _MockModel(stream: [
        _streams([_toolCallMessage('Using tool', 'call1', info.function.name, '{}')]),
        _streams([Message.assistant('done')]),
      ]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [testTool])),
        handlers: [
          _ToolWrapperHandler(
            wrapStreamable: _streamableWrapper(
              () => callOrder.add('wrapper1-stream-before'),
              () => callOrder.add('wrapper1-stream-after'),
            ),
          ),
          _ToolWrapperHandler(
            wrapStreamable: _streamableWrapper(
              () => callOrder.add('wrapper2-stream-before'),
              () => callOrder.add('wrapper2-stream-after'),
            ),
          ),
        ],
      ));

      final r = Runner(
        agent: agent,
        enableStreaming: true,
        checkpointStore: InMemoryCheckpointStore(),
      );
      final events = r.run(ctx, [Message.user('test')]);

      var hasStreamingToolResult = false;
      for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
        final mo = e.output?.messageOutput;
        if (mo != null && mo.isStreaming && mo.role == RoleType.tool) {
          hasStreamingToolResult = true;
          try {
            while (await mo.messageStream!.nextOrNull() != null) {}
            // Go: any Recv error ends the loop.
            // ignore: avoid_catches_without_on_clauses
          } catch (_) {}
        }
      }

      expect(hasStreamingToolResult, isTrue, reason: 'Should have streaming tool result');
      expect(
        callOrder,
        ['wrapper1-stream-before', 'wrapper2-stream-before', 'wrapper2-stream-after', 'wrapper1-stream-after'],
        reason: 'Streaming wrappers should be called in correct order',
      );
      expect(cm.streamCalls, 2);
    });

    test('ToolWrapperCanModifyResult', () async {
      final testTool = _NamedTool('test_tool');
      final info = await testTool.info();
      final cm = _MockModel(generate: [
        _returns(_toolCallMessage('Using tool', 'call1', info.function.name, '{}')),
        _returns(Message.assistant('done')),
      ]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [testTool])),
        handlers: [
          _ToolWrapperHandler(
            wrapInvokable: _resultModifyingWrapper((result) => 'modified: $result'),
          ),
        ],
      ));

      final toolContents = <String>[];
      final events = agent.run(ctx, _input('test'));
      for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
        final message = e.output?.messageOutput?.message;
        if (message != null && message.role == RoleType.tool) {
          toolContents.add(message.content);
        }
      }

      expect(toolContents, everyElement('modified: test_tool result'));
      expect(cm.generateCalls, 2);
    });
  });

  group('TestToolContextInWrappers', () {
    test('ToolContextHasCorrectNameAndCallID', () async {
      final testTool = _NamedTool('context_test_tool');
      final info = await testTool.info();
      String? capturedToolName;
      String? capturedCallId;
      final cm = _MockModel(generate: [
        _returns(_toolCallMessage('Using tool', 'test_call_id_123', info.function.name, '{}')),
        _returns(Message.assistant('done')),
      ]);

      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: cm,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [testTool])),
        handlers: [
          _ToolWrapperHandler(
            wrapInvokable: (_, endpoint, tool) {
              capturedToolName = tool.name;
              capturedCallId = tool.callId;
              return endpoint;
            },
          ),
        ],
      ));

      await _drain(agent.run(ctx, _input('test')));

      expect(capturedToolName, 'context_test_tool', reason: 'ToolContext should have correct tool name');
      expect(capturedCallId, 'test_call_id_123', reason: 'ToolContext should have correct call ID');
      expect(cm.generateCalls, 2);
    });
  });

  group('TestEnhancedToolArgumentsPropagation', () {
    test('ArgumentsPassedCorrectly', () async {
      String? capturedArgs;
      final handlers = <ChatModelAgentMiddleware>[
        _EnhancedToolWrapperHandler(
          wrapEnhancedInvokable: (_, endpoint, _) => (ctx, argument, options) {
            capturedArgs = argument.text;
            return endpoint(ctx, argument, options);
          },
        ),
      ];

      final middlewares = handlersToToolMiddlewares(handlers);
      Future<EnhancedToolCallOutput> mockEndpoint(RunContext ctx, ToolCallInput input) async =>
          const EnhancedToolCallOutput(ToolResult());

      final wrapped = middlewares[0].enhancedInvokable!(mockEndpoint);
      await wrapped(
        RunContext.background(),
        const ToolCallInput(
          name: 'test_tool',
          callId: 'call-1',
          arguments: '{"name": "test", "value": 123}',
        ),
      );

      expect(capturedArgs, '{"name": "test", "value": 123}');
    });
  });

  group('TestEnhancedToolResultPropagation', () {
    test('ResultPassedThroughMiddleware', () async {
      final expectedResult = ToolResult([ToolOutputPart.text('original result')]);
      ToolResult? capturedResult;
      final handlers = <ChatModelAgentMiddleware>[
        _EnhancedToolWrapperHandler(
          wrapEnhancedInvokable: (_, endpoint, _) => (ctx, argument, options) async {
            final result = await endpoint(ctx, argument, options);
            capturedResult = result;
            return result;
          },
        ),
      ];

      final middlewares = handlersToToolMiddlewares(handlers);
      Future<EnhancedToolCallOutput> mockEndpoint(RunContext ctx, ToolCallInput input) async =>
          EnhancedToolCallOutput(expectedResult);

      final wrapped = middlewares[0].enhancedInvokable!(mockEndpoint);
      final output = await wrapped(
        RunContext.background(),
        const ToolCallInput(name: 'test', callId: '1', arguments: '{}'),
      );

      expect(capturedResult, expectedResult);
      expect(output.result, expectedResult);
    });

    test('ModifiedResultPropagated', () async {
      final modifiedResult = ToolResult([ToolOutputPart.text('modified result')]);
      final handlers = <ChatModelAgentMiddleware>[
        _EnhancedToolWrapperHandler(
          wrapEnhancedInvokable: (_, endpoint, _) => (ctx, argument, options) async {
            await endpoint(ctx, argument, options);
            return modifiedResult;
          },
        ),
      ];

      final middlewares = handlersToToolMiddlewares(handlers);
      Future<EnhancedToolCallOutput> mockEndpoint(RunContext ctx, ToolCallInput input) async =>
          EnhancedToolCallOutput(ToolResult([ToolOutputPart.text('original')]));

      final wrapped = middlewares[0].enhancedInvokable!(mockEndpoint);
      final output = await wrapped(
        RunContext.background(),
        const ToolCallInput(name: 'test', callId: '1', arguments: '{}'),
      );

      expect(output.result, modifiedResult);
      expect(output.result.parts[0].text, 'modified result');
    });
  });

  group('TestEventSenderToolHandler', () {
    Future<List<AgentEvent>> run(
      BaseTool tool, {
      required bool streaming,
      List<ChatModelAgentMiddleware> handlers = const [],
    }) async {
      final agent = ChatModelAgent(ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        model: _MockToolCallingModel('test_tool'),
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [tool])),
        handlers: handlers,
      ));
      final r = Runner(agent: agent, enableStreaming: streaming);
      return _collectToolEvents(r.run(ctx, [Message.user('test')]));
    }

    group('Invokable', () {
      test('DefaultSendsEvent', () async {
        final toolEvents = await run(
          _InvokableTestTool('test_tool', 'invokable_output'),
          streaming: false,
        );
        expect(toolEvents, hasLength(1));
        expect(await _collectToolContent(toolEvents), contains('invokable_output'));
      });

      test('UserConfiguredSkipsDefault', () async {
        final toolEvents = await run(
          _InvokableTestTool('test_tool', 'invokable_output'),
          streaming: false,
          handlers: [const EventSenderToolWrapper()],
        );
        expect(toolEvents, hasLength(1));
      });

      test('InnermostGetsOriginalOutput', () async {
        const originalResult = 'original_invokable_output';
        const modifiedResult = 'modified_invokable_output';
        final toolEvents = await run(
          _InvokableTestTool('test_tool', originalResult),
          streaming: false,
          handlers: [
            const _InvokableResultModifier(modifiedResult),
            const EventSenderToolWrapper(),
          ],
        );
        expect(toolEvents.length, greaterThanOrEqualTo(1));
        expect(await _collectToolContent(toolEvents), contains(originalResult));
      });
    });

    group('Streamable', () {
      test('DefaultSendsEvent', () async {
        final toolEvents = await run(
          _StreamableTestTool('test_tool', 'streamable_output'),
          streaming: true,
        );
        expect(toolEvents, hasLength(1));
        expect(await _collectToolContent(toolEvents), contains('streamable_output'));
      });

      test('UserConfiguredSkipsDefault', () async {
        final toolEvents = await run(
          _StreamableTestTool('test_tool', 'streamable_output'),
          streaming: true,
          handlers: [const EventSenderToolWrapper()],
        );
        expect(toolEvents, hasLength(1));
      });

      test('InnermostGetsOriginalOutput', () async {
        const originalResult = 'original_streamable_output';
        const modifiedResult = 'modified_streamable_output';
        final toolEvents = await run(
          _StreamableTestTool('test_tool', originalResult),
          streaming: true,
          handlers: [
            const _StreamableResultModifier(modifiedResult),
            const EventSenderToolWrapper(),
          ],
        );
        expect(toolEvents.length, greaterThanOrEqualTo(1));
        expect(await _collectToolContent(toolEvents), contains(originalResult));
      });
    });

    group('EnhancedInvokable', () {
      test('DefaultSendsEvent', () async {
        final toolEvents = await run(
          _EnhancedInvokableTestTool('test_tool', 'enhanced_invokable_output'),
          streaming: false,
        );
        expect(toolEvents, hasLength(1));
        expect(await _collectToolContent(toolEvents), contains('enhanced_invokable_output'));
      });

      test('UserConfiguredSkipsDefault', () async {
        final toolEvents = await run(
          _EnhancedInvokableTestTool('test_tool', 'enhanced_invokable_output'),
          streaming: false,
          handlers: [const EventSenderToolWrapper()],
        );
        expect(toolEvents, hasLength(1));
      });

      test('InnermostGetsOriginalOutput', () async {
        const originalResult = 'original_enhanced_invokable_output';
        const modifiedResult = 'modified_enhanced_invokable_output';
        final toolEvents = await run(
          _EnhancedInvokableTestTool('test_tool', originalResult),
          streaming: false,
          handlers: [
            const _EnhancedInvokableResultModifier(modifiedResult),
            const EventSenderToolWrapper(),
          ],
        );
        expect(toolEvents.length, greaterThanOrEqualTo(1));
        expect(await _collectToolContent(toolEvents), contains(originalResult));
      });
    });

    group('EnhancedStreamable', () {
      test('DefaultSendsEvent', () async {
        final toolEvents = await run(
          _EnhancedStreamableTestTool('test_tool', 'enhanced_streamable_output'),
          streaming: true,
        );
        expect(toolEvents, hasLength(1));
        expect(await _collectToolContent(toolEvents), contains('enhanced_streamable_output'));
      });

      test('UserConfiguredSkipsDefault', () async {
        final toolEvents = await run(
          _EnhancedStreamableTestTool('test_tool', 'enhanced_streamable_output'),
          streaming: true,
          handlers: [const EventSenderToolWrapper()],
        );
        expect(toolEvents, hasLength(1));
      });

      test('InnermostGetsOriginalOutput', () async {
        const originalResult = 'original_enhanced_streamable_output';
        const modifiedResult = 'modified_enhanced_streamable_output';
        final toolEvents = await run(
          _EnhancedStreamableTestTool('test_tool', originalResult),
          streaming: true,
          handlers: [
            const _EnhancedStreamableResultModifier(modifiedResult),
            const EventSenderToolWrapper(),
          ],
        );
        expect(toolEvents.length, greaterThanOrEqualTo(1));
        expect(await _collectToolContent(toolEvents), contains(originalResult));
      });
    });
  });
}

/// Port of the local `unregisteredType` of RunLocalValueGobEncodabilityCheck.
class _UnregisteredType {
  const _UnregisteredType(this.data);

  final String data;
}
