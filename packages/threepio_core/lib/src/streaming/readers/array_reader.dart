part of '../stream_reader.dart';

/// A reader over items that are all there already.
///
/// Port of eino's `arrayReader`: never waits, and reports the end with the
/// call that follows the last item.
final class _ArrayReader<T> extends _Reader<T> {
  _ArrayReader(this._items, [this._index = 0, this._stamp, this._onDispose]);

  final List<T> _items;
  int _index;

  /// Set for a copy: tells the reader it was copied from that it was closed.
  final FutureOr<void> Function()? _onDispose;

  /// One stamp for the whole array, taken when it is first read: its items
  /// "arrive" together, so a merged reader delivers them in one run.
  int? _stamp;

  @override
  FutureOr<_Event<T>> _pull() {
    final stamp = _stamp ??= _nextStamp();
    if (_index < _items.length) return _Event<T>.data(_items[_index++], stamp);
    return _Event<T>.eof(stamp);
  }

  @override
  FutureOr<void> _dispose() => _onDispose?.call();

  /// Copies of an array need no shared buffer: each one walks the same list
  /// from the current position.
  @override
  List<_Reader<T>> _copies(int n) {
    var open = n;
    FutureOr<void> copyClosed() {
      open--;
      if (open == 0) return _release();
    }

    return List.generate(
      n,
      (_) => _ArrayReader<T>(_items, _index, _stamp, copyClosed),
    );
  }
}
