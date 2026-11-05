// Port of eino v0.9.22 adk/message_id_test.go (classic messages only).
//
// Ports: TestMessageID_EventHasID_Generate,
// TestMessageID_EventAndStateShareSameID, TestMessageID_Stream_FirstChunkOnly,
// TestMessageID_ToolMessagesHaveID, TestMessageID_Retry_FinalResultHasID,
// TestMessageID_WrapModelSeesID, TestMessageID_UserInputNoAutoID,
// TestMessageID_SendEvent_MiddlewareMustEnsureID,
// TestAttack_ConcatCorruptsIDIfMultipleChunksCarryIt,
// TestAttack_ConcatPreservesIDIfOnlyFirstChunkHasIt,
// TestAttack_ConcurrentGenerate_NoSharedExtraMutation.
//
// Go tests that observe the state through the deprecated `Middlewares`
// (`AgentMiddleware.BeforeChatModel` / `AfterChatModel`) use the handler hooks
// `beforeModelRewriteState` / `afterModelRewriteState` instead: eino runs the
// deprecated hooks right around those (chatmodel.go, "Execution Order").
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

// ---------------------------------------------------------------------------
// Helpers and fakes
// ---------------------------------------------------------------------------

/// Port of `isValidUUID`.
bool _isValidUuid(String s) {
  if (s.length != 36) return false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (c != '-') return false;
    } else if (!RegExp('[0-9a-fA-F]').hasMatch(c)) {
      return false;
    }
  }
  return true;
}

/// Port of `collectEvents`.
Future<List<AgentEvent>> _collectEvents(StreamReader<AgentEvent> it) =>
    it.collectAll();

typedef _GenerateFn = Future<Message> Function(
  List<Message> input,
  ChatModelOptions? options,
);
typedef _StreamFn = Future<StreamReader<Message>> Function(
  List<Message> input,
  ChatModelOptions? options,
);

/// Port of `mockModel.NewMockToolCallingChatModel`: Generate and Stream answer
/// with [onGenerate] / [onStream]; [maxGenerate] / [maxStream] are gomock's
/// `Times(n)` (a further call throws, like gomock's "unexpected call").
/// `WithTools` returns the model itself.
class _MockModel extends ToolCallingChatModel {
  _MockModel({
    this.onGenerate,
    this.onStream,
    this.maxGenerate = 1 << 30,
    this.maxStream = 1 << 30,
  });

  final _GenerateFn? onGenerate;
  final _StreamFn? onStream;
  final int maxGenerate;
  final int maxStream;
  int generateCalls = 0;
  int streamCalls = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    generateCalls++;
    final fn = onGenerate;
    if (fn == null || generateCalls > maxGenerate) {
      throw StateError('unexpected Generate call #$generateCalls');
    }
    return fn(input, options);
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    streamCalls++;
    final fn = onStream;
    if (fn == null || streamCalls > maxStream) {
      throw StateError('unexpected Stream call #$streamCalls');
    }
    return fn(input, options);
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

/// Port of `fakeToolForTest` (react_test.go).
class _FakeToolForTest extends InvokableTool {
  _FakeToolForTest({required this.tarCount});

  final int tarCount;
  int curCount = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'test_tool',
        desc: 'test tool for unit testing',
        params: const {
          'name': ParameterInfo(
            type: DataType.string,
            desc: 'user name for testing',
            required: true,
          ),
        },
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final p = jsonDecode(argumentsJson) as Map<String, dynamic>;
    if (curCount >= tarCount) return '{"say": "bye"}';
    curCount++;
    return '{"say": "hello ${p['name']}"}';
  }
}

/// A middleware whose `beforeModelRewriteState` / `afterModelRewriteState`
/// run closures. Stands in for eino's deprecated `AgentMiddleware`
/// `BeforeChatModel` / `AfterChatModel`.
class _StateHooks extends ChatModelAgentMiddleware {
  const _StateHooks({this.before, this.after});

  final Future<void> Function(RunContext ctx, ChatModelAgentState state)? before;
  final Future<void> Function(RunContext ctx, ChatModelAgentState state)? after;

  @override
  Future<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async {
    await before?.call(ctx, state);
    return (ctx, state);
  }

  @override
  Future<(RunContext, ChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async {
    await after?.call(ctx, state);
    return (ctx, state);
  }
}

/// Port of `wrapModelIDCheckHandler`.
class _WrapModelIdCheckHandler extends ChatModelAgentMiddleware {
  const _WrapModelIdCheckHandler(this.onGenerate);

  final void Function(Message result) onGenerate;

  @override
  BaseChatModel wrapModel(
    RunContext ctx,
    BaseChatModel model,
    ModelContext context,
  ) =>
      _IdCheckModelWrapper(model, onGenerate);
}

/// Port of `idCheckModelWrapper`.
class _IdCheckModelWrapper extends BaseChatModel {
  _IdCheckModelWrapper(this.inner, this.onGenerate);

  final BaseChatModel inner;
  final void Function(Message result) onGenerate;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final result = await inner.generate(input, options: options);
    onGenerate(result);
    return result;
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) =>
      inner.stream(input, options: options);
}

AgentInput _input(String text, {bool streaming = false}) =>
    AgentInput(messages: [Message.user(text)], enableStreaming: streaming);

/// Go's `errors.Is`: [error] or one of its causes is [target].
bool _isOrCausedBy(Object? error, Object target) {
  for (Object? e = error; e != null; e = e is ThreepioException ? e.cause : null) {
    if (identical(e, target)) return true;
  }
  return false;
}

class _RetryableError implements Exception {
  const _RetryableError();

  @override
  String toString() => 'retryable error';
}

void main() {
  final ctx = RunContext.background();

  // Scenario 1: AgentEvent messages have IDs (Generate mode).
  test('TestMessageID_EventHasID_Generate', () async {
    final cm = _MockModel(
      onGenerate: (_, _) async => Message.assistant('hello world'),
      maxGenerate: 1,
    );
    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestMsgID',
      instruction: 'test',
      model: cm,
    ));

    final events = await _collectEvents(agent.run(ctx, _input('hi')));
    expect(events, hasLength(1));
    expect(events[0].error, isNull);
    expect(events[0].output?.messageOutput, isNotNull);

    final msg = events[0].output!.messageOutput!.message;
    expect(msg, isNotNull);
    final msgId = messageIdOf(msg!);
    expect(msgId, isNotEmpty, reason: 'event message should have an ID');
    expect(_isValidUuid(msgId), isTrue, reason: 'message ID should be a valid UUID, got: $msgId');
    expect(cm.generateCalls, 1);
  });

  // Scenario 2: Event and state messages share the same ID.
  test('TestMessageID_EventAndStateShareSameID', () async {
    final cm = _MockModel(
      onGenerate: (_, _) async => Message.assistant('response'),
      maxGenerate: 1,
    );
    var stateMessagesAfterModel = <Message>[];

    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestMsgID',
      instruction: 'test',
      model: cm,
      handlers: [
        _StateHooks(after: (ctx, state) async {
          // Capture state messages after model call (including the model output).
          stateMessagesAfterModel = List.of(state.messages);
        }),
      ],
    ));

    final events = await _collectEvents(agent.run(ctx, _input('hi')));
    expect(events, hasLength(1));
    expect(events[0].error, isNull);

    final eventMsgId = messageIdOf(events[0].output!.messageOutput!.message!);
    expect(eventMsgId, isNotEmpty);

    // The last message in state should be the model output with the same ID.
    expect(stateMessagesAfterModel, isNotEmpty);
    final stateMsgId = messageIdOf(stateMessagesAfterModel.last);
    expect(stateMsgId, eventMsgId,
        reason: 'event msg ID ($eventMsgId) and state msg ID ($stateMsgId) must match');
    expect(cm.generateCalls, 1);
  });

  // Scenario 3: Stream — first chunk carries ID, concatenated message has correct ID.
  test('TestMessageID_Stream_FirstChunkOnly', () async {
    final cm = _MockModel(
      onStream: (_, _) async => StreamReader.fromIterable([
        Message.assistant('chunk1'),
        Message.assistant('chunk2'),
        Message.assistant('chunk3'),
      ]),
      maxStream: 1,
    );
    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestMsgID',
      instruction: 'test',
      model: cm,
    ));

    final iter = agent.run(ctx, _input('hi', streaming: true));

    final event = await iter.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.output?.messageOutput, isNotNull);
    expect(event.output!.messageOutput!.isStreaming, isTrue);

    final stream = event.output!.messageOutput!.messageStream;
    expect(stream, isNotNull);

    final chunks = <Message>[];
    while (true) {
      Message? msg;
      try {
        msg = await stream!.nextOrNull();
        // Go: any Recv error ends the loop.
        // ignore: avoid_catches_without_on_clauses
      } catch (_) {
        break;
      }
      if (msg == null) break;
      chunks.add(msg);
    }
    expect(chunks.length, greaterThanOrEqualTo(1));

    // First chunk should have the ID.
    final firstChunkId = messageIdOf(chunks[0]);
    expect(firstChunkId, isNotEmpty, reason: 'first chunk should carry the message ID');
    expect(_isValidUuid(firstChunkId), isTrue);

    // Subsequent chunks should NOT have the ID in extra (first-chunk-only injection).
    for (var i = 1; i < chunks.length; i++) {
      expect(messageIdOf(chunks[i]), isEmpty,
          reason: 'chunk $i should not have message ID (first-chunk-only)');
    }

    // No more events.
    expect(await iter.nextOrNull(), isNull);
    expect(cm.streamCalls, 1);
  });

  // Scenario 4: Tool messages have IDs.
  test('TestMessageID_ToolMessagesHaveID', () async {
    final fakeTool = _FakeToolForTest(tarCount: 1);
    final info = await fakeTool.info();

    var generateCount = 0;
    final cm = _MockModel(onGenerate: (_, _) async {
      generateCount++;
      if (generateCount == 1) {
        return Message.assistant('calling tool', toolCalls: [
          ToolCall(
            id: 'tc-1',
            function: FunctionCall(name: info.function.name, arguments: '{"name": "tester"}'),
          ),
        ]);
      }
      return Message.assistant('done');
    });

    // Capture tool result messages from state before the 2nd model call.
    var toolMsgIdInState = '';
    var beforeModelCount = 0;
    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestMsgID',
      instruction: 'test',
      model: cm,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [fakeTool])),
      handlers: [
        _StateHooks(before: (ctx, state) async {
          beforeModelCount++;
          if (beforeModelCount == 2) {
            // 2nd model call: state.messages contains tool result messages.
            for (final m in state.messages) {
              if (m.role == RoleType.tool && m.toolCallId == 'tc-1') {
                toolMsgIdInState = messageIdOf(m);
              }
            }
          }
        }),
      ],
    ));

    final events = await _collectEvents(agent.run(ctx, _input('use tool')));
    // Expect 3 events: model(tool_call) + tool(result) + model(final).
    expect(events, hasLength(3));

    // Tool event (index 1).
    final toolEvent = events[1];
    expect(toolEvent.error, isNull);
    expect(toolEvent.output?.messageOutput, isNotNull);
    expect(toolEvent.output!.messageOutput!.role, RoleType.tool);

    final toolMsg = toolEvent.output!.messageOutput!.message;
    expect(toolMsg, isNotNull);
    final toolMsgId = messageIdOf(toolMsg!);
    expect(toolMsgId, isNotEmpty, reason: 'tool message should have an ID');
    expect(_isValidUuid(toolMsgId), isTrue);

    // All events should have IDs.
    for (var i = 0; i < events.length; i++) {
      final ev = events[i];
      expect(ev.error, isNull);
      expect(ev.output?.messageOutput, isNotNull);
      final msg = ev.output!.messageOutput!.message;
      expect(msg, isNotNull);
      expect(messageIdOf(msg!), isNotEmpty, reason: 'event[$i] should have a message ID');
    }

    // The tool message in state should share the same ID as the event tool message.
    expect(toolMsgIdInState, isNotEmpty, reason: 'tool message in state should have an ID');
    expect(toolMsgIdInState, toolMsgId,
        reason: 'tool event msg ID ($toolMsgId) and state msg ID ($toolMsgIdInState) must match');
  });

  // Scenario 5: Retry — the final accepted result carries a message ID.
  test('TestMessageID_Retry_FinalResultHasID', () async {
    const retryErr = _RetryableError();
    var callCount = 0;
    final cm = _MockModel(
      onGenerate: (_, _) async {
        callCount++;
        if (callCount < 3) throw retryErr;
        return Message.assistant('Success after retry');
      },
      maxGenerate: 3,
    );

    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestMsgID',
      instruction: 'test',
      model: cm,
      modelRetryConfig: ModelRetryConfig(
        maxRetries: 3,
        shouldRetry: (ctx, retryCtx) =>
            RetryDecision(retry: _isOrCausedBy(retryCtx.error, retryErr)),
        // No real waiting in tests (Go uses the default backoff).
        backoff: (_, _) => Duration.zero,
      ),
    ));

    final events = await _collectEvents(agent.run(ctx, _input('hello')));
    expect(events, hasLength(1));
    expect(events[0].error, isNull);

    final msgId = messageIdOf(events[0].output!.messageOutput!.message!);
    expect(msgId, isNotEmpty, reason: 'surviving message should have an ID');
    expect(_isValidUuid(msgId), isTrue);
    expect(callCount, 3);
  });

  // Scenario 6: WrapModel handler sees model output with ID.
  test('TestMessageID_WrapModelSeesID', () async {
    final cm = _MockModel(
      onGenerate: (_, _) async => Message.assistant('model output'),
      maxGenerate: 1,
    );
    var capturedMsgId = '';

    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestMsgID',
      instruction: 'test',
      model: cm,
      handlers: [
        _WrapModelIdCheckHandler((result) => capturedMsgId = messageIdOf(result)),
      ],
    ));

    final events = await _collectEvents(agent.run(ctx, _input('hi')));
    expect(events, hasLength(1));
    expect(events[0].error, isNull);

    expect(capturedMsgId, isNotEmpty, reason: 'WrapModel handler should see message ID on model output');
    expect(_isValidUuid(capturedMsgId), isTrue);

    // The event should carry the same ID.
    final eventMsgId = messageIdOf(events[0].output!.messageOutput!.message!);
    expect(eventMsgId, capturedMsgId,
        reason: 'WrapModel-captured ID ($capturedMsgId) should match event ID ($eventMsgId)');
    expect(cm.generateCalls, 1);
  });

  // Scenario 7: User input messages do NOT get automatic IDs.
  test('TestMessageID_UserInputNoAutoID', () async {
    var stateMessagesBeforeModel = <Message>[];
    final cm = _MockModel(
      onGenerate: (input, _) async {
        stateMessagesBeforeModel = List.of(input);
        return Message.assistant('response');
      },
      maxGenerate: 1,
    );
    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestMsgID',
      instruction: 'test',
      model: cm,
    ));

    final events = await _collectEvents(agent.run(ctx, _input('hello')));
    expect(events, hasLength(1));
    expect(events[0].error, isNull);

    expect(stateMessagesBeforeModel, isNotEmpty);
    for (var i = 0; i < stateMessagesBeforeModel.length; i++) {
      final msg = stateMessagesBeforeModel[i];
      expect(messageIdOf(msg), isEmpty,
          reason: 'input message[$i] (role=${msg.role}) should NOT have auto-assigned ID');
    }
    expect(cm.generateCalls, 1);
  });

  // Scenario 8: Middleware must call ensureMessageId before sendEvent.
  //
  // Go relies on pointer identity: the message the middleware puts into the
  // state is the one it sends. Dart messages are immutable, so the test reads
  // the id back from the message in the state instead.
  test('TestMessageID_SendEvent_MiddlewareMustEnsureID', () async {
    final cm = _MockModel(
      onGenerate: (_, _) async => Message.assistant('model response'),
      maxGenerate: 1,
    );

    Message? middlewareMsg;
    var stateMsgIdAfterSendEvent = '';
    Object? hookError;

    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestMsgID',
      instruction: 'test',
      model: cm,
      handlers: [
        _StateHooks(after: (ctx, state) async {
          try {
            // Middleware is responsible for assigning the ID before sending.
            final msg = ensureMessageId(Message.assistant('middleware injected'));
            middlewareMsg = msg;

            // Write to state.
            state.messages.add(msg);

            // Send as event — sendEvent does NOT auto-assign an ID.
            await ctx.sendEvent(AgentEvent.fromMessage(msg, role: RoleType.assistant));

            stateMsgIdAfterSendEvent = messageIdOf(state.messages.last);
            // Recorded and asserted outside the hook.
            // ignore: avoid_catches_without_on_clauses
          } catch (e) {
            hookError = e;
            rethrow;
          }
        }),
      ],
    ));

    final allEvents = await _collectEvents(agent.run(ctx, _input('hi')));
    expect(hookError, isNull);

    // At least 2 events: model response + middleware injected message.
    expect(allEvents.length, greaterThanOrEqualTo(2));

    // The middleware message should have an ID (assigned via ensureMessageId).
    expect(middlewareMsg, isNotNull);
    final middlewareMsgId = messageIdOf(middlewareMsg!);
    expect(middlewareMsgId, isNotEmpty, reason: 'middleware should have assigned an ID via EnsureMessageID');
    expect(_isValidUuid(middlewareMsgId), isTrue);

    // The ID read back from the state after sendEvent is the same.
    expect(stateMsgIdAfterSendEvent, middlewareMsgId,
        reason: 'ID read from state ($stateMsgIdAfterSendEvent) should match message ID ($middlewareMsgId)');

    // Find the middleware event in the collected events.
    var middlewareEventMsgId = '';
    for (final ev in allEvents) {
      if (ev.error != null || ev.output?.messageOutput == null) continue;
      final msg = ev.output!.messageOutput!.message;
      if (msg != null && msg.content == 'middleware injected') {
        middlewareEventMsgId = messageIdOf(msg);
        break;
      }
    }
    expect(middlewareEventMsgId, middlewareMsgId,
        reason: 'event message ID ($middlewareEventMsgId) should match the middleware message ID ($middlewareMsgId)');
  });

  test('TestAttack_ConcatCorruptsIDIfMultipleChunksCarryIt', () {
    const id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    final msgs = [
      const Message(role: RoleType.assistant, content: 'chunk1', extra: {einoMessageIdKey: id}),
      const Message(role: RoleType.assistant, content: 'chunk2', extra: {einoMessageIdKey: id}),
      const Message(role: RoleType.assistant, content: 'chunk3', extra: {einoMessageIdKey: id}),
    ];
    final concatenated = concatMessages(msgs);

    final resultId = messageIdOf(concatenated);
    // concatMessages string-concatenates duplicate extra keys, corrupting the ID.
    expect(resultId, isNot(id), reason: 'ConcatMessages should corrupt the ID when multiple chunks carry it');
    expect(resultId.length, isNot(36), reason: 'corrupted ID should not be 36 chars');
    expect(concatenated.content, 'chunk1chunk2chunk3');
  });

  test('TestAttack_ConcatPreservesIDIfOnlyFirstChunkHasIt', () {
    const id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    final msgs = [
      const Message(role: RoleType.assistant, content: 'chunk1', extra: {einoMessageIdKey: id}),
      const Message(role: RoleType.assistant, content: 'chunk2'),
      const Message(role: RoleType.assistant, content: 'chunk3'),
    ];
    final concatenated = concatMessages(msgs);

    expect(messageIdOf(concatenated), id, reason: 'ID should be preserved when only first chunk carries it');
    expect(concatenated.content, 'chunk1chunk2chunk3');
  });

  // Go runs 10 goroutines against one shared *Message to catch a data race on
  // its Extra map. Dart messages are immutable and runs are concurrent on one
  // isolate: the intent ported is that 10 concurrent runs answered with the
  // same message object each get a valid, distinct id.
  test('TestAttack_ConcurrentGenerate_NoSharedExtraMutation', () async {
    // Shared singleton message - the same object is returned every time.
    final sharedMsg = Message.assistant('shared response');
    final cm = _MockModel(onGenerate: (_, _) async => sharedMsg);

    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestAttack',
      instruction: 'test',
      model: cm,
    ));

    const n = 10;
    final results = await Future.wait([
      for (var i = 0; i < n; i++) _collectEvents(agent.run(ctx, _input('hi'))),
    ]);

    final ids = <String>[];
    for (final events in results) {
      expect(events, hasLength(1));
      expect(events[0].error, isNull);
      final msg = events[0].output!.messageOutput!.message;
      expect(msg, isNotNull);
      ids.add(messageIdOf(msg!));
    }

    // All IDs should be unique and valid.
    final seen = <String>{};
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      expect(id, isNotEmpty, reason: 'run $i should have an ID');
      expect(_isValidUuid(id), isTrue, reason: 'run $i ID should be valid UUID: $id');
      expect(seen.contains(id), isFalse, reason: 'run $i has duplicate ID: $id');
      seen.add(id);
    }
  });
}
