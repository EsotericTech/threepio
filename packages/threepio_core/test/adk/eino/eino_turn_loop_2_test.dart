// Port of eino `adk/turn_loop_test.go` (v0.9.22), second part: its tests
// from TestTurnLoop_CheckpointIDWithoutStore_FreshStart (line 1874) to
// TestTurnLoop_TurnContext_PreemptedChannel (line 3149), with the helpers of
// lines 1–237. The first part (from TestTurnLoop_StopIsIdempotent) is in
// `eino_turn_loop_test.dart`, whose header lists the adaptations; the rest of
// the Go file (from TestPreemptController_BeginPushSnapshotsPlanningTurn) is
// ported elsewhere.
//
// Ported here: TestTurnLoop_CheckpointIDWithoutStore_FreshStart,
// _CheckpointNotFound_FreshStart, _CheckpointEmptyData_TreatedAsNoCheckpoint,
// _CheckpointLoadError_ReturnsError, _CheckpointCorruptData_ReturnsError,
// _CheckpointSaveError_ReturnsError, _StaleCheckpointDeletion_OnCleanResume,
// _CheckpointDeleter_CalledOnContextCancel, _GenResumeNil_Error,
// _SameCheckpointID_OverwritePattern, _CheckpointHasRunnerStateButEmptyBytes,
// _GenResumeReturnsError, _ResumeWaitsForInFlightPushBeforePlanning (adapted,
// see the test), _CheckpointSaveError_MergesWithExistingError,
// _ResumeWithParams, _ResumeInterruptAgain_PreservesEnableStreamingCheckpoint
// (its runner-checkpoint check through a third loop, see the test),
// _TargetedResume_TimeoutEscalationReplacesCheckpoint,
// _Stop_EscalatesCancelMode, _DefaultOnAgentEvents_ErrorPropagation,
// _OnAgentEventsError, _StopCallFromGenInput, _PushFromOnAgentEvents,
// TestNewTurnLoop_PushBeforeRun, _WaitBeforeRun, _RunIsIdempotent,
// _ConcurrentPushAndRun, TestTurnLoop_RunCtx_Propagation,
// _TurnContext_PreemptedChannel. Not ported: none.
//
// Checkpoints are JSON: where the Go test reads or writes a checkpoint with
// the private (un)marshalTurnLoopCheckpoint, this file uses the JSON envelope
// the loop writes (`kind`, `has_runner_state`, `runner_checkpoint`,
// `unhandled_items`, `canceled_items`).
@Timeout(Duration(seconds: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/cancel.dart';
import 'package:threepio_core/src/adk/eino/run_options.dart';

// ---------------------------------------------------------------------------
// Helpers (Go lines 1–237, plus cancel_test.go's cancelTestChatModel).
// ---------------------------------------------------------------------------

typedef _RunFunc = Future<AgentOutput?> Function(RunContext ctx, AgentInput input);

/// Port of `turnLoopMockAgent` (its `events` are not used in this file):
/// sends no event, or the result of [runFunc].
final class _MockAgent implements Agent {
  _MockAgent({this.agentName = 'test', this.runFunc});

  final String agentName;
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

/// Port of `turnLoopCancellableMockAgent` (its `onCancel` is not used in
/// this file): [runFunc] gets a context whose token is cancelled when the
/// run's cancel context asks for a cancel.
final class _CancellableAgent implements Agent {
  _CancellableAgent({required this.runFunc});

  final _RunFunc runFunc;

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
          if (requested) own.cancel('context canceled');
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

/// Port of `errorCheckpointStore`.
final class _ErrorStore implements CheckpointStore {
  _ErrorStore({this.getErr, this.setErr});

  final Exception? getErr;
  final Exception? setErr;

  @override
  Future<Uint8List?> get(String key) async {
    final error = getErr;
    if (error != null) throw error;
    return null;
  }

  @override
  Future<void> set(String key, Uint8List value) async {
    final error = setErr;
    if (error != null) throw error;
  }
}

/// A [_Store] whose `get` waits for [gate] once it is set.
final class _GatedStore extends _Store {
  final Completer<void> getEntered = Completer<void>();
  Completer<void>? gate;

  @override
  Future<Uint8List?> get(String key) async {
    final wait = gate;
    if (wait != null) {
      _close(getEntered);
      await wait.future;
    }
    return super.get(key);
  }
}

/// Port of `turnLoopStopModeProbeAgent`: hands out its cancel context, and
/// once a cancel is asked for, waits until it is immediate and fails with the
/// cancel error.
final class _StopModeProbeAgent implements Agent {
  final Completer<CancelContext> ccCh = Completer<CancelContext>();

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
    ccCh.complete(cc);
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(() async {
      try {
        if (!await _cancelRequested(cc)) return;
        for (var i = 0; i < 3000; i++) {
          if (cc.mode.isEmpty) {
            writer.send(AgentEvent(error: cc.createCancelError()));
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }
}

/// Port of interrupt_test.go's `myAgent`.
final class _MyAgent implements ResumableAgent {
  _MyAgent({this.runFn, this.resumeFn});

  final StreamReader<AgentEvent> Function(RunContext ctx, AgentInput input)? runFn;
  final StreamReader<AgentEvent> Function(RunContext ctx, ResumeInfo info)? resumeFn;

  @override
  String get name => 'myAgent';

  @override
  String get description => 'myAgent description';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      runFn!(ctx, input);

  @override
  StreamReader<AgentEvent> resume(
    RunContext ctx,
    ResumeInfo info, {
    List<AgentRunOption> options = const [],
  }) =>
      resumeFn!(ctx, info);
}

/// Port of `turnLoopTargetedResumeTimeoutModel`: call 1 asks for `ask_user`,
/// call 2 streams "partial" and then waits for [release], call 3 answers.
final class _TargetedResumeTimeoutModel extends BaseChatModel {
  int calls = 0;
  final Completer<void> secondStarted = Completer<void>();
  final Completer<void> thirdStarted = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    final reader = await stream(input, options: options);
    try {
      final message = await reader.nextOrNull();
      if (message == null) throw StateError('EOF');
      return message;
    } finally {
      await reader.close();
    }
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    switch (++calls) {
      case 1:
        return StreamReader.fromIterable([
          Message(
            role: RoleType.assistant,
            content: '',
            toolCalls: [
              ToolCall(
                id: 'ask_1',
                function: FunctionCall(
                  name: 'ask_user',
                  arguments: '{"question":"continue?"}',
                ),
              ),
            ],
          ),
        ]);
      case 2:
        final (reader, writer) = pipe<Message>(capacity: 1);
        unawaited(() async {
          try {
            writer.send(Message.assistant('partial'));
            _close(secondStarted);
            await release.future;
          } finally {
            await writer.close();
          }
        }());
        return reader;
      default:
        _close(thirdStarted);
        return StreamReader.fromIterable([Message.assistant('resumed')]);
    }
  }
}

/// Port of `turnLoopTargetedResumeTool`.
final class _TargetedResumeTool extends InvokableTool {
  int calls = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'ask_user',
        desc: '',
        params: const {'question': ParameterInfo(type: DataType.string)},
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    calls++;
    final wasInterrupted = getInterruptState<String>(ctx).wasInterrupted;
    final resume = getResumeContext<String>(ctx);
    if (wasInterrupted && resume.isResumeTarget && resume.hasData) {
      return resume.data!;
    }
    throw statefulInterrupt(ctx, 'answer required', 'awaiting answer');
  }
}

/// The runner checkpoint inside a TurnLoop checkpoint (Base64), from the JSON
/// envelope (Go: `unmarshalTurnLoopCheckpoint(...).RunnerCheckpoint`).
String? _runnerCheckpointOf(Uint8List data) =>
    (jsonDecode(utf8.decode(data)) as Map<String, Object?>)['runner_checkpoint']
        as String?;

const _turnCtxKey = ContextKey<String>('eino_turn_loop_2_test.turnCtxKey');

void main() {
  test('TestTurnLoop_CheckpointIDWithoutStore_FreshStart', () async {
    var genInputCalled = false;
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        checkpointId: 'some-id',
        genInput: (ctx, loop, items) async {
          genInputCalled = true;
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        prepareAgent: _prepareTestAgent,
        onAgentEvents: _drainAndStop,
      ),
    );
    loop
      ..push('a')
      ..run(RunContext.background());
    final exit = await loop.wait();
    expect(exit.exitReason, isNull);
    expect(genInputCalled, isTrue);
  });

  test('TestTurnLoop_CheckpointNotFound_FreshStart', () async {
    final store = _Store();
    var genInputCalled = false;
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: 'nonexistent-id',
        genInput: (ctx, loop, items) async {
          genInputCalled = true;
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        prepareAgent: _prepareTestAgent,
        onAgentEvents: _drainAndStop,
      ),
    );
    loop
      ..push('a')
      ..run(RunContext.background());
    final exit = await loop.wait();
    expect(exit.exitReason, isNull);
    expect(genInputCalled, isTrue);
  });

  test('TestTurnLoop_CheckpointEmptyData_TreatedAsNoCheckpoint', () async {
    final store = _Store();
    store.m['cp-empty'] = Uint8List(0);
    var genInputCalled = false;
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: 'cp-empty',
        genInput: (ctx, loop, items) async {
          genInputCalled = true;
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        prepareAgent: _prepareTestAgent,
        onAgentEvents: _drainAndStop,
      ),
    );
    loop
      ..push('a')
      ..run(RunContext.background());
    final exit = await loop.wait();
    expect(exit.exitReason, isNull);
    expect(genInputCalled, isTrue);
  });

  test('TestTurnLoop_CheckpointLoadError_ReturnsError', () async {
    final store = _ErrorStore(getErr: Exception('store unavailable'));
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: 'cp-1',
        genInput: _consumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop
      ..push('a')
      ..run(RunContext.background());
    final exit = await loop.wait();
    expect(exit.exitReason, isNotNull);
    expect('${exit.exitReason}', contains('store unavailable'));
  });

  test('TestTurnLoop_CheckpointCorruptData_ReturnsError', () async {
    final store = _Store();
    store.m['cp-corrupt'] = Uint8List.fromList(utf8.encode('not-valid-gob-data'));
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: 'cp-corrupt',
        genInput: _consumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop
      ..push('a')
      ..run(RunContext.background());
    final exit = await loop.wait();
    expect(exit.exitReason, isNotNull);
    expect('${exit.exitReason}', contains('failed to unmarshal checkpoint'));
  });

  test('TestTurnLoop_CheckpointSaveError_ReturnsError', () async {
    final saveStore = _ErrorStore(setErr: Exception('write failed'));
    final slowModel = _SlowModel();
    final exit = await _cancelledRun(saveStore, 'cp-1', _chatAgent(slowModel), slowModel);
    expect(exit.exitReason, isNotNull);
    expect(exit.checkpointAttempted, isTrue);
    expect(exit.checkpointError, isNotNull);
    expect('${exit.checkpointError}', contains('write failed'));
  });

  test('TestTurnLoop_StaleCheckpointDeletion_OnCleanResume', () async {
    final store = _Store();
    const cpId = 'stale-session';
    final loop1 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop1
      ..push('a')
      ..stop()
      ..run(RunContext.background());
    await loop1.wait();
    expect(store.m.containsKey(cpId), isTrue,
        reason: 'checkpoint should exist after first loop saves it');

    final loop2 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAllWithMsg,
        prepareAgent: _prepareTestAgent,
        onAgentEvents: _drainAndStop,
      ),
    );
    loop2
      ..push('b')
      ..run(RunContext.background());
    final exit2 = await loop2.wait();
    expect(exit2.exitReason, isNull);
    expect(store.m.containsKey(cpId), isTrue,
        reason: 'checkpoint should still exist because loop2 was stopped and saved a new one');
  });

  test('TestTurnLoop_CheckpointDeleter_CalledOnContextCancel', () async {
    final store = _DeletableStore();
    const cpId = 'deleter-session';
    final loop1 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop1
      ..push('a')
      ..stop()
      ..run(RunContext.background());
    await loop1.wait();
    expect(store.m.containsKey(cpId), isTrue, reason: 'checkpoint saved after loop1');

    final token2 = CancelToken();
    final loop2 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAllWithMsg,
        prepareAgent: _prepareTestAgent,
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          token2.cancel();
        },
      ),
    );
    loop2
      ..push('b')
      ..run(RunContext.background(cancelToken: token2));
    final exit2 = await loop2.wait();
    expect(exit2.exitReason, _isContextCancel);
    expect(store.deleteCalled, isTrue, reason: 'CheckPointDeleter.Delete should be called');
    expect(store.deletedKey, cpId);
    expect(store.m.containsKey(cpId), isFalse, reason: 'checkpoint should be removed from store');
  });

  test('TestTurnLoop_GenResumeNil_Error', () async {
    final store = _Store();
    const cpId = 'resume-nil-session';
    final slowModel = _SlowModel();
    await _cancelledRun(store, cpId, _chatAgent(slowModel), slowModel);

    final loop2 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    )..run(RunContext.background());
    final exit2 = await loop2.wait();
    expect(exit2.exitReason, isNotNull);
    expect('${exit2.exitReason}', contains('GenResume is required'));
  });

  test('TestTurnLoop_SameCheckpointID_OverwritePattern', () async {
    final store = _Store();
    const cpId = 'overwrite-session';
    final loop1 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop1
      ..push('a')
      ..push('b')
      ..stop()
      ..run(RunContext.background());
    await loop1.wait();
    final data1 = List.of(store.m[cpId] ?? const <int>[]);
    expect(data1, isNotEmpty);

    final loop2 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAll,
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop2
      ..push('c')
      ..stop()
      ..run(RunContext.background());
    await loop2.wait();
    final data2 = List.of(store.m[cpId] ?? const <int>[]);
    expect(data2, isNotEmpty);
    expect(data2, isNot(data1), reason: 'checkpoint data should change because items are different');

    List<String>? seen;
    final loop3 = TurnLoop<String>(
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
    loop3
      ..push('d')
      ..run(RunContext.background());
    final exit3 = await loop3.wait();
    expect(exit3.exitReason, isNull);
    expect(seen, ['a', 'b', 'c', 'd'],
        reason: "should see loop2's unhandled items (a,b,c from loop2's checkpoint) plus new d");
  });

  test('TestTurnLoop_CheckpointHasRunnerStateButEmptyBytes', () async {
    final store = _Store();
    const cpId = 'empty-runner-bytes';
    // Go: marshalTurnLoopCheckpoint(&turnLoopCheckpoint{HasRunnerState: true,
    // RunnerCheckpoint: nil, UnhandledItems: ["x"]}).
    store.m[cpId] = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'kind': '_eino_adk_turn_loop_checkpoint',
          'has_runner_state': true,
          'unhandled_items': ['x'],
          'canceled_items': <Object?>[],
        }),
      ),
    );
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
      ..run(RunContext.background());
    final exit = await loop.wait();
    expect(exit.exitReason, isNotNull);
    expect('${exit.exitReason}', contains('has runner state but bytes are empty'));
  });

  test('TestTurnLoop_GenResumeReturnsError', () async {
    final store = _Store();
    const cpId = 'resume-err-session';
    final slowModel = _SlowModel();
    await _cancelledRun(store, cpId, _chatAgent(slowModel), slowModel);

    final genResumeErr = Exception('resume callback failed');
    final loop2 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAll,
        genResume: (ctx, loop, canceled, unhandled, newItems) async => throw genResumeErr,
        prepareAgent: _prepareTestAgent,
      ),
    )..run(RunContext.background());
    final exit2 = await loop2.wait();
    expect(exit2.exitReason, isNotNull);
    expect(exit2.exitReason, _isError(genResumeErr));
  });

  // Adapted. Go sets the private `pendingResume` and blocks a PushStrategy in
  // a goroutine while Run plans the resume. In Dart a push (its strategy
  // included) is synchronous, so it is never in flight while the loop plans;
  // the pending resume comes from a real cancel checkpoint, and the strategy
  // push lands while the loop is loading it. genResume must see it, after the
  // item pushed before run.
  test('TestTurnLoop_ResumeWaitsForInFlightPushBeforePlanning', () async {
    final store = _GatedStore();
    const cpId = 'resume-waits-for-push';
    final slowModel = _SlowModel();
    await _cancelledRun(store, cpId, _chatAgent(slowModel), slowModel, item: 'interrupted');

    final resumeErr = Exception('stop after observing resume inputs');
    final genResumeCalled = Completer<void>();
    List<String>? resumeNewItems;
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAll,
        genResume: (ctx, loop, interruptedItems, unhandledItems, newItems) async {
          resumeNewItems = List.of(newItems);
          genResumeCalled.complete();
          throw resumeErr;
        },
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop.push('pre-existing');
    store.gate = Completer<void>();
    loop.run(RunContext.background());
    await store.getEntered.future;

    var strategyEntered = false;
    var genResumeCalledDuringStrategy = false;
    final pushed = loop.push(
      'during-resume',
      options: [
        PushOption.strategy((ctx, tc) {
          strategyEntered = true;
          genResumeCalledDuringStrategy = genResumeCalled.isCompleted;
          return const [];
        }),
      ],
    );
    expect(strategyEntered, isTrue, reason: 'strategy did not enter');
    expect(genResumeCalledDuringStrategy, isFalse,
        reason: 'GenResume should wait for in-flight PushStrategy to finish');
    expect(pushed.accepted, isTrue);
    // Go: assert.Nil(t, ack) — a push without preempt has no `resolved`.
    expect(pushed.resolved, isNull);

    store.gate!.complete();
    final exit = await loop.wait();
    expect(exit.exitReason, _isError(resumeErr));
    expect(resumeNewItems, ['pre-existing', 'during-resume']);
  });

  test('TestTurnLoop_CheckpointSaveError_MergesWithExistingError', () async {
    final saveStore = _ErrorStore(setErr: Exception('disk full'));
    final slowModel = _SlowModel();
    final exit = await _cancelledRun(saveStore, 'cp-merge-err', _chatAgent(slowModel), slowModel);
    expect(exit.exitReason, isNotNull);
    expect(exit.exitReason, _isCancelError,
        reason: 'ExitReason should be CancelError, not merged with checkpoint error');
    expect(exit.checkpointAttempted, isTrue);
    expect(exit.checkpointError, isNotNull);
    expect('${exit.checkpointError}', contains('disk full'));
  });

  test('TestTurnLoop_ResumeWithParams', () async {
    final store = _Store();
    const cpId = 'resume-params-session';
    final slowModel = _SlowModel();
    final agent = _chatAgent(slowModel);
    final exit1 = await _cancelledRun(store, cpId, agent, slowModel);
    expect(exit1.exitReason, _isCancelError);

    // Go's model answers after 500 ms in the resumed turn too.
    slowModel.delay = const Duration(milliseconds: 10);
    ResumeParams? resumeParamsUsed;
    final loop2 = TurnLoop<String>(
      TurnLoopConfig(
        store: store,
        checkpointId: cpId,
        genInput: _consumeAll,
        genResume: (ctx, loop, canceled, unhandled, newItems) async {
          const params = ResumeParams(targets: {'some-address': 'user-data'});
          resumeParamsUsed = params;
          return GenResumeResult(
            resumeParams: params,
            consumed: [...canceled, ...unhandled, ...newItems],
          );
        },
        prepareAgent: _prepare(agent),
        onAgentEvents: _drainAndStop,
      ),
    )..run(RunContext.background());
    await loop2.wait();
    expect(resumeParamsUsed, isNotNull,
        reason: 'GenResume should have been called with ResumeParams');
    expect(resumeParamsUsed!.targets, contains('some-address'));
  });

  group('TestTurnLoop_ResumeInterruptAgain_PreservesEnableStreamingCheckpoint', () {
    for (final enableStreaming in [true, false]) {
      test('enable_streaming_$enableStreaming', () async {
        final store = _Store();
        final cpId = 'streaming-resume-$enableStreaming';
        const originalMessage = 'msg1';

        AgentInput? firstInput;
        final firstAgent = _MyAgent(
          runFn: (ctx, input) {
            firstInput = input;
            return StreamReader.fromIterable([interruptEvent(ctx, 'first_interrupt')]);
          },
        );
        final loop1 = TurnLoop<String>(
          TurnLoopConfig(
            store: store,
            checkpointId: cpId,
            genInput: (ctx, loop, items) async => GenInputResult(
              input: AgentInput(
                messages: [Message.user(items[0])],
                enableStreaming: enableStreaming,
              ),
              consumed: items,
            ),
            prepareAgent: _prepare(firstAgent),
          ),
        );
        loop1
          ..push(originalMessage)
          ..run(RunContext.background());
        final exit1 = await loop1.wait();
        expect(firstInput?.enableStreaming, enableStreaming);
        expect(firstInput?.messages, hasLength(1));
        expect(firstInput?.messages[0].content, originalMessage);
        expect(exit1.exitReason, _isInterruptError);
        expect(exit1.checkpointError, isNull);

        Future<GenResumeResult<String>> genResume(
          RunContext ctx,
          TurnLoop<String> loop,
          List<String> interrupted,
          List<String> unhandled,
          List<String> newItems,
        ) async =>
            GenResumeResult(
              consumed: interrupted,
              remaining: [...unhandled, ...newItems],
            );

        bool? secondStreaming;
        final secondAgent = _MyAgent(
          resumeFn: (ctx, info) {
            secondStreaming = info.enableStreaming;
            return StreamReader.fromIterable([interruptEvent(ctx, 'second_interrupt')]);
          },
        );
        final loop2 = TurnLoop<String>(
          TurnLoopConfig(
            store: store,
            checkpointId: cpId,
            genInput: _consumeAll,
            genResume: genResume,
            prepareAgent: _prepare(secondAgent),
          ),
        )..run(RunContext.background());
        final exit2 = await loop2.wait();
        expect(secondStreaming, enableStreaming);
        expect(exit2.exitReason, _isInterruptError);
        expect(exit2.checkpointError, isNull);
        expect(store.m.containsKey(cpId), isTrue);

        // Go decodes the runner checkpoint loop2 wrote (private helpers) and
        // checks its EnableStreaming; here a third loop resumes it and its
        // agent sees the streaming mode the checkpoint keeps.
        bool? thirdStreaming;
        final thirdAgent = _MyAgent(
          resumeFn: (ctx, info) {
            thirdStreaming = info.enableStreaming;
            return StreamReader<AgentEvent>.fromIterable(const []);
          },
        );
        final loop3 = TurnLoop<String>(
          TurnLoopConfig(
            store: store,
            checkpointId: cpId,
            genInput: _consumeAll,
            genResume: genResume,
            prepareAgent: _prepare(thirdAgent),
            onAgentEvents: _drainAndStop,
          ),
        )..run(RunContext.background());
        await loop3.wait();
        expect(thirdStreaming, enableStreaming);
      });
    }
  });

  test('TestTurnLoop_TargetedResume_TimeoutEscalationReplacesCheckpoint', () async {
    final store = _Store();
    const cpId = 'targeted-resume-timeout';
    final model = _TargetedResumeTimeoutModel();
    addTearDown(() => _close(model.release));
    final askUser = _TargetedResumeTool();
    final agent = ChatModelAgent(
      ChatModelAgentConfig(
        name: 'TargetedResumeTimeout',
        description: 'test agent',
        model: model,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [askUser])),
      ),
    );

    var interruptId = '';
    Future<void> observeInterrupt(
      RunContext ctx,
      TurnContext<String> tc,
      StreamReader<AgentEvent> events,
    ) async {
      for (var event = await events.nextOrNull();
          event != null;
          event = await events.nextOrNull()) {
        final interrupted = event.action?.interrupted;
        if (interrupted != null) {
          for (final interrupt in interrupted.interruptContexts) {
            if (interrupt.isRootCause) interruptId = interrupt.id;
          }
        }
        final error = event.error;
        if (error != null) {
          Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
        }
      }
    }

    TurnLoop<String> newLoop({
      Future<GenResumeResult<String>> Function(
        RunContext,
        TurnLoop<String>,
        List<String>,
        List<String>,
        List<String>,
      )? genResume,
    }) =>
        TurnLoop<String>(
          TurnLoopConfig(
            store: store,
            checkpointId: cpId,
            genInput: (ctx, loop, items) async => GenInputResult(
              input: AgentInput(
                messages: [Message.user(items[0])],
                enableStreaming: true,
              ),
              consumed: items,
            ),
            genResume: genResume,
            prepareAgent: _prepare(agent),
            onAgentEvents: observeInterrupt,
          ),
        );

    final owner1 = newLoop()
      ..push('start')
      ..run(RunContext.background());
    final exit1 = await owner1.wait();
    expect(exit1.exitReason, _isInterruptError);
    expect(exit1.checkpointAttempted, isTrue);
    expect(exit1.checkpointError, isNull);
    expect(interruptId, isNotEmpty);
    final firstCheckpoint = await store.get(cpId);
    expect(firstCheckpoint, isNotNull);
    final firstRunnerCheckpoint = _runnerCheckpointOf(firstCheckpoint!);

    final owner2 = newLoop(
      genResume: (ctx, loop, a, b, c) async =>
          GenResumeResult(resumeParams: ResumeParams(targets: {interruptId: 'approved'})),
    )..run(RunContext.background());
    await model.secondStarted.future;
    owner2.stop(options: [StopOption.gracefulTimeout(const Duration(milliseconds: 20))]);
    final exit2 = await owner2.wait();
    expect(exit2.checkpointAttempted, isTrue);
    expect(exit2.checkpointError, isNull);

    final finalCheckpoint = await store.get(cpId);
    expect(finalCheckpoint, isNotNull);
    expect(_runnerCheckpointOf(finalCheckpoint!), isNot(firstRunnerCheckpoint),
        reason: 'timeout escalation must replace the resumed runner checkpoint');

    final owner3 = newLoop(
      genResume: (ctx, loop, a, b, c) async => const GenResumeResult(),
    )..run(RunContext.background());
    final first = await Future.any([
      model.thirdStarted.future.then((_) => 'third'),
      owner3.wait().then((_) => 'done'),
    ]);
    if (first == 'third') owner3.stop();
    final exit3 = await owner3.wait();
    expect(exit3.exitReason, isNot(_isInterruptError),
        reason: 'targetless resume did not continue from the replacement checkpoint');
    expect(askUser.calls, 2, reason: 'resolved tool interrupt must not be replayed');
  });

  test('TestTurnLoop_Stop_EscalatesCancelMode', () async {
    final probe = _StopModeProbeAgent();
    final loop = _newAndRun(
      TurnLoopConfig(genInput: _consumeAllWithMsg, prepareAgent: _prepare(probe)),
    );
    loop.push('msg1');
    final cc = await probe.ccCh.future;
    loop
      ..stop(options: [StopOption.gracefulTimeout(const Duration(seconds: 10))])
      ..stop(options: [const StopOption.immediate()]);
    await _eventually(() => cc.shouldCancel && cc.mode.isEmpty, maxPolls: 1000);
    expect(cc.shouldCancel && cc.mode.isEmpty, isTrue,
        reason: 'cancel mode did not escalate to CancelImmediate');
    final exit = await loop.wait();
    expect(exit.exitReason, _isCancelError);
    final ce = ThreepioException.findCause<AgentRunCancelledException>(exit.exitReason)!;
    expect(ce.info.safePoints, isEmpty); // Go: CancelImmediate
  });

  test('TestTurnLoop_DefaultOnAgentEvents_ErrorPropagation', () async {
    final agentErr = Exception('agent execution error');
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: _consumeAllWithMsg,
        prepareAgent: (ctx, loop, consumed) async =>
            _MockAgent(runFunc: (ctx, input) async => throw agentErr),
        // No onAgentEvents: the default handler.
      ),
    );
    loop.push('msg1');
    final result = await loop.wait();
    // The default handler propagates the agent's error as the exit reason.
    expect(result.exitReason, isNotNull);
  });

  test('TestTurnLoop_OnAgentEventsError', () async {
    final handlerErr = Exception('event handler error');
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: _consumeAllWithMsg,
        prepareAgent: _prepareTestAgent,
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          throw handlerErr;
        },
      ),
    );
    loop.push('msg1');
    final result = await loop.wait();
    expect(result.exitReason, _isError(handlerErr));
  });

  test('TestTurnLoop_StopCallFromGenInput', () async {
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          loop.stop();
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop.push('msg1');
    final result = await loop.wait();
    expect(result.exitReason, isNull);
  });

  test('TestTurnLoop_PushFromOnAgentEvents', () async {
    var pushCount = 0;
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: _consumeFirst,
        prepareAgent: _prepareTestAgent,
        onAgentEvents: (ctx, tc, events) async {
          await _drain(events);
          if (++pushCount == 1) {
            // A follow-up item from the callback.
            tc.loop.push('follow-up');
          } else {
            tc.loop.stop();
          }
        },
      ),
    );
    loop.push('initial');
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(pushCount, 2);
  });

  // NewTurnLoop: push, stop and wait all work on a loop that is not running.

  test('TestNewTurnLoop_PushBeforeRun', () async {
    final processedItems = <String>[];
    final processed = Completer<void>();
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          processedItems.addAll(items);
          _close(processed);
          return GenInputResult(
            input: AgentInput(messages: [Message.user(items[0])]),
            consumed: items,
          );
        },
        prepareAgent: _prepareTestAgent,
      ),
    );
    // Pushed before run: buffered.
    expect(loop.push('msg1').accepted, isTrue);
    expect(loop.push('msg2').accepted, isTrue);
    loop.run(RunContext.background());
    await processed.future; // Go sleeps 100 ms.
    loop.stop();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(processedItems, contains('msg1'));
    expect(processedItems, contains('msg2'));
  });

  test('TestNewTurnLoop_WaitBeforeRun', () async {
    // wait completes only once run was called and the loop ended.
    final loop = TurnLoop<String>(
      const TurnLoopConfig(genInput: _consumeAll, prepareAgent: _prepareTestAgent),
    );
    final waitDone = loop.wait();
    final returned = _completionOf(waitDone);
    await Future<void>.delayed(const Duration(milliseconds: 20)); // Go: 50 ms
    expect(returned(), isFalse, reason: 'Wait returned before Run was called');
    loop
      ..push('msg1')
      ..stop()
      ..run(RunContext.background());
    final result = await waitDone;
    expect(result.exitReason, isNull);
    expect(result.unhandledItems, ['msg1']);
  });

  test('TestNewTurnLoop_RunIsIdempotent', () async {
    var genInputCalls = 0;
    final called = Completer<void>();
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async {
          genInputCalls++;
          _close(called);
          return GenInputResult(input: AgentInput(), consumed: items);
        },
        prepareAgent: _prepareTestAgent,
      ),
    );
    loop
      ..push('msg1')
      ..run(RunContext.background())
      ..run(RunContext.background())
      ..run(RunContext.background());
    await called.future; // Go sleeps 100 ms.
    await pumpEventQueue();
    loop.stop();
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(genInputCalls, greaterThanOrEqualTo(1));
  });

  test('TestNewTurnLoop_ConcurrentPushAndRun', () async {
    // A push and a run interleaved in both orders (Go: two goroutines).
    for (var i = 0; i < 100; i++) {
      var count = 0;
      final loop = TurnLoop<String>(
        TurnLoopConfig(
          genInput: (ctx, loop, items) async {
            count += items.length;
            return GenInputResult(input: AgentInput(), consumed: items);
          },
          prepareAgent: (ctx, loop, consumed) async => _MockAgent(),
        ),
      );
      Future<void> push() => Future(() => loop.push('item'));
      Future<void> run() => Future(() => loop.run(RunContext.background()));
      await Future.wait(i.isEven ? [push(), run()] : [run(), push()]);
      await pumpEventQueue(); // Go sleeps 50 ms.
      loop.stop();
      final result = await loop.wait();
      expect(result.exitReason, isNull);
      expect(count + result.unhandledItems.length, lessThanOrEqualTo(1),
          reason: 'total should not exceed pushed amount');
    }
  });

  test('TestTurnLoop_RunCtx_Propagation', () async {
    // GenInputResult.runContext reaches prepareAgent, the agent's run and
    // onAgentEvents.
    const traceVal = 'trace-123';
    String? prepareCtxVal;
    String? agentCtxVal;
    String? eventsCtxVal;
    final loop = TurnLoop<String>(
      TurnLoopConfig(
        genInput: (ctx, loop, items) async => GenInputResult(
          // A context of its own, with per-item trace data.
          runContext: ctx.withValue(_turnCtxKey, traceVal),
          input: AgentInput(messages: [Message.user(items[0])]),
          consumed: items,
        ),
        prepareAgent: (ctx, loop, consumed) async {
          prepareCtxVal = ctx.value(_turnCtxKey);
          return _MockAgent(
            agentName: 'trace-agent',
            runFunc: (ctx, input) async {
              agentCtxVal = ctx.value(_turnCtxKey);
              return const AgentOutput();
            },
          );
        },
        onAgentEvents: (ctx, tc, events) async {
          eventsCtxVal = ctx.value(_turnCtxKey);
          await _drain(events);
          tc.loop.stop();
        },
      ),
    );
    loop
      ..push('hello')
      ..run(RunContext.background());
    final result = await loop.wait();
    expect(result.exitReason, isNull);
    expect(prepareCtxVal, traceVal, reason: 'PrepareAgent should receive RunCtx');
    expect(agentCtxVal, traceVal, reason: 'Agent run should receive RunCtx');
    expect(eventsCtxVal, traceVal, reason: 'OnAgentEvents should receive RunCtx');
  });

  test('TestTurnLoop_TurnContext_PreemptedChannel', () async {
    final preemptedSeen = Completer<void>();
    final agentStarted = Completer<void>();
    final loop = _newAndRun(
      TurnLoopConfig(
        genInput: _consumeAllWithMsg,
        prepareAgent: (ctx, loop, consumed) async => _CancellableAgent(
          runFunc: (ctx, input) async {
            await ctx.cancelToken.whenCancelled;
            throw CancelledException(ctx.cancelToken.reason);
          },
        ),
        onAgentEvents: (ctx, tc, events) async {
          // Go closes agentStarted unguarded; a later turn never gets here
          // because the test stops the loop first.
          _close(agentStarted);
          await tc.preempted; // Go: or a 5 s timeout.
          _close(preemptedSeen);
          await _drain(events);
        },
      ),
    );
    loop.push('msg1');
    await agentStarted.future;
    loop.push(
      'msg2',
      options: [
        PushOption.preemptTimeout(
          {CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls},
          const Duration(milliseconds: 1),
        ),
      ],
    );
    await preemptedSeen.future;
    loop.stop();
    await loop.wait();
  });
}
