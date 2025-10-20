import 'dart:async';

import 'package:meta/meta.dart';

import 'stream_item.dart';

/// Writer for sending items to a stream
class StreamWriter<T> {
  StreamWriter._(this._controller);

  final StreamController<StreamItem<T>> _controller;
  bool _isClosed = false;

  /// Internal factory for creating a writer from a controller
  @internal
  factory StreamWriter.fromController(
    StreamController<StreamItem<T>> controller,
  ) {
    return StreamWriter._(controller);
  }

  /// Send a data chunk to the stream
  ///
  /// Returns true if the stream is closed, false otherwise.
  bool send(T chunk) {
    if (_isClosed) {
      return true;
    }

    _controller.add(StreamItem.data(chunk));
    return false;
  }

  /// Send an error to the stream
  ///
  /// Returns true if the stream is closed, false otherwise.
  bool sendError(Object error, [StackTrace? stackTrace]) {
    if (_isClosed) {
      return true;
    }

    _controller.add(StreamItem.error(error, stackTrace));
    return false;
  }

  /// Send a data chunk with optional error
  ///
  /// This matches the Eino API: Send(chunk T, err error)
  /// Returns true if the stream is closed, false otherwise.
  bool sendWithError(T chunk, [Object? error, StackTrace? stackTrace]) {
    if (_isClosed) {
      return true;
    }

    _controller.add(
      StreamItem(chunk: chunk, error: error, stackTrace: stackTrace),
    );
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
    await _controller.close();
  }

  /// Check if the stream is closed
  bool get isClosed => _isClosed;
}
