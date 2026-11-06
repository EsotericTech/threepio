// The unexported runners of the plan-execute port (eino's sequential and loop
// `workflowAgent`, `adk/workflow.go`) and how `FlowAgent` treats them (the
// `workflowAgent` branches of eino's `flowAgent.Run`/`Resume`). Eino's own
// workflow tests (`TestSequentialAgent`, `TestLoopAgent`, …) test the NOT
// RECOMMENDED public constructors and are not ported; these tests pin the
// behaviour the plan-execute agent relies on, including an interrupt and
// resume inside the loop and a cancel at a transition. The runners are
// imported from `src/` because no library exports them.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/run_options.dart';
import 'package:threepio_core/src/adk/eino/runner.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/loop_runner.dart';
import 'package:threepio_core/src/adk/prebuilt/plan_execute/sequential_runner.dart';

final ctx = RunContext.background();

typedef _RunFn = StreamReader<AgentEvent> Function(RunContext ctx, AgentInput input, List<AgentRunOption> options);
typedef _ResumeFn = StreamReader<AgentEvent> Function(RunContext ctx, ResumeInfo info, List<AgentRunOption> options);

/// A scripted sub-agent that counts its runs and resumes.
final class _Agent implements ResumableAgent {
  _Agent(this.name, {_RunFn? run, _ResumeFn? resume})
      : _run = run ?? ((ctx, input, options) => _say('$name out')),
        _resume = resume;

  @override
  final String name;

  @override
  String get description => '$name agent';

  final _RunFn _run;
  final _ResumeFn? _resume;
  int runs = 0;
  int resumes = 0;
  final List<List<AgentRunOption>> options = [];
  final List<ResumeInfo> resumeInfos = [];

  @override
  StreamReader<AgentEvent> run(RunContext ctx, AgentInput input, {List<AgentRunOption> options = const []}) {
    runs++;
    this.options.add(options);
    return _run(ctx, input, options);
  }

  @override
  StreamReader<AgentEvent> resume(RunContext ctx, ResumeInfo info, {List<AgentRunOption> options = const []}) {
    resumes++;
    resumeInfos.add(info);
    final resume = _resume;
    if (resume == null) throw StateError('$name cannot resume');
    return resume(ctx, info, options);
  }
}

StreamReader<AgentEvent> _say(String text, {AgentAction? action}) => StreamReader.fromIterable([
      AgentEvent.fromMessage(Message.assistant(text), role: RoleType.assistant),
      if (action != null) AgentEvent(action: action),
    ]);

/// The agent name and message content of each event (an action as `action`).
Future<List<String>> _summary(List<AgentEvent> events) async => [
      for (final e in events)
        if (e.error != null)
          '${e.agentName}: error ${e.error}'
        else if (e.output?.messageOutput != null)
          '${e.agentName}: ${(await getMessageFromEvent(e))!.content}'
        else
          '${e.agentName}: action ${e.action}',
    ];

AddressSegment _seg(String id) => AddressSegment(type: addressSegmentAgent, id: id);

AgentEvent? _interruptOf(List<AgentEvent> events) =>
    events.where((e) => e.action?.interrupted != null).firstOrNull;

void main() {
  group('SequentialRunner', () {
    test('runs the sub-agents in order, names their events and shares the session', () async {
      final a = _Agent('a', run: (ctx, input, options) {
        ctx.addSessionValue('x', 1);
        return _say('a out');
      });
      final b = _Agent('b', run: (ctx, input, options) => _say('b saw ${ctx.sessionValue('x')}'));
      final seq = SequentialRunner(name: 'seq', subAgents: [a, b]);
      final events = await Runner(agent: seq).query(ctx, 'go').collectAll();
      expect(await _summary(events), ['a: a out', 'b: b saw 1']);
      expect(seq.componentTypeName, 'Sequential');
    });

    test('an error event ends the run; later sub-agents do not run', () async {
      final a = _Agent('a', run: (ctx, input, options) => StreamReader.fromIterable([
            AgentEvent(error: const ThreepioException('boom')),
            AgentEvent.fromMessage(Message.assistant('never')),
          ]));
      final b = _Agent('b');
      final events = await Runner(agent: SequentialRunner(name: 'seq', subAgents: [a, b])).query(ctx, 'go').collectAll();
      expect(events, hasLength(1));
      expect('${events.single.error}', contains('boom'));
      expect(b.runs, 0);
    });

    test('a sub-agent gets the root input', () async {
      AgentInput? seen;
      final a = _Agent('a', run: (ctx, input, options) {
        seen = input;
        return _say('ok');
      });
      await Runner(agent: SequentialRunner(name: 'seq', subAgents: [a]), enableStreaming: true)
          .run(ctx, [Message.user('hello')])
          .collectAll();
      expect(seen!.messages.single.content, 'hello');
      expect(seen!.enableStreaming, isTrue);
    });

    test('action events that are not interrupts are passed on in order', () async {
      final a = _Agent('a', run: (ctx, input, options) => StreamReader.fromIterable([
            AgentEvent(action: const AgentAction(customizedAction: 'first')),
            AgentEvent.fromMessage(Message.assistant('between')),
            AgentEvent(action: const AgentAction(customizedAction: 'last')),
          ]));
      final events = await Runner(agent: SequentialRunner(name: 'seq', subAgents: [a])).query(ctx, 'go').collectAll();
      expect(events.map((e) => e.action?.customizedAction), ['first', null, 'last']);
      expect(events.map((e) => e.agentName), everyElement('a'));
    });

    test('an interrupt of a sub-agent interrupts the runner; resume continues at that sub-agent', () async {
      final a = _Agent('a');
      final b = _Agent(
        'b',
        run: (ctx, input, options) => StreamReader.fromIterable([
          AgentEvent.fromMessage(Message.assistant('b working')),
          statefulInterruptEvent(ctx, 'need approval', 'b-state'),
        ]),
        resume: (ctx, info, options) => _say('b resumed with ${info.resumeData} from ${info.interruptState}'),
      );
      final c = _Agent('c');
      final store = InMemoryCheckpointStore();
      final runner = Runner(agent: SequentialRunner(name: 'seq', subAgents: [a, b, c]), checkpointStore: store);
      final events = await runner.query(ctx, 'go', options: [AgentRunOption.checkpointId('cp')]).collectAll();
      expect(await _summary(events.where((e) => e.action == null).toList()), ['a: a out', 'b: b working']);
      final interrupt = _interruptOf(events)!;
      expect(interrupt.agentName, 'b');
      expect(interrupt.action!.interrupted!.data, isNull, reason: 'no WorkflowInterruptInfo');
      final root = interrupt.action!.interrupted!.interruptContexts.single;
      expect(root.isRootCause, isTrue);
      expect(root.info, 'need approval');
      expect(root.address, Address([_seg('seq'), _seg('b')]));
      expect(c.runs, 0);

      final resumed = await (await runner.resumeWithParams(ctx, 'cp', ResumeParams(targets: {root.id: 'yes'})))
          .collectAll();
      expect(await _summary(resumed), ['b: b resumed with yes from b-state', 'c: c out']);
      expect((a.runs, b.runs, b.resumes, c.runs), (1, 1, 1, 1));
      expect(b.resumeInfos.single.wasInterrupted, isTrue);
      expect(b.resumeInfos.single.isResumeTarget, isTrue);
    });

    test('a cancel between two sub-agents interrupts at the transition; resume runs the next one', () async {
      final gate = Completer<void>();
      final a = _Agent('a', run: (ctx, input, options) {
        final (reader, writer) = pipe<AgentEvent>();
        unawaited(() async {
          await gate.future;
          writer.send(AgentEvent.fromMessage(Message.assistant('a out')));
          await writer.close();
        }());
        return reader;
      });
      final b = _Agent('b');
      final store = InMemoryCheckpointStore();
      final runner = Runner(agent: SequentialRunner(name: 'seq', subAgents: [a, b]), checkpointStore: store);
      final (cancelOption, cancel) = withCancel();
      final eventsFuture = runner
          .query(ctx, 'go', options: [cancelOption, AgentRunOption.checkpointId('cp')])
          .collectAll();
      await pumpEventQueue();
      // A safe-point cancel: the custom agent has no safe point of its own, so
      // the runner's transition is where it takes effect.
      final handle = cancel(safePoints: {CancelSafePoint.afterChatModel});
      gate.complete();
      expect(await handle.wait(), CancelOutcome.cancelled);
      final events = await eventsFuture;
      expect(await _summary(events.where((e) => e.error == null).toList()), ['a: a out']);
      final cancelled = ThreepioException.findCause<AgentRunCancelledException>(events.last.error)!;
      final point = cancelled.interruptContexts.single;
      expect(point.info, 'Sequential workflow cancel at transition');
      expect(point.address, Address([_seg('seq')]));
      expect(b.runs, 0);

      final resumed = await (await runner.resume(ctx, 'cp')).collectAll();
      expect(await _summary(resumed), ['b: b out']);
      expect((a.runs, b.runs, b.resumes), (1, 1, 0), reason: 'b is run, not resumed');
    });

    test('resume without a state or with a foreign state fails as in eino', () async {
      final seq = SequentialRunner(name: 'seq', subAgents: [_Agent('a')]);
      final noState = await seq.resume(ctx, const ResumeInfo()).collectAll();
      expect('${noState.single.error}', contains("workflowAgent.Resume: agent 'seq' was asked to resume but has no state"));
      final foreign = await seq.resume(ctx, const ResumeInfo(interruptState: 'x')).collectAll();
      expect('${foreign.single.error}', contains('unsupported workflow agent state type: String'));
    });
  });

  group('LoopRunner', () {
    test('runs the sub-agents maxIterations times', () async {
      final loop = LoopRunner(name: 'loop', subAgents: [_Agent('a'), _Agent('b')], maxIterations: 3);
      final events = await Runner(agent: loop).query(ctx, 'go').collectAll();
      expect(await _summary(events), ['a: a out', 'b: b out', 'a: a out', 'b: b out', 'a: a out', 'b: b out']);
      expect(loop.componentTypeName, 'Loop');
    });

    test('maxIterations must be positive', () {
      expect(() => LoopRunner(name: 'loop', subAgents: const [], maxIterations: 0), throwsArgumentError);
    });

    test('a LoopBreak ends the loop and does not reach the caller', () async {
      var round = 0;
      final b = _Agent('b', run: (ctx, input, options) {
        round++;
        return round == 2 ? _say('b stops', action: const AgentAction(customizedAction: LoopBreak('b'))) : _say('b goes on');
      });
      final a = _Agent('a');
      final events = await Runner(agent: LoopRunner(name: 'loop', subAgents: [a, b], maxIterations: 5))
          .query(ctx, 'go')
          .collectAll();
      expect(await _summary(events), ['a: a out', 'b: b goes on', 'a: a out', 'b: b stops']);
      expect(events.any((e) => e.action?.customizedAction is LoopBreak), isFalse);
      expect((a.runs, b.runs), (2, 2));
    });

    test('a LoopBreak on an event with output keeps the output', () async {
      final b = _Agent('b', run: (ctx, input, options) => StreamReader.fromIterable([
            AgentEvent(
              output: AgentOutput(messageOutput: MessageVariant.message(Message.assistant('final'))),
              action: const AgentAction(customizedAction: LoopBreak('b')),
            ),
          ]));
      final events = await Runner(agent: LoopRunner(name: 'loop', subAgents: [b], maxIterations: 5))
          .query(ctx, 'go')
          .collectAll();
      expect(await _summary(events), ['b: final']);
      expect(events.single.action, isNull);
      expect(b.runs, 1);
    });

    test('a break that is not the last event still ends the loop after the sub-agent', () async {
      final b = _Agent('b', run: (ctx, input, options) => StreamReader.fromIterable([
            AgentEvent(action: const AgentAction(customizedAction: LoopBreak('b'))),
            AgentEvent.fromMessage(Message.assistant('after the break')),
          ]));
      final events = await Runner(agent: LoopRunner(name: 'loop', subAgents: [b], maxIterations: 5))
          .query(ctx, 'go')
          .collectAll();
      expect(await _summary(events), ['b: after the break']);
      expect(b.runs, 1);
    });

    // The P9 plan's "resume inside the loop" test: the loop sits inside a
    // sequential runner as in the plan-execute agent, and its second
    // sub-agent interrupts in the second iteration.
    test('an interrupt inside the loop is resumed in the same iteration, and the loop goes on', () async {
      var bRuns = 0;
      final p = _Agent('p');
      final a = _Agent('a');
      final b = _Agent(
        'b',
        run: (ctx, input, options) {
          bRuns++;
          return bRuns == 2 ? StreamReader.fromIterable([statefulInterruptEvent(ctx, 'stop here', bRuns)]) : _say('b out');
        },
        resume: (ctx, info, options) => _say('b resumed (state ${info.interruptState})'),
      );
      final agent = FlowWrappedAgent(
        SequentialRunner(
          name: 'seq',
          subAgents: [p, LoopRunner(name: 'loop', subAgents: [a, b], maxIterations: 3)],
        ),
      );
      final store = InMemoryCheckpointStore();
      final runner = Runner(agent: agent, checkpointStore: store, enableStreaming: true);
      final events = await runner.query(ctx, 'go', options: [AgentRunOption.checkpointId('loop-cp')]).collectAll();
      expect(await _summary(events.where((e) => e.action == null).toList()), [
        'p: p out',
        'a: a out',
        'b: b out',
        'a: a out',
      ]);
      final interrupt = _interruptOf(events)!;
      expect(interrupt.agentName, 'b');
      final point = interrupt.action!.interrupted!.interruptContexts.single;
      expect(point.address, Address([_seg('seq'), _seg('loop'), _seg('b')]), reason: 'not wrapped twice');
      expect(point.info, 'stop here');

      final resumed = await (await runner.resume(ctx, 'loop-cp')).collectAll();
      expect(await _summary(resumed), [
        'b: b resumed (state 2)',
        'a: a out',
        'b: b out',
      ]);
      expect((p.runs, a.runs, b.runs, b.resumes), (1, 3, 3, 1));
      expect(b.resumeInfos.single.enableStreaming, isTrue);
      expect(b.resumeInfos.single.isResumeTarget, isFalse);
    });

    test('a cancel at a transition inside the loop is resumed at that sub-agent', () async {
      final gate = Completer<void>();
      final a = _Agent('a', run: (ctx, input, options) {
        final (reader, writer) = pipe<AgentEvent>();
        unawaited(() async {
          await gate.future;
          writer.send(AgentEvent.fromMessage(Message.assistant('a out')));
          await writer.close();
        }());
        return reader;
      });
      final b = _Agent('b', run: (ctx, input, options) => _say('b out', action: const AgentAction(customizedAction: LoopBreak('b'))));
      final runner = Runner(
        agent: LoopRunner(name: 'loop', subAgents: [a, b], maxIterations: 2),
        checkpointStore: InMemoryCheckpointStore(),
      );
      final (cancelOption, cancel) = withCancel();
      final eventsFuture = runner.query(ctx, 'go', options: [cancelOption, AgentRunOption.checkpointId('cp')]).collectAll();
      await pumpEventQueue();
      final handle = cancel(safePoints: {CancelSafePoint.afterToolCalls});
      gate.complete();
      expect(await handle.wait(), CancelOutcome.cancelled);
      final events = await eventsFuture;
      final cancelled = ThreepioException.findCause<AgentRunCancelledException>(events.last.error)!;
      expect(cancelled.interruptContexts.single.info, 'Loop workflow cancel at transition');
      expect(cancelled.interruptContexts.single.address, Address([_seg('loop')]));

      final resumed = await (await runner.resume(ctx, 'cp')).collectAll();
      expect(await _summary(resumed), ['b: b out']);
      expect((a.runs, b.runs), (1, 1));
    });
  });

  group('FlowAgent with workflow runners', () {
    test('options designated for a sub-agent reach it through the runners', () async {
      final a = _Agent('a');
      final b = _Agent('b');
      final agent = SequentialRunner(name: 'seq', subAgents: [a, LoopRunner(name: 'loop', subAgents: [b], maxIterations: 1)]);
      await Runner(agent: agent).query(ctx, 'go', options: [
        AgentRunOption.custom<String>('for b').designateAgent(['b']),
        AgentRunOption.custom<String>('for someone else').designateAgent(['zzz']),
        AgentRunOption.custom<String>('for all'),
      ]).collectAll();
      expect(AgentRunOption.customValues<String>(b.options.single), ['for b', 'for all']);
      expect(AgentRunOption.customValues<String>(a.options.single), ['for all']);
    });

    test('callback handlers of the run fire once per agent', () async {
      final started = <String>[];
      final types = <String, String>{};
      final handler = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            if (info.componentType == ComponentType.agent) {
              started.add(info.name);
              types[info.name] = info.type;
            }
            return ctx;
          })
          .build();
      final agent = SequentialRunner(name: 'seq', subAgents: [_Agent('a'), LoopRunner(name: 'loop', subAgents: [_Agent('b')], maxIterations: 2)]);
      await Runner(agent: agent).query(ctx, 'go', options: [AgentRunOption.callbacks([handler])]).collectAll();
      expect(started, ['seq', 'a', 'loop', 'b', 'b']);
      expect(types['seq'], 'Sequential');
      expect(types['loop'], 'Loop');
    });

    test('a FlowWrappedAgent is unwrapped, not wrapped twice', () async {
      final b = _Agent('b', run: (ctx, input, options) => StreamReader.fromIterable([interruptEvent(ctx, 'wait')]));
      final wrapped = FlowWrappedAgent(SequentialRunner(name: 'seq', subAgents: [b], description: 'd'));
      expect((wrapped.name, wrapped.description), ('seq', 'd'));
      expect(FlowAgent(wrapped).agent, same(wrapped.inner));
      final events = await Runner(agent: wrapped).query(ctx, 'go').collectAll();
      expect(_interruptOf(events)!.action!.interrupted!.interruptContexts.single.address, Address([_seg('seq'), _seg('b')]));
      // Run directly, the wrapper still runs the agent inside its FlowAgent.
      final direct = await wrapped.run(ctx, AgentInput(messages: [Message.user('go')])).collectAll();
      expect(_interruptOf(direct)!.action!.interrupted!.interruptContexts.single.address, Address([_seg('seq'), _seg('b')]));
    });

    test('filterCallbackHandlersForNestedAgents drops the handlers the wrapper installed', () {
      final handler = CallbackHandlerBuilder().build();
      final forAll = AgentRunOption.callbacks([handler]);
      final forSeq = AgentRunOption.callbacks([handler]).designateAgent(['seq']);
      final forB = AgentRunOption.callbacks([handler]).designateAgent(['b']);
      final empty = AgentRunOption.callbacks(const []);
      final other = AgentRunOption.custom<int>(1);
      expect(filterCallbackHandlersForNestedAgents('seq', [forAll, forSeq, forB, empty, other]), [forB, empty, other]);
    });
  });
}
