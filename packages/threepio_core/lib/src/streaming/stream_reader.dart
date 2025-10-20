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

/// Reader for consuming items from a stream
class StreamReader<T> {
  StreamReader._(this._controller,
      {void Function()? onClose, bool subscribe = false})
      : _onClose = onClose {
    // Subscribe immediately if requested (for user-facing constructors)
    if (subscribe) {
      _ensureSubscription();
    }
  }

  /// Create from a Dart Stream
  factory StreamReader.fromStream(Stream<T> stream) {
    final controller = StreamController<StreamItem<T>>.broadcast();

    stream.listen(
      (data) => controller.add(StreamItem.data(data)),
      onError: (Object error, StackTrace stackTrace) =>
          controller.add(StreamItem.error(error, stackTrace)),
      onDone: controller.close,
      cancelOnError: false,
    );

    // Subscribe immediately to ensure we don't miss events
    return StreamReader._(controller, subscribe: true);
  }

  /// Create from an iterable (array)
  factory StreamReader.fromIterable(Iterable<T> items) {
    final controller = StreamController<StreamItem<T>>.broadcast();

    Future.microtask(() {
      for (final item in items) {
        controller.add(StreamItem.data(item));
      }
      controller.close();
    });

    // Subscribe immediately to ensure we don't miss events
    return StreamReader._(controller, subscribe: true);
  }

  final StreamController<StreamItem<T>> _controller;
  final void Function()? _onClose;
  StreamSubscription<StreamItem<T>>? _subscription;
  final Queue<StreamItem<T>> _queue = Queue<StreamItem<T>>();
  Completer<void>? _itemAvailable;
  bool _streamDone = false;
  bool _isClosed = false;
  final _completer = Completer<void>();

  /// Internal access to the controller stream (for utilities)
  @internal
  StreamController<StreamItem<T>> get controller => _controller;

  /// Internal factory for creating a reader from a controller
  @internal
  factory StreamReader.fromController(
    StreamController<StreamItem<T>> controller, {
    void Function()? onClose,
    bool subscribe = false,
  }) {
    return StreamReader._(controller, onClose: onClose, subscribe: subscribe);
  }

  /// Initialize subscription if not already done
  void _ensureSubscription() {
    if (_subscription != null) return;

    _subscription = _controller.stream.listen(
      (item) {
        _queue.add(item);
        _itemAvailable?.complete();
        _itemAvailable = null;
      },
      onError: (Object error, StackTrace stackTrace) {
        _queue.add(StreamItem.error(error, stackTrace));
        _itemAvailable?.complete();
        _itemAvailable = null;
      },
      onDone: () {
        _streamDone = true;
        _itemAvailable?.complete();
        _itemAvailable = null;
      },
      cancelOnError: false,
    );
  }

  /// Receive the next item from the stream
  ///
  /// Returns the next chunk of data.
  /// Throws [StreamEOFException] when the stream ends.
  /// Throws [StreamClosedException] if called after close.
  /// Rethrows any error from the stream.
  Future<T> recv() async {
    if (_isClosed) {
      throw const StreamClosedException();
    }

    // Ensure we're subscribed to the stream
    _ensureSubscription();

    // Wait for items if queue is empty
    while (true) {
      // Check queue first
      if (_queue.isNotEmpty) {
        final item = _queue.removeFirst();

        if (item.hasError) {
          if (item.stackTrace != null) {
            Error.throwWithStackTrace(item.error!, item.stackTrace!);
          } else {
            throw item.error!;
          }
        }

        return item.chunk!;
      }

      // Stream ended and queue is empty
      if (_streamDone) {
        throw const StreamEOFException();
      }

      // Wait for next item
      _itemAvailable = Completer<void>();
      await _itemAvailable!.future;
    }
  }

  /// Receive all remaining items as a list
  ///
  /// Consumes the entire stream and returns all items.
  /// Throws on error.
  Future<List<T>> collectAll() async {
    final result = <T>[];

    try {
      while (true) {
        result.add(await recv());
      }
    } on StreamEOFException {
      // Expected end of stream
    }

    return result;
  }

  /// Convert this reader to a Dart Stream
  Stream<T> asStream() async* {
    try {
      while (true) {
        yield await recv();
      }
    } on StreamEOFException {
      // Expected end of stream
    }
  }

  /// Close the stream reader
  ///
  /// Should be called when done reading to free resources.
  Future<void> close() async {
    if (_isClosed) {
      return;
    }

    _isClosed = true;
    _onClose?.call();
    await _subscription?.cancel();
    await _controller.close();
    _completer.complete();
  }

  /// Wait for the stream to be closed
  Future<void> get done => _completer.future;

  /// Copy this stream reader into multiple independent readers
  ///
  /// The original reader becomes unusable after this operation.
  /// Each returned reader can independently consume the stream.
  List<StreamReader<T>> copy(int n) {
    if (n < 1) {
      return [];
    }

    if (n == 1) {
      return [this];
    }

    // Create n broadcast controllers for the copies
    final controllers = List.generate(
      n,
      (_) => StreamController<StreamItem<T>>.broadcast(),
    );

    // Broadcast items to all controllers
    _controller.stream.listen(
      (item) {
        for (final controller in controllers) {
          controller.add(item);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        for (final controller in controllers) {
          controller.add(StreamItem.error(error, stackTrace));
        }
      },
      onDone: () {
        for (final controller in controllers) {
          controller.close();
        }
      },
      cancelOnError: false,
    );

    // Mark this reader as closed since copies will handle consumption
    _isClosed = true;

    return controllers.map((c) => StreamReader._(c)).toList();
  }

  /// Transform elements using a converter function
  ///
  /// Return [NoValueException] from the converter to skip an element.
  StreamReader<R> transform<R>(R Function(T) converter) {
    final controller = StreamController<StreamItem<R>>.broadcast();

    _controller.stream.listen(
      (item) {
        if (item.hasError) {
          controller.add(StreamItem<R>.error(item.error!, item.stackTrace));
        } else if (item.chunk != null) {
          try {
            final converted = converter(item.chunk as T);
            controller.add(StreamItem.data(converted));
          } on NoValueException {
            // Skip this item
          } catch (e, st) {
            controller.add(StreamItem<R>.error(e, st));
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        controller.add(StreamItem<R>.error(error, stackTrace));
      },
      onDone: controller.close,
      cancelOnError: false,
    );

    return StreamReader<R>.fromController(controller);
  }
}
