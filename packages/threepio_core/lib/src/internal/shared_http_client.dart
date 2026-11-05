import 'package:http/http.dart' as http;

/// The [http.Client] of a provider and of the copies it makes of itself
/// (`withTools`).
///
/// A client the caller injected is used as is and is never closed here: its
/// creator owns it. Without one, a single client is created on first use,
/// reused for every request and closed by [close].
final class SharedHttpClient {
  /// [owner] names the provider in the error for use after [close].
  SharedHttpClient(this._injected, {required String owner}) : _owner = owner;

  final http.Client? _injected;
  final String _owner;
  http.Client? _created;
  bool _isClosed = false;

  /// The client to send requests with.
  ///
  /// Throws a [StateError] after [close].
  http.Client get client {
    if (_isClosed) {
      throw StateError('$_owner was used after dispose()');
    }
    return _injected ?? (_created ??= http.Client());
  }

  /// Closes the client created here, if any. Safe to call repeatedly.
  void close() {
    _isClosed = true;
    _created?.close();
    _created = null;
  }
}
