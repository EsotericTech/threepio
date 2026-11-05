/// The events an agent emits.
///
/// Port of eino `adk.AgentEvent` and `adk.AgentOutput` and of the message
/// helpers in `adk/interface.go` and `adk/utils.go`.
library;

import 'package:meta/meta.dart';

import '../../compose/interrupt.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../schema/type_registry.dart';
import '../../streaming/stream_reader.dart';
import 'agent_action.dart';
import 'message_variant.dart';

export 'message_variant.dart' show MessageVariant;

/// The output of an agent event: a message and anything else the agent
/// reports.
///
/// Port of eino `adk.AgentOutput`.
@immutable
final class AgentOutput {
  /// An output with a message, a custom payload, or both.
  const AgentOutput({this.messageOutput, this.customizedOutput});

  /// An output from its JSON form; see [toJson].
  factory AgentOutput.fromJson(Map<String, Object?> json) => AgentOutput(
        messageOutput: switch (json['message_output']) {
          final Map<String, Object?> variant =>
            MessageVariant.fromJson(variant),
          _ => null,
        },
        customizedOutput: TypeRegistry.decode(json['customized_output']),
      );

  /// A message the agent produced.
  final MessageVariant? messageOutput;

  /// Any other output. Port of the field `CustomizedOutput`.
  final Object? customizedOutput;

  /// The JSON form; see [MessageVariant.toJson] for streamed messages.
  Map<String, Object?> toJson() => {
        if (messageOutput != null) 'message_output': messageOutput!.toJson(),
        if (customizedOutput != null)
          'customized_output':
              encodeOrDescribe(customizedOutput, 'AgentOutput.customizedOutput'),
      };
}

/// One event of an agent run: an output, an action, or an error.
///
/// Port of eino `adk.AgentEvent`. Eino's `RunPath` is not ported: it belongs
/// to agent transfer, which eino marks as not recommended.
///
/// This class is the Eino-shaped event of `package:threepio_core/adk.dart`.
/// The umbrella library exports an unrelated, older `AgentEvent` (a sealed
/// hierarchy of the Kortney runtime); import this library with a prefix when
/// both are needed.
@immutable
final class AgentEvent {
  /// An event of the agent [agentName].
  const AgentEvent({
    this.agentName = '',
    this.output,
    this.action,
    this.error,
    this.stackTrace,
  });

  /// An event that carries a message, complete or as a [stream].
  ///
  /// Port of eino `adk.EventFromMessage`. With [stream] the event carries
  /// the stream and [message] is ignored.
  factory AgentEvent.fromMessage(
    Message? message, {
    StreamReader<Message>? stream,
    RoleType? role,
    String toolName = '',
  }) =>
      AgentEvent(
        output: AgentOutput(
          messageOutput: stream != null
              ? MessageVariant.stream(stream, role: role, toolName: toolName)
              : MessageVariant.message(
                  message ?? Message(role: role ?? RoleType.assistant),
                  role: role,
                  toolName: toolName,
                ),
        ),
      );

  /// An event that reports [error].
  factory AgentEvent.failure(Object error, [StackTrace? stackTrace]) =>
      AgentEvent(error: error, stackTrace: stackTrace);

  /// An event from its JSON form; see [toJson]. An error comes back as a
  /// [ThreepioException] with the text it had.
  factory AgentEvent.fromJson(Map<String, Object?> json) => AgentEvent(
        agentName: json['agent_name'] as String? ?? '',
        output: switch (json['output']) {
          final Map<String, Object?> output => AgentOutput.fromJson(output),
          _ => null,
        },
        action: switch (json['action']) {
          final Map<String, Object?> action => AgentAction.fromJson(action),
          _ => null,
        },
        error: switch (json['error']) {
          final String text => ThreepioException(text),
          _ => null,
        },
      );

  /// The agent that emitted the event. The `Runner` fills it in when the
  /// agent leaves it empty.
  final String agentName;

  /// What the agent produced.
  final AgentOutput? output;

  /// What the agent asks for (an interrupt, a custom action).
  final AgentAction? action;

  /// The failure the event reports. Port of the field `Err`.
  final Object? error;

  /// Where [error] was thrown, when known.
  final StackTrace? stackTrace;

  /// The message of the event, if it carries one.
  MessageVariant? get messageOutput => output?.messageOutput;

  /// A copy with the given fields replaced.
  AgentEvent copyWith({
    String? agentName,
    AgentOutput? output,
    AgentAction? action,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      AgentEvent(
        agentName: agentName ?? this.agentName,
        output: output ?? this.output,
        action: action ?? this.action,
        error: error ?? this.error,
        stackTrace: stackTrace ?? this.stackTrace,
      );

  /// The JSON form of the event. A streamed message must have been read
  /// first (see [MessageVariant.toJson]); an error is written as its text.
  Map<String, Object?> toJson() => {
        if (agentName.isNotEmpty) 'agent_name': agentName,
        if (output != null) 'output': output!.toJson(),
        if (action != null) 'action': action!.toJson(),
        if (error != null) 'error': error.toString(),
      };

  @override
  String toString() => 'AgentEvent(agent: $agentName, '
      '${output != null ? 'output: ${output!.messageOutput}, ' : ''}'
      '${action != null ? 'action: $action, ' : ''}'
      '${error != null ? 'error: $error' : ''})';
}

/// The message [event] carries, joined from its chunks for a stream, or
/// `null` when it carries none.
///
/// Port of eino `adk.GetMessage`. The event stays readable: its stream is
/// copied, and the copy is joined.
Future<Message?> getMessageFromEvent(AgentEvent event) async {
  final variant = event.output?.messageOutput;
  if (variant == null) return null;
  if (!variant.isStreaming) return variant.message;
  return variant.copyForSecondReader().getMessage();
}

/// A copy of [event] for a second reader. Port of eino
/// `copyTypedAgentEvent`.
@internal
AgentEvent copyAgentEvent(AgentEvent event) {
  final output = event.output;
  final variant = output?.messageOutput;
  if (output == null || variant == null) return event;
  return AgentEvent(
    agentName: event.agentName,
    output: AgentOutput(
      messageOutput: variant.copyForSecondReader(),
      customizedOutput: output.customizedOutput,
    ),
    action: event.action,
    error: event.error,
    stackTrace: event.stackTrace,
  );
}

/// Makes the stream of [event], if it has one, close itself when nobody
/// holds it any more. Port of eino `setAutomaticClose`.
@internal
void setAutomaticClose(AgentEvent event) =>
    event.output?.messageOutput?.messageStream?.setAutomaticClose();
