/// Go's notion of white space, as the eino-ext parsers use it.
library;

import 'package:meta/meta.dart';

import '../../../errors.dart';

/// Whether [rune] is white space for Go's `unicode.IsSpace`: `'\t'`, `'\n'`,
/// `'\v'`, `'\f'`, `'\r'`, `' '`, U+0085, U+00A0 and the other characters
/// with the Unicode property `White_Space`.
///
/// Unlike Dart's `String.trim`, U+FEFF (the byte order mark) is not white
/// space for Go.
@internal
bool goIsSpace(int rune) {
  if (rune <= 0xFF) {
    return (rune >= 0x09 && rune <= 0x0D) ||
        rune == 0x20 ||
        rune == 0x85 ||
        rune == 0xA0;
  }
  return rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200A) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202F ||
      rune == 0x205F ||
      rune == 0x3000;
}

/// [value] without the leading and trailing characters [goIsSpace] accepts.
///
/// Port of Go's `strings.TrimSpace` (and of `strings.TrimFunc(s,
/// unicode.IsSpace)`, which is the same). Every character Go counts as space
/// is in the Basic Multilingual Plane, so code units are enough.
@internal
String goTrimSpace(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && goIsSpace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && goIsSpace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return start == 0 && end == value.length
      ? value
      : value.substring(start, end);
}

/// The text of [error] as Go's `%v` prints an error: the message of a
/// threepio or format exception, the `toString` of anything else.
@internal
String goErrorText(Object error) => switch (error) {
      final ThreepioException e => e.message,
      final FormatException e => e.message,
      _ => error.toString(),
    };
