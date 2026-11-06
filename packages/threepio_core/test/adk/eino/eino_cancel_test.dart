// Port of eino v0.9.22 `adk/cancel_test.go` and `adk/cancel_edge_test.go`:
// the agent-level cancel tests (WithCancel on a ChatModelAgent and a Runner).
//
// Ported Go tests, from cancel_test.go: TestStreamCanceledErrorIs,
// TestCancelContext, TestWithCancel_WithTools, TestWithCancel_WithCheckpoint,
// TestAgentCancelFuncMultipleCalls, TestWithCancel_Streaming,
// TestWithCancel_Resume, TestCancelImmediate_OrphanedToolGoroutine_NoPanic,
// TestCancel_SafePointNeverFires_ErrExecutionEnded.
// From cancel_edge_test.go: TestWithCancel_BeforeExecutionStarts,
// TestWithCancel_AfterCompletion, TestWithCancel_AfterBusinessInterrupt,
// TestWithCancel_AfterError, TestWithCancel_TimeoutEscalation,
// TestWithCancel_AfterChatModel_WithTools,
// TestWithCancel_CancelImmediate_StreamAborted,
// TestWithCancel_MultipleToolsConcurrent,
// TestWithCancel_GraphInterruptRaceBeforeSet,
// TestWithCancel_NoCheckpointStore, TestWithCancel_ModelError,
// TestWithCancel_Resume_SafePoint,
// TestWithCancel_TargetedResume_CancelImmediate,
// TestWithCancel_TargetedResume_SafePoint,
// TestWithCancel_Resume_CancelAfterChatModel_MessagePreserved,
// TestWithCancel_CancelImmediate_NestedAgentTool_ResumeFromToolsNode.
//
// Sub-tests not portable: TestCancelImmediate_OrphanedToolGoroutine_NoPanic's
// unit_send_nil_execCtx, unit_send_nil_generator and
// unit_isImmediateCancelled_nil_cancelContext call methods on nil receivers
// or build an exec context without a generator, which Dart's null safety
// rules out at compile time.
//
// Not ported, they need sequential / loop / parallel workflow agents, a
// supervisor or agent transfer (not ported in Dart): from cancel_test.go
// TestWithCancel_SequentialAgent, TestWithCancel_LoopAgent,
// TestWithCancel_ParallelAgent, TestWithCancel_SupervisorAgent,
// TestCheckCancel_Sequential_BetweenSubAgents,
// TestCheckCancel_Loop_BetweenIterations, TestCheckCancel_Parallel_PreSpawn,
// TestCheckCancel_Transfer_BeforeTarget,
// TestCheckCancel_AlreadyHandled_NoDuplicate,
// TestCancel_SequentialWorkflow_CancelAfterChatModel,
// TestCancelImmediate_ParallelWorkflow_WithAgentTool,
// TestCancelImmediate_SequentialTransitionBoundary,
// TestCancelImmediate_LoopTransitionBoundary,
// TestCancelAfterChatModel_SequentialTransitionBoundary,
// TestCancelAfterChatModel_Sequential_Agent1CompletesCancelBeforeAgent2Resume,
// TestCancelAfterToolCalls_LoopTransitionBoundary,
// TestCancel_ParallelWorkflow_CancelAfterChatModel,
// TestCancel_LoopWorkflow_CancelAfterChatModel,
// TestCancel_NestedWorkflow_AgentTool_CancelAfterChatModel,
// TestCancel_CancelAfterToolCalls_InSequentialWorkflow; from
// cancel_edge_test.go TestWithCancel_SafePoint_DirectWorkflowChildAbortOnly,
// TestWithCancel_RecursiveImmediate_TransferChildCheckpoint,
// TestWithCancel_RecursiveSafePoint_TransferChildCheckpoint.
//
// Not assigned to this file (the recursive / middleware cancel tests are
// ported in another file; the internal unit tests were not assigned here):
// the other tests of cancel_test.go
// (TestCancelMonitoredToolHandler_*, TestCancelContextKey,
// TestFilterCancelOption, TestWrapIterWithMarkDone,
// TestGraphInterruptFuncs_Parallel,
// TestCancelImmediate_AgentTool_PreservesChildCheckpoint,
// TestCancelImmediate_CustomAgent_GracePeriodFallback,
// TestCancelImmediate_MultiLevelNesting,
// TestCancelContext_RecursiveGraceBoundary, TestBuildCancelFunc_*) and of
// cancel_edge_test.go (TestWithCancel_DerivedCheckpointCancelContextMarkedDoneAfterRun,
// TestWithCancel_RecursiveDoesNotTargetAgentEmbeddedInMiddleware, the
// TestWithCancel_RecursiveImmediate_* / NonRecursiveImmediate_* middleware
// tests, TestWithCancel_CancelImmediate_StreamableToolAborted and the
// RecursiveAgentTool / ConcurrentAgentTools tests).
//
// Go's goroutines, channels and `time.Sleep` become Completers: a model or
// tool that "takes" longer than the test waits for a Completer the test
// completes when Go's delay would have passed (or never); Go's sleeps that
// only let the scheduler run become `pumpEventQueue()`; cancel timeouts are
// a few milliseconds.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/agent_context.dart';
import 'package:threepio_core/src/adk/eino/cancel.dart';
import 'package:threepio_core/src/adk/eino/run_options.dart';

/// A chat model that answers [response] on every call.
///
/// Port of eino's test models `blockingChatModel` (with [blocking]: every
/// call waits for [unblock]), `cancelTestChatModel`, `simpleChatModel`,
/// `gatedChatModel` and `plainResponseModel`. Their delays become
/// [blocking]: the test completes [unblock] when Go's delay would have
/// passed, or never for a delay longer than the test (an immediate cancel
/// abandons the call).
final class _Model extends BaseChatModel {
  _Model(this.response, {this.blocking = false});

  final Message response;
  final bool blocking;
  final Completer<void> unblock = Completer<void>();
  final Completer<void> started = Completer<void>();
  int callCount = 0;

  Future<Message> _call() async {
    callCount++;
    if (!started.isCompleted) started.complete();
    if (blocking) await unblock.future;
    return response;
  }

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) =>
      _call();

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await _call()]);
}

/// A model whose calls fail with [error]. Port of eino's `errorChatModel`.
final class _ErrorModel extends BaseChatModel {
  _ErrorModel(this.error);

  final ThreepioException error;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      throw error;

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      throw error;
}

/// A model that raises a business interrupt. Port of eino's
/// `interruptingChatModel`; the node's context comes with the options.
final class _InterruptingModel extends BaseChatModel {
  InterruptSignal _interrupt(ChatModelOptions? options) =>
      interrupt(options?.runContext ?? RunContext.background(), 'test interrupt');

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      throw _interrupt(options);

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      throw _interrupt(options);
}

/// A model that answers [responses] in turn, fails once they are used up,
/// and logs [label] to [callLog] on every call. Port of eino's
/// `countingChatModel` (its `callCh`/`callLabel` become [callLog]).
final class _CountingModel extends BaseChatModel {
  _CountingModel(this.responses, {this.label = '', this.callLog});

  final List<Message> responses;
  final String label;
  final List<String>? callLog;
  int callCount = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final index = callCount++;
    callLog?.add(label);
    if (index >= responses.length) {
      throw ThreepioException(
        'countingChatModel: call ${index + 1} exceeds ${responses.length} '
        'responses (outer model was called too many times - possible '
        'restart from beginning)',
      );
    }
    return responses[index];
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

/// A tool answering [result]. Port of eino's `slowTool`,
/// `slowToolWithSignal`, `blockingTool` (with [blocking]: every call waits
/// for [unblock]) and `callbackTool` (with [onCall]).
final class _Tool extends InvokableTool {
  _Tool(
    this.toolName, {
    this.blocking = false,
    this.result = 'tool result',
    this.onCall,
  });

  final String toolName;
  final bool blocking;
  final String result;
  final void Function()? onCall;
  final Completer<void> unblock = Completer<void>();
  final Completer<void> started = Completer<void>();
  int callCount = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: toolName,
        desc: 'A slow tool for testing',
        params: const {
          'input': ParameterInfo(type: DataType.string, desc: 'Input parameter'),
        },
      );

  @override
  Future<String> run(String argumentsJson) async {
    callCount++;
    onCall?.call();
    if (!started.isCompleted) started.complete();
    if (blocking) await unblock.future;
    return result;
  }
}

ToolCall _toolCall(String id, String name, String arguments) => ToolCall(
      id: id,
      function: FunctionCall(name: name, arguments: arguments),
    );

Message _toolCallMsg(List<ToolCall> calls) =>
    Message(role: RoleType.assistant, toolCalls: calls);

/// The tool call of cancel_test.go's models.
Message _slowToolCall() =>
    _toolCallMsg([_toolCall('call_1', 'slow_tool', '{"input": "test"}')]);

ChatModelAgent _agent(
  BaseChatModel model, {
  String name = 'TestAgent',
  String description = 'Test agent with tool',
  String instruction = '',
  List<BaseTool> tools = const [],
}) =>
    ChatModelAgent(
      ChatModelAgentConfig(
        name: name,
        description: description,
        instruction: instruction,
        model: model,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)),
      ),
    );

AgentRunCancelledException? _cancelErrorOf(AgentEvent event) =>
    ThreepioException.findCause<AgentRunCancelledException>(event.error);

bool _isCancelError(AgentEvent event) => _cancelErrorOf(event) != null;

/// Port of eino's `drainEvents`.
Future<(List<AgentEvent>, bool)> _drainEvents(
  StreamReader<AgentEvent> events,
) async {
  final all = await events.collectAll();
  return (all, all.any(_isCancelError));
}

/// Port of eino's `messageOutputContent`.
Future<String> _messageOutputContent(AgentEvent event) async {
  final output = event.output?.messageOutput;
  if (output == null) return '';
  return (await output.getMessage()).content;
}

void main() {
  final ctx = RunContext.background();

  test('TestStreamCanceledErrorIs', () {
    const Object streamCanceled = StreamCanceledException();
    expect(streamCanceled, isA<StreamCanceledException>());
    expect(
      ThreepioException.findCause<StreamCanceledException>(streamCanceled),
      isNotNull,
    );
    // Go: assert.NotErrorIs(t, streamCanceled, context.Canceled).
    expect(streamCanceled, isNot(isA<CancelledException>()));
  });

  group('TestCancelContext', () {
    test('BasicCancelContext', () {
      final cc = CancelContext.root();
      expect(cc.shouldCancel, isFalse, reason: 'Should not be cancelled initially');

      // Go: cc.setMode(CancelImmediate); close(cc.cancelChan).
      cc.triggerCancel(const {});

      expect(cc.shouldCancel, isTrue, reason: 'Should be cancelled after close(cancelChan)');
      expect(cc.mode, isEmpty, reason: 'CancelImmediate');
    });
  });

  group('TestWithCancel_WithTools', () {
    test('CancelImmediate_DuringModelCall', () async {
      final st = _Tool('slow_tool');
      // Go: the model takes 2 s.
      final slowModel = _Model(_slowToolCall(), blocking: true);
      final runner = Runner(
        agent: _agent(
          slowModel,
          instruction: 'You are a test assistant',
          tools: [st],
        ),
      );

      final (cancelOpt, cancelFn) = withCancel();
      final iter = runner.run(
        ctx,
        [Message.user('Use the tool')],
        options: [cancelOpt],
      );
      final eventsFuture = iter.collectAll();

      await slowModel.started.future;
      await pumpEventQueue();

      final handle = cancelFn();
      expect(await handle.wait(), CancelOutcome.cancelled);

      final events = await eventsFuture;
      expect(events, isNotEmpty);
      expect(events.any(_isCancelError), isTrue, reason: 'expected CancelError in events');
    });

    test('CancelAfterChatModel_DuringToolCall', () async {
      // Go: the tool sleeps 2 s.
      final st = _Tool('slow_tool', blocking: true);
      final modelWithToolCall = _Model(_slowToolCall());
      final agent = _agent(
        modelWithToolCall,
        instruction: 'You are a test assistant',
        tools: [st],
      );

      final (cancelOpt, cancelFn) = withCancel();
      final iter = agent.run(
        ctx,
        AgentInput(messages: [Message.user('Use the tool')]),
        options: [cancelOpt],
      );

      await st.started.future;
      await pumpEventQueue();

      final handle =
          cancelFn(safePoints: {CancelSafePoint.afterChatModel});
      // Go's 2 s of the tool pass.
      st.unblock.complete();
      expect(await handle.wait(), CancelOutcome.cancelled);

      final events = [
        for (final event in await iter.collectAll())
          if (!_isCancelError(event)) event,
      ];
      expect(events, isNotEmpty);
      expect(st.callCount, greaterThanOrEqualTo(1), reason: 'Tool should have been called');
    });

    test('CancelAfterToolCalls_CompletesToolExecution', () async {
      // Go: the tool sleeps 500 ms.
      final st = _Tool('slow_tool', blocking: true);
      final modelWithToolCall = _Model(_slowToolCall());
      final agent = _agent(
        modelWithToolCall,
        instruction: 'You are a test assistant',
        tools: [st],
      );

      final (cancelOpt, cancelFn) = withCancel();
      final iter = agent.run(
        ctx,
        AgentInput(messages: [Message.user('Use the tool')]),
        options: [cancelOpt],
      );

      await st.started.future;
      await pumpEventQueue();

      final handle =
          cancelFn(safePoints: {CancelSafePoint.afterToolCalls});
      st.unblock.complete();
      expect(await handle.wait(), CancelOutcome.cancelled);

      final events = [
        for (final event in await iter.collectAll())
          if (!_isCancelError(event)) event,
      ];
      expect(events, isNotEmpty);
      expect(st.callCount, greaterThanOrEqualTo(1), reason: 'Tool should have been called');
    });

    test('NestedCancelPropagation', () async {
      final cc = CancelContext.root();
      final token = CancelToken();
      addTearDown(token.cancel);
      final child =
          cc.deriveCheckpointAware(RunContext.background(cancelToken: token));

      cc.setRecursive(true);
      // Go: cc.setMode(CancelImmediate); CAS(running → cancelling);
      // close(cc.cancelChan).
      cc.triggerCancel(const {});

      // Go waits for child.cancelChan; the propagation runs in microtasks.
      await pumpEventQueue();

      expect(child.shouldCancel, isTrue, reason: 'Child did not receive cancel signal');
      expect(child.mode, isEmpty, reason: 'CancelImmediate');
    });

    test('DeepAgentIntegrationCancel', () async {
      // Go: the leaf model takes 500 ms.
      final leafModel = _Model(Message.assistant('Leaf result'), blocking: true);
      final leafAgent = ChatModelAgent(
        ChatModelAgentConfig(
          name: 'LeafAgent',
          description: 'desc',
          model: leafModel,
        ),
      );

      final rootModel =
          _Model(_toolCallMsg([_toolCall('call_1', 'LeafAgent', '{}')]));
      final rootAgent = ChatModelAgent(
        ChatModelAgentConfig(
          name: 'RootAgent',
          description: 'desc',
          model: rootModel,
          toolsConfig: ToolsConfig(
            toolsNode: ToolsNodeConfig(tools: [AgentTool(leafAgent)]),
          ),
        ),
      );

      final runner = Runner(agent: rootAgent);
      final (cancelOpt, cancelFn) = withCancel();
      final iter =
          runner.run(ctx, [Message.user('Run leaf')], options: [cancelOpt]);

      await leafModel.started.future;

      final handle = cancelFn(
        safePoints: {CancelSafePoint.afterChatModel},
        recursive: true,
      );
      // Go's leaf model returns 500 ms later, after the cancel reached it.
      await pumpEventQueue();
      leafModel.unblock.complete();
      expect(await handle.wait(), CancelOutcome.cancelled);

      var hasCancelError = false;
      for (final event in await iter.collectAll()) {
        final ce = _cancelErrorOf(event);
        if (ce != null) {
          hasCancelError = true;
          expect(
            ce.interruptSignal,
            isNotNull,
            reason: 'CancelError should carry interrupt signal',
          );
        }
      }
      expect(hasCancelError, isTrue, reason: 'Should have received CancelError');
    });
  });

  group('TestWithCancel_WithCheckpoint', () {
    test('CancelWithCheckpoint', () async {
      final st = _Tool('slow_tool');
      // Go: the model takes 1 s.
      final slowModel = _Model(_slowToolCall(), blocking: true);
      final store = InMemoryCheckpointStore();
      final runner = Runner(
        agent: _agent(
          slowModel,
          instruction: 'You are a test assistant',
          tools: [st],
        ),
        checkpointStore: store,
      );

      final (cancelOpt, cancelFn) = withCancel();
      final iter = runner.run(
        ctx,
        [Message.user('Use the tool')],
        options: [cancelOpt, AgentRunOption.checkpointId('cancel-1')],
      );

      await slowModel.started.future;

      final handle = cancelFn();
      expect(await handle.wait(), CancelOutcome.cancelled);

      final (_, hasCancelError) = await _drainEvents(iter);
      expect(hasCancelError, isTrue, reason: 'Should have CancelError event after cancel');
    });
  });

  group('TestAgentCancelFuncMultipleCalls', () {
    test('SecondCancelReturnsErrAgentFinished', () async {
      final st = _Tool('slow_tool');
      // Go: the model takes 1 s.
      final slowModel = _Model(_slowToolCall(), blocking: true);
      final runner = Runner(
        agent: _agent(
          slowModel,
          instruction: 'You are a test assistant',
          tools: [st],
        ),
      );

      final (cancelOpt, cancelFn) = withCancel();
      final iter = runner.run(
        ctx,
        [Message.user('Use the tool')],
        options: [cancelOpt],
      );

      await slowModel.started.future;

      final handle = cancelFn();
      expect(await handle.wait(), CancelOutcome.cancelled);

      await iter.collectAll();
    });
  });

  group('TestWithCancel_Streaming', () {
    test('CancelImmediate_DuringModelStream', () async {
      final st = _Tool('slow_tool');
      // Go: Stream sleeps 2 s before it returns the stream.
      final slowModel = _Model(_slowToolCall(), blocking: true);
      final runner = Runner(
        agent: _agent(
          slowModel,
          instruction: 'You are a test assistant',
          tools: [st],
        ),
        enableStreaming: true,
      );

      final (cancelOpt, cancelFn) = withCancel();
      final iter = runner.run(
        ctx,
        [Message.user('Use the tool')],
        options: [cancelOpt],
      );
      final eventsFuture = iter.collectAll();

      await slowModel.started.future;
      await pumpEventQueue();

      final handle = cancelFn();
      expect(await handle.wait(), CancelOutcome.cancelled);

      final events = await eventsFuture;
      expect(events, isNotEmpty);
      expect(events.any(_isCancelError), isTrue, reason: 'expected CancelError in events');
    });

    test('CancelAfterToolCalls_Streaming', () async {
      // Go: the tool sleeps 500 ms.
      final st = _Tool('slow_tool', blocking: true);
      final modelWithToolCall = _Model(_slowToolCall());
      final runner = Runner(
        agent: _agent(
          modelWithToolCall,
          instruction: 'You are a test assistant',
          tools: [st],
        ),
        enableStreaming: true,
      );

      final (cancelOpt, cancelFn) = withCancel();
      final iter = runner.run(
        ctx,
        [Message.user('Use the tool')],
        options: [cancelOpt],
      );

      await st.started.future;
      await pumpEventQueue();

      final handle =
          cancelFn(safePoints: {CancelSafePoint.afterToolCalls});
      st.unblock.complete();
      expect(await handle.wait(), CancelOutcome.cancelled);

      final events = [
        for (final event in await iter.collectAll())
          if (!_isCancelError(event)) event,
      ];
      expect(events, isNotEmpty);
      expect(st.callCount, greaterThanOrEqualTo(1), reason: 'Tool should have been called');
    });
  });

  group('TestWithCancel_Resume', () {
    test('Cancel_ThenResume', () async {
      final st = _Tool('slow_tool');
      // Go: the model takes 500 ms.
      final slowModel = _Model(_slowToolCall(), blocking: true);
      final store = InMemoryCheckpointStore();
      const checkpointId = 'resume-cancel-test-1';
      final runner = Runner(
        agent: _agent(
          slowModel,
          instruction: 'You are a test assistant',
          tools: [st],
        ),
        checkpointStore: store,
      );

      final (cancelOpt, cancelFn) = withCancel();
      final iter = runner.run(
        ctx,
        [Message.user('Use the tool')],
        options: [cancelOpt, AgentRunOption.checkpointId(checkpointId)],
      );

      await slowModel.started.future;

      final handle = cancelFn();
      expect(await handle.wait(), CancelOutcome.cancelled);

      var hasCancelErr = false;
      for (final event in await iter.collectAll()) {
        if (event.error != null) {
          if (_isCancelError(event)) {
            hasCancelErr = true;
            continue;
          }
          fail('unexpected error: ${event.error}');
        }
      }
      expect(hasCancelErr, isTrue, reason: 'Should have CancelError event after cancel');

      // Go: 100 ms.
      final slowModel2 = _Model(Message.assistant('Final response after resume'));
      final runner2 = Runner(
        agent: _agent(
          slowModel2,
          instruction: 'You are a test assistant',
          tools: [st],
        ),
        checkpointStore: store,
      );

      final (resumeCancelOpt, _) = withCancel();
      final resumeIter =
          await runner2.resume(ctx, checkpointId, options: [resumeCancelOpt]);

      final resumeEvents = <AgentEvent>[];
      for (final event in await resumeIter.collectAll()) {
        expect(event.error, isNull, reason: 'Should not have error event during resume');
        resumeEvents.add(event);
      }
      expect(resumeEvents, isNotEmpty, reason: 'Resume should produce events');
    });

    test('Resume_ThenCancel', () async {
      final st = _Tool('slow_tool');
      // Go: the model takes 500 ms.
      final slowModel = _Model(_slowToolCall(), blocking: true);
      final store = InMemoryCheckpointStore();
      const checkpointId = 'resume-then-cancel-test-1';
      final runner = Runner(
        agent: _agent(
          slowModel,
          instruction: 'You are a test assistant',
          tools: [st],
        ),
        checkpointStore: store,
      );

      final (cancelOpt, cancelFn) = withCancel();
      final iter = runner.run(
        ctx,
        [Message.user('Use the tool')],
        options: [cancelOpt, AgentRunOption.checkpointId(checkpointId)],
      );

      await slowModel.started.future;

      final handle = cancelFn();
      expect(await handle.wait(), CancelOutcome.cancelled);
      await iter.collectAll();

      final slowModel2 = _Model(
        _toolCallMsg([_toolCall('call_1', 'slow_tool', '{"input": "test"}')]),
        blocking: true,
      );
      final runner2 = Runner(
        agent: _agent(
          slowModel2,
          instruction: 'You are a test assistant',
          tools: [st],
        ),
        checkpointStore: store,
      );

      final (resumeCancelOpt, resumeCancelFn) = withCancel();
      final resumeIter =
          await runner2.resume(ctx, checkpointId, options: [resumeCancelOpt]);
      final resumeEventsFuture = resumeIter.collectAll();

      await slowModel2.started.future;

      final cancelHandle = resumeCancelFn();
      slowModel2.unblock.complete();
      final outcome = await cancelHandle.wait();
      expect(
        outcome,
        anyOf(CancelOutcome.cancelled, CancelOutcome.executionEnded),
        reason: 'unexpected cancel wait outcome: $outcome',
      );

      final stopwatch = Stopwatch()..start();
      final resumeEvents = await resumeEventsFuture;
      final elapsed = stopwatch.elapsed;

      expect(
        elapsed,
        lessThan(const Duration(seconds: 1)),
        reason: 'Resume should return quickly after cancel, elapsed: $elapsed',
      );
      expect(resumeEvents, isNotEmpty);

      final hasCancelError = resumeEvents.any(_isCancelError);
      final executionCompletedBeforeCancel =
          outcome == CancelOutcome.executionEnded;
      expect(
        hasCancelError || executionCompletedBeforeCancel,
        isTrue,
        reason: 'Resume should have CancelError event after cancel, or '
            'execution completed before cancel',
      );
    });
  });

  group('TestCancelImmediate_OrphanedToolGoroutine_NoPanic', () {
    // unit_send_nil_execCtx, unit_send_nil_generator and
    // unit_isImmediateCancelled_nil_cancelContext are not portable (nil
    // receivers / a missing generator do not compile in Dart).

    test('unit_send_after_close', () async {
      final (_, gen) = pipe<AgentEvent>();

      // Go: setMode(CancelImmediate); close(cancelChan); close(immediateChan).
      final cc = CancelContext.root()..triggerCancel(const {});
      cc.sendImmediateInterrupt();

      await gen.close();

      final execCtx = ChatModelAgentExecContext(writer: gen, cancelContext: cc);
      expect(
        () => execCtx.send(const AgentEvent(agentName: 'test')),
        returnsNormally,
        reason: 'send after generator.Close must not panic',
      );
    });

    test('unit_send_after_close_without_cancel_ctx', () async {
      final (_, gen) = pipe<AgentEvent>();
      await gen.close();

      final execCtx = ChatModelAgentExecContext(writer: gen);
      expect(
        () => execCtx.send(const AgentEvent(agentName: 'test')),
        returnsNormally,
        reason: 'send after generator.Close must not panic even without '
            'cancelCtx (trySend safety net)',
      );
    });

    test('unit_trySend_race_window', () async {
      final (_, gen) = pipe<AgentEvent>();
      final cc = CancelContext.root();

      await gen.close();

      final execCtx = ChatModelAgentExecContext(writer: gen, cancelContext: cc);
      expect(
        () => execCtx.send(const AgentEvent(agentName: 'test')),
        returnsNormally,
        reason: 'trySend must handle the case where isImmediateCancelled is '
            'false but generator is closed',
      );
    });

    test('unit_SendEvent_after_close', () async {
      final (_, gen) = pipe<AgentEvent>();

      final cc = CancelContext.root()..triggerCancel(const {});
      cc.sendImmediateInterrupt();

      await gen.close();

      final execCtx = ChatModelAgentExecContext(writer: gen, cancelContext: cc);
      final runCtx = withExecContext(RunContext.background(), execCtx);

      await expectLater(
        runCtx.sendEvent(const AgentEvent(agentName: 'test')),
        completes,
        reason: 'SendEvent after generator.Close must not panic',
      );
    });

    test('unit_SendEvent_no_execCtx', () async {
      await expectLater(
        RunContext.background().sendEvent(const AgentEvent(agentName: 'test')),
        throwsA(isA<StateError>()),
        reason: 'SendEvent without execCtx should return error',
      );
    });

    test('integration_cancel_escalation_orphans_tool', () async {
      // Go: the tool sleeps 2 s.
      final st = _Tool('orphan_tool', blocking: true);
      final mdl = _Model(
        _toolCallMsg([
          _toolCall('call_orphan_1', 'orphan_tool', '{"input": "test"}'),
        ]),
      );
      final agent = _agent(
        mdl,
        name: 'OrphanTestAgent',
        description: 'Test agent for orphaned tool goroutine panic',
        tools: [st],
      );

      final (cancelOpt, cancelFn) = withCancel();
      final iter = agent.run(
        ctx,
        AgentInput(messages: [Message.user('Use the tool')]),
        options: [cancelOpt],
      );

      await st.started.future;

      // Go: 50 ms.
      const timeout = Duration(milliseconds: 5);
      final handle = cancelFn(
        safePoints: {CancelSafePoint.afterChatModel},
        timeout: timeout,
      );
      expect(handle.contributed, isTrue, reason: 'Cancel should contribute');

      final outcome = await handle.wait();
      expect(
        outcome,
        anyOf(CancelOutcome.cancelled, CancelOutcome.timedOut),
        reason: 'handle.Wait should return nil or ErrCancelTimeout, got: $outcome',
      );

      await iter.collectAll();

      // Go waits 3 s for the orphaned tool goroutine to finish and send into
      // the closed generator; here the orphaned tool finishes now. An error
      // it raised would fail the test from the test's zone.
      st.unblock.complete();
      await pumpEventQueue();
    });
  });

  test('TestCancel_SafePointNeverFires_ErrExecutionEnded', () async {
    final m = _Model(
      Message.assistant('Final answer, no tool calls'),
      blocking: true,
    );
    final runner = Runner(
      agent: _agent(
        m,
        name: 'NoToolAgent',
        description: 'Agent with no tools',
        instruction: 'You are a test assistant',
      ),
    );

    final (cancelOpt, cancelFn) = withCancel();
    final iter =
        runner.run(ctx, [Message.user('hello')], options: [cancelOpt]);

    // Go sleeps 50 ms for the agent to enter Generate and block on the gate.
    await m.started.future;

    // A safe point after tool calls, for an agent with no tools: it never
    // fires.
    final handle = cancelFn(safePoints: {CancelSafePoint.afterToolCalls});
    expect(handle.contributed, isTrue);

    m.unblock.complete();

    expect(await handle.wait(), CancelOutcome.executionEnded);

    await iter.collectAll();
  });

  // --- cancel_edge_test.go ---

  test('TestWithCancel_BeforeExecutionStarts', () async {
    final blk = _Model(
      _toolCallMsg([_toolCall('c1', 'bt', '{"input":"x"}')]),
      blocking: true,
    );
    final bt = _Tool('bt', blocking: true);
    final agent = _agent(blk, description: 'test', tools: [bt]);

    final (cancelOpt, cancelFn) = withCancel();

    // The cancel context, to see that the cancel is registered before the
    // run starts.
    final cc = CommonAgentOptions.of([cancelOpt]).cancelContext!;

    // Cancel BEFORE agent.run; it must not hang although nothing runs yet.
    final cancelDone = cancelFn().wait();

    // Go waits for cancelChan to close.
    expect(cc.shouldCancel, isTrue);

    final iter = agent.run(
      ctx,
      AgentInput(messages: [Message.user('hi')]),
      options: [cancelOpt],
    );

    final (_, hasCancelError) = await _drainEvents(iter);
    expect(hasCancelError, isTrue, reason: 'expected CancelError when cancel precedes execution');

    // Either outcome is fine; what matters is that it does not hang.
    await cancelDone;

    expect(bt.callCount, 0, reason: 'tool must not be called');
  });

  test('TestWithCancel_AfterCompletion', () async {
    final agent = _agent(_Model(Message.assistant('done')), description: 'test');

    final (cancelOpt, cancelFn) = withCancel();
    final iter = agent.run(
      ctx,
      AgentInput(messages: [Message.user('hi')]),
      options: [cancelOpt],
    );
    await iter.collectAll();

    final handle = cancelFn();
    expect(await handle.wait(), CancelOutcome.executionEnded);
  });

  test('TestWithCancel_AfterBusinessInterrupt', () async {
    final agent = _agent(_InterruptingModel(), description: 'test');
    final store = InMemoryCheckpointStore();
    final runner = Runner(agent: agent, checkpointStore: store);

    final (cancelOpt, cancelFn) = withCancel();
    final iter = runner.run(
      ctx,
      [Message.user('hi')],
      options: [cancelOpt, AgentRunOption.checkpointId('biz-interrupt-1')],
    );

    var gotInterrupt = false;
    for (final event in await iter.collectAll()) {
      if (event.action?.interrupted != null) gotInterrupt = true;
    }
    expect(gotInterrupt, isTrue, reason: 'expected business interrupt event');

    final handle = cancelFn();
    expect(await handle.wait(), CancelOutcome.executionEnded);
  });

  test('TestWithCancel_AfterError', () async {
    final agent = _agent(
      _ErrorModel(const ThreepioException('model exploded')),
      description: 'test',
    );

    final (cancelOpt, cancelFn) = withCancel();
    final iter = agent.run(
      ctx,
      AgentInput(messages: [Message.user('hi')]),
      options: [cancelOpt],
    );
    await iter.collectAll();

    final handle = cancelFn();
    expect(await handle.wait(), CancelOutcome.executionEnded);
  });

  test('TestWithCancel_TimeoutEscalation', () async {
    final blk = _Model(Message.assistant('hello'), blocking: true);
    final runner = Runner(
      agent: _agent(blk, description: 'test'),
      // Streaming, so that the cancel-monitored model stream is exercised.
      enableStreaming: true,
    );

    // Go: 300 ms. The model never finishes, so the safe point after it
    // cannot fire; the timeout escalates to an immediate cancel.
    const timeout = Duration(milliseconds: 20);
    final (cancelOpt, cancelFn) = withCancel();
    final iter = runner.run(ctx, [Message.user('go')], options: [cancelOpt]);

    await blk.started.future;

    final stopwatch = Stopwatch()..start();
    final handle = cancelFn(
      safePoints: {CancelSafePoint.afterChatModel},
      timeout: timeout,
    );
    final outcome = await handle.wait();
    final elapsed = stopwatch.elapsed;

    expect(
      outcome,
      CancelOutcome.timedOut,
      reason: 'cancel should return ErrCancelTimeout after timeout escalation',
    );
    expect(
      elapsed,
      greaterThanOrEqualTo(timeout),
      reason: 'should wait at least the timeout duration, elapsed=$elapsed',
    );
    expect(
      elapsed,
      lessThan(const Duration(seconds: 3)),
      reason: 'should complete shortly after timeout, elapsed=$elapsed',
    );

    AgentRunCancelledException? cancelError;
    for (final event in await iter.collectAll()) {
      cancelError = _cancelErrorOf(event) ?? cancelError;
    }
    expect(cancelError, isNotNull, reason: 'expected CancelError after timeout escalation');
    expect(cancelError!.info.escalated, isTrue, reason: 'CancelError should report Escalated=true');
    expect(cancelError.info.timeout, isTrue, reason: 'CancelError should report Timeout=true');
  });

  test('TestWithCancel_AfterChatModel_WithTools', () async {
    final blk = _Model(
      _toolCallMsg([_toolCall('c1', 'bt', '{"input":"x"}')]),
      blocking: true,
    );
    final bt = _Tool('bt', blocking: true);
    final agent = _agent(blk, description: 'test', tools: [bt]);

    final (cancelOpt, cancelFn) = withCancel();
    final iter = agent.run(
      ctx,
      AgentInput(messages: [Message.user('hi')]),
      options: [cancelOpt],
    );

    await blk.started.future;

    final cancelDone =
        cancelFn(safePoints: {CancelSafePoint.afterChatModel}).wait();

    await pumpEventQueue();

    blk.unblock.complete();

    expect(await cancelDone, CancelOutcome.cancelled);

    final (_, hasCancelError) = await _drainEvents(iter);
    expect(hasCancelError, isTrue, reason: 'CancelError expected after model returns tool calls');
  });

  test('TestWithCancel_CancelImmediate_StreamAborted', () async {
    final blk = _Model(Message.assistant('hello'), blocking: true);
    final runner = Runner(
      agent: _agent(blk, description: 'test'),
      enableStreaming: true,
    );

    final (cancelOpt, cancelFn) = withCancel();
    final iter = runner.run(ctx, [Message.user('hi')], options: [cancelOpt]);

    await blk.started.future;
    await pumpEventQueue();

    final stopwatch = Stopwatch()..start();
    final handle = cancelFn();
    expect(await handle.wait(), CancelOutcome.cancelled);
    final elapsed = stopwatch.elapsed;
    expect(
      elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'cancel should complete quickly, elapsed=$elapsed',
    );

    var foundCancelError = false;
    for (final event in await iter.collectAll()) {
      if (event.action?.interrupted != null) foundCancelError = true;
      if (_isCancelError(event)) foundCancelError = true;
    }
    expect(foundCancelError, isTrue, reason: 'expected CancelError in event stream');
  });

  test('TestWithCancel_MultipleToolsConcurrent', () async {
    final bt1 = _Tool('tool1', blocking: true);
    final bt2 = _Tool('tool2', blocking: true);

    // The model calls both tools in one response.
    final modelResp = _toolCallMsg([
      _toolCall('c1', 'tool1', '{"input":"a"}'),
      _toolCall('c2', 'tool2', '{"input":"b"}'),
    ]);
    final agent =
        _agent(_Model(modelResp), description: 'test', tools: [bt1, bt2]);

    final (cancelOpt, cancelFn) = withCancel();
    final iter = agent.run(
      ctx,
      AgentInput(messages: [Message.user('go')]),
      options: [cancelOpt],
    );

    // Wait for both tools to start.
    await Future.wait([bt1.started.future, bt2.started.future]);

    // Cancel after tool calls while both are still blocking.
    final cancelDone =
        cancelFn(safePoints: {CancelSafePoint.afterToolCalls}).wait();

    // Unblock both tools; the cancel fires only after both complete.
    await pumpEventQueue();
    bt1.unblock.complete();
    await pumpEventQueue();
    bt2.unblock.complete();

    expect(await cancelDone, CancelOutcome.cancelled);

    expect(bt1.callCount, 1, reason: 'tool1 should complete');
    expect(bt2.callCount, 1, reason: 'tool2 should complete');

    final (_, hasCancelError) = await _drainEvents(iter);
    expect(hasCancelError, isTrue, reason: 'expected CancelError after concurrent tools completed');
  });

  test('TestWithCancel_GraphInterruptRaceBeforeSet', () async {
    final blk = _Model(Message.assistant('hi'), blocking: true);
    final agent = _agent(blk, description: 'test');

    final (cancelOpt, cancelFn) = withCancel();

    final iter = agent.run(
      ctx,
      AgentInput(messages: [Message.user('hi')]),
      options: [cancelOpt],
    );

    // Go cancels from a goroutine that races agent.Run; here the immediate
    // cancel comes after run() returned, before the run's graph registered
    // its interrupter (the retroactive-fire path).
    unawaited(cancelFn().wait());

    // The iteration completes (the test's timeout replaces Go's 5 s).
    await _drainEvents(iter);
  });

  test('TestWithCancel_NoCheckpointStore', () async {
    final blk = _Model(Message.assistant('hi'), blocking: true);
    // No checkpoint store.
    final runner = Runner(agent: _agent(blk, description: 'test'));

    final (cancelOpt, cancelFn) = withCancel();
    final iter = runner.run(ctx, [Message.user('hi')], options: [cancelOpt]);

    await blk.started.future;
    await pumpEventQueue();

    final handle = cancelFn();
    expect(await handle.wait(), CancelOutcome.cancelled);

    AgentRunCancelledException? ce;
    for (final event in await iter.collectAll()) {
      ce = _cancelErrorOf(event);
      if (ce != null) break;
    }
    expect(ce, isNotNull, reason: 'expected CancelError even without checkpoint store');
  });

  test('TestWithCancel_ModelError', () async {
    final agent = _agent(
      _ErrorModel(const ThreepioException('model failed')),
      description: 'test',
    );

    final (cancelOpt, cancelFn) = withCancel();
    final iter = agent.run(
      ctx,
      AgentInput(messages: [Message.user('hi')]),
      options: [cancelOpt],
    );

    var gotModelErr = false;
    for (final event in await iter.collectAll()) {
      if (event.error != null && !_isCancelError(event)) gotModelErr = true;
    }
    expect(gotModelErr, isTrue, reason: 'expected non-cancel error event from model failure');

    final handle = cancelFn();
    expect(
      await handle.wait(),
      CancelOutcome.executionEnded,
      reason: 'cancelFn should return ErrExecutionEnded after model error',
    );
  });

  test('TestWithCancel_Resume_SafePoint', () async {
    // --- phase 1: run to get a checkpoint via CancelImmediate ---
    final blk = _Model(
      _toolCallMsg([_toolCall('c1', 'bt', '{"input":"x"}')]),
      blocking: true,
    );
    // Go: 50 ms.
    final bt = _Tool('bt', result: 'result');
    final store = InMemoryCheckpointStore();
    final runner1 = Runner(
      agent: _agent(blk, description: 'test', tools: [bt]),
      checkpointStore: store,
    );

    final (cancelOpt1, cancelFn1) = withCancel();
    final iter1 = runner1.run(
      ctx,
      [Message.user('hi')],
      options: [cancelOpt1, AgentRunOption.checkpointId('resume-sp-1')],
    );

    await blk.started.future;
    cancelFn1();
    await _drainEvents(iter1);

    // --- phase 2: resume, cancel after chat model ---
    final resumeModel = _Model(
      _toolCallMsg([_toolCall('c1', 'bt', '{"input":"x"}')]),
      blocking: true,
    );
    final bt2 = _Tool('bt', result: 'result');
    final runner2 = Runner(
      agent: _agent(resumeModel, description: 'test', tools: [bt2]),
      checkpointStore: store,
    );

    final (cancelOpt2, cancelFn2) = withCancel();
    final resumeIter =
        await runner2.resume(ctx, 'resume-sp-1', options: [cancelOpt2]);

    await resumeModel.started.future;

    final cancelDone =
        cancelFn2(safePoints: {CancelSafePoint.afterChatModel}).wait();

    await pumpEventQueue();

    resumeModel.unblock.complete();

    expect(await cancelDone, CancelOutcome.cancelled);

    final (_, hasCancelError) = await _drainEvents(resumeIter);
    expect(
      hasCancelError,
      isTrue,
      reason: 'CancelError expected after resumed model returns tool calls',
    );
  });

  test('TestWithCancel_TargetedResume_CancelImmediate', () async {
    final blk = _Model(
      _toolCallMsg([_toolCall('c1', 'st', '{"input":"x"}')]),
      blocking: true,
    );
    final st = _Tool('st', result: 'result');
    final store = InMemoryCheckpointStore();
    final runner = Runner(
      agent: _agent(blk, description: 'test', tools: [st]),
      checkpointStore: store,
    );

    final (cancelOpt, cancelFn) = withCancel();
    final iter = runner.run(
      ctx,
      [Message.user('go')],
      options: [cancelOpt, AgentRunOption.checkpointId('targeted-imm-1')],
    );

    await blk.started.future;

    // CancelImmediate (the default).
    final handle = cancelFn();
    expect(await handle.wait(), CancelOutcome.cancelled);

    AgentRunCancelledException? cancelError;
    for (final event in await iter.collectAll()) {
      cancelError = _cancelErrorOf(event) ?? cancelError;
    }

    expect(cancelError, isNotNull, reason: 'expected CancelError');
    expect(
      cancelError!.interruptContexts,
      isNotEmpty,
      reason: 'CancelError should have InterruptContexts for targeted resume',
    );

    // --- resume with targeted params ---
    final targets = <String, Object?>{
      for (final ic in cancelError.interruptContexts) ic.id: null,
    };

    final resumeModel = _Model(Message.assistant('resumed'));
    final runner2 = Runner(
      agent: _agent(resumeModel, description: 'test', tools: [st]),
      checkpointStore: store,
    );

    final resumeIter = await runner2.resumeWithParams(
      ctx,
      'targeted-imm-1',
      ResumeParams(targets: targets),
    );

    var gotOutput = false;
    for (final event in await resumeIter.collectAll()) {
      if (event.error != null) {
        fail('unexpected error during targeted resume: ${event.error}');
      }
      if (event.output?.messageOutput != null) gotOutput = true;
    }
    expect(gotOutput, isTrue, reason: 'targeted resume should produce output');
  });

  test('TestWithCancel_TargetedResume_SafePoint', () async {
    // The model returns a tool call, so the react graph reaches the safe
    // point after the model, which interrupts for CancelAfterChatModel.
    final blk = _Model(
      _toolCallMsg([_toolCall('c1', 'st', '{"input":"x"}')]),
      blocking: true,
    );
    final st = _Tool('st', result: 'result');
    final store = InMemoryCheckpointStore();
    final runner = Runner(
      agent: _agent(blk, description: 'test', tools: [st]),
      checkpointStore: store,
    );

    final (cancelOpt, cancelFn) = withCancel();
    final iter = runner.run(
      ctx,
      [Message.user('go')],
      options: [cancelOpt, AgentRunOption.checkpointId('targeted-sp-1')],
    );

    await blk.started.future;

    // The cancel is registered before the model returns.
    final cancelDone =
        cancelFn(safePoints: {CancelSafePoint.afterChatModel}).wait();
    await pumpEventQueue();
    blk.unblock.complete();

    expect(await cancelDone, CancelOutcome.cancelled);

    AgentRunCancelledException? cancelError;
    for (final event in await iter.collectAll()) {
      cancelError = _cancelErrorOf(event) ?? cancelError;
    }

    expect(cancelError, isNotNull, reason: 'expected CancelError');
    expect(
      cancelError!.interruptContexts,
      isNotEmpty,
      reason: 'CancelError should have InterruptContexts for targeted resume',
    );

    // --- resume with targeted params ---
    final targets = <String, Object?>{
      for (final ic in cancelError.interruptContexts) ic.id: null,
    };

    final resumeModel = _Model(Message.assistant('resumed'));
    final runner2 = Runner(
      agent: _agent(resumeModel, description: 'test', tools: [st]),
      checkpointStore: store,
    );

    final resumeIter = await runner2.resumeWithParams(
      ctx,
      'targeted-sp-1',
      ResumeParams(targets: targets),
    );

    var gotOutput = false;
    for (final event in await resumeIter.collectAll()) {
      if (event.error != null) {
        fail('unexpected error during targeted resume: ${event.error}');
      }
      if (event.output?.messageOutput != null) gotOutput = true;
    }
    expect(gotOutput, isTrue, reason: 'targeted resume should produce output');
  });

  group('TestWithCancel_Resume_CancelAfterChatModel_MessagePreserved', () {
    test('react_path_tool_call_preserved', () async {
      // The phase-2 model returns no tool calls, so the graph ends; the test
      // tracks whether the tool runs on resume.
      var toolExecuted = false;
      final st = _Tool('my_tool', result: 'ok', onCall: () => toolExecuted = true);

      // The phase-1 model returns a tool call.
      final blk = _Model(
        _toolCallMsg([_toolCall('c1', 'my_tool', '{"input":"x"}')]),
        blocking: true,
      );

      final store = InMemoryCheckpointStore();
      final runner1 = Runner(
        agent: _agent(blk, description: 'test', tools: [st]),
        checkpointStore: store,
      );

      final (cancelOpt1, cancelFn1) = withCancel();
      final iter1 = runner1.run(
        ctx,
        [Message.user('hi')],
        options: [
          cancelOpt1,
          AgentRunOption.checkpointId('react-msg-preserved-1'),
        ],
      );

      await blk.started.future;

      final cancelDone =
          cancelFn1(safePoints: {CancelSafePoint.afterChatModel}).wait();
      await pumpEventQueue();
      blk.unblock.complete();

      expect(await cancelDone, CancelOutcome.cancelled);

      final (_, hasCancelError) = await _drainEvents(iter1);
      expect(hasCancelError, isTrue, reason: 'expected CancelError from phase 1');

      // Phase 2: resume. The model answers with plain text, so the graph
      // ends after one iteration, but first the tool from the checkpoint
      // must run.
      final resumeModel = _Model(Message.assistant('done'));
      final runner2 = Runner(
        agent: _agent(resumeModel, description: 'test', tools: [st]),
        checkpointStore: store,
      );

      final resumeIter = await runner2.resume(ctx, 'react-msg-preserved-1');

      for (final event in await resumeIter.collectAll()) {
        if (event.error != null) {
          fail('unexpected error during resume: ${event.error}');
        }
      }

      // The tool can only run on resume if the tool-call message was kept.
      expect(
        toolExecuted,
        isTrue,
        reason: 'tool was not executed on resume — the tool-call message was lost',
      );
    });
  });

  group('TestWithCancel_CancelImmediate_NestedAgentTool_ResumeFromToolsNode', () {
    late Duration savedGracePeriod;
    setUp(() {
      savedGracePeriod = cancelImmediateGracePeriod;
      // Go: 1 s; the grace period ends early when the run finishes.
      cancelImmediateGracePeriod = const Duration(milliseconds: 20);
    });
    tearDown(() => cancelImmediateGracePeriod = savedGracePeriod);

    for (final tc in [
      (name: 'Invoke_InnerNoTools_NonRecursive', enableStreaming: false, innerHasTools: false, recursive: false),
      (name: 'Stream_InnerNoTools_NonRecursive', enableStreaming: true, innerHasTools: false, recursive: false),
      (name: 'Invoke_InnerWithTools_NonRecursive', enableStreaming: false, innerHasTools: true, recursive: false),
      (name: 'Stream_InnerWithTools_NonRecursive', enableStreaming: true, innerHasTools: true, recursive: false),
      (name: 'Invoke_InnerNoTools_Recursive', enableStreaming: false, innerHasTools: false, recursive: true),
      (name: 'Stream_InnerNoTools_Recursive', enableStreaming: true, innerHasTools: false, recursive: true),
      (name: 'Invoke_InnerWithTools_Recursive', enableStreaming: false, innerHasTools: true, recursive: true),
      (name: 'Stream_InnerWithTools_Recursive', enableStreaming: true, innerHasTools: true, recursive: true),
    ]) {
      test(tc.name, () async {
        // --- inner agent: its model blocks, so that the run is cancelled
        // mid-execution ---
        final List<BaseTool> innerTools;
        final Message innerModelResp;
        if (tc.innerHasTools) {
          innerModelResp =
              _toolCallMsg([_toolCall('ic1', 'inner_tool', '{"input":"x"}')]);
          innerTools = [_Tool('inner_tool', blocking: true, result: 'result')];
        } else {
          innerModelResp = Message.assistant('inner agent done');
          innerTools = const [];
        }
        final innerModel = _Model(innerModelResp, blocking: true);
        addTearDown(innerModel.unblock.complete);

        final innerAgent = _agent(
          innerModel,
          name: 'InnerAgent',
          description: 'inner agent that blocks',
          instruction: 'you are an inner agent',
          tools: innerTools,
        );

        // --- outer agent: counting model ---
        // Call 1: a tool call of InnerAgent. Call 2 (only needed on resume):
        // a plain final answer.
        final outerModel = _CountingModel([
          _toolCallMsg([
            _toolCall('c1', 'InnerAgent', '{"request":"do something"}'),
          ]),
          Message.assistant('outer completed'),
        ]);

        final outerAgent = _agent(
          outerModel,
          name: 'OuterAgent',
          description: 'outer agent with nested agent tool',
          instruction: 'you are an outer agent',
          tools: [AgentTool(innerAgent)],
        );

        final store = InMemoryCheckpointStore();
        final checkpointId = 'cancel-nested-resume-${tc.name}';

        final runner1 = Runner(
          agent: outerAgent,
          enableStreaming: tc.enableStreaming,
          checkpointStore: store,
        );

        // --- phase 1: run and cancel while the inner agent's model blocks ---
        final (cancelOpt, cancelFn) = withCancel();
        final iter = runner1.run(
          ctx,
          [Message.user('go')],
          options: [cancelOpt, AgentRunOption.checkpointId(checkpointId)],
        );

        // The inner model started: the outer model returned its tool call.
        await innerModel.started.future;

        expect(
          outerModel.callCount,
          1,
          reason: 'outer model should have been called once before cancel',
        );

        // Cancel at once. The recursive cases also pass the cancel to the
        // AgentTool's inner ChatModelAgent.
        final handle = tc.recursive ? cancelFn(recursive: true) : cancelFn();
        expect(await handle.wait(), CancelOutcome.cancelled);

        final (_, hasCancelError) = await _drainEvents(iter);
        expect(
          hasCancelError,
          isTrue,
          reason: 'expected CancelError from canceled nested agent tool',
        );

        // --- phase 2: Runner.resume (no targets, no interrupt id) ---
        // Fresh agents. A recursive cancel resumes the inner ChatModelAgent
        // inside the AgentTool before the outer agent answers.
        final resumeModelCalls = <String>[];
        final resumeOuterModel = _CountingModel(
          [Message.assistant('outer completed after resume')],
          label: 'outer',
          callLog: resumeModelCalls,
        );

        final resumeInnerModel = _CountingModel(
          tc.innerHasTools
              ? [
                  _toolCallMsg([
                    _toolCall('ic1', 'inner_tool', '{"input":"x"}'),
                  ]),
                  Message.assistant('inner agent done after resume'),
                ]
              : [Message.assistant('inner agent done after resume')],
          label: 'inner',
          callLog: resumeModelCalls,
        );
        final resumeInnerAgent = _agent(
          resumeInnerModel,
          name: 'InnerAgent',
          description: 'inner agent that returns immediately on resume',
          instruction: 'you are an inner agent',
          tools: tc.innerHasTools
              ? [_Tool('inner_tool', result: 'inner tool result')]
              : const [],
        );

        final resumeOuterAgent = _agent(
          resumeOuterModel,
          name: 'OuterAgent',
          description: 'outer agent with nested agent tool',
          instruction: 'you are an outer agent',
          tools: [AgentTool(resumeInnerAgent)],
        );

        final runner2 = Runner(
          agent: resumeOuterAgent,
          enableStreaming: tc.enableStreaming,
          checkpointStore: store,
        );

        final resumeIter = await runner2.resume(ctx, checkpointId);
        final resumeEvents = await resumeIter.collectAll();

        expect(resumeModelCalls, isNotEmpty, reason: 'no model call observed during resume');
        if (tc.recursive) {
          expect(
            resumeModelCalls.first,
            'inner',
            reason: 'recursive cancel should resume the AgentTool/internal '
                'ChatModelAgent first',
          );
        } else {
          expect(
            resumeModelCalls.first,
            isIn(['outer', 'inner']),
            reason: 'non-recursive cancel does not define whether a root or '
                'already-persisted inner checkpoint resumes first',
          );
        }

        for (final event in resumeEvents) {
          if (event.error != null) {
            fail('unexpected error during resume: ${event.error}');
          }
        }

        // The outer model is called once on resume (for the final answer
        // after the tool results), not restarted from the beginning.
        expect(
          resumeOuterModel.callCount,
          1,
          reason: 'outer model should be called exactly once during resume '
              '(for final answer after tool results), not restarted from the '
              'beginning',
        );

        var gotOutput = false;
        for (final event in resumeEvents) {
          if (await _messageOutputContent(event) ==
              'outer completed after resume') {
            gotOutput = true;
          }
        }
        expect(gotOutput, isTrue, reason: 'should get final output from resumed outer agent');
      });
    }
  });
}
