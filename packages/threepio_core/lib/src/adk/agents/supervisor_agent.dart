import 'dart:async';
import 'dart:convert';

import '../../components/model/base_chat_model.dart';
import '../../components/tool/invokable_tool.dart';
import '../../components/tool/tool_registry.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import '../../streaming/stream_utils.dart';
import '../../streaming/stream_writer.dart';
import '../core/agent_exception.dart';
import '../core/base_agent.dart';
import '../events/agent_action.dart';
import '../events/agent_event.dart';

/// Configuration for supervisor agent.
class SupervisorConfig {
  /// Creates configuration.
  const SupervisorConfig({
    this.maxDelegations = 10,
    this.allowDirectResponse = true,
    this.trackHistory = true,
  });

  /// Maximum number of delegations before forcing completion.
  final int maxDelegations;

  /// Whether supervisor can respond directly without delegating.
  final bool allowDirectResponse;

  /// Whether to track delegation history.
  final bool trackHistory;
}

/// Agent that supervises and delegates to worker agents.
///
/// The supervisor decides which worker should handle each request,
/// delegates to them, and coordinates the overall workflow.
///
/// Example:
/// ```dart
/// final supervisor = SupervisorAgent(
///   name: 'supervisor',
///   description: 'Coordinates research and writing tasks',
///   model: gpt4,
///   workers: {
///     'researcher': researchAgent,
///     'writer': writerAgent,
///     'reviewer': reviewAgent,
///   },
/// );
///
/// final result = await supervisor.invoke([
///   Message.user('Research AI trends and write a summary'),
/// ]);
/// ```
class SupervisorAgent with AgentMixin implements BaseAgent {
  /// Creates a supervisor agent.
  SupervisorAgent({
    required this.name,
    required this.description,
    required ToolCallingChatModel model,
    required Map<String, BaseAgent> workers,
    this.systemPrompt,
    this.config = const SupervisorConfig(),
  })  : _model = model,
        _workers = workers {
    _buildToolRegistry();
  }

  @override
  final String name;

  @override
  final String description;

  final ToolCallingChatModel _model;
  final Map<String, BaseAgent> _workers;
  late final ToolRegistry _toolRegistry;

  /// System prompt for the supervisor.
  final String? systemPrompt;

  /// Supervisor configuration.
  final SupervisorConfig config;

  void _buildToolRegistry() {
    _toolRegistry = ToolRegistry();

    // Register delegation tools for each worker
    for (final entry in _workers.entries) {
      _toolRegistry.register(_DelegationTool(
        workerName: entry.key,
        workerDescription: entry.value.description,
      ));
    }

    // Register finish tool
    _toolRegistry.register(_FinishTool());
  }

  @override
  Future<StreamReader<AgentEvent>> run(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    final ctx = context ?? AgentRunContext();
    final (reader, writer) = pipe<AgentEvent>();

    _runSupervision(messages, writer, ctx)
        .then((_) => writer.close())
        .catchError((Object error, StackTrace stackTrace) {
      writer.send(AgentErrorEvent(
        error: error.toString(),
        stackTrace: stackTrace.toString(),
        runId: ctx.runId,
      ));
      writer.close();
    });

    return reader;
  }

  @override
  Future<Message> invoke(
    List<Message> messages, {
    AgentRunContext? context,
  }) async {
    final reader = await run(messages, context: context);
    Message? lastOutput;

    try {
      while (true) {
        final event = await reader.recv();
        if (event is AgentRunEndEvent) {
          return event.outputMessage;
        }
        if (event is AgentOutputEvent && !event.isPartial) {
          lastOutput = event.message;
        }
      }
    } on StreamEOFException {
      // Stream ended
    } finally {
      await reader.close();
    }

    return lastOutput ?? Message.assistant('');
  }

  @override
  BaseAgent copyWith({
    String? name,
    String? description,
  }) {
    return SupervisorAgent(
      name: name ?? this.name,
      description: description ?? this.description,
      model: _model,
      workers: _workers,
      systemPrompt: systemPrompt,
      config: config,
    );
  }

  Future<void> _runSupervision(
    List<Message> messages,
    StreamWriter<AgentEvent> writer,
    AgentRunContext context,
  ) async {
    final startTime = DateTime.now();

    writer.send(AgentRunStartEvent(
      agentName: name,
      inputMessages: messages,
      runId: context.runId,
      parentRunId: context.parentRunId,
    ));

    // Build conversation history
    final history = <Message>[];

    // Add system prompt
    history.add(Message.system(_buildSystemPrompt()));

    // Add input messages
    history.addAll(messages);

    // Track delegations
    final delegationHistory = <String, List<Message>>{};
    var delegationCount = 0;

    // Get model with tools
    final toolInfoList = await _toolRegistry.getToolInfoList();
    final modelWithTools = _model.withTools(toolInfoList);

    while (delegationCount < config.maxDelegations) {
      checkCancellation(context);

      // Get supervisor decision
      final response = await modelWithTools.generate(history);

      // Check for direct response (no tool calls)
      if (response.toolCalls == null || response.toolCalls!.isEmpty) {
        if (config.allowDirectResponse) {
          writer.send(AgentOutputEvent(
            message: response,
            isPartial: false,
            runId: context.runId,
          ));

          writer.send(AgentRunEndEvent(
            agentName: name,
            outputMessage: response,
            durationMs: DateTime.now().difference(startTime).inMilliseconds,
            runId: context.runId,
          ));

          return;
        } else {
          // Force delegation by prompting again
          history.add(Message.user(
            'Please delegate this task to one of the available workers or use '
            'the finish tool if you have enough information to complete the task.',
          ));
          continue;
        }
      }

      // Process tool calls
      history.add(response);

      for (final toolCall in response.toolCalls!) {
        final toolName = toolCall.function.name;
        final args = jsonDecode(toolCall.function.arguments) as Map<String, dynamic>;

        if (toolName == 'finish') {
          // Supervisor is done
          final summary = args['summary'] as String? ?? response.content;
          final finalMessage = Message.assistant(summary);

          writer.send(AgentActionEvent(
            action: FinishAction(output: summary),
            runId: context.runId,
          ));

          writer.send(AgentOutputEvent(
            message: finalMessage,
            isPartial: false,
            runId: context.runId,
          ));

          writer.send(AgentRunEndEvent(
            agentName: name,
            outputMessage: finalMessage,
            durationMs: DateTime.now().difference(startTime).inMilliseconds,
            runId: context.runId,
          ));

          return;
        }

        // Delegation to worker
        final workerName = toolName.replaceFirst('delegate_to_', '');
        final worker = _workers[workerName];

        if (worker == null) {
          throw AgentTransferException(
            targetAgent: workerName,
            message: 'Worker not found',
            agentName: name,
            runId: context.runId,
          );
        }

        delegationCount++;

        // Emit transfer event
        writer.send(AgentTransferEvent(
          fromAgent: name,
          toAgent: workerName,
          reason: args['task'] as String?,
          runId: context.runId,
        ));

        writer.send(AgentActionEvent(
          action: TransferToAgentAction(
            targetAgent: workerName,
            reason: args['task'] as String?,
          ),
          runId: context.runId,
        ));

        // Build worker input
        final task = args['task'] as String? ?? '';
        final workerInput = <Message>[
          ...messages,
          Message.user('Task from supervisor: $task'),
        ];

        // Add relevant history if tracking
        if (config.trackHistory && delegationHistory[workerName] != null) {
          for (final prevResult in delegationHistory[workerName]!) {
            workerInput.add(prevResult);
          }
        }

        // Execute worker
        final childContext = context.child(
          additionalMetadata: {'delegated_to': workerName},
        );

        final workerResult = await worker.invoke(workerInput, context: childContext);

        // Track history
        if (config.trackHistory) {
          delegationHistory.putIfAbsent(workerName, () => []);
          delegationHistory[workerName]!.add(workerResult);
        }

        // Emit output
        writer.send(AgentOutputEvent(
          message: workerResult,
          isPartial: false,
          runId: context.runId,
        ));

        // Add result to supervisor history
        history.add(Message.tool(
          content: workerResult.content,
          toolCallId: toolCall.id,
          toolName: toolName,
        ));
      }
    }

    throw MaxIterationsExceededException(
      iterations: delegationCount,
      maxIterations: config.maxDelegations,
      agentName: name,
      runId: context.runId,
    );
  }

  String _buildSystemPrompt() {
    final buffer = StringBuffer();

    if (systemPrompt != null) {
      buffer.writeln(systemPrompt);
      buffer.writeln();
    }

    buffer.writeln('You are a supervisor agent coordinating multiple workers.');
    buffer.writeln();
    buffer.writeln('Available workers:');

    for (final entry in _workers.entries) {
      buffer.writeln('- ${entry.key}: ${entry.value.description}');
    }

    buffer.writeln();
    buffer.writeln('Instructions:');
    buffer.writeln('1. Analyze the task and determine which worker(s) should handle it');
    buffer.writeln('2. Delegate specific tasks to workers using the delegate tools');
    buffer.writeln('3. Coordinate results from multiple workers if needed');
    buffer.writeln('4. Use the finish tool when you have a complete answer');

    if (!config.allowDirectResponse) {
      buffer.writeln();
      buffer.writeln('You must always delegate to workers - do not respond directly.');
    }

    return buffer.toString();
  }
}

/// Tool for delegating to a worker.
class _DelegationTool extends InvokableTool {
  _DelegationTool({
    required this.workerName,
    required this.workerDescription,
  });

  final String workerName;
  final String workerDescription;

  @override
  Future<ToolInfo> info() async {
    return ToolInfo.simple(
      name: 'delegate_to_$workerName',
      description: 'Delegate a task to the $workerName worker. $workerDescription',
      properties: {
        'task': JSONSchemaProperty.string(
          description: 'The specific task to delegate to this worker',
        ),
        'context': JSONSchemaProperty.string(
          description: 'Optional additional context for the worker',
        ),
      },
      required: ['task'],
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    // Tool execution is handled by the supervisor, not here
    return 'Delegation handled by supervisor';
  }
}

/// Tool for finishing supervision.
class _FinishTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo.simple(
      name: 'finish',
      description: 'Call this when you have enough information to provide a final answer',
      properties: {
        'summary': JSONSchemaProperty.string(
          description: 'The final summary/answer to return to the user',
        ),
      },
      required: ['summary'],
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    // Tool execution is handled by the supervisor
    return 'Finish handled by supervisor';
  }
}
