// Ports of eino `adk/turn_loop_test.go` (v0.9.22), second part (from
// TestPreemptController_BeginPushSnapshotsPlanningTurn to the end of the Go
// file), split over two Dart files: this one has the loop integration tests
// (preempt, push strategy, UntilIdleFor, attacks, recursive propagation);
// `eino_turn_loop_controllers_test.dart` has the controllers, the option
// checks, the turn buffer, late items, checkpoints and the stop cause, and
// lists the Go tests of this part that are not portable.
//
// Ported here (one `test` or `group` per Go test, same name; `t.Run` sub-tests are tests):
//   TestTurnLoop_ConcurrentPreemptsDuringTurn, TestTurnLoop_PreemptBetweenTurnsAcksImmediately,
//   TestTurnLoop_PushStrategy_DuringTurnTransition (adapted, see there),
//   TestTurnLoop_ConcurrentPreemptAndStop, TestTurnLoop_ConcurrentPushStrategyAndStop,
//   TestTurnLoop_TurnContext_StoppedChannel, TestTurnLoop_TurnContext_BothPreemptedAndStopped,
//   TestTurnLoop_PushStrategy_{DuringTurn,BetweenTurns,OverridesOtherOptions,
//   NestedStrategyStripped,ConsumedInspection}, TestSafePoint_ToCancelMode (through behaviour),
//   TestUntilIdleFor (all sub-tests), TestUntilIdleFor_DoesNotCancelRunningAgent,
//   TestUntilIdleFor_ContextCancelDuringIdleWait,
//   TestAttack_UntilIdleFor_{ConcurrentPushDuringIdleTimer,MultipleStopCallsFirstWins},
//   TestAttack_BareStopOverridesUntilIdleFor, TestAttack_BareStopDoesNotDeescalateExistingCancelIntent,
//   TestAttack_InterruptedItems_EmptyWhenAgentFinishesNormally,
//   TestAttack_StopBeforeRun_UntilIdleFor_ExitsImmediately,
//   TestAttack_PushAfterStop_UntilIdleFor_RoutedToLateItems,
//   TestAttack_ConcurrentStopEscalation_RaceDetector (as an interleaving, see there),
//   TestAttack_SkipCheckpoint_Sticky, TestTurnLoop_Stop_WithImmediate_RecursivePropagation,
//   TestTurnLoop_Push_WithPreemptTimeout_RecursivePropagation,
//   TestTurnLoop_Preempt_LoopStalledAfterSecondPreemptPush,
//   TestAttack_BusinessInterrupt_{NoStore_ExitsWithoutPanic,EmptyConsumed_NoCheckpoint}.
//
// Adapted because Dart is single-threaded: Go goroutine races become a bounded number of
// interleaved async calls; Go sleeps become completers, delays of at most 20 ms, or fake_async
// (for idle times of 100 ms and more); Go's `waitOrFail` (a 2 s timer) polls in 1 ms steps
// instead of arming a long timer.

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/cancel.dart';
import 'package:threepio_core/src/adk/eino/run_options.dart';
import 'package:threepio_core/src/adk/eino/turn_loop.dart';

// ---------------------------------------------------------------------------
// Helpers (Go: lines 1–237 of turn_loop_test.go, plus the few helpers of the
// first part this part uses).
// ---------------------------------------------------------------------------

const Set<CancelSafePoint> _afterChatModel = {CancelSafePoint.afterChatModel};
const Set<CancelSafePoint> _afterToolCalls = {CancelSafePoint.afterToolCalls};
const Set<CancelSafePoint> _anySafePoint = {
  CancelSafePoint.afterChatModel,
  CancelSafePoint.afterToolCalls,
};

/// Go's `waitOrFail`: waits for [future], failing after about 2 s. It polls
/// in 1 ms steps rather than arming a long real timer.
Future<T> _waitOrFail<T>(Future<T> future, String message) async {
  var completed = false;
  unawaited(
    future.then<void>(
      (_) => completed = true,
      onError: (Object _, StackTrace __) => completed = true,
    ),
  );
  for (var i = 0; i < 2000 && !completed; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  if (!completed) fail(message);
  return future;
}

/// Polls [condition] in 1 ms steps (bounded); whether it became true. Go's
/// probes loop with `time.Sleep(1 * time.Millisecond)` the same way.
Future<bool> _until(bool Function() condition, {int maxSteps = 3000}) async {
  for (var i = 0; i < maxSteps; i++) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return condition();
}

/// Lets the loop finish what it does after a callback returned (Go polls the
/// private turn phase, `requirePreemptPhase`).
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 1));

Future<void> _drain(StreamReader<AgentEvent> events) async {
  while (await events.nextOrNull() != null) {}
}

/// Port of `turnLoopMockAgent` (named "test"; no test of this part gives it
/// scripted events, so without [runFunc] it sends none).
final class _MockAgent implements Agent {
  _MockAgent({this.runFunc});

  @override
  String get name => 'test';

  @override
  String get description => 'mock agent';

  final Future<AgentOutput> Function(RunContext ctx, AgentInput input)? runFunc;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(() async {
      try {
        final run = runFunc;
        if (run == null) return;
        try {
          writer.send(AgentEvent(output: await run(ctx, input)));
        } on Object catch (error, stackTrace) {
          writer.send(AgentEvent(error: error, stackTrace: stackTrace));
        }
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }
}

/// Port of `turnLoopCancellableMockAgent`: [runFunc] gets a context whose
/// cancel token is cancelled once the run's cancel context is cancelled
/// ([onCancel] is called first, as in Go).
final class _CancellableAgent implements Agent {
  _CancellableAgent({this.name = 'test', required this.runFunc, this.onCancel});

  @override
  final String name;

  @override
  String get description => 'mock agent';

  final Future<AgentOutput> Function(RunContext ctx, AgentInput input) runFunc;
  final void Function(CancelContext cc)? onCancel;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final cc = CommonAgentOptions.of(options).cancelContext;
    final own = CancelToken();
    final runCtx = ctx.withCancelToken(CancelToken.any([ctx.cancelToken, own])!);
    final (reader, writer) = pipe<AgentEvent>();
    if (cc != null) {
      unawaited(() async {
        // Go: `<-cc.cancelChan` (a goroutine that outlives runFunc). The Dart
        // cancel context has no listener for its safe-point cancel signal:
        // poll it until the run is marked done.
        await _until(() => cc.shouldCancel || cc.isDone, maxSteps: 5000);
        if (!cc.shouldCancel) return;
        onCancel?.call(cc);
        own.cancel('agent canceled');
      }());
    }
    unawaited(() async {
      try {
        writer.send(AgentEvent(output: await runFunc(runCtx, input)));
      } on Object catch (error, stackTrace) {
        writer.send(AgentEvent(error: error, stackTrace: stackTrace));
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }
}

/// Go's `<-ctx.Done(); return nil, ctx.Err()`.
Future<AgentOutput> _untilCancelledThenError(RunContext ctx) async {
  await ctx.cancelToken.whenCancelled;
  throw CancelledException(ctx.cancelToken.reason);
}

/// Go's `<-ctx.Done(); return &AgentOutput{}, nil`.
Future<AgentOutput> _untilCancelledThenOk(RunContext ctx) async {
  await ctx.cancelToken.whenCancelled;
  return const AgentOutput();
}

/// Port of `turnLoopStopModeProbeAgent`: hands out the run's cancel context
/// and ends with its cancel error once the cancel is immediate.
final class _StopModeProbeAgent implements Agent {
  final List<CancelContext> contexts = [];
  final Completer<CancelContext> _first = Completer<CancelContext>();

  /// Go: `cc := <-agentStarted`.
  Future<CancelContext> get firstContext => _first.future;

  @override
  String get name => 'probe';

  @override
  String get description => 'probe';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final cc = CommonAgentOptions.of(options).cancelContext!;
    contexts.add(cc);
    if (!_first.isCompleted) _first.complete(cc);
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(() async {
      try {
        if (!await _until(() => cc.shouldCancel)) return;
        if (!await _until(() => cc.mode.isEmpty)) return;
        writer.send(AgentEvent(error: cc.createCancelError()));
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }
}

/// Port of `turnLoopNestedProbeAgent`: like the stop-mode probe, plus a child
/// cancel context derived as an `AgentTool` would.
final class _NestedProbeAgent implements Agent {
  final List<CancelContext> parents = [];
  final List<CancelContext> children = [];
  final Completer<void> _started = Completer<void>();

  /// Go: `cc := <-parentCCCh; child := <-childCCCh`.
  Future<void> get started => _started.future;

  @override
  String get name => 'nested-probe';

  @override
  String get description => 'nested-probe';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final cc = CommonAgentOptions.of(options).cancelContext!;
    final child = cc.deriveCheckpointAware(ctx);
    parents.add(cc);
    children.add(child);
    if (!_started.isCompleted) _started.complete();
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(() async {
      try {
        if (!await _until(() => cc.shouldCancel)) return;
        if (!await _until(() => cc.mode.isEmpty)) return;
        writer.send(AgentEvent(error: cc.createCancelError()));
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
      StreamReader<AgentEvent>.fromIterable([interruptEvent(ctx, interruptInfo)]);
}

/// Port of `turnLoopCheckpointStore`.
class _TestStore implements CheckpointStore {
  final Map<String, Uint8List> m = {};

  @override
  Future<Uint8List?> get(String key) async => m[key];

  @override
  Future<void> set(String key, Uint8List value) async => m[key] = value;
}

typedef _GenInput = Future<GenInputResult<String>> Function(
  RunContext ctx,
  TurnLoop<String> loop,
  List<String> items,
);
typedef _PrepareAgent = Future<Agent> Function(
  RunContext ctx,
  TurnLoop<String> loop,
  List<String> consumed,
);
typedef _OnAgentEvents = Future<void> Function(
  RunContext ctx,
  TurnContext<String> tc,
  StreamReader<AgentEvent> events,
);

/// Port of `newAndRunTurnLoop`.
TurnLoop<String> _newAndRun(TurnLoopConfig<String> config, [RunContext? ctx]) =>
    TurnLoop<String>(config)..run(ctx ?? RunContext.background());

TurnLoopConfig<String> _config({
  required _GenInput genInput,
  required _PrepareAgent prepareAgent,
  _OnAgentEvents? onAgentEvents,
  CheckpointStore? store,
  String checkpointId = '',
}) =>
    TurnLoopConfig<String>(
      genInput: genInput,
      prepareAgent: prepareAgent,
      onAgentEvents: onAgentEvents,
      store: store,
      checkpointId: checkpointId,
    );

/// Port of `genInputConsumeAll`.
Future<GenInputResult<String>> _genInputConsumeAll(
  RunContext ctx,
  TurnLoop<String> loop,
  List<String> items,
) async =>
    GenInputResult(input: AgentInput(), consumed: items);

/// Port of `genInputConsumeAllWithMsg`.
Future<GenInputResult<String>> _genInputConsumeAllWithMsg(
  RunContext ctx,
  TurnLoop<String> loop,
  List<String> items,
) async =>
    GenInputResult(
      input: AgentInput(messages: [Message.user(items[0])]),
      consumed: items,
    );

/// Port of `genInputConsumeFirst`.
Future<GenInputResult<String>> _genInputConsumeFirst(
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
_PrepareAgent _prepareAgent(Agent agent) => (ctx, loop, consumed) async => agent;

/// An agent per turn whose run waits for its cancel, then fails with the
/// context's error (Go: `<-ctx.Done(); return nil, ctx.Err()`).
Future<Agent> _prepareSlowAgent(
  RunContext ctx,
  TurnLoop<String> loop,
  List<String> consumed,
) async =>
    _CancellableAgent(
      name: 'slow',
      runFunc: (ctx, input) => _untilCancelledThenError(ctx),
    );

void _completeOnce(Completer<void> completer) {
  if (!completer.isCompleted) completer.complete();
}

void main() {
  // -------------------------------------------------------------------------
  // Integration tests for race-prone preempt scenarios
  // -------------------------------------------------------------------------

  test('TestTurnLoop_ConcurrentPreemptsDuringTurn', () async {
    final agentStarted = Completer<void>();
    final agent = _CancellableAgent(
      runFunc: (ctx, input) {
        _completeOnce(agentStarted);
        return _untilCancelledThenOk(ctx);
      },
    );

    var genInputCount = 0;
    final secondGenInput = Completer<void>();

    final loop = _newAndRun(
      _config(
        prepareAgent: _prepareAgent(agent),
        genInput: (ctx, loop, items) async {
          if (++genInputCount >= 2) _completeOnce(secondGenInput);
          return GenInputResult(input: AgentInput(), consumed: items);
        },
      ),
    )..push('seed');

    await _waitOrFail(agentStarted.future, 'agent did not start');

    // Go: 10 goroutines; here 10 interleaved async pushes.
    await Future.wait([
      for (var i = 0; i < 10; i++)
        Future<void>(() async {
          final r = loop.push(
            'urgent-$i',
            options: [
              PushOption.preemptTimeout(_anySafePoint, const Duration(milliseconds: 10)),
            ],
          );
          if (r.accepted) {
            await _waitOrFail(r.resolved!, 'ack channel not closed within timeout');
          }
        }),
    ]);

    // Go stops the loop from a goroutine 500 ms later; here once a second
    // turn was planned.
    await _waitOrFail(secondGenInput.future, 'no preempted turn was planned');
    loop.stop(options: [const StopOption.immediate()]);

    final result = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(result.exitReason, isNull);
    expect(
      genInputCount >= 2,
      isTrue,
      reason: 'should have had at least the initial turn + one preempted turn',
    );
  });

  test('TestTurnLoop_PreemptBetweenTurnsAcksImmediately', () async {
    var cancelCount = 0;
    var turnCount = 0;
    final firstTurnDone = Completer<void>();
    final secondTurnDone = Completer<void>();

    final agent = _CancellableAgent(
      name: 'fast',
      runFunc: (ctx, input) async => const AgentOutput(),
      onCancel: (cc) => cancelCount++,
    );

    final loop = _newAndRun(
      _config(
        prepareAgent: _prepareAgent(agent),
        genInput: (ctx, loop, items) async {
          turnCount++;
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          switch (turnCount) {
            case 1:
              _completeOnce(firstTurnDone);
            case 2:
              _completeOnce(secondTurnDone);
          }
        },
      ),
    )..push('first');
    await _waitOrFail(firstTurnDone.future, 'first turn did not complete');
    // Go: requirePreemptPhase(idle); the phase is private in Dart, so the
    // loop is given time to leave the turn.
    await _settle();

    final r = loop.push('between-turns', options: [PushOption.preempt(_anySafePoint)]);
    expect(r.accepted, isTrue);
    await _waitOrFail(r.resolved!, 'ack should be closed');
    expect(cancelCount, 0, reason: 'between-turn preempt must not submit cancel');

    await _waitOrFail(secondTurnDone.future, 'between-turn item was not processed');

    loop.stop();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(turnCount, 2);
  });

  test('TestTurnLoop_PushStrategy_DuringTurnTransition', () async {
    // Adapted: in Go the strategy blocks (in its own goroutine) while the
    // agent finishes, and the next turn must not be planned before the push
    // ends. A Dart strategy is synchronous: nothing else runs while it does,
    // so the agent is released from inside the strategy and the check is made
    // when the push returns.
    final agentStarted = Completer<void>();
    final allowFinish = Completer<void>();
    final strategyEntered = Completer<void>();

    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        _completeOnce(agentStarted);
        await Future.any([allowFinish.future, ctx.cancelToken.whenCancelled]);
        return const AgentOutput();
      },
    );

    var genInputCount = 0;
    final secondTurnDone = Completer<void>();

    final loop = _newAndRun(
      _config(
        prepareAgent: _prepareAgent(agent),
        genInput: (ctx, loop, items) async {
          if (++genInputCount >= 2) _completeOnce(secondTurnDone);
          return GenInputResult(input: AgentInput(), consumed: items);
        },
      ),
    )..push('first');

    await _waitOrFail(agentStarted.future, 'agent did not start');

    var strategyTcNotNil = false;
    loop.push(
      'strategic-item',
      options: [
        PushOption.strategy((ctx, tc) {
          if (tc != null) strategyTcNotNil = true;
          strategyEntered.complete();
          allowFinish.complete();
          return [PushOption.preempt(_anySafePoint)];
        }),
      ],
    );

    expect(strategyEntered.isCompleted, isTrue, reason: 'strategy did not enter');
    expect(
      secondTurnDone.isCompleted,
      isFalse,
      reason: 'second turn should not be planned before strategy Push finishes',
    );

    await _waitOrFail(
      secondTurnDone.future,
      'second turn should eventually run after strategy resolves',
    );

    loop.stop();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(genInputCount >= 2, isTrue);
    expect(strategyTcNotNil, isTrue);
  });

  group('TestTurnLoop_ConcurrentPreemptAndStop', () {
    for (var iter = 0; iter < 20; iter++) {
      test('iter_$iter', () async {
        final agentStarted = Completer<void>();
        final agent = _CancellableAgent(
          runFunc: (ctx, input) {
            _completeOnce(agentStarted);
            return _untilCancelledThenOk(ctx);
          },
        );

        final loop = _newAndRun(
          _config(prepareAgent: (ctx, loop, consumed) async => agent, genInput: _genInputConsumeAll),
        )..push('seed');

        await _waitOrFail(agentStarted.future, 'agent did not start');

        // Go: two goroutines; here two async calls, in alternating order.
        Future<void> preempt() async {
          final r = loop.push('preempt-item', options: [PushOption.preempt(_anySafePoint)]);
          await r.resolved;
        }

        Future<void> stop() async => loop.stop(options: [const StopOption.immediate()]);

        await _waitOrFail(
          Future.wait(
            iter.isEven
                ? [Future<void>(preempt), Future<void>(stop)]
                : [Future<void>(stop), Future<void>(preempt)],
          ),
          'push or stop did not return',
        );
        await _waitOrFail(loop.wait(), 'loop did not exit');
      });
    }
  });

  group('TestTurnLoop_ConcurrentPushStrategyAndStop', () {
    for (var iter = 0; iter < 20; iter++) {
      test('iter_$iter', () async {
        final agentStarted = Completer<void>();
        final agent = _CancellableAgent(
          runFunc: (ctx, input) {
            _completeOnce(agentStarted);
            return _untilCancelledThenOk(ctx);
          },
        );

        final loop = _newAndRun(
          _config(prepareAgent: (ctx, loop, consumed) async => agent, genInput: _genInputConsumeAll),
        )..push('seed');

        await _waitOrFail(agentStarted.future, 'agent did not start');

        // Go: two goroutines; here two async calls, in alternating order.
        Future<void> push() async {
          final r = loop.push(
            'strategic-item',
            options: [PushOption.strategy((ctx, tc) => [PushOption.preempt(_anySafePoint)])],
          );
          await r.resolved;
        }

        Future<void> stop() async => loop.stop(options: [const StopOption.immediate()]);

        await _waitOrFail(
          Future.wait(
            iter.isEven
                ? [Future<void>(push), Future<void>(stop)]
                : [Future<void>(stop), Future<void>(push)],
          ),
          'push or stop did not return',
        );
        await _waitOrFail(loop.wait(), 'loop did not exit');
      });
    }
  });

  test('TestTurnLoop_TurnContext_StoppedChannel', () async {
    final stoppedSeen = Completer<void>();
    final agentStarted = Completer<void>();

    final loop = _newAndRun(
      _config(
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: _prepareSlowAgent,
        onAgentEvents: (ctx, tc, events) async {
          agentStarted.complete();
          await _waitOrFail(tc.stopped, 'timed out waiting for Stopped channel');
          stoppedSeen.complete();
          await _drain(events);
        },
      ),
    )..push('msg1');
    await agentStarted.future;
    loop.stop(options: [const StopOption.immediate()]);

    await _waitOrFail(stoppedSeen.future, 'stopped channel was never observed in OnAgentEvents');

    await _waitOrFail(loop.wait(), 'loop did not exit');
  });

  group('TestTurnLoop_TurnContext_BothPreemptedAndStopped', () {
    test('PreemptThenStop_OnlyPreemptContributes', () async {
      final preemptedSeen = Completer<void>();
      final agentStarted = Completer<void>();

      final loop = _newAndRun(
        _config(
          genInput: _genInputConsumeAllWithMsg,
          prepareAgent: _prepareSlowAgent,
          onAgentEvents: (ctx, tc, events) async {
            agentStarted.complete();
            await _waitOrFail(tc.preempted, 'timed out waiting for Preempted');
            preemptedSeen.complete();
            await _drain(events);
          },
        ),
      )..push('msg1');
      await agentStarted.future;
      loop.push(
        'msg2',
        options: [PushOption.preemptTimeout(_anySafePoint, const Duration(milliseconds: 1))],
      );

      await _waitOrFail(preemptedSeen.future, 'Preempted channel was never closed');

      loop.stop(options: [const StopOption.immediate()]);
      await _waitOrFail(loop.wait(), 'loop did not exit');
    });

    test('StopThenPreempt_OnlyStopContributes', () async {
      final stoppedSeen = Completer<void>();
      final agentStarted = Completer<void>();

      final loop = _newAndRun(
        _config(
          genInput: _genInputConsumeAllWithMsg,
          prepareAgent: _prepareSlowAgent,
          onAgentEvents: (ctx, tc, events) async {
            agentStarted.complete();
            await _waitOrFail(tc.stopped, 'timed out waiting for Stopped');
            stoppedSeen.complete();
            await _drain(events);
          },
        ),
      )..push('msg1');
      await agentStarted.future;
      loop.stop(options: [const StopOption.immediate()]);

      await _waitOrFail(stoppedSeen.future, 'Stopped channel was never closed');

      loop.push(
        'msg2',
        options: [PushOption.preemptTimeout(_anySafePoint, const Duration(milliseconds: 1))],
      );
      await _waitOrFail(loop.wait(), 'loop did not exit');
    });
  });

  test('TestTurnLoop_PushStrategy_DuringTurn', () async {
    final agentStarted = Completer<void>();
    final agentCancelled = Completer<void>();

    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        _completeOnce(agentStarted);
        await ctx.cancelToken.whenCancelled;
        _completeOnce(agentCancelled);
        return const AgentOutput();
      },
    );

    var genInputCalls = 0;
    final secondGenInputCalled = Completer<void>();

    final loop = _newAndRun(
      _config(
        prepareAgent: _prepareAgent(agent),
        genInput: (ctx, loop, items) async {
          if (++genInputCalls >= 2) _completeOnce(secondGenInputCalled);
          return GenInputResult(
            input: AgentInput(messages: [Message.user(items[0])]),
            consumed: [items[0]],
            remaining: items.sublist(1),
          );
        },
      ),
    )..push('first');

    await _waitOrFail(agentStarted.future, 'agent did not start');

    var strategyCalled = 0;
    TurnContext<String>? strategyTc;
    loop.push(
      'urgent',
      options: [
        PushOption.strategy((ctx, tc) {
          strategyCalled++;
          strategyTc = tc;
          return [PushOption.preempt(_anySafePoint)];
        }),
      ],
    );

    await _waitOrFail(agentCancelled.future, 'agent was not cancelled by strategy-returned preempt');

    await _waitOrFail(secondGenInputCalled.future, 'second GenInput was not called after preempt');

    loop.stop(options: [const StopOption.immediate()]);
    await _waitOrFail(loop.wait(), 'loop did not exit');

    expect(strategyCalled, 1);
    expect(strategyTc, isNotNull, reason: 'strategy should receive non-nil TurnContext during a turn');
    expect(strategyTc!.consumed, ['first']);
  });

  test('TestTurnLoop_PushStrategy_BetweenTurns', () async {
    var strategyCalled = 0;
    var strategyTcWasNil = false;

    final agent = _CancellableAgent(runFunc: (ctx, input) async => const AgentOutput());

    final agentDone = Completer<void>();

    final loop = _newAndRun(
      _config(
        prepareAgent: _prepareAgent(agent),
        genInput: _genInputConsumeAllWithMsg,
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          _completeOnce(agentDone);
        },
      ),
    )..push(
        'item',
        options: [
          PushOption.strategy((ctx, tc) {
            strategyCalled++;
            strategyTcWasNil = tc == null;
            return const [];
          }),
        ],
      );

    await _waitOrFail(agentDone.future, 'agent did not complete');

    loop.stop();
    await loop.wait();

    expect(strategyCalled, 1);
    expect(strategyTcWasNil, isTrue, reason: 'strategy should receive nil TurnContext between turns');
  });

  test('TestTurnLoop_PushStrategy_OverridesOtherOptions', () async {
    var agentCancelled = false;
    final agent = _CancellableAgent(
      runFunc: (ctx, input) async => const AgentOutput(),
      onCancel: (cc) => agentCancelled = true,
    );

    final agentDone = Completer<void>();

    final loop = _newAndRun(
      _config(
        prepareAgent: _prepareAgent(agent),
        genInput: _genInputConsumeAllWithMsg,
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          _completeOnce(agentDone);
        },
      ),
    );

    final r = loop.push(
      'item',
      options: [
        PushOption.preempt(_anySafePoint),
        PushOption.strategy((ctx, tc) => const []),
      ],
    );
    expect(r.accepted, isTrue);
    // Go: assert.Nil(t, ack, "ack should be nil since strategy returned no
    // preempt").
    expect(r.resolved, isNull, reason: 'ack should be nil since strategy returned no preempt');

    await _waitOrFail(agentDone.future, 'agent did not complete normally');
    expect(agentCancelled, isFalse);

    loop.stop();
    await loop.wait();
  });

  test('TestTurnLoop_PushStrategy_NestedStrategyStripped', () async {
    final agent = _CancellableAgent(runFunc: (ctx, input) async => const AgentOutput());

    final agentDone = Completer<void>();

    final loop = _newAndRun(
      _config(
        prepareAgent: _prepareAgent(agent),
        genInput: _genInputConsumeAllWithMsg,
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          _completeOnce(agentDone);
        },
      ),
    );

    var innerCalled = 0;
    final r = loop.push(
      'item',
      options: [
        PushOption.strategy(
          (ctx, tc) => [
            PushOption.strategy((ctx, tc) {
              innerCalled++;
              return [PushOption.preempt(_anySafePoint)];
            }),
          ],
        ),
      ],
    );
    expect(r.accepted, isTrue);
    // Go: assert.Nil(t, ack, "ack should be nil since nested strategy was
    // stripped (no preempt)").
    expect(r.resolved, isNull,
        reason: 'ack should be nil since nested strategy was stripped (no preempt)');

    await _waitOrFail(agentDone.future, 'agent did not complete normally');

    loop.stop();
    await loop.wait();

    expect(innerCalled, 0, reason: 'nested strategy should not be called');
  });

  test('TestTurnLoop_PushStrategy_ConsumedInspection', () async {
    final agentStarted = Completer<void>();

    final agent = _CancellableAgent(
      runFunc: (ctx, input) {
        _completeOnce(agentStarted);
        return _untilCancelledThenOk(ctx);
      },
    );

    var genInputCalls = 0;
    final secondGenInputItems = Completer<List<String>>();

    final loop = _newAndRun(
      _config(
        prepareAgent: _prepareAgent(agent),
        genInput: (ctx, loop, items) async {
          if (++genInputCalls >= 2 && !secondGenInputItems.isCompleted) {
            secondGenInputItems.complete(List.of(items));
          }
          return GenInputResult(
            input: AgentInput(messages: [Message.user(items[0])]),
            consumed: [items[0]],
            remaining: items.sublist(1),
          );
        },
      ),
    )..push('low-priority-task');

    await _waitOrFail(agentStarted.future, 'agent did not start');

    loop.push(
      'urgent-task',
      options: [
        PushOption.strategy((ctx, tc) {
          if (tc != null && tc.consumed.isNotEmpty && tc.consumed[0] == 'low-priority-task') {
            return [PushOption.preempt(_anySafePoint)];
          }
          return const [];
        }),
      ],
    );

    final items = await _waitOrFail(
      secondGenInputItems.future,
      'second GenInput was not called after strategy-driven preempt',
    );
    expect(items, contains('urgent-task'));

    loop.stop(options: [const StopOption.immediate()]);
    await _waitOrFail(loop.wait(), 'loop did not exit');
  });

  group('TestSafePoint_ToCancelMode', () {
    // Go converts its SafePoint to a CancelMode; Dart's PushOption.preempt
    // takes the cancel safe points directly. Ported through behaviour: the
    // preempt cancels the running turn at exactly those safe points.
    for (final (name, safePoints) in [
      ('AfterToolCalls', _afterToolCalls),
      ('AfterChatModel', _afterChatModel),
      ('AnySafePoint', _anySafePoint),
    ]) {
      test(name, () async {
        final probe = _StopModeProbeAgent();
        final loop = _newAndRun(
          _config(genInput: _genInputConsumeAllWithMsg, prepareAgent: _prepareAgent(probe)),
        )..push('first');
        final cc = await _waitOrFail(probe.firstContext, 'agent did not start');

        final r = loop.push('urgent', options: [PushOption<String>.preempt(safePoints)]);
        await _waitOrFail(r.resolved!, 'preempt was not resolved');
        expect(cc.shouldCancel, isTrue);
        expect(cc.mode, safePoints);

        loop.stop(options: [const StopOption.immediate()]);
        await _waitOrFail(loop.wait(), 'loop did not exit');
      });
    }
  });

  // -------------------------------------------------------------------------
  // UntilIdleFor
  // -------------------------------------------------------------------------

  group('TestUntilIdleFor', () {
    test('FiresAfterIdleDuration', () {
      fakeAsync((async) {
        var turnDone = false;
        final loop = _newAndRun(
          _config(
            genInput: _genInputConsumeAllWithMsg,
            prepareAgent: (ctx, loop, consumed) async => _MockAgent(
              runFunc: (ctx, input) async {
                turnDone = true;
                return const AgentOutput();
              },
            ),
          ),
        );
        TurnLoopExitState<String>? exit;
        unawaited(loop.wait().then((e) => exit = e));

        loop.push('msg1');
        async.elapse(Duration.zero);
        expect(turnDone, isTrue);

        loop.stop(options: [StopOption.untilIdleFor(const Duration(milliseconds: 50))]);

        // Go waits up to 2 s for the exit.
        async.elapse(const Duration(seconds: 2));
        expect(exit, isNotNull, reason: 'loop did not exit after idle timeout');
      });
    });

    test('ResetsOnPush', () {
      fakeAsync((async) {
        var turnCount = 0;
        var turnsDone = 0;
        final loop = _newAndRun(
          _config(
            genInput: _genInputConsumeAllWithMsg,
            prepareAgent: (ctx, loop, consumed) async => _MockAgent(
              runFunc: (ctx, input) async {
                turnCount++;
                turnsDone++;
                return const AgentOutput();
              },
            ),
          ),
        );
        TurnLoopExitState<String>? exit;
        unawaited(loop.wait().then((e) => exit = e));

        loop.push('msg1');
        async.elapse(Duration.zero);
        expect(turnsDone, 1);

        loop.stop(options: [StopOption.untilIdleFor(const Duration(milliseconds: 200))]);

        async.elapse(const Duration(milliseconds: 100));
        loop.push('msg2');
        async.elapse(Duration.zero);
        expect(turnsDone, 2);

        async.elapse(const Duration(seconds: 2));
        expect(exit, isNotNull, reason: 'loop did not exit after idle timeout');

        expect(turnCount, 2);
      });
    });

    test('EscalatedByStopWithImmediate', () async {
      final probe = _StopModeProbeAgent();
      final loop = _newAndRun(
        _config(genInput: _genInputConsumeAllWithMsg, prepareAgent: _prepareAgent(probe)),
      )..push('msg1');
      final cc = await _waitOrFail(probe.firstContext, 'agent did not start');

      loop
        ..stop(options: [StopOption.untilIdleFor(const Duration(minutes: 10))])
        ..stop(options: [const StopOption.immediate()]);

      expect(
        await _until(() => cc.mode.isEmpty, maxSteps: 2000),
        isTrue,
        reason: 'cancel mode did not escalate to CancelImmediate',
      );

      final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
      expect(exit.exitReason, isA<AgentRunCancelledException>());
      expect((exit.exitReason! as AgentRunCancelledException).info.isImmediate, isTrue);
    });

    test('EscalatedByStopWithGraceful', () async {
      final agentStarted = Completer<void>();
      final agentDone = Completer<void>();
      final loop = _newAndRun(
        _config(
          genInput: _genInputConsumeAllWithMsg,
          prepareAgent: (ctx, loop, consumed) async => _CancellableAgent(
            runFunc: (ctx, input) async {
              agentStarted.complete();
              await ctx.cancelToken.whenCancelled;
              agentDone.complete();
              throw CancelledException(ctx.cancelToken.reason);
            },
          ),
        ),
      )..push('msg1');
      await agentStarted.future;

      // Go's grace period is 50 ms.
      loop
        ..stop(options: [StopOption.untilIdleFor(const Duration(minutes: 10))])
        ..stop(options: [StopOption.gracefulTimeout(const Duration(milliseconds: 20))]);

      await _waitOrFail(agentDone.future, 'agent was not cancelled');

      final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
      expect(exit.exitReason, isNotNull);
    });
  });

  group('TestUntilIdleFor_DoesNotCancelRunningAgent', () {
    // Go: the agent waits for its cancel or 200 ms, with an idle time of
    // 50 ms; here 20 ms and 10 ms.
    _CancellableAgent agentFor(Completer<void> started, Completer<void> done, void Function() onCtxCanceled) =>
        _CancellableAgent(
          runFunc: (ctx, input) async {
            started.complete();
            final canceled = await Future.any([
              ctx.cancelToken.whenCancelled.then((_) => true),
              Future<bool>.delayed(const Duration(milliseconds: 20), () => false),
            ]);
            if (canceled) onCtxCanceled();
            done.complete();
            return const AgentOutput();
          },
        );

    test('BeforeRun', () async {
      final agentStarted = Completer<void>();
      var agentCtxCanceled = false;
      final agentDone = Completer<void>();

      final loop = TurnLoop<String>(
        _config(
          genInput: _genInputConsumeAllWithMsg,
          prepareAgent: (ctx, loop, consumed) async =>
              agentFor(agentStarted, agentDone, () => agentCtxCanceled = true),
        ),
      )
        ..push('msg1')
        ..stop(options: [StopOption.untilIdleFor(const Duration(milliseconds: 10))])
        ..run(RunContext.background());

      await _waitOrFail(agentStarted.future, 'agent did not start');
      await _waitOrFail(agentDone.future, 'agent did not finish');

      final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
      expect(exit.exitReason, isNull, reason: 'UntilIdleFor should not produce a CancelError');
      expect(
        agentCtxCanceled,
        isFalse,
        reason: 'agent context should not have been canceled by UntilIdleFor',
      );
    });

    test('DuringRun', () async {
      final agentStarted = Completer<void>();
      var agentCtxCanceled = false;
      final agentDone = Completer<void>();

      final loop = _newAndRun(
        _config(
          genInput: _genInputConsumeAllWithMsg,
          prepareAgent: (ctx, loop, consumed) async =>
              agentFor(agentStarted, agentDone, () => agentCtxCanceled = true),
        ),
      )..push('msg1');
      await _waitOrFail(agentStarted.future, 'agent did not start');

      loop.stop(options: [StopOption.untilIdleFor(const Duration(milliseconds: 10))]);
      await _waitOrFail(agentDone.future, 'agent did not finish');

      final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
      expect(exit.exitReason, isNull, reason: 'UntilIdleFor should not produce a CancelError');
      expect(
        agentCtxCanceled,
        isFalse,
        reason: 'agent context should not have been canceled by UntilIdleFor',
      );
    });

    test('CancelOptsDroppedInSameCall', () async {
      final agentStarted = Completer<void>();
      var agentCtxCanceled = false;
      final agentDone = Completer<void>();

      final loop = _newAndRun(
        _config(
          genInput: _genInputConsumeAllWithMsg,
          prepareAgent: (ctx, loop, consumed) async =>
              agentFor(agentStarted, agentDone, () => agentCtxCanceled = true),
        ),
      )..push('msg1');
      await _waitOrFail(agentStarted.future, 'agent did not start');

      loop.stop(
        options: [
          StopOption.untilIdleFor(const Duration(milliseconds: 10)),
          const StopOption.immediate(),
        ],
      );
      await _waitOrFail(agentDone.future, 'agent did not finish');

      final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
      expect(
        exit.exitReason,
        isNull,
        reason: 'cancel opts should be dropped when combined with UntilIdleFor',
      );
      expect(agentCtxCanceled, isFalse, reason: 'agent context should not have been canceled');
    });
  });

  test('TestUntilIdleFor_ContextCancelDuringIdleWait', () {
    fakeAsync((async) {
      var turnDone = false;
      final token = CancelToken();

      final loop = _newAndRun(
        _config(
          genInput: _genInputConsumeAllWithMsg,
          prepareAgent: (ctx, loop, consumed) async => _MockAgent(
            runFunc: (ctx, input) async {
              turnDone = true;
              return const AgentOutput();
            },
          ),
        ),
        RunContext.background(cancelToken: token),
      );
      TurnLoopExitState<String>? exit;
      unawaited(loop.wait().then((e) => exit = e));

      loop.push('msg1');
      async.elapse(Duration.zero);
      expect(turnDone, isTrue);

      // Start the idle timer, then cancel the parent context while idle.
      loop.stop(options: [StopOption.untilIdleFor(const Duration(minutes: 10))]);
      async.elapse(const Duration(milliseconds: 20));
      token.cancel();

      async.elapse(const Duration(seconds: 2));
      expect(exit, isNotNull, reason: 'loop should exit when context is canceled during idle wait');

      // Go: context.Canceled.
      expect(exit!.exitReason, isA<CancelledException>());
    });
  });

  // -------------------------------------------------------------------------
  // Attack tests
  // -------------------------------------------------------------------------

  test('TestAttack_UntilIdleFor_ConcurrentPushDuringIdleTimer', () {
    fakeAsync((async) {
      var turnCount = 0;
      var turnsDone = 0;

      final loop = _newAndRun(
        _config(
          genInput: _genInputConsumeAllWithMsg,
          prepareAgent: (ctx, loop, consumed) async => _MockAgent(
            runFunc: (ctx, input) async {
              turnCount++;
              turnsDone++;
              return const AgentOutput();
            },
          ),
        ),
      );
      TurnLoopExitState<String>? exit;
      unawaited(loop.wait().then((e) => exit = e));

      loop.push('msg1');
      async.elapse(Duration.zero);
      expect(turnsDone, 1);

      loop.stop(options: [StopOption.untilIdleFor(const Duration(milliseconds: 200))]);

      for (var i = 0; i < 5; i++) {
        async.elapse(const Duration(milliseconds: 50));
        loop.push('concurrent-${String.fromCharCode(0x61 + i)}');
        async.elapse(Duration.zero);
        expect(turnsDone, i + 2);
      }

      async.elapse(const Duration(seconds: 2));
      expect(
        exit,
        isNotNull,
        reason: 'loop did not exit after idle timeout — Push did not reset timer correctly',
      );

      expect(turnCount, 6, reason: 'all 6 pushes should have been processed');
    });
  });

  test('TestAttack_UntilIdleFor_MultipleStopCallsFirstWins', () {
    fakeAsync((async) {
      var turnDone = false;
      final loop = _newAndRun(
        _config(
          genInput: _genInputConsumeAllWithMsg,
          prepareAgent: (ctx, loop, consumed) async => _MockAgent(
            runFunc: (ctx, input) async {
              turnDone = true;
              return const AgentOutput();
            },
          ),
        ),
      );
      TurnLoopExitState<String>? exit;
      unawaited(loop.wait().then((e) => exit = e));

      loop.push('msg1');
      async.elapse(Duration.zero);
      expect(turnDone, isTrue);

      loop
        ..stop(options: [StopOption.untilIdleFor(const Duration(milliseconds: 100))])
        ..stop(options: [StopOption.untilIdleFor(const Duration(minutes: 10))]);

      async.elapse(const Duration(seconds: 2));
      expect(
        exit,
        isNotNull,
        reason: 'second UntilIdleFor should have been ignored; loop should have exited with 100ms timer',
      );
    });
  });

  test('TestAttack_BareStopOverridesUntilIdleFor', () {
    fakeAsync((async) {
      var agentStarted = false;
      final agentDone = Completer<void>();

      final loop = _newAndRun(
        _config(
          genInput: _genInputConsumeAllWithMsg,
          prepareAgent: (ctx, loop, consumed) async => _MockAgent(
            runFunc: (ctx, input) async {
              agentStarted = true;
              await agentDone.future;
              return const AgentOutput();
            },
          ),
        ),
      );
      TurnLoopExitState<String>? exit;
      unawaited(loop.wait().then((e) => exit = e));

      loop.push('msg1');
      async.elapse(Duration.zero);
      expect(agentStarted, isTrue);

      loop
        ..stop(options: [StopOption.untilIdleFor(const Duration(minutes: 10))])
        ..stop();
      agentDone.complete();

      async.elapse(const Duration(seconds: 2));
      expect(
        exit,
        isNotNull,
        reason: 'bare Stop should override UntilIdleFor and cause immediate shutdown',
      );

      expect(exit!.exitReason, isNull, reason: 'bare Stop should exit cleanly');
    });
  });

  test('TestAttack_BareStopDoesNotDeescalateExistingCancelIntent', () async {
    final probe = _StopModeProbeAgent();
    final loop = _newAndRun(
      _config(genInput: _genInputConsumeAllWithMsg, prepareAgent: _prepareAgent(probe)),
    )..push('msg1');
    final cc = await _waitOrFail(probe.firstContext, 'agent did not start');

    loop.stop(options: [const StopOption.immediate()]);

    await Future<void>.delayed(const Duration(milliseconds: 20));

    loop.stop();

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      cc.mode,
      isEmpty,
      reason: 'bare Stop after WithImmediate must not de-escalate cancel mode',
    );

    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(exit.exitReason, isA<AgentRunCancelledException>());
    expect((exit.exitReason! as AgentRunCancelledException).info.isImmediate, isTrue);
  });

  test('TestAttack_InterruptedItems_EmptyWhenAgentFinishesNormally', () async {
    final agentStarted = Completer<void>();
    final loop = _newAndRun(
      _config(
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: (ctx, loop, consumed) async => _MockAgent(
          runFunc: (ctx, input) async {
            agentStarted.complete();
            return const AgentOutput();
          },
        ),
      ),
    )..push('msg1');
    await _waitOrFail(agentStarted.future, 'agent did not start');
    // Go sleeps 50 ms to let the turn finish.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    loop.stop();

    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(exit.exitReason, isNull);
    expect(
      exit.interruptedItems,
      isEmpty,
      reason: 'InterruptedItems must be empty when agent finished normally',
    );
  });

  test('TestAttack_StopBeforeRun_UntilIdleFor_ExitsImmediately', () {
    fakeAsync((async) {
      final loop = TurnLoop<String>(
        _config(genInput: _genInputConsumeAllWithMsg, prepareAgent: _prepareTestAgent),
      )
        ..stop(options: [StopOption.untilIdleFor(const Duration(minutes: 10))])
        ..stop()
        ..run(RunContext.background());

      TurnLoopExitState<String>? exit;
      unawaited(loop.wait().then((e) => exit = e));

      async.elapse(const Duration(seconds: 2));
      expect(exit, isNotNull, reason: 'loop should exit immediately when Stop() called before Run()');
    });
  });

  test('TestAttack_PushAfterStop_UntilIdleFor_RoutedToLateItems', () async {
    final turnDone = Completer<void>();
    final loop = _newAndRun(
      _config(
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: (ctx, loop, consumed) async => _MockAgent(
          runFunc: (ctx, input) async {
            turnDone.complete();
            return const AgentOutput();
          },
        ),
      ),
    )..push('msg1');
    await _waitOrFail(turnDone.future, 'turn did not run');

    // Go's idle time is 50 ms.
    loop.stop(options: [StopOption.untilIdleFor(const Duration(milliseconds: 10))]);
    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(exit.exitReason, isNull);

    expect(loop.push('after-stop').accepted, isFalse, reason: 'Push after loop exited should return false');

    expect(exit.takeLateItems(), ['after-stop']);
  });

  test('TestAttack_ConcurrentStopEscalation_RaceDetector', () async {
    // Go: a data-race check with 10 goroutines; here 10 interleaved stops,
    // checking that the loop still exits. Go's durations (100 ms, 50 ms) are
    // 20 ms and 10 ms.
    final agentStarted = Completer<void>();
    final loop = _newAndRun(
      _config(
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: (ctx, loop, consumed) async => _CancellableAgent(
          runFunc: (ctx, input) {
            agentStarted.complete();
            return _untilCancelledThenError(ctx);
          },
        ),
      ),
    )..push('msg1');
    await _waitOrFail(agentStarted.future, 'agent did not start');

    await Future.wait([
      for (var i = 0; i < 10; i++)
        Future<void>(() {
          switch (i % 4) {
            case 0:
              loop.stop();
            case 1:
              loop.stop(options: [const StopOption.immediate()]);
            case 2:
              loop.stop(options: [StopOption.gracefulTimeout(const Duration(milliseconds: 20))]);
            case 3:
              loop.stop(options: [StopOption.untilIdleFor(const Duration(milliseconds: 10))]);
          }
        }),
    ]);

    await _waitOrFail(loop.wait(), 'loop did not exit');
  });

  test('TestAttack_SkipCheckpoint_Sticky', () async {
    final agentStarted = Completer<void>();
    final loop = _newAndRun(
      _config(
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: (ctx, loop, consumed) async => _CancellableAgent(
          runFunc: (ctx, input) {
            agentStarted.complete();
            return _untilCancelledThenError(ctx);
          },
        ),
        store: _TestStore(),
        checkpointId: 'test-sticky',
      ),
    )..push('msg1');
    await _waitOrFail(agentStarted.future, 'agent did not start');

    loop
      ..stop(options: [const StopOption.skipCheckpoint()])
      ..stop(options: [const StopOption.immediate()]);

    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(
      exit.checkpointAttempted,
      isFalse,
      reason: 'SkipCheckpoint is sticky; checkpoint should be skipped',
    );
  });

  // -------------------------------------------------------------------------
  // Recursive propagation
  // -------------------------------------------------------------------------

  test('TestTurnLoop_Stop_WithImmediate_RecursivePropagation', () async {
    final probe = _NestedProbeAgent();

    final loop = _newAndRun(
      _config(genInput: _genInputConsumeAllWithMsg, prepareAgent: _prepareAgent(probe)),
    )..push('msg1');
    await _waitOrFail(probe.started, 'agent did not start');
    final cc = probe.parents.first;
    final child = probe.children.first;
    addTearDown(child.markDone);

    final childImmediate = Completer<void>();
    child.onImmediate(() => _completeOnce(childImmediate));

    loop.stop(options: [const StopOption.immediate()]);

    expect(
      await _until(() => child.shouldCancel, maxSteps: 2000),
      isTrue,
      reason: 'child did not receive cancel via recursive propagation',
    );

    await _waitOrFail(
      childImmediate.future,
      'child did not receive immediate cancel via recursive propagation',
    );

    expect(cc.isRecursive, isTrue, reason: 'WithImmediate should set recursive on parent');
    expect(child.shouldCancel, isTrue, reason: 'child should be cancelled');
    expect(child.isImmediateCancelled, isTrue, reason: 'child should have received immediate cancel');

    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(exit.exitReason, isA<AgentRunCancelledException>());
    expect((exit.exitReason! as AgentRunCancelledException).info.isImmediate, isTrue);
  });

  test('TestTurnLoop_Push_WithPreemptTimeout_RecursivePropagation', () async {
    final probe = _NestedProbeAgent();

    final loop = _newAndRun(
      _config(genInput: _genInputConsumeAllWithMsg, prepareAgent: _prepareAgent(probe)),
    )..push('first');
    await _waitOrFail(probe.started, 'agent did not start');
    final cc = probe.parents.first;
    final child = probe.children.first;
    addTearDown(child.markDone);

    final childImmediate = Completer<void>();
    child.onImmediate(() => _completeOnce(childImmediate));

    // A very short timeout, so that the preempt escalates to an immediate
    // cancel quickly.
    loop.push(
      'urgent',
      options: [PushOption.preemptTimeout(_afterChatModel, const Duration(milliseconds: 10))],
    );

    await _waitOrFail(
      childImmediate.future,
      'child did not receive immediate cancel after preempt timeout escalation',
    );

    expect(cc.isRecursive, isTrue, reason: 'WithPreemptTimeout should set recursive on parent');
    expect(child.isImmediateCancelled, isTrue, reason: 'child should have received immediate cancel');

    loop.stop(options: [const StopOption.immediate()]);
    await _waitOrFail(loop.wait(), 'loop did not exit');
  });

  test('TestTurnLoop_Preempt_LoopStalledAfterSecondPreemptPush', () async {
    var turnCount = 0;

    final firstAgentStarted = Completer<void>();
    final secondTurnDone = Completer<void>();
    final thirdTurnDone = Completer<void>();

    final agent = _CancellableAgent(
      runFunc: (ctx, input) async {
        final turn = ++turnCount;
        if (turn == 1) {
          // First turn: signal started, then block until preempted.
          _completeOnce(firstAgentStarted);
          await ctx.cancelToken.whenCancelled;
        }
        return const AgentOutput();
      },
    );

    final loop = _newAndRun(
      _config(
        prepareAgent: _prepareAgent(agent),
        genInput: _genInputConsumeFirst,
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          switch (turnCount) {
            case 2:
              _completeOnce(secondTurnDone);
            case 3:
              _completeOnce(thirdTurnDone);
          }
        },
      ),
    )..push('A');
    await _waitOrFail(firstAgentStarted.future, 'agent did not start for item A');

    loop.push('B', options: [PushOption.preempt(_anySafePoint)]);

    await _waitOrFail(secondTurnDone.future, 'second turn (item B) did not complete');

    loop.push('C', options: [PushOption.preempt(_anySafePoint)]);

    await _waitOrFail(
      thirdTurnDone.future,
      'third turn (item C) was never processed — loop is stuck between turns',
    );

    loop.stop();
    final result = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(result.exitReason, isNull);
    expect(turnCount, 3, reason: 'expected 3 turns to be processed');
  });

  test('TestAttack_BusinessInterrupt_NoStore_ExitsWithoutPanic', () async {
    final interruptAgent = _InterruptAgent('no_store_test');

    final loop = _newAndRun(
      _config(genInput: _genInputConsumeAllWithMsg, prepareAgent: _prepareAgent(interruptAgent)),
    )..push('msg1');
    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');

    expect(
      exit.exitReason,
      isA<TurnLoopInterruptedException>(),
      reason: 'expected *InterruptError, got: ${exit.exitReason}',
    );
    expect(exit.interruptedItems, ['msg1']);
    expect(exit.checkpointAttempted, isFalse, reason: 'no store → no checkpoint attempt');
  });

  test('TestAttack_BusinessInterrupt_EmptyConsumed_NoCheckpoint', () async {
    final store = _TestStore();
    final interruptAgent = _InterruptAgent('idle_test');

    final loop = _newAndRun(
      _config(
        store: store,
        checkpointId: 'idle-cp',
        genInput: (ctx, loop, items) async => GenInputResult(
          input: AgentInput(messages: [Message.user('x')]),
        ),
        prepareAgent: _prepareAgent(interruptAgent),
      ),
    )..push('msg1');
    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');

    expect(
      exit.exitReason,
      isA<TurnLoopInterruptedException>(),
      reason: 'expected *InterruptError, got: ${exit.exitReason}',
    );
    expect(
      exit.interruptedItems,
      isEmpty,
      reason: 'consumed was empty → InterruptedItems should be empty',
    );
  });
}
