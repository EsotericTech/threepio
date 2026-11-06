// Ports eino v0.9.22 `adk/agentic_react_test.go` (cancel cases):
//   TestAgenticReact_CancelAfterChatModel, TestAgenticReact_CancelAfterToolCalls,
//   TestAgenticReact_ResumeThenCancelAfterChatModelCheckpoint;
// plus an immediate cancel of a streaming agentic run and a cancel before
// the graph starts (written for the port; the classic cancel tests cover the
// shared cancel machinery). Go's `time.Sleep(10ms)` before the tool finishes
// is `pumpEventQueue()`.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

import 'agentic_fakes.dart';

/// Port of Go `agenticSignalTool`: blocks until [finish].
class _SignalTool extends InvokableTool {
  _SignalTool(this.name, this.result);

  final String name;
  final String result;
  final Completer<void> started = Completer<void>();
  final Completer<void> _done = Completer<void>();

  void finish() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: name,
        desc: 'blocks until finish() is called',
        params: const {},
      );

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    if (!started.isCompleted) started.complete();
    await _done.future;
    return result;
  }
}

AgenticChatModelAgent _agent(AgenticModel model, List<BaseTool> tools) =>
    AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'cancel-agent',
      description: 'test agentic agent',
      model: model,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)),
    ));

void main() {
  final ctx = RunContext.background();

  test('TestAgenticReact_CancelAfterChatModel', () async {
    var modelCallCount = 0;
    final mdl = MockAgenticModel(
      onGenerate: (_, __) async => switch (++modelCallCount) {
        1 => agenticToolCallMsg('slow', 'c1', '"hi"'),
        2 => agenticToolCallMsg('slow', 'c2', '"hi2"'),
        _ => agenticMsg('should not reach'),
      },
    );
    final slow = _SignalTool('slow', 'slow result');
    final (cancelOpt, cancelFn) = withCancel();
    final iter = _agent(mdl, [slow]).run(
      ctx,
      AgenticAgentInput(messages: [AgenticMessage.user('trigger cancel')]),
      options: [cancelOpt],
    );

    await slow.started.future;
    final handle = cancelFn(safePoints: {CancelSafePoint.afterChatModel});
    await pumpEventQueue();
    slow.finish();

    final events = await drainAgenticEvents(iter);
    expect(await handle.wait(), CancelOutcome.cancelled);
    final error = firstAgenticEventError(events);
    expect(error, isNotNull, reason: 'expected CancelError event');
    expect(
      ThreepioException.findCause<AgentRunCancelledException>(error),
      isNotNull,
    );
    // The model ran again (its message is kept at the safe point).
    expect(modelCallCount, 2);
  });

  test('TestAgenticReact_CancelAfterToolCalls', () async {
    var modelCallCount = 0;
    final mdl = MockAgenticModel(
      onGenerate: (_, __) async => ++modelCallCount == 1
          ? agenticToolCallMsg('slow', 'c1', '"hi"')
          : agenticMsg('should not reach on second call'),
    );
    final slow = _SignalTool('slow', 'slow result');
    final (cancelOpt, cancelFn) = withCancel();
    final iter = _agent(mdl, [slow]).run(
      ctx,
      AgenticAgentInput(messages: [AgenticMessage.user('trigger cancel')]),
      options: [cancelOpt],
    );

    await slow.started.future;
    final handle = cancelFn(safePoints: {CancelSafePoint.afterToolCalls});
    await pumpEventQueue();
    slow.finish();

    final events = await drainAgenticEvents(iter);
    expect(await handle.wait(), CancelOutcome.cancelled);
    final error = firstAgenticEventError(events);
    expect(error, isNotNull, reason: 'expected CancelError event');
    expect(
      ThreepioException.findCause<AgentRunCancelledException>(error),
      isNotNull,
    );
    expect(modelCallCount, 1);
  });

  test('TestAgenticReact_ResumeThenCancelAfterChatModelCheckpoint', () async {
    var modelCallCount = 0;
    final mdl = MockAgenticModel(
      onGenerate: (_, __) async => switch (++modelCallCount) {
        1 => agenticToolCallMsg('approval_tool', 'c1', '"first"'),
        2 => agenticToolCallMsg('approval_tool', 'c2', '"second"'),
        _ => throw StateError('unexpected call #$modelCallCount'),
      },
    );
    final store = InMemoryCheckpointStore();
    final runner = AgenticRunner(
      agent: _agent(mdl, [AgenticInterruptTool('approval_tool')]),
      checkpointStore: store,
    );
    final events1 = await drainAgenticEvents(
      runner.query(
        ctx,
        'approve then cancel',
        options: [AgentRunOption.checkpointId('resume-cancel-cp')],
      ),
    );
    expect(firstAgenticEventError(events1), isNull);
    final int1 = findInterruptEvent(events1);
    expect(int1, isNotNull, reason: 'expected tool interrupt');
    final int1Id = int1!.action!.interrupted!.interruptContexts[0].id;

    final (cancelOpt, cancelFn) = withCancel();
    final handle = cancelFn(safePoints: {CancelSafePoint.afterChatModel});
    expect(handle.contributed, isTrue);

    final events2 = await drainAgenticEvents(
      await runner.resumeWithParams(
        ctx,
        'resume-cancel-cp',
        ResumeParams(targets: {int1Id: 'approved'}),
        options: [cancelOpt],
      ),
    );
    expect(await handle.wait(), CancelOutcome.cancelled);
    for (final event in events2) {
      if (event.error == null) continue;
      final cancelled =
          ThreepioException.findCause<AgentRunCancelledException>(event.error);
      expect(cancelled, isNotNull);
      // The runner saved a checkpoint for the cancel: it can be resumed.
      expect(cancelled!.interruptContexts, isNotEmpty);
    }
    expect(await store.get('resume-cancel-cp'), isNotNull);
  });

  test('an immediate cancel ends a streaming agentic run', () async {
    final (reader, writer) = pipe<AgenticMessage>();
    final mdl = MockAgenticModel(onStream: (_, __) async => reader);
    final (cancelOpt, cancelFn) = withCancel();
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'immediate',
      model: mdl,
    ));
    final iter = agent.run(
      ctx,
      AgenticAgentInput(
        messages: [AgenticMessage.user('hi')],
        enableStreaming: true,
      ),
      options: [cancelOpt],
    );
    writer.send(agenticMsg('partial'));
    await pumpEventQueue();
    final handle = cancelFn();
    final events = await drainAgenticEvents(iter);
    expect(await handle.wait(), CancelOutcome.cancelled);
    expect(
      ThreepioException.findCause<AgentRunCancelledException>(
        firstAgenticEventError(events),
      ),
      isNotNull,
    );
    await writer.close();
  });

  test('a run cancelled before it starts ends with the cancel error', () async {
    final mdl = MockAgenticModel(onGenerate: (_, __) async => agenticMsg('x'));
    final (cancelOpt, cancelFn) = withCancel();
    final handle = cancelFn();
    final events = await drainAgenticEvents(
      AgenticRunner(agent: AgenticChatModelAgent(
        AgenticChatModelAgentConfig(name: 'pre', model: mdl),
      )).query(ctx, 'hi', options: [cancelOpt]),
    );
    expect(await handle.wait(), CancelOutcome.cancelled);
    expect(mdl.generateCalls, 0);
    expect(
      ThreepioException.findCause<AgentRunCancelledException>(
        firstAgenticEventError(events),
      ),
      isNotNull,
    );
  });
}
