part of '../stream_reader.dart';

/// One source of a [_MergeReader] with the event read ahead from it.
final class _MergeSlot<T> {
  _MergeSlot(this.reader, this.name);

  final _Reader<T> reader;

  /// The name reported when this source ends; `null` in an unnamed merge.
  final String? name;

  /// The next event of this source, if it arrived and was not delivered yet.
  _Event<T>? head;

  /// A request to [reader] is under way.
  bool pending = false;

  /// The source has ended and, in a named merge, its end was reported.
  bool done = false;
}

/// A reader over several sources at once.
///
/// Port of eino's `multiStreamReader`. Where Go selects at random among the
/// channels that are ready, this reader delivers what arrived first: it reads
/// one event ahead from every source and hands out the one with the lowest
/// arrival stamp. Nothing more is taken from a source than that one event.
final class _MergeReader<T> extends _Reader<T> {
  _MergeReader(List<_Reader<T>> readers, {List<String>? names})
      : _slots = [
          for (var i = 0; i < readers.length; i++)
            _MergeSlot<T>(readers[i], names?[i]),
        ];

  final List<_MergeSlot<T>> _slots;

  /// Completed by the first read-ahead that arrives while [_pull] waits.
  Completer<void>? _arrival;

  bool _disposed = false;

  @override
  FutureOr<_Event<T>> _pull() {
    while (true) {
      if (_disposed) return _Event<T>.eof(_nextStamp());

      _MergeSlot<T>? earliest;
      var live = 0;
      for (final slot in _slots) {
        if (slot.done) continue;
        live++;
        if (slot.head == null && !slot.pending) _readAhead(slot);

        final head = slot.head;
        if (head != null &&
            (earliest == null || head.stamp < earliest.head!.stamp)) {
          earliest = slot;
        }
      }

      if (earliest != null) {
        final event = earliest.head!;
        earliest.head = null;
        if (!event.isEof) return event;

        earliest.done = true;
        final name = earliest.name;
        if (name != null) {
          return _Event<T>.error(SourceEOFException(name), null, event.stamp);
        }
        continue;
      }

      if (live == 0) return _Event<T>.eof(_nextStamp());

      final arrival = _arrival = Completer<void>();
      return arrival.future.then((_) => _pull());
    }
  }

  void _readAhead(_MergeSlot<T> slot) {
    final requested = slot.reader._request();
    if (requested is! Future<_Event<T>>) {
      slot.head = requested;
      return;
    }

    slot.pending = true;
    unawaited(
      requested.then((event) {
        slot
          ..pending = false
          ..head = event;
        final arrival = _arrival;
        if (arrival != null) {
          _arrival = null;
          arrival.complete();
        }
      }),
    );
  }

  @override
  Future<void> _dispose() async {
    _disposed = true;
    await Future.wait([for (final slot in _slots) slot.reader._release()]);
  }

  @override
  void setAutomaticClose() {
    for (final slot in _slots) {
      if (!slot.done) slot.reader.setAutomaticClose();
    }
  }
}
