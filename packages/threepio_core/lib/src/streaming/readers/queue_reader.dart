part of '../stream_reader.dart';

/// More buffered events than this pause the subscription behind
/// [StreamReader.fromStream]; it resumes once the reader has caught up to
/// [_resumeStreamAt].
const _pauseStreamAt = 64;
const _resumeStreamAt = 16;

/// Closes the channels of readers that were dropped without being closed; see
/// [StreamReader.setAutomaticClose].
final Finalizer<_Channel<Object?>> _automaticCloser =
    Finalizer<_Channel<Object?>>((channel) => channel.closeRecv());

/// An event on its way through a [_Channel].
final class _Parcel<T> {
  _Parcel(this.event, this.accepted);

  final _Event<T> event;

  /// Completes the `sendAsync` call that is waiting for room, with `false`
  /// when the event was taken into the buffer or received and with `true`
  /// when the reader was closed first.
  Completer<bool>? accepted;
}

/// The queue between a [StreamWriter] and its reader.
///
/// Port of eino's `stream`, a Go channel with [capacity] slots. It is an
/// object of its own, referenced by both ends, so that the garbage collector
/// can close the receiving end of a reader that was dropped.
final class _Channel<T> {
  _Channel(this.capacity);

  /// How many events fit before `sendAsync` waits. `0` means it waits until
  /// the event was received.
  final int capacity;

  final Queue<_Parcel<T>> _buffer = Queue<_Parcel<T>>();

  /// The reader is waiting for an event; the buffer is empty then.
  Completer<_Event<T>>? _receiver;

  bool _sendClosed = false;
  bool _recvClosed = false;
  int _endStamp = 0;

  /// Runs when the receiving end closes.
  FutureOr<void> Function()? onRecvClosed;

  /// Runs with the number of buffered events whenever it changes.
  void Function(int buffered)? onBuffered;

  bool get isClosed => _sendClosed || _recvClosed;

  int get buffered => _buffer.length;

  /// Queues [event] without waiting, whatever the capacity. Returns `true`
  /// when the channel is closed and the event was dropped.
  bool add(_Event<T> event) {
    if (isClosed) return true;

    final receiver = _receiver;
    if (receiver != null) {
      _receiver = null;
      receiver.complete(event);
    } else {
      _buffer.add(_Parcel<T>(event, null));
      onBuffered?.call(_buffer.length);
    }
    return false;
  }

  /// Queues [event] and completes when the channel has taken it: at once
  /// while fewer than [capacity] events are waiting, otherwise when enough of
  /// them were received. Completes with `true` when the channel is closed.
  Future<bool> addAndWait(_Event<T> event) {
    if (isClosed) return Future<bool>.value(true);

    final receiver = _receiver;
    if (receiver != null) {
      _receiver = null;
      receiver.complete(event);
      return Future<bool>.value(false);
    }

    if (_buffer.length < capacity) {
      _buffer.add(_Parcel<T>(event, null));
      onBuffered?.call(_buffer.length);
      return Future<bool>.value(false);
    }

    final accepted = Completer<bool>();
    _buffer.add(_Parcel<T>(event, accepted));
    onBuffered?.call(_buffer.length);
    return accepted.future;
  }

  /// The next event: at once when one is buffered or the sender is done.
  FutureOr<_Event<T>> take() {
    if (_recvClosed) return _Event<T>.eof(_nextStamp());

    if (_buffer.isNotEmpty) {
      final parcel = _buffer.removeFirst();
      // Only a sender on a channel without capacity still waits here.
      parcel.accepted?.complete(false);

      // One slot became free: the event that moved into it is accepted.
      if (capacity > 0 && _buffer.length >= capacity) {
        final admitted = _buffer.elementAt(capacity - 1);
        admitted.accepted?.complete(false);
        admitted.accepted = null;
      }

      onBuffered?.call(_buffer.length);
      return parcel.event;
    }

    if (_sendClosed) return _Event<T>.eof(_endStamp);

    final receiver = _receiver = Completer<_Event<T>>();
    return receiver.future;
  }

  /// No more events will be sent; the reader sees the end after the buffered
  /// ones.
  void closeSend() {
    if (isClosed) {
      _sendClosed = true;
      return;
    }
    _sendClosed = true;
    _endStamp = _nextStamp();

    final receiver = _receiver;
    if (receiver != null) {
      _receiver = null;
      receiver.complete(_Event<T>.eof(_endStamp));
    }
  }

  /// The reader is gone: buffered events are dropped and waiting senders are
  /// told.
  FutureOr<void> closeRecv() {
    if (_recvClosed) return null;
    _recvClosed = true;

    for (final parcel in _buffer) {
      parcel.accepted?.complete(true);
    }
    _buffer.clear();

    final receiver = _receiver;
    if (receiver != null) {
      _receiver = null;
      receiver.complete(_Event<T>.eof(_nextStamp()));
    }

    return onRecvClosed?.call();
  }
}

/// The reader of a [_Channel]: the receiving end of [pipe], or the events of
/// a Dart stream.
final class _QueueReader<T> extends _Reader<T> {
  _QueueReader(this._channel);

  /// See [StreamReader.fromStream].
  static _QueueReader<S> fromStream<S>(Stream<S> stream) {
    final channel = _Channel<S>(0);
    final subscription = stream.listen(
      (data) => channel.add(_Event<S>.data(data, _nextStamp())),
      onError: (Object error, StackTrace stackTrace) =>
          channel.add(_Event<S>.error(error, stackTrace, _nextStamp())),
      onDone: channel.closeSend,
      cancelOnError: false,
    );

    channel
      ..onRecvClosed = subscription.cancel
      ..onBuffered = (buffered) {
        if (subscription.isPaused) {
          if (buffered <= _resumeStreamAt) subscription.resume();
        } else if (buffered >= _pauseStreamAt) {
          subscription.pause();
        }
      };

    return _QueueReader<S>(channel);
  }

  final _Channel<T> _channel;
  bool _automaticClose = false;

  @override
  FutureOr<_Event<T>> _pull() => _channel.take();

  @override
  FutureOr<void> _dispose() {
    if (_automaticClose) _automaticCloser.detach(this);
    return _channel.closeRecv();
  }

  @override
  void setAutomaticClose() {
    if (_automaticClose || _released) return;
    _automaticClose = true;
    // The finalizer holds the channel, never the reader.
    _automaticCloser.attach(this, _channel, detach: this);
  }
}

/// Writer for sending items to a stream
///
/// Port of eino `schema.StreamWriter`. A writer is created together with its
/// [StreamReader] by [pipe].
///
/// [send] and [sendError] never wait: the item is queued for the reader
/// however many are queued already. [sendAsync] and [sendErrorAsync] are the
/// counterpart of Go's blocking `Send`: they complete when the pipe has room
/// for the item, which is how a producer is slowed down to the pace of its
/// consumer.
///
/// Always [close] the writer when done; the reader sees the end of the stream
/// only then.
class StreamWriter<T> {
  StreamWriter._(this._channel);

  final _Channel<T> _channel;

  /// Send a data chunk to the stream
  ///
  /// Returns true if the stream is closed, false otherwise.
  bool send(T chunk) => _channel.add(_Event<T>.data(chunk, _nextStamp()));

  /// Send an error to the stream
  ///
  /// The reader's `recv` throws it in place of an item; the stream goes on.
  /// Returns true if the stream is closed, false otherwise.
  bool sendError(Object error, [StackTrace? stackTrace]) =>
      _channel.add(_Event<T>.error(error, stackTrace, _nextStamp()));

  /// Send a data chunk with optional error
  ///
  /// This matches the Eino API: Send(chunk T, err error). When [error] is
  /// given it is what the reader receives; the chunk is dropped.
  /// Returns true if the stream is closed, false otherwise.
  bool sendWithError(T chunk, [Object? error, StackTrace? stackTrace]) =>
      error == null ? send(chunk) : sendError(error, stackTrace);

  /// Sends [chunk] and waits until the pipe has taken it.
  ///
  /// With a `capacity` of `n`, the future completes at once while fewer than
  /// `n` items are waiting to be received, and otherwise when the reader has
  /// received enough of them. With the default capacity of `0` it completes
  /// when the reader has received this very item.
  ///
  /// Completes with `true` if the stream is closed, also when the reader is
  /// closed while the call is waiting; with `false` otherwise.
  ///
  /// ```dart
  /// await for (final line in lines) {
  ///   if (await writer.sendAsync(line)) break; // nobody listens any more
  /// }
  /// await writer.close();
  /// ```
  Future<bool> sendAsync(T chunk) =>
      _channel.addAndWait(_Event<T>.data(chunk, _nextStamp()));

  /// Sends an error like [sendError] and waits like [sendAsync].
  Future<bool> sendErrorAsync(Object error, [StackTrace? stackTrace]) =>
      _channel.addAndWait(_Event<T>.error(error, stackTrace, _nextStamp()));

  /// Close the stream writer
  ///
  /// Notifies receivers that no more items will be sent.
  /// Always call close() when done sending.
  Future<void> close() async => _channel.closeSend();

  /// Check if the stream is closed
  ///
  /// True once [close] was called, and also once the receiving side closed
  /// its reader: nothing sent after that would be read.
  bool get isClosed => _channel.isClosed;
}
