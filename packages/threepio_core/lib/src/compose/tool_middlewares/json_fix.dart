part of '../tool_middleware.dart';

/// A tool middleware that repairs the arguments of a tool call when they are
/// not valid JSON, before the tool sees them.
///
/// Port of the `jsonfix` middleware of the eino examples. Models wrap the
/// arguments in text or special tokens, leave a brace off, forget to escape a
/// quote. [repair] says what is fixed. Arguments that are a valid JSON object
/// are passed on unchanged.
///
/// The middleware throws nothing of its own, so interrupts and every other
/// error of the tool pass through it.
final class JsonFixMiddleware extends ToolMiddleware {
  /// The middleware.
  JsonFixMiddleware()
      : super(
          invokable: (next) => (ctx, input) =>
              next(ctx, input.copyWith(arguments: repair(input.arguments))),
          streamable: (next) => (ctx, input) =>
              next(ctx, input.copyWith(arguments: repair(input.arguments))),
          enhancedInvokable: (next) => (ctx, input) =>
              next(ctx, input.copyWith(arguments: repair(input.arguments))),
          enhancedStreamable: (next) => (ctx, input) =>
              next(ctx, input.copyWith(arguments: repair(input.arguments))),
        );

  /// [input] as a JSON object, as far as that can be made out. Never throws.
  ///
  /// In this order: surrounding text is cut off at the first `{` and the last
  /// `}`; the tokens `<|FunctionCallBegin|>`, `<|FunctionCallEnd|>` and
  /// `<think>` are removed; a missing opening or closing brace is added; and
  /// what is still not JSON goes through a lenient reading that accepts
  /// single and typographic quotes, unquoted keys, trailing and some missing
  /// commas, comments, `None`/`True`/`False`/`undefined`, unescaped quotes,
  /// line breaks and backslashes inside strings, and strings, arrays and
  /// objects that were cut off. When nothing helps, the text is returned as
  /// far as it got.
  ///
  /// Where the Go middleware hands over to the `jsonrepair` library, this is
  /// a small reader of its own: it covers what models get wrong in tool
  /// arguments, not every malformation that library knows. A repaired value
  /// is written anew, so a number may change its spelling (`1.0e3` becomes
  /// `1000.0`).
  static String repair(String input) {
    var text = input.trim();
    if (text.startsWith('{') && text.endsWith('}') && _isJson(text)) {
      return text;
    }

    final open = text.indexOf('{');
    final close = text.lastIndexOf('}');
    if (open >= 0 && close >= open) {
      final inner = text.substring(open, close + 1);
      if (_isJson(inner)) return inner;
      text = inner;
    }

    if (text.startsWith(_callBegin)) text = text.substring(_callBegin.length);
    if (text.endsWith(_callEnd)) {
      text = text.substring(0, text.length - _callEnd.length);
    }
    if (text.startsWith(_think)) text = text.substring(_think.length);

    if (_isJson(text)) return text;
    // The lenient reader closes what was cut off by itself; given the added
    // brace, it would take it for a part of an unclosed string or array.
    var lenient = text;
    if (!text.startsWith('{') && text.endsWith('}')) {
      text = '{$text';
      lenient = text;
    } else if (text.startsWith('{') && !text.endsWith('}')) {
      text = '$text}';
    }
    if (_isJson(text)) return text;

    try {
      return jsonEncode(_LenientJson(lenient).read());
      // Whatever the reading or the encoding fails with, the caller gets the
      // text back.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return text;
    }
  }

  static const _callBegin = '<|FunctionCallBegin|>';
  static const _callEnd = '<|FunctionCallEnd|>';
  static const _think = '<think>';

  static bool _isJson(String text) {
    try {
      jsonDecode(text);
      return true;
    } on FormatException {
      return false;
    }
  }
}

/// Reads text that was meant to be JSON.
///
/// Every loop consumes at least one character or ends, and nesting is
/// bounded, so reading always terminates.
final class _LenientJson {
  _LenientJson(this._text);

  final String _text;
  int _at = 0;

  static const _maxDepth = 64;

  /// An opening quote and the characters that close it.
  static const _quotes = {
    '"': '"',
    "'": "'",
    '\u201c': '\u201d"',
    '\u2018': "\u2019'",
  };

  bool get _done => _at >= _text.length;
  String get _char => _text[_at];

  /// The value the text holds. Several values in a row, as in a list without
  /// its brackets, are read as a list.
  Object? read() {
    _skipSpace();
    if (_done) throw const FormatException('nothing to read');
    final first = _value(0);
    final values = [first];
    while (true) {
      _skipSpace();
      if (_done || _char != ',') break;
      _at++;
      _skipSpace();
      if (_done) break;
      final start = _at;
      values.add(_value(0));
      if (_at == start) break;
    }
    return values.length == 1 ? first : values;
  }

  /// Skips white space and comments.
  void _skipSpace() {
    while (!_done) {
      if (_char.trim().isEmpty) {
        _at++;
      } else if (_text.startsWith('//', _at)) {
        final end = _text.indexOf('\n', _at);
        _at = end < 0 ? _text.length : end + 1;
      } else if (_text.startsWith('/*', _at)) {
        final end = _text.indexOf('*/', _at + 2);
        _at = end < 0 ? _text.length : end + 2;
      } else {
        return;
      }
    }
  }

  Object? _value(int depth) {
    if (depth > _maxDepth) throw const FormatException('nested too deeply');
    _skipSpace();
    if (_done) return null;
    final char = _char;
    if (char == '{') return _object(depth);
    if (char == '[') return _array(depth);
    if (_quotes.containsKey(char)) return _string();
    return _bare();
  }

  Map<String, Object?> _object(int depth) {
    _at++; // {
    final result = <String, Object?>{};
    while (true) {
      _skipSpace();
      if (_done) return result;
      final char = _char;
      if (char == '}') {
        _at++;
        return result;
      }
      // A comma too many, or a bracket that closes nothing.
      if (char == ',' || char == ']') {
        _at++;
        continue;
      }

      final start = _at;
      final key = _quotes.containsKey(char) ? _string() : _bareKey();
      _skipSpace();
      if (!_done && _char == ':') _at++;
      result[key] = _value(depth + 1);
      // A key that could not be read and a value that is not there: step on,
      // or the loop would stand still.
      if (_at == start) _at++;
    }
  }

  List<Object?> _array(int depth) {
    _at++; // [
    final result = <Object?>[];
    while (true) {
      _skipSpace();
      if (_done) return result;
      final char = _char;
      if (char == ']') {
        _at++;
        return result;
      }
      // A comma too many, or a brace that closes nothing.
      if (char == ',' || char == '}') {
        _at++;
        continue;
      }
      final start = _at;
      if (char == '{' || char == '[' || _quotes.containsKey(char)) {
        result.add(_value(depth + 1));
      } else {
        // `[1 2 3]`: numbers and literals in a row are elements whose commas
        // are missing. Words in a row are one string.
        final word = _bareWord();
        final parts = [
          for (final part in word.split(RegExp(r'\s+'))) _convert(part),
        ];
        if (parts.length > 1 && parts.every((part) => part is! String)) {
          result.addAll(parts);
        } else {
          result.add(_convert(word));
        }
      }
      if (_at == start) _at++;
    }
  }

  /// The string that starts at the current quote.
  ///
  /// A quote inside it ends the string only when what follows looks like the
  /// end of a value or of a key, or like the next key of an object whose
  /// comma is missing. A string that is cut off ends with the text.
  String _string() {
    final closing = _quotes[_char]!;
    _at++; // opening quote
    final start = _at;
    var end = _text.length;
    while (!_done) {
      final char = _char;
      if (char == r'\') {
        // Whatever follows a backslash does not end the string.
        _at += 2;
        continue;
      }
      if (closing.contains(char) && _endsValueAfter(_at + 1)) {
        end = _at;
        _at++;
        break;
      }
      _at++;
    }
    if (_at > _text.length) _at = _text.length;
    if (end > _text.length) end = _text.length;
    return _unescape(_text.substring(start, end));
  }

  bool _endsValueAfter(int from) {
    var at = from;
    while (at < _text.length && _text[at].trim().isEmpty) {
      at++;
    }
    if (at >= _text.length) return true;
    final next = _text[at];
    if (',}]:'.contains(next)) return true;
    if (next == '/' && at + 1 < _text.length && '/*'.contains(_text[at + 1])) {
      return true;
    }
    // `"a": "x" "b": "y"`: a quoted word and a colon follow, so this is the
    // end of a value in front of the next key.
    final closing = _quotes[next];
    if (closing == null) return false;
    for (var i = at + 1; i < _text.length; i++) {
      final char = _text[i];
      if (char == '\n') return false;
      if (!closing.contains(char)) continue;
      var after = i + 1;
      while (after < _text.length && _text[after].trim().isEmpty) {
        after++;
      }
      return after < _text.length && _text[after] == ':';
    }
    return false;
  }

  static const _escapes = {
    '"': '"',
    "'": "'",
    r'\': r'\',
    '/': '/',
    'b': '\b',
    'f': '\f',
    'n': '\n',
    'r': '\r',
    't': '\t',
  };

  /// [raw] with its escapes resolved. When one of them is not an escape of
  /// JSON (`C:\Users`), the backslashes were meant literally and all of them
  /// stay, except in front of a quote.
  static String _unescape(String raw) {
    if (!raw.contains(r'\')) return raw;

    final buffer = StringBuffer();
    var literal = false;
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] != r'\') {
        buffer.write(raw[i]);
        continue;
      }
      if (i + 1 >= raw.length) {
        literal = true;
        break;
      }
      final next = raw[i + 1];
      final replacement = _escapes[next];
      if (replacement != null) {
        buffer.write(replacement);
        i++;
        continue;
      }
      final code = next == 'u' && i + 6 <= raw.length
          ? int.tryParse(raw.substring(i + 2, i + 6), radix: 16)
          : null;
      if (code == null) {
        literal = true;
        break;
      }
      buffer.writeCharCode(code);
      i += 5;
    }
    if (!literal) return buffer.toString();
    return raw.replaceAll(r'\"', '"').replaceAll(r"\'", "'");
  }

  String _bareKey() {
    final start = _at;
    while (!_done && !':,}'.contains(_char)) {
      _at++;
    }
    return _text.substring(start, _at).trim();
  }

  /// A value without quotes: a number, a literal, or words.
  Object? _bare() => _convert(_bareWord());

  /// The text of a value without quotes. It ends at a comma, a closing
  /// bracket or a quote.
  String _bareWord() {
    final start = _at;
    while (!_done && !',}]'.contains(_char) && !_quotes.containsKey(_char)) {
      _at++;
    }
    return _text.substring(start, _at).trim();
  }

  static Object? _convert(String word) {
    switch (word) {
      case 'true' || 'True':
        return true;
      case 'false' || 'False':
        return false;
      case 'null' || 'None' || 'undefined' || '':
        return null;
    }
    final number = num.tryParse(word);
    // JSON has no NaN and no infinity: those stay words.
    return number != null && number.isFinite ? number : word;
  }
}
