/// The deep agent: a `ChatModelAgent` with a todo list, file and shell tools,
/// and sub-agents it hands tasks to.
///
/// Port of eino `adk/prebuilt/deep` (`deep.go`, `types.go`).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../../components/model/base_chat_model.dart';
import '../../../components/tool/invokable_tool.dart';
import '../../../core/run_context.dart';
import '../../../schema/message.dart';
import '../../eino/agent.dart';
import '../../eino/chat_model_agent.dart';
import '../../eino/chat_model_agent_config.dart';
import '../../eino/middleware.dart';
import '../../eino/middleware_context.dart';
import '../../eino/model_failover.dart';
import '../../eino/model_retry.dart';
import '../../filesystem/backend.dart';
import '../../middlewares/filesystem/filesystem.dart';
import 'prompt.dart';
import 'task_tool.dart';
import 'write_todos.dart';

/// The configuration of a deep agent.
///
/// Port of eino `deep.Config`. Not ported: `OutputKey` (agent transfer, not
/// recommended by eino; write a session value in a middleware's
/// `afterAgent` instead) and the deprecated `Middlewares` (use [handlers]).
final class DeepAgentConfig {
  /// The configuration of a deep agent with [chatModel].
  const DeepAgentConfig({
    required this.chatModel,
    this.name = '',
    this.description = '',
    this.instruction = '',
    this.subAgents = const [],
    this.toolsConfig = const ToolsConfig(),
    this.maxIteration = 20,
    this.backend,
    this.shell,
    this.streamingShell,
    this.withoutWriteTodos = false,
    this.withoutGeneralSubAgent = false,
    this.taskToolDescriptionGenerator,
    this.handlers = const [],
    this.modelRetryConfig,
    this.modelFailoverConfig,
  });

  /// The name of the agent.
  final String name;

  /// What the agent does.
  final String description;

  /// The model; with tools it is told about them as a `ChatModelAgent`'s
  /// model is.
  final BaseChatModel chatModel;

  /// The system instruction; eino's built-in one (general assistant
  /// guidelines, security, coding style and tool usage) when empty.
  final String instruction;

  /// Agents the `task` tool can start, each with a fresh context (only the
  /// task's description as input). They need distinct names.
  final List<Agent> subAgents;

  /// The agent's own tools (the general-purpose sub-agent gets them too).
  final ToolsConfig toolsConfig;

  /// How many model calls a run may make; 20 when 0 or less.
  final int maxIteration;

  /// The files the file tools (`ls`, `read_file`, `write_file`,
  /// `edit_file`, `glob`, `grep`) work on; without it there are none.
  final FilesystemBackend? backend;

  /// A shell for the `execute` tool; needs [backend]; not together with
  /// [streamingShell].
  final Shell? shell;

  /// A streaming shell for the `execute` tool; needs [backend]; not
  /// together with [shell].
  final StreamingShell? streamingShell;

  /// Leaves out the `write_todos` tool.
  final bool withoutWriteTodos;

  /// Leaves out the general-purpose sub-agent (a copy of this agent without
  /// the `task` tool).
  final bool withoutGeneralSubAgent;

  /// Builds the `task` tool's description from the sub-agents; eino's text
  /// listing them when `null`.
  final TaskToolDescriptionGenerator? taskToolDescriptionGenerator;

  /// More middlewares, after the built-in ones (the general-purpose
  /// sub-agent gets them too).
  final List<ChatModelAgentMiddleware> handlers;

  /// Retries of failed model calls (of this agent only).
  final ModelRetryConfig? modelRetryConfig;

  /// Other models to try when a call fails (also for the general-purpose
  /// sub-agent).
  final ModelFailoverConfig? modelFailoverConfig;
}

/// The deep agent.
///
/// Port of eino `deep.New`: a `ChatModelAgent` with eino's instruction (or
/// [DeepAgentConfig.instruction]) and, as middlewares in this order,
///
/// 1. the `write_todos` tool, which keeps the agent's todo list in the
///    session value [sessionKeyTodos] (unless `withoutWriteTodos`);
/// 2. a [FilesystemMiddleware] with the file tools and `execute` (when
///    there is a backend);
/// 3. the `task` tool, which starts a sub-agent (one of
///    [DeepAgentConfig.subAgents] or the general-purpose one) on a task
///    with a fresh context and returns its answer (when there is any
///    sub-agent);
/// 4. [DeepAgentConfig.handlers].
///
/// ```dart
/// final agent = await DeepAgent.create(ctx, DeepAgentConfig(
///   name: 'coder',
///   chatModel: model,
///   backend: InMemoryBackend(),
///   handlers: [SummarizationMiddleware(model: model)],
/// ));
/// final events = Runner(agent: agent).query(ctx, 'Summarize /data/report.csv');
/// ```
///
/// Like eino's, the agent does not summarize its history by itself: add a
/// `SummarizationMiddleware` to `handlers` for long runs. The model input is
/// the instruction and the messages, without filling session values into
/// the instruction.
abstract final class DeepAgent {
  /// The session key of the todo list (`List<Todo>`). Port of
  /// `SessionKeyTodos`.
  static const sessionKeyTodos = 'deep_agent_session_key_todos';

  /// The deep agent of [config]. Port of `deep.New`.
  ///
  /// Throws [ArgumentError] for a shell without a backend or for both
  /// shells (eino's `filesystem.New` errors).
  static Future<ResumableAgent> create(
    RunContext ctx,
    DeepAgentConfig config,
  ) async {
    ensureDeepTypesRegistered();
    final handlers = buildBuiltinMiddlewares(config);
    final instruction = config.instruction.isEmpty
        ? deepBaseAgentInstruction()
        : config.instruction;
    if (!config.withoutGeneralSubAgent || config.subAgents.isNotEmpty) {
      final tool = newTaskTool(
        descriptionGenerator: config.taskToolDescriptionGenerator,
        subAgents: config.subAgents,
        withoutGeneralSubAgent: config.withoutGeneralSubAgent,
        model: config.chatModel,
        instruction: instruction,
        toolsConfig: config.toolsConfig,
        maxIteration: config.maxIteration,
        handlers: [...handlers, ...config.handlers],
        modelFailoverConfig: config.modelFailoverConfig,
      );
      handlers.add(taskToolMiddleware(tool));
    }
    return ChatModelAgent(
      ChatModelAgentConfig(
        name: config.name,
        description: config.description,
        instruction: instruction,
        model: config.chatModel,
        toolsConfig: config.toolsConfig,
        maxIterations: config.maxIteration,
        handlers: [...handlers, ...config.handlers],
        genModelInput: deepGenModelInput,
        modelRetryConfig: config.modelRetryConfig,
        modelFailoverConfig: config.modelFailoverConfig,
      ),
    );
  }
}

/// The model input of the deep agent and its general-purpose sub-agent: a
/// system message with the instruction (when there is one), then the input.
/// Unlike `defaultGenModelInput`, session values are not filled into the
/// instruction. Port of `typedGenModelInput`.
@internal
List<Message> deepGenModelInput(
  RunContext ctx,
  String instruction,
  AgentInput input,
) =>
    [
      if (instruction.isNotEmpty) Message.system(instruction),
      ...input.messages,
    ];

/// The built-in middlewares before the `task` tool: `write_todos` and the
/// file tools. Port of `buildTypedBuiltinAgentMiddlewares`.
@visibleForTesting
List<ChatModelAgentMiddleware> buildBuiltinMiddlewares(DeepAgentConfig config) {
  final middlewares = <ChatModelAgentMiddleware>[];
  if (!config.withoutWriteTodos) {
    middlewares.add(AppendPromptToolMiddleware(tool: newWriteTodosTool()));
  }
  if (config.backend != null || config.shell != null || config.streamingShell != null) {
    final backend = config.backend;
    if (backend == null) {
      throw ArgumentError('backend should not be nil');
    }
    middlewares.add(
      FilesystemMiddleware(
        backend: backend,
        shell: config.shell,
        streamingShell: config.streamingShell,
      ),
    );
  }
  return middlewares;
}

/// Appends [prompt] to the agent's instruction and [tool] to its tools when
/// a run starts. Port of eino's unexported `typedAppendPromptTool`.
@internal
final class AppendPromptToolMiddleware extends ChatModelAgentMiddleware {
  /// A middleware that adds [prompt] and [tool].
  const AppendPromptToolMiddleware({this.prompt = '', this.tool});

  /// The text appended to the instruction.
  final String prompt;

  /// The tool added to the agent's tools, if any.
  final BaseTool? tool;

  @override
  FutureOr<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) {
    agent.instruction += prompt;
    final added = tool;
    if (added != null) agent.tools = [...agent.tools, added];
    return (ctx, agent);
  }

  @override
  String toString() => 'AppendPromptToolMiddleware($tool)';
}
