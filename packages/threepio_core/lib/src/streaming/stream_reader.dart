/// Pull-based streams: [StreamReader], [StreamWriter] and the functions that
/// create and combine them.
///
/// Port of eino `schema/stream.go`. One library, split into parts by reader
/// kind, because the kinds share a private pull protocol.
library;

import 'dart:async';
import 'dart:collection';

import '../errors.dart';

part 'readers/array_reader.dart';
part 'readers/concat_reader.dart';
part 'readers/convert_reader.dart';
part 'readers/copy_reader.dart';
part 'readers/foreign_reader.dart';
part 'readers/merge_reader.dart';
part 'readers/queue_reader.dart';
part 'readers/reader_base.dart';
part 'readers/stream_functions.dart';

/// Custom exception indicating end of stream
///
/// The Dart counterpart of Go's `io.EOF` as returned by `StreamReader.Recv`.
class StreamEOFException implements Exception {
  const StreamEOFException();

  @override
  String toString() => 'End of stream reached';
}

/// Exception thrown when receiving after stream is closed
///
/// Port of eino `schema.ErrRecvAfterClosed`.
class StreamClosedException implements ThreepioException {
  const StreamClosedException();

  /// What was attempted.
  @override
  String get message => 'Attempted to receive from closed stream';

  @override
  Object? get cause => null;

  @override
  String toString() => 'Attempted to receive from closed stream';
}

/// Exception indicating no value should be emitted (for filtering)
///
/// Port of eino `schema.ErrNoValue`: throw it from the function given to
/// [StreamReader.convert] to drop the element.
class NoValueException implements Exception {
  const NoValueException();

  @override
  String toString() => 'No value to emit';
}

/// Exception indicating EOF from a specific named source stream
///
/// Port of eino `schema.SourceEOF`; [sourceName] is what Go reads with
/// `schema.GetSourceName`. A reader made by [mergeNamedStreamReaders] throws
/// one from [StreamReader.recv] for every source that ends, and goes on with
/// the others.
class SourceEOFException implements Exception {
  SourceEOFException(this.sourceName);

  final String sourceName;

  @override
  String toString() => 'EOF from source stream: $sourceName';
}

/// Reader for consuming items from a stream.
///
/// Port of eino `schema.StreamReader`. A reader is pulled: nothing is taken
/// from its source until [recv] asks for the next item. It has a single
/// consumer, which calls [recv] until it throws [StreamEOFException] and then
/// [close]:
///
/// ```dart
/// try {
///   while (true) {
///     process(await reader.recv());
///   }
/// } on StreamEOFException {
///   // done
/// } finally {
///   await reader.close();
/// }
/// ```
///
/// [nextOrNull] and [asStream] give the same loop a more familiar shape.
///
/// Readers come from [pipe], [StreamReader.fromIterable],
/// [StreamReader.fromStream], [convert], [copy], [mergeStreamReaders],
/// [mergeNamedStreamReaders] and [concatStreamReaders].
///
/// [copy], [convert] and the merge and concat functions hand the reader over
/// to the readers they return. From then on the original is unusable ([recv]
/// throws [StreamClosedException], [close] does nothing, a second hand-over
/// throws [StateError]) and closing the derived readers releases the source.
///
/// This class cannot be extended. The readers of this library are the only
/// implementations the combining functions can pull from directly; any other
/// implementation is read through its public members.
abstract class StreamReader<T> {
  StreamReader._();

  /// Create from a Dart Stream.
  ///
  /// The stream is listened to immediately and its events are buffered until
  /// they are received. While more than a few dozen events are waiting, the
  /// subscription is paused. [close] cancels the subscription.
  factory StreamReader.fromStream(Stream<T> stream) =>
      _QueueReader.fromStream<T>(stream);

  /// Create from an iterable (array).
  ///
  /// Port of eino `schema.StreamReaderFromArray`. The items are copied; all of
  /// them are available at once and the end of the stream is reported by the
  /// [recv] call that follows the last item.
  factory StreamReader.fromIterable(Iterable<T> items) =>
      _ArrayReader<T>(List<T>.of(items, growable: false));

  /// Receive the next item from the stream
  ///
  /// Port of eino `StreamReader.Recv`.
  ///
  /// Throws [StreamEOFException] when the stream has ended, and keeps doing so
  /// on every later call. Throws [StreamClosedException] if called after
  /// [close], or if the reader is closed while the call is waiting for an
  /// item. An error sent into the stream is rethrown; the stream goes on after
  /// it.
  ///
  /// Calls made while another one is still waiting are served in the order
  /// they were made.
  Future<T> recv();

  /// The next item, or `null` once the stream has ended.
  ///
  /// The shape of the `Next()` loop of Go's `AsyncIterator`:
  ///
  /// ```dart
  /// for (var event = await events.nextOrNull();
  ///     event != null;
  ///     event = await events.nextOrNull()) {
  ///   handle(event);
  /// }
  /// ```
  ///
  /// Everything else [recv] throws is thrown here as well. For a reader of a
  /// nullable type a `null` item cannot be told from the end of the stream;
  /// use [recv] there.
  Future<T?> nextOrNull() async {
    try {
      return await recv();
    } on StreamEOFException {
      return null;
    }
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
  /// The stream is pulled from this reader at the pace of its listener. It
  /// ends when the reader does, and it [close]s the reader when it ends or
  /// when the listener cancels, for example by leaving an `await for` loop
  /// early. The [SourceEOFException] markers of a named merge are skipped.
  ///
  /// An error of the reader is passed on and ends the stream.
  Stream<T> asStream() {
    late final StreamController<T> controller;
    var pumping = false;

    // The listener cancelled, or the reader ended or failed.
    var finished = false;

    Future<void> finish() async {
      finished = true;
      await close();
      unawaited(controller.close());
    }

    Future<void> pump() async {
      if (pumping || finished) return;
      pumping = true;
      try {
        while (!finished && controller.hasListener && !controller.isPaused) {
          try {
            final item = await recv();
            if (finished) return;
            controller.add(item);
          } on SourceEOFException {
            // One source of a named merge ended; the others go on.
          } on StreamEOFException {
            if (!finished) await finish();
          } catch (error, stackTrace) {
            // After a cancel this is the StreamClosedException of our own
            // close, which nobody listens for any more.
            if (finished) return;
            controller.addError(error, stackTrace);
            await finish();
          }
        }
      } finally {
        pumping = false;
      }
    }

    // Synchronous, so that a listener that pauses on an event (as `await for`
    // does) is seen as paused before the next item would be pulled.
    controller = StreamController<T>(
      sync: true,
      onListen: () => unawaited(pump()),
      onResume: () => unawaited(pump()),
      onCancel: () {
        finished = true;
        return close();
      },
    );
    return controller.stream;
  }

  /// Close the stream reader
  ///
  /// Port of eino `StreamReader.Close`. Call it when done reading, also after
  /// [StreamEOFException], to release the source: the writer of a pipe learns
  /// that nobody listens any more, the subscription behind
  /// [StreamReader.fromStream] is cancelled, the sources of a derived reader
  /// are closed. A [recv] call that is waiting for an item completes with
  /// [StreamClosedException]. Closing twice is harmless.
  ///
  /// Closing a reader that was handed over by [copy], [convert] or a merge or
  /// concat function does nothing: the derived readers own the source.
  Future<void> close();

  /// Completes when the source of this reader was released, either by [close]
  /// or by closing the readers derived from it.
  Future<void> get done;

  /// Copy this stream reader into multiple independent readers
  ///
  /// Port of eino `StreamReader.Copy`. Each returned reader sees every item,
  /// at its own pace and whenever it starts reading. The source is pulled when
  /// the first copy needs an item the others have not asked for yet, and an
  /// item is kept only until the slowest open copy has received it. The source
  /// is released when the last copy is closed.
  ///
  /// The original reader becomes unusable after this operation, except that
  /// `copy(1)` returns the reader itself. `copy(0)` returns an empty list.
  List<StreamReader<T>> copy(int n);

  /// Lets the garbage collector release the source of this reader if the
  /// reader is dropped without [close] having been called.
  ///
  /// Port of eino `StreamReader.SetAutomaticClose`. It is a safety net for
  /// readers given to code that may forget to close them; when that happens is
  /// up to the garbage collector, so closing explicitly stays the rule.
  void setAutomaticClose();

  /// A reader of the items of this one, each passed through [fn].
  ///
  /// Port of eino `schema.StreamReaderWithConvert`. The conversion is lazy: an
  /// item is taken from this reader and converted when the returned reader is
  /// asked for one. [fn] may be asynchronous.
  ///
  /// * Throw [NoValueException] from [fn] to drop the item. Any other error
  ///   thrown by [fn] is delivered by [recv] in place of the item, and the
  ///   stream goes on.
  /// * [errWrapper] sees every error that comes out of this reader (not those
  ///   thrown by [fn]). What it returns is delivered instead; when it returns
  ///   `null` the error is skipped and the next item is read. Port of
  ///   `schema.WithErrWrapper`.
  /// * [onEof] runs once, when this reader has ended. A value it returns is
  ///   delivered as one more item and an error it throws is delivered as an
  ///   error; after either, the stream ends. Returning `null` (or throwing
  ///   [StreamEOFException]) just ends the stream. Port of `schema.WithOnEOF`.
  ///
  /// The original reader becomes unusable after this operation; closing the
  /// returned reader releases it.
  StreamReader<D> convert<D>(
    FutureOr<D> Function(T item) fn, {
    Object? Function(Object error)? errWrapper,
    FutureOr<D?> Function()? onEof,
  });

  /// Transform elements using a converter function
  ///
  /// The same as [convert] without its options, kept under its earlier name.
  /// Throw [NoValueException] from the converter to skip an element.
  StreamReader<R> transform<R>(R Function(T) converter) =>
      convert<R>(converter);
}
