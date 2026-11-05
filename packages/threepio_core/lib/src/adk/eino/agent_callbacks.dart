/// What agents report to callback handlers.
///
/// Port of eino `adk/callback.go`.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../callbacks/callback_context.dart';
import '../../callbacks/handler_helper.dart';
import '../../callbacks/run_info.dart';
import '../../components/component_type.dart';
import '../../core/run_context.dart';
import '../../streaming/stream_reader.dart';
import 'agent.dart';
import 'agent_event.dart';
import 'interrupt.dart';
import 'run_options.dart';

/// What an agent reports when it starts: its input for a new run, or what it
/// resumes with.
///
/// Port of eino `adk.AgentCallbackInput`. Handlers get it as the input of
/// `onStart` for components of kind `ComponentType.agent`.
@immutable
final class AgentCallbackInput {
  /// The report of an agent starting.
  const AgentCallbackInput({this.input, this.resumeInfo});

  /// [raw] if it is an agent's start report, else `null`. Port of eino
  /// `adk.ConvAgentCallbackInput`.
  static AgentCallbackInput? from(Object? raw) =>
      raw is AgentCallbackInput ? raw : null;

  /// The input of a new run; `null` when the agent resumes.
  final AgentInput? input;

  /// What the agent resumes with; `null` for a new run.
  final ResumeInfo? resumeInfo;
}

/// What an agent reports when it ends: the stream of its events.
///
/// Port of eino `adk.AgentCallbackOutput`. Every handler gets a stream of its
/// own; the agent does not wait for it. Read it without blocking the hook:
/// start reading in `onEnd` and return (the hooks of the other handlers run
/// after this one returns).
@immutable
final class AgentCallbackOutput {
  /// The report of an agent with [events].
  const AgentCallbackOutput(this.events);

  /// [raw] if it is an agent's end report, else `null`. Port of eino
  /// `adk.ConvAgentCallbackOutput`.
  static AgentCallbackOutput? from(Object? raw) =>
      raw is AgentCallbackOutput ? raw : null;

  /// The events of the agent, as they happen.
  final StreamReader<AgentEvent> events;
}

/// An [AgentCallbackHandler] whose functions get the typed reports of an
/// agent: [AgentCallbackInput] on start and [AgentCallbackOutput] on end.
///
/// Port of eino `utils/callbacks.AgentCallbackHandler`. Payloads of another
/// type reach the functions as `null`. ([AgentCallbackHandler] itself passes
/// the payload on as it is, which earlier releases relied on.)
AgentCallbackHandler typedAgentCallbackHandler({
  TypedCallbackHook<AgentCallbackInput?>? onStart,
  TypedCallbackHook<AgentCallbackOutput?>? onEnd,
}) =>
    AgentCallbackHandler(
      onStart: onStart == null
          ? null
          : (ctx, info, raw) => onStart(ctx, info, AgentCallbackInput.from(raw)),
      onEnd: onEnd == null
          ? null
          : (ctx, info, raw) => onEnd(ctx, info, AgentCallbackOutput.from(raw)),
    );

/// [ctx] with the run info of the agent [agentName] and the callback
/// handlers of [options]. Port of eino `initAgentCallbacks`.
@internal
RunContext initAgentCallbacks(
  RunContext ctx,
  String agentName,
  String agentType,
  List<AgentRunOption> options,
) {
  final info = RunInfo(
    name: agentName,
    type: agentType,
    componentType: ComponentType.agent,
  );
  final handlers = CommonAgentOptions.of(options).handlers;
  if (handlers.isEmpty) return reuseHandlers(ctx, info);
  return appendHandlers(ctx, info, handlers);
}

/// The type of [agent] for its run info. Port of eino `getAgentType`.
@internal
String agentTypeOf(Agent agent) => componentTypeNameOf(agent) ?? '';

/// [count] reports with a stream of the events of [output] each. Port of eino
/// `copyAgentCallbackOutput`.
@internal
List<AgentCallbackOutput> copyAgentCallbackOutput(
  AgentCallbackOutput output,
  int count,
) =>
    [
      for (final events in copyEventStream(output.events, count))
        AgentCallbackOutput(events),
    ];

/// [count] readers of the events of [source], each with its own copy of
/// every streamed message. Port of eino `copyTypedEventIterator`.
@internal
List<StreamReader<AgentEvent>> copyEventStream(
  StreamReader<AgentEvent> source,
  int count,
) {
  if (count <= 0) return const [];
  if (count == 1) return [source];
  final pipes = [for (var i = 0; i < count; i++) pipe<AgentEvent>()];
  unawaited(() async {
    try {
      for (var event = await source.nextOrNull();
          event != null;
          event = await source.nextOrNull()) {
        for (var i = 0; i < count - 1; i++) {
          pipes[i].$2.send(copyAgentEvent(event));
        }
        pipes[count - 1].$2.send(event);
      }
      // A failure to read or copy reaches every reader as an event.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      for (final (_, writer) in pipes) {
        writer.send(AgentEvent(error: error, stackTrace: stackTrace));
      }
    } finally {
      for (final (_, writer) in pipes) {
        await writer.close();
      }
    }
  }());
  return [for (final (reader, _) in pipes) reader];
}
