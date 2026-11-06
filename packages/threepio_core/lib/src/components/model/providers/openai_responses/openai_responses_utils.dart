/// Helpers of the OpenAI Responses agentic model: lenient JSON readers, Go's
/// zero-value rules and the input-source resolution of media blocks.
///
/// Port of eino-ext `components/model/agenticopenai/utils.go` and of the
/// URL helpers of `responses_convertor.go`. Not exported: the package-level
/// helpers of the Go package are private there too.
library;

import 'dart:convert';

import '../../../../errors.dart';
import 'openai_responses_exception.dart';

/// A failure of a conversion (Go: an `error` returned by a converter).
OpenAIResponsesException conversionError(String message) =>
    OpenAIResponsesException(message, isRetryable: false);

/// Runs [body]; a conversion failure it throws gets [prefix] in front of its
/// message, as Go's `fmt.Errorf("prefix: %w", err)` does.
T wrapConversion<T>(String prefix, T Function() body) {
  try {
    return body();
  } on OpenAIResponsesException catch (error) {
    throw error.wrap(prefix);
  } on ThreepioException catch (error) {
    throw OpenAIResponsesException(
      '$prefix: ${error.message}',
      isRetryable: false,
      cause: error,
    );
  }
}

/// The string under [key], or `''` (Go's zero value) when there is none.
String jsonString(Map<String, Object?>? json, String key) =>
    switch (json?[key]) {
      final String value => value,
      _ => '',
    };

/// The number under [key] as an `int`, or `0`.
int jsonInt(Map<String, Object?>? json, String key) => switch (json?[key]) {
      final num value => value.toInt(),
      _ => 0,
    };

/// The number under [key] as a `double`, or `0`.
double jsonDouble(Map<String, Object?>? json, String key) =>
    switch (json?[key]) {
      final num value => value.toDouble(),
      _ => 0,
    };

/// The bool under [key], or `false`.
bool jsonBool(Map<String, Object?>? json, String key) => switch (json?[key]) {
      final bool value => value,
      _ => false,
    };

/// The object under [key], or `null`.
Map<String, Object?>? jsonObject(Map<String, Object?>? json, String key) =>
    asJsonObject(json?[key]);

/// [value] when it is a JSON object, or `null`.
Map<String, Object?>? asJsonObject(Object? value) => switch (value) {
      final Map<String, Object?> map => map,
      final Map<Object?, Object?> map => {
          for (final MapEntry(:key, :value) in map.entries) '$key': value,
        },
      _ => null,
    };

/// The objects of the list under [key]; other elements are skipped.
List<Map<String, Object?>> jsonObjectList(
  Map<String, Object?>? json,
  String key,
) =>
    switch (json?[key]) {
      final List<Object?> list => [
          for (final item in list)
            if (asJsonObject(item) case final map?) map,
        ],
      _ => const [],
    };

/// The strings of the list under [key]; other elements are skipped.
List<String> jsonStringList(Map<String, Object?>? json, String key) =>
    switch (json?[key]) {
      final List<Object?> list => [
          for (final item in list)
            if (item is String) item,
        ],
      _ => const [],
    };

/// Whether [value] is Go's zero value of its kind: `null`, `''`, `0`,
/// `false`, an empty list or map.
bool isZeroValue(Object? value) => switch (value) {
      null => true,
      final String text => text.isEmpty,
      final num number => number == 0,
      final bool flag => !flag,
      final Iterable<Object?> items => items.isEmpty,
      final Map<Object?, Object?> map => map.isEmpty,
      _ => false,
    };

/// [x] unless it is a zero value, else [y]. Port of eino-ext `coalesce`.
T coalesce<T>(T x, T y) => isZeroValue(x) ? y : x;

/// Puts [value] under [key] unless it is empty (Go: `newOpenaiStrOpt`, an
/// optional request field left out when empty).
void putNonEmpty(Map<String, Object?> json, String key, String value) {
  if (value.isNotEmpty) json[key] = value;
}

/// The URL of a media source: [url] when set, else a data URL of
/// [base64Data]. Port of eino-ext `resolveURL`.
String resolveUrl(String url, String base64Data, String mimeType) {
  if (url.isNotEmpty) return url;
  if (mimeType.isEmpty) {
    throw conversionError('mimeType is required when using base64Data');
  }
  return ensureDataUrl(base64Data, mimeType);
}

/// The data URL of the raw base64 string [base64Data]. Port of eino-ext
/// `ensureDataURL`.
String ensureDataUrl(String base64Data, String mimeType) {
  if (base64Data.startsWith('data:')) {
    throw conversionError(
      'base64Data field must be a raw base64 string, but got a string with '
      "prefix 'data:'",
    );
  }
  if (mimeType.isEmpty) throw conversionError('mimeType is required');
  return 'data:$mimeType;base64,$base64Data';
}

/// The URL or the file id a media block is sent with. Port of eino-ext
/// `resolveInputSource`: a URL or inline data wins over a file id, and the
/// file id is used only when neither is set.
({String url, String fileId}) resolveInputSource(
  String url,
  String base64Data,
  String mimeType,
  String fileId,
) {
  if (url.isNotEmpty || base64Data.isNotEmpty) {
    return (url: resolveUrl(url, base64Data, mimeType), fileId: '');
  }
  if (fileId.isNotEmpty) return (url: '', fileId: fileId);
  return (url: resolveUrl(url, base64Data, mimeType), fileId: '');
}

/// [value], a decoded JSON value, as Go's `json.Marshal` writes the `any`
/// the SDK decoded it into: object keys sorted by their bytes, `<`, `>`,
/// `&`, U+2028 and U+2029 escaped, every number a `float64` (`1` for `1.0`,
/// exponent form below 1e-6 and from 1e21 on). Other values throw an
/// [OpenAIResponsesException].
String goJsonMarshal(Object? value) {
  final out = StringBuffer();
  _writeGoJson(out, value);
  return out.toString();
}

void _writeGoJson(StringBuffer out, Object? value) {
  switch (value) {
    case null:
      out.write('null');
    case final bool flag:
      out.write(flag);
    case final num number:
      out.write(_goFloat(number.toDouble()));
    case final String text:
      _writeGoString(out, text);
    case final List<Object?> items:
      out.write('[');
      for (final (index, item) in items.indexed) {
        if (index > 0) out.write(',');
        _writeGoJson(out, item);
      }
      out.write(']');
    case final Map<Object?, Object?> map:
      final keys = [for (final key in map.keys) '$key']..sort(_compareUtf8);
      out.write('{');
      for (final (index, key) in keys.indexed) {
        if (index > 0) out.write(',');
        _writeGoString(out, key);
        out.write(':');
        _writeGoJson(out, map[key]);
      }
      out.write('}');
    default:
      throw conversionError(
        'json: unsupported type: ${value.runtimeType}',
      );
  }
}

int _compareUtf8(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

/// A `float64` as Go's encoder writes it. Dart's `toString()` picks the
/// same shortest digits and the same notation; it only adds `.0` to an
/// integral value.
String _goFloat(double number) {
  if (!number.isFinite) {
    throw conversionError('json: unsupported value: $number');
  }
  final text = number.toString();
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

void _writeGoString(StringBuffer out, String text) {
  const hex = '0123456789abcdef';
  out.write('"');
  for (final rune in text.runes) {
    switch (rune) {
      case 0x22:
        out.write(r'\"');
      case 0x5c:
        out.write(r'\\');
      case 0x0a:
        out.write(r'\n');
      case 0x0d:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      case 0x08:
        out.write(r'\b');
      case 0x0c:
        out.write(r'\f');
      case 0x3c || 0x3e || 0x26 || 0x2028 || 0x2029:
        out
          ..write(r'\u')
          ..write(rune.toRadixString(16).padLeft(4, '0'));
      case < 0x20:
        out
          ..write(r'\u00')
          ..write(hex[rune >> 4])
          ..write(hex[rune & 0xf]);
      case >= 0xd800 && <= 0xdfff:
        // A lone surrogate is no valid text; Go writes U+FFFD for it.
        out.write(r'\ufffd');
      default:
        out.writeCharCode(rune);
    }
  }
  out.write('"');
}
