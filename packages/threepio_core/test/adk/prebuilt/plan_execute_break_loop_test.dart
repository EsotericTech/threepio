// `PlanExecute.breakLoopAction`: the scoped public form of eino's
// `adk.NewBreakLoopAction`, with which a custom replanner given to
// `planexecute.New` ends the loop (coordinator decision 2 after P9). Only
// `package:threepio_core/adk.dart` is imported, so these tests also prove
// that the factory is reachable through the public API while the loop runner
// and its `LoopBreak` stay private.
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

final ctx = RunContext.background();

typedef _RunFn = StreamReader<AgentEvent> Function(
  RunContext ctx,
  AgentInput input,
  int run,
);

/// A scripted agent that counts its runs.
final class _Agent implements Agent {
  _Agent(this.name, [_RunFn? run]) : _run = run ?? _sayRun;

  @override
  final String name;

  @override
  String get description => '$name agent';

  final _RunFn _run;
  int runs = 0;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    runs++;
    return _run(ctx, input, runs);
  }

  static StreamReader<AgentEvent> _sayRun(
    RunContext ctx,
    AgentInput input,
    int run,
  ) =>
      _say('out $run');
}

StreamReader<AgentEvent> _say(String text, {AgentAction? action}) =>
    StreamReader.fromIterable([
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

Future<ResumableAgent> _planExecute({
  required Agent replanner,
  Agent? executor,
  int maxIterations = 5,
}) =>
    PlanExecute.create(
      ctx,
      PlanExecuteLoopConfig(
        planner: _Agent('planner'),
        executor: executor ?? _Agent('executor'),
        replanner: replanner,
        maxIterations: maxIterations,
      ),
    );

void main() {
  group('PlanExecute.breakLoopAction', () {
    test('a custom replanner ends the loop with it', () async {
      final executor = _Agent('executor');
      final replanner = _Agent('my_replanner', (ctx, input, run) {
        if (run < 2) return _say('revised plan $run');
        return _say(
          'final answer',
          action: PlanExecute.breakLoopAction('my_replanner'),
        );
      });
      final agent = await _planExecute(
        executor: executor,
        replanner: replanner,
      );

      final events = await Runner(agent: agent).query(ctx, 'go').collectAll();

      expect(await _summary(events), [
        'planner: out 1',
        'executor: out 1',
        'my_replanner: revised plan 1',
        'executor: out 2',
        'my_replanner: final answer',
      ]);
      // Two rounds, not the five maxIterations allows.
      expect(executor.runs, 2);
      expect(replanner.runs, 2);
      // The break is not passed on to the caller.
      expect(events.where((e) => e.action != null), isEmpty);
    });

    test('without it the loop runs until maxIterations', () async {
      final executor = _Agent('executor');
      final replanner = _Agent('my_replanner');
      final agent = await _planExecute(
        executor: executor,
        replanner: replanner,
        maxIterations: 3,
      );

      final events = await Runner(agent: agent).query(ctx, 'go').collectAll();

      expect(executor.runs, 3);
      expect(replanner.runs, 3);
      expect(events, hasLength(7));
    });

    test('the event that carries it keeps its output', () async {
      final replanner = _Agent(
        'my_replanner',
        (ctx, input, run) => StreamReader.fromIterable([
          AgentEvent.fromMessage(
            Message.assistant('answer and break'),
            role: RoleType.assistant,
          ).copyWith(action: PlanExecute.breakLoopAction('my_replanner')),
        ]),
      );
      final agent = await _planExecute(replanner: replanner);

      final events = await Runner(agent: agent).query(ctx, 'go').collectAll();

      expect(await _summary(events), [
        'planner: out 1',
        'executor: out 1',
        'my_replanner: answer and break',
      ]);
      expect(events.last.action, isNull);
      expect(replanner.runs, 1);
    });

    test('the executor can end the loop too; the replanner then does not run',
        () async {
      final executor = _Agent(
        'executor',
        (ctx, input, run) => _say(
          'done at once',
          action: PlanExecute.breakLoopAction('executor'),
        ),
      );
      final replanner = _Agent('my_replanner');
      final agent = await _planExecute(
        executor: executor,
        replanner: replanner,
      );

      final events = await Runner(agent: agent).query(ctx, 'go').collectAll();

      expect(await _summary(events), [
        'planner: out 1',
        'executor: done at once',
      ]);
      expect(executor.runs, 1);
      expect(replanner.runs, 0);
    });

    test('a streaming run ends the same way', () async {
      final executor = _Agent('executor');
      final replanner = _Agent(
        'my_replanner',
        (ctx, input, run) => _say(
          'streamed answer',
          action: PlanExecute.breakLoopAction('my_replanner'),
        ),
      );
      final agent = await _planExecute(
        executor: executor,
        replanner: replanner,
      );

      final events = await Runner(agent: agent, enableStreaming: true)
          .query(ctx, 'go')
          .collectAll();

      expect(executor.runs, 1);
      expect(replanner.runs, 1);
      expect(events.where((e) => e.action != null), isEmpty);
      expect(events.last.agentName, 'my_replanner');
    });

    test('is an action of the agent named, equal for equal names', () {
      final action = PlanExecute.breakLoopAction('my_replanner');
      expect(action.interrupted, isNull);
      expect(action.customizedAction, isNotNull);
      expect(
        PlanExecute.breakLoopAction('my_replanner').customizedAction,
        action.customizedAction,
      );
      expect(
        PlanExecute.breakLoopAction('other').customizedAction,
        isNot(action.customizedAction),
      );
      expect('${action.customizedAction}', contains('my_replanner'));
    });
  });
}
