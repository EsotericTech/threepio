/// The explicit run context that replaces Go's `context.Context`.
library;

import '../components/model/cancel_token.dart';

/// A typed key for a value stored in a [RunContext].
///
/// Keys are compared by identity, like the unexported key types Go code uses
/// with `context.WithValue`. Keep a key private to the library that owns the
/// value and expose typed accessors as an extension on [RunContext]:
///
/// ```dart
/// final _tenantKey = ContextKey<String>('tenant');
///
/// extension TenantContext on RunContext {
///   String? get tenant => value(_tenantKey);
///   RunContext withTenant(String tenant) => withValue(_tenantKey, tenant);
/// }
/// ```
///
/// Two `const` keys with the same type argument and the same [debugName] are
/// one and the same object. Give every `const` key its own name, or create
/// the key with `final` as above when it has to be unique no matter what.
final class ContextKey<T extends Object> {
  /// Creates a key. [debugName] only shows up in [toString].
  const ContextKey(this.debugName);

  /// A name for error messages and debugging; it does not identify the key.
  final String debugName;

  @override
  String toString() => 'ContextKey<$T>($debugName)';
}

/// What a call carries along: a cancellation token and typed values.
///
/// Port of the role `context.Context` plays in Eino. A context is immutable.
/// [withValue] and [withCancelToken] return a copy and leave the original, and
/// every other copy made from it, untouched, so a callee can never change what
/// its caller sees.
///
/// New APIs take the context as their first positional parameter
/// (`runnable.invoke(ctx, input)`). There is no ambient, zone-based context.
final class RunContext {
  /// The root context: no values, and [cancelToken] or a token of its own that
  /// is never cancelled by anyone else.
  RunContext.background({CancelToken? cancelToken})
      : cancelToken = cancelToken ?? CancelToken(),
        _values = const {};

  RunContext._(this.cancelToken, this._values);

  /// Cancels the work done under this context.
  ///
  /// Long-running operations check it between steps and stop with a
  /// [CancelledException].
  final CancelToken cancelToken;

  /// Identity-keyed and never modified after construction.
  final Map<ContextKey<Object>, Object> _values;

  /// The value stored under [key], or `null` when there is none.
  T? value<T extends Object>(ContextKey<T> key) => _values[key] as T?;

  /// A copy of this context in which [key] maps to [value].
  RunContext withValue<T extends Object>(ContextKey<T> key, T value) {
    final values = Map<ContextKey<Object>, Object>.identity()
      ..addAll(_values)
      ..[key] = value;
    return RunContext._(cancelToken, values);
  }

  /// A copy of this context that is cancelled through [token] instead.
  ///
  /// To keep the current token in effect as well, combine the two first:
  /// `ctx.withCancelToken(CancelToken.any([ctx.cancelToken, mine])!)`.
  RunContext withCancelToken(CancelToken token) => RunContext._(token, _values);

  @override
  String toString() {
    final keys = _values.keys.map((key) => key.debugName).join(', ');
    return 'RunContext(cancelled: ${cancelToken.isCancelled}, values: [$keys])';
  }
}
