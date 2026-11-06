/// How `LangfuseHandler` writes what the components of the agentic path
/// report: the callback payloads of agentic models, agentic chat templates
/// and agentic agents, as JSON objects of their fields, and the agentic
/// messages in them.
///
/// Internal to the Langfuse handler; the agentic twin of the payload cases of
/// `toJsonValue` in `langfuse_values.dart`. eino-ext `callbacks/langfuse/v2`
/// writes every payload with `json.Marshal`, which gives a Go struct its
/// exported fields; as for the classic payloads, the keys here are the
/// camel-case names of the Dart fields and empty fields are left out. The
/// messages themselves are written with `AgenticMessage.toJson`, which is
/// Go's JSON of `schema.AgenticMessage` (see [agenticMessageJson]).
library;

import '../../adk/agentic/agentic_agent.dart';
import '../../adk/agentic/agentic_callbacks.dart';
import '../../adk/eino/interrupt.dart';
import '../../components/model/agentic_model.dart';
import '../../components/prompt/agentic_prompt_callbacks.dart';
import '../../schema/agentic_message.dart';
import 'langfuse_values.dart';

/// [value] with the agentic values in it — [value] itself, or the items of
/// a list (the chunks of a stream) — replaced by their JSON: the callback
/// payloads by maps of their fields, the messages by [agenticMessageJson].
/// Anything else is returned as it is (the very same object), so that
/// `toJsonValue` writes it exactly as it would have.
///
/// The maps still hold the tools and extras as they are; `toJsonValue`
/// writes those.
Object? agenticJsonValue(Object? value) => switch (value) {
      final AgenticMessage message => agenticMessageJson(message),
      final AgenticAgentInput input => {
          'messages': _messages(input.messages),
          'enableStreaming': input.enableStreaming,
        },
      final AgenticModelCallbackConfig config => _compact({
          'model': config.model,
          'maxTokens': config.maxTokens,
          'temperature': config.temperature,
          'topP': config.topP,
        }),
      final AgenticModelCallbackInput input => _compact({
          'messages': _messages(input.messages),
          'tools': input.tools,
          'config': agenticJsonValue(input.config),
          'extra': input.extra,
        }),
      final AgenticModelCallbackOutput output => _compact({
          'message': agenticJsonValue(output.message),
          'config': agenticJsonValue(output.config),
          'tokenUsage': output.tokenUsage,
          'extra': output.extra,
        }),
      final AgenticPromptCallbackInput input => _compact({
          // A placeholder's variable holds agentic messages.
          'variables': {
            for (final MapEntry(:key, :value) in input.variables.entries)
              key: agenticJsonValue(value),
          },
          'extra': input.extra,
        }),
      final AgenticPromptCallbackOutput output => _compact({
          'result': _messages(output.result),
          'extra': output.extra,
        }),
      final AgenticAgentCallbackInput input => _compact({
          'input': agenticJsonValue(input.input),
          'resumeInfo': _resumeInfo(input.resumeInfo),
        }),
      final List<Object?> items when items.any(_isAgenticValue) => [
          for (final item in items) agenticJsonValue(item),
        ],
      _ => value,
    };

/// [message] as Go's JSON of `schema.AgenticMessage`
/// (`AgenticMessage.toJson`), with the values of the `extra` maps of the
/// message and of its blocks written as `toJsonValue` writes those of a
/// classic message: with their own `toJson`, or as their `toString()`.
///
/// `AgenticMessage.toJson` writes such a value for a checkpoint: a value of
/// a registered type tagged with the name of its type (the item ids the
/// OpenAI Responses model keeps in its block extras become
/// `{"$type": …, "$value": {"value": …}}`, where Go writes the string), and
/// it throws [ArgumentError] for a value that is no JSON value and of no
/// registered type. Telemetry shows the value instead, as for the classic
/// messages. When such a value is somewhere else in the message (an
/// `extension`, the arguments or the result of a server tool), the message
/// is written as its `toString()` (Go's `String()`): eino-ext writes the
/// fields of any Go value (`json.Marshal`), which Dart cannot, and failing
/// the observation, and with it the trace, over a value only the telemetry
/// cannot encode would show a run as failed that is not.
///
/// Any other failure (a `toJson` that throws) is left to the encoding, as
/// for a classic payload: the message itself is returned, and `encodeJson`
/// fails on it and reports it.
Object agenticMessageJson(AgenticMessage message) {
  try {
    return _withPlainExtras(message).toJson();
    // What `TypeRegistry.encode` throws for a value it cannot encode.
    // ignore: avoid_catching_errors
  } on ArgumentError {
    return '$message';
  } on Object {
    return message;
  }
}

/// [message] with the values of its extras and of the extras of its blocks
/// as JSON; [message] itself when it has none.
AgenticMessage _withPlainExtras(AgenticMessage message) {
  if (message.extra == null &&
      message.contentBlocks.every((block) => block.extra == null)) {
    return message;
  }
  return message.copyWith(
    contentBlocks: [
      for (final block in message.contentBlocks)
        block.copyWith(extra: _plainExtra(block.extra)),
    ],
    extra: _plainExtra(message.extra),
  );
}

List<Object> _messages(List<AgenticMessage> messages) =>
    [for (final message in messages) agenticMessageJson(message)];

/// [extra] with every value as `toJsonValue` writes it: JSON only.
Map<String, Object?>? _plainExtra(Map<String, Object?>? extra) => extra == null
    ? null
    : {
        for (final MapEntry(:key, :value) in extra.entries)
          key: toJsonValue(value),
      };

/// The fields of [info] (Go writes `adk.ResumeInfo` with its fields).
Map<String, Object?>? _resumeInfo(ResumeInfo? info) => info == null
    ? null
    : _compact({
        'enableStreaming': info.enableStreaming,
        'wasInterrupted': info.wasInterrupted,
        'interruptState': info.interruptState,
        'isResumeTarget': info.isResumeTarget,
        'resumeData': info.resumeData,
      });

bool _isAgenticValue(Object? value) =>
    value is AgenticMessage ||
    value is AgenticAgentInput ||
    value is AgenticModelCallbackConfig ||
    value is AgenticModelCallbackInput ||
    value is AgenticModelCallbackOutput ||
    value is AgenticPromptCallbackInput ||
    value is AgenticPromptCallbackOutput ||
    value is AgenticAgentCallbackInput;

Map<String, Object?> _compact(Map<String, Object?> fields) =>
    fields..removeWhere((_, value) => value == null);
