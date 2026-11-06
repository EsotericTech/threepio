/// An agent that runs an agentic model and its tools.
///
/// Port of eino `adk.TypedChatModelAgent[*schema.AgenticMessage]`
/// (`adk/chatmodel.go`: `NewTypedChatModelAgent`, `buildNoToolsRunFunc`,
/// `buildAgenticReActRunFunc`, `handleRunFuncError`, `applyBeforeAgent`,
/// `applyAfterAgent`, `prepareExecContext`, `getRunFunc`, `Run`, `Resume`,
/// the agentic `newDefaultGenModelInput`). **Beta**.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../components/component_type.dart';
import '../../components/model/agentic_model.dart';
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
import '../../compose/resume.dart';
import '../../compose/runnable.dart';
import '../../compose/stream_conversion.dart';
import '../../compose/tool_middleware.dart';
import '../../compose/tools_node.dart';
import '../../compose/tools_node_options.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/agentic_message.dart';
import '../../schema/tool_info.dart';
import '../../streaming/stream_reader.dart';
import '../eino/agent_action.dart';
import '../eino/agent_tool.dart' show AgentToolRunOptions, AgentToolStreaming;
import '../eino/cancel.dart';
import '../eino/chat_model_agent_config.dart' show ToolsConfig;
import '../eino/event_senders.dart' show handlersToToolMiddlewares;
import '../eino/interrupt.dart';
import '../eino/middleware_context.dart';
import '../eino/react_graph.dart' show ReactState;
import '../eino/run_options.dart';
import '../eino/tool_info_context.dart';
import 'agentic_agent.dart';
import 'agentic_agent_tool.dart' show AgenticAgentToolEventSink;
import 'agentic_context.dart';
import 'agentic_middleware.dart';
import 'agentic_react_graph.dart';
import 'agentic_runner.dart' show wrapAgenticEventsWithCancelContext;
import 'agentic_wrappers.dart';

/// Effectively no limit on the steps of the agent's graph; `maxIterations`
/// bounds the loop (eino uses `math.MaxInt`).
const _unlimitedRunSteps = 1 << 31;

/// Turns the instruction and the input of a run into the messages the
/// agentic model starts with. Port of eino
/// `adk.TypedGenModelInput[*schema.AgenticMessage]`.
typedef AgenticGenModelInput = FutureOr<List<AgenticMessage>> Function(
  RunContext ctx,
  String instruction,
  AgenticAgentInput input,
);

/// The default [AgenticGenModelInput]: a system message with the
/// instruction (when there is one), then the input messages.
///
/// Port of the agentic branch of eino `newDefaultGenModelInput`. Unlike the
/// classic `defaultGenModelInput`, the instruction is used as it is: eino
/// does not fill placeholders from session values on the agentic path.
List<AgenticMessage> defaultAgenticGenModelInput(
  RunContext ctx,
  String instruction,
  AgenticAgentInput input,
) =>
    [
      if (instruction.isNotEmpty) AgenticMessage.system(instruction),
      ...input.messages,
    ];

/// The configuration of an [AgenticChatModelAgent].
///
/// Port of eino `adk.TypedChatModelAgentConfig[*schema.AgenticMessage]`.
/// The tools configuration is the classic [ToolsConfig] (tools speak text
/// and `ToolResult`s on both paths). Not ported, as on the classic path:
/// `Exit`, `OutputKey` and the deprecated `Middlewares`. Not built for
/// agentic models yet: `ModelRetryConfig` and `ModelFailoverConfig`.
@immutable
final class AgenticChatModelAgentConfig {
  /// The configuration of an agent with [model].
  const AgenticChatModelAgentConfig({
    required this.model,
    this.name = '',
    this.description = '',
    this.instruction = '',
    this.toolsConfig = const ToolsConfig(),
    this.genModelInput,
    this.maxIterations = 20,
    this.handlers = const [],
  });

  /// The name of the agent.
  final String name;

  /// What the agent does.
  final String description;

  /// The system instruction (used as it is by the default
  /// [genModelInput]).
  final String instruction;

  /// The agentic model. With tools it is told about them through
  /// `ChatModelOptions.tools` (an agentic model takes its tools per call).
  final AgenticModel model;

  /// The tools.
  final ToolsConfig toolsConfig;

  /// How the model input is built; [defaultAgenticGenModelInput] when
  /// `null`.
  final AgenticGenModelInput? genModelInput;

  /// How many model calls a run may make before it fails with
  /// `ExceedMaxIterationsException`; 20 when 0 or less.
  final int maxIterations;

  /// The middlewares, in order (the first one's wrappers are the
  /// outermost).
  final List<AgenticChatModelAgentMiddleware> handlers;
}

/// An agent that answers with an agentic model and calls its function tools
/// in a loop: the model, then the tool calls it asked for, then the model
/// again, until it answers without function tool calls.
///
/// Port of eino `adk.TypedChatModelAgent[*schema.AgenticMessage]`
/// (`NewTypedChatModelAgent`). Without tools a run is one model call. Run it
/// through an `AgenticRunner`:
///
/// ```dart
/// final agent = AgenticChatModelAgent(AgenticChatModelAgentConfig(
///   name: 'assistant',
///   description: 'Answers questions',
///   instruction: 'You are helpful.',
///   model: model,
///   toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: [search])),
/// ));
/// final events = AgenticRunner(agent: agent).query(ctx, 'Hello');
/// ```
///
/// Events: one per model call (its message, role assistant, streamed when
/// the run streams) and one per function tool result (a user message with a
/// `FunctionToolResult` or `ToolSearchFunctionToolResult` block); a failure
/// is an event with an error, and an interrupt (a tool that called
/// `interrupt` or one of its relatives) is the last event, its action
/// carrying a [ChatModelAgentInterruptInfo]. Server-side and MCP tool calls
/// the model makes itself are content blocks of its message and are not run
/// by the agent.
final class AgenticChatModelAgent
    implements ResumableAgenticAgent, TypedComponent {
  /// An agent from [config].
  AgenticChatModelAgent(this.config)
      : _toolMiddlewares = [
          // The default tool event sender, outermost (eino installs the
          // agentic one; it has no public constructor).
          ...handlersToToolMiddlewares(
            const [AgenticToolHooks(AgenticEventSenderToolWrapper())],
          ),
          ...config.toolsConfig.toolsNode.toolCallMiddlewares,
          // Ends tool streams when the run is torn down at once (eino
          // `cancelMonitoredToolHandler`, also on the agentic path).
          cancelMonitoredToolMiddleware,
        ] {
    ensureAdkTypesRegistered();
    registerAgenticAdkTypes();
  }

  /// The configuration.
  final AgenticChatModelAgentConfig config;

  final List<ToolMiddleware> _toolMiddlewares;
  Future<_ExecContext>? _defaultExec;

  @override
  String get name => config.name;

  @override
  String get description => config.description;

  /// Port of `TypedChatModelAgent.GetType`.
  @override
  String get componentTypeName => 'ChatModel';

  @override
  StreamReader<AgenticAgentEvent> run(
    RunContext ctx,
    AgenticAgentInput input, {
    List<AgentRunOption> options = const [],
  }) =>
      _startRun(ctx, options, input: input);

  @override
  StreamReader<AgenticAgentEvent> resume(
    RunContext ctx,
    ResumeInfo info, {
    List<AgentRunOption> options = const [],
  }) =>
      _startRun(ctx, options, resumeInfo: info);

  StreamReader<AgenticAgentEvent> _startRun(
    RunContext context,
    List<AgentRunOption> options, {
    AgenticAgentInput? input,
    ResumeInfo? resumeInfo,
  }) {
    final (reader, writer) = pipe<AgenticAgentEvent>();
    final (cancelContext, owned) = resolveRunCancelContext(
      context,
      CommonAgentOptions.of(options).cancelContext,
    );
    var ctx = context;
    void Function()? abortOnlyCancel;
    if (owned && cancelContext != null && cancelContext.abortOnly) {
      (ctx, abortOnlyCancel) = withAbortOnlyCancelContext(ctx, cancelContext);
    }
    unawaited(
      _start(
        ctx,
        writer,
        options,
        input: input,
        resumeInfo: resumeInfo,
        cancel: _RunCancel(cancelContext, owned: owned),
      ).whenComplete(() => abortOnlyCancel?.call()),
    );
    return owned
        ? wrapAgenticEventsWithCancelContext(reader, cancelContext)
        : reader;
  }

  Future<void> _start(
    RunContext context,
    StreamWriter<AgenticAgentEvent> writer,
    List<AgentRunOption> options, {
    required _RunCancel cancel,
    AgenticAgentInput? input,
    ResumeInfo? resumeInfo,
  }) async {
    final cancelContext = cancel.context;
    void failed(Object error, [StackTrace? stackTrace]) {
      if (cancel.owned) cancelContext?.markDone();
      writer.send(AgenticAgentEvent(error: error, stackTrace: stackTrace));
    }

    try {
      var ctx = withAgenticExecContext(
        context,
        AgenticExecContext(writer: writer, cancelContext: cancelContext),
      );
      final _ExecContext defaults;
      try {
        defaults = await (_defaultExec ??= _prepareExecContext());
        // Eino keeps a failure to prepare (a tool's info()) and sends it as
        // it is on every run.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        failed(error, stackTrace);
        return;
      }
      final _ExecContext exec;
      final _ExecContext graphExec;
      try {
        (ctx, exec, graphExec) = await _execContextFor(ctx, defaults);
        // A middleware's failure in beforeAgent.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        failed(
          ThreepioException(
            'ChatModelAgent getRunFunc error: $error',
            cause: error,
          ),
          stackTrace,
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
      final AgenticAgentInput runInput;
      if (resumeInfo == null) {
        store = BridgeStore();
        runInput = input!;
      } else {
        final state = resumeInfo.interruptState;
        if (state is! String) {
          failed(
            ThreepioException(
              "ChatModelAgent.Resume: agent '$name' was asked to resume but "
              '${state == null ? 'has no state' : 'has invalid interrupt '
                  'state type: ${state.runtimeType}'}',
            ),
          );
          return;
        }
        store = BridgeStore.resume(bridgeCheckpointId, base64Decode(state));
        runInput = AgenticAgentInput(enableStreaming: resumeInfo.enableStreaming);
        final resumeData = resumeInfo.resumeData;
        if (resumeData != null && resumeData is! ChatModelAgentResumeData) {
          failed(
            ThreepioException(
              "ChatModelAgent.Resume: agent '$name' was asked to resume but "
              'has invalid resume data type: ${resumeData.runtimeType}',
            ),
          );
          return;
        }
        // Eino's resume data rewrites a classic history (`*State`); on an
        // agentic state its modifier finds no such state and does nothing.
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

      ctx = withCancelContext(ctx, cancelContext);
      await _runGraph(
        ctx,
        graphExec.tools.isEmpty
            ? _buildNoTools(ctx, store, cancelContext)
            : _buildReact(ctx, graphExec, store, cancelContext),
        cancel: cancel,
        writer: writer,
        store: store,
        input: runInput,
        instruction: exec.instruction,
        returnDirectly: exec.returnDirectly,
        composeOptions: composeOptions,
        afterToolCallsHook: runOptions.afterToolCallsHook,
      );
      // Whatever escaped is the run's failure.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      failed(error, stackTrace);
    } finally {
      await writer.close();
    }
  }

  /// The setup of this run and the one its graph is built from. Port of
  /// eino `getRunFunc`.
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
        ...handlersToToolMiddlewares([
          for (final handler in config.handlers) AgenticToolHooks(handler),
        ]),
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
        toolInfos: await _toolInfosOf(agent.tools, ctx),
        toolSearchTool: agent.toolSearchTool,
        toolUpdated: true,
        rebuildGraph: (defaults.tools.isEmpty && agent.tools.isNotEmpty) ||
            (defaults.returnDirectly.isEmpty &&
                agent.returnDirectly.isNotEmpty),
      ),
    );
  }

  /// Port of eino `applyAfterAgent`.
  Future<void> _applyAfterAgent(RunContext context) async {
    if (config.handlers.isEmpty) return;
    var state = AgenticChatModelAgentState(messages: const []);
    await processState<AgenticReactState>(context, (_, saved) {
      state = AgenticChatModelAgentState(
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
            'handler[$index] (${handler.runtimeType}) AfterAgent failed: '
            '$error',
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
  /// `buildAgenticReActRunFunc`.
  Future<Runnable<_RunInput, AgenticMessage>> _buildReact(
    RunContext ctx,
    _ExecContext exec,
    BridgeStore store,
    CancelContext? cancelContext,
  ) async {
    final react = await newAgenticReactGraph(
      ctx,
      AgenticReactConfig(
        model: config.model,
        toolsConfig: _toolsNodeConfig(exec),
        modelWrapperConfig: AgenticModelWrapperConfig(
          handlers: config.handlers,
          toolInfos: exec.toolInfos,
          cancelContext: cancelContext,
        ),
        toolsReturnDirectly: exec.returnDirectly,
        agentName: name,
        maxIterations: config.maxIterations,
        cancelContext: cancelContext,
        afterAgent: config.handlers.isEmpty
            ? null
            : (ctx, message) async {
                await _applyAfterAgent(ctx);
                return message;
              },
      ),
    );
    final genModelInput = config.genModelInput ?? defaultAgenticGenModelInput;
    final chain = Chain<_RunInput, AgenticMessage>()
      ..appendLambda(
        Lambda.invokable(
          (RunContext ctx, _RunInput input) async => AgenticReactInput(
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
  /// `buildNoToolsRunFunc` (agentic: `AppendAgenticModel`).
  Future<Runnable<_RunInput, AgenticMessage>> _buildNoTools(
    RunContext ctx,
    BridgeStore store,
    CancelContext? cancelContext,
  ) {
    final model = buildAgenticModelWrappers(
      config.model,
      AgenticModelWrapperConfig(
        handlers: config.handlers,
        cancelContext: cancelContext,
      ),
    );
    final genModelInput = config.genModelInput ?? defaultAgenticGenModelInput;
    final chain = Chain<_RunInput, AgenticMessage>(
      localState: LocalState.of<AgenticReactState>((_) => AgenticReactState()),
    )
      ..appendLambda(
        Lambda.invokable((RunContext ctx, _RunInput input) async {
          final messages =
              await genModelInput(ctx, input.instruction, input.input);
          await processState<AgenticReactState>(
            ctx,
            (_, state) => state.messages.addAll(messages),
          );
          return messages;
        }),
      )
      ..appendAgenticModel(model);
    if (config.handlers.isNotEmpty) {
      chain.appendLambda(
        Lambda.invokable((RunContext ctx, AgenticMessage message) async {
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
    Future<Runnable<_RunInput, AgenticMessage>> build, {
    required _RunCancel cancel,
    required StreamWriter<AgenticAgentEvent> writer,
    required BridgeStore store,
    required AgenticAgentInput input,
    required String instruction,
    required Set<String> returnDirectly,
    required List<CallOption> composeOptions,
    required FutureOr<void> Function(RunContext ctx)? afterToolCallsHook,
  }) async {
    final cancelContext = cancel.context;
    final Runnable<_RunInput, AgenticMessage> runnable;
    try {
      runnable = await build;
      // A failure to build or compile the graph.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      if (cancel.owned) cancelContext?.markDone();
      writer.send(AgenticAgentEvent(error: error, stackTrace: stackTrace));
      return;
    }
    var graphCtx = context;
    if (cancelContext != null) {
      // An immediate cancel interrupts the graph with no wait.
      final (interruptible, interrupter) = graphCtx.withGraphInterrupt();
      graphCtx = interruptible;
      cancelContext.addGraphInterrupter(interrupter);
    }
    final ctx = withAgenticExecContext(
      graphCtx,
      AgenticExecContext(
        writer: writer,
        runtimeReturnDirectly: returnDirectly,
        cancelContext: cancelContext,
        afterToolCallsHook: afterToolCallsHook,
      ),
    );
    // A run cancelled before its graph started ends here (the shared check
    // sends a classic error event; its error is passed on).
    if (checkPreExecCancel(
      cancelContext,
      (event) => writer.send(
        AgenticAgentEvent(error: event.error, stackTrace: event.stackTrace),
      ),
    )) {
      return;
    }
    final runInput = _RunInput(input, instruction);
    final options = [
      ...composeOptions,
      if (config.toolsConfig.emitInternalEvents)
        CallOption.tool(
          ToolOptions(extensions: [AgenticAgentToolEventSink(writer)]),
        ),
      // Eino passes the streaming flag to agent tools on the agentic path
      // too (an agent tool among the tools streams its inner run).
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
      await _handleRunError(ctx, error, stackTrace, store, writer, cancel);
    }
  }

  /// Port of eino `handleRunFuncError`.
  Future<void> _handleRunError(
    RunContext ctx,
    Object error,
    StackTrace stackTrace,
    BridgeStore store,
    StreamWriter<AgenticAgentEvent> writer,
    _RunCancel cancel,
  ) async {
    final cancelContext = cancel.context;
    // An abort-only run that was torn down ends silently.
    if (isAbortOnlyCancelled(cancelContext)) {
      if (cancel.owned) cancelContext!.markDone();
      return;
    }
    final info = extractInterruptInfo(error);
    if (info == null) {
      if (cancel.owned) cancelContext?.markDone();
      writer.send(AgenticAgentEvent(error: error, stackTrace: stackTrace));
      return;
    }
    // A business interrupt while no cancel is pending ends the run; with a
    // cancel pending the interrupt becomes its error further out.
    if (cancelContext != null && !cancelContext.shouldCancel) {
      cancelContext.markDone();
    }
    final data = await store.get(bridgeCheckpointId);
    if (data == null) {
      writer.send(
        AgenticAgentEvent(
          agentName: name,
          error: const ThreepioException(
            'interrupt occurred but checkpoint data is missing',
          ),
        ),
      );
      return;
    }
    final signal = compositeInterrupt(ctx, info, base64Encode(data), [error])
        as AddressedInterruptSignal;
    writer.send(
      AgenticAgentEvent(
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
  String toString() => 'AgenticChatModelAgent($name)';
}

/// The compose options from the run options. Port of eino
/// `getComposeOptions` (without the deprecated history modifier); the run
/// options are the classic ones, message-agnostic.
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

/// The infos of [tools]; with [ctx], a tool that can build its info from
/// the run's context does.
Future<List<ToolInfo>> _toolInfosOf(
  List<BaseTool> tools, [
  RunContext? ctx,
]) async =>
    [
      for (final tool in tools)
        await (ctx != null && tool is RunContextToolInfo
            ? (tool as RunContextToolInfo).infoWithContext(ctx)
            : tool.info()),
    ];

/// The cancel context of a run and whether the agent owns it (marks it done
/// and turns interrupts into cancels) or an agent around it does.
final class _RunCancel {
  const _RunCancel(this.context, {required this.owned});

  final CancelContext? context;
  final bool owned;
}

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

/// The input of the agent's graph. Port of eino `agenticReactRunInput` and
/// `typedNoToolsInput`.
final class _RunInput {
  const _RunInput(this.input, this.instruction);

  final AgenticAgentInput input;
  final String instruction;
}
