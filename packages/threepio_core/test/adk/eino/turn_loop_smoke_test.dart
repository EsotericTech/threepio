// Smoke tests of the TurnLoop (eino `adk/turn_loop.go`): batching, a stop
// between turns, a preempt at a safe point, an immediate stop with a
// checkpoint and the loop that resumes it, late items, idle stop. The ports
// of eino's TurnLoop tests are in `eino_turn_loop_test.dart`.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

/// A model that answers each call with the next message, after its gate.
final class _Model extends BaseChatModel {
  _Model(this.replies, {this.gates = const {}});

  final List<Message> replies;
  final Map<int, Future<void>> gates;
  final List<List<Message>> inputs = [];
  final List<Completer<void>> started = List.generate(8, (_) => Completer<void>());

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    final index = inputs.length;
    inputs.add(List.of(input));
    started[index].complete();
    await gates[index];
    return index < replies.length ? replies[index] : Message.assistant('reply $index');
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

final class _Tool extends InvokableTool {
  _Tool({this.gate});

  final Future<void>? gate;
  final Completer<void> started = Completer<void>();
  int calls = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'work',
        desc: 'does work',
        params: const {'input': ParameterInfo(type: DataType.string)},
      );

  @override
  Future<String> run(String argumentsJson) async {
    calls++;
    if (!started.isCompleted) started.complete();
    await gate;
    return 'worked';
  }
}

Message _callWork() => Message(
      role: RoleType.assistant,
      content: '',
      toolCalls: [
        ToolCall(id: 'c1', function: FunctionCall(name: 'work', arguments: '{}')),
      ],
    );

Agent _agent(BaseChatModel model, [List<BaseTool> tools = const []]) => ChatModelAgent(
      ChatModelAgentConfig(
        name: 'agent',
        description: 'test agent',
        model: model,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)),
      ),
    );

TurnLoopConfig<String> _config(
  Agent agent, {
  List<List<String>>? turns,
  CheckpointStore? store,
  String checkpointId = '',
  Future<GenResumeResult<String>> Function(
    RunContext, TurnLoop<String>, List<String>, List<String>, List<String>)?
      genResume,
}) =>
    TurnLoopConfig<String>(
      genInput: (ctx, loop, items) async {
        turns?.add(List.of(items));
        return GenInputResult(
          input: AgentInput(messages: [for (final item in items) Message.user(item)]),
          consumed: items,
        );
      },
      prepareAgent: (ctx, loop, consumed) async => agent,
      genResume: genResume,
      store: store,
      checkpointId: checkpointId,
    );

void main() {
  final ctx = RunContext.background();

  test('items pushed before run are handled in one turn; a stop ends the loop', () async {
    final model = _Model([Message.assistant('done')]);
    final turns = <List<String>>[];
    final loop = TurnLoop<String>(_config(_agent(model), turns: turns));
    expect(loop.push('a').accepted, isTrue);
    expect(loop.push('b').accepted, isTrue);
    loop.run(ctx);
    await model.started[0].future;
    loop.stop();
    final exit = await loop.wait();
    expect(exit.exitReason, isNull);
    expect(turns, [
      ['a', 'b'],
    ]);
    expect(model.inputs.single.map((m) => m.content), ['a', 'b']);
    expect(exit.unhandledItems, isEmpty);
    expect(loop.push('late').accepted, isFalse);
    expect(exit.takeLateItems(), ['late']);
    expect(() => loop.push('later'), throwsStateError);
  });

  test('a preempt at the safe point after the tool calls starts a new turn', () async {
    final release = Completer<void>();
    final tool = _Tool(gate: release.future);
    final model = _Model([_callWork(), Message.assistant('second turn')]);
    final turns = <List<String>>[];
    final loop = TurnLoop<String>(_config(_agent(model, [tool]), turns: turns));
    loop
      ..push('first')
      ..run(ctx);
    await tool.started.future;
    final pushed = loop.push(
      'urgent',
      options: [PushOption.preempt({CancelSafePoint.afterToolCalls})],
    );
    expect(pushed.accepted, isTrue);
    await pushed.resolved;
    release.complete();
    await model.started[1].future;
    loop.stop();
    final exit = await loop.wait();
    expect(exit.exitReason, isNull);
    expect(turns, [
      ['first'],
      ['urgent'],
    ]);
    expect(tool.calls, 1);
  });

  test('an immediate stop cancels the turn, writes a checkpoint, and a new loop resumes it',
      () async {
    final model = _Model(
      [_callWork(), Message.assistant('resumed answer')],
      gates: {0: Completer<void>().future},
    );
    final store = InMemoryCheckpointStore();
    final loop = TurnLoop<String>(
      _config(_agent(model, [_Tool()]), store: store, checkpointId: 'loop'),
    );
    loop
      ..push('task')
      ..run(ctx);
    await model.started[0].future;
    loop.stop(options: [const StopOption.immediate(), const StopOption.cause('shutdown')]);
    final exit = await loop.wait();
    expect(exit.exitReason, isA<AgentRunCancelledException>());
    expect(exit.interruptedItems, ['task']);
    expect(exit.stopCause, 'shutdown');
    expect(exit.checkpointAttempted, isTrue);
    expect(exit.checkpointError, isNull);
    expect(await store.get('loop'), isNotNull);

    // The model call that was cut off is made again by the resumed turn.
    final resumedModel = _Model([_callWork(), Message.assistant('resumed answer')]);
    List<String>? resumedWith;
    final resumed = TurnLoop<String>(
      _config(
        _agent(resumedModel, [_Tool()]),
        store: store,
        checkpointId: 'loop',
        genResume: (ctx, loop, interrupted, unhandled, newItems) async {
          resumedWith = [...interrupted, '|', ...unhandled, '|', ...newItems];
          return GenResumeResult(consumed: interrupted);
        },
      ),
    );
    resumed
      ..push('new')
      ..run(ctx);
    await resumedModel.started[1].future;
    resumed.stop();
    final resumedExit = await resumed.wait();
    expect(resumedWith, ['task', '|', '|', 'new']);
    expect(resumedExit.exitReason, isNull);
  });

  test('an agent interrupt ends the loop with TurnLoopInterruptedException', () async {
    final model = _Model([
      Message(
        role: RoleType.assistant,
        content: '',
        toolCalls: [
          ToolCall(id: 'c1', function: FunctionCall(name: 'ask', arguments: '{}')),
        ],
      ),
    ]);
    final ask = FunctionTool<Map<String, Object?>, String>(
      name: 'ask',
      description: 'asks',
      params: const ParamsOneOf.params({}),
      fromJson: (json) => json,
      invoke: (ctx, input, options) => throw interrupt(ctx, 'need input'),
    );
    final store = InMemoryCheckpointStore();
    final loop = TurnLoop<String>(
      _config(_agent(model, [ask]), store: store, checkpointId: 'hitl'),
    );
    loop
      ..push('question')
      ..run(ctx);
    final exit = await loop.wait();
    expect(exit.exitReason, isA<TurnLoopInterruptedException>());
    final contexts = (exit.exitReason! as TurnLoopInterruptedException).interruptContexts;
    expect(contexts.any((c) => c.info == 'need input'), isTrue);
    expect(exit.interruptedItems, ['question']);
    expect(exit.checkpointAttempted, isTrue);
  });

  test('untilIdleFor stops an idle loop', () {
    fakeAsync((async) {
      final model = _Model([Message.assistant('ok')]);
      final loop = TurnLoop<String>(_config(_agent(model)))..run(ctx);
      TurnLoopExitState<String>? exit;
      unawaited(loop.wait().then((e) => exit = e));
      loop.stop(options: [StopOption.untilIdleFor(const Duration(seconds: 5))]);
      async.elapse(const Duration(seconds: 3));
      loop.push('work');
      async
        ..flushMicrotasks()
        ..elapse(const Duration(seconds: 3));
      expect(exit, isNull);
      async.elapse(const Duration(seconds: 3));
      expect(exit, isNotNull);
      expect(exit!.exitReason, isNull);
      expect(model.inputs, hasLength(1));
    });
  });

  test('a stop before run makes run exit at once', () async {
    final loop = TurnLoop<String>(_config(_agent(_Model([]))))
      ..push('x')
      ..stop()
      ..run(ctx);
    final exit = await loop.wait();
    expect(exit.exitReason, isNull);
    expect(exit.unhandledItems, ['x']);
  });

  test('option arguments are checked', () {
    expect(() => PushOption<String>.preempt({}), throwsArgumentError);
    expect(() => StopOption.untilIdleFor(Duration.zero), throwsArgumentError);
    expect(() => StopOption.gracefulTimeout(-const Duration(seconds: 1)), throwsArgumentError);
  });
}
