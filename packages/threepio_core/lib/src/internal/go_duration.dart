/// Go's text for a duration.
library;

/// [duration] as Go's `time.Duration.String` writes it: `0s`, `20ms`,
/// `1.5s`, `1m30s`, `2h0m0s`, and microseconds with the micro sign. Go
/// counts nanoseconds; a Dart [Duration] has microseconds, so the shortest
/// unit here is the microsecond.
String goDurationString(Duration duration) {
  var micros = duration.inMicroseconds;
  if (micros == 0) return '0s';
  final negative = micros < 0;
  if (negative) micros = -micros;

  final String text;
  if (micros < Duration.microsecondsPerMillisecond) {
    text = '$micros${String.fromCharCode(0xB5)}s';
  } else if (micros < Duration.microsecondsPerSecond) {
    final millis = micros ~/ Duration.microsecondsPerMillisecond;
    final fraction = micros % Duration.microsecondsPerMillisecond;
    text = '$millis${_fraction(fraction, 3)}ms';
  } else {
    final fraction = micros % Duration.microsecondsPerSecond;
    final totalSeconds = micros ~/ Duration.microsecondsPerSecond;
    final seconds = '${totalSeconds % 60}${_fraction(fraction, 6)}s';
    final totalMinutes = totalSeconds ~/ 60;
    if (totalMinutes == 0) {
      text = seconds;
    } else {
      final hours = totalMinutes ~/ 60;
      final minutes = '${totalMinutes % 60}m$seconds';
      text = hours == 0 ? minutes : '${hours}h$minutes';
    }
  }
  return negative ? '-$text' : text;
}

/// `.5` for 500 of 1000 ([digits] 3): the fraction without trailing zeros,
/// or nothing when it is zero (Go: `fmtFrac`).
String _fraction(int value, int digits) {
  if (value == 0) return '';
  var text = value.toString().padLeft(digits, '0');
  while (text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  return '.$text';
}
