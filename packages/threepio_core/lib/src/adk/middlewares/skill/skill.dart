/// A middleware that lets an agent load skills (SKILL.md files) and run them
/// inline or in a sub-agent.
///
/// Port of eino `adk/middlewares/skill/skill.go` (`NewMiddleware`, classic
/// messages). Not ported, because eino deprecates them: `skill.New` (the
/// `AgentMiddleware` path) and `Config.UseChinese` (use `setAdkLanguage`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../components/model/base_chat_model.dart';
import '../../../components/model/chat_model_options.dart';
import '../../../components/tool/invokable_tool.dart';
import '../../../components/tool/tool_options.dart';
import '../../../compose/local_state.dart';
import '../../../compose/tools_node.dart' show toolCallIdOf;
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/tool_info.dart';
import '../../../streaming/stream_reader.dart';
import '../../eino/agent.dart';
import '../../eino/agent_context.dart';
import '../../eino/event_senders.dart' show bindToolsFor;
import '../../eino/middleware.dart';
import '../../eino/middleware_context.dart';
import '../../eino/react_graph.dart' show ReactState;
import '../../eino/tool_info_context.dart';
import '../internal/go_compat.dart';
import 'prompt.dart';

/// The run-local key of the model an inline skill switched to. Port of
/// `activeModelKey`.
@visibleForTesting
const String skillActiveModelKey = '__skill_active_model__';

/// How a skill runs. Port of eino `skill.ContextMode`.
enum SkillContextMode {
  /// In the current agent: the tool returns the skill's content (the
  /// default, an empty or unknown `context`).
  inline(''),

  /// In a new sub-agent without the conversation. Port of `ContextModeFork`.
  fork('fork'),

  /// In a new sub-agent that gets the conversation. Port of
  /// `ContextModeForkWithContext`.
  forkWithContext('fork_with_context');

  const SkillContextMode(this.value);

  /// The value in a SKILL.md front matter.
  final String value;

  /// The mode written as [value]; anything unknown runs inline, as in eino.
  static SkillContextMode parse(String? value) =>
      values.firstWhere((mode) => mode.value == value, orElse: () => inline);
}

/// The YAML front matter of a SKILL.md file. Port of eino
/// `skill.FrontMatter`.
@immutable
final class SkillFrontMatter {
  /// A front matter.
  const SkillFrontMatter({
    required this.name,
    this.description = '',
    this.context = SkillContextMode.inline,
    this.agent = '',
    this.model = '',
  });

  /// The skill's name, which the model passes to the tool.
  final String name;

  /// When to use the skill; shown in the tool description.
  final String description;

  /// How the skill runs.
  final SkillContextMode context;

  /// The agent a forked skill runs in (asked of the [AgentHub]; `''` for
  /// its default).
  final String agent;

  /// The model the skill wants (asked of the [ModelHub]).
  final String model;

  @override
  bool operator ==(Object other) =>
      other is SkillFrontMatter &&
      other.name == name &&
      other.description == description &&
      other.context == context &&
      other.agent == agent &&
      other.model == model;

  @override
  int get hashCode => Object.hash(name, description, context, agent, model);

  @override
  String toString() => 'SkillFrontMatter($name)';
}

/// A skill: its front matter, its instructions and where it lives. Port of
/// eino `skill.Skill`.
@immutable
final class Skill {
  /// A skill.
  const Skill({required this.frontMatter, this.content = '', this.baseDirectory = ''});

  /// The front matter.
  final SkillFrontMatter frontMatter;

  /// The markdown after the front matter: the skill's instructions.
  final String content;

  /// The absolute directory of the SKILL.md file.
  final String baseDirectory;

  /// The skill's name.
  String get name => frontMatter.name;

  /// When to use the skill.
  String get description => frontMatter.description;

  /// How the skill runs.
  SkillContextMode get context => frontMatter.context;

  /// The agent a forked skill runs in.
  String get agent => frontMatter.agent;

  /// The model the skill wants.
  String get model => frontMatter.model;

  @override
  bool operator ==(Object other) =>
      other is Skill &&
      other.frontMatter == frontMatter &&
      other.content == content &&
      other.baseDirectory == baseDirectory;

  @override
  int get hashCode => Object.hash(frontMatter, content, baseDirectory);

  @override
  String toString() => 'Skill($name, $baseDirectory)';
}

/// Where skills come from. Port of eino `skill.Backend`.
abstract interface class SkillBackend {
  /// The front matter of every skill. Port of `Backend.List`.
  Future<List<SkillFrontMatter>> list(RunContext ctx);

  /// The skill [name]; throws when there is none. Port of `Backend.Get`.
  Future<Skill> get(RunContext ctx, String name);
}

/// What the middleware passes to [AgentHub.get]. Port of eino
/// `skill.AgentHubOptions`.
@immutable
final class AgentHubOptions {
  /// Options with the skill's [model], if it names one.
  const AgentHubOptions({this.model});

  /// The model the skill asked for (from the [ModelHub]); `null` when it
  /// names none and the hub should use its default.
  final BaseChatModel? model;
}

/// Gives the agents forked skills run in. Port of eino `skill.AgentHub`.
abstract interface class AgentHub {
  /// The agent [name]; `''` asks for the default agent.
  Future<Agent> get(RunContext ctx, String name, AgentHubOptions options);
}

/// Gives the models skills name. Port of eino `skill.ModelHub`.
abstract interface class ModelHub {
  /// The model [name].
  Future<BaseChatModel> get(RunContext ctx, String name);
}

/// What [SkillMiddleware.buildForkMessages] gets. Port of eino
/// `skill.SubAgentInput`.
@immutable
final class SkillSubAgentInput {
  /// The input of a forked skill.
  const SkillSubAgentInput({
    required this.skill,
    required this.mode,
    required this.rawArguments,
    required this.skillContent,
    this.history = const [],
    this.toolCallId = '',
  });

  /// The skill.
  final Skill skill;

  /// Its mode.
  final SkillContextMode mode;

  /// The tool call's arguments, as JSON.
  final String rawArguments;

  /// The skill's content for this call.
  final String skillContent;

  /// The conversation (only for [SkillContextMode.forkWithContext]).
  final List<Message> history;

  /// The id of the skill tool call (only for
  /// [SkillContextMode.forkWithContext]).
  final String toolCallId;
}

/// What [SkillMiddleware.formatForkResult] gets. Port of eino
/// `skill.SubAgentOutput`.
@immutable
final class SkillSubAgentOutput {
  /// The output of a forked skill.
  const SkillSubAgentOutput({
    required this.skill,
    required this.mode,
    required this.rawArguments,
    this.messages = const [],
    this.results = const [],
  });

  /// The skill.
  final Skill skill;

  /// Its mode.
  final SkillContextMode mode;

  /// The tool call's arguments, as JSON.
  final String rawArguments;

  /// Every message the sub-agent sent.
  final List<Message> messages;

  /// The non-empty contents of those messages.
  final List<String> results;
}

/// The skills system prompt for the tool [toolName]. Port of eino
/// `skill.SystemPromptFunc`.
typedef SkillSystemPromptBuilder = String Function(RunContext ctx, String toolName);

/// The skill tool's description for [skills]. Port of eino
/// `skill.ToolDescriptionFunc`.
typedef SkillToolDescriptionBuilder = String Function(
  RunContext ctx,
  List<SkillFrontMatter> skills,
);

/// The skill tool's parameters from [defaults] (only the required `skill`).
/// Port of eino `Config.CustomToolParams`.
typedef SkillToolParamsBuilder = FutureOr<Map<String, ParameterInfo>?> Function(
  RunContext ctx,
  Map<String, ParameterInfo> defaults,
);

/// The content of a skill for one call. Port of eino `Config.BuildContent`.
typedef SkillContentBuilder = FutureOr<String> Function(
  RunContext ctx,
  Skill skill,
  String rawArguments,
);

/// The messages a forked skill's agent starts with. Port of eino
/// `Config.BuildForkMessages`.
typedef SkillForkMessagesBuilder = FutureOr<List<Message>> Function(
  RunContext ctx,
  SkillSubAgentInput input,
);

/// The tool result of a forked skill. Port of eino
/// `Config.FormatForkResult`.
typedef SkillForkResultFormatter = FutureOr<String> Function(
  RunContext ctx,
  SkillSubAgentOutput output,
);

/// Gives the agent a skill tool and tells it how to use skills.
///
/// Port of eino `skill.NewMiddleware`. `beforeAgent` appends the skills
/// system prompt to the instruction and adds the tool (named `skill` unless
/// [skillToolName] says otherwise), whose description lists every skill of
/// [backend]. When the model calls it with a skill's name:
///
/// * an **inline** skill returns its content (by default `Launching skill:
///   <name>`, its directory and its instructions; [buildContent] replaces
///   it). A skill that names a model makes the following model calls of the
///   run use that model from [modelHub];
/// * a **fork** skill runs in an agent from [agentHub] (the skill's `agent`,
///   with its model from [modelHub]) that gets only the skill's content as a
///   user message; **fork_with_context** gives it the conversation and the
///   content as the skill call's tool result. [buildForkMessages] replaces
///   those messages, [formatForkResult] the tool result (by default the
///   sub-agent's answers).
final class SkillMiddleware extends ChatModelAgentMiddleware {
  /// A skill middleware on [backend].
  SkillMiddleware({
    required SkillBackend backend,
    String? skillToolName,
    AgentHub? agentHub,
    ModelHub? modelHub,
    SkillSystemPromptBuilder? customSystemPrompt,
    SkillToolDescriptionBuilder? customToolDescription,
    SkillToolParamsBuilder? customToolParams,
    SkillContentBuilder? buildContent,
    SkillForkMessagesBuilder? buildForkMessages,
    SkillForkResultFormatter? formatForkResult,
  }) : this._(
          skillToolName ?? defaultSkillToolName,
          customSystemPrompt,
          SkillTool(
            backend: backend,
            name: skillToolName ?? defaultSkillToolName,
            agentHub: agentHub,
            modelHub: modelHub,
            customToolDescription: customToolDescription,
            customToolParams: customToolParams,
            buildContent: buildContent,
            buildForkMessages: buildForkMessages,
            formatForkResult: formatForkResult,
          ),
        );

  SkillMiddleware._(String name, SkillSystemPromptBuilder? customSystemPrompt, this.tool)
      : instruction = customSystemPrompt != null
            ? customSystemPrompt(RunContext.background(), name)
            : buildSkillSystemPrompt(name);

  /// What `beforeAgent` appends to the instruction. As in eino, a custom
  /// system prompt is built once, here (with a background context).
  final String instruction;

  /// The skill tool.
  final SkillTool tool;

  @override
  FutureOr<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) {
    agent
      ..instruction = '${agent.instruction}\n$instruction'
      ..tools = [...agent.tools, tool];
    return (ctx, agent);
  }

  /// Switches to the model an inline skill asked for: after such a skill
  /// the run's model calls go to that model of the [ModelHub].
  ///
  /// Port of `WrapModel`. Outside a run this throws, as in eino. The model
  /// is looked up when it is called (Dart's `wrapModel` is synchronous).
  @override
  BaseChatModel wrapModel(RunContext ctx, BaseChatModel model, ModelContext context) {
    final hub = tool.modelHub;
    if (hub == null) return model;
    final Object? name;
    try {
      if (!ctx.hasRunLocalValue(skillActiveModelKey)) return model;
      name = ctx.runLocalValue(skillActiveModelKey);
      // Outside a run the accessors throw StateError; eino returns an error.
      // ignore: avoid_catching_errors
    } on StateError catch (error) {
      throw ThreepioException(
        'failed to get active model from run local value: ${error.message}',
        cause: error,
      );
    }
    if (name is! String || name.isEmpty) return model;
    return _HubModel(hub, name, ctx);
  }
}

/// The model [name] of [hub], looked up when it is called.
final class _HubModel extends BaseChatModel {
  _HubModel(this.hub, this.name, this.ctx);

  final ModelHub hub;
  final String name;
  final RunContext ctx;

  Future<BaseChatModel> _resolve(ChatModelOptions? options) async {
    final BaseChatModel model;
    try {
      model = await hub.get(ctx, name);
    } on Object catch (error) {
      throw ThreepioException(
        "failed to get model '$name' from ModelHub: ${goValueString(error)}",
        cause: error,
      );
    }
    return bindToolsFor(model, options);
  }

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async =>
      (await _resolve(options)).generate(input, options: options);

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) async =>
      (await _resolve(options)).stream(input, options: options);
}

/// The skill tool. Port of eino `skillTool`.
@visibleForTesting
final class SkillTool extends InvokableTool implements RunContextToolInfo {
  /// The tool [name] on [backend].
  SkillTool({
    required this.backend,
    required this.name,
    this.agentHub,
    this.modelHub,
    this.customToolDescription,
    this.customToolParams,
    this.buildContent,
    this.buildForkMessages,
    this.formatForkResult,
  });

  /// Where the skills come from.
  final SkillBackend backend;

  /// The tool's name.
  final String name;

  /// Gives the agents of forked skills.
  final AgentHub? agentHub;

  /// Gives the models skills name.
  final ModelHub? modelHub;

  /// Replaces the description.
  final SkillToolDescriptionBuilder? customToolDescription;

  /// Changes the parameters.
  final SkillToolParamsBuilder? customToolParams;

  /// Replaces the content of a skill.
  final SkillContentBuilder? buildContent;

  /// Replaces the messages of a forked skill's agent.
  final SkillForkMessagesBuilder? buildForkMessages;

  /// Replaces the result of a forked skill.
  final SkillForkResultFormatter? formatForkResult;

  @override
  Future<ToolInfo> info() => infoWithContext(RunContext.background());

  /// The tool's info, listing the skills of [backend]. Port of `Info`; the
  /// `ChatModelAgent` calls it with the run's context.
  @override
  Future<ToolInfo> infoWithContext(RunContext ctx) async {
    final List<SkillFrontMatter> skills;
    try {
      skills = await backend.list(ctx);
    } on Object catch (error) {
      throw ThreepioException('failed to list skills: ${goValueString(error)}', cause: error);
    }
    final custom = customToolDescription;
    final description = custom != null
        ? custom(ctx, skills)
        : skillToolDescriptionBase() + renderSkillToolDescription(skills);
    final Map<String, ParameterInfo> params;
    try {
      params = await buildParams(ctx);
    } on Object catch (error) {
      throw ThreepioException(
        'failed to build skill tool params: ${goValueString(error)}',
        cause: error,
      );
    }
    return ToolInfo.fromParams(name: name, desc: description, params: params);
  }

  /// The parameters: the required `skill`, changed by [customToolParams].
  /// Port of `buildParamsOneOf`.
  @visibleForTesting
  Future<Map<String, ParameterInfo>> buildParams(RunContext ctx) async {
    final defaults = {
      'skill': ParameterInfo(type: DataType.string, desc: skillParamDescription(), required: true),
    };
    final custom = customToolParams;
    if (custom == null) return defaults;
    // Go falls back to the map it handed the callback (with its edits).
    final given = Map<String, ParameterInfo>.of(defaults);
    final params = Map<String, ParameterInfo>.of(await custom(ctx, given) ?? given);
    final skill = params['skill'] ?? defaults['skill']!;
    params['skill'] = ParameterInfo(
      type: skill.type,
      elemInfo: skill.elemInfo,
      subParams: skill.subParams,
      desc: skill.desc,
      enumValues: skill.enumValues,
      required: true,
    );
    return params;
  }

  @override
  Future<String> invokableRun(RunContext ctx, String argumentsJson, {ToolOptions? options}) =>
      _run(ctx, argumentsJson);

  @override
  Future<String> run(String argumentsJson) => _run(RunContext.background(), argumentsJson);

  Future<String> _run(RunContext ctx, String argumentsJson) async {
    final String skillName;
    try {
      final decoded = jsonDecode(argumentsJson);
      if (decoded is! Map) throw const FormatException('arguments are not a JSON object');
      final value = decoded['skill'];
      if (value != null && value is! String) throw const FormatException('"skill" is not a string');
      skillName = (value as String?) ?? '';
    } on FormatException catch (error) {
      throw ThreepioException('failed to unmarshal arguments: ${error.message}', cause: error);
    }
    final Skill skill;
    try {
      skill = await backend.get(ctx, skillName);
    } on Object catch (error) {
      throw ThreepioException('failed to get skill: ${goValueString(error)}', cause: error);
    }
    switch (skill.context) {
      case SkillContextMode.forkWithContext:
        return _runAgentMode(ctx, skill, forkHistory: true, rawArguments: argumentsJson);
      case SkillContextMode.fork:
        return _runAgentMode(ctx, skill, forkHistory: false, rawArguments: argumentsJson);
      case SkillContextMode.inline:
        if (skill.model.isNotEmpty) {
          try {
            ctx.setRunLocalValue(skillActiveModelKey, skill.model);
            // Outside a run there is nowhere to keep it; eino ignores that.
            // ignore: avoid_catching_errors
          } on StateError {
            // Nothing to do.
          }
        }
        return _skillContent(ctx, skill, argumentsJson);
    }
  }

  Future<String> _skillContent(RunContext ctx, Skill skill, String rawArguments) async {
    final builder = buildContent;
    if (builder == null) return defaultSkillContent(skill.name, skill.baseDirectory, skill.content);
    try {
      return await builder(ctx, skill, rawArguments);
    } on Object catch (error) {
      throw ThreepioException('failed to build skill result: ${goValueString(error)}', cause: error);
    }
  }

  Future<String> _runAgentMode(
    RunContext ctx,
    Skill skill, {
    required bool forkHistory,
    required String rawArguments,
  }) async {
    final hub = agentHub;
    if (hub == null) {
      throw ThreepioException(
        "skill '${skill.name}' requires context:${skill.context.value} but AgentHub is not configured",
      );
    }
    BaseChatModel? model;
    if (skill.model.isNotEmpty) {
      final models = modelHub;
      if (models == null) {
        throw ThreepioException(
          "skill '${skill.name}' requires model '${skill.model}' but ModelHub is not configured",
        );
      }
      try {
        model = await models.get(ctx, skill.model);
      } on Object catch (error) {
        throw ThreepioException(
          "failed to get model '${skill.model}' from ModelHub: ${goValueString(error)}",
          cause: error,
        );
      }
    }
    final Agent agent;
    try {
      agent = await hub.get(ctx, skill.agent, AgentHubOptions(model: model));
    } on Object catch (error) {
      throw ThreepioException(
        "failed to get agent '${skill.agent}' from AgentHub: ${goValueString(error)}",
        cause: error,
      );
    }
    final String skillContent;
    try {
      skillContent = await _skillContent(ctx, skill, rawArguments);
    } on Object catch (error) {
      throw ThreepioException('failed to build skill result: ${goValueString(error)}', cause: error);
    }

    var history = const <Message>[];
    var toolCallId = '';
    if (forkHistory) {
      try {
        history = await messagesFromState(ctx);
      } on Object catch (error) {
        throw ThreepioException(
          'failed to get messages from state: ${goValueString(error)}',
          cause: error,
        );
      }
      toolCallId = toolCallIdOf(ctx) ?? '';
    }

    final List<Message> messages;
    final forkBuilder = buildForkMessages;
    if (forkBuilder != null) {
      try {
        messages = await forkBuilder(
          ctx,
          SkillSubAgentInput(
            skill: skill,
            mode: skill.context,
            rawArguments: rawArguments,
            skillContent: skillContent,
            history: history,
            toolCallId: toolCallId,
          ),
        );
      } on Object catch (error) {
        throw ThreepioException(
          'failed to build fork messages: ${goValueString(error)}',
          cause: error,
        );
      }
    } else if (forkHistory) {
      messages = [...history, Message.tool(content: skillContent, toolCallId: toolCallId)];
    } else {
      messages = [Message.user(skillContent)];
    }

    final events = agent.run(ctx, AgentInput(messages: messages));
    final messageList = <Message>[];
    final results = <String>[];
    try {
      for (var event = await events.nextOrNull(); event != null; event = await events.nextOrNull()) {
        final error = event.error;
        if (error != null) {
          throw ThreepioException('failed to run agent event: ${goValueString(error)}', cause: error);
        }
        final variant = event.output?.messageOutput;
        if (variant == null) continue;
        final Message message;
        try {
          message = await variant.getMessage();
        } on Object catch (error) {
          throw ThreepioException(
            'failed to get message from event: ${goValueString(error)}',
            cause: error,
          );
        }
        messageList.add(message);
        if (message.content.isNotEmpty) results.add(message.content);
      }
    } finally {
      await events.close();
    }

    final formatter = formatForkResult;
    if (formatter != null) {
      try {
        return await formatter(
          ctx,
          SkillSubAgentOutput(
            skill: skill,
            mode: skill.context,
            rawArguments: rawArguments,
            messages: messageList,
            results: results,
          ),
        );
      } on Object catch (error) {
        throw ThreepioException(
          'failed to format fork result: ${goValueString(error)}',
          cause: error,
        );
      }
    }
    return skillSubAgentResult(skill.name, results.join('\n'));
  }
}

/// The conversation of the `ChatModelAgent` run [ctx] belongs to. Port of
/// `getMessagesFromState`.
@visibleForTesting
Future<List<Message>> messagesFromState(RunContext ctx) async {
  var messages = const <Message>[];
  try {
    await processState<ReactState>(ctx, (_, state) => messages = List.of(state.messages));
  } on Object catch (error) {
    throw ThreepioException('failed to process state: ${goValueString(error)}', cause: error);
  }
  return messages;
}

/// The list of skills in the tool description. Port of
/// `renderToolDescription` (eino renders a Go template; the output is the
/// same).
@visibleForTesting
String renderSkillToolDescription(List<SkillFrontMatter> skills) {
  final out = StringBuffer('\n<available_skills>');
  for (final skill in skills) {
    out.write(
      '\n<skill>\n<name>\n${skill.name}\n</name>\n<description>\n${skill.description}\n</description>\n</skill>',
    );
  }
  out.write('\n</available_skills>\n');
  return out.toString();
}
