part of '../stream_reader.dart';

/// Arrival counter: every item is stamped when it becomes available, so that a
/// merged reader can deliver the items of its sources in the order they
/// arrived.
int _lastStamp = 0;

int _nextStamp() => ++_lastStamp;

/// One step of a stream: an item, an error, or the end.
final class _Event<T> {
  _Event.data(T this.value, this.stamp)
      : error = null,
        stackTrace = null,
        isEof = false;

  _Event.error(Object this.error, this.stackTrace, this.stamp)
      : value = null,
        isEof = false;

  _Event.eof(this.stamp)
      : value = null,
        error = null,
        stackTrace = null,
        isEof = true;

  /// The item. Only meaningful when this is neither an error nor the end; it
  /// may be `null` for a reader of a nullable type.
  final T? value;
  final Object? error;
  final StackTrace? stackTrace;
  final bool isEof;

  /// When the event became available; see [_nextStamp].
  final int stamp;

  bool get isError => error != null;
}

/// The readers of this library.
///
/// A kind implements [_pull] and [_dispose]. Everything else is shared: the
/// queue of waiting [recv] calls, closing, and the hand-over to a derived
/// reader, which goes on pulling through [_request].
abstract class _Reader<T> extends StreamReader<T> {
  _Reader() : super._();

  /// Produces the next event of this kind of reader.
  ///
  /// Called for one event at a time: not again before the future it returned
  /// has completed. Must not throw and the future must not fail; errors are
  /// events. After the end it is not called again.
  FutureOr<_Event<T>> _pull();

  /// Lets go of whatever this kind of reader reads from. Called once.
  FutureOr<void> _dispose();

  /// Requests for an event that could not be answered at once, oldest first.
  ///
  /// Before a hand-over they belong to [recv] calls, afterwards to the derived
  /// reader.
  final Queue<Completer<_Event<T>>> _requests = Queue<Completer<_Event<T>>>();

  /// A [_pull] has returned a future that has not completed yet.
  bool _pulling = false;

  /// An event that arrived when nobody was waiting for it any more: the [recv]
  /// call that asked for it was failed by a hand-over. The new owner gets it.
  _Event<T>? _stash;

  /// The end of the stream, once it was reached.
  _Event<T>? _end;

  /// [recv] is no longer allowed: closed, or handed over.
  bool _recvClosed = false;

  /// A derived reader owns this one.
  bool _handedOver = false;

  /// The source was let go.
  bool _released = false;

  final Completer<void> _doneCompleter = Completer<void>();

  /// The next event, for [recv] and for the reader this one was handed to.
  ///
  /// Answers synchronously whenever the kind of reader can, so that a reader
  /// over data that is already there never makes its consumer wait.
  FutureOr<_Event<T>> _request() {
    if (_released) return _end ?? _Event<T>.eof(_nextStamp());

    if (_requests.isEmpty && !_pulling) {
      final stashed = _stash;
      if (stashed != null) {
        _stash = null;
        return stashed;
      }
      final end = _end;
      if (end != null) return end;

      final pulled = _guardedPull();
      if (pulled is! Future<_Event<T>>) return _remember(pulled);

      _pulling = true;
      final request = Completer<_Event<T>>();
      _requests.add(request);
      unawaited(pulled.then(_onPulled));
      return request.future;
    }

    final request = Completer<_Event<T>>();
    _requests.add(request);
    return request.future;
  }

  FutureOr<_Event<T>> _guardedPull() {
    try {
      final pulled = _pull();
      if (pulled is Future<_Event<T>>) {
        return pulled.catchError(
          (Object error, StackTrace stackTrace) =>
              _Event<T>.error(error, stackTrace, _nextStamp()),
        );
      }
      return pulled;
    } catch (error, stackTrace) {
      return _Event<T>.error(error, stackTrace, _nextStamp());
    }
  }

  _Event<T> _remember(_Event<T> event) {
    if (event.isEof) _end = event;
    return event;
  }

  void _onPulled(_Event<T> event) {
    _pulling = false;
    if (_released) return;

    _remember(event);
    if (_requests.isEmpty) {
      if (!event.isEof) _stash = event;
      return;
    }

    _requests.removeFirst().complete(event);
    _serve();
  }

  /// Answers waiting requests for as long as events are available at once.
  void _serve() {
    while (_requests.isNotEmpty && !_pulling) {
      final pulled = _end ?? _guardedPull();
      if (pulled is Future<_Event<T>>) {
        _pulling = true;
        unawaited(pulled.then(_onPulled));
        return;
      }
      _requests.removeFirst().complete(_remember(pulled));
    }
  }

  void _failRequests(Object error) {
    while (_requests.isNotEmpty) {
      _requests.removeFirst().completeError(error, StackTrace.current);
    }
  }

  /// Makes this reader the source of a derived reader.
  ///
  /// [recv] calls that are waiting fail with [StreamClosedException]; the
  /// event they were waiting for is not lost, the new owner receives it.
  void _handOver() {
    if (_handedOver) throw _alreadyHandedOver();
    _handedOver = true;
    _recvClosed = true;
    _failRequests(const StreamClosedException());
  }

  /// Lets go of the source. Called by [close], or by the owner of a reader
  /// that was handed over. Safe to call repeatedly.
  Future<void> _release() async {
    if (_released) return;
    _released = true;
    _stash = null;

    // Whoever still waits is a derived reader that is being closed itself.
    final end = _end ??= _Event<T>.eof(_nextStamp());
    while (_requests.isNotEmpty) {
      _requests.removeFirst().complete(end);
    }

    try {
      await _dispose();
    } finally {
      _doneCompleter.complete();
    }
  }

  @override
  Future<T> recv() async {
    if (_recvClosed) throw const StreamClosedException();

    final request = _request();
    final event = request is Future<_Event<T>> ? await request : request;

    if (event.isEof) throw const StreamEOFException();
    final error = event.error;
    if (error != null) {
      Error.throwWithStackTrace(error, event.stackTrace ?? StackTrace.current);
    }
    return event.value as T;
  }

  @override
  Future<void> close() async {
    if (_recvClosed) return;

    _recvClosed = true;
    _failRequests(const StreamClosedException());
    await _release();
  }

  @override
  Future<void> get done => _doneCompleter.future;

  @override
  List<StreamReader<T>> copy(int n) {
    if (n < 1) return [];
    if (n == 1) return [this];

    _handOver();
    return _copies(n);
  }

  /// The [n] readers [copy] returns; this reader was handed over already.
  List<_Reader<T>> _copies(int n) {
    final source = _CopySource<T>(this, n);
    final first = _CopyNode<T>();
    return List.generate(n, (_) => _CopyReader<T>(source, first));
  }

  @override
  StreamReader<D> convert<D>(
    FutureOr<D> Function(T item) fn, {
    Object? Function(Object error)? errWrapper,
    FutureOr<D?> Function()? onEof,
  }) {
    _handOver();
    return _ConvertReader<T, D>(this, fn, errWrapper, onEof);
  }

  /// Nothing to release for a reader that holds no resource of its own.
  @override
  void setAutomaticClose() {}
}

StateError _alreadyHandedOver() => StateError(
      'This StreamReader was already handed over to another reader; '
      'use copy() to consume a stream more than once.',
    );

/// The readers of this library behind [readers], taken over for one derived
/// reader.
///
/// All of them or none: throws [StateError], and leaves every reader as it
/// was, when one of them was handed over before or is given twice.
List<_Reader<T>> _takeOverAll<T>(Iterable<StreamReader<T>> readers) {
  final given = Set<StreamReader<T>>.identity();
  final sources = <_Reader<T>>[];
  for (final reader in readers) {
    final source = reader is _Reader<T> ? reader : _ForeignReader<T>(reader);
    if (!given.add(reader) || source._handedOver) throw _alreadyHandedOver();
    sources.add(source);
  }

  for (final source in sources) {
    source._handOver();
  }
  return sources;
}
