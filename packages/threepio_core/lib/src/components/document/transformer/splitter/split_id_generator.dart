/// What the eino-ext splitters share: the ids of the chunks they cut, and the
/// Go string functions their algorithms are written in.
///
/// Port of the `IDGenerator` type that eino-ext's `splitter/recursive`,
/// `splitter/markdown`, `splitter/html` and `splitter/semantic` each declare
/// (the four declarations are identical).
library;

import 'package:meta/meta.dart';

import '../../../../core/run_context.dart';

/// Makes the id of the chunk number [splitIndex] (counted from 0 within its
/// document) cut out of the document whose id is [originalId].
///
/// Port of eino-ext `recursive.IDGenerator` (and of the identical types of
/// the markdown, html and semantic splitters). A document's id is optional in
/// threepio, so [originalId] is `null` for a document without one (Go passes
/// the empty string); the result becomes the chunk's id as it is.
///
/// [ctx] is the context of the call: the `runContext` of the
/// `TransformerOptions` given to `transform`, or a fresh
/// `RunContext.background()` when there is none.
///
/// ```dart
/// String? numbered(RunContext ctx, String? originalId, int splitIndex) =>
///     '${originalId ?? ''}_part$splitIndex';
/// ```
typedef SplitIdGenerator = String? Function(
  RunContext ctx,
  String? originalId,
  int splitIndex,
);

/// The id generator a splitter uses when its config names none: every chunk
/// keeps the id of its document.
///
/// Port of eino-ext `defaultIDGenerator`.
@internal
String? defaultSplitIdGenerator(
  RunContext ctx,
  String? originalId,
  int splitIndex,
) =>
    originalId;

/// The length of [text] as Go's `len` measures it: its number of bytes in
/// UTF-8.
///
/// The default `lenFunc` of the recursive and the semantic splitter (Go:
/// `func(s string) int { return len(s) }`). A lone surrogate, which has no
/// UTF-8 form, counts as the three bytes of the U+FFFD that `utf8.encode`
/// writes for it.
@internal
int splitterUtf8Length(String text) {
  var bytes = 0;
  final length = text.length;
  for (var i = 0; i < length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 &&
        unit <= 0xDBFF &&
        i + 1 < length &&
        (text.codeUnitAt(i + 1) & 0xFC00) == 0xDC00) {
      // A surrogate pair: one code point outside the BMP, four bytes.
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/// [value] without the leading and trailing white space Go's
/// `strings.TrimSpace` removes (Unicode `White_Space`; unlike Dart's `trim`,
/// U+FEFF is kept).
@internal
String splitterGoTrimSpace(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && _isGoSpace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isGoSpace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return start == 0 && end == value.length
      ? value
      : value.substring(start, end);
}

/// Whether Go's `unicode.IsSpace` holds for the code unit [c]. Every such
/// code point is in the BMP, so testing code units is exact.
bool _isGoSpace(int c) =>
    (c >= 0x09 && c <= 0x0D) ||
    c == 0x20 ||
    c == 0x85 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// [text] cut at every [separator], as Go's `strings.Split` cuts it.
///
/// An empty [separator] cuts [text] into its code points (Go: its UTF-8
/// sequences), so a character outside the BMP stays whole; the empty text
/// then gives no pieces at all. Otherwise this is Dart's `split`, which
/// agrees with Go's: `''` gives `['']`, and leading and trailing pieces are
/// kept even when they are empty.
@internal
List<String> splitterGoSplit(String text, String separator) =>
    separator.isEmpty ? _explode(text) : text.split(separator);

/// [text] cut after every [separator], each piece but the last ending with
/// it, as Go's `strings.SplitAfter` cuts it. An empty [separator] cuts like
/// [splitterGoSplit].
@internal
List<String> splitterGoSplitAfter(String text, String separator) {
  if (separator.isEmpty) return _explode(text);
  final pieces = <String>[];
  var start = 0;
  while (true) {
    final index = text.indexOf(separator, start);
    if (index < 0) break;
    final end = index + separator.length;
    pieces.add(text.substring(start, end));
    start = end;
  }
  pieces.add(text.substring(start));
  return pieces;
}

/// The code points of [text], each as a string (Go's `explode`).
List<String> _explode(String text) =>
    [for (final rune in text.runes) String.fromCharCode(rune)];
