import 'package:test/test.dart';
import 'package:threepio_core/src/adk/core/agent_exception.dart';
import 'package:threepio_core/src/adk/core/base_agent.dart';
import 'package:threepio_core/src/adk/events/agent_event.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

void main() {
  group('AgentRunContext', () {
    test('creates with default values', () {
      final context = AgentRunContext();

      expect(context.runId, isNotEmpty);
      expect(context.parentRunId, isNull);
      expect(context.maxIterations, 10);
      expect(context.timeout, isNull);
      expect(context.metadata, isEmpty);
      expect(context.isCancelled, false);
    });

    test('creates with custom values', () {
      final context = AgentRunContext(
        runId: 'custom-run',
        parentRunId: 'parent',
        maxIterations: 5,
        timeout: Duration(seconds: 30),
        metadata: {'key': 'value'},
      );

      expect(context.runId, 'custom-run');
      expect(context.parentRunId, 'parent');
      expect(context.maxIterations, 5);
      expect(context.timeout, Duration(seconds: 30));
      expect(context.metadata, {'key': 'value'});
    });

    test('child creates nested context', () {
      final parent = AgentRunContext(
        runId: 'parent-run',
        maxIterations: 10,
        metadata: {'parent': 'data'},
      );

      final child = parent.child(
        maxIterations: 5,
        additionalMetadata: {'child': 'data'},
      );

      expect(child.parentRunId, 'parent-run');
      expect(child.runId, isNot('parent-run'));
      expect(child.maxIterations, 5);
      expect(child.metadata['parent'], 'data');
      expect(child.metadata['child'], 'data');
    });

    test('copyWith creates modified copy', () {
      final original = AgentRunContext(
        runId: 'original',
        maxIterations: 10,
      );

      final copy = original.copyWith(
        maxIterations: 5,
      );

      expect(copy.runId, 'original');
      expect(copy.maxIterations, 5);
    });

    test('isCancelled checks shouldCancel callback', () {
      var shouldCancel = false;
      final context = AgentRunContext(
        shouldCancel: () => shouldCancel,
      );

      expect(context.isCancelled, false);

      shouldCancel = true;
      expect(context.isCancelled, true);
    });

    test('onEvent callback receives events', () {
      final events = <AgentEvent>[];
      final context = AgentRunContext(
        onEvent: (event) => events.add(event),
      );

      final event = AgentOutputEvent(
        message: Message.assistant('Test'),
        runId: context.runId,
      );

      context.onEvent?.call(event);

      expect(events.length, 1);
      expect(events.first, event);
    });
  });

  group('AgentStepResult', () {
    test('creates with required fields', () {
      final result = AgentStepResult(
        messages: [Message.assistant('Response')],
        actions: [],
      );

      expect(result.messages.length, 1);
      expect(result.actions, isEmpty);
      expect(result.shouldContinue, true);
      expect(result.error, isNull);
      expect(result.hasError, false);
    });

    test('hasError returns true when error present', () {
      final result = AgentStepResult(
        messages: [],
        actions: [],
        error: Exception('Test error'),
      );

      expect(result.hasError, true);
    });

    test('shouldContinue can be false', () {
      final result = AgentStepResult(
        messages: [],
        actions: [],
        shouldContinue: false,
      );

      expect(result.shouldContinue, false);
    });
  });

  group('AgentException types', () {
    test('MaxIterationsExceededException contains iteration info', () {
      final exception = MaxIterationsExceededException(
        iterations: 15,
        maxIterations: 10,
        agentName: 'test-agent',
        runId: 'run-1',
      );

      expect(exception.iterations, 15);
      expect(exception.maxIterations, 10);
      expect(exception.message, contains('15'));
      expect(exception.message, contains('10'));
      expect(exception.toString(), contains('test-agent'));
    });

    test('ToolExecutionException contains tool info', () {
      final exception = ToolExecutionException(
        toolName: 'search',
        message: 'Network error',
        toolCallId: 'tc-1',
        arguments: '{"query": "test"}',
      );

      expect(exception.toolName, 'search');
      expect(exception.message, contains('search'));
      expect(exception.message, contains('Network error'));
      expect(exception.toolCallId, 'tc-1');
    });

    test('AgentTransferException contains target info', () {
      final exception = AgentTransferException(
        targetAgent: 'researcher',
        message: 'Not available',
      );

      expect(exception.targetAgent, 'researcher');
      expect(exception.message, contains('researcher'));
    });

    test('AgentConfigurationException contains config info', () {
      final exception = AgentConfigurationException(
        message: 'Invalid config',
        configKey: 'maxIterations',
        configValue: -1,
      );

      expect(exception.configKey, 'maxIterations');
      expect(exception.configValue, -1);
    });

    test('InvalidAgentInputException contains input type', () {
      final exception = InvalidAgentInputException(
        message: 'Empty input',
        inputType: 'message',
      );

      expect(exception.inputType, 'message');
    });

    test('AgentTimeoutException contains duration', () {
      final exception = AgentTimeoutException(
        timeout: Duration(seconds: 30),
        agentName: 'slow-agent',
      );

      expect(exception.timeout, Duration(seconds: 30));
      expect(exception.message, contains('30'));
    });

    test('AgentCancelledException has optional reason', () {
      final exception = AgentCancelledException(
        agentName: 'test',
        reason: 'User requested',
      );

      expect(exception.message, 'User requested');
    });

    test('ToolNotFoundException lists available tools', () {
      final exception = ToolNotFoundException(
        toolName: 'missing-tool',
        availableTools: ['tool1', 'tool2'],
      );

      expect(exception.toolName, 'missing-tool');
      expect(exception.toString(), contains('tool1'));
      expect(exception.toString(), contains('tool2'));
    });

    test('PlanningException includes partial plan', () {
      final exception = PlanningException(
        message: 'Failed to complete plan',
        partialPlan: ['Step 1', 'Step 2'],
      );

      expect(exception.partialPlan, ['Step 1', 'Step 2']);
    });

    test('WorkflowException includes step info', () {
      final exception = WorkflowException(
        message: 'Step failed',
        failedStep: 'research',
        stepIndex: 2,
      );

      expect(exception.failedStep, 'research');
      expect(exception.stepIndex, 2);
    });
  });

  group('AgentMixin', () {
    test('checkCancellation throws when cancelled', () {
      final agent = _TestAgent();
      var shouldCancel = false;
      final context = AgentRunContext(
        shouldCancel: () => shouldCancel,
      );

      // Should not throw initially
      expect(() => agent.checkCancellation(context), returnsNormally);

      // Should throw when cancelled
      shouldCancel = true;
      expect(
        () => agent.checkCancellation(context),
        throwsA(isA<AgentCancelledException>()),
      );
    });

    test('emitEvent calls context callback', () {
      final agent = _TestAgent();
      final events = <AgentEvent>[];
      final context = AgentRunContext(
        onEvent: (event) => events.add(event),
      );

      final event = AgentOutputEvent(
        message: Message.assistant('Test'),
        runId: context.runId,
      );

      agent.emitEvent(event, context);

      expect(events.length, 1);
      expect(events.first, event);
    });

    test('emitEvent handles null context', () {
      final agent = _TestAgent();
      final event = AgentOutputEvent(
        message: Message.assistant('Test'),
        runId: 'run-1',
      );

      // Should not throw
      expect(() => agent.emitEvent(event, null), returnsNormally);
    });
  });
}

/// Test implementation of BaseAgent with AgentMixin
class _TestAgent with AgentMixin implements BaseAgent {
  @override
  String get name => 'test-agent';

  @override
  String get description => 'A test agent';

  @override
  Future<StreamReader<AgentEvent>> run(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<Message> invoke(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    throw UnimplementedError();
  }

  @override
  BaseAgent copyWith({String? name, String? description}) {
    return this;
  }
}
