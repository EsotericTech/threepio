// Regression tests for the findings of the independent P6 review: a custom
// agent that throws (with and without callbacks), tool binding under
// failover, the cause of RetryExhaustedException, the sleep of a retry, the
// AgentTool's request and interrupt checks, and run-local value presence.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/model_retry.dart';
import 'package:threepio_core/src/adk/eino/react_graph.dart';
import 'package:threepio_core/src/compose/local_state.dart';

import '../../support/scripted_chat_model.dart';

final class _ThrowingAgent implements ResumableAgent {
  @override
  String get name => 'thrower';

  @override
  String get description => 'throws';

  @override
  StreamReader<AgentEvent> run(RunContext ctx, AgentInput input, {List<AgentRunOption> options = const []}) =>
      throw StateError('run blew up');

  @override
  StreamReader<AgentEvent> resume(RunContext ctx, ResumeInfo info, {List<AgentRunOption> options = const []}) =>
      throw StateError('resume blew up');
}

final class _InterruptWithoutSignal implements Agent {
  @override
  String get name => 'bare';

  @override
  String get description => 'interrupts by hand';

  @override
  StreamReader<AgentEvent> run(RunContext ctx, AgentInput input, {List<AgentRunOption> options = const []}) =>
      StreamReader.fromIterable([
        AgentEvent(action: AgentAction(interrupted: AgentInterruptInfo(data: 'x'))),
      ]);
}

final class _AnswerAgent implements Agent {
  final List<String> requests = [];

  @override
  String get name => 'answer';

  @override
  String get description => 'answers';

  @override
  StreamReader<AgentEvent> run(RunContext ctx, AgentInput input, {List<AgentRunOption> options = const []}) {
    requests.add(input.messages.single.content);
    return StreamReader.fromIterable([AgentEvent.fromMessage(Message.assistant('done'))]);
  }
}

/// A callback-aware model that only honours tools bound with `withTools`.
final class _BoundOnlyModel extends ToolCallingChatModel implements CallbackAwareComponent {
  _BoundOnlyModel([this.tools, List<List<String>>? seen]) : seen = seen ?? [];

  final List<ToolInfo>? tools;
  final List<List<String>> seen;

  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    seen.add([for (final tool in tools ?? const <ToolInfo>[]) tool.function.name]);
    return Message.assistant('ok');
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => _BoundOnlyModel(tools, seen);
}

class _Echo extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(name: 'echo', desc: 'echo', params: const {});

  @override
  Future<String> run(String argumentsJson) async => argumentsJson;
}

void main() {
  group('a custom agent whose run or resume throws', () {
    test('without callbacks: one error event', () async {
      final events = await Runner(agent: _ThrowingAgent()).query(RunContext.background(), 'go').collectAll();
      expect('${events.single.error}', contains('run blew up'));
    });

    test('with callbacks: the error is named and onEnd sees it', () async {
      final ended = <AgentEvent>[];
      final done = <Future<void>>[];
      final handler = CallbackHandlerBuilder()
          .onEnd((ctx, info, output) {
            final events = AgentCallbackOutput.from(output)?.events;
            if (events != null) done.add(events.collectAll().then(ended.addAll));
            return ctx;
          })
          .build();
      final events = await Runner(agent: _ThrowingAgent())
          .query(RunContext.background(), 'go', options: [AgentRunOption.callbacks([handler])])
          .collectAll();
      expect(events.single.agentName, 'thrower');
      expect('${events.single.error}', contains('run blew up'));
      await Future.wait(done);
      expect('${ended.single.error}', contains('run blew up'));
    });
  });

  test('failover binds the tools to a callback-aware model that only honours withTools', () async {
    final primary = _BoundOnlyModel();
    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'a',
      model: primary,
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [_Echo()])),
      modelFailoverConfig: ModelFailoverConfig(
        shouldFailover: (_, __, ___) => false,
        getFailoverModel: (_, __) => (primary, null),
      ),
    ));
    final events = await Runner(agent: agent).query(RunContext.background(), 'go').collectAll();
    expect(events.map((e) => e.error), everyElement(isNull));
    expect(primary.seen.single, ['echo']);
  });

  test('sleepUnlessCancelled: no wait, no failure, for a delay of zero', () async {
    final token = CancelToken()..cancel();
    final ctx = RunContext.background(cancelToken: token);
    await sleepUnlessCancelled(ctx, Duration.zero);
    expect(sleepUnlessCancelled(ctx, const Duration(milliseconds: 1)), throwsA(isA<CancelledException>()));
  });

  group('AgentTool', () {
    test('a request that is not a string is refused', () async {
      final agent = _AnswerAgent();
      final tool = AgentTool(agent);
      expect(
        tool.invokableRun(RunContext.background(), jsonEncode({'request': 3})),
        throwsA(isA<ThreepioFormatException>()),
      );
      expect(await tool.invokableRun(RunContext.background(), jsonEncode({'request': 'hi'})), 'done');
      expect(agent.requests, ['hi']);
    });

    test('an interrupt without a signal is an error, not an empty result', () async {
      final tool = AgentTool(_InterruptWithoutSignal());
      expect(
        tool.invokableRun(RunContext.background(), jsonEncode({'request': 'hi'})),
        throwsA(isA<ThreepioException>().having((e) => e.message, 'message', contains('without an interrupt signal'))),
      );
    });
  });

  test('hasRunLocalValue tells a missing key from a null value', () {
    final ctx = withInternalState(RunContext.background(), ReactState());
    expect(ctx.hasRunLocalValue('k'), isFalse);
    ctx.setRunLocalValue('k', null);
    expect(ctx.hasRunLocalValue('k'), isTrue);
    expect(ctx.runLocalValue('k'), isNull);
    expect(() => RunContext.background().hasRunLocalValue('k'), throwsStateError);
  });

  test('a failing tool info() is sent as it is, a failing beforeAgent with the prefix', () async {
    final broken = ChatModelAgent(ChatModelAgentConfig(
      name: 'a',
      model: ScriptedChatModel([]),
      toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [_BrokenInfo()])),
    ));
    final first = await Runner(agent: broken).query(RunContext.background(), 'go').collectAll();
    expect(first.single.error, isA<StateError>());
    final second = await Runner(agent: broken).query(RunContext.background(), 'go').collectAll();
    expect(second.single.error, isA<StateError>(), reason: 'kept for every run, as eino');

    final failingHook = ChatModelAgent(ChatModelAgentConfig(
      name: 'b',
      model: ScriptedChatModel([]),
      handlers: const [_FailingBeforeAgent()],
    ));
    final events = await Runner(agent: failingHook).query(RunContext.background(), 'go').collectAll();
    expect('${events.single.error}', contains('ChatModelAgent getRunFunc error'));
    expect('${events.single.error}', contains('BeforeAgent failed'));
  });
}

class _BrokenInfo extends InvokableTool {
  @override
  Future<ToolInfo> info() async => throw StateError('no info');

  @override
  Future<String> run(String argumentsJson) async => '';
}

final class _FailingBeforeAgent extends ChatModelAgentMiddleware {
  const _FailingBeforeAgent();

  @override
  Future<(RunContext, ChatModelAgentContext)> beforeAgent(RunContext ctx, ChatModelAgentContext agent) =>
      throw StateError('hook');
}
