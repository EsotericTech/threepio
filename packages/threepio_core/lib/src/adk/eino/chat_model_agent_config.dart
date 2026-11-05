/// The configuration of a `ChatModelAgent`.
///
/// Port of eino `adk.ChatModelAgentConfig`, `adk.ToolsConfig` and
/// `adk.GenModelInput` (`adk/chatmodel.go`).
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../components/model/base_chat_model.dart';
import '../../components/prompt/chat_template.dart';
import '../../compose/tools_node.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../schema/message_template.dart';
import 'agent.dart';
import 'agent_context.dart';
import 'middleware.dart';
import 'model_failover.dart';
import 'model_retry.dart';

/// Turns the instruction and the input of a run into the messages the model
/// starts with. Port of eino `adk.GenModelInput`.
typedef GenModelInput = FutureOr<List<Message>> Function(
  RunContext ctx,
  String instruction,
  AgentInput input,
);

/// The default [GenModelInput]: a system message with the instruction (when
/// there is one), then the input messages.
///
/// Port of eino `defaultGenModelInput`. When the run has session values, the
/// instruction is an f-string template filled from them (`{user}` becomes
/// the session value `user`); an instruction with literal braces then needs
/// `{{`/`}}` or a [GenModelInput] of its own.
Future<List<Message>> defaultGenModelInput(
  RunContext ctx,
  String instruction,
  AgentInput input,
) async {
  final messages = <Message>[];
  if (instruction.isNotEmpty) {
    var system = Message.system(instruction);
    final values = ctx.sessionValues;
    if (values.isNotEmpty) {
      try {
        final formatted = await ChatTemplate.fromMessages(
          FormatType.fString,
          [system],
        ).format(values, options: ChatTemplateOptions(runContext: ctx));
        system = formatted.first;
        // The formatter's failure, whatever it is.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        Error.throwWithStackTrace(
          ThreepioException(
            'defaultGenModelInput: failed to format instruction using FString '
            'template. This formatting is triggered automatically when '
            'SessionValues are present. If your instruction contains literal '
            'curly braces (e.g., JSON), provide a custom GenModelInput that '
            'uses another format. If you are using SessionValues for purposes '
            'other than instruction formatting, provide a custom GenModelInput '
            'that does no formatting at all: $error',
            cause: error,
          ),
          stackTrace,
        );
      }
    }
    messages.add(system);
  }
  messages.addAll(input.messages);
  return messages;
}

/// The tools of a `ChatModelAgent`. Port of eino `adk.ToolsConfig`.
@immutable
final class ToolsConfig {
  /// The tools configuration.
  const ToolsConfig({
    this.toolsNode = const ToolsNodeConfig(tools: []),
    this.returnDirectly = const {},
    this.emitInternalEvents = false,
  });

  /// The tools and how the tools node runs them (sequentially or not, tool
  /// middlewares, unknown tools, aliases).
  final ToolsNodeConfig toolsNode;

  /// The names of the tools whose result ends the run: the result is the
  /// agent's answer and the model is not called again.
  final Set<String> returnDirectly;

  /// Whether the events of the agents behind `AgentTool`s are passed on to
  /// this agent's caller as they happen. They are not part of this agent's
  /// state; interrupts of those agents propagate either way.
  final bool emitInternalEvents;
}

/// The configuration of a `ChatModelAgent`.
///
/// Port of eino `adk.ChatModelAgentConfig`. Not ported: `Exit` and
/// `OutputKey` (agent transfer, not recommended by eino; write a session
/// value in a middleware's `afterAgent` instead of `OutputKey`) and the
/// deprecated `Middlewares` (use [handlers]).
@immutable
final class ChatModelAgentConfig {
  /// The configuration of an agent with [model].
  const ChatModelAgentConfig({
    required this.model,
    this.name = '',
    this.description = '',
    this.instruction = '',
    this.toolsConfig = const ToolsConfig(),
    this.genModelInput,
    this.maxIterations = 20,
    this.handlers = const [],
    this.modelRetryConfig,
    this.modelFailoverConfig,
  });

  /// The name of the agent. An `AgentTool` made from the agent needs one.
  final String name;

  /// What the agent does. An `AgentTool` made from the agent needs one.
  final String description;

  /// The system instruction. With session values, `{key}` placeholders are
  /// filled by the default [genModelInput].
  final String instruction;

  /// The model. With tools it is told about them through
  /// `ChatModelOptions.tools`, and a `ToolCallingChatModel` also gets them
  /// with `withTools`.
  final BaseChatModel model;

  /// The tools.
  final ToolsConfig toolsConfig;

  /// How the model input is built; [defaultGenModelInput] when `null`.
  final GenModelInput? genModelInput;

  /// How many model calls a run may make before it fails with
  /// `ExceedMaxIterationsException`; 20 when 0 or less.
  final int maxIterations;

  /// The middlewares, in order (the first one's wrappers are the outermost).
  final List<ChatModelAgentMiddleware> handlers;

  /// Retries of failed model calls.
  final ModelRetryConfig? modelRetryConfig;

  /// Other models to try when a call fails.
  final ModelFailoverConfig? modelFailoverConfig;
}
