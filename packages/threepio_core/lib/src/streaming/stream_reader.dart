import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import 'stream_item.dart';

/// Custom exception indicating end of stream
class StreamEOFException implements Exception {
  const StreamEOFException();

  @override
  String toString() => 'End of stream reached';
}

/// Exception thrown when receiving after stream is closed
class StreamClosedException implements Exception {
  const StreamClosedException();

  @override
  String toString() => 'Attempted to receive from closed stream';
}

/// Exception indicating no value should be emitted (for filtering)
class NoValueException implements Exception {
  const NoValueException();

  @override
  String toString() => 'No value to emit';
}

/// Exception indicating EOF from a specific named source stream
class SourceEOFException implements Exception {
  SourceEOFException(this.sourceName);

  final String sourceName;

  @override
  String toString() => 'EOF from source stream: $sourceName';
}

/// Reader for consuming items from a stream.
///
/// A reader has a single consumer: call [recv] until it throws
/// [StreamEOFException], then [close]. Items that arrive before the consumer
/// asks for them are buffered, so nothing is lost between creating a reader and
/// the first [recv].
///
/// [copy], [transform] and the merge and concat helpers hand the reader over to
/// the readers they return. From then on the original reader is unusable
/// ([recv] throws [StreamClosedException]) and closing the derived readers
/// releases the underlying source.
class StreamReader<T> {
  StreamReader._({Future<void> Function()? onClose}) : _onClose = onClose;

  /// Create from a Dart Stream.
  ///
  /// The stream is listened to immediately; [close] cancels the subscription.
  factory StreamReader.fromStream(Stream<T> stream) {
    final reader = StreamReader<T>._();
    final subscription = stream.listen(
      (data) => reader.feed(StreamItem.data(data)),
      onError: (Object error, StackTrace stackTrace) =>
          reader.feed(StreamItem.error(error, stackTrace)),
      onDone: reader.feedDone,
      cancelOnError: false,
    );
    reader._onClose = subscription.cancel;
    return reader;
  }

  /// Create from an iterable (array).
  ///
  /// All items are available at once and the end of the stream is reported by
  /// the [recv] call that follows the last item.
  factory StreamReader.fromIterable(Iterable<T> items) {
    final reader = StreamReader<T>._();
    for (final item in items) {
      reader.feed(StreamItem.data(item));
    }
    reader.feedDone();
    return reader;
  }

  /// Creates an empty reader that is filled through [feed] and [feedDone].
  ///
  /// [onClose] runs once, when the reader is closed or released.
  @internal
  factory StreamReader.buffered({Future<void> Function()? onClose}) {
    return StreamReader<T>._(onClose: onClose);
  }

  Future<void> Function()? _onClose;

  /// Items that arrived and were not yet received.
  final Queue<StreamItem<T>> _queue = Queue<StreamItem<T>>();

  /// [recv] calls waiting for an item, oldest first.
  final Queue<Completer<StreamItem<T>>> _waiters =
      Queue<Completer<StreamItem<T>>>();

  /// Where items go once this reader was handed over by [drainTo].
  ({void Function(StreamItem<T> item) onItem, void Function() onDone})? _drain;

  /// The producer signalled the end of the stream.
  bool _sourceDone = false;

  /// [recv] is no longer allowed: closed, or handed over by [drainTo].
  bool _isClosed = false;

  /// The source was let go; late items are dropped.
  bool _isReleased = false;

  final _doneCompleter = Completer<void>();

  /// Whether the source of this reader was released, either by [close] or by
  /// closing the readers derived from it. Items fed afterwards are dropped.
  @internal
  bool get isReleased => _isReleased;

  /// Adds an item to this reader's buffer, or completes a waiting [recv].
  ///
  /// Does nothing once the reader was released or the stream has ended, so a
  /// producer never fails because its consumer went away.
  @internal
  void feed(StreamItem<T> item) {
    if (_isReleased || _sourceDone) return;

    final drain = _drain;
    if (drain != null) {
      drain.onItem(item);
    } else if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(item);
    } else {
      _queue.add(item);
    }
  }

  /// Marks the end of the stream: once the buffer is empty, [recv] throws
  /// [StreamEOFException].
  @internal
  void feedDone() {
    if (_isReleased || _sourceDone) return;
    _sourceDone = true;

    final drain = _drain;
    if (drain != null) {
      drain.onDone();
    } else {
      _failWaiters(const StreamEOFException());
    }
  }

  /// Hands this reader over to a derived reader.
  ///
  /// Buffered items are passed to [onItem] immediately, later ones as they
  /// arrive, and [onDone] is called when the stream ends. This reader becomes
  /// unusable; the new owner calls [release] when it is closed.
  @internal
  void drainTo({
    required void Function(StreamItem<T> item) onItem,
    required void Function() onDone,
  }) {
    if (_drain != null) {
      throw StateError(
        'This StreamReader was already handed over to another reader; '
        'use copy() to consume a stream more than once.',
      );
    }

    final wasEnded = _sourceDone || _isReleased;
    _isClosed = true;
    _failWaiters(const StreamClosedException());
    _drain = (onItem: onItem, onDone: onDone);

    while (_queue.isNotEmpty) {
      onItem(_queue.removeFirst());
    }
    if (wasEnded) onDone();
  }

  /// Lets go of the source of this reader, for example by cancelling the
  /// subscription behind [StreamReader.fromStream]. Safe to call repeatedly.
  @internal
  Future<void> release() async {
    if (_isReleased) return;
    _isReleased = true;
    _queue.clear();

    try {
      await _onClose?.call();
    } finally {
      _doneCompleter.complete();
    }
  }

  void _failWaiters(Object error) {
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(error);
    }
  }

  /// Receive the next item from the stream
  ///
  /// Returns the next chunk of data.
  /// Throws [StreamEOFException] when the stream ends.
  /// Throws [StreamClosedException] if called after close, or if the reader
  /// is closed while the call is waiting for an item.
  /// Rethrows any error from the stream.
  Future<T> recv() async {
    if (_isClosed) {
      throw const StreamClosedException();
    }

    final StreamItem<T> item;
    if (_queue.isNotEmpty) {
      item = _queue.removeFirst();
    } else if (_sourceDone) {
      throw const StreamEOFException();
    } else {
      final waiter = Completer<StreamItem<T>>();
      _waiters.add(waiter);
      item = await waiter.future;
    }

    final error = item.error;
    if (error != null) {
      Error.throwWithStackTrace(error, item.stackTrace ?? StackTrace.current);
    }

    return item.chunk as T;
  }

  /// Receive all remaining items as a list
  ///
  /// Consumes the entire stream and returns all items.
  /// Throws on error. The [SourceEOFException] markers of a named merge are
  /// not errors and are skipped.
  Future<List<T>> collectAll() async {
    final result = <T>[];

    try {
      while (true) {
        try {
          result.add(await recv());
        } on SourceEOFException {
          // One source of a named merge ended; the others go on.
        }
      }
    } on StreamEOFException {
      // Expected end of stream
    }

    return result;
  }

  /// Convert this reader to a Dart Stream
  ///
  /// The [SourceEOFException] markers of a named merge are skipped.
  Stream<T> asStream() async* {
    try {
      while (true) {
        try {
          yield await recv();
        } on SourceEOFException {
          // One source of a named merge ended; the others go on.
        }
      }
    } on StreamEOFException {
      // Expected end of stream
    }
  }

  /// Close the stream reader
  ///
  /// Should be called when done reading to free resources. A [recv] call that
  /// is waiting for an item completes with [StreamClosedException].
  ///
  /// Closing a reader that was handed over by [copy], [transform] or a merge
  /// or concat helper does nothing: the derived readers own the source.
  Future<void> close() async {
    if (_isClosed) {
      return;
    }

    _isClosed = true;
    _failWaiters(const StreamClosedException());
    await release();
  }

  /// Wait for the stream to be closed
  Future<void> get done => _doneCompleter.future;

  /// Copy this stream reader into multiple independent readers
  ///
  /// The original reader becomes unusable after this operation.
  /// Each returned reader can independently consume the stream and sees every
  /// item, whenever it starts reading. The source is released when the last
  /// copy is closed.
  List<StreamReader<T>> copy(int n) {
    if (n < 1) {
      return [];
    }

    if (n == 1) {
      return [this];
    }

    var openCopies = n;
    Future<void> onCopyClosed() async {
      openCopies--;
      if (openCopies == 0) await release();
    }

    final copies = List.generate(
      n,
      (_) => StreamReader<T>._(onClose: onCopyClosed),
    );

    drainTo(
      onItem: (item) {
        for (final copy in copies) {
          copy.feed(item);
        }
      },
      onDone: () {
        for (final copy in copies) {
          copy.feedDone();
        }
      },
    );

    return copies;
  }

  /// Transform elements using a converter function
  ///
  /// Throw [NoValueException] from the converter to skip an element. Any
  /// other exception is delivered to the consumer of the returned reader.
  ///
  /// The original reader becomes unusable after this operation; closing the
  /// returned reader releases it.
  StreamReader<R> transform<R>(R Function(T) converter) {
    final transformed = StreamReader<R>._(onClose: release);

    drainTo(
      onItem: (item) {
        final error = item.error;
        if (error != null) {
          transformed.feed(StreamItem<R>.error(error, item.stackTrace));
          return;
        }

        try {
          transformed.feed(StreamItem.data(converter(item.chunk as T)));
        } on NoValueException {
          // Skip this item
        } catch (e, st) {
          transformed.feed(StreamItem<R>.error(e, st));
        }
      },
      onDone: transformed.feedDone,
    );

    return transformed;
  }
}
