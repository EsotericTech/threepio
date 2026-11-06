/// Helpers that let the middleware ports keep Go's exact text and length
/// rules: byte lengths of UTF-8, `fmt.Sprintf`, `pyfmt.Fmt`, `path/filepath`
/// and `encoding/json` output.
///
/// Go measures strings in UTF-8 bytes (`len(s)`), and the middlewares' limits
/// and truncation points are byte counts; these helpers do the same.
@internal
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/tool_info.dart';
import '../../../schema/tool_result.dart';

/// The length of [s] in UTF-8 bytes (Go `len(s)`).
int utf8Length(String s) {
  var length = 0;
  for (final rune in s.runes) {
    length += rune < 0x80
        ? 1
        : rune < 0x800
            ? 2
            : rune < 0x10000
                ? 3
                : 4;
  }
  return length;
}

/// The longest prefix of [s] that is at most [maxBytes] UTF-8 bytes long
/// and ends on a character boundary (Go `truncateBytes`,
/// `clampPrefixToUTF8Boundary`).
String utf8Prefix(String s, int maxBytes) {
  if (maxBytes <= 0) return '';
  final bytes = utf8.encode(s);
  if (maxBytes >= bytes.length) return s;
  var n = maxBytes;
  while (n > 0 && (bytes[n] & 0xC0) == 0x80) {
    n--;
  }
  return utf8.decode(bytes.sublist(0, n));
}

/// The longest suffix of [s] that is at most [maxBytes] UTF-8 bytes long
/// and starts on a character boundary (Go `clampSuffixToUTF8Boundary`).
String utf8Suffix(String s, int maxBytes) {
  if (maxBytes <= 0) return '';
  final bytes = utf8.encode(s);
  final length = bytes.length;
  if (maxBytes >= length) return s;
  var start = length - maxBytes;
  while (start < length && (bytes[start] & 0xC0) == 0x80) {
    start++;
  }
  return utf8.decode(bytes.sublist(start));
}

/// The UTF-8 bytes of [s] from [start] on (Go `s[start:]`), with [start]
/// moved forward to a character boundary.
String utf8From(String s, int start) {
  final bytes = utf8.encode(s);
  if (start <= 0) return s;
  if (start >= bytes.length) return '';
  var i = start;
  while (i < bytes.length && (bytes[i] & 0xC0) == 0x80) {
    i++;
  }
  return utf8.decode(bytes.sublist(i));
}

/// Go's `fmt.Sprintf` for the verbs the middleware prompts use: `%s`, `%d`,
/// `%v` and `%%`.
String goSprintf(String format, List<Object?> args) {
  final out = StringBuffer();
  var next = 0;
  for (var i = 0; i < format.length; i++) {
    final c = format[i];
    if (c != '%' || i + 1 >= format.length) {
      out.write(c);
      continue;
    }
    final verb = format[i + 1];
    i++;
    if (verb == '%') {
      out.write('%');
    } else if (verb == 's' || verb == 'd' || verb == 'v') {
      out.write(next < args.length ? goValueString(args[next]) : '%!$verb(MISSING)');
      next++;
    } else {
      out
        ..write('%')
        ..write(verb);
    }
  }
  return out.toString();
}

/// How Go's `%v` prints [value]: errors by their message, `nil` as `<nil>`.
String goValueString(Object? value) => switch (value) {
      null => '<nil>',
      final ThreepioException e => e.message,
      _ => value.toString(),
    };

/// The `pyfmt.Fmt` subset the middleware templates use: `{name}` is
/// replaced by the value of `name`, `{{` and `}}` stand for braces. A name
/// that is not in [vars] is a [ThreepioFormatException], as in pyfmt.
String formatNamed(String template, Map<String, Object?> vars) {
  final out = StringBuffer();
  var i = 0;
  while (i < template.length) {
    final c = template[i];
    if (c == '{') {
      if (i + 1 < template.length && template[i + 1] == '{') {
        out.write('{');
        i += 2;
        continue;
      }
      final end = template.indexOf('}', i + 1);
      if (end < 0) {
        throw ThreepioFormatException('pyfmt: unclosed brace', source: template);
      }
      final name = template.substring(i + 1, end);
      if (!vars.containsKey(name)) {
        throw ThreepioFormatException('pyfmt: missing key "$name"', source: template);
      }
      out.write(goValueString(vars[name]));
      i = end + 1;
      continue;
    }
    if (c == '}' && i + 1 < template.length && template[i + 1] == '}') {
      out.write('}');
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

final p.Context _posix = p.Context(style: p.Style.posix);

/// Go `filepath.Clean` on POSIX paths.
String goClean(String path) => path.isEmpty ? '.' : _posix.normalize(path);

/// Go `filepath.Join`: the non-empty elements joined and cleaned.
String goJoin(List<String> parts) {
  final kept = parts.where((part) => part.isNotEmpty).toList();
  if (kept.isEmpty) return '';
  return goClean(kept.join('/'));
}

/// Go `filepath.Dir`: everything up to the last `/`, cleaned (`a/b/` gives
/// `a/b`).
String goDir(String path) {
  final slash = path.lastIndexOf('/');
  return goClean(slash < 0 ? '' : path.substring(0, slash + 1));
}

/// Go `filepath.Base`.
String goBase(String path) {
  if (path.isEmpty) return '.';
  var trimmed = path;
  while (trimmed.length > 1 && trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed == '/') return '/';
  final slash = trimmed.lastIndexOf('/');
  return slash < 0 ? trimmed : trimmed.substring(slash + 1);
}

/// Go `filepath.Ext`: from the last dot of the last element, also for a
/// dot file (`.md` for `.md`).
String goExt(String path) {
  for (var i = path.length - 1; i >= 0 && path[i] != '/'; i--) {
    if (path[i] == '.') return path.substring(i);
  }
  return '';
}

/// Go `filepath.IsAbs` on POSIX paths.
bool goIsAbs(String path) => path.startsWith('/');

/// Go `strings.Fields`: [s] split at runs of white space.
List<String> goFields(String s) =>
    s.split(RegExp(r'\s+')).where((field) => field.isNotEmpty).toList();

/// [s] as Go's `encoding/json` would write it inside a document: `<`, `>`
/// and `&` escaped, as Go escapes HTML by default.
String goEscapeHtml(String json) => json
    .replaceAll('<', r'\u003c')
    .replaceAll('>', r'\u003e')
    .replaceAll('&', r'\u0026')
    .replaceAll('\u2028', r'\u2028')
    .replaceAll('\u2029', r'\u2029');

/// The JSON of a tool output part in the shape of eino's
/// `schema.ToolOutputPart` (Go field tags, the media's common fields
/// inlined, `omitempty` fields left out).
Map<String, Object?> goToolOutputPartJson(ToolOutputPart part) {
  Map<String, Object?> media(MessagePartCommon common) => {
        if (common.url != null) 'url': common.url,
        if (common.base64Data != null) 'base64data': common.base64Data,
        if (common.fileId != null) 'file_id': common.fileId,
        if ((common.mimeType ?? '').isNotEmpty) 'mime_type': common.mimeType,
        if (common.extra != null && common.extra!.isNotEmpty)
          'extra': _sortedMap(common.extra!),
      };
  return {
    'type': _toolPartTypeName(part.type),
    if ((part.text ?? '').isNotEmpty) 'text': part.text,
    if (part.image != null) 'image': media(part.image!.common),
    if (part.audio != null) 'audio': media(part.audio!.common),
    if (part.video != null) 'video': media(part.video!.common),
    if (part.file != null) 'file': media(part.file!.common),
    if (part.toolSearchResult != null)
      'tool_search_result': {
        'tools': [
          for (final tool in part.toolSearchResult!.tools) _goToolInfoJson(tool),
        ],
      },
    if (part.extra != null && part.extra!.isNotEmpty) 'extra': _sortedMap(part.extra!),
  };
}

String _toolPartTypeName(ToolPartType type) => switch (type) {
      ToolPartType.text => 'text',
      ToolPartType.image => 'image',
      ToolPartType.audio => 'audio',
      ToolPartType.video => 'video',
      ToolPartType.file => 'file',
      ToolPartType.toolSearchResult => 'tool_search_result',
    };

/// What eino's default token estimators measure for a tool: Go marshals a
/// `schema.ToolInfo` *value* with its `Extra` set to nil, which skips the
/// pointer-receiver `MarshalJSON` and writes only the exported fields
/// (`{"Name":…,"Desc":…,"Extra":null}`; the parameters are unexported).
String goToolInfoValueJson(ToolInfo info) =>
    jsonEncode({'Name': info.name, 'Desc': info.desc ?? '', 'Extra': null});

/// The length Go's `sonic.Marshal(tool.ParamsOneOf)` adds for a tool in a
/// tool-search result: `{}` for parameters, `null` without.
int goParamsOneOfJsonLength(ToolInfo info) =>
    info.function.parameters == null ? 4 : 2;

Map<String, Object?> _goToolInfoJson(ToolInfo info) => {
      if (info.name.isNotEmpty) 'name': info.name,
      if ((info.desc ?? '').isNotEmpty) 'desc': info.desc,
      if (info.extra != null && info.extra!.isNotEmpty) 'extra': _sortedMap(info.extra!),
      if (info.function.parameters != null) 'has_params_one_of': true,
      if (info.function.parameters != null)
        'json_schema':
            info.function.parametersJsonSchema ??
                info.function.parameters!.toJson(),
    };

Map<String, Object?> _sortedMap(Map<String, dynamic> map) {
  final keys = map.keys.toList()..sort();
  return {for (final key in keys) key: map[key]};
}

/// Go's `json.MarshalIndent(parts, "", "\t")` of tool output parts.
String goIndentedToolOutputParts(List<ToolOutputPart> parts) => goEscapeHtml(
      const JsonEncoder.withIndent('\t')
          .convert([for (final part in parts) goToolOutputPartJson(part)]),
    );

/// The compact JSON of [value] with Go's HTML escaping.
String goJsonEncode(Object? value) => goEscapeHtml(jsonEncode(value));
