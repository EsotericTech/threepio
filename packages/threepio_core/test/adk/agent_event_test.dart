import 'package:test/test.dart';
import 'package:threepio_core/src/adk/events/agent_action.dart';
import 'package:threepio_core/src/adk/events/agent_event.dart';
import 'package:threepio_core/src/schema/message.dart' hide TokenUsage;

void main() {
  group('AgentAction', () {
    group('ToolCallAction', () {
      test('creates with required fields', () {
        final action = ToolCallAction(
          toolCallId: 'tc-1',
          toolName: 'search',
          arguments: '{"query": "test"}',
        );

        expect(action.toolCallId, 'tc-1');
        expect(action.toolName, 'search');
        expect(action.arguments, '{"query": "test"}');
        expect(action.description, 'Call tool: search');
      });

      test('serializes and deserializes', () {
        final action = ToolCallAction(
          toolCallId: 'tc-1',
          toolName: 'search',
          arguments: '{"query": "test"}',
        );

        final json = action.toJson();
        final restored = AgentAction.fromJson(json) as ToolCallAction;

        expect(restored.toolCallId, action.toolCallId);
        expect(restored.toolName, action.toolName);
        expect(restored.arguments, action.arguments);
      });
    });

    group('TransferToAgentAction', () {
      test('creates with required fields', () {
        final action = TransferToAgentAction(
          targetAgent: 'researcher',
          reason: 'Need research assistance',
        );

        expect(action.targetAgent, 'researcher');
        expect(action.reason, 'Need research assistance');
        expect(action.description, 'Transfer to agent: researcher');
      });

      test('serializes and deserializes', () {
        final action = TransferToAgentAction(
          targetAgent: 'researcher',
          reason: 'Need help',
          context: {'topic': 'AI'},
        );

        final json = action.toJson();
        final restored = AgentAction.fromJson(json) as TransferToAgentAction;

        expect(restored.targetAgent, action.targetAgent);
        expect(restored.reason, action.reason);
        expect(restored.context, action.context);
      });
    });

    group('FinishAction', () {
      test('creates with required fields', () {
        final action = FinishAction(
          output: 'Task completed',
          summary: 'Successfully finished',
        );

        expect(action.output, 'Task completed');
        expect(action.summary, 'Successfully finished');
        expect(action.description, 'Finish with output');
      });

      test('serializes and deserializes', () {
        final action = FinishAction(output: 'Done');

        final json = action.toJson();
        final restored = AgentAction.fromJson(json) as FinishAction;

        expect(restored.output, action.output);
      });
    });

    group('ThinkAction', () {
      test('creates with thought', () {
        final action = ThinkAction(thought: 'I should search first');

        expect(action.thought, 'I should search first');
        expect(action.description, 'Think');
      });

      test('serializes and deserializes', () {
        final action = ThinkAction(thought: 'Planning next step');

        final json = action.toJson();
        final restored = AgentAction.fromJson(json) as ThinkAction;

        expect(restored.thought, action.thought);
      });
    });

    group('RequestInputAction', () {
      test('creates with prompt', () {
        final action = RequestInputAction(
          prompt: 'Please confirm',
          inputType: 'confirmation',
          options: ['yes', 'no'],
        );

        expect(action.prompt, 'Please confirm');
        expect(action.inputType, 'confirmation');
        expect(action.options, ['yes', 'no']);
      });

      test('serializes and deserializes', () {
        final action = RequestInputAction(
          prompt: 'Choose option',
          options: ['A', 'B', 'C'],
        );

        final json = action.toJson();
        final restored = AgentAction.fromJson(json) as RequestInputAction;

        expect(restored.prompt, action.prompt);
        expect(restored.options, action.options);
      });
    });
  });

  group('AgentEvent', () {
    group('AgentRunStartEvent', () {
      test('creates with required fields', () {
        final event = AgentRunStartEvent(
          agentName: 'assistant',
          inputMessages: [Message.user('Hello')],
          runId: 'run-1',
        );

        expect(event.agentName, 'assistant');
        expect(event.inputMessages.length, 1);
        expect(event.runId, 'run-1');
        expect(event.eventType, 'run_start');
      });

      test('serializes and deserializes', () {
        final event = AgentRunStartEvent(
          agentName: 'assistant',
          inputMessages: [Message.user('Hello')],
          runId: 'run-1',
          parentRunId: 'parent-run',
          metadata: {'key': 'value'},
        );

        final json = event.toJson();
        final restored = AgentEvent.fromJson(json) as AgentRunStartEvent;

        expect(restored.agentName, event.agentName);
        expect(restored.runId, event.runId);
        expect(restored.parentRunId, event.parentRunId);
        expect(restored.metadata, event.metadata);
      });
    });

    group('AgentRunEndEvent', () {
      test('creates with required fields', () {
        final event = AgentRunEndEvent(
          agentName: 'assistant',
          outputMessage: Message.assistant('Done'),
          durationMs: 1500,
          runId: 'run-1',
        );

        expect(event.agentName, 'assistant');
        expect(event.outputMessage.content, 'Done');
        expect(event.durationMs, 1500);
        expect(event.eventType, 'run_end');
      });

      test('serializes and deserializes', () {
        final event = AgentRunEndEvent(
          agentName: 'assistant',
          outputMessage: Message.assistant('Done'),
          durationMs: 1500,
          runId: 'run-1',
          toolCallCount: 3,
          tokenUsage: TokenUsage(
            promptTokens: 100,
            completionTokens: 50,
            totalTokens: 150,
          ),
        );

        final json = event.toJson();
        final restored = AgentEvent.fromJson(json) as AgentRunEndEvent;

        expect(restored.agentName, event.agentName);
        expect(restored.durationMs, event.durationMs);
        expect(restored.toolCallCount, event.toolCallCount);
        expect(restored.tokenUsage?.totalTokens, 150);
      });
    });

    group('AgentOutputEvent', () {
      test('creates with message', () {
        final event = AgentOutputEvent(
          message: Message.assistant('Hello!'),
          isPartial: true,
          runId: 'run-1',
        );

        expect(event.message.content, 'Hello!');
        expect(event.isPartial, true);
        expect(event.eventType, 'output');
      });

      test('serializes and deserializes', () {
        final event = AgentOutputEvent(
          message: Message.assistant('Response'),
          runId: 'run-1',
        );

        final json = event.toJson();
        final restored = AgentEvent.fromJson(json) as AgentOutputEvent;

        expect(restored.message.content, event.message.content);
        expect(restored.isPartial, event.isPartial);
      });
    });

    group('AgentActionEvent', () {
      test('creates with action', () {
        final action = ToolCallAction(
          toolCallId: 'tc-1',
          toolName: 'search',
          arguments: '{}',
        );

        final event = AgentActionEvent(
          action: action,
          runId: 'run-1',
          stepNumber: 1,
        );

        expect(event.action, isA<ToolCallAction>());
        expect(event.stepNumber, 1);
        expect(event.eventType, 'action');
      });

      test('serializes and deserializes', () {
        final event = AgentActionEvent(
          action: FinishAction(output: 'Done'),
          runId: 'run-1',
        );

        final json = event.toJson();
        final restored = AgentEvent.fromJson(json) as AgentActionEvent;

        expect(restored.action, isA<FinishAction>());
      });
    });

    group('ToolResultEvent', () {
      test('creates with result', () {
        final event = ToolResultEvent(
          toolCallId: 'tc-1',
          toolName: 'search',
          result: '{"results": []}',
          runId: 'run-1',
        );

        expect(event.toolCallId, 'tc-1');
        expect(event.toolName, 'search');
        expect(event.result, '{"results": []}');
        expect(event.isError, false);
        expect(event.eventType, 'tool_result');
      });

      test('handles error results', () {
        final event = ToolResultEvent(
          toolCallId: 'tc-1',
          toolName: 'search',
          result: 'Error: Network timeout',
          isError: true,
          runId: 'run-1',
        );

        expect(event.isError, true);
      });

      test('serializes and deserializes', () {
        final event = ToolResultEvent(
          toolCallId: 'tc-1',
          toolName: 'calculate',
          result: '42',
          durationMs: 100,
          runId: 'run-1',
        );

        final json = event.toJson();
        final restored = AgentEvent.fromJson(json) as ToolResultEvent;

        expect(restored.toolCallId, event.toolCallId);
        expect(restored.toolName, event.toolName);
        expect(restored.result, event.result);
        expect(restored.durationMs, event.durationMs);
      });
    });

    group('AgentTransferEvent', () {
      test('creates with transfer info', () {
        final event = AgentTransferEvent(
          fromAgent: 'coordinator',
          toAgent: 'researcher',
          reason: 'Research needed',
          runId: 'run-1',
        );

        expect(event.fromAgent, 'coordinator');
        expect(event.toAgent, 'researcher');
        expect(event.reason, 'Research needed');
        expect(event.eventType, 'transfer');
      });

      test('serializes and deserializes', () {
        final event = AgentTransferEvent(
          fromAgent: 'a',
          toAgent: 'b',
          context: {'data': 'info'},
          runId: 'run-1',
        );

        final json = event.toJson();
        final restored = AgentEvent.fromJson(json) as AgentTransferEvent;

        expect(restored.fromAgent, event.fromAgent);
        expect(restored.toAgent, event.toAgent);
        expect(restored.context, event.context);
      });
    });

    group('AgentErrorEvent', () {
      test('creates with error', () {
        final event = AgentErrorEvent(
          error: 'Something went wrong',
          isRecoverable: true,
          runId: 'run-1',
        );

        expect(event.error, 'Something went wrong');
        expect(event.isRecoverable, true);
        expect(event.eventType, 'error');
      });

      test('serializes and deserializes', () {
        final event = AgentErrorEvent(
          error: 'Test error',
          stackTrace: 'at line 1',
          runId: 'run-1',
        );

        final json = event.toJson();
        final restored = AgentEvent.fromJson(json) as AgentErrorEvent;

        expect(restored.error, event.error);
        expect(restored.stackTrace, event.stackTrace);
      });
    });

    group('AgentStateUpdateEvent', () {
      test('creates with state change', () {
        final event = AgentStateUpdateEvent(
          stateName: 'iteration',
          newValue: 2,
          previousValue: 1,
          runId: 'run-1',
        );

        expect(event.stateName, 'iteration');
        expect(event.newValue, 2);
        expect(event.previousValue, 1);
        expect(event.eventType, 'state_update');
      });

      test('serializes and deserializes', () {
        final event = AgentStateUpdateEvent(
          stateName: 'phase',
          newValue: 'planning',
          runId: 'run-1',
        );

        final json = event.toJson();
        final restored = AgentEvent.fromJson(json) as AgentStateUpdateEvent;

        expect(restored.stateName, event.stateName);
        expect(restored.newValue, event.newValue);
      });
    });
  });

  group('TokenUsage', () {
    test('creates with values', () {
      final usage = TokenUsage(
        promptTokens: 100,
        completionTokens: 50,
        totalTokens: 150,
      );

      expect(usage.promptTokens, 100);
      expect(usage.completionTokens, 50);
      expect(usage.totalTokens, 150);
    });

    test('serializes and deserializes', () {
      final usage = TokenUsage(
        promptTokens: 100,
        completionTokens: 50,
        totalTokens: 150,
      );

      final json = usage.toJson();
      final restored = TokenUsage.fromJson(json);

      expect(restored.promptTokens, usage.promptTokens);
      expect(restored.completionTokens, usage.completionTokens);
      expect(restored.totalTokens, usage.totalTokens);
    });
  });
}
