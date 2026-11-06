// Ports eino v0.9.22 `adk/agentic_callback_integration_test.go`:
//   TestAgenticCallback (OnStart_Invocation, OnEnd_Invocation,
//   RunInfo_Fields, Events_MatchAgentOutput), TestAgenticCallbackMultipleHandlers,
//   TestCoverage_WrapAgenticIterWithOnEnd (through the flow agent, which is
//   where eino's `wrapAgenticIterWithOnEnd` runs); plus the typed handler
//   through `HandlerHelper.agenticAgent` (written for the port).
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/agentic/agentic_runner.dart'
    show AgenticFlowAgent;

import 'agentic_fakes.dart';

/// Port of Go `agenticCallbackRecorder`.
class _Recorder {
  bool onStartCalled = false;
  bool onEndCalled = false;
  RunInfo? runInfo;
  AgenticAgentCallbackInput? inputReceived;
  final List<AgenticAgentEvent> eventsReceived = [];
  final Completer<void> eventsDone = Completer<void>();

  void closeOnce() {
    if (!eventsDone.isCompleted) eventsDone.complete();
  }
}

/// Port of Go `newAgenticRecordingHandler`.
ComponentCallbackHandler _recordingHandler(_Recorder recorder) =>
    CallbackHandlerBuilder()
        .onStart((ctx, info, input) {
          if (info.componentType != ComponentType.agenticAgent) return ctx;
          recorder
            ..onStartCalled = true
            ..runInfo = info;
          final agentInput = AgenticAgentCallbackInput.from(input);
          if (agentInput != null) recorder.inputReceived = agentInput;
          return ctx;
        })
        .onEnd((ctx, info, output) {
          if (info.componentType != ComponentType.agenticAgent) return ctx;
          recorder
            ..onEndCalled = true
            ..runInfo = info;
          final agentOutput = AgenticAgentCallbackOutput.from(output);
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

void main() {
  final ctx = RunContext.background();

  group('TestAgenticCallback', () {
    const expectedContent = 'This is the test response content';
    late _Recorder recorder;
    late List<AgenticAgentEvent> agentEvents;

    setUpAll(() async {
      final m = MockAgenticModel(
        onGenerate: (_, __) async => agenticMsg(expectedContent),
      );
      final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
        name: 'TestChatAgent',
        description: 'Test chat agent',
        instruction: 'You are a test agent',
        model: m,
      ));
      recorder = _Recorder();
      final handler = _recordingHandler(recorder);
      agentEvents = await drainAgenticEvents(
        AgenticRunner(agent: agent).query(
          ctx,
          'hello',
          options: [AgentRunOption.callbacks([handler])],
        ),
      );
      await recorder.eventsDone.future;
      expect(agenticEventRoleProblems(agentEvents), isEmpty);
    });

    test('OnStart_Invocation', () {
      expect(recorder.onStartCalled, isTrue, reason: 'OnStart should be called');
      expect(recorder.inputReceived, isNotNull);
      expect(recorder.inputReceived!.input, isNotNull);
      expect(recorder.inputReceived!.input!.messages, hasLength(1));
    });

    test('OnEnd_Invocation', () {
      expect(recorder.onEndCalled, isTrue, reason: 'OnEnd should be called');
      expect(recorder.eventsReceived, hasLength(1));
    });

    test('RunInfo_Fields', () {
      expect(recorder.runInfo, isNotNull);
      expect(recorder.runInfo!.name, 'TestChatAgent');
      expect(recorder.runInfo!.componentType, ComponentType.agenticAgent);
      expect(recorder.runInfo!.type, 'ChatModel');
    });

    test('Events_MatchAgentOutput', () {
      expect(agentEvents, isNotEmpty);
      final received = recorder.eventsReceived;
      expect(received, hasLength(1));
      expect(
        agenticTextContent(received[0].output!.messageOutput!.message),
        expectedContent,
      );
    });
  });

  test('TestAgenticCallbackMultipleHandlers', () async {
    final m = MockAgenticModel(
      onGenerate: (_, __) async => agenticMsg('test response'),
    );
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'TestAgent',
      description: 'Test agent',
      instruction: 'You are a test agent',
      model: m,
    ));
    final recorder1 = _Recorder();
    final recorder2 = _Recorder();
    await drainAgenticEvents(
      AgenticRunner(agent: agent).query(
        ctx,
        'hello',
        options: [
          AgentRunOption.callbacks([
            _recordingHandler(recorder1),
            _recordingHandler(recorder2),
          ]),
        ],
      ),
    );
    await recorder1.eventsDone.future;
    await recorder2.eventsDone.future;
    expect(recorder1.onStartCalled, isTrue);
    expect(recorder2.onStartCalled, isTrue);
    expect(recorder1.onEndCalled, isTrue);
    expect(recorder2.onEndCalled, isTrue);
    expect(recorder1.eventsReceived, isNotEmpty);
    expect(recorder2.eventsReceived, isNotEmpty);
  });

  test('TestCoverage_WrapAgenticIterWithOnEnd', () async {
    var onEndCalled = false;
    final handler = CallbackHandlerBuilder()
        .onStart((ctx, info, input) => ctx)
        .onEnd((ctx, info, output) {
          if (info.componentType == ComponentType.agenticAgent) {
            onEndCalled = true;
          }
          return ctx;
        })
        .build();
    final agent = MyAgenticAgent(
      name: 'test-agent',
      runFn: (ctx, input, options) => StreamReader.fromIterable([
        AgenticAgentEvent(
          output: AgenticAgentOutput(
            messageOutput: AgenticMessageVariant.message(agenticMsg('done')),
          ),
        ),
      ]),
    );
    final events = await drainAgenticEvents(
      AgenticFlowAgent(agent).run(
        ctx,
        AgenticAgentInput(messages: [AgenticMessage.user('Hi')]),
        [AgentRunOption.callbacks([handler])],
      ),
    );
    expect(events, hasLength(1));
    expect(events.single.agentName, 'test-agent');
    expect(onEndCalled, isTrue, reason: 'OnEnd callback should have been called');
  });

  test('typedAgenticAgentCallbackHandler through HandlerHelper', () async {
    AgenticAgentCallbackInput? started;
    final ended = Completer<List<AgenticAgentEvent>>();
    final handler = HandlerHelper()
        .agenticAgent(
          typedAgenticAgentCallbackHandler(
            onStart: (ctx, info, input) {
              started = input;
              return ctx;
            },
            onEnd: (ctx, info, output) {
              unawaited(drainAgenticEvents(output!.events).then(ended.complete));
              return ctx;
            },
          ),
        )
        .handler();
    final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
      name: 'typed',
      model: MockAgenticModel(onGenerate: (_, __) async => agenticMsg('hi')),
    ));
    await drainAgenticEvents(
      AgenticRunner(agent: agent)
          .query(ctx, 'hello', options: [AgentRunOption.callbacks([handler])]),
    );
    expect(started!.input!.messages.single, AgenticMessage.user('hello'));
    final events = await ended.future;
    expect(agenticTextContent(events.single.output!.messageOutput!.message), 'hi');
  });
}
