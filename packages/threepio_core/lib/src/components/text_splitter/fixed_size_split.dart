import 'dart:math' as math;

/// Splits [text] into windows of at most [chunkSize] characters, each starting
/// [chunkOverlap] characters before the end of the previous one.
///
/// This is the last resort of the structure-aware splitters, used for a segment
/// that is longer than a chunk and contains no separator to split on.
///
/// The loop always terminates: it stops after the window that reaches the end
/// of [text], and every other window must start after the previous one. A
/// [chunkOverlap] that is not smaller than [chunkSize] would violate that, so
/// it is reported as a [StateError] instead of looping forever.
List<String> splitByLength(
  String text, {
  required int chunkSize,
  required int chunkOverlap,
}) {
  final chunks = <String>[];
  var start = 0;

  while (start < text.length) {
    final end = math.min(start + chunkSize, text.length);
    chunks.add(text.substring(start, end));
    if (end >= text.length) break;

    final next = end - chunkOverlap;
    if (next <= start) {
      throw StateError(
        'splitByLength made no progress at offset $start '
        '(chunkSize: $chunkSize, chunkOverlap: $chunkOverlap)',
      );
    }
    start = next;
  }

  return chunks;
}
