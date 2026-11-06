// Ports eino v0.9.22 cancel tests about the cancel internals and recursive
// cancels:
//
// * `adk/cancel_recursive_test.go` (all): TestDeriveCheckpointAwareCancelContext,
//   TestDeriveAbortOnlyCancelContext, TestWithAbortOnlyCancelContext,
//   TestCheckPreExecCancel, TestDeriveCheckpointAwareCancelContext_Race,
//   TestAppendCancelContextOption_CopiesInputSlice,
//   TestDeriveCheckpointAwareSubAgentCancelContext,
//   TestResolveRunCancelContext_CheckpointAwareInheritedScope,
//   TestAttack_DirectNestedAgentUnderCheckpointAwareParentGetsAbortOnlyScope.
// * `adk/cancel_multicall_test.go` (all): TestAgentCancelFunc_MultiCall_EscalateToImmediate,
//   TestAgentCancelFunc_MultiCall_JoinSafePointModes,
//   TestAgentCancelFunc_MultiCall_TimeoutDeadlineJoinUsesAbsoluteTime,
//   TestAgentCancelFunc_MultiCall_TimeoutEscalationReturnsErrCancelTimeout.
// * `adk/cancel_stream_race_test.go` (all):
//   TestWithCancel_CancelImmediate_MidStream_AlwaysCheckpoints.
// * From `adk/cancel_test.go`: TestCancelMonitoredToolHandler_StreamableToolCall,
//   TestCancelMonitoredToolHandler_EnhancedStreamableToolCall, TestCancelContextKey,
//   TestFilterCancelOption, TestWrapIterWithMarkDone, TestGraphInterruptFuncs_Parallel,
//   TestCancelImmediate_CustomAgent_GracePeriodFallback,
//   TestCancelImmediate_MultiLevelNesting, TestCancelContext_RecursiveGraceBoundary,
//   TestBuildCancelFunc_StateDoneUnderLock.
// * From `adk/cancel_edge_test.go`:
//   TestWithCancel_DerivedCheckpointCancelContextMarkedDoneAfterRun,
//   TestWithCancel_RecursiveDoesNotTargetAgentEmbeddedInMiddleware,
//   TestWithCancel_RecursiveImmediate_MiddlewareChildAbortOnly,
//   TestWithCancel_RecursiveImmediate_MiddlewareChildAgentToolCheckpointResumeBarrier,
//   TestWithCancel_RecursiveImmediate_BeforeAgentChildAbortOnly,
//   TestWithCancel_RecursiveImmediate_MultiLevelMiddlewareChildrenAbortOnly,
//   TestWithCancel_NonRecursiveImmediate_DoesNotAbortMiddlewareChild,
//   TestWithCancel_CancelImmediate_StreamableToolAborted,
//   TestWithCancel_CancelImmediate_RecursiveAgentTool_StreamableToolResume,
//   TestWithCancel_CancelImmediate_RecursiveAgentTool_ResumeDeepestAgentTool,
//   TestWithCancel_CancelImmediate_ConcurrentAgentTools_ResumeWithoutRestart.
//
// Not ported:
// * TestDeriveCheckpointAwareCancelContext/Shallow/NeverRecursive_GoroutineCleanup:
//   counts Go goroutines; Dart has no equivalent.
// * TestDeriveAbortOnlyCancelContext/NilParentReturnsNil: `deriveAbortOnly` is a
//   method of a non-null parent; null safety rules the case out at compile time.
// * TestBuildCancelFunc_CASFailStateDone: only exercises a Go data race (the
//   window between a state check and a CAS); its deterministic outcome is
//   pinned by TestBuildCancelFunc_StateDoneUnderLock.
// * TestCancelImmediate_AgentTool_PreservesChildCheckpoint: needs
//   NewSequentialAgent (workflow agents are not ported).
//
// Go's goroutines + sleeps become Completers; a Go model that "takes 2 s"
// awaits a future that never completes (an immediate cancel abandons it).
// `assertNotClosedWithin(ch, 50ms)` becomes a 5 ms settle and a check.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/agent_context.dart'
    show ChatModelAgentExecContext, withExecContext;
import 'package:threepio_core/src/adk/eino/cancel.dart';
import 'package:threepio_core/src/adk/eino/run_options.dart'
    show CommonAgentOptions, cancelContextOption, filterCancelOption;

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// Port of Go `cancelTestChatModel` (`newTestChatModel`) and of
/// `simpleChatModel`: answers [response] on every call. With [blocks] (Go's
/// 2 s delay) the call never finishes.
final class _TestChatModel extends BaseChatModel {
  _TestChatModel(this.response, {this.blocks = false});

  final Message response;
  final bool blocks;
  final Completer<void> started = Completer<void>();
  final Completer<void> done = Completer<void>();
  int calls = 0;

  Future<Message> _call() async {
    calls++;
    if (!started.isCompleted) started.complete();
    if (blocks) await Completer<void>().future;
    if (!done.isCompleted) done.complete();
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

/// Port of Go `blockingChatModel`: blocks until [unblock] completes, then
/// answers [response].
final class _BlockingModel extends BaseChatModel {
  _BlockingModel(this.response);

  final Message response;
  final Completer<void> unblock = Completer<void>();
  final Completer<void> started = Completer<void>();
  int calls = 0;

  Future<Message> _call() async {
    calls++;
    if (!started.isCompleted) started.complete();
    await unblock.future;
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

/// Port of Go `contextAwareBlockingChatModel`: blocks until [release]
/// completes or the call's context is cancelled (Go `ctx.Done()`; here the
/// cancel token of `options.runContext`), which it reports in
/// [cancelObserved].
final class _ContextAwareBlockingModel extends BaseChatModel {
  _ContextAwareBlockingModel(this.response);

  final Message response;
  final Completer<void> release = Completer<void>();
  final Completer<void> started = Completer<void>();
  final Completer<void> cancelObserved = Completer<void>();
  int calls = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    calls++;
    if (!started.isCompleted) started.complete();
    final token = options?.runContext?.cancelToken;
    final cancelled = await Future.any([
      if (token != null) token.whenCancelled.then((_) => true),
      release.future.then((_) => false),
    ]);
    if (cancelled) {
      if (!cancelObserved.isCompleted) cancelObserved.complete();
      token!.throwIfCancelled();
    }
    return response;
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

/// Port of Go `plainResponseModel`: answers [text] at once.
final class _PlainModel extends BaseChatModel {
  _PlainModel(this.text);

  final String text;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      Message.assistant(text);

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([Message.assistant(text)]);
}

/// Port of Go `countingChatModel`: answers [responses] in order, logging
/// [label] into [callLog] on every call; a call beyond [responses] fails.
final class _CountingModel extends BaseChatModel {
  _CountingModel(this.responses, {this.callLog, this.label = ''});

  final List<Message> responses;
  final List<String>? callLog;
  final String label;
  int calls = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final index = calls++;
    callLog?.add(label);
    if (index >= responses.length) {
      throw StateError(
        'countingChatModel: call ${index + 1} exceeds ${responses.length} '
        'responses (outer model was called too many times - possible restart '
        'from beginning)',
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

/// Port of Go `deltaThenStuckChatModel`: streams [delta], then hangs as a
/// provider whose transport is never torn down.
final class _DeltaThenStuckModel extends BaseChatModel {
  _DeltaThenStuckModel(this.delta);

  final Message delta;
  final Completer<void> started = Completer<void>();

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      delta;

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final (reader, writer) = pipe<Message>(capacity: 1);
    writer.send(delta);
    if (!started.isCompleted) started.complete();
    // Never closed: the transport hangs.
    return reader;
  }
}

/// Port of Go `toolCallStreamModel`: a call of `slow_tool` first, then
/// `done`.
final class _ToolCallStreamModel extends BaseChatModel {
  int calls = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    calls++;
    if (calls == 1) {
      return _toolCallMsg([_toolCall('c1', 'slow_tool', '{"input":"x"}')]);
    }
    return Message.assistant('done');
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

// ---------------------------------------------------------------------------
// Tools and agents
// ---------------------------------------------------------------------------

const _inputParams = {'input': ParameterInfo(type: DataType.string)};

/// Port of Go `callbackTool`.
final class _CallbackTool extends InvokableTool {
  _CallbackTool(this.toolName, this.onCall);

  final String toolName;
  final void Function() onCall;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.fromParams(name: toolName, desc: 'callback tool', params: _inputParams);

  @override
  Future<String> run(String argumentsJson) async {
    onCall();
    return 'ok';
  }
}

/// Port of Go `blockingTool`: blocks until [unblock] completes.
final class _BlockingTool extends InvokableTool {
  _BlockingTool(this.toolName);

  final String toolName;
  final Completer<void> unblock = Completer<void>();
  int calls = 0;

  @override
  Future<ToolInfo> info() async =>
      ToolInfo.fromParams(name: toolName, desc: 'blocking tool', params: _inputParams);

  @override
  Future<String> run(String argumentsJson) async {
    calls++;
    await unblock.future;
    return 'result';
  }
}

/// Port of Go `slowStreamingTool` (a streamable, not invokable, tool): sends
/// [chunks]; with a [gate] it parks after the second chunk until the gate
/// completes. Go's chunk interval becomes one event-loop turn.
final class _SlowStreamingTool extends StreamableTool {
  _SlowStreamingTool(this.toolName, this.chunks, {this.gate});

  final String toolName;
  final List<String> chunks;
  final Future<void>? gate;
  final Completer<void> started = Completer<void>();
  final Completer<void> parked = Completer<void>();

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: toolName,
        desc: 'slow streaming tool',
        params: _inputParams,
      );

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final (reader, writer) = pipe<String>(capacity: 1);
    unawaited(() async {
      try {
        if (!started.isCompleted) started.complete();
        for (final (index, chunk) in chunks.indexed) {
          await Future<void>.delayed(Duration.zero);
          if (await writer.sendAsync(chunk)) return;
          if (index == 1 && gate != null) {
            if (!parked.isCompleted) parked.complete();
            await gate;
          }
        }
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }
}

/// Port of Go `cancelUnawareAgent`: a custom agent that ignores the cancel
/// protocol; its run never ends (Go: sleeps 5 s, longer than the test).
final class _CancelUnawareAgent implements Agent {
  _CancelUnawareAgent(this.name, this.description);

  @override
  final String name;

  @override
  final String description;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final (reader, _) = pipe<AgentEvent>();
    return reader;
  }
}

/// Port of Go `testAfterModelRewriteStateHandler`.
final class _AfterModelRewriteStateHandler extends ChatModelAgentMiddleware {
  _AfterModelRewriteStateHandler(this.fn);

  final Future<(RunContext, ChatModelAgentState)> Function(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) fn;

  @override
  Future<(RunContext, ChatModelAgentState)> afterModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) =>
      fn(ctx, state, model);
}

/// Eino's deprecated `AgentMiddleware{BeforeChatModel: fn}` (not ported):
/// the same hook as `beforeModelRewriteState`, before every model call.
final class _BeforeChatModelHandler extends ChatModelAgentMiddleware {
  _BeforeChatModelHandler(this.fn);

  final Future<void> Function(RunContext ctx, ChatModelAgentState state) fn;

  @override
  Future<(RunContext, ChatModelAgentState)> beforeModelRewriteState(
    RunContext ctx,
    ChatModelAgentState state,
    ModelContext model,
  ) async {
    await fn(ctx, state);
    return (ctx, state);
  }
}

/// Port of Go `testBeforeAgentHandler`.
final class _BeforeAgentHandler extends ChatModelAgentMiddleware {
  _BeforeAgentHandler(this.fn);

  final Future<(RunContext, ChatModelAgentContext)> Function(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) fn;

  @override
  Future<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) =>
      fn(ctx, agent);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Message _toolCallMsg(List<ToolCall> calls) =>
    Message(role: RoleType.assistant, toolCalls: calls);

ToolCall _toolCall(String id, String name, String args) =>
    ToolCall(id: id, function: FunctionCall(name: name, arguments: args));

/// Port of Go `newToolCallResponse`.
Message _newToolCallResponse(String toolName) =>
    _toolCallMsg([_toolCall('call_1', toolName, '{}')]);

ChatModelAgent _agent(
  String name,
  BaseChatModel model, {
  String? description,
  String instruction = '',
  List<BaseTool> tools = const [],
  Set<String> returnDirectly = const {},
  List<ChatModelAgentMiddleware> handlers = const [],
}) =>
    ChatModelAgent(
      ChatModelAgentConfig(
        name: name,
        description: description ?? name,
        instruction: instruction,
        model: model,
        toolsConfig: ToolsConfig(
          toolsNode: ToolsNodeConfig(tools: tools),
          returnDirectly: returnDirectly,
        ),
        handlers: handlers,
      ),
    );

/// Port of Go `newAgentWithTool`.
ChatModelAgent _agentWithTool(String name, BaseChatModel model, Agent subAgent) =>
    _agent(name, model, tools: [AgentTool(subAgent)]);

AgentRunCancelledException? _cancelErrorOf(AgentEvent event) =>
    ThreepioException.findCause<AgentRunCancelledException>(event.error);

/// Port of Go `drainEvents`.
Future<(List<AgentEvent>, bool)> _drainEvents(StreamReader<AgentEvent> events) async {
  final all = await events.collectAll();
  return (all, all.any((e) => _cancelErrorOf(e) != null));
}

/// Port of Go `drainCancelErrors`.
Future<(List<AgentEvent>, List<AgentRunCancelledException>)> _drainCancelErrors(
  StreamReader<AgentEvent> events,
) async {
  final all = await events.collectAll();
  return (
    all,
    [
      for (final event in all)
        if (_cancelErrorOf(event) case final cancelled?) cancelled,
    ],
  );
}

/// Port of Go `drainCancelError`: the last cancel error of the stream.
Future<AgentRunCancelledException?> _drainCancelError(
  StreamReader<AgentEvent> events,
) async {
  AgentRunCancelledException? found;
  for (final event in await events.collectAll()) {
    found = _cancelErrorOf(event) ?? found;
  }
  return found;
}

/// Port of Go `drainResumeErrors`.
Future<List<Object>> _drainResumeErrors(StreamReader<AgentEvent> events) async => [
      for (final event in await events.collectAll())
        if (event.error case final error?) error,
    ];

/// Port of Go `runChildAgentToEnd`: the first error event is rethrown.
Future<void> _runChildAgentToEnd(RunContext ctx, Agent child, String message) async {
  final events = child.run(ctx, AgentInput(messages: [Message.user(message)]));
  for (var event = await events.nextOrNull();
      event != null;
      event = await events.nextOrNull()) {
    final error = event.error;
    if (error != null) {
      Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
    }
  }
}

/// Port of Go `assertCancelErrorExcludesAddresses`.
void _expectExcludesAddresses(AgentRunCancelledException cancelled, List<String> names) {
  for (final context in cancelled.interruptContexts) {
    final address = '${context.address}';
    for (final name in names) {
      expect(address, isNot(contains(name)));
    }
  }
}

/// Go's `assertNotClosedWithin(ch, 50ms)` and the waits for a propagation:
/// the propagation runs in microtasks, a few milliseconds are plenty.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

/// Go's `context.WithCancel(context.Background())`.
(RunContext, void Function()) _cancellableContext() {
  final token = CancelToken();
  return (RunContext.background(cancelToken: token), token.cancel);
}

/// Port of Go `setupParentChild`.
(CancelContext, CancelContext) _setupParentChild() {
  final parent = CancelContext.root();
  final (ctx, cancel) = _cancellableContext();
  final child = parent.deriveCheckpointAware(ctx);
  addTearDown(() {
    child.markDone();
    cancel();
  });
  return (parent, child);
}

/// Port of Go `setupAbortOnlyChild`.
(CancelContext, CancelContext) _setupAbortOnlyChild() {
  final parent = CancelContext.root();
  final (ctx, cancel) = _cancellableContext();
  final child = parent.deriveAbortOnly(ctx);
  addTearDown(() {
    child.markDone();
    cancel();
  });
  return (parent, child);
}

/// A graph interrupter for a cancel context (Go's `setGraphInterruptFunc`
/// with a counting function). An interrupter can be called once only (a
/// second call throws), so "called once" is `isInterrupted`.
GraphInterrupter _interrupter() => RunContext.background().withGraphInterrupt().$2;

void main() {
  final ctx = RunContext.background();

  late Duration savedGracePeriod;
  setUp(() {
    savedGracePeriod = cancelImmediateGracePeriod;
    // Go: 1 s. The descendants of a recursive immediate cancel report their
    // interrupts within a few event-loop turns.
    cancelImmediateGracePeriod = const Duration(milliseconds: 20);
  });
  tearDown(() => cancelImmediateGracePeriod = savedGracePeriod);

  // -------------------------------------------------------------------------
  // cancel_recursive_test.go
  // -------------------------------------------------------------------------

  group('TestDeriveCheckpointAwareCancelContext', () {
    group('Shallow', () {
      test('DoesNotPropagateSafePoint', () async {
        final (parent, child) = _setupParentChild();
        parent.triggerCancel({CancelSafePoint.afterChatModel});
        await _settle();
        expect(child.shouldCancel, isFalse);
      });

      test('ImmediateDoesNotPropagate', () async {
        final (parent, child) = _setupParentChild();
        parent.triggerImmediateCancel();
        await _settle();
        expect(child.isImmediateCancelled, isFalse);
      });

      test('GrandchildNoPropagation', () async {
        final a = CancelContext.root();
        final (ctx, cancel) = _cancellableContext();
        final b = a.deriveCheckpointAware(ctx);
        final c = b.deriveCheckpointAware(ctx);
        addTearDown(() {
          c.markDone();
          b.markDone();
          cancel();
        });

        a.triggerCancel({CancelSafePoint.afterChatModel});
        await _settle();
        expect(b.shouldCancel, isFalse);
        expect(c.shouldCancel, isFalse);
      });
    });

    group('Recursive', () {
      test('PropagatesSafePoint', () async {
        final (parent, child) = _setupParentChild();
        parent
          ..setRecursive(true)
          ..triggerCancel({CancelSafePoint.afterChatModel});
        await _settle();
        expect(child.shouldCancel, isTrue);
      });

      test('ImmediatePropagates', () async {
        final (parent, child) = _setupParentChild();
        parent
          ..setRecursive(true)
          ..triggerImmediateCancel();
        await _settle();
        expect(child.isImmediateCancelled, isTrue);
      });

      test('GrandchildPropagation', () async {
        final a = CancelContext.root();
        final (ctx, cancel) = _cancellableContext();
        final b = a.deriveCheckpointAware(ctx);
        final c = b.deriveCheckpointAware(ctx);
        addTearDown(() {
          c.markDone();
          b.markDone();
          cancel();
        });

        a
          ..setRecursive(true)
          ..triggerCancel({CancelSafePoint.afterChatModel});
        await _settle();
        expect(b.shouldCancel, isTrue);
        expect(c.shouldCancel, isTrue);
      });

      test('SetBeforeCancel', () async {
        final (parent, child) = _setupParentChild();
        parent.setRecursive(true);
        parent.triggerCancel({CancelSafePoint.afterChatModel});
        await _settle();
        expect(child.shouldCancel, isTrue);
      });

      test('AfterRecursiveAndCancelAlreadySet', () async {
        final parent = CancelContext.root();
        final (ctx, cancel) = _cancellableContext();
        parent
          ..setRecursive(true)
          ..triggerCancel({CancelSafePoint.afterChatModel});

        final child = parent.deriveCheckpointAware(ctx);
        addTearDown(() {
          child.markDone();
          cancel();
        });
        await _settle();
        expect(child.shouldCancel, isTrue);
      });
    });

    group('Escalation', () {
      test('EscalateFromNonRecursive', () async {
        final (parent, child) = _setupParentChild();
        parent.triggerCancel({CancelSafePoint.afterChatModel});
        await _settle();
        expect(child.shouldCancel, isFalse);

        parent.setRecursive(true);
        await _settle();
        expect(child.shouldCancel, isTrue);
      });

      test('EscalateImmediate', () async {
        final (parent, child) = _setupParentChild();
        parent.triggerImmediateCancel();
        await _settle();
        expect(child.isImmediateCancelled, isFalse);

        parent.setRecursive(true);
        await _settle();
        expect(child.isImmediateCancelled, isTrue);
      });
    });
  });

  group('TestDeriveAbortOnlyCancelContext', () {
    test('SafePointDoesNotPropagate', () async {
      final (parent, child) = _setupAbortOnlyChild();
      parent
        ..setRecursive(true)
        ..triggerCancel({CancelSafePoint.afterChatModel});
      await _settle();
      expect(child.shouldCancel, isFalse);
      expect(child.isImmediateCancelled, isFalse);
    });

    test('RecursiveImmediatePropagates', () async {
      final (parent, child) = _setupAbortOnlyChild();
      parent
        ..setRecursive(true)
        ..triggerImmediateCancel();
      await _settle();
      expect(child.isImmediateCancelled, isTrue);
    });

    test('LateRecursiveImmediateEscalationPropagates', () async {
      final (parent, child) = _setupAbortOnlyChild();
      parent.triggerImmediateCancel();
      await _settle();
      expect(child.isImmediateCancelled, isFalse);

      parent.setRecursive(true);
      await _settle();
      expect(child.isImmediateCancelled, isTrue);
    });

    test('ChildCompletionPreventsLaterPropagation', () async {
      final (parent, child) = _setupAbortOnlyChild();
      parent.triggerImmediateCancel();
      await _settle();
      child.markDone();
      parent.setRecursive(true);
      await _settle();
      expect(child.isImmediateCancelled, isFalse);
    });

    test('ParentImmediateThenContextDoneExits', () async {
      final parent = CancelContext.root();
      final (ctx, cancel) = _cancellableContext();
      final child = parent.deriveAbortOnly(ctx);
      addTearDown(() {
        child.markDone();
        cancel();
      });

      parent.triggerImmediateCancel();
      await _settle();
      expect(child.isImmediateCancelled, isFalse);

      cancel();
      await _settle();
      expect(child.isImmediateCancelled, isFalse);
    });

    test('CheckpointAwareDescendantStopsAtAbortOnlyBoundary', () {
      final root = CancelContext.root();
      final (ctx, cancel) = _cancellableContext();
      addTearDown(cancel);

      final abortOnly = root.deriveAbortOnly(ctx);
      final checkpointAwareScope = abortOnly.deriveCheckpointAware(ctx);
      addTearDown(() {
        checkpointAwareScope.markDone();
        abortOnly.markDone();
      });

      checkpointAwareScope.markCheckpointAwareDescendant();

      expect(checkpointAwareScope.hasCheckpointAwareDescendant, isTrue);
      expect(abortOnly.hasCheckpointAwareDescendant, isFalse);
      expect(root.hasCheckpointAwareDescendant, isFalse);
    });
  });

  test('TestWithAbortOnlyCancelContext', () async {
    // Go sets `abortOnly` on a fresh context; in Dart it is final, so the
    // abort-only context is derived from a root.
    final cc = CancelContext.root().deriveAbortOnly(ctx);

    final (abortCtx, cancel) = withAbortOnlyCancelContext(ctx, cc);
    addTearDown(cancel);

    cc.markDone();
    await _settle();
    expect(
      abortCtx.cancelToken.isCancelled,
      isTrue,
      reason: 'abort-only context was not canceled when cancel context completed',
    );
  });

  group('TestCheckPreExecCancel', () {
    test('AbortOnlyImmediateTerminatesWithoutEvent', () async {
      final cc = CancelContext.root().deriveAbortOnly(ctx)
        ..triggerImmediateCancel();

      final (reader, writer) = pipe<AgentEvent>();
      expect(checkPreExecCancel(cc, writer.send), isTrue);
      await cc.done;
      expect(cc.isDone, isTrue);

      await writer.close();
      expect(await reader.nextOrNull(), isNull);
    });

    test('AlreadyHandledCancelTerminatesWithoutDuplicateEvent', () async {
      final cc = CancelContext.root()..triggerImmediateCancel();
      expect(cc.markCancelHandled(), isTrue);

      final (reader, writer) = pipe<AgentEvent>();
      expect(checkPreExecCancel(cc, writer.send), isTrue);

      await writer.close();
      expect(await reader.nextOrNull(), isNull);
    });
  });

  group('TestDeriveCheckpointAwareCancelContext_Race', () {
    test('SetRecursiveConcurrentWithCancelChan', () async {
      // Go races two goroutines 100 times; Dart is single-threaded: every
      // order of the two calls, back to back or a microtask apart.
      for (final recursiveFirst in [true, false]) {
        for (final gap in [false, true]) {
          final parent = CancelContext.root();
          final (ctx, cancel) = _cancellableContext();
          final child = parent.deriveCheckpointAware(ctx);

          Future<void> setRecursive() async => parent.setRecursive(true);
          Future<void> trigger() async =>
              parent.triggerCancel({CancelSafePoint.afterChatModel});
          final calls = recursiveFirst ? [setRecursive, trigger] : [trigger, setRecursive];
          await calls[0]();
          if (gap) await Future<void>.value();
          await calls[1]();

          await _settle();
          expect(
            child.shouldCancel,
            isTrue,
            reason: 'recursiveFirst=$recursiveFirst gap=$gap: child did not receive cancel',
          );
          child.markDone();
          cancel();
        }
      }
    });

    test('ChildCompletesBeforeEscalation', () async {
      final parent = CancelContext.root();
      final (ctx, cancel) = _cancellableContext();
      addTearDown(cancel);
      final child = parent.deriveCheckpointAware(ctx);

      parent.triggerCancel({CancelSafePoint.afterChatModel});
      await _settle();
      child.markDone();
      await _settle();
      parent.setRecursive(true);

      await _settle();
      expect(child.shouldCancel, isFalse);
    });

    test('MultipleChildren_PartialCompletion', () async {
      final parent = CancelContext.root();
      final (ctx, cancel) = _cancellableContext();
      addTearDown(cancel);
      final child1 = parent.deriveCheckpointAware(ctx);
      final child2 = parent.deriveCheckpointAware(ctx);

      parent.triggerCancel({CancelSafePoint.afterChatModel});
      await _settle();
      child1.markDone();
      await _settle();
      parent.setRecursive(true);

      await _settle();
      expect(child2.shouldCancel, isTrue);
      expect(child1.shouldCancel, isFalse);
      child2.markDone();
    });

    test('ContextCancelConcurrentWithRecursive', () async {
      // Go checks for a deadlock between two goroutines; here: both orders.
      for (final cancelFirst in [true, false]) {
        final parent = CancelContext.root();
        final (ctx, cancel) = _cancellableContext();
        final child = parent.deriveCheckpointAware(ctx);
        parent.triggerCancel({CancelSafePoint.afterChatModel});

        if (cancelFirst) {
          cancel();
          parent.setRecursive(true);
        } else {
          parent.setRecursive(true);
          cancel();
        }
        child.markDone();
        await _settle();
      }
    });

    test('ConcurrentSetRecursive', () {
      final parent = CancelContext.root();
      for (var i = 0; i < 10; i++) {
        parent.setRecursive(true);
      }
      expect(parent.isRecursive, isTrue);
    });
  });

  test('TestAppendCancelContextOption_CopiesInputSlice', () {
    final parent = CancelContext.root();
    final (baseCtx, cancel) = _cancellableContext();
    addTearDown(cancel);
    final child = parent.deriveCheckpointAware(baseCtx);
    addTearDown(child.markDone);

    // Go's `skipTransferMessages` option (transfer is not ported): any other
    // option. A growable list: appending in place would be visible.
    final opts = <AgentRunOption>[AgentRunOption.custom<String>('skip-transfer')];

    final childOpts = appendCancelContextOption(opts, child);

    expect(opts, hasLength(1));
    expect(childOpts, hasLength(2));
    expect(
      CommonAgentOptions.of(opts).cancelContext,
      isNull,
      reason: "appendCancelContextOption reused the caller's list",
    );
    expect(
      CommonAgentOptions.of(childOpts).cancelContext,
      same(child),
      reason: 'sub-agent opts did not receive the requested cancel context',
    );
  });

  group('TestDeriveCheckpointAwareSubAgentCancelContext', () {
    test('CheckpointAwareParent', () {
      final parent = CancelContext.root();
      final (baseCtx, cancel) = _cancellableContext();
      addTearDown(cancel);
      final runCtx = withCancelContext(baseCtx, parent);

      final child = deriveCheckpointAwareSubAgentCancelContext(runCtx, const []);
      if (child != null) addTearDown(child.markDone);

      expect(child, isNotNull, reason: 'sub-agent cancel context was not derived');
      expect(child, isNot(same(parent)));
      expect(child!.parent, same(parent));
      expect(child.abortOnly, isFalse);
      expect(parent.hasCheckpointAwareDescendant, isTrue);
    });

    test('AbortOnlyParentIsResumeBarrier', () {
      final root = CancelContext.root();
      final (baseCtx, cancel) = _cancellableContext();
      addTearDown(cancel);
      final abortOnly = root.deriveAbortOnly(baseCtx);
      addTearDown(abortOnly.markDone);
      final runCtx = withCancelContext(baseCtx, abortOnly);

      final child = deriveCheckpointAwareSubAgentCancelContext(runCtx, const []);
      if (child != null) addTearDown(child.markDone);

      expect(child, isNull, reason: 'crossed an abort-only resume barrier');
      expect(abortOnly.hasCheckpointAwareDescendant, isFalse);
      expect(root.hasCheckpointAwareDescendant, isFalse);
    });
  });

  test('TestResolveRunCancelContext_CheckpointAwareInheritedScope', () {
    final parent = CancelContext.root();
    final (baseCtx, cancel) = _cancellableContext();
    addTearDown(cancel);

    final child = parent.deriveCheckpointAware(baseCtx);
    addTearDown(child.markDone);
    final runCtx = withCancelContext(baseCtx, child);

    final (got, owned) = resolveRunCancelContext(runCtx, null);
    expect(got, same(child), reason: 'checkpoint-aware inherited scope was not reused');
    expect(owned, isFalse);
  });

  test('TestAttack_DirectNestedAgentUnderCheckpointAwareParentGetsAbortOnlyScope', () {
    final parent = CancelContext.root();
    final (baseCtx, cancel) = _cancellableContext();
    addTearDown(cancel);

    final checkpointAware = parent.deriveCheckpointAware(baseCtx);
    addTearDown(checkpointAware.markDone);
    var runCtx = withCancelContext(baseCtx, checkpointAware);
    final (_, writer) = pipe<AgentEvent>();
    runCtx = withExecContext(
      runCtx,
      ChatModelAgentExecContext(writer: writer, cancelContext: checkpointAware),
    );

    final (got, owned) = resolveRunCancelContext(runCtx, null);
    expect(got, isNot(same(checkpointAware)));
    expect(got, isNotNull);
    expect(got!.abortOnly, isTrue);
    expect(got.parent, same(checkpointAware));
    expect(owned, isTrue);
  });

  // -------------------------------------------------------------------------
  // cancel_multicall_test.go
  // -------------------------------------------------------------------------

  test('TestAgentCancelFunc_MultiCall_EscalateToImmediate', () async {
    final cc = CancelContext.root();
    final interrupter = _interrupter();
    cc.addGraphInterrupter(interrupter);

    final handle1 = cc.cancel(safePoints: {CancelSafePoint.afterChatModel});
    final handle2 = cc.cancel();
    expect(interrupter.isInterrupted, isTrue);

    final cancelError = cc.createCancelError();
    expect(cancelError.info.safePoints, isEmpty);
    expect(cancelError.info.escalated, isTrue);
    expect(cancelError.info.timeout, isFalse);

    expect(cc.markCancelHandled(), isTrue);
    expect(await handle1.wait(), CancelOutcome.cancelled);
    expect(await handle2.wait(), CancelOutcome.cancelled);
  });

  test('TestAgentCancelFunc_MultiCall_JoinSafePointModes', () async {
    final cc = CancelContext.root();

    final handle1 = cc.cancel(safePoints: {CancelSafePoint.afterChatModel});
    final handle2 = cc.cancel(safePoints: {CancelSafePoint.afterToolCalls});

    expect(cc.mode, {CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls});

    expect(cc.markCancelHandled(), isTrue);
    expect(await handle1.wait(), CancelOutcome.cancelled);
    expect(await handle2.wait(), CancelOutcome.cancelled);
  });

  test('TestAgentCancelFunc_MultiCall_TimeoutDeadlineJoinUsesAbsoluteTime', () {
    fakeAsync((async) {
      final cc = CancelContext.root();
      final handle1 = cc.cancel(
        safePoints: {CancelSafePoint.afterChatModel},
        timeout: const Duration(milliseconds: 200),
      );
      async.elapse(const Duration(milliseconds: 50));
      final handle2 = cc.cancel(
        safePoints: {CancelSafePoint.afterToolCalls},
        timeout: const Duration(milliseconds: 60),
      );

      expect(cc.markCancelHandled(), isTrue);
      final outcomes = <CancelOutcome>[];
      handle1.wait().then(outcomes.add);
      handle2.wait().then(outcomes.add);
      async.flushMicrotasks();
      expect(outcomes, [CancelOutcome.cancelled, CancelOutcome.cancelled]);

      // Go reads the private deadline; here it is observed: the second
      // request's deadline (50 + 60 = 110 ms after the first) is earlier than
      // the first one's (200 ms), so the cancel escalates at 110 ms.
      final observed = CancelContext.root();
      final interrupter = _interrupter();
      observed
        ..addGraphInterrupter(interrupter)
        ..cancel(
          safePoints: {CancelSafePoint.afterChatModel},
          timeout: const Duration(milliseconds: 200),
        );
      async.elapse(const Duration(milliseconds: 50));
      observed.cancel(
        safePoints: {CancelSafePoint.afterToolCalls},
        timeout: const Duration(milliseconds: 60),
      );
      async.elapse(const Duration(milliseconds: 59));
      expect(interrupter.isInterrupted, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(interrupter.isInterrupted, isTrue);
      expect(observed.markCancelHandled(), isTrue);
    });
  });

  test('TestAgentCancelFunc_MultiCall_TimeoutEscalationReturnsErrCancelTimeout', () {
    fakeAsync((async) {
      final cc = CancelContext.root();
      final interrupter = _interrupter();
      cc.addGraphInterrupter(interrupter);
      final handle = cc.cancel(
        safePoints: {CancelSafePoint.afterChatModel},
        timeout: const Duration(milliseconds: 30),
      );

      async.elapse(const Duration(milliseconds: 30));
      expect(interrupter.isInterrupted, isTrue, reason: 'timeout escalation did not interrupt');

      final cancelError = cc.createCancelError();
      expect(cancelError.info.safePoints, {CancelSafePoint.afterChatModel});
      expect(cancelError.info.escalated, isTrue);
      expect(cancelError.info.timeout, isTrue);

      expect(cc.markCancelHandled(), isTrue);
      CancelOutcome? outcome;
      handle.wait().then((o) => outcome = o);
      async.flushMicrotasks();
      expect(outcome, CancelOutcome.timedOut);
    });
  });

  // -------------------------------------------------------------------------
  // cancel_stream_race_test.go
  // -------------------------------------------------------------------------

  test('TestWithCancel_CancelImmediate_MidStream_AlwaysCheckpoints', () async {
    // Go repeats 300 times to catch a goroutine race; Dart is deterministic,
    // a few iterations keep the loop honest.
    const iterations = 10;
    for (var i = 0; i < iterations; i++) {
      final model = _DeltaThenStuckModel(Message.assistant('hello'));
      final agent = _agent('TestAgent', model, description: 'test');
      final store = InMemoryCheckpointStore();
      final runner = Runner(agent: agent, enableStreaming: true, checkpointStore: store);

      const checkpointId = 'mid-stream-race';
      final (cancelOpt, cancelFn) = withCancel();
      final events = runner.run(
        ctx,
        [Message.user('hi')],
        options: [cancelOpt, AgentRunOption.checkpointId(checkpointId)],
      );

      await model.started.future;

      final handle = cancelFn();
      expect(await handle.wait(), CancelOutcome.cancelled, reason: 'iteration $i');

      var foundCancelError = false;
      var foundRawStreamCanceled = false;
      for (final event in await events.collectAll()) {
        if (_cancelErrorOf(event) != null) {
          foundCancelError = true;
        } else if (ThreepioException.findCause<StreamCanceledException>(event.error) != null) {
          foundRawStreamCanceled = true;
        }
      }
      expect(foundRawStreamCanceled, isFalse, reason: 'iteration $i: raw StreamCanceled leaked');
      expect(foundCancelError, isTrue, reason: 'iteration $i: expected a cancel error');
      expect(await store.get(checkpointId), isNotNull, reason: 'iteration $i: no checkpoint');
    }
  });

  // -------------------------------------------------------------------------
  // cancel_test.go
  // -------------------------------------------------------------------------

  const toolInput = ToolCallInput(name: 'test', arguments: '', callId: '');

  group('TestCancelMonitoredToolHandler_StreamableToolCall', () {
    test('NoCancelContext_PassesThrough', () async {
      final (r, w) = pipe<String>(capacity: 1);
      unawaited(() async {
        await w.sendAsync('chunk1');
        await w.sendAsync('chunk2');
        await w.close();
      }());

      Future<StreamToolCallOutput> next(RunContext ctx, ToolCallInput input) async =>
          StreamToolCallOutput(r);

      final wrapped = cancelMonitoredToolMiddleware.streamable!(next);
      final output = await wrapped(RunContext.background(), toolInput);

      expect(await output.result.recv(), 'chunk1');
      expect(await output.result.recv(), 'chunk2');
      await expectLater(output.result.recv(), throwsA(isA<StreamEOFException>()));
    });

    test('WithCancelContext_NoCancel_StreamsNormally', () async {
      final cc = CancelContext.root();
      final (r, w) = pipe<String>(capacity: 1);
      unawaited(() async {
        await w.sendAsync('data1');
        await w.sendAsync('data2');
        await w.close();
      }());

      Future<StreamToolCallOutput> next(RunContext ctx, ToolCallInput input) async =>
          StreamToolCallOutput(r);

      final wrapped = cancelMonitoredToolMiddleware.streamable!(next);
      final output = await wrapped(withCancelContext(ctx, cc), toolInput);

      expect(await output.result.recv(), 'data1');
      expect(await output.result.recv(), 'data2');
      await expectLater(output.result.recv(), throwsA(isA<StreamEOFException>()));
    });

    test('WithCancelContext_ImmediateCancel_TerminatesStream', () async {
      final cc = CancelContext.root();
      // Go sleeps 200 ms before the second chunk: a gate that never opens.
      final (r, w) = pipe<String>(capacity: 1);
      unawaited(() async {
        await w.sendAsync('chunk1');
        await Completer<void>().future;
        await w.sendAsync('chunk2');
      }());

      Future<StreamToolCallOutput> next(RunContext ctx, ToolCallInput input) async =>
          StreamToolCallOutput(r);

      final wrapped = cancelMonitoredToolMiddleware.streamable!(next);
      final output = await wrapped(withCancelContext(ctx, cc), toolInput);

      expect(await output.result.recv(), 'chunk1');

      // Go: close(cc.immediateChan).
      cc.sendImmediateInterrupt();

      await expectLater(output.result.recv(), throwsA(isA<StreamCanceledException>()));
    });

    test('WithCancelContext_AlreadyCancelled_TerminatesImmediately', () async {
      final cc = CancelContext.root()..sendImmediateInterrupt();

      final (r, w) = pipe<String>(capacity: 1);
      unawaited(() async {
        await w.sendAsync('should-not-see');
        await w.close();
      }());

      Future<StreamToolCallOutput> next(RunContext ctx, ToolCallInput input) async =>
          StreamToolCallOutput(r);

      final wrapped = cancelMonitoredToolMiddleware.streamable!(next);
      final output = await wrapped(withCancelContext(ctx, cc), toolInput);

      await expectLater(output.result.recv(), throwsA(isA<StreamCanceledException>()));
    });

    test('NextReturnsError_PropagatesError', () async {
      final cc = CancelContext.root();
      final nextError = Exception('tool execution failed');

      Future<StreamToolCallOutput> next(RunContext ctx, ToolCallInput input) async =>
          throw nextError;

      final wrapped = cancelMonitoredToolMiddleware.streamable!(next);
      await expectLater(
        wrapped(withCancelContext(ctx, cc), toolInput),
        throwsA(same(nextError)),
      );
    });
  });

  group('TestCancelMonitoredToolHandler_EnhancedStreamableToolCall', () {
    test('NoCancelContext_PassesThrough', () async {
      final tr1 = ToolResult([ToolOutputPart.text('chunk1')]);
      final (r, w) = pipe<ToolResult>(capacity: 1);
      unawaited(() async {
        await w.sendAsync(tr1);
        await w.close();
      }());

      Future<EnhancedStreamToolCallOutput> next(RunContext ctx, ToolCallInput input) async =>
          EnhancedStreamToolCallOutput(r);

      final wrapped = cancelMonitoredToolMiddleware.enhancedStreamable!(next);
      final output = await wrapped(RunContext.background(), toolInput);

      expect(await output.result.recv(), tr1);
      await expectLater(output.result.recv(), throwsA(isA<StreamEOFException>()));
    });

    test('WithCancelContext_ImmediateCancel_TerminatesStream', () async {
      final cc = CancelContext.root();
      final tr1 = ToolResult([ToolOutputPart.text('chunk1')]);
      final tr2 = ToolResult([ToolOutputPart.text('chunk2')]);
      final (r, w) = pipe<ToolResult>(capacity: 1);
      unawaited(() async {
        await w.sendAsync(tr1);
        await Completer<void>().future;
        await w.sendAsync(tr2);
      }());

      Future<EnhancedStreamToolCallOutput> next(RunContext ctx, ToolCallInput input) async =>
          EnhancedStreamToolCallOutput(r);

      final wrapped = cancelMonitoredToolMiddleware.enhancedStreamable!(next);
      final output = await wrapped(withCancelContext(ctx, cc), toolInput);

      expect(await output.result.recv(), tr1);

      cc.sendImmediateInterrupt();

      await expectLater(output.result.recv(), throwsA(isA<StreamCanceledException>()));
    });

    test('NextReturnsError_PropagatesError', () async {
      final cc = CancelContext.root();
      final nextError = Exception('enhanced tool failed');

      Future<EnhancedStreamToolCallOutput> next(RunContext ctx, ToolCallInput input) async =>
          throw nextError;

      final wrapped = cancelMonitoredToolMiddleware.enhancedStreamable!(next);
      await expectLater(
        wrapped(withCancelContext(ctx, cc), toolInput),
        throwsA(same(nextError)),
      );
    });
  });

  group('TestCancelContextKey', () {
    test('WithAndGet_RoundTrips', () {
      final cc = CancelContext.root();
      expect(cancelContextOf(withCancelContext(ctx, cc)), same(cc));
    });

    test('Get_NoValue_ReturnsNil', () {
      expect(cancelContextOf(RunContext.background()), isNull);
    });

    test('With_NilCancelContext_ReturnsOriginalCtx', () {
      final base = RunContext.background();
      expect(withCancelContext(base, null), same(base));
    });
  });

  group('TestFilterCancelOption', () {
    test('RemovesCancelOption', () {
      final (cancelOpt, _) = withCancel();
      final sessionOpt = AgentRunOption.sessionValues({'key': 'value'});

      final filtered = filterCancelOption([cancelOpt, sessionOpt]);
      expect(filtered, hasLength(1), reason: 'Should have removed the cancel option');

      final common = CommonAgentOptions.of(filtered);
      expect(common.sessionValues, {'key': 'value'});
      expect(common.cancelContext, isNull);
    });

    test('KeepsNonCancelOptions', () {
      final sessionOpt = AgentRunOption.sessionValues({'key': 'value'});
      final callbackOpt = AgentRunOption.callbacks(const []);

      expect(filterCancelOption([sessionOpt, callbackOpt]), hasLength(2));
    });

    test('EmptyInput', () {
      // Go: nil in, nil out; Dart lists are never null.
      expect(filterCancelOption(const []), isEmpty);
    });
  });

  // Go tests a helper of its test file (`wrapIterWithMarkDone`); the library's
  // counterpart is `wrapEventsWithCancelContext`, which also marks done.
  group('TestWrapIterWithMarkDone', () {
    test('MarksDoneAfterDrain', () async {
      final cc = CancelContext.root();
      final (reader, writer) = pipe<AgentEvent>();
      unawaited(() async {
        writer.send(AgentEvent(agentName: 'test'));
        await writer.close();
      }());

      final wrapped = wrapEventsWithCancelContext(reader, cc);

      final event = await wrapped.nextOrNull();
      expect(event, isNotNull);
      expect(event!.agentName, 'test');
      expect(await wrapped.nextOrNull(), isNull);

      await cc.done;
      expect(cc.isDone, isTrue, reason: 'doneChan was not closed after drain');
    });

    test('NilCancelContext_PassesThrough', () {
      final (reader, writer) = pipe<AgentEvent>();
      unawaited(() async {
        writer.send(AgentEvent(agentName: 'test'));
        await writer.close();
      }());

      expect(wrapEventsWithCancelContext(reader, null), same(reader));
    });
  });

  group('TestGraphInterruptFuncs_Parallel', () {
    test('MultipleGraphInterruptFuncsAllCalled', () {
      final cc = CancelContext.root();
      final first = _interrupter();
      final second = _interrupter();
      cc
        ..addGraphInterrupter(first)
        ..addGraphInterrupter(second)
        // Go: setMode(CancelImmediate), CAS running→cancelling, close(cancelChan).
        ..triggerCancel(const {})
        ..sendImmediateInterrupt();

      expect(first.isInterrupted, isTrue, reason: 'first graph interrupt func should be called');
      expect(second.isInterrupted, isTrue, reason: 'second graph interrupt func should be called');
    });

    test('RetroactiveFire_OnSetAfterCancel', () {
      // Go pokes the fields of an immediate cancel that was sent; here the
      // methods that set them.
      final cc = CancelContext.root()
        ..triggerCancel(const {})
        ..sendImmediateInterrupt();

      final late = _interrupter();
      cc.addGraphInterrupter(late);

      expect(late.isInterrupted, isTrue, reason: 'should retroactively fire new func');
    });
  });

  test('TestCancelImmediate_CustomAgent_GracePeriodFallback', () async {
    final customAgent = _CancelUnawareAgent('custom_slow', 'A custom agent that ignores cancel');

    final rootModel = _TestChatModel(_newToolCallResponse('custom_slow'));
    final rootAgent = _agentWithTool('root_agent', rootModel, customAgent);

    final runner = Runner(agent: rootAgent);

    final (cancelOpt, cancelFn) = withCancel();
    final events = runner.run(ctx, [Message.user('test')], options: [cancelOpt]);

    await rootModel.started.future;
    await rootModel.done.future;

    final stopwatch = Stopwatch()..start();
    final handle = cancelFn();
    expect(await handle.wait(), CancelOutcome.cancelled);

    final cancelError = await _drainCancelError(events);
    stopwatch.stop();

    expect(cancelError, isNotNull, reason: 'Should have CancelError (from grace period fallback)');
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('TestCancelImmediate_MultiLevelNesting', () async {
    final innerLeafModel = _TestChatModel(
      Message.assistant('inner leaf response'),
      blocks: true,
    );
    final innerLeafAgent = _agent(
      'inner_leaf',
      innerLeafModel,
      description: 'Innermost leaf agent',
    );

    final middleAgent = _agentWithTool(
      'middle_agent',
      _TestChatModel(_newToolCallResponse('inner_leaf')),
      innerLeafAgent,
    );

    final rootAgent = _agentWithTool(
      'root_agent',
      _TestChatModel(_newToolCallResponse('middle_agent')),
      middleAgent,
    );

    final store = InMemoryCheckpointStore();
    final runner = Runner(agent: rootAgent, checkpointStore: store);

    final (cancelOpt, cancelFn) = withCancel();
    final events = runner.run(
      ctx,
      [Message.user('test')],
      options: [cancelOpt, AgentRunOption.checkpointId('multi-level-1')],
    );

    await innerLeafModel.started.future;

    final stopwatch = Stopwatch()..start();
    final handle = cancelFn();
    expect(handle.contributed, isTrue);
    expect(await handle.wait(), CancelOutcome.cancelled);

    final cancelError = await _drainCancelError(events);
    stopwatch.stop();

    expect(cancelError, isNotNull, reason: 'Should have CancelError from multi-level nesting');
    expect(cancelError!.interruptSignal, isNotNull);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));

    final resumeInnerLeaf = _agent(
      'inner_leaf',
      _TestChatModel(Message.assistant('resumed inner leaf')),
      description: 'Innermost leaf agent',
    );
    final resumeMiddle = _agentWithTool(
      'middle_agent',
      _TestChatModel(Message.assistant('resumed middle')),
      resumeInnerLeaf,
    );
    final resumeRoot = _agentWithTool(
      'root_agent',
      _TestChatModel(Message.assistant('resumed root')),
      resumeMiddle,
    );

    final runner2 = Runner(agent: resumeRoot, checkpointStore: store);
    final resumeEvents = await runner2.resume(ctx, 'multi-level-1');
    expect(
      await _drainResumeErrors(resumeEvents),
      isEmpty,
      reason: 'Resume should complete without errors',
    );
  });

  group('TestCancelContext_RecursiveGraceBoundary', () {
    test('CheckpointAwareDescendantMarker_PropagatesToParents', () {
      final parent = CancelContext.root();
      final child = parent.deriveCheckpointAware(ctx);
      final grandchild = child.deriveCheckpointAware(ctx);
      addTearDown(() {
        grandchild.markDone();
        child.markDone();
      });

      expect(parent.hasCheckpointAwareDescendant, isFalse);
      expect(child.hasCheckpointAwareDescendant, isFalse);

      grandchild.markCheckpointAwareDescendant();

      expect(grandchild.hasCheckpointAwareDescendant, isTrue);
      expect(child.hasCheckpointAwareDescendant, isTrue);
      expect(parent.hasCheckpointAwareDescendant, isTrue);
    });
  });

  test('TestBuildCancelFunc_StateDoneUnderLock', () async {
    // Go holds `cancelMu` so that the run ends while the cancel waits for the
    // lock. Dart has no lock: the run ending first is the same state.
    final cc = CancelContext.root()..markDone();

    final handle = cc.cancel(safePoints: {CancelSafePoint.afterToolCalls});
    expect(
      handle.contributed,
      isFalse,
      reason: 'cancel should not be accepted when execution already done',
    );
    expect(await handle.wait(), CancelOutcome.executionEnded);
  });

  // -------------------------------------------------------------------------
  // cancel_edge_test.go
  // -------------------------------------------------------------------------

  test('TestWithCancel_DerivedCheckpointCancelContextMarkedDoneAfterRun', () async {
    final agent = _agent(
      'ChildAgent',
      _PlainModel('done'),
      description: 'test child agent',
    );

    final parent = CancelContext.root();
    final parentCtx = withCancelContext(ctx, parent);
    final child = parent.deriveCheckpointAware(parentCtx);

    final childOpt = cancelContextOption(child);
    final events = agent.run(
      parentCtx,
      AgentInput(messages: [Message.user('hi')]),
      options: [childOpt],
    );
    await events.collectAll();

    await child.done;
    expect(
      child.isDone,
      isTrue,
      reason: 'derived checkpoint cancel context was not marked done after child run completion',
    );
  });

  test('TestWithCancel_RecursiveDoesNotTargetAgentEmbeddedInMiddleware', () async {
    final innerModel = _BlockingModel(
      _toolCallMsg([_toolCall('inner-call', 'inner-tool', '{"input":"x"}')]),
    );
    final innerToolCalled = Completer<void>();
    final innerTool = _CallbackTool('inner-tool', () {
      if (!innerToolCalled.isCompleted) innerToolCalled.complete();
    });
    final innerAgent = _agent(
      'InnerMiddlewareAgent',
      innerModel,
      description: 'agent invoked as middleware implementation detail',
      tools: [innerTool],
      returnDirectly: {'inner-tool'},
    );

    final outerTool = _BlockingTool('outer-tool');
    final outerAgent = _agent(
      'OuterAgent',
      _TestChatModel(
        _toolCallMsg([_toolCall('outer-call', 'outer-tool', '{"input":"x"}')]),
      ),
      description: 'outer agent',
      tools: [outerTool],
      handlers: [
        _AfterModelRewriteStateHandler((ctx, state, _) async {
          await _runChildAgentToEnd(ctx, innerAgent, 'run');
          return (ctx, state);
        }),
      ],
    );

    final (cancelOpt, cancelFn) = withCancel();
    final events = outerAgent.run(
      ctx,
      AgentInput(messages: [Message.user('run')]),
      options: [cancelOpt],
    );

    await innerModel.started.future;

    final cancelDone = cancelFn(
      safePoints: {CancelSafePoint.afterChatModel},
      recursive: true,
    ).wait();

    innerModel.unblock.complete();

    // Go: within 5 s, else "recursive cancel incorrectly targeted the
    // middleware's embedded agent".
    await innerToolCalled.future;

    expect(await cancelDone, CancelOutcome.cancelled);

    final (_, hasCancelError) = await _drainEvents(events);
    expect(hasCancelError, isTrue, reason: 'outer agent should cancel at its own safe-point');
    expect(outerTool.calls, 0, reason: 'outer tool must not run after cancellation');
  });

  test('TestWithCancel_RecursiveImmediate_MiddlewareChildAbortOnly', () async {
    final childModel = _ContextAwareBlockingModel(Message.assistant('child done'));
    final childAgent = _agent(
      'MiddlewareChild',
      childModel,
      description: 'direct middleware child',
      instruction: 'child',
    );

    final outerAgent = _agent(
      'OuterMiddlewareAgent',
      _PlainModel('outer done'),
      description: 'outer',
      instruction: 'outer',
      handlers: [
        _BeforeChatModelHandler(
          (ctx, _) => _runChildAgentToEnd(ctx, childAgent, 'child work'),
        ),
      ],
    );

    final store = InMemoryCheckpointStore();
    const checkpointId = 'recursive-immediate-middleware-child-abort-only';
    final runner = Runner(agent: outerAgent, checkpointStore: store);

    final (cancelOpt, cancelFn) = withCancel();
    final events = runner.run(
      ctx,
      [Message.user('go')],
      options: [cancelOpt, AgentRunOption.checkpointId(checkpointId)],
    );

    await childModel.started.future;

    final handle = cancelFn(recursive: true);

    // Go: within 1 s, else "middleware child did not observe recursive
    // immediate context cancellation".
    await childModel.cancelObserved.future;

    expect(await handle.wait(), CancelOutcome.cancelled);
    final (_, cancelErrors) = await _drainCancelErrors(events);
    expect(cancelErrors, hasLength(1), reason: 'exactly one root CancelError');
    _expectExcludesAddresses(cancelErrors.single, ['MiddlewareChild']);

    final resumeChildModel = _CountingModel([Message.assistant('fresh child run after resume')]);
    final resumeChildAgent = _agent(
      'MiddlewareChild',
      resumeChildModel,
      description: 'direct middleware child',
      instruction: 'child',
    );

    final resumeOuterAgent = _agent(
      'OuterMiddlewareAgent',
      _PlainModel('outer done after resume'),
      description: 'outer',
      instruction: 'outer',
      handlers: [
        _BeforeChatModelHandler(
          (ctx, _) => _runChildAgentToEnd(ctx, resumeChildAgent, 'child work'),
        ),
      ],
    );

    final resumeRunner = Runner(agent: resumeOuterAgent, checkpointStore: store);
    final resumeEvents = await resumeRunner.resume(ctx, checkpointId);
    final (resumeAll, resumeCancelErrors) = await _drainCancelErrors(resumeEvents);
    expect(resumeCancelErrors, isEmpty);
    expect(resumeAll, isNotEmpty);
    expect(
      resumeChildModel.calls,
      1,
      reason: 'middleware child should be invoked as a fresh Run on root resume',
    );
  });

  test(
    'TestWithCancel_RecursiveImmediate_MiddlewareChildAgentToolCheckpointResumeBarrier',
    () async {
      final leafModel = _BlockingModel(Message.assistant('leaf done'));
      final leafAgent = _agent(
        'MiddlewareLeafAgent',
        leafModel,
        description: 'leaf agent wrapped as a tool under a direct middleware child',
        instruction: 'leaf',
      );

      final childModel = _CountingModel([
        _toolCallMsg([_toolCall('child-leaf', 'MiddlewareLeafAgent', '{"request":"leaf work"}')]),
        Message.assistant('child done'),
      ]);
      final childAgent = _agent(
        'MiddlewareChildWithAgentTool',
        childModel,
        description: 'direct middleware child with an agent tool',
        instruction: 'child',
        tools: [AgentTool(leafAgent)],
      );

      var childInterruptSeen = false;
      final outerAgent = _agent(
        'OuterMiddlewareAgent',
        _PlainModel('outer done'),
        description: 'outer',
        instruction: 'outer',
        handlers: [
          _BeforeChatModelHandler((ctx, _) async {
            final childEvents = childAgent.run(
              ctx,
              AgentInput(messages: [Message.user('child work')]),
            );
            for (var event = await childEvents.nextOrNull();
                event != null;
                event = await childEvents.nextOrNull()) {
              if (event.action?.interrupted != null) childInterruptSeen = true;
              final error = event.error;
              if (error != null) {
                Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
              }
            }
          }),
        ],
      );

      final store = InMemoryCheckpointStore();
      const checkpointId = 'recursive-immediate-middleware-agent-tool-resume-barrier';
      final runner = Runner(agent: outerAgent, checkpointStore: store);

      final (cancelOpt, cancelFn) = withCancel();
      final events = runner.run(
        ctx,
        [Message.user('go')],
        options: [cancelOpt, AgentRunOption.checkpointId(checkpointId)],
      );

      await leafModel.started.future;

      final handle = cancelFn(recursive: true);
      expect(
        await handle.wait(),
        CancelOutcome.cancelled,
        reason: 'the root may handle its own immediate interrupt, but not a checkpoint '
            'hidden behind a direct middleware Run',
      );
      final (_, cancelErrors) = await _drainCancelErrors(events);
      expect(cancelErrors, hasLength(1), reason: 'only the root immediate cancel');
      _expectExcludesAddresses(cancelErrors.single, ['MiddlewareLeafAgent']);
      expect(
        childInterruptSeen,
        isFalse,
        reason: 'the abort-only middleware child must swallow the nested AgentTool interrupt',
      );

      final resumeLeafModel = _CountingModel([Message.assistant('leaf done after resume')]);
      final resumeLeafAgent = _agent(
        'MiddlewareLeafAgent',
        resumeLeafModel,
        description: 'leaf agent wrapped as a tool under a direct middleware child',
        instruction: 'leaf',
      );

      final resumeChildModel = _CountingModel([
        _toolCallMsg([_toolCall('child-leaf', 'MiddlewareLeafAgent', '{"request":"leaf work"}')]),
        Message.assistant('child done after resume'),
      ]);
      final resumeChildAgent = _agent(
        'MiddlewareChildWithAgentTool',
        resumeChildModel,
        description: 'direct middleware child with an agent tool',
        instruction: 'child',
        tools: [AgentTool(resumeLeafAgent)],
      );

      final resumeOuterAgent = _agent(
        'OuterMiddlewareAgent',
        _PlainModel('outer done after resume'),
        description: 'outer',
        instruction: 'outer',
        handlers: [
          _BeforeChatModelHandler(
            (ctx, _) => _runChildAgentToEnd(ctx, resumeChildAgent, 'child work'),
          ),
        ],
      );

      final resumeRunner = Runner(agent: resumeOuterAgent, checkpointStore: store);
      final resumeEvents = await resumeRunner.resume(ctx, checkpointId);
      final (resumeAll, resumeCancelErrors) = await _drainCancelErrors(resumeEvents);
      expect(resumeCancelErrors, isEmpty);
      expect(resumeAll, isNotEmpty);
      expect(
        resumeChildModel.calls,
        greaterThanOrEqualTo(1),
        reason: 'middleware child should be invoked as a fresh Run on root resume',
      );
      expect(
        resumeLeafModel.calls,
        1,
        reason: 'nested AgentTool should run fresh, not resume from the hidden checkpoint',
      );
    },
  );

  test('TestWithCancel_RecursiveImmediate_BeforeAgentChildAbortOnly', () async {
    final childModel = _ContextAwareBlockingModel(Message.assistant('child done'));
    final childAgent = _agent(
      'BeforeAgentMiddlewareChild',
      childModel,
      description: 'direct BeforeAgent child',
      instruction: 'child',
    );

    final outerAgent = _agent(
      'OuterBeforeAgentMiddlewareAgent',
      _PlainModel('outer done'),
      description: 'outer',
      instruction: 'outer',
      handlers: [
        _BeforeAgentHandler((ctx, runCtx) async {
          await _runChildAgentToEnd(ctx, childAgent, 'child work');
          return (ctx, runCtx);
        }),
      ],
    );

    final (cancelOpt, cancelFn) = withCancel();
    // Go runs `Runner.Run` in a goroutine (BeforeAgent may block it); Dart's
    // returns at once.
    final events = Runner(agent: outerAgent).run(
      ctx,
      [Message.user('go')],
      options: [cancelOpt],
    );

    await childModel.started.future;

    final handle = cancelFn(recursive: true);

    await childModel.cancelObserved.future;

    expect(await handle.wait(), CancelOutcome.cancelled);
    final (_, cancelErrors) = await _drainCancelErrors(events);
    expect(cancelErrors, hasLength(1), reason: 'exactly one root CancelError');
    _expectExcludesAddresses(cancelErrors.single, ['BeforeAgentMiddlewareChild']);
  });

  test('TestWithCancel_RecursiveImmediate_MultiLevelMiddlewareChildrenAbortOnly', () async {
    final cModel = _ContextAwareBlockingModel(Message.assistant('c done'));
    final agentC = _agent(
      'MiddlewareChildC',
      cModel,
      description: 'direct middleware child C',
      instruction: 'child C',
    );

    final bCancelObserved = Completer<void>();
    final agentB = _agent(
      'MiddlewareChildB',
      _PlainModel('b done'),
      description: 'direct middleware child B',
      instruction: 'child B',
      handlers: [
        _BeforeChatModelHandler((ctx, _) {
          unawaited(ctx.cancelToken.whenCancelled.then((_) {
            if (!bCancelObserved.isCompleted) bCancelObserved.complete();
          }));
          return _runChildAgentToEnd(ctx, agentC, 'c work');
        }),
      ],
    );

    final outerAgent = _agent(
      'OuterMultiLevelMiddlewareAgent',
      _PlainModel('outer done'),
      description: 'outer',
      instruction: 'outer',
      handlers: [
        _BeforeChatModelHandler(
          (ctx, _) => _runChildAgentToEnd(ctx, agentB, 'b work'),
        ),
      ],
    );

    final (cancelOpt, cancelFn) = withCancel();
    final events = Runner(agent: outerAgent).run(
      ctx,
      [Message.user('go')],
      options: [cancelOpt],
    );

    await cModel.started.future;

    final handle = cancelFn(recursive: true);

    await bCancelObserved.future;
    await cModel.cancelObserved.future;

    expect(await handle.wait(), CancelOutcome.cancelled);
    final (_, cancelErrors) = await _drainCancelErrors(events);
    expect(cancelErrors, hasLength(1), reason: 'exactly one root CancelError');
    _expectExcludesAddresses(cancelErrors.single, ['MiddlewareChildB', 'MiddlewareChildC']);
  });

  test('TestWithCancel_NonRecursiveImmediate_DoesNotAbortMiddlewareChild', () async {
    final childModel = _ContextAwareBlockingModel(Message.assistant('child done'));
    final childAgent = _agent(
      'MiddlewareChild',
      childModel,
      description: 'direct middleware child',
      instruction: 'child',
    );

    final outerAgent = _agent(
      'OuterMiddlewareAgent',
      _PlainModel('outer done'),
      description: 'outer',
      instruction: 'outer',
      handlers: [
        _BeforeChatModelHandler(
          (ctx, _) => _runChildAgentToEnd(ctx, childAgent, 'child work'),
        ),
      ],
    );

    final (cancelOpt, cancelFn) = withCancel();
    final events = Runner(agent: outerAgent).run(
      ctx,
      [Message.user('go')],
      options: [cancelOpt],
    );

    await childModel.started.future;

    final handle = cancelFn();
    // Go: assertNotClosedWithin(cancelObserved, 100ms).
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(childModel.cancelObserved.isCompleted, isFalse);

    childModel.release.complete();

    expect(await handle.wait(), CancelOutcome.cancelled);
    final (_, cancelErrors) = await _drainCancelErrors(events);
    expect(cancelErrors, hasLength(1));
  });

  test('TestWithCancel_CancelImmediate_StreamableToolAborted', () async {
    final tcm = _ToolCallStreamModel();
    // The gate stays closed (Go closes it after the test).
    final gate = Completer<void>();
    final st = _SlowStreamingTool(
      'slow_tool',
      ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j'],
      gate: gate.future,
    );

    final agent = _agent('TestAgent', tcm, description: 'test', tools: [st]);
    final runner = Runner(agent: agent, enableStreaming: true);

    final (cancelOpt, cancelFn) = withCancel();
    final events = runner.run(ctx, [Message.user('hi')], options: [cancelOpt]);

    await st.started.future;

    var foundStreamCanceled = false;
    var foundCancelError = false;
    final toolStreamReady = Completer<void>();
    final drained = () async {
      for (var e = await events.nextOrNull(); e != null; e = await events.nextOrNull()) {
        final output = e.output?.messageOutput;
        if (output != null && output.isStreaming && output.role == RoleType.tool) {
          if (!toolStreamReady.isCompleted) toolStreamReady.complete();
          final stream = output.messageStream!;
          while (true) {
            try {
              await stream.recv();
            } on Object catch (error) {
              if (ThreepioException.findCause<StreamCanceledException>(error) != null) {
                foundStreamCanceled = true;
              }
              break;
            }
          }
        }
        if (e.action?.interrupted != null) foundCancelError = true;
        if (_cancelErrorOf(e) != null) foundCancelError = true;
      }
    }();

    await toolStreamReady.future;

    final outcome = await cancelFn().wait();
    await drained;

    if (outcome == CancelOutcome.executionEnded) {
      // Go: a valid race outcome on slow runtimes.
      markTestSkipped('cancel raced with completion (executionEnded)');
      return;
    }
    expect(outcome, CancelOutcome.cancelled);
    expect(foundStreamCanceled, isTrue, reason: "expected StreamCanceled on the tool's stream");
    expect(foundCancelError, isTrue, reason: 'expected CancelError in event stream');
  });

  test('TestWithCancel_CancelImmediate_RecursiveAgentTool_StreamableToolResume', () async {
    final gate = Completer<void>();
    final streamTool = _SlowStreamingTool('slow_tool', ['a', 'b', 'c'], gate: gate.future);

    final innerModel = _CountingModel([
      _toolCallMsg([_toolCall('inner-call', 'slow_tool', '{"input":"x"}')]),
      Message.assistant('inner done'),
    ]);
    final innerAgent = _agent(
      'InnerAgent',
      innerModel,
      description: 'inner agent',
      tools: [streamTool],
    );

    final outerModel = _CountingModel([
      _toolCallMsg([_toolCall('outer-call', 'InnerAgent', '{"request":"work"}')]),
      Message.assistant('outer done'),
    ]);
    final outerAgent = _agent(
      'OuterAgent',
      outerModel,
      description: 'outer agent',
      tools: [AgentTool(innerAgent)],
    );

    final store = InMemoryCheckpointStore();
    const checkpointId = 'recursive-agent-tool-streamable-tool';
    final runner = Runner(agent: outerAgent, enableStreaming: true, checkpointStore: store);
    final (cancelOpt, cancelFn) = withCancel();
    final events = runner.run(
      ctx,
      [Message.user('go')],
      options: [cancelOpt, AgentRunOption.checkpointId(checkpointId)],
    );

    final drained = _drainEvents(events);

    await streamTool.parked.future;

    final handle = cancelFn(recursive: true);
    expect(handle.contributed, isTrue);
    expect(await handle.wait(), CancelOutcome.cancelled);

    final (allEvents, hasCancelError) = await drained;
    expect(hasCancelError, isTrue);
    for (final event in allEvents) {
      expect(ThreepioException.findCause<StreamCanceledException>(event.error), isNull);
    }
    expect(await store.get(checkpointId), isNotNull);
    expect(innerModel.calls, 1);
    expect(outerModel.calls, 1);

    final resumeTool = _SlowStreamingTool('slow_tool', ['resumed tool result']);
    final resumeInnerModel = _CountingModel([Message.assistant('inner resumed')]);
    final resumeInnerAgent = _agent(
      'InnerAgent',
      resumeInnerModel,
      description: 'inner agent',
      tools: [resumeTool],
    );

    final resumeOuterModel = _CountingModel([Message.assistant('outer resumed')]);
    final resumeOuterAgent = _agent(
      'OuterAgent',
      resumeOuterModel,
      description: 'outer agent',
      tools: [AgentTool(resumeInnerAgent)],
    );

    final resumeRunner = Runner(
      agent: resumeOuterAgent,
      enableStreaming: true,
      checkpointStore: store,
    );
    final resumeEvents = await resumeRunner.resume(ctx, checkpointId);
    final (resumeAll, hasResumeCancelError) = await _drainEvents(resumeEvents);
    expect(hasResumeCancelError, isFalse);
    for (final event in resumeAll) {
      expect(event.error, isNull);
    }
    expect(resumeInnerModel.calls, 1);
    expect(resumeOuterModel.calls, 1);
    expect(
      resumeTool.started.isCompleted,
      isTrue,
      reason: 'resume did not rerun the interrupted inner streaming tool',
    );
  });

  test('TestWithCancel_CancelImmediate_RecursiveAgentTool_ResumeDeepestAgentTool', () async {
    final leafModel = _BlockingModel(Message.assistant('leaf done'));
    final leafAgent = _agent(
      'LeafAgent',
      leafModel,
      description: 'leaf agent that blocks',
      instruction: 'you are a leaf agent',
    );

    final middleModel = _CountingModel([
      _toolCallMsg([_toolCall('middle-leaf', 'LeafAgent', '{"request":"leaf work"}')]),
      Message.assistant('middle done'),
    ]);
    final middleAgent = _agent(
      'MiddleAgent',
      middleModel,
      description: 'middle agent with an agent tool',
      instruction: 'you are a middle agent',
      tools: [AgentTool(leafAgent)],
    );

    final outerModel = _CountingModel([
      _toolCallMsg([_toolCall('outer-middle', 'MiddleAgent', '{"request":"middle work"}')]),
      Message.assistant('outer done'),
    ]);
    final outerAgent = _agent(
      'OuterAgent',
      outerModel,
      description: 'outer agent with recursive agent tool nesting',
      instruction: 'you are an outer agent',
      tools: [AgentTool(middleAgent)],
    );

    final store = InMemoryCheckpointStore();
    const checkpointId = 'cancel-recursive-agent-tool-resume';
    final runner1 = Runner(agent: outerAgent, checkpointStore: store);

    final (cancelOpt, cancelFn) = withCancel();
    final events = runner1.run(
      ctx,
      [Message.user('go')],
      options: [cancelOpt, AgentRunOption.checkpointId(checkpointId)],
    );

    await leafModel.started.future;

    final handle = cancelFn(recursive: true);
    expect(await handle.wait(), CancelOutcome.cancelled);
    final (_, hasCancelError) = await _drainEvents(events);
    expect(hasCancelError, isTrue, reason: 'expected CancelError from recursive nested agent tool');

    final modelCalls = <String>[];
    final resumeLeafModel = _CountingModel(
      [Message.assistant('leaf done after resume')],
      callLog: modelCalls,
      label: 'leaf',
    );
    final resumeLeafAgent = _agent(
      'LeafAgent',
      resumeLeafModel,
      description: 'leaf agent that returns on resume',
      instruction: 'you are a leaf agent',
    );

    final resumeMiddleModel = _CountingModel(
      [Message.assistant('middle done after resume')],
      callLog: modelCalls,
      label: 'middle',
    );
    final resumeMiddleAgent = _agent(
      'MiddleAgent',
      resumeMiddleModel,
      description: 'middle agent with an agent tool',
      instruction: 'you are a middle agent',
      tools: [AgentTool(resumeLeafAgent)],
    );

    final resumeOuterModel = _CountingModel(
      [Message.assistant('outer done after resume')],
      callLog: modelCalls,
      label: 'outer',
    );
    final resumeOuterAgent = _agent(
      'OuterAgent',
      resumeOuterModel,
      description: 'outer agent with recursive agent tool nesting',
      instruction: 'you are an outer agent',
      tools: [AgentTool(resumeMiddleAgent)],
    );

    final runner2 = Runner(agent: resumeOuterAgent, checkpointStore: store);
    final resumeEvents = await runner2.resume(ctx, checkpointId);

    final (resumeAll, hasResumeCancelError) = await _drainEvents(resumeEvents);
    expect(modelCalls, isNotEmpty, reason: 'no model call observed during resume');
    expect(
      modelCalls.first,
      'leaf',
      reason: 'recursive AgentTool nesting should resume the deepest internal agent first',
    );
    expect(hasResumeCancelError, isFalse, reason: 'resume should complete without another CancelError');
    expect(resumeAll, isNotEmpty);
    expect(resumeLeafModel.calls, 1);
    expect(resumeMiddleModel.calls, 1);
    expect(resumeOuterModel.calls, 1);
  });

  test('TestWithCancel_CancelImmediate_ConcurrentAgentTools_ResumeWithoutRestart', () async {
    final innerAModel = _BlockingModel(Message.assistant('inner A done'));
    final innerBModel = _BlockingModel(Message.assistant('inner B done'));

    final innerAAgent = _agent(
      'InnerAgentA',
      innerAModel,
      description: 'inner agent A',
      instruction: 'you are inner agent A',
    );
    final innerBAgent = _agent(
      'InnerAgentB',
      innerBModel,
      description: 'inner agent B',
      instruction: 'you are inner agent B',
    );

    final outerModel = _CountingModel([
      _toolCallMsg([
        _toolCall('outer-a', 'InnerAgentA', '{"request":"work A"}'),
        _toolCall('outer-b', 'InnerAgentB', '{"request":"work B"}'),
      ]),
      Message.assistant('outer done'),
    ]);
    final outerAgent = _agent(
      'OuterAgent',
      outerModel,
      description: 'outer agent with concurrent agent tools',
      instruction: 'you are an outer agent',
      tools: [AgentTool(innerAAgent), AgentTool(innerBAgent)],
    );

    final store = InMemoryCheckpointStore();
    const checkpointId = 'cancel-concurrent-agent-tools-resume';
    final runner1 = Runner(agent: outerAgent, checkpointStore: store);

    final (cancelOpt, cancelFn) = withCancel();
    final events = runner1.run(
      ctx,
      [Message.user('go')],
      options: [cancelOpt, AgentRunOption.checkpointId(checkpointId)],
    );

    await innerAModel.started.future;
    await innerBModel.started.future;

    final handle = cancelFn(recursive: true);
    expect(await handle.wait(), CancelOutcome.cancelled);
    final (_, hasCancelError) = await _drainEvents(events);
    expect(hasCancelError, isTrue, reason: 'expected CancelError from concurrent agent tools');

    final modelCalls = <String>[];
    final resumeInnerAModel = _CountingModel(
      [Message.assistant('inner A done after resume')],
      callLog: modelCalls,
      label: 'innerA',
    );
    final resumeInnerBModel = _CountingModel(
      [Message.assistant('inner B done after resume')],
      callLog: modelCalls,
      label: 'innerB',
    );

    final resumeInnerAAgent = _agent(
      'InnerAgentA',
      resumeInnerAModel,
      description: 'inner agent A',
      instruction: 'you are inner agent A',
    );
    final resumeInnerBAgent = _agent(
      'InnerAgentB',
      resumeInnerBModel,
      description: 'inner agent B',
      instruction: 'you are inner agent B',
    );

    final resumeOuterModel = _CountingModel(
      [Message.assistant('outer done after resume')],
      callLog: modelCalls,
      label: 'outer',
    );
    final resumeOuterAgent = _agent(
      'OuterAgent',
      resumeOuterModel,
      description: 'outer agent with concurrent agent tools',
      instruction: 'you are an outer agent',
      tools: [AgentTool(resumeInnerAAgent), AgentTool(resumeInnerBAgent)],
    );

    final runner2 = Runner(agent: resumeOuterAgent, checkpointStore: store);
    final resumeEvents = await runner2.resume(ctx, checkpointId);

    final (resumeAll, hasResumeCancelError) = await _drainEvents(resumeEvents);
    expect(modelCalls, isNotEmpty, reason: 'no model call observed during resume');
    expect(
      ['innerA', 'innerB'],
      contains(modelCalls.first),
      reason: 'concurrent AgentTools should resume an internal agent before the outer model',
    );
    expect(hasResumeCancelError, isFalse, reason: 'resume should complete without another CancelError');
    expect(resumeAll, isNotEmpty);
    expect(resumeInnerAModel.calls, 1);
    expect(resumeInnerBModel.calls, 1);
    expect(resumeOuterModel.calls, 1);
  });
}
