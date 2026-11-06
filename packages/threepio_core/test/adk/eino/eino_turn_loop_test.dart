// Port of eino `adk/turn_loop_test.go` (v0.9.22), its helpers (lines 1–237)
// and its tests from TestTurnLoop_StopIsIdempotent (line 238) to
// TestTurnLoop_TurnContext_PreemptedChannel (line 3149). The tests from
// TestTurnLoop_CheckpointIDWithoutStore_FreshStart on are in
// `eino_turn_loop_2_test.dart`; the rest of the Go file (from
// TestPreemptController_BeginPushSnapshotsPlanningTurn) is ported elsewhere.
//
// Ported here: TestTurnLoop_StopIsIdempotent, _WaitMultipleGoroutines,
// _UnhandledItemsOnStop, _GenInputError, _GetAgentError, _BatchProcessing,
// _StopWithMode, _Preempt_CancelsCurrentAgent, _Preempt_DiscardsConsumedItems,
// _Preempt_WithAgentCancelMode, _PreemptAck_ClosesAfterCancelIsInitiated,
// _PreemptAck_ClosesImmediatelyIfLoopNotStarted,
// _Preempt_EscalatesOnSecondPreempt, _Preempt_JoinsSafePointModesOnSecondPreempt,
// _Push_WithoutPreempt_DoesNotCancel,
// _PreemptDelay_NoMispreemptOnNaturalCompletion,
// _PreemptDuringPlanningCancelsUpcomingAgent, _ConcurrentPush,
// _StopAfterReceive_RecoverItem, _StopAfterGenInput_RecoverConsumed,
// _GetAgentError_RecoverConsumed, _GenInputError_RecoverItems,
// _PrepareAgentError_RecoverItemsInOrder, _ContextCancel,
// _ContextDeadlineExceeded, _ContextCancelBeforeReceive,
// _ContextCancelDuringBlockingReceive, _ContextCancelAfterGenInput_RecoverItems,
// _OnAgentEventsReceivesEvents, _BareStop_AgentRunsToCompletion,
// _StopCheckPointIDInCancelError, _CancelError_CapturedIndependentlyOfCallback,
// _CancelError_CustomErrorWins_InterruptedItemsStillSet,
// _StopWithoutCheckpointIDDoesNotPersist, _StopWhileIdle_SkipsCheckpoint,
// _StopBetweenTurnsAndResume, _StopCancel_InterruptedItems_PersistAndRestore,
// _PreemptThenStop_InterruptedItems_ReflectsStoppedTurn,
// _BusinessInterrupt_PersistAndResume. Not ported: none (every Go test of
// the range is ported, in this file or the second one).
//
// Adaptations (Dart is single-threaded): goroutines become async calls,
// channels become Completers, `time.Sleep` of 20 ms–5 s becomes a Completer
// the test completes, a ≤ 20 ms timer, or a model call that never completes
// (an immediate cancel abandons it). Go's `<-cc.cancelChan` has no public
// listener in Dart: the mock agents poll `cc.shouldCancel` every millisecond.
@Timeout(Duration(seconds: 5))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/cancel.dart';
import 'package:threepio_core/src/adk/eino/run_options.dart';

// ---------------------------------------------------------------------------
// Helpers (Go lines 1–237, plus cancel_test.go's cancelTestChatModel).
// ---------------------------------------------------------------------------

typedef _RunFunc = Future<AgentOutput?> Function(RunContext ctx, AgentInput input);

/// Port of `turnLoopMockAgent`: sends [events], or the result of [runFunc].
final class _MockAgent implements Agent {
  _MockAgent({this.agentName = 'test', this.events = const [], this.runFunc});

  final String agentName;
  final List<AgentEvent> events;
  final _RunFunc? runFunc;

  @override
  String get name => agentName;

  @override
  String get description => 'mock agent';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(() async {
      try {
        final fn = runFunc;
        if (fn != null) {
          try {
            writer.send(AgentEvent(output: await fn(ctx, input)));
            // The Go runFunc returns its error; here it throws.
            // ignore: avoid_catches_without_on_clauses
          } catch (error, stackTrace) {
            writer.send(AgentEvent(error: error, stackTrace: stackTrace));
          }
          return;
        }
        for (final event in events) {
          writer.send(event);
        }
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }
}

/// Go's `<-cc.cancelChan`: completes with `true` once a cancel is asked for,
/// `false` when the run ended first (Go's goroutine would leak). Polled,
/// bounded to about 3 s.
Future<bool> _cancelRequested(CancelContext cc) async {
  for (var i = 0; i < 3000; i++) {
    if (cc.shouldCancel) return true;
    if (cc.isDone) return false;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return false;
}

/// Go's `require.Eventually`-style polling loops, bounded.
Future<void> _eventually(bool Function() condition, {int maxPolls = 500}) async {
  for (var i = 0; i < maxPolls && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// Port of `turnLoopCancellableMockAgent`: [runFunc] gets a context whose
/// token is cancelled when the run's cancel context asks for a cancel, after
/// [onCancel] saw it.
final class _CancellableAgent implements Agent {
  _CancellableAgent({required this.runFunc, this.onCancel});

  _RunFunc runFunc;
  final void Function(CancelContext cc)? onCancel;

  @override
  String get name => 'test';

  @override
  String get description => 'mock agent';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final cc = CommonAgentOptions.of(options).cancelContext;
    final own = CancelToken();
    final cancelCtx = ctx.withCancelToken(CancelToken.any([ctx.cancelToken, own])!);
    final (reader, writer) = pipe<AgentEvent>();
    if (cc != null) {
      unawaited(
        _cancelRequested(cc).then((requested) {
          if (!requested) return;
          // As in Go: onCancel before the context's cancel.
          onCancel?.call(cc);
          own.cancel('context canceled');
        }),
      );
    }
    final fn = runFunc;
    unawaited(() async {
      try {
        writer.send(AgentEvent(output: await fn(cancelCtx, input)));
        // The Go runFunc returns its error; here it throws.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        writer.send(AgentEvent(error: error, stackTrace: stackTrace));
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }
}

/// Port of `turnLoopInterruptAgent`.
final class _InterruptAgent implements Agent {
  _InterruptAgent(this.interruptInfo);

  final Object? interruptInfo;

  @override
  String get name => 'InterruptAgent';

  @override
  String get description => 'agent that interrupts';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      StreamReader.fromIterable([interruptEvent(ctx, interruptInfo)]);
}

/// A Go `chan struct{}` with a buffer: [send] never blocks (sends beyond the
/// buffer are kept, not dropped), [receive] takes the next one.
final class _Chan {
  int _buffered = 0;
  final List<Completer<void>> _waiters = [];

  void send() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _buffered++;
    }
  }

  Future<void> receive() {
    if (_buffered > 0) {
      _buffered--;
      return Future.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }
}

/// Port of cancel_test.go's `cancelTestChatModel`: signals [started], waits
/// [delay] and answers. A `null` delay (Go: 500 ms–5 s, longer than the
/// test) never completes; an immediate cancel abandons the call.
final class _SlowModel extends BaseChatModel {
  Duration? delay;
  final Message response = Message.assistant('Hello');
  final _Chan started = _Chan();
  final _Chan done = _Chan();

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    started.send();
    final wait = delay;
    if (wait == null) {
      await Completer<void>().future;
    } else {
      await Future<void>.delayed(wait);
    }
    done.send();
    return response;
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

ChatModelAgent _chatAgent(BaseChatModel model) => ChatModelAgent(
      ChatModelAgentConfig(
        name: 'TestAgent',
        description: 'Test agent',
        instruction: 'You are a test assistant',
        model: model,
      ),
    );

/// Port of `turnLoopCheckpointStore` (no `Delete`).
class _Store implements CheckpointStore {
  final Map<String, Uint8List> m = {};

  @override
  Future<Uint8List?> get(String key) async => m[key];

  @override
  Future<void> set(String key, Uint8List value) async => m[key] = value;
}

/// Port of `deletableCheckpointStore`.
final class _DeletableStore extends _Store implements CheckpointDeleter {
  bool deleteCalled = false;
  String deletedKey = '';

  @override
  Future<void> delete(String key) async {
    deleteCalled = true;
    deletedKey = key;
    m.remove(key);
  }
}

/// Go's `errors.Is`: [error] is [target] or wraps it.
bool _errorIs(Object? error, Object target) {
  Object? current = error;
  for (var depth = 0; current != null && depth < 64; depth++) {
    if (identical(current, target)) return true;
    current = current is ThreepioException ? current.cause : null;
  }
  return false;
}

Matcher _isError(Object target) =>
    predicate<Object?>((error) => _errorIs(error, target), 'is or wraps $target');

/// `errors.As(err, &cancelErr)` for `*CancelError`.
final Matcher _isCancelError = predicate<Object?>(
  (error) => ThreepioException.findCause<AgentRunCancelledException>(error) != null,
  'is or wraps an AgentRunCancelledException',
);

/// `errors.As(err, &intErr)` for `*InterruptError`.
final Matcher _isInterruptError = predicate<Object?>(
  (error) => ThreepioException.findCause<TurnLoopInterruptedException>(error) != null,
  'is or wraps a TurnLoopInterruptedException',
);

/// `errors.Is(err, context.Canceled)` (and `context.DeadlineExceeded`).
final Matcher _isContextCancel = predicate<Object?>(
  (error) => ThreepioException.findCause<CancelledException>(error) != null,
  'is or wraps a CancelledException',
);

/// Port of `newAndRunTurnLoop`.
TurnLoop<String> _newAndRun(TurnLoopConfig<String> config, [RunContext? ctx]) =>
    TurnLoop<String>(config)..run(ctx ?? RunContext.background());

/// Port of `genInputConsumeAll`.
Future<GenInputResult<String>> _consumeAll(
  RunContext ctx,
  TurnLoop<String> loop,
  List<String> items,
) async =>
    GenInputResult(input: AgentInput(), consumed: items);

/// Port of `genInputConsumeAllWithMsg`.
Future<GenInputResult<String>> _consumeAllWithMsg(
  RunContext ctx,
  TurnLoop<String> loop,
  List<String> items,
) async =>
    GenInputResult(
      input: AgentInput(messages: [Message.user(items[0])]),
      consumed: items,
    );

/// Port of `genInputConsumeFirst`.
Future<GenInputResult<String>> _consumeFirst(
  RunContext ctx,
  TurnLoop<String> loop,
  List<String> items,
) async =>
    GenInputResult(
      input: AgentInput(messages: [Message.user(items[0])]),
      consumed: [items[0]],
      remaining: items.sublist(1),
    );

/// Port of `prepareTestAgent`.
Future<Agent> _prepareTestAgent(
  RunContext ctx,
  TurnLoop<String> loop,
  List<String> consumed,
) async =>
    _MockAgent();

/// Port of `prepareAgent`.
Future<Agent> Function(RunContext, TurnLoop<String>, List<String>) _prepare(
  Agent agent,
) =>
    (ctx, loop, consumed) async => agent;

/// An `OnAgentEvents` that drains the events and stops the loop.
Future<void> _drainAndStop(
  RunContext ctx,
  TurnContext<String> tc,
  StreamReader<AgentEvent> events,
) async {
  await _drain(events);
  tc.loop.stop();
}

Future<void> _drain(StreamReader<AgentEvent> events) async {
  while (await events.nextOrNull() != null) {}
}

/// Go's `close(ch)` guarded by a `sync.Once`.
void _close(Completer<void> completer) {
  if (!completer.isCompleted) completer.complete();
}

/// A future's completion as a flag (Go's non-blocking `select` on a channel).
bool Function() _completionOf(Future<void> future) {
  var completed = false;
  unawaited(future.then((_) => completed = true));
  return () => completed;
}

/// Port of `newPreemptTestLoop`.
Future<TurnLoop<String>> _newPreemptTestLoop(_CancellableAgent agent) async {
  final agentStarted = Completer<void>();
  final original = agent.runFunc;
  agent.runFunc = (ctx, input) {
    _close(agentStarted);
    return original(ctx, input);
  };
  final loop = _newAndRun(
    TurnLoopConfig(prepareAgent: _prepare(agent), genInput: _consumeFirst),
  );
  loop.push('first');
  await agentStarted.future;
  return loop;
}

/// The first loop of the resume tests: a ChatModelAgent on a model that never
/// answers, cancelled at once while the model runs, with a checkpoint.
Future<TurnLoopExitState<String>> _cancelledRun(
  CheckpointStore store,
  String checkpointId,
  Agent agent,
  _SlowModel model, {
  String item = 'msg1',
}) async {
  final loop = _newAndRun(
    TurnLoopConfig(
      store: store,
      checkpointId: checkpointId,
      genInput: _consumeAllWithMsg,
      prepareAgent: _prepare(agent),
    ),
  );
  loop.push(item);
  await model.started.receive();
  loop.stop(options: [const StopOption.immediate()]);
  return loop.wait();
}

void main() {
  test('TestTurnLoop_StopIsIdempotent', () async {
    final loop = _newAndRun(
      const TurnLoopConfig(genInput: _consumeAll, prepareAgent: _prepareTestAgent),
    );
    loop
      ..stop()
      ..stop()
      ..stop();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
  });

  test('TestTurnLoop_WaitMultipleGoroutines', () async {
    final loop = _newAndRun(
      const TurnLoopConfig(genInput: _consumeAll, prepareAgent: _prepareTestAgent),
    )..stop();
    final results = await Future.wait([loop.wait(), loop.wait(), loop.wait()]);
    expect(results[0], same(results[1]));
    expect(results[1], same(results[2]));
  });

  test('TestTurnLoop_UnhandledItemsOnStop', () async {
    final started = Completer<void>();
    final blocked = Completer<void>();
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          started.complete();
          await blocked.future;
          return GenInputResult(
            input: AgentInput(),
            consumed: items.sublist(0, 1),
            remaining: items.sublist(1),
          );
        },
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop
      ..push('msg1')
      ..push('msg2')
      ..push('msg3');
    await started.future;
    loop.stop();
    blocked.complete();
    final result = await loop.wait();
    expect(result.unhandledItems, isNotEmpty, reason: 'should return unhandled items');
  });

  test('TestTurnLoop_GenInputError', () async {
    final genErr = Exception('gen input error');
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async => throw genErr,
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop.push('msg1');
    final result = await loop.wait();
    expect(result.exitReason, _isError(genErr));
  });

  test('TestTurnLoop_GetAgentError', () async {
    final agentErr = Exception('get agent error');
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: _consumeAll,
        prepareAgent: (ctx, loop, consumed) async => throw agentErr,
      ),
    );
    loop.push('msg1');
    final result = await loop.wait();
    expect(result.exitReason, _isError(agentErr));
  });

  test('TestTurnLoop_BatchProcessing', () async {
    final batches = <List<String>>[];
    final thirdBatch = Completer<void>();
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          batches.add(List.of(items));
          if (batches.length == 3) thirdBatch.complete();
          return GenInputResult(
            input: AgentInput(),
            consumed: items.sublist(0, 1),
            remaining: items.sublist(1),
          );
        },
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop
      ..push('msg1')
      ..push('msg2')
      ..push('msg3');
    // Go sleeps 200 ms for the turns to run; one turn per item.
    await thirdBatch.future;
    loop.stop();
    await loop.wait();
    expect(batches, isNotEmpty, reason: 'should have processed at least one batch');
  });

  test('TestTurnLoop_StopWithMode', () async {
    final loop = _newAndRun(
      const TurnLoopConfig(genInput: _consumeAll, prepareAgent: _prepareTestAgent),
    )..stop(options: [const StopOption.graceful()]);
    final result = await loop.wait();
    expect(result.exitReason, isNull);
  });

  test('TestTurnLoop_Preempt_CancelsCurrentAgent', () async {
    final agentStarted = Completer<void>();
    final agentCancelled = Completer<void>();
    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        _close(agentStarted);
        await ctx.cancelToken.whenCancelled;
        _close(agentCancelled);
        return const AgentOutput();
      },
    );
    var genInputCalls = 0;
    final secondGenInputCalled = Completer<void>();
    final loop = _newAndRun(
      TurnLoopConfig(
        prepareAgent: _prepare(agent),
        genInput: (ctx, loop, items) async {
          if (++genInputCalls >= 2) _close(secondGenInputCalled);
          return GenInputResult(
            input: AgentInput(messages: [Message.user(items[0])]),
            consumed: [items[0]],
            remaining: items.sublist(1),
          );
        },
      ),
    );
    loop.push('first');
    await agentStarted.future;
    loop.push(
      'urgent',
      options: [
        PushOption.preempt({CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls}),
      ],
    );
    await agentCancelled.future;
    await secondGenInputCalled.future;
    loop.stop(options: [const StopOption.immediate()]);
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(genInputCalls, greaterThanOrEqualTo(2));
  });

  test('TestTurnLoop_Preempt_DiscardsConsumedItems', () async {
    final agentStarted = Completer<void>();
    final agentDone = Completer<void>();
    var firstAgentRun = true;
    final genInputResults = <List<String>>[];
    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        final isFirst = firstAgentRun;
        firstAgentRun = false;
        if (isFirst) {
          _close(agentStarted);
          await ctx.cancelToken.whenCancelled;
        } else {
          _close(agentDone);
        }
        return const AgentOutput();
      },
    );
    final loop = _newAndRun(
      TurnLoopConfig(
        prepareAgent: _prepare(agent),
        genInput: (ctx, loop, items) async {
          genInputResults.add(List.of(items));
          return GenInputResult(
            input: AgentInput(messages: [Message.user(items[0])]),
            consumed: [items[0]],
            remaining: items.sublist(1),
          );
        },
      ),
    );
    loop.push('first');
    await agentStarted.future;
    loop.push(
      'urgent',
      options: [
        PushOption.preempt({CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls}),
      ],
    );
    await agentDone.future;
    loop.stop();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(genInputResults.length, greaterThanOrEqualTo(2));
    expect(genInputResults[1], isNot(contains('first')));
    expect(genInputResults[1], contains('urgent'));
  });

  test('TestTurnLoop_Preempt_WithAgentCancelMode', () async {
    final cancelFuncCalled = Completer<void>();
    Set<CancelSafePoint> firstCancelModeUsed = const {};
    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        await ctx.cancelToken.whenCancelled;
        return const AgentOutput();
      },
      onCancel: (cc) {
        if (cancelFuncCalled.isCompleted) return;
        firstCancelModeUsed = cc.mode;
        cancelFuncCalled.complete();
      },
    );
    final loop = await _newPreemptTestLoop(agent);
    loop.push(
      'urgent',
      options: [PushOption.preempt({CancelSafePoint.afterToolCalls})],
    );
    await cancelFuncCalled.future;
    loop.stop(options: [const StopOption.immediate()]);
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(firstCancelModeUsed, {CancelSafePoint.afterToolCalls});
  });

  test('TestTurnLoop_PreemptAck_ClosesAfterCancelIsInitiated', () async {
    final cancelObserved = Completer<void>();
    final agentFinishGate = Completer<void>();
    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        await ctx.cancelToken.whenCancelled;
        await agentFinishGate.future;
        return const AgentOutput();
      },
      onCancel: (cc) => _close(cancelObserved),
    );
    final loop = await _newPreemptTestLoop(agent);
    final pushed = loop.push(
      'urgent',
      options: [PushOption.preempt({CancelSafePoint.afterToolCalls})],
    );
    expect(pushed.accepted, isTrue);
    await pushed.resolved;
    await cancelObserved.future;
    agentFinishGate.complete();
    loop.stop(options: [const StopOption.immediate()]);
    final result = await loop.wait();
    expect(result.exitReason, isNull);
  });

  test('TestTurnLoop_PreemptAck_ClosesImmediatelyIfLoopNotStarted', () async {
    final loop = TurnLoop<String>(
      const TurnLoopConfig(genInput: _consumeAll, prepareAgent: _prepareTestAgent),
    );
    final pushed = loop.push(
      'urgent',
      options: [
        PushOption.preempt({CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls}),
      ],
    );
    expect(pushed.accepted, isTrue);
    await pushed.resolved;
  });

  test('TestTurnLoop_Preempt_EscalatesOnSecondPreempt', () async {
    final firstCancelSeen = Completer<void>();
    final agentFinishGate = Completer<void>();
    CancelContext? ccPtr;
    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        await ctx.cancelToken.whenCancelled;
        await agentFinishGate.future;
        return const AgentOutput();
      },
      onCancel: (cc) {
        ccPtr = cc;
        _close(firstCancelSeen);
      },
    );
    final loop = await _newPreemptTestLoop(agent);
    loop.push(
      'urgent1',
      options: [PushOption.preempt({CancelSafePoint.afterChatModel})],
    );
    await firstCancelSeen.future;
    loop.push(
      'urgent2',
      options: [
        PushOption.preemptTimeout(
          {CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls},
          const Duration(milliseconds: 1),
        ),
      ],
    );
    const wantMode = {CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls};
    await _eventually(() {
      final cc = ccPtr;
      return cc != null && cc.mode.containsAll(wantMode) && cc.mode.length == 2 && cc.isEscalated;
    });
    final cc = ccPtr;
    expect(cc, isNotNull, reason: 'cancel context was not captured');
    expect(cc!.mode, wantMode);
    expect(cc.isEscalated, isTrue);
    agentFinishGate.complete();
    loop.stop(options: [const StopOption.immediate()]);
    final result = await loop.wait();
    expect(result.exitReason, isNull);
  });

  test('TestTurnLoop_Preempt_JoinsSafePointModesOnSecondPreempt', () async {
    final firstCancelSeen = Completer<void>();
    final agentFinishGate = Completer<void>();
    CancelContext? ccPtr;
    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        await ctx.cancelToken.whenCancelled;
        await agentFinishGate.future;
        return const AgentOutput();
      },
      onCancel: (cc) {
        ccPtr = cc;
        _close(firstCancelSeen);
      },
    );
    final loop = await _newPreemptTestLoop(agent);
    loop.push(
      'urgent1',
      options: [PushOption.preempt({CancelSafePoint.afterChatModel})],
    );
    await firstCancelSeen.future;
    loop.push(
      'urgent2',
      options: [PushOption.preempt({CancelSafePoint.afterToolCalls})],
    );
    const want = {CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls};
    await _eventually(() {
      final cc = ccPtr;
      return cc != null && cc.mode.containsAll(want) && cc.mode.length == 2;
    });
    final cc = ccPtr;
    expect(cc, isNotNull, reason: 'cancel context was not captured');
    expect(cc!.mode, want);
    agentFinishGate.complete();
    loop.stop(options: [const StopOption.immediate()]);
    final result = await loop.wait();
    expect(result.exitReason, isNull);
  });

  test('TestTurnLoop_Push_WithoutPreempt_DoesNotCancel', () async {
    var agentRunCount = 0;
    final agentDone = Completer<void>();
    final firstStarted = Completer<void>();
    final firstWork = Completer<void>();
    final agent = _MockAgent(
      runFunc: (ctx, input) async {
        agentRunCount++;
        if (agentRunCount == 1) {
          // Go sleeps 100 ms; the test releases the first run.
          firstStarted.complete();
          await firstWork.future;
        }
        if (agentRunCount == 2) agentDone.complete();
        return const AgentOutput();
      },
    );
    final loop = _newAndRun(
      TurnLoopConfig(prepareAgent: _prepare(agent), genInput: _consumeFirst),
    );
    loop.push('first');
    await firstStarted.future;
    loop.push('second');
    firstWork.complete();
    await agentDone.future;
    loop.stop();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(agentRunCount, 2);
  });

  test('TestTurnLoop_PreemptDelay_NoMispreemptOnNaturalCompletion', () async {
    final agent1Started = Completer<void>();
    final allowAgent1Done = Completer<void>();
    final agent1Done = Completer<void>();
    final agent2Started = Completer<void>();
    final allowAgent2Done = Completer<void>();
    final agent2Done = Completer<void>();
    var agentRunCount = 0;
    var agent2Cancelled = false;
    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        switch (++agentRunCount) {
          case 1:
            _close(agent1Started);
            await allowAgent1Done.future;
            _close(agent1Done);
          case 2:
            _close(agent2Started);
            await Future.any([allowAgent2Done.future, ctx.cancelToken.whenCancelled]);
            if (ctx.cancelToken.isCancelled) {
              agent2Cancelled = true; // Go: t.Error("Agent2 was unexpectedly cancelled")
              throw CancelledException(ctx.cancelToken.reason);
            }
            _close(agent2Done);
        }
        return const AgentOutput();
      },
    );
    final loop = _newAndRun(
      TurnLoopConfig(prepareAgent: _prepare(agent), genInput: _consumeFirst),
    );
    loop.push('first');
    await agent1Started.future;
    // Go delays the preempt by 500 ms; 20 ms is still long after the first
    // agent's natural end.
    final pushed = loop.push(
      'second',
      options: [
        PushOption.preempt({CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls}),
        PushOption.preemptDelay(const Duration(milliseconds: 20)),
      ],
    );
    allowAgent1Done.complete();
    await agent1Done.future;
    await agent2Started.future;
    await pushed.resolved;
    allowAgent2Done.complete();
    await agent2Done.future;
    loop.stop();
    final result = await loop.wait();
    expect(agent2Cancelled, isFalse, reason: 'Agent2 was unexpectedly cancelled');
    expect(result.exitReason, isNull);
    expect(agentRunCount, 2);
  });

  test('TestTurnLoop_PreemptDuringPlanningCancelsUpcomingAgent', () async {
    final genInputEntered = Completer<void>();
    final allowGenInput = Completer<void>();
    final cancelSubmitted = Completer<void>();
    final agentCancelled = Completer<void>();
    var agentRunCount = 0;
    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        if (++agentRunCount == 1) {
          await ctx.cancelToken.whenCancelled;
          _close(agentCancelled);
        }
        return const AgentOutput();
      },
      onCancel: (cc) => _close(cancelSubmitted),
    );
    var genInputOnce = false;
    final loop = _newAndRun(
      TurnLoopConfig(
        prepareAgent: _prepare(agent),
        genInput: (ctx, loop, items) async {
          if (!genInputOnce) {
            genInputOnce = true;
            genInputEntered.complete();
            await allowGenInput.future;
          }
          return GenInputResult(
            input: AgentInput(messages: [Message.user(items[0])]),
            consumed: [items[0]],
            remaining: items.sublist(1),
          );
        },
      ),
    );
    loop.push('first');
    await genInputEntered.future;
    final pushed = loop.push(
      'urgent',
      options: [
        PushOption.preempt({CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls}),
      ],
    );
    expect(pushed.accepted, isTrue);
    final acked = _completionOf(pushed.resolved!);
    await Future<void>.delayed(Duration.zero);
    expect(acked(), isFalse, reason: 'ack should still be open');
    allowGenInput.complete();
    await cancelSubmitted.future;
    await pushed.resolved;
    await agentCancelled.future;
    loop.stop();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(agentRunCount, greaterThanOrEqualTo(1));
  });

  test('TestTurnLoop_ConcurrentPush', () async {
    var count = 0;
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          count += items.length;
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        prepareAgent: _prepareTestAgent,
      ),
    );
    // Ten interleaved pushers of ten items each (Go: ten goroutines).
    await Future.wait([
      for (var i = 0; i < 10; i++)
        () async {
          for (var j = 0; j < 10; j++) {
            loop.push('msg-$i-$j');
            await Future<void>.delayed(Duration.zero);
          }
        }(),
    ]);
    // Go sleeps 200 ms for the loop to handle the items.
    await _eventually(() => count >= 100, maxPolls: 50);
    loop.stop();
    final result = await loop.wait();
    final processed = count;
    final unhandled = result.unhandledItems.length;
    expect(processed, greaterThan(0), reason: 'should have processed some items');
    expect(processed + unhandled, lessThanOrEqualTo(100),
        reason: 'total should not exceed pushed amount');
  });

  test('TestTurnLoop_StopAfterReceive_RecoverItem', () async {
    final receiveStarted = Completer<void>();
    final cancelDone = Completer<void>();
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          receiveStarted.complete();
          await cancelDone.future;
          await Future<void>.delayed(const Duration(milliseconds: 10)); // Go: 50 ms
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop.push('msg1');
    await receiveStarted.future;
    loop.stop();
    cancelDone.complete();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
  });

  test('TestTurnLoop_StopAfterGenInput_RecoverConsumed', () async {
    final genInputDone = Completer<void>();
    final prepareEntered = Completer<void>();
    final prepareGate = Completer<void>();
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          genInputDone.complete();
          return GenInputResult(
            input: AgentInput(),
            consumed: items.sublist(0, 1),
            remaining: items.sublist(1),
          );
        },
        // Go sleeps 100 ms here and stops the loop 60 ms after genInput
        // (which sleeps 50 ms): the stop lands while prepareAgent runs.
        prepareAgent: (ctx, loop, consumed) async {
          prepareEntered.complete();
          await prepareGate.future;
          return _MockAgent();
        },
      ),
    );
    loop
      ..push('msg1')
      ..push('msg2');
    await genInputDone.future;
    await prepareEntered.future;
    loop.stop();
    prepareGate.complete();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
  });

  test('TestTurnLoop_GetAgentError_RecoverConsumed', () async {
    final agentErr = Exception('get agent error');
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async => GenInputResult(
          input: AgentInput(),
          consumed: items.sublist(0, 1),
          remaining: items.sublist(1),
        ),
        prepareAgent: (ctx, loop, consumed) async => throw agentErr,
      ),
    );
    loop
      ..push('msg1')
      ..push('msg2');
    final result = await loop.wait();
    expect(result.exitReason, _isError(agentErr));
    expect(result.unhandledItems, isNotEmpty,
        reason: 'should recover at least the consumed item and remaining');
  });

  test('TestTurnLoop_GenInputError_RecoverItems', () async {
    final genErr = Exception('gen input error');
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async => throw genErr,
        prepareAgent: _prepareTestAgent,
      ),
    );
    expect(loop.push('msg1').accepted, isTrue);
    expect(loop.push('msg2').accepted, isTrue);
    loop.run(RunContext.background());
    final result = await loop.wait();
    expect(result.exitReason, _isError(genErr));
    expect(result.unhandledItems, hasLength(2),
        reason: 'should recover all items when GenInput fails');
    expect(result.unhandledItems, contains('msg1'));
    expect(result.unhandledItems, contains('msg2'));
  });

  test('TestTurnLoop_PrepareAgentError_RecoverItemsInOrder', () async {
    final agentErr = Exception('prepare agent error');
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          String? urgent;
          final remaining = <String>[];
          for (final item in items) {
            if (item == 'urgent') {
              urgent = item;
            } else {
              remaining.add(item);
            }
          }
          if (urgent != null) {
            return GenInputResult(
              input: AgentInput(),
              consumed: [urgent],
              remaining: remaining,
            );
          }
          return GenInputResult(
            input: AgentInput(),
            consumed: items.sublist(0, 1),
            remaining: items.sublist(1),
          );
        },
        prepareAgent: (ctx, loop, consumed) async => throw agentErr,
      ),
    );
    loop
      ..push('msg1')
      ..push('urgent')
      ..push('msg2');
    final result = await loop.wait();
    expect(result.exitReason, _isError(agentErr));
    expect(result.unhandledItems, hasLength(3), reason: 'should recover all items');
    expect(result.unhandledItems, ['msg1', 'urgent', 'msg2'],
        reason: 'should preserve original push order even when GenInput selects '
            'non-prefix items');
  });

  // Context cancel tests: the TurnLoop closes its buffer when the context is
  // cancelled, which ends a blocking receive; the loop then exits with a
  // CancelledException (Go: the context error).

  test('TestTurnLoop_ContextCancel', () async {
    final token = CancelToken();
    final genInputStarted = Completer<void>();
    final genInputDone = Completer<void>();
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          genInputStarted.complete();
          await genInputDone.future;
          ctx.cancelToken.throwIfCancelled();
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        prepareAgent: _prepareTestAgent,
      ),
      RunContext.background(cancelToken: token),
    );
    loop.push('msg1');
    await genInputStarted.future;
    token.cancel();
    genInputDone.complete();
    final result = await loop.wait();
    expect(result.exitReason, _isContextCancel);
  });

  test('TestTurnLoop_ContextDeadlineExceeded', () async {
    // Go: a 50 ms deadline against a 100 ms genInput. Dart has no deadline
    // error: a token cancelled by a 5 ms timer, against 20 ms, and the exit
    // reason is a CancelledException.
    final token = CancelToken();
    final deadline = Timer(const Duration(milliseconds: 5), token.cancel);
    addTearDown(deadline.cancel);
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          await Future.any([
            Future<void>.delayed(const Duration(milliseconds: 20)),
            ctx.cancelToken.whenCancelled,
          ]);
          ctx.cancelToken.throwIfCancelled();
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        prepareAgent: _prepareTestAgent,
      ),
      RunContext.background(cancelToken: token),
    );
    loop.push('msg1');
    final result = await loop.wait();
    expect(result.exitReason, _isContextCancel);
  });

  test('TestTurnLoop_ContextCancelBeforeReceive', () async {
    final token = CancelToken()..cancel();
    final loop = TurnLoop<String>(
      const TurnLoopConfig(genInput: _consumeAll, prepareAgent: _prepareTestAgent),
    );
    // Pushed before run, so that the item is buffered before the context
    // watcher closes the buffer.
    loop
      ..push('msg1')
      ..run(RunContext.background(cancelToken: token));
    final result = await loop.wait();
    expect(result.exitReason, _isContextCancel);
    expect(result.unhandledItems, hasLength(1));
  });

  test('TestTurnLoop_ContextCancelDuringBlockingReceive', () async {
    final token = CancelToken();
    final loop = _newAndRun(
      const TurnLoopConfig(genInput: _consumeAll, prepareAgent: _prepareTestAgent),
      RunContext.background(cancelToken: token),
    );
    // No item: the receive blocks (Go sleeps 50 ms).
    await pumpEventQueue();
    token.cancel();
    final result = await loop.wait();
    expect(result.exitReason, _isContextCancel);
  });

  test('TestTurnLoop_ContextCancelAfterGenInput_RecoverItems', () async {
    final token = CancelToken();
    var genInputCount = 0;
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          if (++genInputCount == 1) token.cancel();
          return GenInputResult(
            input: AgentInput(),
            consumed: items.sublist(0, 1),
            remaining: items.sublist(1),
          );
        },
        prepareAgent: (ctx, loop, consumed) async {
          ctx.cancelToken.throwIfCancelled();
          return _MockAgent();
        },
      ),
      RunContext.background(cancelToken: token),
    );
    loop
      ..push('msg1')
      ..push('msg2');
    final result = await loop.wait();
    expect(result.exitReason, _isContextCancel);
    expect(result.unhandledItems, isNotEmpty,
        reason: 'should recover consumed and remaining items');
  });

  test('TestTurnLoop_OnAgentEventsReceivesEvents', () async {
    final receivedEvents = <AgentEvent>[];
    final receivedConsumed = <String>[];
    final handled = Completer<void>();
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: _consumeAllWithMsg,
        prepareAgent: _prepareTestAgent,
        onAgentEvents: (ctx, tc, events) async {
          receivedConsumed.addAll(tc.consumed);
          for (var event = await events.nextOrNull();
              event != null;
              event = await events.nextOrNull()) {
            receivedEvents.add(event);
          }
          _close(handled);
        },
      ),
    );
    loop.push('msg1');
    await handled.future; // Go sleeps 100 ms.
    loop.stop();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(receivedConsumed, isNotEmpty, reason: 'should have received consumed items');
  });

  // The core contract of a bare stop: the running agent finishes with a
  // context that is not cancelled, the loop exits cleanly, and no new turn
  // starts even with items buffered.
  test('TestTurnLoop_BareStop_AgentRunsToCompletion', () async {
    final agentStarted = Completer<void>();
    final agentWork = Completer<void>();
    bool? agentCtxCancelled;
    String? agentOutput;
    var turnsExecuted = 0;
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: _consumeFirst,
        prepareAgent: (ctx, loop, consumed) async => _MockAgent(
          agentName: 'worker',
          runFunc: (ctx, input) async {
            turnsExecuted++;
            agentStarted.complete();
            // Go simulates 200 ms of work (not waiting for a cancel); the
            // test ends the work after its stop.
            await agentWork.future;
            agentCtxCancelled = ctx.cancelToken.isCancelled;
            agentOutput = 'work-done';
            return const AgentOutput();
          },
        ),
      ),
    );
    loop
      ..push('task1')
      ..push('task2');
    await agentStarted.future;
    loop.stop();
    agentWork.complete();
    final result = await loop.wait();
    expect(agentCtxCancelled, isNotNull, reason: 'agent never reported context state');
    expect(agentCtxCancelled, isFalse, reason: "bare Stop must not cancel the agent's context");
    expect(agentOutput, 'work-done');
    expect(result.exitReason, isNull);
    expect(result.interruptedItems, isEmpty);
    expect(turnsExecuted, 1,
        reason: 'bare Stop must prevent new turns from starting after the current one completes');
    expect(result.unhandledItems, ['task2'],
        reason: 'the second item should appear in UnhandledItems');
  });

  test('TestTurnLoop_StopCheckPointIDInCancelError', () async {
    const checkpointId = 'turn-loop-cancel-ckpt-1';
    final store = _Store();
    final slowModel = _SlowModel();
    final result = await _cancelledRun(store, checkpointId, _chatAgent(slowModel), slowModel);
    expect(result.exitReason, _isCancelError, reason: 'ExitReason should be a *CancelError');
    expect(store.m.containsKey(checkpointId), isTrue,
        reason: 'checkpoint should be saved under the configured CheckpointID');
  });

  // The loop reports the cancel as the exit reason and fills the interrupted
  // items even when the callback swallows the cancel error.
  test('TestTurnLoop_CancelError_CapturedIndependentlyOfCallback', () async {
    const checkpointId = 'cancel-capture-independent-1';
    final store = _Store();
    final slowModel = _SlowModel();
    final loop = _newAndRun(
      TurnLoopConfig(
        store: store,
        checkpointId: checkpointId,
        genInput: _consumeAllWithMsg,
        prepareAgent: _prepare(_chatAgent(slowModel)),
        // Swallows every error, the cancel included.
        onAgentEvents: (ctx, tc, events) => _drain(events),
      ),
    );
    loop.push('msg1');
    await slowModel.started.receive();
    loop.stop(options: [const StopOption.immediate()]);
    final result = await loop.wait();
    expect(result.exitReason, _isCancelError,
        reason: 'ExitReason should be *CancelError even when OnAgentEvents swallows it');
    expect(result.interruptedItems, ['msg1'],
        reason: 'InterruptedItems should contain the items that were being processed');
    expect(store.m.containsKey(checkpointId), isTrue,
        reason: 'checkpoint should be saved under the configured CheckpointID');
  });

  // A custom error of the callback during a cancel is the exit reason, and
  // the interrupted items are still set: they were in flight.
  test('TestTurnLoop_CancelError_CustomErrorWins_InterruptedItemsStillSet', () async {
    const checkpointId = 'cancel-custom-error-wins-1';
    final store = _Store();
    final customErr = Exception('user callback encountered a problem');
    final slowModel = _SlowModel();
    final loop = _newAndRun(
      TurnLoopConfig(
        store: store,
        checkpointId: checkpointId,
        genInput: _consumeAllWithMsg,
        prepareAgent: _prepare(_chatAgent(slowModel)),
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          throw customErr;
        },
      ),
    );
    loop.push('msg1');
    await slowModel.started.receive();
    loop.stop(options: [const StopOption.immediate()]);
    final result = await loop.wait();
    expect(result.exitReason, _isError(customErr),
        reason: "ExitReason should be the user's custom error, not CancelError");
    expect(result.interruptedItems, ['msg1'],
        reason: 'InterruptedItems should contain the items that were being processed');
    expect(store.m.containsKey(checkpointId), isTrue,
        reason: 'checkpoint should be saved even when user returns custom error');
  });

  test('TestTurnLoop_StopWithoutCheckpointIDDoesNotPersist', () async {
    final store = _Store();
    final slowModel = _SlowModel();
    final result = await _cancelledRun(store, '', _chatAgent(slowModel), slowModel);
    expect(result.exitReason, _isCancelError, reason: 'ExitReason should be a *CancelError');
    expect(store.m, isEmpty,
        reason: 'no checkpoint should be saved when CheckpointID is not configured');
  });

  test('TestTurnLoop_StopWhileIdle_SkipsCheckpoint', () async {
    final store = _DeletableStore();
    const cpId = 'idle-session';
    final loop = _newAndRun(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    )..stop();
    final exit = await loop.wait();
    expect(exit.exitReason, isNull);
    expect(store.m.containsKey(cpId), isFalse,
        reason: 'no checkpoint should be saved when TurnLoop is idle');
  });

  test('TestTurnLoop_StopBetweenTurnsAndResume', () async {
    final store = _Store();
    const cpId = 'between-turns-session';
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop
      ..push('a')
      ..push('b')
      ..stop()
      ..run(RunContext.background());
    final exit = await loop.wait();
    expect(exit.exitReason, isNull);

    List<String>? seen;
    final loop2 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: (ctx, loop, items) async {
          seen = List.of(items);
          return GenInputResult(
            input: AgentInput(messages: [Message.user(items[0])]),
            consumed: items,
          );
        },
        prepareAgent: _prepareTestAgent,
        onAgentEvents: _drainAndStop,
      ),
    );
    loop2
      ..push('c')
      ..run(RunContext.background());
    final exit2 = await loop2.wait();
    expect(exit2.exitReason, isNull);
    expect(seen, ['a', 'b', 'c']);
  });

  // A stop with an immediate cancel reports the interrupted items, persists
  // them, and a new loop restored from the checkpoint passes them to
  // genResume.
  test('TestTurnLoop_StopCancel_InterruptedItems_PersistAndRestore', () async {
    final store = _Store();
    const cpId = 'inflight-persist-session';
    final slowModel = _SlowModel();
    final agent = _chatAgent(slowModel);

    // Phase 1: run, cancel mid-turn, check the exit state.
    final exit = await _cancelledRun(store, cpId, agent, slowModel);
    expect(exit.exitReason, _isCancelError, reason: 'expected *CancelError');
    expect(exit.interruptedItems, ['msg1'],
        reason: 'InterruptedItems in exit state should contain the items that were '
            'mid-execution');
    expect(exit.checkpointAttempted, isTrue, reason: 'checkpoint should be attempted');
    expect(exit.checkpointError, isNull, reason: 'checkpoint save should succeed');
    expect(store.m.containsKey(cpId), isTrue, reason: 'checkpoint should exist in store');

    // Phase 2: restore; genResume gets the same interrupted items.
    slowModel.delay = const Duration(milliseconds: 10);
    var genResumeCalled = false;
    var genInputCalled = false;
    List<String>? resumeInterruptedItems;
    List<String>? resumeUnhandledItems;
    final loop2 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genResume: (ctx, loop, interruptedItems, unhandledItems, newItems) async {
          genResumeCalled = true;
          resumeInterruptedItems = List.of(interruptedItems);
          resumeUnhandledItems = List.of(unhandledItems);
          return GenResumeResult(
            consumed: interruptedItems,
            remaining: [...unhandledItems, ...newItems],
          );
        },
        genInput: (ctx, loop, items) async {
          // Go: t.Fatal("GenInput should not be called when resuming ...").
          genInputCalled = true;
          throw StateError('GenInput should not be called when resuming from a cancel checkpoint');
        },
        prepareAgent: _prepare(agent),
        onAgentEvents: _drainAndStop,
      ),
    )..run(RunContext.background());
    final exit2 = await loop2.wait();
    expect(genInputCalled, isFalse,
        reason: 'GenInput should not be called when resuming from a cancel checkpoint');
    expect(exit2.exitReason, isNull);
    expect(genResumeCalled, isTrue,
        reason: 'GenResume should be called when restoring from a cancel checkpoint');
    expect(resumeInterruptedItems, ['msg1'],
        reason: "GenResume's interruptedItems should match the original exit state's "
            'InterruptedItems');
    expect(resumeUnhandledItems, isEmpty,
        reason: 'unhandledItems should be empty (all items were consumed before cancel)');
  });

  // A preempt cancels turn 1 and a stop with an immediate cancel cancels turn
  // 2: the interrupted items are turn 2's.
  test('TestTurnLoop_PreemptThenStop_InterruptedItems_ReflectsStoppedTurn', () async {
    final store = _Store();
    const cpId = 'preempt-then-stop-session';
    var turnCount = 0;
    final slowModel = _SlowModel(); // Go: 5 s.
    final loop = _newAndRun(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: (ctx, loop, items) async {
          turnCount++;
          return GenInputResult(
            input: AgentInput(messages: [Message.user(items[0])]),
            consumed: items,
          );
        },
        prepareAgent: _prepare(_chatAgent(slowModel)),
      ),
    );

    // Turn 1: push "a", wait for the agent, preempt with "b".
    loop.push('a');
    await slowModel.started.receive();
    final pushed = loop.push(
      'b',
      options: [
        PushOption.preemptTimeout(
          {CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls},
          const Duration(milliseconds: 10),
        ),
      ],
    );
    await pushed.resolved;

    // Turn 2 starts with the buffered items.
    await slowModel.started.receive();
    loop.stop(options: [const StopOption.immediate()]);
    final exit = await loop.wait();
    expect(exit.exitReason, _isCancelError, reason: 'expected *CancelError');
    expect(exit.interruptedItems, isNotEmpty,
        reason: 'InterruptedItems should not be empty after Stop cancel');
    expect(exit.interruptedItems, contains('b'),
        reason: "InterruptedItems should contain 'b' which was part of turn 2's consumed items");
    expect(turnCount, greaterThanOrEqualTo(2));
  });

  test('TestTurnLoop_BusinessInterrupt_PersistAndResume', () async {
    final store = _Store();
    const cpId = 'interrupt-session';
    // An agent that interrupts with interruptEvent.
    final interruptAgent = _InterruptAgent('approval_needed');
    final loop = _newAndRun(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAllWithMsg,
        prepareAgent: _prepare(interruptAgent),
      ),
    );
    loop.push('msg1');
    final exit = await loop.wait();

    // 1. The exit reason is an interrupt (neither null nor a cancel).
    expect(exit.exitReason, _isInterruptError, reason: 'expected *InterruptError');
    final intErr = ThreepioException.findCause<TurnLoopInterruptedException>(exit.exitReason)!;
    // 2. Its interrupt contexts are set.
    expect(intErr.interruptContexts, isNotEmpty);
    // 3. The interrupted items are the turn's.
    expect(exit.interruptedItems, ['msg1']);
    // 4. The checkpoint was written.
    expect(exit.checkpointAttempted, isTrue);
    expect(exit.checkpointError, isNull);
    expect(store.m.containsKey(cpId), isTrue, reason: 'checkpoint should exist in store');

    // 5. A new loop with the same checkpoint id resumes through genResume.
    var genResumeCalled = false;
    List<String>? resumeInterruptedItems;
    final loop2 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genResume: (ctx, loop, interruptedItems, unhandledItems, newItems) async {
          genResumeCalled = true;
          resumeInterruptedItems = List.of(interruptedItems);
          return GenResumeResult(
            consumed: interruptedItems,
            remaining: [...unhandledItems, ...newItems],
          );
        },
        genInput: _consumeAll,
        // On resume the agent completes normally.
        prepareAgent: (ctx, loop, consumed) async => _MockAgent(
          agentName: 'ResumeAgent',
          events: const [AgentEvent(output: AgentOutput())],
        ),
        onAgentEvents: _drainAndStop,
      ),
    )..run(RunContext.background());
    final exit2 = await loop2.wait();
    expect(exit2.exitReason, isNull);
    expect(genResumeCalled, isTrue, reason: 'GenResume should be called on checkpoint resume');
    expect(resumeInterruptedItems, ['msg1'],
        reason: 'interruptedItems should contain the original items');
  });
}
