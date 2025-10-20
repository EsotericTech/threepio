import 'package:freezed_annotation/freezed_annotation.dart';

part 'stream_item.freezed.dart';

/// Represents an item in a stream with optional error information
@freezed
class StreamItem<T> with _$StreamItem<T> {
  const factory StreamItem({
    /// The chunk of data (null for error-only items)
    T? chunk,

    /// Optional error associated with this chunk
    Object? error,

    /// Optional stack trace for the error
    StackTrace? stackTrace,
  }) = _StreamItem;

  const StreamItem._();

  /// Create a data item
  factory StreamItem.data(T chunk) => StreamItem(chunk: chunk);

  /// Create an error item without data
  factory StreamItem.error(Object error, [StackTrace? stackTrace]) =>
      StreamItem(
        chunk: null,
        error: error,
        stackTrace: stackTrace,
      );

  /// Check if this item contains an error
  bool get hasError => error != null;
}
