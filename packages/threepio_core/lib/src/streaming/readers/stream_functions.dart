part of '../stream_reader.dart';

/// Create a pipe with a reader and writer pair
///
/// Port of eino `schema.Pipe`. What the writer sends, the reader receives, in
/// order. Once the reader is closed, sending returns `true` and drops the
/// item instead of failing.
///
/// [capacity] is the number of items the pipe takes before
/// [StreamWriter.sendAsync] makes its caller wait for the reader; with `0`
/// every `sendAsync` waits until its item was received. [StreamWriter.send]
/// never waits and queues the item whatever the capacity.
///
/// Usage:
/// ```dart
/// final (reader, writer) = pipe<String>(capacity: 10);
///
/// // In sender
/// unawaited(() async {
///   try {
///     for (var i = 0; i < 5; i++) {
///       if (await writer.sendAsync('item $i')) break;
///     }
///   } finally {
///     await writer.close();
///   }
/// }());
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
  if (capacity < 0) {
    throw ArgumentError.value(capacity, 'capacity', 'must not be negative');
  }
  final channel = _Channel<T>(capacity);
  return (_QueueReader<T>(channel), StreamWriter<T>._(channel));
}

/// Merge multiple stream readers into a single reader
///
/// Port of eino `schema.MergeStreamReaders`. The merged reader reads at most
/// one item ahead from each source and delivers, of the items it has, the one
/// that arrived at its source first. Closing it releases every source.
///
/// An empty list gives an empty reader and a single reader is returned as it
/// is; otherwise the given readers are handed over and become unusable.
///
/// Usage:
/// ```dart
/// final reader1 = StreamReader.fromIterable([1, 2, 3]);
/// final reader2 = StreamReader.fromIterable([4, 5, 6]);
/// final merged = mergeStreamReaders([reader1, reader2]);
///
/// await for (final item in merged.asStream()) {
///   print(item);
/// }
/// ```
StreamReader<T> mergeStreamReaders<T>(List<StreamReader<T>> readers) {
  if (readers.isEmpty) {
    return StreamReader.fromIterable(<T>[]);
  }

  if (readers.length == 1) {
    return readers.first;
  }

  return _MergeReader<T>(_takeOverAll(readers));
}

/// Merge multiple named stream readers into a single reader
///
/// Port of eino `schema.MergeNamedStreamReaders`. Like [mergeStreamReaders],
/// and in addition `recv` throws a [SourceEOFException] carrying the name of
/// each source at the point where that source ends, before it goes on with
/// the others. [StreamEOFException] follows when all of them have ended.
///
/// Usage:
/// ```dart
/// final merged = mergeNamedStreamReaders({
///   'stream1': StreamReader.fromIterable([1, 2]),
///   'stream2': StreamReader.fromIterable([3, 4]),
/// });
///
/// while (true) {
///   try {
///     print(await merged.recv());
///   } on SourceEOFException catch (e) {
///     print('${e.sourceName} ended');
///   } on StreamEOFException {
///     break;
///   }
/// }
/// ```
StreamReader<T> mergeNamedStreamReaders<T>(
  Map<String, StreamReader<T>> readers,
) {
  if (readers.isEmpty) {
    return StreamReader.fromIterable(<T>[]);
  }

  return _MergeReader<T>(
    _takeOverAll(readers.values),
    names: readers.keys.toList(),
  );
}

/// Concatenate multiple stream readers sequentially
///
/// Reads from each stream in order, moving to the next stream
/// only after the previous one completes. Errors of a stream are passed on in
/// place and do not end it. Closing the returned reader releases every source.
///
/// An empty list gives an empty reader and a single reader is returned as it
/// is; otherwise the given readers are handed over and become unusable.
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

  return _ConcatReader<T>(_takeOverAll(readers));
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
/// Throw [NoValueException] from the converter to skip elements.
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
