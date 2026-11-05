import 'dart:async';

/// A lock for asynchronous critical sections.
///
/// Dart code runs on one thread, but a section that awaits can be entered by
/// another caller while the first one is suspended. [protect] runs sections
/// one at a time, in the order they were requested:
///
/// ```dart
/// final mutex = AsyncMutex();
///
/// Future<void> addInterest() => mutex.protect(() async {
///   final balance = await readBalance();
///   await writeBalance(balance * 1.01);
/// });
/// ```
///
/// The lock is not re-entrant: calling [protect] from inside a section of the
/// same mutex waits for itself and never completes.
final class AsyncMutex {
  /// Completes when the most recently requested section has finished.
  Future<void> _last = Future<void>.value();
  int _pending = 0;

  /// Whether a section is running or waiting to run.
  bool get isLocked => _pending > 0;

  /// Runs [action] after every section requested earlier has finished, and
  /// completes with its result.
  ///
  /// An error thrown by [action] goes to the caller of this method and does
  /// not keep later sections from running.
  Future<T> protect<T>(FutureOr<T> Function() action) async {
    final previous = _last;
    final finished = Completer<void>();
    _last = finished.future;
    _pending++;

    await previous;
    try {
      return await action();
    } finally {
      _pending--;
      finished.complete();
    }
  }
}
