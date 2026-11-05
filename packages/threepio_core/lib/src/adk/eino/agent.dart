/// The agent contract of the ADK.
///
/// Port of the classic (`*schema.Message`) half of eino `adk/interface.go`.
library;

import 'package:meta/meta.dart';

import '../../core/run_context.dart';
import '../../schema/message.dart';
import '../../streaming/stream_reader.dart';
import 'agent_event.dart';
import 'interrupt.dart';
import 'run_options.dart';

/// What an agent is asked to do: the conversation so far and whether its
/// answer should stream.
///
/// Port of eino `adk.AgentInput`.
@immutable
final class AgentInput {
  /// An input with [messages].
  AgentInput({
    List<Message> messages = const [],
    this.enableStreaming = false,
  }) : messages = List.unmodifiable(messages);

  /// An input from its JSON form; see [toJson].
  factory AgentInput.fromJson(Map<String, Object?> json) => AgentInput(
        messages: [
          for (final message in (json['messages'] as List<Object?>?) ?? const [])
            Message.fromJson((message! as Map).cast<String, dynamic>()),
        ],
        enableStreaming: json['enable_streaming'] == true,
      );

  /// The conversation the agent continues.
  final List<Message> messages;

  /// Whether the agent should stream its model output
  /// ([MessageVariant.stream]) instead of sending complete messages.
  final bool enableStreaming;

  /// The JSON form of the input, as a checkpoint keeps it.
  Map<String, Object?> toJson() => {
        'messages': [for (final message in messages) message.toJson()],
        'enable_streaming': enableStreaming,
      };

  @override
  String toString() =>
      'AgentInput(${messages.length} messages, streaming: $enableStreaming)';
}

/// An agent: takes an [AgentInput] and answers with a stream of
/// [AgentEvent]s.
///
/// Port of eino `adk.Agent` (`TypedAgent[*schema.Message]`). Errors are
/// events too ([AgentEvent.error]); the stream itself does not fail. Run an
/// agent through a `Runner`, which adds callbacks, session values and
/// checkpoints.
abstract interface class Agent {
  /// The name of the agent. A tool made from the agent with `AgentTool` is
  /// called by it.
  String get name;

  /// What the agent does, for the model that decides to call it.
  String get description;

  /// Runs the agent. Port of eino `Agent.Run`.
  StreamReader<AgentEvent> run(
    RunContext ctx,
    AgentInput input, {
    List<AgentRunOption> options = const [],
  });
}

/// An agent that can go on after it interrupted.
///
/// Port of eino `adk.ResumableAgent`.
abstract interface class ResumableAgent implements Agent {
  /// Continues a run that interrupted. [info] says whether this agent was
  /// interrupted itself, what it saved and what the caller sent it. Port of
  /// eino `ResumableAgent.Resume`.
  StreamReader<AgentEvent> resume(
    RunContext ctx,
    ResumeInfo info, {
    List<AgentRunOption> options = const [],
  });
}
