// Ports eino v0.9.22 `adk/callback_integration_test.go`:
//   TestCallbackOnStartInvocation, TestCallbackOnEndInvocation,
//   TestCallbackRunInfoForChatModelAgent, TestMultipleCallbackHandlers.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

/// The gomock `MockToolCallingChatModel` of the Go tests: `Generate` answers
/// "test response" and is expected exactly once (`Times(1)`), `WithTools`
/// returns the model (`AnyTimes()`), `Stream` is not expected. Calls are
/// counted and checked by [verify] (Go: `ctrl.Finish()`).
class _MockModel extends ToolCallingChatModel {
  int generateCalls = 0;
  int streamCalls = 0;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    generateCalls++;
    return Message.assistant('test response');
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    streamCalls++;
    throw StateError('unexpected call to Stream');
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;

  void verify() {
    expect(generateCalls, 1, reason: 'Generate: expected exactly 1 call');
    expect(streamCalls, 0, reason: 'Stream: unexpected call');
  }
}

/// Port of Go `callbackRecorder`.
class _CallbackRecorder {
  bool onStartCalled = false;
  bool onEndCalled = false;
  RunInfo? runInfo;
  AgentCallbackInput? inputReceived;
  final List<AgentEvent> eventsReceived = [];
  late Completer<void> eventsDone;

  void closeOnce() {
    if (!eventsDone.isCompleted) eventsDone.complete();
  }
}

/// Port of Go `newRecordingHandler`.
ComponentCallbackHandler _newRecordingHandler(_CallbackRecorder recorder) {
  recorder.eventsDone = Completer<void>();
  return CallbackHandlerBuilder()
      .onStart((ctx, info, input) {
        if (info.componentType != ComponentType.agent) return ctx;
        recorder
          ..onStartCalled = true
          ..runInfo = info;
        final agentInput = AgentCallbackInput.from(input);
        if (agentInput != null) recorder.inputReceived = agentInput;
        return ctx;
      })
      .onEnd((ctx, info, output) {
        if (info.componentType != ComponentType.agent) return ctx;
        recorder
          ..onEndCalled = true
          ..runInfo = info;

        final agentOutput = AgentCallbackOutput.from(output);
        if (agentOutput != null) {
          final events = agentOutput.events;
          unawaited(() async {
            try {
              for (var event = await events.nextOrNull();
                  event != null;
                  event = await events.nextOrNull()) {
                recorder.eventsReceived.add(event);
              }
            } finally {
              recorder.closeOnce();
            }
          }());
          return ctx;
        }
        recorder.closeOnce();
        return ctx;
      })
      .build();
}

Future<void> _drain(StreamReader<AgentEvent> iter) async {
  while (await iter.nextOrNull() != null) {}
}

void main() {
  test('TestCallbackOnStartInvocation', () async {
    final ctx = RunContext.background();
    final cm = _MockModel();

    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestAgent',
      description: 'Test agent for callback',
      instruction: 'You are a test agent',
      model: cm,
    ));

    final recorder = _CallbackRecorder();
    final handler = _newRecordingHandler(recorder);

    final runner = Runner(agent: agent);
    await _drain(
      runner.query(ctx, 'hello', options: [AgentRunOption.callbacks([handler])]),
    );

    await recorder.eventsDone.future;

    expect(recorder.onStartCalled, isTrue, reason: 'OnStart should be called');
    expect(recorder.inputReceived, isNotNull, reason: 'Input should be received');
    expect(recorder.inputReceived!.input, isNotNull, reason: 'AgentInput should be set');
    expect(recorder.inputReceived!.input!.messages, hasLength(1));
    cm.verify();
  });

  test('TestCallbackOnEndInvocation', () async {
    final ctx = RunContext.background();
    final cm = _MockModel();

    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestAgent',
      description: 'Test agent for callback',
      instruction: 'You are a test agent',
      model: cm,
    ));

    final recorder = _CallbackRecorder();
    final handler = _newRecordingHandler(recorder);

    final runner = Runner(agent: agent);
    await _drain(
      runner.query(ctx, 'hello', options: [AgentRunOption.callbacks([handler])]),
    );

    await recorder.eventsDone.future;

    expect(recorder.onEndCalled, isTrue, reason: 'OnEnd should be called');
    expect(recorder.eventsReceived, isNotEmpty, reason: 'Events should be received');
    cm.verify();
  });

  test('TestCallbackRunInfoForChatModelAgent', () async {
    final ctx = RunContext.background();
    final cm = _MockModel();

    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestChatAgent',
      description: 'Test chat agent',
      instruction: 'You are a test agent',
      model: cm,
    ));

    final recorder = _CallbackRecorder();
    final handler = _newRecordingHandler(recorder);

    final runner = Runner(agent: agent);
    await _drain(
      runner.query(ctx, 'hello', options: [AgentRunOption.callbacks([handler])]),
    );

    await recorder.eventsDone.future;

    expect(recorder.runInfo, isNotNull);
    expect(recorder.runInfo!.name, 'TestChatAgent');
    expect(recorder.runInfo!.type, 'ChatModel');
    expect(recorder.runInfo!.componentType, ComponentType.agent);
    cm.verify();
  });

  test('TestMultipleCallbackHandlers', () async {
    final ctx = RunContext.background();
    final cm = _MockModel();

    final agent = ChatModelAgent(ChatModelAgentConfig(
      name: 'TestAgent',
      description: 'Test agent',
      instruction: 'You are a test agent',
      model: cm,
    ));

    final recorder1 = _CallbackRecorder();
    final recorder2 = _CallbackRecorder();
    final handler1 = _newRecordingHandler(recorder1);
    final handler2 = _newRecordingHandler(recorder2);

    final runner = Runner(agent: agent);
    await _drain(
      runner.query(
        ctx,
        'hello',
        options: [AgentRunOption.callbacks([handler1, handler2])],
      ),
    );

    await recorder1.eventsDone.future;
    await recorder2.eventsDone.future;

    expect(recorder1.onStartCalled, isTrue, reason: 'Handler1 OnStart should be called');
    expect(recorder2.onStartCalled, isTrue, reason: 'Handler2 OnStart should be called');
    expect(recorder1.onEndCalled, isTrue, reason: 'Handler1 OnEnd should be called');
    expect(recorder2.onEndCalled, isTrue, reason: 'Handler2 OnEnd should be called');

    expect(recorder1.eventsReceived, isNotEmpty, reason: 'Handler1 should receive events');
    expect(recorder2.eventsReceived, isNotEmpty, reason: 'Handler2 should receive events');
    cm.verify();
  });
}
