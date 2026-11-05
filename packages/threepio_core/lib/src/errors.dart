/// The exception types every part of threepio shares.
library;

/// The base of the exceptions threepio throws for failures a caller is
/// expected to handle: a provider that answers with an error, a document that
/// cannot be loaded, a run that was cancelled, a graph that cannot continue.
///
/// Port of the role the `error` values Eino returns play. Catch it to treat
/// every failure reported by the framework in one place:
///
/// ```dart
/// try {
///   await model.generate(messages);
/// } on ThreepioException catch (error) {
///   log.warning(error.message);
/// }
/// ```
///
/// Three kinds of thrown objects are not threepio exceptions, on purpose:
///
/// * Mistakes in the calling code. They stay [ArgumentError], [StateError]
///   and [UnsupportedError], as everywhere in Dart, and are not meant to be
///   caught.
/// * The signals of a stream (`StreamEOFException`, `SourceEOFException`,
///   `NoValueException`). They steer a read loop and say nothing about a
///   failure.
/// * `InterruptSignal`. It pauses a run so that it can be resumed.
///
/// New exception types extend this class. Types that existed before it
/// implement it and keep their own fields.
class ThreepioException implements Exception {
  /// An exception that says [message], raised because of [cause] if there is
  /// one.
  const ThreepioException(this.message, {this.cause});

  /// What went wrong, in words meant for people.
  final String message;

  /// The error this exception was raised for, or `null` when it is not the
  /// consequence of another one.
  ///
  /// The counterpart of an error wrapped with `%w` in Go. Use [findCause] to
  /// look through a chain of causes.
  final Object? cause;

  /// The first object of type [T] among [error] and its causes, or `null`.
  ///
  /// The counterpart of Go's `errors.As`: code that wraps the errors of the
  /// work it started (a graph node, a tool call) keeps them reachable through
  /// [cause], and this is how a caller gets at the one it knows how to handle.
  ///
  /// ```dart
  /// final cancelled = ThreepioException.findCause<CancelledException>(error);
  /// ```
  static T? findCause<T extends Object>(Object? error) {
    // A chain is short. The limit only keeps a cycle from looping forever.
    var current = error;
    for (var depth = 0; depth < _maxCauseDepth && current != null; depth++) {
      if (current is T) return current;
      if (current is! ThreepioException) return null;
      current = current.cause;
    }
    return null;
  }

  static const _maxCauseDepth = 64;

  @override
  String toString() {
    final cause = this.cause;
    return cause == null
        ? 'ThreepioException: $message'
        : 'ThreepioException: $message\nCaused by: $cause';
  }
}

/// Input that is not in the form it has to be in: a template that cannot be
/// rendered, model output that does not parse, tool arguments that are not
/// the JSON the tool expects.
///
/// It is a [FormatException], so code that catches those keeps working, and a
/// [ThreepioException], so it is also caught with everything else threepio
/// reports.
class ThreepioFormatException extends FormatException
    implements ThreepioException {
  /// A format error that says [message].
  ///
  /// [source] is the text that could not be read and [offset] the position in
  /// it where reading failed, when they are known. [cause] is the error of
  /// the decoder that gave up, if there was one.
  const ThreepioFormatException(
    String message, {
    Object? source,
    int? offset,
    this.cause,
  }) : super(message, source, offset);

  @override
  final Object? cause;
}
