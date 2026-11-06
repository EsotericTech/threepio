/// Helpers shared by the agentic schema types: Go's JSON shape (`omitempty`,
/// values of a type only the implementer knows), the text of Go's
/// `String()` methods, and deep equality.
///
/// Not exported: the public surface is the `toJson`/`fromJson`/`toString`/
/// `==` members of the types in `agentic_message.dart`, `agentic_tool_choice.dart`
/// and `extensions/*.dart`.
@internal
library;

import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'type_registry.dart';

const DeepCollectionEquality _deep = DeepCollectionEquality();

/// Deep equality: lists by position, maps by key, anything else with `==`.
bool deepEquals(Object? a, Object? b) => _deep.equals(a, b);

/// The hash that goes with [deepEquals].
int deepHash(Object? value) => _deep.hash(value);

// ---------------------------------------------------------------------------
// Writing Go's JSON shape.
// ---------------------------------------------------------------------------

/// Writes [value] under [key] unless it is empty (Go `string` + `omitempty`).
void putString(Map<String, Object?> json, String key, String value) {
  if (value.isNotEmpty) json[key] = value;
}

/// Writes [value] under [key] unless it is 0 (Go `int` + `omitempty`).
void putInt(Map<String, Object?> json, String key, int value) {
  if (value != 0) json[key] = value;
}

/// Writes [value] under [key] unless it is `null` (a Go pointer +
/// `omitempty`).
void putObject(Map<String, Object?> json, String key, Object? value) {
  if (value != null) json[key] = value;
}

/// Writes [value] under [key] unless it is empty (a Go slice + `omitempty`).
void putList(Map<String, Object?> json, String key, List<Object?> value) {
  if (value.isNotEmpty) json[key] = value;
}

/// Writes a value of a type only its producer knows (a Go `any` field +
/// `omitempty`) with [TypeRegistry.encode]: JSON values as they are, values
/// of registered types tagged with their name.
void putAny(Map<String, Object?> json, String key, Object? value) {
  if (value != null) json[key] = TypeRegistry.encode(value);
}

/// Writes an `extra` map (Go `map[string]any` + `omitempty`), its values
/// through [TypeRegistry.encode] like [putAny].
void putExtra(Map<String, Object?> json, String key, Map<String, Object?>? extra) {
  if (extra != null && extra.isNotEmpty) json[key] = TypeRegistry.encode(extra);
}

// ---------------------------------------------------------------------------
// Reading Go's JSON shape.
// ---------------------------------------------------------------------------

/// The string under [key], `''` when there is none.
String readString(Map<String, Object?> json, String key) =>
    json[key] as String? ?? '';

/// The string under [key], or `null` when there is none or it is empty.
String? readNonEmptyString(Map<String, Object?> json, String key) {
  final value = json[key] as String?;
  return value == null || value.isEmpty ? null : value;
}

/// The integer under [key], 0 when there is none.
int readInt(Map<String, Object?> json, String key) =>
    (json[key] as num?)?.toInt() ?? 0;

/// The integer under [key], or `null` when there is none.
int? readIntOrNull(Map<String, Object?> json, String key) =>
    (json[key] as num?)?.toInt();

/// The bool under [key], `false` when there is none.
bool readBool(Map<String, Object?> json, String key) =>
    json[key] as bool? ?? false;

/// The object under [key], or `null` when there is none.
Map<String, Object?>? readMap(Map<String, Object?> json, String key) =>
    asJsonMap(json[key]);

/// [value] as a JSON object, or `null` when it is `null`.
Map<String, Object?>? asJsonMap(Object? value) =>
    (value as Map<Object?, Object?>?)?.cast<String, Object?>();

/// The objects of the list under [key], none when there is no list.
Iterable<Map<String, Object?>> readMaps(Map<String, Object?> json, String key) =>
    (json[key] as List<Object?>? ?? const []).map((item) => asJsonMap(item)!);

/// The object under [key] read with [fromJson], or `null` when there is
/// none.
T? readObject<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?> json) fromJson,
) {
  final value = readMap(json, key);
  return value == null ? null : fromJson(value);
}

/// The objects of the list under [key] read with [fromJson].
List<T> readObjects<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?> json) fromJson,
) =>
    [for (final item in readMaps(json, key)) fromJson(item)];

/// The string under [key] made into a value of an open string enum with
/// [make], or `null` when it is absent or empty (Go's zero value).
T? readOpenValue<T>(
  Map<String, Object?> json,
  String key,
  T Function(String value) make,
) {
  final value = readNonEmptyString(json, key);
  return value == null ? null : make(value);
}

/// The value [putAny] wrote under [key], rebuilt with [TypeRegistry.decode].
Object? readAny(Map<String, Object?> json, String key) =>
    TypeRegistry.decode(json[key]);

/// The `extra` map [putExtra] wrote under [key], or `null`.
Map<String, Object?>? readExtra(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  return (TypeRegistry.decode(value)! as Map<Object?, Object?>)
      .cast<String, Object?>();
}

// ---------------------------------------------------------------------------
// The text of Go's String() methods.
// ---------------------------------------------------------------------------

/// Port of eino's `truncateString`: [s] cut to [maxLen] bytes of UTF-8 and
/// followed by `...` when it is longer.
String truncateString(String s, int maxLen) {
  final bytes = utf8.encode(s);
  if (bytes.length <= maxLen) return s;
  return '${utf8.decode(bytes.sublist(0, maxLen), allowMalformed: true)}...';
}

/// The length of [s] in bytes of UTF-8, Go's `len(s)`.
int byteLength(String s) => utf8.encode(s).length;

/// Port of eino's `formatMediaString`.
String formatMediaString(
  String url,
  String base64Data,
  String fileId,
  String mimeType,
  String detail,
) {
  final sb = StringBuffer();
  if (url.isNotEmpty) sb.write('      url: ${truncateString(url, 100)}\n');
  if (fileId.isNotEmpty) sb.write('      file_id: $fileId\n');
  if (base64Data.isNotEmpty) {
    sb.write(
      '      base64_data: ${truncateString(base64Data, 20)}... '
      '(${byteLength(base64Data)} bytes)\n',
    );
  }
  if (mimeType.isNotEmpty) sb.write('      mime_type: $mimeType\n');
  if (detail.isNotEmpty) sb.write('      detail: $detail\n');
  return sb.toString();
}

/// Port of eino's `printAny`: a string as it is, a JSON value (`null`, a
/// bool, a number, a list, a map) as Go's `json.MarshalIndent(a, "", "  ")`
/// writes it, and any other object with its `toString()` (Go: `String()`
/// of a `fmt.Stringer`). A collection that holds something JSON cannot
/// represent is written with `toString()` as well (Go's `%v` fallback).
String printAny(Object? value) {
  if (value is String) return value;
  if (value == null ||
      value is bool ||
      value is num ||
      value is List<Object?> ||
      value is Map<Object?, Object?>) {
    try {
      return goJsonIndent(value);
    } on _NotJson {
      return '$value';
    }
  }
  return value.toString();
}

/// Thrown by [goJsonIndent] for a value Go's encoder rejects or Dart cannot
/// write without reflection.
final class _NotJson implements Exception {
  const _NotJson();
}

/// [value] as Go's `json.MarshalIndent(value, "", "  ")` writes it: map keys
/// sorted, `<`, `>` and `&` escaped, integral doubles without a fraction.
///
/// Throws [_NotJson] for anything that is not a JSON value.
@visibleForTesting
String goJsonIndent(Object? value) {
  final out = StringBuffer();
  _writeGoJson(out, value, '');
  return out.toString();
}

void _writeGoJson(StringBuffer out, Object? value, String indent) {
  switch (value) {
    case null:
      out.write('null');
    case final bool flag:
      out.write(flag ? 'true' : 'false');
    case final int number:
      out.write(number);
    case final double number:
      out.write(_goFloat(number));
    case final String text:
      _writeGoString(out, text);
    case final List<Object?> items:
      if (items.isEmpty) {
        out.write('[]');
        return;
      }
      final inner = '$indent  ';
      out.write('[\n');
      for (final (index, item) in items.indexed) {
        if (index > 0) out.write(',\n');
        out.write(inner);
        _writeGoJson(out, item, inner);
      }
      out.write('\n$indent]');
    case final Map<Object?, Object?> map:
      if (map.isEmpty) {
        out.write('{}');
        return;
      }
      final keys = [
        for (final key in map.keys)
          if (key is String) key else throw const _NotJson(),
      ]..sort(_compareUtf8);
      final inner = '$indent  ';
      out.write('{\n');
      for (final (index, key) in keys.indexed) {
        if (index > 0) out.write(',\n');
        out.write(inner);
        _writeGoString(out, key);
        out.write(': ');
        _writeGoJson(out, map[key], inner);
      }
      out.write('\n$indent}');
    default:
      throw const _NotJson();
  }
}

/// Go sorts map keys by their bytes.
int _compareUtf8(String a, String b) {
  final x = utf8.encode(a);
  final y = utf8.encode(b);
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

/// A double as Go's encoder writes a `float64`: the shortest digits that
/// read back as the same number, in exponent form below 1e-6 and from 1e21
/// on. Dart's `toString()` chooses the same digits and the same form; it
/// only adds `.0` to an integral value, which Go leaves out (`1e20` is
/// `100000000000000000000`, `-0.0` is `-0`).
String _goFloat(double number) {
  if (number.isNaN || number.isInfinite) throw const _NotJson();
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

// ---------------------------------------------------------------------------
// Concatenation.
// ---------------------------------------------------------------------------

/// Whether two values of a type only their producer knows count as one type
/// for concatenation (Go compares `reflect.TypeOf`). Runtime types must
/// agree, except that all string-keyed maps count as one type, all lists as
/// another, and all numbers as a third: Dart literals carry the type
/// arguments they were inferred with.
bool sameValueType(Object a, Object b) =>
    a.runtimeType == b.runtimeType ||
    (a is Map<String, Object?> && b is Map<String, Object?>) ||
    (a is List<Object?> && b is List<Object?>) ||
    (a is String && b is String) ||
    (a is num && b is num);
