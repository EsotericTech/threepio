import 'package:meta/meta.dart';

import 'stream_item.dart';
import 'stream_reader.dart';

/// Writer for sending items to a stream
///
/// A writer is created together with its [StreamReader] by `pipe`. Items are
/// buffered in the reader until they are received.
class StreamWriter<T> {
  StreamWriter._(this._reader);

  /// Internal factory for creating the writer that fills [reader].
  @internal
  factory StreamWriter.forReader(StreamReader<T> reader) {
    return StreamWriter._(reader);
  }

  final StreamReader<T> _reader;
  bool _isClosed = false;

  /// Send a data chunk to the stream
  ///
  /// Returns true if the stream is closed, false otherwise.
  bool send(T chunk) => _add(StreamItem.data(chunk));

  /// Send an error to the stream
  ///
  /// Returns true if the stream is closed, false otherwise.
  bool sendError(Object error, [StackTrace? stackTrace]) =>
      _add(StreamItem.error(error, stackTrace));

  /// Send a data chunk with optional error
  ///
  /// This matches the Eino API: Send(chunk T, err error)
  /// Returns true if the stream is closed, false otherwise.
  bool sendWithError(T chunk, [Object? error, StackTrace? stackTrace]) =>
      _add(StreamItem(chunk: chunk, error: error, stackTrace: stackTrace));

  bool _add(StreamItem<T> item) {
    if (isClosed) {
      return true;
    }

    _reader.feed(item);
    return false;
  }

  /// Close the stream writer
  ///
  /// Notifies receivers that no more items will be sent.
  /// Always call close() when done sending.
  Future<void> close() async {
    if (_isClosed) {
      return;
    }

    _isClosed = true;
    _reader.feedDone();
  }

  /// Check if the stream is closed
  ///
  /// True once [close] was called, and also once the receiving side closed
  /// its reader: nothing sent after that would be read.
  bool get isClosed => _isClosed || _reader.isReleased;
}
