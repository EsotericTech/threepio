/// The planner of the plan-execute agent.
///
/// Port of `PlannerConfig`, `NewPlanner`, `planner` and `argToContent` of
/// eino `adk/prebuilt/planexecute/plan_execute.go`.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../../components/model/base_chat_model.dart';
import '../../../components/model/chat_model_options.dart';
import '../../../components/prompt/chat_template.dart';
import '../../../compose/call_options.dart';
import '../../../compose/chain.dart';
import '../../../compose/graph_options.dart';
import '../../../compose/lambda.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/message_concat.dart';
import '../../../schema/tool_info.dart';
import '../../../streaming/stream_reader.dart';
import '../../eino/agent.dart';
import '../../eino/agent_context.dart';
import '../../eino/agent_event.dart';
import '../../eino/run_options.dart';
import '../../middlewares/internal/go_compat.dart';
import 'plan.dart';
import 'plan_execute.dart';

/// Builds the planner's model input from the user's messages. Port of eino
/// `planexecute.GenPlannerModelInputFn`.
typedef PlannerModelInput = FutureOr<List<Message>> Function(
  RunContext ctx,
  List<Message> userInput,
);

/// The configuration of the planner.
///
/// Port of eino `planexecute.PlannerConfig`. Give either
/// [chatModelWithFormattedOutput], a model that answers with the plan's JSON
/// as its content, or [toolCallingChatModel], which is given [toolInfo] and
/// writes the plan as that tool's arguments (it is asked to call a tool).
final class PlannerConfig {
  /// The configuration of a planner.
  const PlannerConfig({
    this.chatModelWithFormattedOutput,
    this.toolCallingChatModel,
    this.toolInfo,
    this.genInput,
    this.planDecoder,
  });

  /// A model that answers with the plan's JSON; used when set.
  final BaseChatModel? chatModelWithFormattedOutput;

  /// A model that writes the plan as the arguments of [toolInfo].
  final ToolCallingChatModel? toolCallingChatModel;

  /// The plan tool; [PlanExecute.planToolInfo] when `null`.
  final ToolInfo? toolInfo;

  /// Builds the model input from the user's messages; the default formats
  /// [PlanExecute.plannerPrompt] with them.
  final PlannerModelInput? genInput;

  /// Builds the plan from the JSON; the default is `{"steps": [...]}`.
  final PlanDecoder? planDecoder;
}

/// The default planner input: [PlanExecute.plannerPrompt] with the user's
/// messages as `input`. Port of `defaultGenPlannerInputFn`.
@visibleForTesting
Future<List<Message>> defaultGenPlannerInput(
  RunContext ctx,
  List<Message> userInput,
) =>
    PlanExecute.plannerPrompt.format(
      {'input': userInput},
      options: ChatTemplateOptions(runContext: ctx),
    );

/// The planner agent of [config]. Port of `planexecute.NewPlanner`.
@internal
PlannerAgent newPlannerAgent(PlannerConfig config) {
  ensurePlanExecuteTypesRegistered();
  final BaseChatModel chatModel;
  var toolCall = false;
  final formatted = config.chatModelWithFormattedOutput;
  if (formatted != null) {
    chatModel = formatted;
  } else {
    final toolCalling = config.toolCallingChatModel;
    if (toolCalling == null) {
      throw ArgumentError(
        'PlannerConfig needs chatModelWithFormattedOutput or '
        'toolCallingChatModel',
      );
    }
    toolCall = true;
    chatModel = toolCalling.withTools([config.toolInfo ?? PlanExecute.planToolInfo]);
  }
  return PlannerAgent(
    toolCall: toolCall,
    chatModel: chatModel,
    genInput: config.genInput ?? defaultGenPlannerInput,
    planDecoder: config.planDecoder ?? DefaultPlan.decode,
  );
}

/// The planner. Port of eino's unexported `planner`.
@internal
final class PlannerAgent implements Agent {
  /// A planner that asks [chatModel] for the plan.
  PlannerAgent({
    required this.toolCall,
    required this.chatModel,
    required this.genInput,
    required this.planDecoder,
  });

  /// Whether the plan comes as tool arguments rather than as content.
  final bool toolCall;

  /// The model, with the plan tool bound when [toolCall].
  final BaseChatModel chatModel;

  /// Builds the model input.
  final PlannerModelInput genInput;

  /// Builds the plan.
  final PlanDecoder planDecoder;

  @override
  String get name => 'planner';

  @override
  String get description => 'a planner agent';

  @override
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  }) {
    final (reader, writer) = pipe<AgentEvent>();
    ctx.addSessionValue(PlanExecute.userInputSessionKey, input.messages);
    unawaited(_run(ctx, input, writer));
    return reader;
  }

  Future<void> _run(
    RunContext ctx,
    AgentInput input,
    StreamWriter<AgentEvent> writer,
  ) async {
    try {
      final chain = Chain<AgentInput, Plan>()
        ..appendLambda(
          Lambda.invokable(
            (RunContext ctx, AgentInput input) => genInput(ctx, input.messages),
          ),
        )
        ..appendChatModel(chatModel)
        ..appendLambda(
          Lambda.collectable((RunContext ctx, StreamReader<Message> stream) async {
            if (input.enableStreaming) {
              final copies = stream.copy(2);
              final output = toolCall ? copies[0].convert(argToContent) : copies[0];
              writer.send(
                AgentEvent.fromMessage(
                  null,
                  stream: output,
                  role: RoleType.assistant,
                ),
              );
              return concatMessageStream(copies[1]);
            }
            final message = await concatMessageStream(stream);
            final Message output;
            if (toolCall) {
              final calls = message.toolCalls ?? const [];
              if (calls.isEmpty) throw const ThreepioException('no tool call');
              output = Message.assistant(calls.first.function.arguments);
            } else {
              output = message;
            }
            writer.send(AgentEvent.fromMessage(output, role: RoleType.assistant));
            return message;
          }),
        )
        ..appendLambda(
          Lambda.invokable((RunContext ctx, Message message) async {
            final String planJson;
            if (toolCall) {
              final calls = message.toolCalls ?? const [];
              if (calls.isEmpty) throw const ThreepioException('no tool call');
              planJson = calls.first.function.arguments;
            } else {
              planJson = message.content;
            }
            final plan = await decodePlan(ctx, planDecoder, planJson);
            ctx.addSessionValue(PlanExecute.planSessionKey, plan);
            return plan;
          }),
        );
      final runnable = await chain.compile(
        ctx,
        options: GraphCompileOptions(graphName: name),
      );
      final output = await runnable.stream(
        ctx,
        input,
        options: [
          if (toolCall)
            CallOption.chatModel(
              const ChatModelOptions(toolChoice: ToolChoice.forced),
            ),
        ],
      );
      await drainStream(output);
      // The chain's failure is the agent's error event.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      writer.send(AgentEvent(error: error, stackTrace: stackTrace));
    } finally {
      await writer.close();
    }
  }

  @override
  String toString() => 'PlannerAgent(toolCall: $toolCall)';
}

/// The plan [decoder] builds from [json]; its failure as eino words it. Port
/// of `plan.UnmarshalJSON` and `fmt.Errorf("unmarshal plan error: %w", err)`.
@internal
Future<Plan> decodePlan(RunContext ctx, PlanDecoder decoder, String json) async {
  try {
    return await decoder(ctx, json);
    // Whatever the decoder throws.
    // ignore: avoid_catches_without_on_clauses
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ThreepioException(
        'unmarshal plan error: ${goValueString(error)}',
        cause: error,
      ),
      stackTrace,
    );
  }
}

/// The arguments of the first tool call of [message], as the content of an
/// assistant message; a chunk without tool calls is dropped. Port of eino
/// `argToContent`.
@internal
Message argToContent(Message message) {
  final calls = message.toolCalls ?? const [];
  if (calls.isEmpty) throw const NoValueException();
  return Message.assistant(calls.first.function.arguments);
}

/// Reads [stream] to its end and closes it: the chain's output is not used,
/// but its side effects (events, session values) must have happened, and an
/// error inside it must surface.
@internal
Future<void> drainStream<T>(StreamReader<T> stream) async {
  try {
    for (;;) {
      await stream.recv();
    }
  } on StreamEOFException {
    return;
  } finally {
    await stream.close();
  }
}
