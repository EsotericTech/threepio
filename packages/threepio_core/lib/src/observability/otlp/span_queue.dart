/// The queue between the code that ends spans and the exporter that sends
/// them.
library;

import 'dart:collection';

import 'otlp_json.dart';

/// A bounded first-in-first-out queue of finished spans.
///
/// A span that arrives while the queue holds [maxSize] spans is turned away:
/// tracing must never grow without bound because the collector is slow or
/// away. [dropped] counts those spans.
final class SpanQueue {
  /// A queue that holds at most [maxSize] spans.
  SpanQueue({this.maxSize = 2048}) {
    if (maxSize <= 0) {
      throw ArgumentError.value(maxSize, 'maxSize', 'must be positive');
    }
  }

  /// The most spans the queue holds.
  final int maxSize;

  final Queue<OtlpSpan> _spans = ListQueue<OtlpSpan>();
  int _dropped = 0;

  /// The number of spans waiting.
  int get length => _spans.length;

  /// Whether no span is waiting.
  bool get isEmpty => _spans.isEmpty;

  /// Whether a span is waiting.
  bool get isNotEmpty => _spans.isNotEmpty;

  /// How many spans were turned away because the queue was full.
  int get dropped => _dropped;

  /// Appends [span]. Returns `false`, and counts the span as dropped, when
  /// the queue is full.
  bool add(OtlpSpan span) {
    if (_spans.length >= maxSize) {
      _dropped++;
      return false;
    }
    _spans.addLast(span);
    return true;
  }

  /// Takes up to [max] spans off the front, oldest first.
  List<OtlpSpan> takeBatch(int max) {
    final batch = <OtlpSpan>[];
    while (batch.length < max && _spans.isNotEmpty) {
      batch.add(_spans.removeFirst());
    }
    return batch;
  }

  /// Removes and returns every waiting span.
  List<OtlpSpan> takeAll() => takeBatch(_spans.length);
}
