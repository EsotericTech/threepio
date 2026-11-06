/// The helpers of the LangSmith handler: run names and types, what a chat
/// model reports, the metadata of a run and the formats of its times.
///
/// Internal to the LangSmith handler (not exported); port of eino-ext
/// `callbacks/langsmith/utils.go` and of the time formats of
/// `langsmith.go`.
library;

import 'package:meta/meta.dart';

import '../../../components/model/model_callbacks.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/message_concat.dart';
import '../../run_info.dart';
import 'langsmith_client.dart';

/// The name a run of the component [info] describes is shown under.
///
/// Port of `runInfoToName`: the name of the component, or else its
/// implementation type followed by its kind (`OpenAIChatModel`).
@internal
String langSmithRunName(RunInfo info) => info.name.isNotEmpty
    ? info.name
    : '${info.type}${info.componentType.einoName}';

/// The kind of run the component [info] describes is shown as.
///
/// Port of `runInfoToRunType`: a chat model is an `llm` run, a tool a `tool`
/// run, everything else a `chain` run.
@internal
LangSmithRunType langSmithRunType(RunInfo info) => switch (info.componentType) {
      ComponentType.chatModel => LangSmithRunType.llm,
      ComponentType.tool => LangSmithRunType.tool,
      _ => LangSmithRunType.chain,
    };

/// What the inputs of a chat model call say, read with
/// [langSmithExtractModelInput].
typedef LangSmithModelInput = ({
  ModelCallbackConfig? config,
  List<Message> messages,
  Map<String, Object?>? extra,
});

/// What the outputs of a chat model call say, read with
/// [langSmithExtractModelOutput]. A `null` `message` stands for Go's empty
/// message: no output was a chat model output with a message.
typedef LangSmithModelOutput = ({
  TokenUsage? usage,
  Message? message,
  Map<String, Object?>? extra,
});

/// Reads the settings, messages and extra values of a chat model call from
/// its [inputs] (one per chunk of a streamed input; `null` for a chunk that
/// is not the input of a chat model).
///
/// Port of `extractModelInput`: the last settings and the last non-empty
/// extra values win; the message lists are joined position by position
/// (`schema.ConcatMessageArray`). Throws a [ThreepioException] when they
/// cannot be joined.
@internal
LangSmithModelInput langSmithExtractModelInput(
  List<ModelCallbackInput?> inputs,
) {
  ModelCallbackConfig? config;
  Map<String, Object?>? extra;
  final arrays = <List<Message>>[];
  for (final input in inputs) {
    if (input == null) continue;
    if (input.messages.isNotEmpty) arrays.add(input.messages);
    final inputExtra = input.extra;
    if (inputExtra != null && inputExtra.isNotEmpty) extra = inputExtra;
    config = input.config ?? config;
  }
  if (arrays.isEmpty) {
    return (config: config, messages: const <Message>[], extra: extra);
  }
  final List<Message> messages;
  try {
    messages = concatMessageArray(arrays);
  } on Object catch (error) {
    throw ThreepioException(
      'concat messages failed: ${langSmithErrorText(error)}',
      cause: error,
    );
  }
  return (config: config, messages: messages, extra: extra);
}

/// Reads the token usage, message and extra values of a chat model call from
/// its [outputs] (one per chunk of a streamed output; `null` for a chunk
/// that is not the output of a chat model).
///
/// Port of `extractModelOutput`: the last usage and the last extra values
/// win, and the messages are joined (`schema.ConcatMessages`). Throws a
/// [ThreepioException] when they cannot be joined.
@internal
LangSmithModelOutput langSmithExtractModelOutput(
  List<ModelCallbackOutput?> outputs,
) {
  TokenUsage? usage;
  Map<String, Object?>? extra;
  final chunks = <Message>[];
  for (final output in outputs) {
    if (output == null) continue;
    usage = output.tokenUsage ?? usage;
    final message = output.message;
    if (message != null) chunks.add(message);
    extra = output.extra ?? extra;
  }
  if (chunks.isEmpty) return (usage: usage, message: null, extra: extra);
  final Message message;
  try {
    message = concatMessages(chunks);
  } on Object catch (error) {
    throw ThreepioException(
      'concat message failed: ${langSmithErrorText(error)}',
      cause: error,
    );
  }
  return (usage: usage, message: message, extra: extra);
}

/// The text of [error] as Go's `err.Error()` gives it: the message of a
/// [ThreepioException] (which, like a Go error, already says what caused
/// it), and `toString()` of anything else.
@internal
String langSmithErrorText(Object? error) {
  try {
    return error is ThreepioException ? error.message : '$error';
    // A `toString` that fails still leaves something to report.
    // ignore: avoid_catches_without_on_clauses
  } catch (_) {
    return '${error.runtimeType}';
  }
}

/// The JSON Go writes for an empty `schema.Message`, which is what a run
/// whose streamed output held no message shows as its output.
@internal
const Map<String, Object?> langSmithEmptyMessageJson = {
  'role': '',
  'content': '',
};

/// A copy of [original] that has an entry `metadata` (a map), which is where
/// LangSmith looks for the metadata of a run.
///
/// Port of `SafeDeepCopySyncMapMetadata`. Like Go, the copy is shallow: the
/// values are shared with [original].
@internal
Map<String, Object?> langSmithCopyMetadata(Map<String, Object?>? original) {
  final copy = <String, Object?>{...?original};
  if (!copy.containsKey('metadata')) copy['metadata'] = <String, Object?>{};
  return copy;
}

/// [extra] with the settings of a chat model call added to its `metadata`
/// entry: `ls_model_name`, `ls_max_tokens` (the keys LangSmith shows a model
/// run with) and `model_conf`.
///
/// Port of the block that `OnStart` and `OnStartWithStreamInput` share. The
/// `metadata` map is copied before it is changed (Go writes into the map the
/// caller gave `SetMetadata`). A `metadata` entry that is not a map is left
/// as it is and the settings are not added (Go would panic). The values are
/// those Go writes: an empty name and `0` tokens when the call did not set
/// them, and `model_conf` with the field names of eino's `model.Config`.
@internal
Map<String, Object?> langSmithWithModelConfig(
  Map<String, Object?> extra,
  ModelCallbackConfig config,
) {
  final inner = extra['metadata'];
  if (inner is! Map) return extra;
  return {
    ...extra,
    'metadata': <String, Object?>{
      for (final MapEntry(:key, :value) in inner.entries) '$key': value,
      'ls_model_name': config.model ?? '',
      'ls_max_tokens': config.maxTokens ?? 0,
      'model_conf': <String, Object?>{
        'Model': config.model ?? '',
        'MaxTokens': config.maxTokens ?? 0,
        'Temperature': config.temperature ?? 0,
        'TopP': config.topP ?? 0,
        'Stop': config.stop,
      },
    },
  };
}

/// [extra] with the token [usage] of a chat model call added to its
/// `metadata` entry as `usage_metadata`, the key LangSmith counts tokens by.
///
/// Port of the usage block of `OnEndWithStreamOutput`. Like
/// [langSmithWithModelConfig], the `metadata` map is copied, and one that is
/// not a map is left alone.
@internal
Map<String, Object?> langSmithWithUsage(
  Map<String, Object?> extra,
  TokenUsage usage,
) {
  final inner = extra['metadata'];
  if (inner is! Map) return extra;
  return {
    ...extra,
    'metadata': <String, Object?>{
      for (final MapEntry(:key, :value) in inner.entries) '$key': value,
      'usage_metadata': <String, Object?>{
        'input_tokens': usage.promptTokens,
        'output_tokens': usage.completionTokens,
        'total_tokens': usage.totalTokens,
      },
    },
  };
}

/// The `dotted_order` of a run that starts at [start] with the id [runId],
/// beneath the run whose dotted order is [parentDottedOrder] (empty for a
/// root run).
///
/// Port of the `fmt.Sprintf("%s.%sZ%s", …)` of `OnStart`, `StartSpan` and
/// `OnStartWithStreamInput`, with the time formatted by
/// [langSmithDottedTime].
@internal
String langSmithDottedOrder(
  String parentDottedOrder,
  DateTime start,
  String runId,
) {
  final segment = '${langSmithDottedTime(start)}Z$runId';
  return parentDottedOrder.isEmpty ? segment : '$parentDottedOrder.$segment';
}

/// [time] (in UTC) as the timestamp of a dotted order: year, month, day,
/// `T`, hour, minute, second and the six digits of the microseconds, the
/// format LangSmith's own SDKs write and parse (`%Y%m%dT%H%M%S%f`).
///
/// A deliberate fix of a Go bug. eino-ext formats the time with the layout
/// `20060102T150405000000`, meant as those six digits, but Go reads the
/// trailing `000000` as literal text (only digits after a `.` or `,` are a
/// fraction of a second): every eino dotted order has `000000` there, so
/// runs that start within the same second sort by their random ids instead
/// of by their start. The digits here are those of the run's `start_time`.
@internal
String langSmithDottedTime(DateTime time) {
  final utc = time.toUtc();
  return '${_digits(utc.year, 4)}${_digits(utc.month, 2)}'
      '${_digits(utc.day, 2)}T${_digits(utc.hour, 2)}'
      '${_digits(utc.minute, 2)}${_digits(utc.second, 2)}'
      '${_digits(utc.millisecond * 1000 + utc.microsecond, 6)}';
}

/// [time] (in UTC) as Go's `encoding/json` writes a `time.Time`: RFC 3339
/// with the fraction of a second, without its trailing zeros, and no
/// fraction at all when it is zero (`2025-10-10T12:34:56.1234Z`).
@internal
String langSmithTimeJson(DateTime time) {
  final utc = time.toUtc();
  final seconds = '${_digits(utc.year, 4)}-${_digits(utc.month, 2)}-'
      '${_digits(utc.day, 2)}T${_digits(utc.hour, 2)}:'
      '${_digits(utc.minute, 2)}:${_digits(utc.second, 2)}';
  final micros = utc.millisecond * 1000 + utc.microsecond;
  if (micros == 0) return '${seconds}Z';
  var fraction = _digits(micros, 6);
  while (fraction.endsWith('0')) {
    fraction = fraction.substring(0, fraction.length - 1);
  }
  return '$seconds.${fraction}Z';
}

String _digits(int value, int width) => '$value'.padLeft(width, '0');
