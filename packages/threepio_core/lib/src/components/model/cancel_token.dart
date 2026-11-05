import 'dart:async';

/// Cooperative cancellation for model calls and agent runs.
///
/// Call [cancel] once; every listener sees [isCancelled] flip and
/// [whenCancelled] complete. Modelled on Eino's `context.Context` cancel.
class CancelToken {
  CancelToken();

  /// One token for a call that may be cancelled from several places.
  ///
  /// The result is cancelled as soon as any of [tokens] is, with the reason of
  /// the token that fired first (of the first one in [tokens] when several
  /// were cancelled already). `null` entries are ignored. A single token is
  /// returned as it is, and `null` when there is none at all.
  ///
  /// A model call can receive a token in `ChatModelOptions.cancelToken` and
  /// another one in its `RunContext`; this is how the two become the one
  /// token the call listens to.
  ///
  /// Cancelling the returned token does not cancel the tokens it was made
  /// from. They hold on to it until one of them, or it, is cancelled.
  static CancelToken? any(Iterable<CancelToken?> tokens) {
    final sources = <CancelToken>[];
    for (final token in tokens) {
      if (token != null && !sources.contains(token)) sources.add(token);
    }
    if (sources.isEmpty) return null;
    if (sources.length == 1) return sources.single;

    for (final source in sources) {
      if (source.isCancelled) return CancelToken()..cancel(source.reason);
    }
    return _AnyCancelToken(sources);
  }

  final Completer<void> _completer = Completer<void>();
  String? _reason;

  /// Tokens made from this one by [any]. They are cancelled in the same call
  /// that cancels this token, so that no check in between can miss it.
  List<CancelToken>? _dependents;

  bool get isCancelled => _completer.isCompleted;
  String? get reason => _reason;

  /// Completes when [cancel] is called; never errors.
  Future<void> get whenCancelled => _completer.future;

  void cancel([String? reason]) {
    if (_completer.isCompleted) return;
    _reason = reason;
    _completer.complete();

    final dependents = _dependents;
    if (dependents != null) {
      _dependents = null;
      for (final dependent in dependents) {
        dependent.cancel(reason);
      }
    }
  }

  /// Throws [CancelledException] if cancelled.
  void throwIfCancelled() {
    if (isCancelled) throw CancelledException(_reason);
  }
}

/// The token [CancelToken.any] returns for two or more live tokens.
final class _AnyCancelToken extends CancelToken {
  _AnyCancelToken(this._sources) {
    for (final source in _sources) {
      (source._dependents ??= []).add(this);
    }
  }

  final List<CancelToken> _sources;

  @override
  void cancel([String? reason]) {
    if (isCancelled) return;
    // Whoever cancelled this token, the others need not remember it.
    for (final source in _sources) {
      source._dependents?.remove(this);
    }
    super.cancel(reason);
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
