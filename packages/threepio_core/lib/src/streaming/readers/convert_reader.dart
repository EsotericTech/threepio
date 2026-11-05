part of '../stream_reader.dart';

/// A reader that converts the items of [_source] as they are asked for.
///
/// Port of eino's `streamReaderWithConvert`.
final class _ConvertReader<S, T> extends _Reader<T> {
  _ConvertReader(this._source, this._convert, this._errWrapper, this._onEof);

  final _Reader<S> _source;
  final FutureOr<T> Function(S item) _convert;
  final Object? Function(Object error)? _errWrapper;
  final FutureOr<T?> Function()? _onEof;

  /// [_onEof] ran; the next end of the source is the end of this reader.
  bool _eofHandled = false;

  @override
  FutureOr<_Event<T>> _pull() {
    // Stays synchronous for as long as the source and the converter are, and
    // loops because the converter and the error wrapper can drop an event.
    while (true) {
      final requested = _source._request();
      if (requested is Future<_Event<S>>) return _pullAsync(requested);

      final handled = _handle(requested);
      if (handled is Future<_Event<T>?>) return _pullAsync(null, handled);
      if (handled != null) return handled;
    }
  }

  /// The rest of [_pull] once something has to be waited for: the request to
  /// the source, or else the event [handling] is turning into.
  Future<_Event<T>> _pullAsync(
    Future<_Event<S>>? requested, [
    Future<_Event<T>?>? handling,
  ]) async {
    var handled = handling ?? _handle(await requested!);
    while (true) {
      final event = handled is Future<_Event<T>?> ? await handled : handled;
      if (event != null) return event;

      final next = _source._request();
      handled = _handle(next is Future<_Event<S>> ? await next : next);
    }
  }

  /// What [event] of the source becomes here; `null` when it is dropped.
  FutureOr<_Event<T>?> _handle(_Event<S> event) {
    // Closed in the meantime: the source reports its end because it was let
    // go, and neither the converter nor onEof should hear of it.
    if (_released) return _Event<T>.eof(event.stamp);
    if (event.isEof) return _handleEof(event);

    final error = event.error;
    if (error != null) return _handleError(event, error);

    try {
      final converted = _convert(event.value as S);
      if (converted is Future<T>) {
        return converted.then<_Event<T>?>(
          (value) => _Event<T>.data(value, event.stamp),
          onError: (Object error, StackTrace stackTrace) =>
              _conversionFailed(error, stackTrace, event.stamp),
        );
      }
      return _Event<T>.data(converted, event.stamp);
    } catch (error, stackTrace) {
      return _conversionFailed(error, stackTrace, event.stamp);
    }
  }

  _Event<T>? _conversionFailed(Object error, StackTrace stackTrace, int stamp) {
    if (error is NoValueException) return null;
    return _Event<T>.error(error, stackTrace, stamp);
  }

  _Event<T>? _handleError(_Event<S> event, Object error) {
    final wrap = _errWrapper;
    if (wrap == null) return _Event<T>.error(error, event.stackTrace, event.stamp);

    try {
      final wrapped = wrap(error);
      if (wrapped == null) return null;
      return _Event<T>.error(
        wrapped,
        identical(wrapped, error) ? event.stackTrace : StackTrace.current,
        event.stamp,
      );
    } catch (wrapperError, stackTrace) {
      return _Event<T>.error(wrapperError, stackTrace, event.stamp);
    }
  }

  FutureOr<_Event<T>?> _handleEof(_Event<S> end) {
    final onEof = _onEof;
    if (onEof == null || _eofHandled) return _Event<T>.eof(end.stamp);
    _eofHandled = true;

    _Event<T> injected(T? value) => value == null
        ? _Event<T>.eof(end.stamp)
        : _Event<T>.data(value, end.stamp);

    _Event<T> failed(Object error, StackTrace stackTrace) =>
        error is StreamEOFException
            ? _Event<T>.eof(end.stamp)
            : _Event<T>.error(error, stackTrace, end.stamp);

    try {
      final value = onEof();
      if (value is Future<T?>) {
        return value.then<_Event<T>?>(injected, onError: failed);
      }
      return injected(value);
    } catch (error, stackTrace) {
      return failed(error, stackTrace);
    }
  }

  @override
  Future<void> _dispose() => _source._release();

  @override
  void setAutomaticClose() => _source.setAutomaticClose();
}
