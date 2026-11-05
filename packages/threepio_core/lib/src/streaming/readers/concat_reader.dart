part of '../stream_reader.dart';

/// A reader over several sources, one after the other.
///
/// Not part of Eino; the lazy counterpart of concatenating arrays. A source is
/// not read before the one in front of it has ended.
final class _ConcatReader<T> extends _Reader<T> {
  _ConcatReader(this._readers);

  final List<_Reader<T>> _readers;
  int _current = 0;

  @override
  FutureOr<_Event<T>> _pull() {
    while (_current < _readers.length) {
      final requested = _readers[_current]._request();
      if (requested is Future<_Event<T>>) return requested.then(_orNext);
      if (!requested.isEof) return requested;
      _current++;
    }
    return _Event<T>.eof(_nextStamp());
  }

  FutureOr<_Event<T>> _orNext(_Event<T> event) {
    if (!event.isEof) return event;
    _current++;
    return _pull();
  }

  @override
  Future<void> _dispose() async {
    _current = _readers.length;
    await Future.wait([for (final reader in _readers) reader._release()]);
  }

  @override
  void setAutomaticClose() {
    for (final reader in _readers.skip(_current)) {
      reader.setAutomaticClose();
    }
  }
}
