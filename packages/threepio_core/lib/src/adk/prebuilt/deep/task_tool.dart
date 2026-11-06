/// The `task` tool of the deep agent: hands a task to a sub-agent that runs
/// with a fresh context.
///
/// Port of eino `adk/prebuilt/deep/task_tool.go`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../components/model/base_chat_model.dart';
import '../../../components/tool/invokable_tool.dart';
import '../../../components/tool/tool_options.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/tool_info.dart';
import '../../eino/agent.dart';
import '../../eino/agent_tool.dart';
import '../../eino/chat_model_agent.dart';
import '../../eino/chat_model_agent_config.dart';
import '../../eino/middleware.dart';
import '../../eino/model_failover.dart';
import '../../eino/tool_info_context.dart';
import '../../middlewares/internal/go_compat.dart';
import 'deep_agent.dart';
import 'prompt.dart';

/// Builds the description of the `task` tool from the sub-agents it can
/// start. Port of `deep.Config.TaskToolDescriptionGenerator`.
typedef TaskToolDescriptionGenerator = FutureOr<String> Function(
  RunContext ctx,
  List<Agent> availableAgents,
);

/// The name of the task tool. Port of eino `taskToolName`.
const taskToolName = 'task';

/// The name of the general-purpose sub-agent. Port of eino
/// `generalAgentName`.
const generalAgentName = 'general-purpose';

/// The default description of the `task` tool: eino's text with one line
/// `- <name>: <description>` per sub-agent. Port of
/// `typedDefaultTaskToolDescription`.
@visibleForTesting
String defaultTaskToolDescription(RunContext ctx, List<Agent> subAgents) {
  final list = StringBuffer();
  for (final agent in subAgents) {
    list.write('- ${agent.name}: ${agent.description}\n');
  }
  return formatNamed(deepTaskToolDescriptionTemplate(), {
    'other_agents': list.toString(),
  });
}

/// The `task` tool: starts the sub-agent named by `subagent_type` with
/// `description` as its only message (an `AgentTool` each) and returns its
/// last message.
///
/// Port of eino's unexported `typedTaskTool`. The description is built per
/// run, with the run's context.
@internal
final class TaskTool extends InvokableTool implements RunContextToolInfo {
  /// A tool over [subAgentTools] (by name), described from [subAgents].
  TaskTool({
    required Map<String, InvokableTool> subAgentTools,
    required List<Agent> subAgents,
    TaskToolDescriptionGenerator? descriptionGenerator,
  })  : subAgentTools = Map.unmodifiable(subAgentTools),
        subAgents = List.unmodifiable(subAgents),
        _describe = descriptionGenerator ?? defaultTaskToolDescription;

  /// The tool of each sub-agent, by name.
  final Map<String, InvokableTool> subAgentTools;

  /// The sub-agents the description lists, in order (the general-purpose
  /// one last).
  final List<Agent> subAgents;

  final TaskToolDescriptionGenerator _describe;

  @override
  Future<ToolInfo> info() => infoWithContext(RunContext.background());

  @override
  Future<ToolInfo> infoWithContext(RunContext ctx) async => ToolInfo.fromParams(
        name: taskToolName,
        desc: await _describe(ctx, subAgents),
        params: const {
          'subagent_type': ParameterInfo(type: DataType.string),
          'description': ParameterInfo(type: DataType.string),
        },
      );

  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final (subagentType, description) = _argumentsOf(argumentsJson);
    final tool = subAgentTools[subagentType];
    if (tool == null) {
      throw ThreepioException('subagent type $subagentType not found');
    }
    return tool.invokableRun(
      ctx,
      jsonEncode({'request': description}),
      options: options,
    );
  }

  /// Go's `json.Unmarshal` into `taskToolArgument`: missing fields are
  /// empty, unknown ones ignored (field names must match exactly; Go also
  /// accepts other letter cases).
  static (String, String) _argumentsOf(String argumentsJson) {
    try {
      // Go's json.Unmarshal of `null` leaves the struct empty.
      final decoded = jsonDecode(argumentsJson) ?? const <String, Object?>{};
      if (decoded is! Map<String, Object?>) {
        throw FormatException('not a JSON object', argumentsJson);
      }
      String field(String key) {
        final value = decoded[key];
        if (value == null) return '';
        if (value is! String) {
          throw FormatException('"$key" must be a string', argumentsJson);
        }
        return value;
      }

      return (field('subagent_type'), field('description'));
    } on FormatException catch (error) {
      throw ThreepioFormatException(
        'failed to unmarshal task tool input json: ${error.message}',
        source: argumentsJson,
        cause: error,
      );
    }
  }

  @override
  String toString() => 'TaskTool(${subAgentTools.keys.join(', ')})';
}

/// The `task` tool over [subAgents] and, unless [withoutGeneralSubAgent], a
/// general-purpose sub-agent with the deep agent's [model], [instruction],
/// tools, [handlers] and failover (not its retry config, as in eino). Port
/// of `typedNewTaskTool`.
@internal
TaskTool newTaskTool({
  required List<Agent> subAgents,
  required bool withoutGeneralSubAgent,
  TaskToolDescriptionGenerator? descriptionGenerator,
  BaseChatModel? model,
  String instruction = '',
  ToolsConfig toolsConfig = const ToolsConfig(),
  int maxIteration = 20,
  List<ChatModelAgentMiddleware> handlers = const [],
  ModelFailoverConfig? modelFailoverConfig,
}) {
  final tools = <String, InvokableTool>{};
  final described = List<Agent>.of(subAgents);
  if (!withoutGeneralSubAgent) {
    if (model == null) {
      throw ArgumentError.notNull('model');
    }
    final general = ChatModelAgent(
      ChatModelAgentConfig(
        name: generalAgentName,
        description: deepGeneralAgentDescription(),
        instruction: instruction,
        model: model,
        toolsConfig: toolsConfig,
        maxIterations: maxIteration,
        handlers: handlers,
        genModelInput: deepGenModelInput,
        modelFailoverConfig: modelFailoverConfig,
      ),
    );
    tools[general.name] = AgentTool(general);
    described.add(general);
  }
  for (final agent in subAgents) {
    tools[agent.name] = AgentTool(agent);
  }
  return TaskTool(
    subAgentTools: tools,
    subAgents: described,
    descriptionGenerator: descriptionGenerator,
  );
}

/// The middleware that adds the `task` tool and its prompt. Port of
/// `typedTaskToolMiddleware`.
@internal
ChatModelAgentMiddleware taskToolMiddleware(TaskTool tool) =>
    AppendPromptToolMiddleware(prompt: deepTaskPrompt(), tool: tool);
