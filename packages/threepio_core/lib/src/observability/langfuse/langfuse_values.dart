/// How `LangfuseHandler` turns what components report into span attributes:
/// JSON, masked and cut to size.
///
/// Internal to the Langfuse handler; port of the helper functions of eino-ext
/// `callbacks/langfuse/v2/handler.go` and `model.go`.
library;

import 'dart:convert';

import '../../components/document/document_callbacks.dart';
import '../../components/embedding/embedding_callbacks.dart';
import '../../components/indexer/indexer_callbacks.dart';
import '../../components/model/model_callbacks.dart';
import '../../components/prompt/prompt_callbacks.dart';
import '../../components/retriever/retriever_callbacks.dart';
import '../../components/tool/tool_callbacks.dart';
import '../../schema/document.dart';
import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import '../../schema/tool_result.dart';
import '../../streaming/stream_reader.dart';

/// What takes the place of the middle of a text that was cut.
const truncationMarker = '...[truncated]...';

/// [value] cut to at most [maxLength] UTF-16 code units: its beginning, the
/// [truncationMarker] and its end. Port of `truncateText`.
String truncateText(String value, int maxLength) {
  if (maxLength <= 0) return '';
  if (value.length <= maxLength) return value;
  if (maxLength <= truncationMarker.length) return _prefix(value, maxLength);
  final available = maxLength - truncationMarker.length;
  final head = available * 7 ~/ 10;
  final tail = available - head;
  return '${_prefix(value, head)}$truncationMarker${_suffix(value, tail)}';
}

/// A JSON object of at most [maxLength] code units that stands for the JSON
/// text [value]: `{"original_length": …, "preview": …, "truncated": true}`.
/// Port of `truncateJSON`.
///
/// What is exported in place of a JSON value that is too long has to be JSON
/// again, or Langfuse shows it as a broken string.
String truncateJson(String value, int maxLength) {
  if (maxLength < 2) return '';
  var previewLength = maxLength;
  while (true) {
    final encoded = jsonEncode({
      'original_length': value.length,
      'preview': truncateText(value, previewLength),
      'truncated': true,
    });
    if (encoded.length <= maxLength) return encoded;
    if (previewLength == 0) return '{}';
    previewLength ~/= 2;
  }
}

/// Whether [value] is a JSON text.
bool isJson(String value) {
  try {
    jsonDecode(value);
    return true;
  } on FormatException {
    return false;
  }
}

/// The function every attribute value goes through before it is put on a
/// span: [mask] first, then the cut to [maxLength] code units (a negative
/// [maxLength] means no limit). Port of `newValuePreparer`.
///
/// [onLimit] is called for every value that had to be cut.
String Function(String value) valuePreparer({
  required String Function(String value)? mask,
  required int maxLength,
  required void Function() onLimit,
}) =>
    (original) {
      final value = mask == null ? original : mask(original);
      if (maxLength < 0 || value.length <= maxLength) return value;
      onLimit();
      return isJson(original) || isJson(value)
          ? truncateJson(value, maxLength)
          : truncateText(value, maxLength);
    };

/// [value] cut to [available] code units, as JSON if it is JSON.
String fitValue(String value, int available) => isJson(value)
    ? truncateJson(value, available)
    : truncateText(value, available);

/// The key of a metadata entry as an attribute name segment. Port of
/// `metadataKey`.
String metadataKey(String key) {
  final cleaned = key.replaceAll('.', '_').trim();
  return switch (cleaned) {
    '' || '__proto__' || 'constructor' || 'prototype' => '_$cleaned',
    _ => cleaned,
  };
}

/// The output of an observation that failed.
String errorOutput(String message) => jsonEncode({'error': message});

/// The output of an observation that was cancelled.
String cancelledOutput(String cause) =>
    jsonEncode({'cause': cause, 'status': 'cancelled'});

/// The output of an observation that was interrupted to be resumed later.
String interruptedOutput(String cause) =>
    jsonEncode({'cause': cause, 'status': 'interrupted'});

/// [value] as JSON text, or `null` when it cannot be encoded.
String? encodeJson(Object? value) {
  try {
    return jsonEncode(toJsonValue(value));
    // Anything a `toJson` of application code may throw.
    // ignore: avoid_catches_without_on_clauses
  } catch (_) {
    return null;
  }
}

/// The single value of [values], or the list when there are several (the
/// chunks of a stream). Port of `collapseValues`.
Object? collapseValues(List<Object?> values) =>
    values.length == 1 ? values.single : values;

/// [value] as something `jsonEncode` accepts.
///
/// Port of what `json.Marshal` does for the payloads of eino: messages,
/// documents and the callback payloads of the components are written with
/// their fields, `null` fields left out. An object of a type this library
/// does not know is written with its own `toJson` when it has one and as its
/// `toString()` otherwise.
Object? toJsonValue(Object? value, [int depth = 0]) {
  if (depth > _maxDepth) return '$value';
  Object? nested(Object? inner) => toJsonValue(inner, depth + 1);

  return switch (value) {
    null || String() || bool() || int() => value,
    final double number => number.isFinite ? number : '$number',
    final Message message => _withoutNulls(message.toJson(), depth),
    final Document document => _withoutNulls(document.toJson(), depth),
    final DocumentSource source => _withoutNulls(source.toJson(), depth),
    final ToolInfo info => _withoutNulls(info.toJson(), depth),
    final ToolResult result => _withoutNulls(result.toJson(), depth),
    final TokenUsage usage => _withoutNulls(usage.toJson(), depth),
    final ModelCallbackConfig config => _compact({
        'model': config.model,
        'maxTokens': config.maxTokens,
        'temperature': config.temperature,
        'topP': config.topP,
        'stop': config.stop,
      }),
    final ModelCallbackInput input => _compact({
        'messages': nested(input.messages),
        'tools': nested(input.tools),
        'toolChoice': input.toolChoice?.name,
        'config': nested(input.config),
        'extra': nested(input.extra),
      }),
    final ModelCallbackOutput output => _compact({
        'message': nested(output.message),
        'config': nested(output.config),
        'tokenUsage': nested(output.tokenUsage),
        'extra': nested(output.extra),
      }),
    final PromptCallbackInput input => _compact({
        'variables': nested(input.variables),
        'extra': nested(input.extra),
      }),
    final PromptCallbackOutput output => _compact({
        'result': nested(output.result),
        'extra': nested(output.extra),
      }),
    final ToolCallbackInput input => _compact({
        'argumentsJson': input.argumentsJson,
        'extra': nested(input.extra),
      }),
    final ToolCallbackOutput output => _compact({
        'response': output.response,
        'toolOutput': nested(output.toolOutput),
        'extra': nested(output.extra),
      }),
    final EmbeddingCallbackConfig config => _compact({
        'model': config.model,
        'encodingFormat': config.encodingFormat,
      }),
    final EmbeddingCallbackInput input => _compact({
        'texts': input.texts,
        'config': nested(input.config),
        'extra': nested(input.extra),
      }),
    // The vectors themselves are large and say nothing to a reader.
    final EmbeddingCallbackOutput output => _compact({
        'embeddings': output.embeddings.length,
        'dimensions':
            output.embeddings.isEmpty ? null : output.embeddings.first.length,
        'config': nested(output.config),
        'tokenUsage': nested(output.tokenUsage),
        'extra': nested(output.extra),
      }),
    final RetrieverCallbackInput input => _compact({
        'query': input.query,
        'topK': input.topK,
        'filter': input.filter,
        'scoreThreshold': input.scoreThreshold,
        'extra': nested(input.extra),
      }),
    final RetrieverCallbackOutput output => _compact({
        'docs': nested(output.docs),
        'extra': nested(output.extra),
      }),
    final IndexerCallbackInput input => _compact({
        'docs': nested(input.docs),
        'extra': nested(input.extra),
      }),
    final IndexerCallbackOutput output => _compact({
        'ids': output.ids,
        'extra': nested(output.extra),
      }),
    final LoaderCallbackInput input => _compact({
        'source': nested(input.source),
        'extra': nested(input.extra),
      }),
    final LoaderCallbackOutput output => _compact({
        'source': nested(output.source),
        'docs': nested(output.docs),
        'extra': nested(output.extra),
      }),
    final TransformerCallbackInput input => _compact({
        'input': nested(input.input),
        'extra': nested(input.extra),
      }),
    final TransformerCallbackOutput output => _compact({
        'output': nested(output.output),
        'extra': nested(output.extra),
      }),
    final Map<Object?, Object?> map => {
        for (final MapEntry(:key, :value) in map.entries) '$key': nested(value),
      },
    final Iterable<Object?> items => [for (final item in items) nested(item)],
    final Enum constant => constant.name,
    final DateTime time => time.toUtc().toIso8601String(),
    Uri() || Duration() => '$value',
    Stream<Object?>() || StreamReader<Object?>() => '<stream>',
    _ => _viaToJson(value, depth),
  };
}

const _maxDepth = 32;

Map<String, Object?> _compact(Map<String, Object?> fields) =>
    fields..removeWhere((_, value) => value == null);

/// The JSON of a freezed value without the fields that are `null`, at every
/// level: what Go's `omitempty` leaves of a message.
Object? _withoutNulls(Object? json, int depth) {
  if (depth > _maxDepth) return '$json';
  return switch (json) {
    final Map<Object?, Object?> map => {
        for (final MapEntry(:key, :value) in map.entries)
          if (value != null) '$key': _withoutNulls(value, depth + 1),
      },
    final List<Object?> list => [
        for (final item in list) _withoutNulls(item, depth + 1),
      ],
    String() || num() || bool() || null => json,
    // A nested value that `toJson` left as an object.
    _ => _nestedWithoutNulls(json, depth),
  };
}

Object? _nestedWithoutNulls(Object value, int depth) {
  final converted = toJsonValue(value, depth + 1);
  return converted is Map || converted is List
      ? _withoutNulls(converted, depth + 1)
      : converted;
}

Object? _viaToJson(Object value, int depth) {
  try {
    // The one place that has to ask an object of unknown type for its JSON.
    // ignore: avoid_dynamic_calls
    final json = (value as dynamic).toJson();
    return toJsonValue(json as Object?, depth + 1);
    // A type without `toJson`.
    // ignore: avoid_catching_errors
  } on NoSuchMethodError {
    return '$value';
  }
}

/// The first [length] code units of [value], without half of a surrogate
/// pair at the end.
String _prefix(String value, int length) {
  if (value.length <= length) return value;
  var end = length;
  if (end > 0 && _isHighSurrogate(value.codeUnitAt(end - 1))) end--;
  return value.substring(0, end);
}

/// The last [length] code units of [value], without half of a surrogate pair
/// at the start.
String _suffix(String value, int length) {
  if (value.length <= length) return value;
  var start = value.length - length;
  if (start < value.length && _isLowSurrogate(value.codeUnitAt(start))) {
    start++;
  }
  return value.substring(start);
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
