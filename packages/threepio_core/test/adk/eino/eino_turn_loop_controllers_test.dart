// Ports of eino `adk/turn_loop_test.go` (v0.9.22), second part (from
// TestPreemptController_BeginPushSnapshotsPlanningTurn to the end of the Go
// file), split over two Dart files: this one has the controllers, the option
// checks, the turn buffer, late items, checkpoints and the stop cause;
// `eino_turn_loop_controllers_loop_test.dart` has the loop integration tests
// (preempt, push strategy, UntilIdleFor, attacks, recursive propagation). The
// first part of the Go file (up to TestTurnLoop_TurnContext_PreemptedChannel)
// is ported in another file.
//
// Ported here (one `test` per Go test, same name):
//   TestPreemptController_* (21), TestCancelRequestState_* (7), TestStopController_* (12),
//   TestWithGracefulTimeout_NonPositive_Panics, TestWithPreempt_ZeroSafePoint_Panics,
//   TestWithPreemptTimeout_ZeroSafePoint_Panics, TestUntilIdleFor_NonPositive_Panics,
//   TestDeriveCheckpointAwareCancelContext_NilParent_ReturnsNil (adapted, see there),
//   TestAttack_TurnBuffer_WakeupDoesNotLoseItems, TestAttack_TurnBuffer_ClearWakeupPreventsSpuriousReturn,
//   TestTurnLoop_PushAfterStop_BufferedAsLateItems, TestTurnLoop_TakeLateItems_Idempotent,
//   TestTurnLoop_PushAfterTakeLateItems_Panics, TestTurnLoop_TakeLateItems_NeverCalled_NoImpact,
//   TestTurnLoop_CheckpointErr_SeparateFromExitReason,
//   TestTurnLoop_CheckpointAttempted_{FalseWhenNoStore,FalseOnErrorExit},
//   TestTurnLoop_StopConcurrentWithCallbackError_NoCheckpoint,
//   TestTurnLoop_DeleteWithoutCheckPointDeleter_NoOp, TestTurnLoop_StopWithSkipCheckpoint,
//   TestTurnLoop_StopWithSkipCheckpoint_DeletesStaleCheckpoint, TestTurnLoop_StopWithStopCause,
//   TestTurnLoop_StopCause_{EmptyWhenNoStop,InTurnContext,FirstNonEmptyWins},
//   TestTurnLoop_StopBeforeRun_{PushThenStop,StopThenPush}, TestTurnLoop_SkipCheckpoint_Sticky.
//
// Not portable:
// * TestNewTurnLoop_NilGenInput_Panics, TestNewTurnLoop_NilPrepareAgent_Panics: `genInput` and
//   `prepareAgent` are required, non-nullable parameters in Dart.
// * TestSaveTurnLoopCheckpoint_NilStore: Go's private `saveTurnLoopCheckpoint` has no Dart
//   counterpart; the Dart loop never tries to save without a store
//   (TestTurnLoop_CheckpointAttempted_FalseWhenNoStore checks that).
// * TestSetupBridgeStore_NilStore_Resume: the private `_setupBridgeStore` is unreachable with a
//   nil store and a resume (a resume needs a checkpoint read from the store).
// * The last assertion of TestPreemptController_RejectsInvalidTurnPhaseTransitions (a stale
//   pending request poked into the controller): `pending` has no setter, `PreemptRequest` has a
//   private constructor, and no public call leaves a request pending in the idle phase.
//
// Adapted because Dart is single-threaded: Go goroutine races become a bounded number of
// interleaved async calls; Go sleeps become completers or delays of at most 20 ms; Go's
// `waitOrFail` (a 2 s timer) polls in 1 ms steps instead of arming a long timer.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/cancel.dart';
import 'package:threepio_core/src/adk/eino/run_options.dart';
import 'package:threepio_core/src/adk/eino/turn_buffer.dart';
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

/// Go's `[]AgentCancelOption{WithAgentCancelMode(m), WithAgentCancelTimeout(d), WithRecursive()}`.
CancelArgs _args(
  Set<CancelSafePoint> safePoints, {
  Duration? timeout,
  bool recursive = false,
}) =>
    (safePoints: safePoints, timeout: timeout, recursive: recursive);

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

/// Port of `turnLoopMockAgent` as this file uses it: named "test", with no
/// events and no `runFunc`, so its run ends at once.
final class _MockAgent implements Agent {
  @override
  String get name => 'test';

  @override
  String get description => 'mock agent';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      StreamReader<AgentEvent>.fromIterable(const []);
}

/// Port of `turnLoopCancellableMockAgent` (without `onCancel`, which no test
/// of this file uses): [runFunc] gets a context whose cancel token is
/// cancelled once the run's cancel context is cancelled.
final class _CancellableAgent implements Agent {
  _CancellableAgent({required this.name, required this.runFunc});

  @override
  final String name;

  @override
  String get description => 'mock agent';

  final Future<AgentOutput> Function(RunContext ctx, AgentInput input) runFunc;

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
        if (cc.shouldCancel) own.cancel('agent canceled');
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

/// Port of `turnLoopCheckpointStore`.
class _TestStore implements CheckpointStore {
  final Map<String, Uint8List> m = {};

  @override
  Future<Uint8List?> get(String key) async => m[key];

  @override
  Future<void> set(String key, Uint8List value) async => m[key] = value;
}

/// Port of `deletableCheckpointStore`.
final class _DeletableStore extends _TestStore implements CheckpointDeleter {
  bool deleteCalled = false;
  String? deletedKey;

  @override
  Future<void> delete(String key) async {
    deleteCalled = true;
    deletedKey = key;
    m.remove(key);
  }
}

/// Port of `errorCheckpointStore` (only its `Set` error is used here).
final class _ErrorStore implements CheckpointStore {
  _ErrorStore({this.setError});

  final Object? setError;

  @override
  Future<Uint8List?> get(String key) async => null;

  @override
  Future<void> set(String key, Uint8List value) async {
    final error = setError;
    if (error != null) throw error;
  }
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

/// Port of `prepareTestAgent`.
Future<Agent> _prepareTestAgent(
  RunContext ctx,
  TurnLoop<String> loop,
  List<String> consumed,
) async =>
    _MockAgent();

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

Matcher _stateError(String message) =>
    throwsA(isA<StateError>().having((e) => e.message, 'message', message));

Matcher _argumentError(String message) =>
    throwsA(isA<ArgumentError>().having((e) => e.message, 'message', message));

void main() {
  // -------------------------------------------------------------------------
  // PreemptController
  // -------------------------------------------------------------------------

  test('TestPreemptController_BeginPushSnapshotsPlanningTurn', () {
    final c = PreemptController()..beginPlanningTurn();

    final snapshot = c.beginPush();
    c.endPush();

    expect(snapshot.hasTargetTurn, isTrue);
    expect(snapshot.turnId, isNot(0));
    expect(snapshot.ctx, isNull);
    expect(snapshot.turnContext, isNull);
  });

  test('TestPreemptController_BeginPushSnapshotsActiveTurn', () {
    final c = PreemptController();
    final ctx = RunContext.background()
        .withValue(const ContextKey<String>('testContextKey'), 'value');
    const tc = 'turn-context';

    c
      ..beginPlanningTurn()
      ..beginActiveTurn(ctx, tc);
    final snapshot = c.beginPush();
    c.endPush();

    expect(snapshot.hasTargetTurn, isTrue);
    expect(snapshot.turnId, isNot(0));
    expect(snapshot.ctx, same(ctx));
    expect(snapshot.turnContext, tc);
  });

  test('TestPreemptController_RequestPreemptIdleTurnAcksImmediately', () {
    final c = PreemptController();
    final snapshot = c.beginPush();
    c.endPush();

    final ack = Completer<void>();
    c.requestPreempt(snapshot, ack, _args(_afterChatModel));

    expect(ack.isCompleted, isTrue);
    expect(c.receivePreempt(), isNull);
  });

  test('TestPreemptController_RejectsInvalidTurnPhaseTransitions', () {
    final c = PreemptController();

    expect(
      () => c.beginActiveTurn(RunContext.background(), 'tc'),
      _stateError(
        'adk: preemptController.beginActiveTurn called while turn phase is idle; expected planning',
      ),
    );
    expect(
      c.abortPlanningTurn,
      _stateError(
        'adk: preemptController.abortPlanningTurn called while turn phase is idle; expected planning',
      ),
    );
    expect(
      c.endActiveTurn,
      _stateError(
        'adk: preemptController.endActiveTurn called while turn phase is idle; expected active',
      ),
    );

    c.beginPlanningTurn();
    expect(
      c.beginPlanningTurn,
      _stateError(
        'adk: preemptController.beginPlanningTurn called while turn phase is planning; expected idle',
      ),
    );
    c.abortPlanningTurn();
    // Not portable: Go then sets `c.pending` directly to check the "stale
    // pending preempt request" panic (see the file comment).
  });

  test('TestPreemptController_RequestPreemptForPlanningTurnIsConsumedAfterActivation', () {
    final c = PreemptController()..beginPlanningTurn();
    final snapshot = c.beginPush();
    c.endPush();

    final ack = Completer<void>();
    c.requestPreempt(snapshot, ack, _args(_afterChatModel));

    expect(c.receivePreempt(), isNull);
    expect(ack.isCompleted, isFalse);

    c.beginActiveTurn(RunContext.background(), 'tc');
    final req = c.receivePreempt();
    expect(req, isNotNull);
    expect(ack.isCompleted, isFalse);

    req!.ack();
    expect(ack.isCompleted, isTrue);
  });

  test('TestPreemptController_RequestPreemptForActiveTurnIsConsumedOnce', () {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc');
    final snapshot = c.beginPush();
    c.endPush();

    final ack = Completer<void>();
    c.requestPreempt(snapshot, ack, _args(_afterChatModel));

    final req = c.receivePreempt();
    expect(req, isNotNull);
    final args = req!.cancelArgs(DateTime.now());
    expect(args.safePoints, _afterChatModel);
    expect(ack.isCompleted, isFalse);

    expect(c.receivePreempt(), isNull);

    req.ack();
    expect(ack.isCompleted, isTrue);
  });

  test('TestPreemptController_AbortPlanningTurnAcksUnconsumedRequest', () {
    final c = PreemptController()..beginPlanningTurn();
    final snapshot = c.beginPush();
    c.endPush();

    final ack = Completer<void>();
    c.requestPreempt(snapshot, ack, _args(_afterChatModel));

    final req = c.abortPlanningTurn();
    expect(req, isNotNull);
    req!.ack();
    expect(ack.isCompleted, isTrue);

    expect(c.receivePreempt(), isNull);
  });

  test('TestPreemptController_EndActiveTurnAcksUnconsumedRequest', () {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc');
    final snapshot = c.beginPush();
    c.endPush();

    final ack = Completer<void>();
    c.requestPreempt(snapshot, ack, _args(_afterChatModel));

    final req = c.endActiveTurn();
    expect(req, isNotNull);
    req!.ack();
    expect(ack.isCompleted, isTrue);

    expect(c.receivePreempt(), isNull);
  });

  test('TestPreemptController_EndActiveTurnDoesNotAckConsumedRequest', () {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc');
    final snapshot = c.beginPush();
    c.endPush();

    final ack = Completer<void>();
    c.requestPreempt(snapshot, ack, _args(_afterChatModel));
    final req = c.receivePreempt();
    expect(req, isNotNull);

    expect(c.endActiveTurn(), isNull);
    expect(ack.isCompleted, isFalse);

    req!.ack();
    expect(ack.isCompleted, isTrue);
  });

  test('TestPreemptController_TargetTurnMismatchAcksImmediately', () {
    final c = PreemptController()..beginPlanningTurn();
    final snapshot = c.beginPush();
    c
      ..endPush()
      ..abortPlanningTurn()
      ..beginPlanningTurn();

    final ack = Completer<void>();
    c.requestPreempt(snapshot, ack, _args(_afterChatModel));

    expect(ack.isCompleted, isTrue);
    expect(c.receivePreempt(), isNull);
  });

  test('TestPreemptController_WaitForPushesBlocksUntilPushEnds', () async {
    final c = PreemptController()..beginPush();

    var waitDone = false;
    final waiting = c.waitForPushes().then((_) => waitDone = true);

    await _settle();
    expect(waitDone, isFalse, reason: 'waitForPushes should block while a push is in flight');

    c.endPush();
    await _waitOrFail(waiting, 'waitForPushes should unblock after endPush');
    expect(waitDone, isTrue);
  });

  test('TestPreemptController_MultipleRequestsBeforeReceiveMergeAcksAndUseMergedOpts', () {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc');
    final snapshot = c.beginPush();
    c.endPush();

    final ack1 = Completer<void>();
    final ack2 = Completer<void>();
    c
      ..requestPreempt(snapshot, ack1, _args(_afterChatModel, timeout: const Duration(minutes: 1)))
      ..requestPreempt(
        snapshot,
        ack2,
        _args(_afterToolCalls, recursive: true, timeout: const Duration(seconds: 1)),
      );

    final req = c.receivePreempt();
    expect(req, isNotNull);
    final args = req!.cancelArgs(DateTime.now());
    expect(args.safePoints, _anySafePoint);
    expect(args.recursive, isTrue);
    expect(args.timeout, isNotNull);
    expect(args.timeout! <= const Duration(seconds: 1), isTrue);

    expect(ack1.isCompleted, isFalse);
    expect(ack2.isCompleted, isFalse);
    req.ack();
    expect(ack1.isCompleted, isTrue);
    expect(ack2.isCompleted, isTrue);
  });

  test('TestPreemptController_ConcurrentPreemptRequestsMergeAndAck', () async {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc');
    final snapshot = c.beginPush();
    c.endPush();

    // Go: 50 goroutines; here 50 interleaved async calls.
    const requestCount = 50;
    final acks = List.generate(requestCount, (_) => Completer<void>());
    await Future.wait([
      for (var i = 0; i < requestCount; i++)
        Future<void>(() => c.requestPreempt(snapshot, acks[i], _args(_afterChatModel))),
    ]);

    final req = c.receivePreempt();
    expect(req, isNotNull);
    req!.ack();
    for (final ack in acks) {
      expect(ack.isCompleted, isTrue);
    }
  });

  test('TestPreemptController_CloseForLoopExitDuringDelayedPreempt', () async {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc');

    final snapshot = c.beginPush();
    c
      ..endPush()
      ..closeForLoopExit();

    final ack = Completer<void>();
    final done = Future<void>(() => c.requestPreempt(snapshot, ack, _args(_afterChatModel)));

    await _waitOrFail(done, 'requestPreempt after closeForLoopExit must not deadlock');
    expect(ack.isCompleted, isTrue);
  });

  test('TestPreemptController_RequestPreemptAfterCloseForLoopExit', () {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc');
    final snapshot = c.beginPush();
    c
      ..endPush()
      ..closeForLoopExit();

    final ack = Completer<void>();
    c.requestPreempt(snapshot, ack, _args(_afterToolCalls));
    expect(ack.isCompleted, isTrue);

    expect(c.receivePreempt(), isNull);
  });

  test('TestPreemptController_ConcurrentBeginPushAndWaitForPushes', () async {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc');

    // Go: 100 goroutines; here 100 interleaved async pushes.
    const pushCount = 100;
    final pushes = [
      for (var i = 0; i < pushCount; i++)
        Future<void>(() async {
          c.beginPush();
          await Future<void>.delayed(Duration.zero);
          c.endPush();
        }),
    ];

    final waitDone = Future<void>(c.waitForPushes);

    await Future.wait(pushes);

    await _waitOrFail(waitDone, 'waitForPushes deadlocked with concurrent beginPush/endPush');
  });

  test('TestPreemptController_RequestPreemptWithNilAck', () {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc');
    final snapshot = c.beginPush();
    c.endPush();

    expect(() => c.requestPreempt(snapshot, null, _args(_afterChatModel)), returnsNormally);

    final req = c.receivePreempt();
    expect(req, isNotNull);
    expect(req!.ack, returnsNormally);
  });

  test('TestPreemptController_MergeImmediateOverridesTimeout', () {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc');
    final snapshot = c.beginPush();
    c.endPush();

    final ack1 = Completer<void>();
    c.requestPreempt(snapshot, ack1, _args(_afterToolCalls, timeout: const Duration(seconds: 10)));

    final ack2 = Completer<void>();
    c.requestPreempt(snapshot, ack2, _args(const {}));

    final req = c.receivePreempt();
    expect(req, isNotNull);

    final args = req!.cancelArgs(DateTime.now());
    expect(args.safePoints, isEmpty);
    expect(args.timeout, isNull, reason: 'CancelImmediate merge should clear timeout');

    req.ack();
    expect(ack1.isCompleted, isTrue);
    expect(ack2.isCompleted, isTrue);
  });

  test('TestPreemptController_DelayedPreemptTargetGoneBetweenTurns', () {
    final c = PreemptController()
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc1');
    final oldSnapshot = c.beginPush();
    c.endPush();
    expect(c.endActiveTurn(), isNull);

    c
      ..beginPlanningTurn()
      ..beginActiveTurn(RunContext.background(), 'tc2');

    final ack = Completer<void>();
    c.requestPreempt(oldSnapshot, ack, _args(_afterChatModel));
    expect(ack.isCompleted, isTrue);

    expect(c.receivePreempt(), isNull, reason: 'stale preempt must not affect new turn');

    c.endActiveTurn();
  });

  test('TestPreemptController_EndPushWithoutBeginPushPanics', () {
    final c = PreemptController();

    expect(
      c.endPush,
      _stateError('adk: preemptController.endPush called without matching beginPush'),
    );
  });

  test('TestPreemptController_BeginActiveTurnNotifiesExistingPending', () async {
    final c = PreemptController()..beginPlanningTurn();
    final snapshot = c.beginPush();
    c.endPush();

    final ack = Completer<void>();
    c.requestPreempt(snapshot, ack, _args(_afterChatModel));

    expect(c.receivePreempt(), isNull);

    c.beginActiveTurn(RunContext.background(), 'tc');

    // Go reads the buffered `notify` channel; the Dart notification waits for
    // the watcher and is delivered in a microtask.
    final notified = Completer<void>();
    c.attachWatcher(() => _completeOnce(notified));
    await _waitOrFail(
      notified.future,
      'beginActiveTurn should notify watcher when there is a pending request',
    );
    c.detachWatcher();

    final req = c.receivePreempt();
    expect(req, isNotNull);
    req!.ack();
    expect(ack.isCompleted, isTrue);
  });

  // -------------------------------------------------------------------------
  // cancelRequestState
  // -------------------------------------------------------------------------

  test('TestCancelRequestState_ImmediateDominatesSafePointModes', () {
    final now = DateTime.now();
    final state = CancelRequestState(_args(_afterChatModel, timeout: const Duration(minutes: 1)), now)
      ..merge(_args(const {}), now);

    final args = state.cancelArgs(now);
    expect(args.safePoints, isEmpty);
    expect(args.timeout, isNull);
  });

  test('TestCancelRequestState_NilMergeDoesNotCreateCancelIntent', () {
    final now = DateTime.now();
    final state = CancelRequestState(_args(_afterChatModel), now)..merge(null, now);

    expect(state.cancelArgs(now).safePoints, _afterChatModel);
  });

  test('TestCancelRequestState_EmptyMergeMeansExplicitImmediate', () {
    final now = DateTime.now();
    // Go: an empty, non-nil option slice.
    final state = CancelRequestState(_args(_afterChatModel), now)..merge(_args(const {}), now);

    expect(state.cancelArgs(now).safePoints, isEmpty);
  });

  test('TestCancelRequestState_SafePointModesJoin', () {
    final now = DateTime.now();
    final state = CancelRequestState(_args(_afterChatModel), now)..merge(_args(_afterToolCalls), now);

    expect(state.cancelArgs(now).safePoints, _anySafePoint);
  });

  test('TestCancelRequestState_RecursiveIsMonotonic', () {
    final now = DateTime.now();
    final state = CancelRequestState(_args(_afterChatModel), now)
      ..merge(_args(_afterToolCalls, recursive: true), now)
      ..merge(_args(_afterChatModel), now);

    expect(state.cancelArgs(now).recursive, isTrue);
  });

  test('TestCancelRequestState_TimeoutUsesEarliestDeadline', () {
    final now = DateTime.now();
    final later = now.add(const Duration(milliseconds: 100));
    final state = CancelRequestState(
      _args(_afterChatModel, timeout: const Duration(seconds: 10)),
      now,
    )..merge(_args(_afterToolCalls, timeout: const Duration(seconds: 1)), later);

    final timeout = state.cancelArgs(later).timeout;
    expect(timeout, isNotNull);
    expect(timeout! <= const Duration(seconds: 1), isTrue);
  });

  test('TestCancelRequestState_ExpiredTimeoutConvertsToImmediate', () {
    final now = DateTime.now();
    // Go: 1 ns; a Dart Duration counts microseconds.
    final state = CancelRequestState(
      _args(_afterChatModel, timeout: const Duration(microseconds: 1)),
      now,
    );

    final args = state.cancelArgs(now.add(const Duration(seconds: 1)));
    expect(args.safePoints, isEmpty);
    expect(args.timeout, isNull);
  });

  // -------------------------------------------------------------------------
  // stopController
  // -------------------------------------------------------------------------

  test('TestStopController_BareStopCommitsWithoutCancelRequest', () {
    final c = StopController();

    final decision = c.requestStop(StopConfig());

    expect(decision.commit, isTrue);
    expect(c.isCommitted, isTrue);
    c.beginActiveTurn();
    expect(c.receiveCancel(), isNull);
  });

  test('TestStopController_UntilIdleForDoesNotCreateCancelRequest', () {
    final c = StopController();

    final decision = c.requestStop(StopConfig()..idleFor = const Duration(seconds: 1));

    expect(decision.commit, isFalse);
    expect(decision.wakeIdle, isTrue);
    expect(c.idleDuration, const Duration(seconds: 1));
    expect(c.isCommitted, isFalse);
    c.beginActiveTurn();
    expect(c.receiveCancel(), isNull);
  });

  test('TestStopController_CancelOptsDroppedWhenCombinedWithUntilIdleFor', () {
    final c = StopController();

    final decision = c.requestStop(
      StopConfig()
        ..idleFor = const Duration(seconds: 1)
        ..cancel = _args(const {}, recursive: true),
    );

    expect(decision.commit, isFalse);
    c.beginActiveTurn();
    expect(c.receiveCancel(), isNull);
  });

  test('TestStopController_ImmediateStopCreatesPendingCancelForActiveTurn', () {
    final c = StopController()..beginActiveTurn();

    final decision = c.requestStop(StopConfig()..cancel = _args(const {}, recursive: true));

    expect(decision.commit, isTrue);
    final req = c.receiveCancel();
    expect(req, isNotNull);
    final args = req!.cancelArgs(DateTime.now());
    expect(args.safePoints, isEmpty);
    expect(args.recursive, isTrue);
  });

  test('TestStopController_StopBeforeWatcherStartsConsumedAfterBeginActiveTurn', () {
    final c = StopController();

    final decision = c.requestStop(StopConfig()..cancel = _args(const {}, recursive: true));
    expect(decision.commit, isTrue);

    c.beginActiveTurn();
    final req = c.receiveCancel();
    expect(req, isNotNull);
    expect(req!.cancelArgs(DateTime.now()).safePoints, isEmpty);
  });

  test('TestStopController_EndActiveTurnDropsUnconsumedCancel', () {
    final c = StopController()
      ..beginActiveTurn()
      ..requestStop(StopConfig()..cancel = _args(const {}, recursive: true));

    final req = c.endActiveTurn();

    expect(req, isNotNull);
    expect(c.receiveCancel(), isNull);
  });

  test('TestStopController_RepeatedStopsMergeWithoutDeescalation', () {
    final c = StopController()
      ..beginActiveTurn()
      ..requestStop(StopConfig()..cancel = _args(const {}, recursive: true))
      ..requestStop(StopConfig())
      ..requestStop(StopConfig()..cancel = _args(_anySafePoint, recursive: true));

    final req = c.receiveCancel();
    expect(req, isNotNull);
    final args = req!.cancelArgs(DateTime.now());
    expect(args.safePoints, isEmpty);
    expect(args.recursive, isTrue);
  });

  test('TestStopController_RepeatedStopsUseSharedCancelMergeState', () {
    final c = StopController()
      ..beginActiveTurn()
      ..requestStop(StopConfig()..cancel = _args(_afterChatModel))
      ..requestStop(StopConfig()..cancel = _args(_afterToolCalls));

    final req = c.receiveCancel();
    expect(req, isNotNull);
    expect(req!.cancelArgs(DateTime.now()).safePoints, _anySafePoint);
  });

  test('TestStopController_StopCauseFirstNonEmptyWins', () {
    final c = StopController()
      ..requestStop(StopConfig())
      ..requestStop(StopConfig()..cause = 'first')
      ..requestStop(StopConfig()..cause = 'second');

    expect(c.cause, 'first');
  });

  test('TestStopController_SkipCheckpointSticky', () {
    final c = StopController()
      ..requestStop(StopConfig()..skipCheckpoint = true)
      ..requestStop(StopConfig());

    expect(c.skipCheckpoint, isTrue);
  });

  test('TestStopController_ConcurrentStopRequestsRaceSafe', () async {
    final c = StopController()..beginActiveTurn();

    // Go: 20 goroutines; here 20 interleaved async calls.
    await Future.wait([
      for (var i = 0; i < 20; i++)
        Future<void>(() {
          switch (i % 5) {
            case 0:
              c.requestStop(StopConfig());
            case 1:
              c.requestStop(StopConfig()..cancel = _args(const {}, recursive: true));
            case 2:
              c.requestStop(
                StopConfig()
                  ..cancel = _args(
                    _afterChatModel,
                    timeout: const Duration(seconds: 1),
                    recursive: true,
                  ),
              );
            case 3:
              c.requestStop(StopConfig()..idleFor = const Duration(seconds: 1));
            case 4:
              c.requestStop(
                StopConfig()
                  ..skipCheckpoint = true
                  ..cause = 'cause',
              );
          }
        }),
    ]);

    expect(c.isCommitted, isTrue);
    expect(c.skipCheckpoint, isTrue);
  });

  test('TestStopController_CloseForLoopExitClearsPendingCancel', () {
    final c = StopController()
      ..beginActiveTurn()
      ..requestStop(StopConfig()..cancel = _args(const {}, recursive: true))
      ..closeForLoopExit();

    expect(c.receiveCancel(), isNull);
  });

  // -------------------------------------------------------------------------
  // Option arguments
  // -------------------------------------------------------------------------

  test('TestWithGracefulTimeout_NonPositive_Panics', () {
    expect(
      () => StopOption.gracefulTimeout(Duration.zero),
      _argumentError('adk: WithGracefulTimeout: gracePeriod must be positive'),
    );
    expect(
      () => StopOption.gracefulTimeout(const Duration(seconds: -1)),
      _argumentError('adk: WithGracefulTimeout: gracePeriod must be positive'),
    );
  });

  // Go's hint names its own constants (AfterToolCalls, AfterChatModel,
  // AnySafePoint); the Dart message names the Dart ones, so only the common
  // prefix is pinned.
  test('TestWithPreempt_ZeroSafePoint_Panics', () {
    expect(
      () => PushOption<String>.preempt(const {}),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          startsWith('adk: SafePoint must not be zero; use '),
        ),
      ),
    );
  });

  test('TestWithPreemptTimeout_ZeroSafePoint_Panics', () {
    expect(
      () => PushOption<String>.preemptTimeout(const {}, const Duration(seconds: 1)),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          startsWith('adk: SafePoint must not be zero; use '),
        ),
      ),
    );
  });

  test('TestUntilIdleFor_NonPositive_Panics', () {
    expect(
      () => StopOption.untilIdleFor(Duration.zero),
      _argumentError('adk: UntilIdleFor: duration must be positive'),
    );
    expect(
      () => StopOption.untilIdleFor(const Duration(seconds: -1)),
      _argumentError('adk: UntilIdleFor: duration must be positive'),
    );
  });

  test('TestDeriveCheckpointAwareCancelContext_NilParent_ReturnsNil', () {
    // Adapted: a method cannot be called on a null CancelContext in Dart; the
    // null-safe entry point derives nothing without a parent context.
    expect(deriveCheckpointAwareSubAgentCancelContext(RunContext.background(), const []), isNull);
  });

  test('TestAttack_TurnBuffer_WakeupDoesNotLoseItems', () async {
    final tb = TurnBuffer<String>()
      ..send('a')
      ..send('b')
      ..wakeup()
      ..send('c');

    final got = <String>[];
    for (var i = 0; i < 3; i++) {
      final (ok, value) = await tb.receive();
      expect(ok, isTrue);
      got.add(value!);
    }

    expect(got, ['a', 'b', 'c'], reason: 'Wakeup must not cause items to be lost');
  });

  test('TestAttack_TurnBuffer_ClearWakeupPreventsSpuriousReturn', () async {
    final tb = TurnBuffer<String>()
      ..wakeup()
      ..clearWakeup();

    String? received;
    final receiving = tb.receive().then((result) {
      final (ok, value) = result;
      if (ok) received = value;
    });

    // Go sleeps 50 ms.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    tb.send('real');

    await _waitOrFail(receiving, 'Receive blocked forever despite Send');
    expect(received, 'real', reason: 'ClearWakeup should prevent spurious empty return');
  });

  // -------------------------------------------------------------------------
  // Late items, checkpoints, stop cause
  // -------------------------------------------------------------------------

  test('TestTurnLoop_PushAfterStop_BufferedAsLateItems', () async {
    final processed = Completer<String>();

    final loop = _newAndRun(
      _config(
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: _prepareTestAgent,
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          if (!processed.isCompleted) processed.complete(tc.consumed[0]);
        },
      ),
    )..push('msg1');
    await _waitOrFail(processed.future, 'msg1 was not processed');
    loop.stop();
    final result = await loop.wait();

    final ok1 = loop.push('late1').accepted;
    final ok2 = loop.push('late2').accepted;
    final ok3 = loop.push('late3').accepted;
    expect(ok1, isFalse);
    expect(ok2, isFalse);
    expect(ok3, isFalse);

    expect(result.takeLateItems(), ['late1', 'late2', 'late3']);
  });

  test('TestTurnLoop_TakeLateItems_Idempotent', () async {
    final loop = TurnLoop<String>(
      _config(genInput: _genInputConsumeAll, prepareAgent: _prepareTestAgent),
    )
      ..push('a')
      ..stop()
      ..run(RunContext.background());
    final result = await loop.wait();

    loop.push('late1');

    final first = result.takeLateItems();
    final second = result.takeLateItems();
    final third = result.takeLateItems();

    expect(first, ['late1']);
    expect(second, first, reason: 'subsequent calls should return the same slice');
    expect(third, first, reason: 'subsequent calls should return the same slice');
  });

  test('TestTurnLoop_PushAfterTakeLateItems_Panics', () async {
    final loop = TurnLoop<String>(
      _config(genInput: _genInputConsumeAll, prepareAgent: _prepareTestAgent),
    )
      ..push('a')
      ..stop()
      ..run(RunContext.background());
    final result = await loop.wait();

    result.takeLateItems();

    expect(() => loop.push('too-late'), _stateError('TurnLoop: Push called after TakeLateItems'));
  });

  test('TestTurnLoop_TakeLateItems_NeverCalled_NoImpact', () async {
    final loop = TurnLoop<String>(
      _config(genInput: _genInputConsumeAll, prepareAgent: _prepareTestAgent),
    )
      ..push('a')
      ..push('b')
      ..stop()
      ..run(RunContext.background());
    final result = await loop.wait();

    expect(result.unhandledItems, contains('b'));
    expect(result.exitReason, isNull);
  });

  test('TestTurnLoop_CheckpointErr_SeparateFromExitReason', () async {
    final saveStore = _ErrorStore(setError: Exception('storage unavailable'));

    final loop = TurnLoop<String>(
      _config(
        store: saveStore,
        checkpointId: 'cp-separate-err',
        genInput: _genInputConsumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    )
      ..push('a')
      ..stop()
      ..run(RunContext.background());
    final result = await loop.wait();

    expect(result.exitReason, isNull);
    expect(result.checkpointAttempted, isTrue);
    expect(result.checkpointError, isNotNull);
    expect('${result.checkpointError}', contains('storage unavailable'));
  });

  test('TestTurnLoop_CheckpointAttempted_FalseWhenNoStore', () async {
    final loop = TurnLoop<String>(
      _config(genInput: _genInputConsumeAll, prepareAgent: _prepareTestAgent),
    )
      ..push('a')
      ..stop()
      ..run(RunContext.background());
    final result = await loop.wait();

    expect(result.checkpointAttempted, isFalse);
    expect(result.checkpointError, isNull);
  });

  test('TestTurnLoop_CheckpointAttempted_FalseOnErrorExit', () async {
    final store = _TestStore();
    final genInputErr = Exception('gen input failed');

    final firstTurnDone = Completer<void>();
    var callCount = 0;
    final loop = _newAndRun(
      _config(
        store: store,
        checkpointId: 'cp-err-exit',
        genInput: (ctx, loop, items) async {
          if (++callCount > 1) throw genInputErr;
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        prepareAgent: _prepareTestAgent,
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          firstTurnDone.complete();
        },
      ),
    )..push('msg1');
    await _waitOrFail(firstTurnDone.future, 'first turn did not complete');
    loop.push('msg2');
    final result = await _waitOrFail(loop.wait(), 'loop did not exit');

    expect(result.exitReason, same(genInputErr));
    expect(result.checkpointAttempted, isFalse);
    expect(result.checkpointError, isNull);
  });

  test('TestTurnLoop_StopConcurrentWithCallbackError_NoCheckpoint', () async {
    final store = _TestStore();
    const cpId = 'stop-concurrent-err';

    final prepareErr = Exception('prepare agent failed');
    final firstTurnDone = Completer<void>();
    final stopCalled = Completer<void>();
    var prepareCount = 0;

    final loop = _newAndRun(
      _config(
        store: store,
        checkpointId: cpId,
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: (ctx, loop, consumed) async {
          if (++prepareCount > 1) {
            // Wait until stop() has been called, so the stop is committed.
            await stopCalled.future;
            throw prepareErr;
          }
          return _MockAgent();
        },
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          firstTurnDone.complete();
        },
      ),
    )..push('msg1');
    await _waitOrFail(firstTurnDone.future, 'first turn did not complete');
    loop.push('msg2');

    // Go: a goroutine stops the loop and then lets prepareAgent fail.
    unawaited(
      Future<void>(() {
        loop.stop();
        stopCalled.complete();
      }),
    );

    final result = await _waitOrFail(loop.wait(), 'loop did not exit');

    if (result.exitReason != null && result.exitReason is! AgentRunCancelledException) {
      expect(result.exitReason, same(prepareErr));
      expect(
        result.checkpointAttempted,
        isFalse,
        reason: 'should not checkpoint when exit is caused by callback error',
      );
    }
  });

  test('TestTurnLoop_DeleteWithoutCheckPointDeleter_NoOp', () async {
    final store = _TestStore();
    const cpId = 'no-deleter';

    final loop1 = TurnLoop<String>(
      _config(
        store: store,
        checkpointId: cpId,
        genInput: _genInputConsumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    )
      ..push('a')
      ..stop()
      ..run(RunContext.background());
    await loop1.wait();

    expect(store.m.containsKey(cpId), isTrue, reason: 'checkpoint should be saved');

    // The second loop exits through a cancelled context: it tries to delete
    // the stale checkpoint, but the store is no CheckpointDeleter.
    final token2 = CancelToken();
    final loop2 = TurnLoop<String>(
      _config(
        store: store,
        checkpointId: cpId,
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: _prepareTestAgent,
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          token2.cancel();
        },
      ),
    )
      ..push('b')
      ..run(RunContext.background(cancelToken: token2));
    await _waitOrFail(loop2.wait(), 'loop2 did not exit');

    expect(
      store.m.containsKey(cpId),
      isTrue,
      reason: 'checkpoint should still exist without CheckPointDeleter',
    );
    expect(store.m[cpId], isNotNull, reason: 'checkpoint should not be set to nil');
  });

  test('TestTurnLoop_StopWithSkipCheckpoint', () async {
    final store = _TestStore();
    const cpId = 'skip-cp-session';

    final loop = TurnLoop<String>(
      _config(
        store: store,
        checkpointId: cpId,
        genInput: _genInputConsumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    )
      ..push('a')
      ..push('b')
      ..stop(options: [const StopOption.skipCheckpoint()])
      ..run(RunContext.background());

    final exit = await loop.wait();
    expect(exit.exitReason, isNull);
    expect(
      exit.checkpointAttempted,
      isFalse,
      reason: 'checkpoint should be skipped when WithSkipCheckpoint is used',
    );

    expect(
      store.m.containsKey(cpId),
      isFalse,
      reason: 'no checkpoint should be saved when WithSkipCheckpoint is used',
    );
  });

  test('TestTurnLoop_StopWithSkipCheckpoint_DeletesStaleCheckpoint', () async {
    final store = _DeletableStore();
    const cpId = 'skip-stale-session';

    final loop1 = TurnLoop<String>(
      _config(
        store: store,
        checkpointId: cpId,
        genInput: _genInputConsumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    )
      ..push('a')
      ..stop()
      ..run(RunContext.background());
    final exit1 = await loop1.wait();
    expect(exit1.checkpointAttempted, isTrue);

    expect(store.m.containsKey(cpId), isTrue, reason: 'first loop should save checkpoint');

    final loop2 = TurnLoop<String>(
      _config(
        store: store,
        checkpointId: cpId,
        genInput: _genInputConsumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    )
      ..push('b')
      ..stop(options: [const StopOption.skipCheckpoint()])
      ..run(RunContext.background());
    final exit2 = await loop2.wait();
    expect(exit2.checkpointAttempted, isFalse, reason: 'second loop should skip checkpoint');

    expect(
      store.deleteCalled,
      isTrue,
      reason: 'stale checkpoint should be deleted when SkipCheckpoint is used',
    );
    expect(store.deletedKey, cpId);
  });

  test('TestTurnLoop_StopWithStopCause', () async {
    const cause = 'user session timeout';

    final loop = _newAndRun(
      _config(genInput: _genInputConsumeAll, prepareAgent: _prepareTestAgent),
    )
      ..push('a')
      ..stop(options: [const StopOption.cause(cause)]);

    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(exit.stopCause, cause);
  });

  test('TestTurnLoop_StopCause_EmptyWhenNoStop', () async {
    final loop = _newAndRun(
      _config(genInput: _genInputConsumeAll, prepareAgent: _prepareTestAgent),
    )..stop();
    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(exit.stopCause, isEmpty);
  });

  test('TestTurnLoop_StopCause_InTurnContext', () async {
    const cause = 'business shutdown';
    final gotCause = Completer<String>();
    final agentStarted = Completer<void>();

    final loop = _newAndRun(
      _config(
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: _prepareSlowAgent,
        onAgentEvents: (ctx, tc, events) async {
          agentStarted.complete();
          await _waitOrFail(tc.stopped, 'timed out waiting for Stopped channel');
          gotCause.complete(tc.stopCause);
          await _drain(events);
        },
      ),
    )..push('msg1');
    await agentStarted.future;
    loop.stop(options: [const StopOption.immediate(), const StopOption.cause(cause)]);

    final c = await _waitOrFail(gotCause.future, 'timed out waiting for StopCause in TurnContext');
    expect(c, cause);

    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(exit.stopCause, cause);
  });

  test('TestTurnLoop_StopCause_FirstNonEmptyWins', () async {
    final agentStarted = Completer<void>();

    final loop = _newAndRun(
      _config(
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: _prepareSlowAgent,
        onAgentEvents: (ctx, tc, events) async {
          agentStarted.complete();
          await _drain(events);
        },
      ),
    )..push('msg1');
    await agentStarted.future;
    loop
      ..stop(options: [const StopOption.graceful(), const StopOption.cause('first cause')])
      ..stop(options: [const StopOption.cause('second cause')]);

    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(exit.stopCause, 'first cause', reason: 'first non-empty StopCause should win');
  });

  test('TestTurnLoop_StopBeforeRun_PushThenStop', () async {
    var called = false;
    final loop = TurnLoop<String>(
      _config(
        genInput: (ctx, loop, items) async {
          called = true;
          fail('GenInput should not be called when Stop is called before Run');
        },
        prepareAgent: (ctx, loop, consumed) async {
          called = true;
          fail('PrepareAgent should not be called when Stop is called before Run');
        },
      ),
    );

    expect(loop.push('item1').accepted, isTrue);
    expect(loop.push('item2').accepted, isTrue);

    loop
      ..stop()
      ..run(RunContext.background());
    final result = await loop.wait();

    expect(called, isFalse);
    expect(result.exitReason, isNull);
    expect(result.unhandledItems, ['item1', 'item2']);
    expect(result.interruptedItems, isEmpty);
    expect(result.takeLateItems(), isEmpty);
  });

  test('TestTurnLoop_StopBeforeRun_StopThenPush', () async {
    var called = false;
    final loop = TurnLoop<String>(
      _config(
        genInput: (ctx, loop, items) async {
          called = true;
          fail('GenInput should not be called when Stop is called before Run');
        },
        prepareAgent: (ctx, loop, consumed) async {
          called = true;
          fail('PrepareAgent should not be called when Stop is called before Run');
        },
      ),
    )..stop();

    expect(loop.push('item1').accepted, isFalse);
    expect(loop.push('item2').accepted, isFalse);

    loop.run(RunContext.background());
    final result = await loop.wait();

    expect(called, isFalse);
    expect(result.exitReason, isNull);
    expect(result.unhandledItems, isEmpty);
    expect(result.interruptedItems, isEmpty);
    expect(result.takeLateItems(), ['item1', 'item2']);
  });

  test('TestTurnLoop_SkipCheckpoint_Sticky', () async {
    final agentStarted = Completer<void>();

    final store = _TestStore();
    const cpId = 'sticky-skip-session';

    final loop = _newAndRun(
      _config(
        store: store,
        checkpointId: cpId,
        genInput: _genInputConsumeAllWithMsg,
        prepareAgent: _prepareSlowAgent,
        onAgentEvents: (ctx, tc, events) async {
          agentStarted.complete();
          await _drain(events);
        },
      ),
    )..push('msg1');
    await agentStarted.future;
    loop
      ..stop(options: [const StopOption.graceful(), const StopOption.skipCheckpoint()])
      ..stop();

    final exit = await _waitOrFail(loop.wait(), 'loop did not exit');
    expect(
      exit.checkpointAttempted,
      isFalse,
      reason: 'SkipCheckpoint should be sticky across multiple Stop calls',
    );

    expect(
      store.m.containsKey(cpId),
      isFalse,
      reason: 'no checkpoint should be saved when SkipCheckpoint was set in any Stop call',
    );
  });
}
