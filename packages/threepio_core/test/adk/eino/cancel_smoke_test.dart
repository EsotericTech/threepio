// Smoke tests of the agent cancel (eino `adk/cancel.go`): immediate and
// safe-point cancels of a ChatModelAgent, the cancel handle's outcomes, a
// cancelled run's checkpoint and its resume, and a stream ended by an
// immediate cancel. The ports of eino's cancel tests are in
// `eino_cancel_test.dart`.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

/// One model call: waits for [gate] (if any), then answers [message], or
/// streams [chunks] with [chunkGates] before them.
final class _Turn {
  _Turn(this.message, {this.gate});
  _Turn.stream(this.chunks, {this.chunkGates = const {}}) : message = null, gate = null;

  final Message? message;
  final Future<void>? gate;
  List<Message> chunks = const [];
  Map<int, Future<void>> chunkGates = const {};
  final Completer<void> started = Completer<void>();
}

final class _Model extends BaseChatModel {
  _Model(this.turns);

  final List<_Turn> turns;
  int calls = 0;

  _Turn _next() {
    if (calls >= turns.length) throw StateError('script exhausted');
    final turn = turns[calls++];
    turn.started.complete();
    return turn;
  }

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    final turn = _next();
    await turn.gate;
    return turn.message!;
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async {
    final turn = _next();
    if (turn.message != null) {
      await turn.gate;
      return StreamReader.fromIterable([turn.message!]);
    }
    final (reader, writer) = pipe<Message>();
    unawaited(() async {
      for (final (index, chunk) in turn.chunks.indexed) {
        await turn.chunkGates[index];
        if (writer.send(chunk)) return;
      }
      await writer.close();
    }());
    return reader;
  }
}

final class _Tool extends InvokableTool {
  _Tool(this.toolName, {this.gate});

  final String toolName;
  final Future<void>? gate;
  final Completer<void> started = Completer<void>();
  int calls = 0;

  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: toolName,
        desc: 'a test tool',
        params: const {'input': ParameterInfo(type: DataType.string)},
      );

  @override
  Future<String> run(String argumentsJson) async {
    calls++;
    if (!started.isCompleted) started.complete();
    await gate;
    return 'tool result';
  }
}

Message _toolCall(String name, [String id = 'call_1']) => Message(
      role: RoleType.assistant,
      content: '',
      toolCalls: [
        ToolCall(
          id: id,
          function: FunctionCall(name: name, arguments: '{"input":"x"}'),
        ),
      ],
    );

ChatModelAgent _agent(BaseChatModel model, [List<BaseTool> tools = const []]) =>
    ChatModelAgent(
      ChatModelAgentConfig(
        name: 'agent',
        description: 'test agent',
        instruction: 'You are a test assistant',
        model: model,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)),
      ),
    );

AgentRunCancelledException? _cancelOf(List<AgentEvent> events) {
  for (final event in events) {
    final error = event.error;
    if (error is AgentRunCancelledException) return error;
  }
  return null;
}

void main() {
  final ctx = RunContext.background();

  test('immediate cancel during the model call', () async {
    final turn = _Turn(_toolCall('slow'), gate: Completer<void>().future);
    final model = _Model([turn]);
    final tool = _Tool('slow');
    final (option, cancel) = withCancel();
    final events = Runner(agent: _agent(model, [tool]))
        .query(ctx, 'go', options: [option]);
    final collected = events.collectAll();
    await turn.started.future;
    final handle = cancel();
    expect(handle.contributed, isTrue);
    expect(await handle.wait(), CancelOutcome.cancelled);
    final cancelled = _cancelOf(await collected);
    expect(cancelled, isNotNull);
    expect(cancelled!.info.isImmediate, isTrue);
    expect(cancelled.info.escalated, isFalse);
    expect(tool.calls, 0);
  });

  test('cancel after the model call: the tools do not run', () async {
    final release = Completer<void>();
    final turn = _Turn(_toolCall('slow'), gate: release.future);
    final model = _Model([turn]);
    final tool = _Tool('slow');
    final (option, cancel) = withCancel();
    final events = _agent(model, [tool]).run(
      ctx,
      AgentInput(messages: [Message.user('go')]),
      options: [option],
    );
    final collected = events.collectAll();
    await turn.started.future;
    final handle = cancel(safePoints: {CancelSafePoint.afterChatModel});
    release.complete();
    expect(await handle.wait(), CancelOutcome.cancelled);
    final all = await collected;
    final cancelled = _cancelOf(all);
    expect(cancelled, isNotNull);
    expect(cancelled!.info.safePoints, {CancelSafePoint.afterChatModel});
    expect(tool.calls, 0);
    // The model's message was sent before the cancel.
    expect(all.where((e) => e.output != null), hasLength(1));
  });

  test('cancel after the tool calls: the tool finishes, the model is not called again',
      () async {
    final release = Completer<void>();
    final model = _Model([_Turn(_toolCall('slow')), _Turn(Message.assistant('done'))]);
    final tool = _Tool('slow', gate: release.future);
    final (option, cancel) = withCancel();
    final events = _agent(model, [tool]).run(
      ctx,
      AgentInput(messages: [Message.user('go')]),
      options: [option],
    );
    final collected = events.collectAll();
    await tool.started.future;
    final handle = cancel(safePoints: {CancelSafePoint.afterToolCalls});
    release.complete();
    expect(await handle.wait(), CancelOutcome.cancelled);
    expect(_cancelOf(await collected), isNotNull);
    expect(tool.calls, 1);
    expect(model.calls, 1);
  });

  test('a cancel after the run ended reports executionEnded', () async {
    final model = _Model([_Turn(Message.assistant('hi'))]);
    final (option, cancel) = withCancel();
    final events =
        await Runner(agent: _agent(model)).query(ctx, 'go', options: [option]).collectAll();
    expect(_cancelOf(events), isNull);
    final handle = cancel();
    expect(handle.contributed, isFalse);
    expect(await handle.wait(), CancelOutcome.executionEnded);
  });

  test('a safe point that is never reached: the run ends, executionEnded', () async {
    final release = Completer<void>();
    final turn = _Turn(Message.assistant('final answer'), gate: release.future);
    final model = _Model([turn]);
    final (option, cancel) = withCancel();
    final collected =
        Runner(agent: _agent(model, [_Tool('t')])).query(ctx, 'go', options: [option]).collectAll();
    await turn.started.future;
    final handle = cancel(safePoints: {CancelSafePoint.afterChatModel});
    release.complete();
    expect(await handle.wait(), CancelOutcome.executionEnded);
    expect(_cancelOf(await collected), isNull);
  });

  test('timeout escalation to an immediate cancel', () async {
    final turn = _Turn(_toolCall('slow'), gate: Completer<void>().future);
    final model = _Model([turn]);
    final (option, cancel) = withCancel();
    final collected =
        Runner(agent: _agent(model, [_Tool('slow')])).query(ctx, 'go', options: [option]).collectAll();
    await turn.started.future;
    final handle = cancel(
      safePoints: {CancelSafePoint.afterChatModel},
      timeout: const Duration(milliseconds: 5),
    );
    expect(await handle.wait(), CancelOutcome.timedOut);
    final cancelled = _cancelOf(await collected);
    expect(cancelled!.info.escalated, isTrue);
    expect(cancelled.info.timeout, isTrue);
  });

  test('checkpoint on cancel and resume', () async {
    final release = Completer<void>();
    final model = _Model([
      _Turn(_toolCall('slow')),
      _Turn(Message.assistant('after resume')),
    ]);
    final tool = _Tool('slow', gate: release.future);
    final store = InMemoryCheckpointStore();
    final runner = Runner(agent: _agent(model, [tool]), checkpointStore: store);
    final (option, cancel) = withCancel();
    final collected = runner.query(
      ctx,
      'go',
      options: [option, AgentRunOption.checkpointId('cp')],
    ).collectAll();
    await tool.started.future;
    expect(await cancel().wait(), CancelOutcome.cancelled);
    final cancelled = _cancelOf(await collected);
    expect(cancelled, isNotNull);
    expect(cancelled!.interruptContexts, isNotEmpty);
    expect(await store.get('cp'), isNotNull);

    release.complete();
    final resumed = await (await runner.resume(ctx, 'cp')).collectAll();
    expect(resumed.where((e) => e.error != null), isEmpty);
    final last = await getMessageFromEvent(resumed.last);
    expect(last?.content, 'after resume');
    // The tool that was cut off ran again.
    expect(tool.calls, 2);
  });

  test('an immediate cancel ends the model stream', () async {
    final second = Completer<void>();
    final turn = _Turn.stream(
      [Message.assistant('Hello'), Message.assistant(' world')],
      chunkGates: {1: second.future},
    );
    final model = _Model([turn]);
    final (option, cancel) = withCancel();
    final events = Runner(agent: _agent(model), enableStreaming: true)
        .query(ctx, 'go', options: [option]);
    final first = await events.nextOrNull();
    final stream = first!.output!.messageOutput!.messageStream!;
    expect((await stream.recv()).content, 'Hello');
    expect(await cancel().wait(), CancelOutcome.cancelled);
    await expectLater(stream.recv(), throwsA(isA<StreamCanceledException>()));
    final rest = await events.collectAll();
    expect(_cancelOf(rest), isNotNull);
    second.complete();
  });
}
