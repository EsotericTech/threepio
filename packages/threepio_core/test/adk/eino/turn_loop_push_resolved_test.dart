// `TurnLoop.push` returns `resolved == null` wherever eino's `Push` returns a
// nil ack channel (coordinator decision 2 after P7): a push without preempt,
// a push whose strategy asks for no preempt, and a push that is not accepted.
// A preemptive push that is accepted always has a future, which completes at
// once when the loop has not started (eino closes the channel at once).
//
// Go: `adk/turn_loop.go` `pushWithConfig`, `pushWithStrategy`; the nil-ack
// assertions of `TestTurnLoop_PushStrategy_NoPreempt`,
// `TestTurnLoop_PushStrategy_NestedStrategyStripped` and
// `TestTurnLoop_ResumeWaitsForInFlightPushBeforePlanning`.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

final class _Model extends BaseChatModel {
  final Completer<void> started = Completer<void>();
  final Completer<void> gate = Completer<void>();

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    return Message.assistant('done');
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async =>
      StreamReader.fromIterable([await generate(input, options: options)]);
}

TurnLoop<String> _loop(BaseChatModel model) => TurnLoop<String>(
      TurnLoopConfig<String>(
        genInput: (ctx, loop, items) async => GenInputResult(
          input: AgentInput(messages: [for (final item in items) Message.user(item)]),
          consumed: items,
        ),
        prepareAgent: (ctx, loop, consumed) async => ChatModelAgent(
          ChatModelAgentConfig(name: 'agent', description: 'test agent', model: model),
        ),
      ),
    );

const _any = {CancelSafePoint.afterChatModel, CancelSafePoint.afterToolCalls};

void main() {
  final ctx = RunContext.background();

  test('a push without preempt has no resolved future', () async {
    final model = _Model();
    final loop = _loop(model);
    final pushed = loop.push('a');
    expect(pushed.accepted, isTrue);
    expect(pushed.resolved, isNull);
    loop.run(ctx);
    await model.started.future;
    final during = loop.push('b');
    expect(during.accepted, isTrue);
    expect(during.resolved, isNull);
    model.gate.complete();
    loop.stop();
    await loop.wait();
  });

  test('a push whose strategy asks for no preempt has no resolved future', () {
    final loop = _loop(_Model());
    final pushed = loop.push(
      'a',
      options: [
        PushOption.preempt(_any),
        PushOption.strategy((ctx, tc) => const []),
      ],
    );
    expect(pushed.accepted, isTrue);
    expect(pushed.resolved, isNull);
  });

  test('a preemptive push before run has a future that is complete at once', () async {
    final loop = _loop(_Model());
    final pushed = loop.push('a', options: [PushOption.preempt(_any)]);
    expect(pushed.accepted, isTrue);
    expect(pushed.resolved, isNotNull);
    var completed = false;
    unawaited(pushed.resolved!.then((_) => completed = true));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isTrue);
  });

  test('a strategy that asks for a preempt gets a resolved future', () async {
    final loop = _loop(_Model());
    final pushed = loop.push(
      'a',
      options: [PushOption.strategy((ctx, tc) => [PushOption.preempt(_any)])],
    );
    expect(pushed.accepted, isTrue);
    expect(pushed.resolved, isNotNull);
    await pushed.resolved;
  });

  test('a push that is not accepted has no resolved future, with or without preempt', () async {
    final model = _Model()..gate.complete();
    final loop = _loop(model)..run(ctx);
    loop.stop();
    await loop.wait();
    final plain = loop.push('late');
    expect(plain.accepted, isFalse);
    expect(plain.resolved, isNull);
    final preemptive = loop.push('late 2', options: [PushOption.preempt(_any)]);
    expect(preemptive.accepted, isFalse);
    expect(preemptive.resolved, isNull);
    final viaStrategy = loop.push(
      'late 3',
      options: [PushOption.strategy((ctx, tc) => [PushOption.preempt(_any)])],
    );
    expect(viaStrategy.accepted, isFalse);
    expect(viaStrategy.resolved, isNull);
  });
}
