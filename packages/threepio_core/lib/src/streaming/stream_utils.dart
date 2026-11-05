import 'stream_item.dart';
import 'stream_reader.dart';
import 'stream_writer.dart';

/// Create a pipe with a reader and writer pair
///
/// Items sent by the writer are buffered in the reader until they are
/// received. Once the reader is closed, `send` returns `true` and drops the
/// item instead of failing.
///
/// [capacity] is accepted for API compatibility with Eino's `schema.Pipe`. The
/// buffer is unbounded and `send` never blocks.
///
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
  final reader = StreamReader<T>.buffered();
  return (reader, StreamWriter<T>.forReader(reader));
}

/// Merge multiple stream readers into a single reader
///
/// All source streams are read concurrently and items are emitted
/// as they arrive from any source. Closing the merged reader releases every
/// source.
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

  final merged = StreamReader<T>.buffered(
    onClose: () => _releaseAll(readers),
  );
  var activeCount = readers.length;

  for (final reader in readers) {
    reader.drainTo(
      onItem: merged.feed,
      onDone: () {
        activeCount--;
        if (activeCount == 0) {
          merged.feedDone();
        }
      },
    );
  }

  return merged;
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

  final merged = StreamReader<T>.buffered(
    onClose: () => _releaseAll(readers.values),
  );
  var activeCount = readers.length;

  for (final MapEntry(key: name, value: reader) in readers.entries) {
    reader.drainTo(
      onItem: merged.feed,
      onDone: () {
        // Emit SourceEOF for this specific stream
        merged.feed(StreamItem<T>.error(SourceEOFException(name)));

        activeCount--;
        if (activeCount == 0) {
          merged.feedDone();
        }
      },
    );
  }

  return merged;
}

/// Concatenate multiple stream readers sequentially
///
/// Reads from each stream in order, moving to the next stream
/// only after the previous one completes. Errors of a stream are passed on in
/// place and do not end it.
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

  final concatenated = StreamReader<T>.buffered(
    onClose: () => _releaseAll(readers),
  );

  // Take over one reader at a time, the next one when the previous has ended.
  void drainFrom(int index) {
    if (index == readers.length) {
      concatenated.feedDone();
      return;
    }

    readers[index].drainTo(
      onItem: concatenated.feed,
      onDone: () => drainFrom(index + 1),
    );
  }

  drainFrom(0);

  return concatenated;
}

/// Releases the sources of [readers] when the reader derived from them closes.
Future<void> _releaseAll<T>(Iterable<StreamReader<T>> readers) async {
  await Future.wait([for (final reader in readers) reader.release()]);
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
