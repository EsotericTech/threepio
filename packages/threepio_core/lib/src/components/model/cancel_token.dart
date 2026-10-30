import 'dart:async';

/// Cooperative cancellation for model calls and agent runs.
///
/// Call [cancel] once; every listener sees [isCancelled] flip and
/// [whenCancelled] complete. Modelled on Eino's `context.Context` cancel.
class CancelToken {
  CancelToken();

  final Completer<void> _completer = Completer<void>();
  String? _reason;

  bool get isCancelled => _completer.isCompleted;
  String? get reason => _reason;

  /// Completes when [cancel] is called; never errors.
  Future<void> get whenCancelled => _completer.future;

  void cancel([String? reason]) {
    if (_completer.isCompleted) return;
    _reason = reason;
    _completer.complete();
  }

  /// Throws [CancelledException] if cancelled.
  void throwIfCancelled() {
    if (isCancelled) throw CancelledException(_reason);
  }
}

/// Thrown when work is abandoned because its [CancelToken] was cancelled.
class CancelledException implements Exception {
  const CancelledException([this.reason]);

  final String? reason;

  @override
  String toString() =>
      'CancelledException${reason != null ? '($reason)' : ''}';
}
