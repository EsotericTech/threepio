/// Go's JSON text, as the eino packages write it.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

final RegExp _jsonEscape = RegExp(r'\\(.)');

/// The JSON text `sonic.MarshalString` writes for [value], which is how
/// eino's `utils.NewTool`, `utils.InferTool` and the eino-ext tools encode
/// the answer of a tool for the model.
///
/// [value] is anything `jsonEncode` accepts (objects with a `toJson()`
/// method included). sonic's default configuration escapes no HTML
/// characters and writes the control characters other than tab, line feed
/// and carriage return as six-character escapes, backspace and form feed
/// included; `jsonEncode` writes those two as `\b` and `\f`, which are
/// rewritten here. Map entries keep their order. Numbers are written as
/// `jsonEncode` writes them (`1.0` for an integral double, where Go writes
/// `1`); only the string escaping is sonic's. This is sonic's native encoder
/// (amd64 from Go 1.17, arm64 from Go 1.20, below Go 1.28 for sonic v1.15);
/// elsewhere sonic falls back to `encoding/json`, which also escapes U+2028
/// and U+2029 (and writes `\b` and `\f` since Go 1.22).
@internal
String goSonicMarshal(Object? value) {
  final backslash = String.fromCharCode(0x5c);
  return jsonEncode(value).replaceAllMapped(
    _jsonEscape,
    (match) => switch (match[1]) {
      'b' => '${backslash}u0008',
      'f' => '${backslash}u000c',
      _ => match[0]!,
    },
  );
}
