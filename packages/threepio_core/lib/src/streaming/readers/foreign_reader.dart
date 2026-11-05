part of '../stream_reader.dart';

/// Reads a [StreamReader] that is not one of this library's through its
/// public members, so that it can be merged, concatenated and so on like any
/// other.
final class _ForeignReader<T> extends _Reader<T> {
  _ForeignReader(this._reader);

  final StreamReader<T> _reader;

  @override
  Future<_Event<T>> _pull() async {
    try {
      return _Event<T>.data(await _reader.recv(), _nextStamp());
    } on StreamEOFException {
      return _Event<T>.eof(_nextStamp());
    } on StreamClosedException {
      // Closed behind our back: there is nothing more to read, and reporting
      // it as an error would do so on every further call.
      return _Event<T>.eof(_nextStamp());
    } catch (error, stackTrace) {
      return _Event<T>.error(error, stackTrace, _nextStamp());
    }
  }

  @override
  Future<void> _dispose() => _reader.close();

  @override
  void setAutomaticClose() => _reader.setAutomaticClose();
}
