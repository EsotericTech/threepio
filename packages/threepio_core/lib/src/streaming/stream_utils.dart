import 'dart:async';

import 'stream_item.dart';
import 'stream_reader.dart';
import 'stream_writer.dart';

/// Create a pipe with a reader and writer pair
///
/// The capacity parameter specifies the buffer size for the stream.
/// Usage:
/// ```dart
/// final (reader, writer) = pipe<String>(capacity: 10);
///
/// // In sender
/// await Future(() async {
///   try {
///     for (var i = 0; i < 5; i++) {
///       writer.send('item $i');
///     }
///   } finally {
///     await writer.close();
///   }
/// });
///
/// // In receiver
/// try {
///   while (true) {
///     final item = await reader.recv();
///     print(item);
///   }
/// } on StreamEOFException {
///   // End of stream
/// } finally {
///   await reader.close();
/// }
/// ```
(StreamReader<T>, StreamWriter<T>) pipe<T>({int capacity = 0}) {
  final controller = StreamController<StreamItem<T>>.broadcast(
    // Use sync mode for unbuffered
    sync: capacity == 0,
  );

  int closeCount = 0;
  final closeLock = <void>[];

  void onClose() {
    closeCount++;
    if (closeCount == 2) {
      // Both reader and writer are closed
      closeLock.clear();
    }
  }

  final reader = StreamReader<T>.fromController(
    controller,
    onClose: onClose,
    subscribe:
        true, // Subscribe immediately to avoid missing events from writer
  );
  final writer = StreamWriter<T>.fromController(controller);

  return (reader, writer);
}

/// Merge multiple stream readers into a single reader
///
/// All source streams are read concurrently and items are emitted
/// as they arrive from any source.
///
/// Usage:
/// ```dart
/// final reader1 = StreamReader.fromIterable([1, 2, 3]);
/// final reader2 = StreamReader.fromIterable([4, 5, 6]);
/// final merged = mergeStreamReaders([reader1, reader2]);
///
/// await for (final item in merged.asStream()) {
///   print(item); // Items from both streams interleaved
/// }
/// ```
StreamReader<T> mergeStreamReaders<T>(List<StreamReader<T>> readers) {
  if (readers.isEmpty) {
    return StreamReader.fromIterable(<T>[]);
  }

  if (readers.length == 1) {
    return readers.first;
  }

  final controller = StreamController<StreamItem<T>>.broadcast();
  final subscriptions = <StreamSubscription<StreamItem<T>>>[];
  var activeCount = readers.length;

  for (final reader in readers) {
    final subscription = reader.controller.stream.listen(
      controller.add,
      onError: (Object error, StackTrace stackTrace) {
        controller.add(StreamItem<T>.error(error, stackTrace));
      },
      onDone: () {
        activeCount--;
        if (activeCount == 0) {
          controller.close();
        }
      },
      cancelOnError: false,
    );
    subscriptions.add(subscription);
  }

  // Clean up subscriptions when the merged reader is closed
  void onClose() {
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
  }

  return StreamReader<T>.fromController(controller, onClose: onClose);
}

/// Merge multiple named stream readers into a single reader
///
/// When a source stream ends, a [SourceEOFException] with the source name
/// is emitted before continuing with other streams.
///
/// Usage:
/// ```dart
/// final streams = {
///   'stream1': StreamReader.fromIterable([1, 2]),
///   'stream2': StreamReader.fromIterable([3, 4]),
/// };
/// final merged = mergeNamedStreamReaders(streams);
///
/// try {
///   while (true) {
///     final item = await merged.recv();
///     print(item);
///   }
/// } on SourceEOFException catch (e) {
///   print('${e.sourceName} ended');
/// } on StreamEOFException {
///   print('All streams ended');
/// }
/// ```
StreamReader<T> mergeNamedStreamReaders<T>(
    Map<String, StreamReader<T>> readers) {
  if (readers.isEmpty) {
    return StreamReader.fromIterable(<T>[]);
  }

  if (readers.length == 1) {
    return readers.values.first;
  }

  final controller = StreamController<StreamItem<T>>.broadcast();
  final subscriptions = <String, StreamSubscription<StreamItem<T>>>{};
  var activeCount = readers.length;

  for (final entry in readers.entries) {
    final name = entry.key;
    final reader = entry.value;

    final subscription = reader.controller.stream.listen(
      controller.add,
      onError: (Object error, StackTrace stackTrace) {
        controller.add(StreamItem<T>.error(error, stackTrace));
      },
      onDone: () {
        // Emit SourceEOF for this specific stream
        controller.add(
          StreamItem<T>.error(SourceEOFException(name)),
        );

        activeCount--;
        if (activeCount == 0) {
          controller.close();
        }
      },
      cancelOnError: false,
    );
    subscriptions[name] = subscription;
  }

  // Clean up subscriptions when the merged reader is closed
  void onClose() {
    for (final subscription in subscriptions.values) {
      subscription.cancel();
    }
  }

  return StreamReader<T>.fromController(controller, onClose: onClose);
}

/// Concatenate multiple stream readers sequentially
///
/// Reads from each stream in order, moving to the next stream
/// only after the previous one completes.
///
/// Usage:
/// ```dart
/// final reader1 = StreamReader.fromIterable([1, 2, 3]);
/// final reader2 = StreamReader.fromIterable([4, 5, 6]);
/// final concatenated = concatStreamReaders([reader1, reader2]);
///
/// final all = await concatenated.collectAll();
/// print(all); // [1, 2, 3, 4, 5, 6]
/// ```
StreamReader<T> concatStreamReaders<T>(List<StreamReader<T>> readers) {
  if (readers.isEmpty) {
    return StreamReader.fromIterable(<T>[]);
  }

  if (readers.length == 1) {
    return readers.first;
  }

  final controller = StreamController<StreamItem<T>>.broadcast();

  Future<void> processReaders() async {
    for (final reader in readers) {
      // Use recv() to read all items from this reader
      try {
        while (true) {
          final item = await reader.recv();
          controller.add(StreamItem.data(item));
        }
      } on StreamEOFException {
        // This reader is done, move to next
      } catch (e, st) {
        // Propagate other errors
        controller.add(StreamItem<T>.error(e, st));
      }
    }
    await controller.close();
  }

  // Start processing in the background
  processReaders();

  return StreamReader<T>.fromController(controller);
}

/// Copy a stream reader into multiple independent readers
///
/// This is a convenience function that calls [StreamReader.copy].
/// The original reader becomes unusable after this operation.
///
/// Usage:
/// ```dart
/// final original = StreamReader.fromIterable([1, 2, 3]);
/// final copies = copyStreamReader(original, 3);
///
/// final results = await Future.wait([
///   copies[0].collectAll(),
///   copies[1].collectAll(),
///   copies[2].collectAll(),
/// ]);
/// // Each result will be [1, 2, 3]
/// ```
List<StreamReader<T>> copyStreamReader<T>(StreamReader<T> reader, int n) {
  return reader.copy(n);
}

/// Transform a stream reader using a converter function
///
/// This is a convenience function that calls [StreamReader.transform].
/// Return [NoValueException] from converter to skip elements.
///
/// Usage:
/// ```dart
/// final reader = StreamReader.fromIterable([1, 2, 3, 4, 5]);
/// final doubled = transformStreamReader(
///   reader,
///   (x) => x * 2,
/// );
///
/// final result = await doubled.collectAll();
/// print(result); // [2, 4, 6, 8, 10]
/// ```
StreamReader<R> transformStreamReader<T, R>(
  StreamReader<T> reader,
  R Function(T) converter,
) {
  return reader.transform<R>(converter);
}
