/// Templates that render to messages: [MessagesTemplate], its two
/// implementations in this package ([Message] itself and
/// [MessagesPlaceholder]) and the template syntaxes of [FormatType].
///
/// Port of the template part of eino `schema/message.go`.
library;

import 'package:jinja/jinja.dart' as jinja;
import 'package:meta/meta.dart';

import '../core/run_context.dart';
import '../errors.dart';
import 'message.dart';

/// The template syntax of a prompt.
///
/// Port of eino `schema.FormatType`.
enum FormatType {
  /// Python format-string syntax: `{name}`, `{user.name}`, `{items[0]}`,
  /// `{price:.2f}`, and `{{` / `}}` for literal braces.
  ///
  /// Eino renders these with `pyfmt`; this is a port of it. A value is
  /// rendered with `toString()` unless a format specification is given.
  fString,

  /// Go's `text/template` syntax. Not available in Dart: formatting with it
  /// throws [UnsupportedError]. The value exists so that code and stored
  /// configuration written for Eino can name it.
  goTemplate,

  /// Jinja2 syntax (`{{ name }}`, `{% if … %}`), rendered by `package:jinja`.
  ///
  /// As in Eino, templates cannot pull in other templates: there is nothing to
  /// `include`, `extends` or `import` from.
  jinja2,
}

/// Something that renders to a list of messages.
///
/// Port of eino `schema.MessagesTemplate`. A chat template is a list of these:
/// each [Message] renders to itself with its placeholders filled, each
/// [MessagesPlaceholder] to the messages found under its key.
// ignore: one_member_abstracts
abstract interface class MessagesTemplate {
  /// The messages this template gives for [vars], read as [type].
  ///
  /// Throws [FormatException] when the template is malformed or [vars] lacks
  /// what it needs. The templates of this library throw a
  /// [ThreepioFormatException], which is one.
  Future<List<Message>> format(
    RunContext ctx,
    Map<String, Object?> vars,
    FormatType type,
  );
}

/// A place in a chat template for a list of messages taken from the
/// variables, typically the conversation so far.
///
/// Port of eino `schema.MessagesPlaceholder`.
///
/// ```dart
/// const history = MessagesPlaceholder('history', optional: true);
/// final messages = await history.format(
///   RunContext.background(),
///   {'history': [Message.user('what is eino?')]},
///   FormatType.fString,
/// );
/// ```
@immutable
final class MessagesPlaceholder implements MessagesTemplate {
  /// A placeholder for the messages under [key]. Unless it is [optional], the
  /// key has to be there.
  const MessagesPlaceholder(this.key, {this.optional = false});

  /// The variable that holds the messages.
  final String key;

  /// Whether a missing variable renders to no messages instead of failing.
  final bool optional;

  @override
  Future<List<Message>> format(
    RunContext ctx,
    Map<String, Object?> vars,
    FormatType type,
  ) async {
    if (!vars.containsKey(key)) {
      if (optional) return [];
      throw ThreepioFormatException(
        'message placeholder format: $key not found',
      );
    }

    final value = vars[key];
    if (value is List<Message>) return value;
    if (value is List<Object?> && value.every((item) => item is Message)) {
      return value.cast<Message>();
    }
    throw ThreepioFormatException(
      'only messages can be used to format message placeholder, '
      'key: $key, actual type: ${value.runtimeType}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MessagesPlaceholder &&
      other.key == key &&
      other.optional == optional;

  @override
  int get hashCode => Object.hash(key, optional);

  @override
  String toString() => 'MessagesPlaceholder($key, optional: $optional)';
}

/// [message] with its text rendered; the body of [Message.format].
@internal
Message formatMessage(
  Message message,
  Map<String, Object?> vars,
  FormatType type,
) {
  final formatted = message.copyWith(
    content: _formatContent(message.content, vars, type),
  );

  final parts = message.userInputMultiContent;
  if (parts == null || parts.isEmpty) return formatted;

  MessagePartCommon sources(MessagePartCommon common) => common.copyWith(
        url: _formatSource(common.url, vars, type),
        base64Data: _formatSource(common.base64Data, vars, type),
        fileId: _formatSource(common.fileId, vars, type),
      );

  return formatted.copyWith(
    userInputMultiContent: [
      for (final part in parts)
        switch (part.type) {
          ChatMessagePartType.text => part.copyWith(
              text: _formatSource(part.text, vars, type),
            ),
          ChatMessagePartType.imageUrl => part.copyWith(
              image: part.image?.copyWith(common: sources(part.image!.common)),
            ),
          ChatMessagePartType.audioUrl => part.copyWith(
              audio: part.audio?.copyWith(common: sources(part.audio!.common)),
            ),
          ChatMessagePartType.videoUrl => part.copyWith(
              video: part.video?.copyWith(common: sources(part.video!.common)),
            ),
          ChatMessagePartType.fileUrl => part.copyWith(
              file: part.file?.copyWith(common: sources(part.file!.common)),
            ),
          ChatMessagePartType.reasoning ||
          ChatMessagePartType.toolSearchResult =>
            part,
        },
    ],
  );
}

/// [content] rendered with [vars] in the syntax [type]: the text formatting
/// of [Message.format], shared with the agentic templates
/// (`AgenticMessage.format`).
///
/// Throws [ThreepioFormatException] for a malformed template or a missing
/// variable and [UnsupportedError] for [FormatType.goTemplate].
@internal
String formatTemplateText(
  String content,
  Map<String, Object?> vars,
  FormatType type,
) =>
    _formatContent(content, vars, type);

/// A text that is absent or empty is left alone, as in Eino.
String? _formatSource(
  String? source,
  Map<String, Object?> vars,
  FormatType type,
) =>
    source == null || source.isEmpty
        ? source
        : _formatContent(source, vars, type);

String _formatContent(
  String content,
  Map<String, Object?> vars,
  FormatType type,
) =>
    switch (type) {
      FormatType.fString => _FStringFormatter(content, vars).format(),
      FormatType.jinja2 => _formatJinja(content, vars),
      FormatType.goTemplate => throw UnsupportedError(
          'Go templates (FormatType.goTemplate) are not available in Dart; '
          'use FormatType.fString or FormatType.jinja2',
        ),
    };

/// The loader has no templates, so there is nothing to include, extend or
/// import: Eino gets the same effect by disabling those keywords.
final jinja.Environment _jinjaEnvironment =
    jinja.Environment(loader: const jinja.MapLoader({}));

String _formatJinja(String content, Map<String, Object?> vars) {
  try {
    return _jinjaEnvironment.fromString(content).render(vars);
  } on jinja.TemplateError catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ThreepioFormatException('jinja2: $error', source: content, cause: error),
      stackTrace,
    );
    // The template is input, and the interpreter reports what is wrong with
    // it in more than one way (a bad attribute access is a TypeError, say).
    // To the caller they are all a template that cannot be rendered.
    // ignore: avoid_catching_errors
  } on Error catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ThreepioFormatException('jinja2: $error', source: content, cause: error),
      stackTrace,
    );
  }
}

/// Python format strings, the way `pyfmt` (the library Eino uses) reads them
/// when it is given the variables as its only argument.
final class _FStringFormatter {
  _FStringFormatter(this._template, this._vars);

  final String _template;
  final Map<String, Object?> _vars;

  /// Whether the fields are empty (`{}`, numbered automatically) or named;
  /// a template cannot mix the two.
  bool? _automatic;

  /// How many automatically numbered fields there were so far.
  int _position = 0;

  Never _fail(String message) =>
      throw ThreepioFormatException(message, source: _template);

  String format() {
    final out = StringBuffer();
    final end = _template.length;
    var i = 0;

    while (i < end) {
      final char = _template[i];

      if (char == '}') {
        if (i + 1 == end || _template[i + 1] != '}') {
          _fail("Single '}' encountered in format string");
        }
        out.write('}');
        i += 2;
        continue;
      }

      if (char != '{') {
        out.write(char);
        i++;
        continue;
      }

      if (i + 1 < end && _template[i + 1] == '{') {
        out.write('{');
        i += 2;
        continue;
      }

      final close = _template.indexOf('}', i + 1);
      if (close < 0) _fail("Single '{' encountered in format string");

      final field = _template.substring(i + 1, close);
      final colon = field.indexOf(':');
      final name = colon < 0 ? field : field.substring(0, colon);
      final spec = colon < 0 ? '' : field.substring(colon + 1);

      final value = _lookUp(name);
      out.write(spec.isEmpty ? '$value' : _render(value, spec));
      i = close + 1;
    }

    return out.toString();
  }

  /// The value [name] stands for: a variable, then any number of `.field` and
  /// `[field]` steps into maps and lists.
  Object? _lookUp(String name) {
    // pyfmt receives the variables as its one positional argument, so `{}`
    // and `{0}` are the variables themselves, and there is no second one.
    final automatic = name.isEmpty;
    if ((_automatic ??= automatic) != automatic) {
      _fail(
        automatic
            ? 'cannot switch from manual field specification to automatic '
                'field numbering'
            : 'cannot switch from automatic field numbering to manual field '
                'specification',
      );
    }
    if (automatic) {
      if (_position > 0) _fail('too large offset: $_position');
      _position++;
      return _vars;
    }

    final steps = _steps(name);
    final first = steps.first;

    Object? value;
    if (first.isEmpty || first == '0') {
      value = _vars;
    } else if (int.tryParse(first) != null) {
      _fail('index out of bounds: $first');
    } else {
      value = _element(first, _vars);
    }

    for (final step in steps.skip(1)) {
      value = _element(step, value);
    }
    return value;
  }

  List<String> _steps(String name) {
    final steps = <String>[];
    final current = StringBuffer();
    var i = 0;

    while (i < name.length) {
      final char = name[i];
      if (char == '.') {
        steps.add(current.toString());
        current.clear();
        i++;
      } else if (char == '[') {
        final close = name.indexOf(']', i);
        if (close < 0) _fail('unmatched [ in $name');
        if (i > 0 && name[i - 1] != ']') steps.add(current.toString());
        current.clear();
        steps.add(name.substring(i + 1, close));
        i = close + 1;
        if (i < name.length && name[i] != '[' && name[i] != '.') {
          _fail('must begin a new subfield after a closing bracket in $name');
        }
        if (i < name.length && name[i] == '.') i++;
        if (i == name.length) return steps;
      } else if (char == ']') {
        _fail('unmatched ] in $name');
      } else {
        current.write(char);
        i++;
      }
    }

    // A dot at the very end names nothing more.
    if (current.isNotEmpty || steps.isEmpty) steps.add(current.toString());
    return steps;
  }

  Object? _element(String name, Object? source) {
    if (source is Map<Object?, Object?>) {
      if (source.containsKey(name)) return source[name];
      final index = int.tryParse(name);
      if (index != null && source.containsKey(index)) return source[index];
      _fail('could not find key: $name');
    }

    if (source is List<Object?>) {
      final index = int.tryParse(name);
      if (index == null || index < 0) _fail('could not parse index: $name');
      if (index >= source.length) _fail('index out of bounds: $index');
      return source[index];
    }

    _fail(
      'attempted to get item "$name" from ${source.runtimeType}, '
      'which is neither a map nor a list',
    );
  }

  static final RegExp _specPattern = RegExp(
    r'^(?:(.)?([<>=^]))?([+\- ])?(#)?(0)?(\d+)?(?:\.(\d+))?([bdoxXeEfFgGs%])?$',
    unicode: true,
  );

  /// [value] according to a format specification such as `>8`, `08.3f` or
  /// `+d`: `[[fill]align][sign][#][0][width][.precision][type]`.
  String _render(Object? value, String spec) {
    final match = _specPattern.firstMatch(spec);
    if (match == null) _fail('Invalid format specification: $spec');

    var fill = match.group(1) ?? ' ';
    var align = match.group(2) ?? '>';
    final sign = match.group(3) ?? '-';
    final alternate = match.group(4) != null;
    if (match.group(5) != null) {
      if (match.group(1) == null) fill = '0';
      if (match.group(2) == null) align = '=';
    }
    final width = int.parse(match.group(6) ?? '0');
    final precision = switch (match.group(7)) {
      final String digits => int.parse(digits),
      null => null,
    };
    final type = match.group(8) ??
        switch (value) {
          int() => 'd',
          double() => precision == null ? '' : 'g',
          _ => 's',
        };

    var body = _body(value, type, precision, alternate, spec);
    var prefix = '';
    if (value is num && type != 's') {
      if (body.startsWith('-')) {
        prefix = '-';
        body = body.substring(1);
      } else if (sign != '-') {
        prefix = sign;
      }
      // Zero padding goes between `0x` and the digits.
      if (alternate && RegExp('^0[xXbo]').hasMatch(body)) {
        prefix += body.substring(0, 2);
        body = body.substring(2);
      }
    }

    final padding = width - prefix.length - body.length;
    if (padding <= 0) return '$prefix$body';

    return switch (align) {
      '<' => '$prefix$body${fill * padding}',
      '=' => '$prefix${fill * padding}$body',
      '^' => '${fill * (padding ~/ 2)}$prefix$body'
          '${fill * (padding - padding ~/ 2)}',
      _ => '${fill * padding}$prefix$body',
    };
  }

  String _body(
    Object? value,
    String type,
    int? precision,
    bool alternate,
    String spec,
  ) {
    num number() => value is num
        ? value
        : _fail('Format specification "$spec" needs a number, got $value');

    int integer() {
      final n = number();
      return n is int ? n : _fail('Format type "$type" needs an integer');
    }

    switch (type) {
      case 's':
      case '':
        final text = '$value';
        return precision != null && precision < text.length
            ? text.substring(0, precision)
            : text;
      case 'd':
        return '${integer()}';
      case 'b':
        final n = integer();
        final digits = n.abs().toRadixString(2);
        return '${n < 0 ? '-' : ''}${alternate ? '0b' : ''}$digits';
      case 'o':
        final n = integer();
        final digits = n.abs().toRadixString(8);
        return '${n < 0 ? '-' : ''}${alternate ? '0o' : ''}$digits';
      case 'x':
      case 'X':
        final n = integer();
        final digits = n.abs().toRadixString(16);
        final text = '${n < 0 ? '-' : ''}${alternate ? '0x' : ''}$digits';
        return type == 'X' ? text.toUpperCase() : text;
      case 'f':
      case 'F':
        return number().toDouble().toStringAsFixed(precision ?? 6);
      case 'e':
      case 'E':
        final text = _exponential(number().toDouble(), precision ?? 6);
        return type == 'E' ? text.toUpperCase() : text;
      case 'g':
      case 'G':
        final digits = precision == null || precision == 0 ? 6 : precision;
        var text = number().toDouble().toStringAsPrecision(digits);
        if (text.contains('e')) {
          text = _exponential(number().toDouble(), digits - 1);
        }
        if (text.contains('.') && !alternate) {
          final exponentAt = text.indexOf('e');
          final mantissa = exponentAt < 0 ? text : text.substring(0, exponentAt);
          final exponent = exponentAt < 0 ? '' : text.substring(exponentAt);
          text = mantissa.replaceFirst(RegExp(r'\.?0+$'), '') + exponent;
        }
        return type == 'G' ? text.toUpperCase() : text;
      case '%':
        return '${(number() * 100).toDouble().toStringAsFixed(precision ?? 6)}%';
      default:
        _fail('Invalid format specification: $spec');
    }
  }

  /// Dart writes `1.5e+3`, Python and Go `1.5e+03`.
  static String _exponential(double value, int precision) {
    final text = value.toStringAsExponential(precision);
    final at = text.indexOf('e');
    final exponent = text.substring(at + 2);
    return '${text.substring(0, at + 2)}${exponent.padLeft(2, '0')}';
  }
}
