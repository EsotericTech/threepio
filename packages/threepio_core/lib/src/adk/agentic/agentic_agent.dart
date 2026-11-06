/// The agent contract of the agentic path: inputs, events and agents that
/// speak [AgenticMessage].
///
/// Port of the `*schema.AgenticMessage` half of eino `adk/interface.go`
/// (`TypedAgentInput`, `TypedAgentEvent`, `TypedAgentOutput`,
/// `TypedMessageVariant`, `TypedAgent`, `TypedResumableAgent`,
/// `EventFromAgenticMessage`), of `TypedGetMessage` and
/// `copyTypedAgentEvent` (`adk/utils.go`) and of `TypedInterrupt`,
/// `TypedStatefulInterrupt` and `TypedCompositeInterrupt`
/// (`adk/interrupt.go`). **Beta**, as the whole agentic path is upstream.
library;

import 'package:meta/meta.dart';

import '../../compose/interrupt.dart' show encodeOrDescribe;
import '../../core/interrupt_signal.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/agentic_message.dart';
import '../../schema/type_registry.dart';
import '../../streaming/stream_reader.dart';
import '../eino/agent_action.dart';
import '../eino/agent_event.dart' show AgentEvent;
import '../eino/interrupt.dart';
import '../eino/run_options.dart';
import 'agent_message_codec.dart';

/// What an agentic agent is asked to do: the conversation so far and
/// whether its answer should stream.
///
/// Port of eino `adk.TypedAgentInput[*schema.AgenticMessage]`.
@immutable
final class AgenticAgentInput {
  /// An input with [messages].
  AgenticAgentInput({
    List<AgenticMessage> messages = const [],
    this.enableStreaming = false,
  }) : messages = List.unmodifiable(messages);

  /// An input from its JSON form; see [toJson].
  factory AgenticAgentInput.fromJson(Map<String, Object?> json) =>
      AgenticAgentInput(
        messages: [
          for (final message in (json['messages'] as List<Object?>?) ?? const [])
            agenticMessageCodec.decode((message! as Map).cast<String, Object?>()),
        ],
        enableStreaming: json['enable_streaming'] == true,
      );

  /// The conversation the agent continues.
  final List<AgenticMessage> messages;

  /// Whether the agent should stream its model output
  /// ([AgenticMessageVariant.stream]) instead of sending complete messages.
  final bool enableStreaming;

  /// The JSON form of the input, as a checkpoint keeps it.
  Map<String, Object?> toJson() => {
        'messages': [
          for (final message in messages) agenticMessageCodec.encode(message),
        ],
        'enable_streaming': enableStreaming,
      };

  @override
  String toString() => 'AgenticAgentInput(${messages.length} messages, '
      'streaming: $enableStreaming)';
}

/// An agentic message an agent produced: complete
/// ([AgenticMessageVariant.message]) or as the stream of its chunks
/// ([AgenticMessageVariant.stream]).
///
/// Port of eino `adk.TypedMessageVariant[*schema.AgenticMessage]`. Go's
/// `Role` and `ToolName` are always empty for agentic messages (tool results
/// travel as blocks inside the message) and are not ported; [agenticRole]
/// is Go's `AgenticRole` (`null` stands for Go's empty role). A stream has
/// one reader: read it with [messageStream] or join it with [getMessage],
/// not both. After [getMessage] the joined message is kept, and
/// [messageStream] gives it as a one-chunk stream.
sealed class AgenticMessageVariant {
  AgenticMessageVariant._({this.agenticRole});

  /// A complete message.
  factory AgenticMessageVariant.message(
    AgenticMessage message, {
    AgenticRoleType? agenticRole,
  }) = _CompleteAgenticMessage;

  /// A message that arrives in chunks.
  factory AgenticMessageVariant.stream(
    StreamReader<AgenticMessage> stream, {
    AgenticRoleType? agenticRole,
  }) =>
      _StreamingAgenticMessage(
        JoinOnceStream(stream, agenticMessageCodec),
        agenticRole: agenticRole,
      );

  /// A variant from its JSON form; see [toJson]. A stream comes back as a
  /// stream of its joined message, as in eino.
  factory AgenticMessageVariant.fromJson(Map<String, Object?> json) {
    final role = _roleOf(json['agentic_role']);
    final message = agenticMessageCodec.decode(
      (json['message']! as Map).cast<String, Object?>(),
    );
    if (json['is_streaming'] == true) {
      return _StreamingAgenticMessage(
        JoinOnceStream.joined(message, agenticMessageCodec),
        agenticRole: role,
      );
    }
    return _CompleteAgenticMessage(message, agenticRole: role);
  }

  /// Who the message is from: [AgenticRoleType.assistant] for model output,
  /// [AgenticRoleType.user] for tool results. Known before a stream is read.
  final AgenticRoleType? agenticRole;

  /// Whether the message arrives in chunks.
  bool get isStreaming;

  /// The complete message, or `null` for a stream.
  AgenticMessage? get message;

  /// The stream of chunks, or `null` for a complete message.
  StreamReader<AgenticMessage>? get messageStream;

  /// The message, joined from its chunks for a stream.
  ///
  /// Port of eino `TypedMessageVariant.GetMessage`. Reads the stream to its
  /// end the first time; the result is kept. An error in the stream is
  /// rethrown, also by later calls.
  Future<AgenticMessage> getMessage();

  /// The JSON form, as a checkpoint keeps it (port of eino
  /// `gobEncodeAgenticMessageVariant`). A stream is written as its joined
  /// message, so it must have been read with [getMessage] first (or have
  /// been read to its end by the agent that produced it); otherwise this
  /// throws [StateError].
  Map<String, Object?> toJson();

  /// A second variant over the same message, for a second reader. For a
  /// stream, this variant and the copy each get their own copy of the
  /// chunks. Port of the message half of eino `copyTypedAgentEvent`.
  @internal
  AgenticMessageVariant copyForSecondReader();

  Map<String, Object?> _json(AgenticMessage message, bool isStreaming) => {
        'is_streaming': isStreaming,
        'message': agenticMessageCodec.encode(message),
        if (agenticRole != null) 'agentic_role': agenticRole!.value,
      };

  static AgenticRoleType? _roleOf(Object? json) {
    if (json is! String) return null;
    for (final role in AgenticRoleType.values) {
      if (role.value == json) return role;
    }
    return null;
  }
}

final class _CompleteAgenticMessage extends AgenticMessageVariant {
  _CompleteAgenticMessage(this._message, {super.agenticRole}) : super._();

  final AgenticMessage _message;

  @override
  bool get isStreaming => false;

  @override
  AgenticMessage get message => _message;

  @override
  StreamReader<AgenticMessage>? get messageStream => null;

  @override
  Future<AgenticMessage> getMessage() async => _message;

  @override
  Map<String, Object?> toJson() => _json(_message, false);

  @override
  AgenticMessageVariant copyForSecondReader() => this;

  @override
  String toString() => 'AgenticMessageVariant.message(role: '
      '${agenticRole?.value}, ${_message.contentBlocks.length} blocks)';
}

final class _StreamingAgenticMessage extends AgenticMessageVariant {
  _StreamingAgenticMessage(this._core, {super.agenticRole}) : super._();

  final JoinOnceStream<AgenticMessage> _core;

  @override
  bool get isStreaming => true;

  @override
  AgenticMessage? get message => null;

  @override
  StreamReader<AgenticMessage> get messageStream => _core.stream;

  @override
  Future<AgenticMessage> getMessage() => _core.join();

  @override
  Map<String, Object?> toJson() {
    final joined = _core.joinedOrRecorded;
    if (joined == null) {
      throw StateError(
        'a streamed message can only be written to JSON after its stream '
        'has been read (AgenticMessageVariant.getMessage)',
      );
    }
    return _json(joined, true);
  }

  @override
  AgenticMessageVariant copyForSecondReader() => _StreamingAgenticMessage(
        _core.copyForSecondReader(),
        agenticRole: agenticRole,
      );

  @override
  String toString() =>
      'AgenticMessageVariant.stream(role: ${agenticRole?.value})';
}

/// A stream variant whose chunks [recorder] sees while another reader reads
/// them; it can be written to JSON once that reader is done.
@internal
AgenticMessageVariant recordedAgenticStreamVariant(
  StreamReader<AgenticMessage> stream,
  TypedStreamRecorder<AgenticMessage> recorder, {
  AgenticRoleType? agenticRole,
}) =>
    _StreamingAgenticMessage(
      JoinOnceStream(stream, agenticMessageCodec, recorder: recorder),
      agenticRole: agenticRole,
    );

/// The output of an agentic agent event: a message and anything else the
/// agent reports.
///
/// Port of eino `adk.TypedAgentOutput[*schema.AgenticMessage]`.
@immutable
final class AgenticAgentOutput {
  /// An output with a message, a custom payload, or both.
  const AgenticAgentOutput({this.messageOutput, this.customizedOutput});

  /// An output from its JSON form; see [toJson].
  factory AgenticAgentOutput.fromJson(Map<String, Object?> json) =>
      AgenticAgentOutput(
        messageOutput: switch (json['message_output']) {
          final Map<String, Object?> variant =>
            AgenticMessageVariant.fromJson(variant),
          _ => null,
        },
        customizedOutput: TypeRegistry.decode(json['customized_output']),
      );

  /// A message the agent produced.
  final AgenticMessageVariant? messageOutput;

  /// Any other output. Port of the field `CustomizedOutput`.
  final Object? customizedOutput;

  /// The JSON form; see [AgenticMessageVariant.toJson] for streamed
  /// messages.
  Map<String, Object?> toJson() => {
        if (messageOutput != null) 'message_output': messageOutput!.toJson(),
        if (customizedOutput != null)
          'customized_output': encodeOrDescribe(
            customizedOutput,
            'AgenticAgentOutput.customizedOutput',
          ),
      };
}

/// One event of an agentic agent run: an output, an action, or an error.
///
/// Port of eino `adk.TypedAgentEvent[*schema.AgenticMessage]` (registered
/// for checkpoints as `_eino_adk_agentic_event`). Eino's `RunPath` is not
/// ported (agent transfer, which eino does not recommend); the actions are
/// the classic [AgentAction]s.
@immutable
final class AgenticAgentEvent {
  /// An event of the agent [agentName].
  const AgenticAgentEvent({
    this.agentName = '',
    this.output,
    this.action,
    this.error,
    this.stackTrace,
  });

  /// An event that carries a message, complete or as a [stream].
  ///
  /// Port of eino `adk.EventFromAgenticMessage`. With [stream] the event
  /// carries the stream and [message] is ignored. [agenticRole] is known
  /// before the stream is read.
  factory AgenticAgentEvent.fromMessage(
    AgenticMessage? message, {
    StreamReader<AgenticMessage>? stream,
    AgenticRoleType? agenticRole,
  }) =>
      AgenticAgentEvent(
        output: AgenticAgentOutput(
          messageOutput: stream != null
              ? AgenticMessageVariant.stream(stream, agenticRole: agenticRole)
              : AgenticMessageVariant.message(
                  message ??
                      AgenticMessage(
                        role: agenticRole ?? AgenticRoleType.assistant,
                      ),
                  agenticRole: agenticRole,
                ),
        ),
      );

  /// An event that reports [error]. Port of eino's error iterators
  /// (`genAgenticErrorIter`).
  factory AgenticAgentEvent.failure(Object error, [StackTrace? stackTrace]) =>
      AgenticAgentEvent(error: error, stackTrace: stackTrace);

  /// An event from its JSON form; see [toJson]. An error comes back as a
  /// [ThreepioException] with the text it had.
  factory AgenticAgentEvent.fromJson(Map<String, Object?> json) =>
      AgenticAgentEvent(
        agentName: json['agent_name'] as String? ?? '',
        output: switch (json['output']) {
          final Map<String, Object?> output => AgenticAgentOutput.fromJson(output),
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

  /// The agent that emitted the event. The `AgenticRunner` fills it in when
  /// the agent leaves it empty.
  final String agentName;

  /// What the agent produced.
  final AgenticAgentOutput? output;

  /// What the agent asks for (an interrupt, a custom action).
  final AgentAction? action;

  /// The failure the event reports. Port of the field `Err`.
  final Object? error;

  /// Where [error] was thrown, when known.
  final StackTrace? stackTrace;

  /// The message of the event, if it carries one.
  AgenticMessageVariant? get messageOutput => output?.messageOutput;

  /// A copy with the given fields replaced.
  AgenticAgentEvent copyWith({
    String? agentName,
    AgenticAgentOutput? output,
    AgentAction? action,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      AgenticAgentEvent(
        agentName: agentName ?? this.agentName,
        output: output ?? this.output,
        action: action ?? this.action,
        error: error ?? this.error,
        stackTrace: stackTrace ?? this.stackTrace,
      );

  /// The JSON form of the event. A streamed message must have been read
  /// first (see [AgenticMessageVariant.toJson]); an error is written as its
  /// text.
  Map<String, Object?> toJson() => {
        if (agentName.isNotEmpty) 'agent_name': agentName,
        if (output != null) 'output': output!.toJson(),
        if (action != null) 'action': action!.toJson(),
        if (error != null) 'error': error.toString(),
      };

  @override
  String toString() => 'AgenticAgentEvent(agent: $agentName, '
      '${output != null ? 'output: ${output!.messageOutput}, ' : ''}'
      '${action != null ? 'action: $action, ' : ''}'
      '${error != null ? 'error: $error' : ''})';
}

/// An agent of the agentic path: takes an [AgenticAgentInput] and answers
/// with a stream of [AgenticAgentEvent]s.
///
/// Port of eino `adk.TypedAgent[*schema.AgenticMessage]`. Errors are events
/// too ([AgenticAgentEvent.error]); the stream itself does not fail. Run an
/// agent through an `AgenticRunner`, which adds callbacks, session values
/// and checkpoints.
abstract interface class AgenticAgent {
  /// The name of the agent.
  String get name;

  /// What the agent does.
  String get description;

  /// Runs the agent. Port of eino `TypedAgent.Run`.
  StreamReader<AgenticAgentEvent> run(
    RunContext ctx,
    AgenticAgentInput input, {
    List<AgentRunOption> options = const [],
  });
}

/// An agentic agent that can go on after it interrupted.
///
/// Port of eino `adk.TypedResumableAgent[*schema.AgenticMessage]`.
abstract interface class ResumableAgenticAgent implements AgenticAgent {
  /// Continues a run that interrupted. Port of eino
  /// `TypedResumableAgent.Resume`.
  StreamReader<AgenticAgentEvent> resume(
    RunContext ctx,
    ResumeInfo info, {
    List<AgentRunOption> options = const [],
  });
}

/// The message [event] carries, joined from its chunks for a stream, or
/// `null` when it carries none.
///
/// Port of eino `adk.TypedGetMessage[*schema.AgenticMessage]`. The event
/// stays readable: its stream is copied, and the copy is joined.
Future<AgenticMessage?> getAgenticMessageFromEvent(
  AgenticAgentEvent event,
) async {
  final variant = event.output?.messageOutput;
  if (variant == null) return null;
  if (!variant.isStreaming) return variant.message;
  return variant.copyForSecondReader().getMessage();
}

/// An event that interrupts the run, with [info] for the caller.
///
/// Port of eino `adk.TypedInterrupt[*schema.AgenticMessage]`; the agentic
/// twin of `interruptEvent`. An agent sends it as its last event; the
/// `AgenticRunner` saves a checkpoint (with `AgentRunOption.checkpointId`),
/// and `AgenticRunner.resume` continues the run at this agent.
AgenticAgentEvent agenticInterruptEvent(RunContext ctx, Object? info) =>
    agenticEventOf(interruptEvent(ctx, info));

/// Like [agenticInterruptEvent], and [state] is saved with the interrupt;
/// the agent gets it back as [ResumeInfo.interruptState]. Port of eino
/// `adk.TypedStatefulInterrupt[*schema.AgenticMessage]`.
AgenticAgentEvent agenticStatefulInterruptEvent(
  RunContext ctx,
  Object? info,
  Object? state,
) =>
    agenticEventOf(statefulInterruptEvent(ctx, info, state));

/// An interrupt of an agentic agent that wraps the interrupts of what it ran
/// ([subSignals]). Port of eino
/// `adk.TypedCompositeInterrupt[*schema.AgenticMessage]`.
AgenticAgentEvent agenticCompositeInterruptEvent(
  RunContext ctx,
  Object? info,
  Object? state,
  List<InterruptSignal> subSignals,
) =>
    agenticEventOf(compositeInterruptEvent(ctx, info, state, subSignals));

/// The agentic event with the action and error of a classic event without
/// output: the interrupt events are built once, by the classic functions
/// (their action and interrupt signal do not depend on the message type).
@internal
AgenticAgentEvent agenticEventOf(AgentEvent event) => AgenticAgentEvent(
      agentName: event.agentName,
      action: event.action,
      error: event.error,
      stackTrace: event.stackTrace,
    );

/// A copy of [event] for a second reader. Port of eino
/// `copyTypedAgentEvent`.
@internal
AgenticAgentEvent copyAgenticAgentEvent(AgenticAgentEvent event) {
  final output = event.output;
  final variant = output?.messageOutput;
  if (output == null || variant == null) return event;
  return AgenticAgentEvent(
    agentName: event.agentName,
    output: AgenticAgentOutput(
      messageOutput: variant.copyForSecondReader(),
      customizedOutput: output.customizedOutput,
    ),
    action: event.action,
    error: event.error,
    stackTrace: event.stackTrace,
  );
}

/// Makes the stream of [event], if it has one, close itself when nobody
/// holds it any more. Port of eino `typedSetAutomaticClose`.
@internal
void setAgenticAutomaticClose(AgenticAgentEvent event) =>
    event.output?.messageOutput?.messageStream?.setAutomaticClose();
