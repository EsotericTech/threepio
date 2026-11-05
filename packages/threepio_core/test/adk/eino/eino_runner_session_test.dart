// Ports eino v0.9.22 `adk/runner_test.go` and `adk/runctx_test.go`.
//
// From runner_test.go: TestNewRunner, TestRunner_Run, TestRunner_Query,
// TestRunner_Run_WithStreaming, TestRunner_Query_WithStreaming,
// TestResumeWithMissingCheckpoint (ported with a classic `Message` agent
// instead of eino's agentic `myAgenticAgent`).
// From runctx_test.go: TestSessionValues.
import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/agent_context.dart'
    show AdkRunContext, RunSession, initAdkRunContext, withAdkRunContext;

/// Port of eino's `mockRunnerAgent`: replays [responses] and records how it
/// was called.
class _MockRunnerAgent implements Agent {
  _MockRunnerAgent(this.name, this.description, this.responses);

  @override
  final String name;

  @override
  final String description;

  final List<AgentEvent> responses;

  int callCount = 0;
  AgentInput? lastInput;
  bool enableStreaming = false;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    callCount++;
    lastInput = input;
    enableStreaming = input.enableStreaming;

    final (reader, writer) = pipe<AgentEvent>();
    unawaited(() async {
      try {
        // eino stops at an event with an Exit action; Exit is not ported.
        for (final event in responses) {
          writer.send(event);
        }
      } finally {
        await writer.close();
      }
    }());
    return reader;
  }
}

/// Port of eino's `myAgenticAgent` for TestResumeWithMissingCheckpoint, with
/// classic messages: its run is a closure, and it cannot be resumed.
class _FnAgent implements Agent {
  _FnAgent(this.name, this.runFn);

  @override
  final String name;

  @override
  String get description => '';

  final StreamReader<AgentEvent> Function(
    RunContext ctx,
    AgentInput input,
    List<AgentRunOption> options,
  ) runFn;

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      runFn(ctx, input, options);
}

/// A context inside a fresh run session (eino: `setRunCtx(ctx,
/// &runContext{Session: newRunSession()})`).
RunContext _ctxWithSession() => withAdkRunContext(
      RunContext.background(),
      AdkRunContext(session: RunSession()),
    );

void main() {
  test('TestNewRunner', () {
    // Dart: the agent is a required parameter (eino accepts an empty
    // RunnerConfig), so the runner is built with one.
    final runner = Runner(agent: _MockRunnerAgent('a', 'd', const []));
    expect(runner, isNotNull);
  });

  test('TestRunner_Run', () async {
    final ctx = RunContext.background();
    final mockAgent = _MockRunnerAgent('TestAgent', 'Test agent for Runner', [
      AgentEvent(
        agentName: 'TestAgent',
        output: AgentOutput(
          messageOutput: MessageVariant.message(
            Message.assistant('Response from test agent'),
            role: RoleType.assistant,
          ),
        ),
      ),
    ]);

    final runner = Runner(agent: mockAgent);
    final msgs = [Message.user('Hello, agent!')];

    final iterator = runner.run(ctx, msgs);

    final event = await iterator.nextOrNull();
    // Dart: the runner's FlowAgent calls agent.run after the asynchronous
    // callbacks.onStart, so the call is checked once the first event arrived
    // (eino checks right after runner.Run, which calls the agent
    // synchronously).
    expect(mockAgent.callCount, 1);
    expect(mockAgent.lastInput!.messages, equals(msgs));
    expect(mockAgent.enableStreaming, isFalse);

    expect(event, isNotNull);
    expect(event!.agentName, 'TestAgent');
    expect(event.output, isNotNull);
    expect(event.output!.messageOutput, isNotNull);
    expect(event.output!.messageOutput!.message, isNotNull);
    expect(
      event.output!.messageOutput!.message!.content,
      'Response from test agent',
    );

    expect(await iterator.nextOrNull(), isNull);
  });

  test('TestRunner_Run_WithStreaming', () async {
    final ctx = RunContext.background();
    final mockAgent = _MockRunnerAgent('TestAgent', 'Test agent for Runner', [
      AgentEvent(
        agentName: 'TestAgent',
        output: AgentOutput(
          messageOutput: MessageVariant.stream(
            StreamReader.fromIterable([Message.assistant('Streaming response')]),
            role: RoleType.assistant,
          ),
        ),
      ),
    ]);

    final runner = Runner(agent: mockAgent, enableStreaming: true);
    final msgs = [Message.user('Hello, agent!')];

    final iterator = runner.run(ctx, msgs);

    final event = await iterator.nextOrNull();
    // Dart: checked after the first event; see TestRunner_Run.
    expect(mockAgent.callCount, 1);
    expect(mockAgent.lastInput!.messages, equals(msgs));
    expect(mockAgent.enableStreaming, isTrue);

    expect(event, isNotNull);
    expect(event!.agentName, 'TestAgent');
    expect(event.output, isNotNull);
    expect(event.output!.messageOutput, isNotNull);
    expect(event.output!.messageOutput!.isStreaming, isTrue);

    expect(await iterator.nextOrNull(), isNull);
  });

  test('TestRunner_Query', () async {
    final ctx = RunContext.background();
    final mockAgent = _MockRunnerAgent('TestAgent', 'Test agent for Runner', [
      AgentEvent(
        agentName: 'TestAgent',
        output: AgentOutput(
          messageOutput: MessageVariant.message(
            Message.assistant('Response to query'),
            role: RoleType.assistant,
          ),
        ),
      ),
    ]);

    final runner = Runner(agent: mockAgent);

    final iterator = runner.query(ctx, 'Test query');

    final event = await iterator.nextOrNull();
    // Dart: checked after the first event; see TestRunner_Run.
    expect(mockAgent.callCount, 1);
    expect(mockAgent.lastInput!.messages, hasLength(1));
    expect(mockAgent.lastInput!.messages[0].content, 'Test query');
    expect(mockAgent.enableStreaming, isFalse);

    expect(event, isNotNull);
    expect(event!.agentName, 'TestAgent');
    expect(event.output, isNotNull);
    expect(event.output!.messageOutput, isNotNull);
    expect(event.output!.messageOutput!.message, isNotNull);
    expect(event.output!.messageOutput!.message!.content, 'Response to query');

    expect(await iterator.nextOrNull(), isNull);
  });

  test('TestRunner_Query_WithStreaming', () async {
    final ctx = RunContext.background();
    final mockAgent = _MockRunnerAgent('TestAgent', 'Test agent for Runner', [
      AgentEvent(
        agentName: 'TestAgent',
        output: AgentOutput(
          messageOutput: MessageVariant.stream(
            StreamReader.fromIterable(
              [Message.assistant('Streaming query response')],
            ),
            role: RoleType.assistant,
          ),
        ),
      ),
    ]);

    final runner = Runner(agent: mockAgent, enableStreaming: true);

    final iterator = runner.query(ctx, 'Test query');

    final event = await iterator.nextOrNull();
    // Dart: checked after the first event; see TestRunner_Run.
    expect(mockAgent.callCount, 1);
    expect(mockAgent.lastInput!.messages, hasLength(1));
    expect(mockAgent.lastInput!.messages[0].content, 'Test query');
    expect(mockAgent.enableStreaming, isTrue);

    expect(event, isNotNull);
    expect(event!.agentName, 'TestAgent');
    expect(event.output, isNotNull);
    expect(event.output!.messageOutput, isNotNull);
    expect(event.output!.messageOutput!.isStreaming, isTrue);

    expect(await iterator.nextOrNull(), isNull);
  });

  test('TestResumeWithMissingCheckpoint', () async {
    final ctx = RunContext.background();
    final agent = _FnAgent('resume-agent', (ctx, input, options) {
      final (reader, writer) = pipe<AgentEvent>();
      unawaited(() async {
        try {
          writer.send(
            AgentEvent(
              output: AgentOutput(
                messageOutput: MessageVariant.message(Message.assistant('ok')),
              ),
            ),
          );
        } finally {
          await writer.close();
        }
      }());
      return reader;
    });

    final runner = Runner(agent: agent, checkpointStore: InMemoryCheckpointStore());

    // eino: "ResumeWithParams with nonexistent checkpoint should not panic";
    // an error is returned (Dart: thrown as a ThreepioException) or comes as
    // an event. Anything else thrown fails the test, as a panic would.
    final errors = <Object>[];
    try {
      final iter = await runner.resumeWithParams(
        ctx,
        'nonexistent-checkpoint',
        ResumeParams(targets: const {'fake-id': null}),
      );
      for (var event = await iter.nextOrNull();
          event != null;
          event = await iter.nextOrNull()) {
        if (event.error != null) errors.add(event.error!);
      }
    } on ThreepioException catch (error) {
      errors.add(error);
    }
    // Not pinned by eino; recorded so a failure shows what happened.
    addTearDown(() => printOnFailure('resume errors: $errors'));
  });

  group('TestSessionValues', () {
    test('BasicSessionValues', () {
      final ctx = _ctxWithSession();

      final values = <String, Object?>{
        'key1': 'value1',
        'key2': 42,
        'key3': true,
      };
      ctx.addSessionValues(values);

      final retrievedValues = ctx.sessionValues;

      expect(retrievedValues['key1'], 'value1');
      expect(retrievedValues['key2'], 42);
      expect(retrievedValues['key3'], true);
      expect(retrievedValues, hasLength(3));
    });

    test('AddSessionValuesEmptyContext', () {
      final ctx = RunContext.background();

      ctx.addSessionValues({'key1': 'value1'});

      final retrievedValues = ctx.sessionValues;
      expect(retrievedValues, isEmpty);
    });

    test('GetSessionValuesEmptyContext', () {
      final ctx = RunContext.background();

      final retrievedValues = ctx.sessionValues;
      expect(retrievedValues, isEmpty);
    });

    // AddSessionValuesNilValues is not ported: the map parameter is not
    // nullable in Dart, so `addSessionValues(null)` does not compile.

    test('AddSessionValuesEmptyValues', () {
      final ctx = _ctxWithSession();

      ctx.addSessionValues(const {});

      final retrievedValues = ctx.sessionValues;
      expect(retrievedValues, isEmpty);
    });

    test('AddSessionValuesComplexTypes', () {
      final ctx = _ctxWithSession();

      final values = <String, Object?>{
        'string': 'hello world',
        'int': 123,
        'float': 45.67,
        'bool': true,
        'slice': ['a', 'b', 'c'],
        'map': {'x': 1, 'y': 2},
        // Go: struct{ Name string }{Name: "test"}.
        'struct': (name: 'test'),
      };
      ctx.addSessionValues(values);

      final retrievedValues = ctx.sessionValues;

      expect(retrievedValues['string'], 'hello world');
      expect(retrievedValues['int'], 123);
      expect(retrievedValues['float'], 45.67);
      expect(retrievedValues['bool'], true);
      expect(retrievedValues['slice'], equals(['a', 'b', 'c']));
      expect(retrievedValues['map'], equals({'x': 1, 'y': 2}));
      expect(retrievedValues['struct'], (name: 'test'));
      expect(retrievedValues, hasLength(7));
    });

    test('AddSessionValuesOverwrite', () {
      final ctx = _ctxWithSession();

      ctx.addSessionValues({'key1': 'initial1', 'key2': 'initial2'});
      ctx.addSessionValues({'key1': 'overwritten1', 'key3': 'new3'});

      final retrievedValues = ctx.sessionValues;

      expect(retrievedValues['key1'], 'overwritten1');
      expect(retrievedValues['key2'], 'initial2');
      expect(retrievedValues['key3'], 'new3');
      expect(retrievedValues, hasLength(3));
    });

    test('ConcurrentSessionValues', () async {
      final ctx = _ctxWithSession();

      ctx.addSessionValues({'counter': 0});

      // Go: two goroutines; Dart: two interleaved asynchronous loops.
      Future<void> writer(String key) async {
        for (var i = 0; i < 100; i++) {
          ctx.addSessionValues({key: i});
          await Future<void>.delayed(Duration.zero);
        }
      }

      await Future.wait([writer('goroutine1'), writer('goroutine2')]);

      final retrievedValues = ctx.sessionValues;
      expect(retrievedValues['counter'], 0);
      expect(retrievedValues['goroutine1'], 99);
      expect(retrievedValues['goroutine2'], 99);
    });

    test('GetSessionValueIndividual', () {
      final ctx = _ctxWithSession();

      ctx.addSessionValues({'key1': 'value1', 'key2': 42});

      final value1 = ctx.sessionValue('key1');
      final exists1 = ctx.hasSessionValue('key1');
      final value2 = ctx.sessionValue('key2');
      final exists2 = ctx.hasSessionValue('key2');
      final value3 = ctx.sessionValue('nonexistent');
      final exists3 = ctx.hasSessionValue('nonexistent');

      expect(exists1, isTrue);
      expect(value1, 'value1');

      expect(exists2, isTrue);
      expect(value2, 42);

      expect(exists3, isFalse);
      expect(value3, isNull);
    });

    test('AddSessionValueIndividual', () {
      final ctx = _ctxWithSession();

      ctx
        ..addSessionValue('key1', 'value1')
        ..addSessionValue('key2', 42);

      final retrievedValues = ctx.sessionValues;

      expect(retrievedValues['key1'], 'value1');
      expect(retrievedValues['key2'], 42);
      expect(retrievedValues, hasLength(2));
    });

    test('AddSessionValueEmptyContext', () {
      final ctx = RunContext.background();

      ctx.addSessionValue('key1', 'value1');

      expect(ctx.hasSessionValue('key1'), isFalse);
      expect(ctx.sessionValue('key1'), isNull);

      final retrievedValues = ctx.sessionValues;
      expect(retrievedValues, isEmpty);
    });

    test('IntegrationWithRunContext', () {
      final input = AgentInput(messages: [Message.user('test input')]);
      final (ctx, runCtx) =
          initAdkRunContext(RunContext.background(), 'test-agent', input);

      expect(runCtx, isNotNull);
      expect(runCtx.session, isNotNull);

      ctx.addSessionValues({'integration_key': 'integration_value'});

      final retrievedValues = ctx.sessionValues;
      expect(retrievedValues['integration_key'], 'integration_value');

      // RunPath is not ported; depth stands in for its length (eino also
      // checks RunPath[0].agentName == "test-agent").
      expect(runCtx.depth, 1);
    });
  });
}
