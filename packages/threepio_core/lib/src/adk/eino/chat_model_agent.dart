/// An agent that runs a chat model and its tools.
///
/// Port of eino `adk.ChatModelAgent` (`adk/chatmodel.go`).
library;

import 'dart:async';
import 'dart:convert';

import '../../components/component_type.dart';
import '../../components/model/chat_model_options.dart';
import '../../components/tool/invokable_tool.dart';
import '../../components/tool/tool_options.dart';
import '../../compose/call_options.dart';
import '../../compose/chain.dart';
import '../../compose/checkpoint_serializer.dart';
import '../../compose/graph_options.dart';
import '../../compose/interrupt.dart';
import '../../compose/lambda.dart';
import '../../compose/local_state.dart';
import '../../compose/runnable.dart';
import '../../compose/stream_conversion.dart';
import '../../compose/tool_middleware.dart';
import '../../compose/tools_node.dart';
import '../../compose/tools_node_options.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import 'agent.dart';
import 'agent_action.dart';
import 'agent_context.dart';
import 'agent_event.dart';
import 'agent_tool.dart';
import 'chat_model_agent_config.dart';
import 'event_senders.dart';
import 'interrupt.dart';
import 'middleware_context.dart';
import 'react_graph.dart';
import 'run_options.dart';

/// Effectively no limit on the steps of the agent's graph; `maxIterations`
/// bounds the loop (eino uses `math.MaxInt`).
const _unlimitedRunSteps = 1 << 31;

/// An agent that answers with a chat model and calls tools in a loop: the
/// model, then the tool calls it asked for, then the model again, until it
/// answers without tool calls.
///
/// Port of eino `adk.ChatModelAgent` (`NewChatModelAgent`). Without tools a
/// run is one model call. Run it through a `Runner`:
///
/// ```dart
/// final agent = ChatModelAgent(ChatModelAgentConfig(
///   name: 'assistant',
///   description: 'Answers questions',
///   instruction: 'You are helpful.',
///   model: model,
///   toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [search])),
/// ));
/// final events = Runner(agent: agent).query(ctx, 'Hello');
/// ```
///
/// Events: one per model call (its message, streamed when the run streams)
/// and one per tool result; a failure is an event with an error, and an
/// interrupt (a tool called `interrupt`) is an event whose action carries a
/// [ChatModelAgentInterruptInfo].
final class ChatModelAgent implements ResumableAgent, TypedComponent {
  /// An agent from [config].
  ChatModelAgent(this.config)
      : _toolMiddlewares = [
          if (!hasUserEventSenderToolWrapper(config.handlers))
            ...handlersToToolMiddlewares(const [EventSenderToolWrapper()]),
          ...config.toolsConfig.toolsNode.toolCallMiddlewares,
          // P7 appends the cancel-monitored stream middleware here (eino
          // `cancelMonitoredToolHandler`, innermost).
        ] {
    ensureAdkTypesRegistered();
  }

  /// The configuration.
  final ChatModelAgentConfig config;

  final List<ToolMiddleware> _toolMiddlewares;
  Future<_ExecContext>? _defaultExec;

  @override
  String get name => config.name;

  @override
  String get description => config.description;

  /// Port of `ChatModelAgent.GetType`.
  @override
  String get componentTypeName => 'ChatModel';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(_start(ctx, writer, options, input: input));
    return reader;
  }

  @override
  StreamReader<AgentEvent> resume(
    RunContext ctx,
    ResumeInfo info, {
    List<AgentRunOption> options = const [],
  }) {
    final (reader, writer) = pipe<AgentEvent>();
    unawaited(_start(ctx, writer, options, resumeInfo: info));
    return reader;
  }

  Future<void> _start(
    RunContext context,
    StreamWriter<AgentEvent> writer,
    List<AgentRunOption> options, {
    AgentInput? input,
    ResumeInfo? resumeInfo,
  }) async {
    try {
      // P7 resolves the run's cancel context here (eino
      // `resolveRunCancelContext`).
      var ctx = withExecContext(
        context,
        ChatModelAgentExecContext(
          writer: writer,
          failoverLastSuccessModel: config.model,
        ),
      );
      final _ExecContext defaults;
      try {
        defaults = await (_defaultExec ??= _prepareExecContext());
        // Eino keeps a failure to prepare (a tool's info()) and sends it as
        // it is on every run.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        writer.send(AgentEvent(error: error, stackTrace: stackTrace));
        return;
      }
      final _ExecContext exec;
      final _ExecContext graphExec;
      try {
        (ctx, exec, graphExec) = await _execContextFor(ctx, defaults);
        // A middleware's failure in beforeAgent.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        writer.send(
          AgentEvent(
            error: ThreepioException(
              'ChatModelAgent getRunFunc error: $error',
              cause: error,
            ),
            stackTrace: stackTrace,
          ),
        );
        return;
      }

      final runOptions = ChatModelAgentRunOptions.of(options);
      final composeOptions = <CallOption>[
        ..._composeOptionsOf(runOptions),
        CallOption.checkpointId(bridgeCheckpointId),
        if (exec.toolInfos.isNotEmpty)
          CallOption.chatModel(ChatModelOptions(tools: exec.toolInfos)),
        if (exec.toolSearchTool != null)
          CallOption.chatModel(
            ChatModelOptions(toolSearchTool: exec.toolSearchTool),
          ),
        if (exec.toolUpdated)
          CallOption.toolsNode(ToolsNodeOptions(toolList: exec.tools)),
      ];

      final BridgeStore store;
      final AgentInput runInput;
      if (resumeInfo == null) {
        store = BridgeStore();
        runInput = input!;
      } else {
        final state = resumeInfo.interruptState;
        if (state is! String) {
          writer.send(
            AgentEvent(
              error: ThreepioException(
                "ChatModelAgent.resume: agent '$name' was asked to resume but "
                'has ${state == null ? 'no state' : 'an invalid interrupt '
                    'state of type ${state.runtimeType}'}',
              ),
            ),
          );
          return;
        }
        store = BridgeStore.resume(bridgeCheckpointId, base64Decode(state));
        runInput = AgentInput(enableStreaming: resumeInfo.enableStreaming);
        final resumeData = resumeInfo.resumeData;
        if (resumeData != null && resumeData is! ChatModelAgentResumeData) {
          writer.send(
            AgentEvent(
              error: ThreepioException(
                "ChatModelAgent.resume: agent '$name' was asked to resume but "
                'has invalid resume data of type ${resumeData.runtimeType}',
              ),
            ),
          );
          return;
        }
        final modifier = resumeData is ChatModelAgentResumeData
            ? resumeData.historyModifier
            : null;
        if (modifier != null) {
          composeOptions.add(
            CallOption.stateModifier((ctx, path, state) {
              if (state is ReactState) {
                state.messages = modifier(ctx, state.messages);
              }
            }),
          );
        }
      }

      await _runGraph(
        ctx,
        graphExec.tools.isEmpty
            ? _buildNoTools(ctx, store)
            : _buildReact(ctx, graphExec, store),
        writer: writer,
        store: store,
        input: runInput,
        instruction: exec.instruction,
        returnDirectly: exec.returnDirectly,
        composeOptions: composeOptions,
        afterToolCallsHook: runOptions.afterToolCallsHook,
        emitToolEvents: config.toolsConfig.emitInternalEvents,
      );
      // Whatever escaped is the run's failure.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      writer.send(AgentEvent(error: error, stackTrace: stackTrace));
    } finally {
      await writer.close();
    }
  }

  /// The setup of this run and the one its graph is built from. Port of eino
  /// `getRunFunc`.
  Future<(RunContext, _ExecContext, _ExecContext)> _execContextFor(
    RunContext ctx,
    _ExecContext defaults,
  ) async {
    if (config.handlers.isEmpty) return (ctx, defaults, defaults);
    final (next, runtime) = await _applyBeforeAgent(ctx, defaults);
    return (next, runtime, runtime.rebuildGraph ? runtime : defaults);
  }

  /// Port of eino `prepareExecContext`.
  Future<_ExecContext> _prepareExecContext() async {
    final tools = List<BaseTool>.of(config.toolsConfig.toolsNode.tools);
    return _ExecContext(
      instruction: config.instruction,
      tools: tools,
      toolMiddlewares: [
        ..._toolMiddlewares,
        ...handlersToToolMiddlewares(config.handlers),
      ],
      returnDirectly: Set.of(config.toolsConfig.returnDirectly),
      toolInfos: await _toolInfosOf(tools),
    );
  }

  /// Port of eino `applyBeforeAgent`.
  Future<(RunContext, _ExecContext)> _applyBeforeAgent(
    RunContext context,
    _ExecContext defaults,
  ) async {
    var ctx = context;
    var agent = ChatModelAgentContext(
      instruction: defaults.instruction,
      tools: defaults.tools,
      returnDirectly: defaults.returnDirectly,
    );
    for (final (index, handler) in config.handlers.indexed) {
      try {
        (ctx, agent) = await handler.beforeAgent(ctx, agent);
        // A middleware's failure fails the run.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        Error.throwWithStackTrace(
          ThreepioException(
            'handler[$index] (${handler.runtimeType}) BeforeAgent failed: '
            '$error',
            cause: error,
          ),
          stackTrace,
        );
      }
    }
    return (
      ctx,
      _ExecContext(
        instruction: agent.instruction,
        tools: List.of(agent.tools),
        toolMiddlewares: defaults.toolMiddlewares,
        returnDirectly: Set.of(agent.returnDirectly),
        toolInfos: await _toolInfosOf(agent.tools),
        toolSearchTool: agent.toolSearchTool,
        toolUpdated: true,
        rebuildGraph:
            (defaults.tools.isEmpty && agent.tools.isNotEmpty) ||
                (defaults.returnDirectly.isEmpty &&
                    agent.returnDirectly.isNotEmpty),
      ),
    );
  }

  /// Port of eino `applyAfterAgent`.
  Future<void> _applyAfterAgent(RunContext context) async {
    if (config.handlers.isEmpty) return;
    var state = ChatModelAgentState(messages: const []);
    await processState<ReactState>(context, (_, saved) {
      state = ChatModelAgentState(
        messages: saved.messages,
        toolInfos: saved.toolInfos ?? const [],
        deferredToolInfos: saved.deferredToolInfos,
      );
    });
    var ctx = context;
    for (final (index, handler) in config.handlers.indexed) {
      try {
        ctx = await handler.afterAgent(ctx, state);
        // A middleware's failure fails the run.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        Error.throwWithStackTrace(
          ThreepioException(
            'handler[$index] (${handler.runtimeType}) AfterAgent failed: $error',
            cause: error,
          ),
          stackTrace,
        );
      }
    }
  }

  ToolsNodeConfig _toolsNodeConfig(_ExecContext exec) {
    final base = config.toolsConfig.toolsNode;
    return ToolsNodeConfig(
      tools: exec.tools,
      toolAliases: base.toolAliases,
      unknownToolsHandler: base.unknownToolsHandler,
      executeSequentially: base.executeSequentially,
      toolArgumentsHandler: base.toolArgumentsHandler,
      toolCallMiddlewares: exec.toolMiddlewares,
    );
  }

  /// The compiled graph of a run with tools. Port of eino
  /// `buildMessageReActRunFunc`.
  Future<Runnable<_RunInput, Message>> _buildReact(
    RunContext ctx,
    _ExecContext exec,
    BridgeStore store,
  ) async {
    final react = await newReactGraph(
      ctx,
      ReactConfig(
        model: config.model,
        toolsConfig: _toolsNodeConfig(exec),
        modelWrapperConfig: ModelWrapperConfig(
          handlers: config.handlers,
          retryConfig: config.modelRetryConfig,
          failoverConfig: config.modelFailoverConfig,
          toolInfos: exec.toolInfos,
        ),
        toolsReturnDirectly: exec.returnDirectly,
        agentName: name,
        maxIterations: config.maxIterations,
        afterAgent: config.handlers.isEmpty
            ? null
            : (ctx, message) async {
                await _applyAfterAgent(ctx);
                return message;
              },
      ),
    );
    final genModelInput = config.genModelInput ?? defaultGenModelInput;
    final chain = Chain<_RunInput, Message>()
      ..appendLambda(
        Lambda.invokable(
          (RunContext ctx, _RunInput input) async => ReactInput(
            await genModelInput(ctx, input.instruction, input.input),
          ),
        ),
      )
      ..appendGraph(
        react,
        options: const NodeOptions(
          name: 'ReAct',
          compileOptions: GraphCompileOptions(maxRunSteps: _unlimitedRunSteps),
        ),
      );
    return chain.compile(
      ctx,
      options: GraphCompileOptions(
        graphName: name,
        checkpointStore: store,
        serializer: const JsonCheckpointSerializer(),
        maxRunSteps: _unlimitedRunSteps,
      ),
    );
  }

  /// The compiled chain of a run without tools. Port of eino
  /// `buildNoToolsRunFunc`.
  Future<Runnable<_RunInput, Message>> _buildNoTools(
    RunContext ctx,
    BridgeStore store,
  ) {
    final model = buildModelWrappers(
      config.model,
      ModelWrapperConfig(
        handlers: config.handlers,
        retryConfig: config.modelRetryConfig,
        failoverConfig: config.modelFailoverConfig,
      ),
    );
    final genModelInput = config.genModelInput ?? defaultGenModelInput;
    final chain = Chain<_RunInput, Message>(
      localState: LocalState.of<ReactState>((_) => ReactState()),
    )
      ..appendLambda(
        Lambda.invokable((RunContext ctx, _RunInput input) async {
          final messages =
              await genModelInput(ctx, input.instruction, input.input);
          await processState<ReactState>(
            ctx,
            (_, state) => state.messages.addAll(messages),
          );
          return messages;
        }),
      )
      ..appendChatModel(model);
    if (config.handlers.isNotEmpty) {
      chain.appendLambda(
        Lambda.invokable((RunContext ctx, Message message) async {
          await _applyAfterAgent(ctx);
          return message;
        }),
      );
    }
    return chain.compile(
      ctx,
      options: GraphCompileOptions(
        graphName: name,
        checkpointStore: store,
        serializer: const JsonCheckpointSerializer(),
      ),
    );
  }

  Future<void> _runGraph(
    RunContext context,
    Future<Runnable<_RunInput, Message>> build, {
    required StreamWriter<AgentEvent> writer,
    required BridgeStore store,
    required AgentInput input,
    required String instruction,
    required Set<String> returnDirectly,
    required List<CallOption> composeOptions,
    required FutureOr<void> Function(RunContext ctx)? afterToolCallsHook,
    required bool emitToolEvents,
  }) async {
    final Runnable<_RunInput, Message> runnable;
    try {
      runnable = await build;
      // A failure to build or compile the graph.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      writer.send(AgentEvent(error: error, stackTrace: stackTrace));
      return;
    }
    final ctx = withExecContext(
      context,
      ChatModelAgentExecContext(
        writer: writer,
        runtimeReturnDirectly: returnDirectly,
        failoverLastSuccessModel: config.model,
        afterToolCallsHook: afterToolCallsHook,
      ),
    );
    // P7: a run cancelled before it started ends here (eino
    // `checkPreExecCancel`).
    final runInput = _RunInput(input, instruction);
    final options = [
      ...composeOptions,
      if (emitToolEvents)
        CallOption.tool(ToolOptions(extensions: [AgentToolEventSink(writer)])),
      if (input.enableStreaming)
        CallOption.tool(const ToolOptions(extensions: [AgentToolStreaming()])),
    ];
    try {
      if (input.enableStreaming) {
        final stream = await runnable.stream(ctx, runInput, options: options);
        // Eino closes the output stream unread; reading it surfaces an error
        // that arrives inside the stream instead of losing it.
        await concatStreamReader(stream);
      } else {
        await runnable.invoke(ctx, runInput, options: options);
      }
      // The graph's failure (or interrupt) becomes the run's last event.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      await _handleRunError(ctx, error, stackTrace, store, writer);
    }
  }

  /// Port of eino `handleRunFuncError`.
  Future<void> _handleRunError(
    RunContext ctx,
    Object error,
    StackTrace stackTrace,
    BridgeStore store,
    StreamWriter<AgentEvent> writer,
  ) async {
    final info = extractInterruptInfo(error);
    if (info == null) {
      writer.send(AgentEvent(error: error, stackTrace: stackTrace));
      return;
    }
    final data = await store.get(bridgeCheckpointId);
    if (data == null) {
      writer.send(
        AgentEvent(
          agentName: name,
          error: const ThreepioException(
            'interrupt occurred but checkpoint data is missing',
          ),
        ),
      );
      return;
    }
    final signal =
        compositeInterrupt(ctx, info, base64Encode(data), [error])
            as AddressedInterruptSignal;
    writer.send(
      AgentEvent(
        agentName: name,
        action: AgentAction.interruptedBy(
          AgentInterruptInfo(
            data: ChatModelAgentInterruptInfo(info: info, data: data),
            interruptContexts: toInterruptContexts(
              signal,
              allowedSegmentTypes: allowedAddressSegmentTypes,
            ),
          ),
          signal,
        ),
      ),
    );
  }

  @override
  String toString() => 'ChatModelAgent($name)';
}

/// The compose options from the run options. Port of eino
/// `getComposeOptions` (without the deprecated history modifier).
List<CallOption> _composeOptionsOf(ChatModelAgentRunOptions options) {
  final chatModelOptions = options.chatModelOptions;
  final toolExtensions = <Object>[
    ...?options.toolOptions?.extensions,
    for (final MapEntry(:key, :value) in options.agentToolOptions.entries)
      AgentToolRunOptions(key, value),
  ];
  return [
    if (chatModelOptions != null) CallOption.chatModel(chatModelOptions),
    if (toolExtensions.isNotEmpty)
      CallOption.tool(ToolOptions(extensions: toolExtensions)),
  ];
}

Future<List<ToolInfo>> _toolInfosOf(List<BaseTool> tools) async => [
      for (final tool in tools) await tool.info(),
    ];

/// The setup of a run. Port of eino `execContext`.
final class _ExecContext {
  _ExecContext({
    required this.instruction,
    required this.tools,
    required this.toolMiddlewares,
    required this.returnDirectly,
    required this.toolInfos,
    this.toolSearchTool,
    this.toolUpdated = false,
    this.rebuildGraph = false,
  });

  final String instruction;
  final List<BaseTool> tools;
  final List<ToolMiddleware> toolMiddlewares;
  final Set<String> returnDirectly;
  final List<ToolInfo> toolInfos;
  final ToolInfo? toolSearchTool;
  final bool toolUpdated;
  final bool rebuildGraph;
}

/// The input of the agent's graph. Port of eino `reactRunInput` and
/// `typedNoToolsInput`.
final class _RunInput {
  const _RunInput(this.input, this.instruction);

  final AgentInput input;
  final String instruction;
}
