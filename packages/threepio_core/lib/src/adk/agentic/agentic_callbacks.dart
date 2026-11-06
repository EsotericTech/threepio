/// What agentic agents report to callback handlers.
///
/// Port of the agentic half of eino `adk/callback.go`
/// (`TypedAgentCallbackInput[*schema.AgenticMessage]`,
/// `TypedAgentCallbackOutput`, `ConvTypedCallbackInput`,
/// `ConvTypedCallbackOutput`, `initAgenticCallbacks`,
/// `copyTypedEventIterator`, `copyTypedCallbackOutput`). **Beta**.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../../callbacks/callback_context.dart';
import '../../callbacks/handler_helper.dart';
import '../../callbacks/run_info.dart';
import '../../components/component_type.dart';
import '../../core/run_context.dart';
import '../../streaming/stream_reader.dart';
import '../eino/interrupt.dart';
import '../eino/run_options.dart';
import 'agentic_agent.dart';

/// What an agentic agent reports when it starts: its input for a new run,
/// or what it resumes with.
///
/// Port of eino `adk.TypedAgentCallbackInput[*schema.AgenticMessage]`.
/// Handlers get it as the input of `onStart` for components of kind
/// `ComponentType.agenticAgent` (eino `ComponentOfAgenticAgent`).
@immutable
final class AgenticAgentCallbackInput {
  /// The report of an agentic agent starting.
  const AgenticAgentCallbackInput({this.input, this.resumeInfo});

  /// [raw] if it is an agentic agent's start report, else `null`. Port of
  /// eino `adk.ConvTypedCallbackInput[*schema.AgenticMessage]`.
  static AgenticAgentCallbackInput? from(Object? raw) =>
      raw is AgenticAgentCallbackInput ? raw : null;

  /// The input of a new run; `null` when the agent resumes.
  final AgenticAgentInput? input;

  /// What the agent resumes with; `null` for a new run.
  final ResumeInfo? resumeInfo;
}

/// What an agentic agent reports when it ends: the stream of its events.
///
/// Port of eino `adk.TypedAgentCallbackOutput[*schema.AgenticMessage]`.
/// Every handler gets a stream of its own; the agent does not wait for it.
/// Read it without blocking the hook: start reading in `onEnd` and return.
@immutable
final class AgenticAgentCallbackOutput {
  /// The report of an agent with [events].
  const AgenticAgentCallbackOutput(this.events);

  /// [raw] if it is an agentic agent's end report, else `null`. Port of
  /// eino `adk.ConvTypedCallbackOutput[*schema.AgenticMessage]`.
  static AgenticAgentCallbackOutput? from(Object? raw) =>
      raw is AgenticAgentCallbackOutput ? raw : null;

  /// The events of the agent, as they happen.
  final StreamReader<AgenticAgentEvent> events;
}

/// An `AgenticAgentCallbackHandler` whose functions get the typed reports
/// of an agentic agent: [AgenticAgentCallbackInput] on start and
/// [AgenticAgentCallbackOutput] on end.
///
/// Port of eino `utils/callbacks.AgenticAgentCallbackHandler` with
/// `adk.ConvTypedCallbackInput/Output[*schema.AgenticMessage]`; the agentic
/// twin of `typedAgentCallbackHandler`. Payloads of another type reach the
/// functions as `null`. Register it with `HandlerHelper.agenticAgent`.
AgenticAgentCallbackHandler typedAgenticAgentCallbackHandler({
  TypedCallbackHook<AgenticAgentCallbackInput?>? onStart,
  TypedCallbackHook<AgenticAgentCallbackOutput?>? onEnd,
}) =>
    AgenticAgentCallbackHandler(
      onStart: onStart == null
          ? null
          : (ctx, info, raw) =>
              onStart(ctx, info, AgenticAgentCallbackInput.from(raw)),
      onEnd: onEnd == null
          ? null
          : (ctx, info, raw) =>
              onEnd(ctx, info, AgenticAgentCallbackOutput.from(raw)),
    );

/// [ctx] with the run info of the agentic agent [agentName] and the
/// callback handlers of [options]. Port of eino `initAgenticCallbacks`.
@internal
RunContext initAgenticAgentCallbacks(
  RunContext ctx,
  String agentName,
  String agentType,
  List<AgentRunOption> options,
) {
  final info = RunInfo(
    name: agentName,
    type: agentType,
    componentType: ComponentType.agenticAgent,
  );
  final handlers = CommonAgentOptions.of(options).handlers;
  if (handlers.isEmpty) return reuseHandlers(ctx, info);
  return appendHandlers(ctx, info, handlers);
}

/// The type of [agent] for its run info. Port of eino `getTypedAgentType`.
@internal
String agenticAgentTypeOf(AgenticAgent agent) =>
    componentTypeNameOf(agent) ?? '';

/// [count] reports with a stream of the events of [output] each. Port of
/// eino `copyTypedCallbackOutput[*schema.AgenticMessage]`.
@internal
List<AgenticAgentCallbackOutput> copyAgenticAgentCallbackOutput(
  AgenticAgentCallbackOutput output,
  int count,
) =>
    [
      for (final events in copyAgenticEventStream(output.events, count))
        AgenticAgentCallbackOutput(events),
    ];

/// [count] readers of the events of [source], each with its own copy of
/// every streamed message. Port of eino
/// `copyTypedEventIterator[*schema.AgenticMessage]`.
@internal
List<StreamReader<AgenticAgentEvent>> copyAgenticEventStream(
  StreamReader<AgenticAgentEvent> source,
  int count,
) {
  if (count <= 0) return const [];
  if (count == 1) return [source];
  final pipes = [for (var i = 0; i < count; i++) pipe<AgenticAgentEvent>()];
  unawaited(() async {
    try {
      for (var event = await source.nextOrNull();
          event != null;
          event = await source.nextOrNull()) {
        for (var i = 0; i < count - 1; i++) {
          pipes[i].$2.send(copyAgenticAgentEvent(event));
        }
        pipes[count - 1].$2.send(event);
      }
      // A failure to read or copy reaches every reader as an event.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      for (final (_, writer) in pipes) {
        writer.send(AgenticAgentEvent(error: error, stackTrace: stackTrace));
      }
    } finally {
      for (final (_, writer) in pipes) {
        await writer.close();
      }
    }
  }());
  return [for (final (reader, _) in pipes) reader];
}
