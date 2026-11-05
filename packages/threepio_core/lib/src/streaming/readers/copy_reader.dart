part of '../stream_reader.dart';

/// One element of the linked buffer the copies of a reader share.
///
/// Port of eino's `cpStreamElement`. A copy holds on to the element it reads
/// next, so an element lives exactly until the slowest copy has passed it.
final class _CopyNode<T> {
  /// The event of this position: `null` until a copy asks for it, the pending
  /// request while the source is being pulled, then the event itself.
  FutureOr<_Event<T>>? event;

  _CopyNode<T>? next;
}

/// The reader behind a set of copies; port of eino's `parentStreamReader`.
final class _CopySource<T> {
  _CopySource(this._source, this._open);

  final _Reader<T> _source;

  /// Copies that were not closed yet.
  int _open;

  /// The event at [node], pulling the source when no copy got that far yet.
  FutureOr<_Event<T>> eventAt(_CopyNode<T> node) {
    final known = node.event;
    if (known != null) return known;

    final requested = _source._request();
    node.event = requested;
    if (requested is Future<_Event<T>>) {
      unawaited(requested.then((event) => node.event = event));
    }
    return requested;
  }

  /// A copy was closed; the last one releases the source.
  FutureOr<void> copyClosed() {
    _open--;
    if (_open == 0) return _source._release();
  }
}

/// One of the readers returned by `copy`; port of eino's `childStreamReader`.
final class _CopyReader<T> extends _Reader<T> {
  _CopyReader(this._shared, _CopyNode<T> first) : _next = first;

  final _CopySource<T> _shared;

  /// The element this copy reads next; `null` once the copy was closed.
  _CopyNode<T>? _next;

  @override
  FutureOr<_Event<T>> _pull() {
    final node = _next;
    if (node == null) return _Event<T>.eof(_nextStamp());

    final event = _shared.eventAt(node);
    if (event is Future<_Event<T>>) {
      return event.then((event) => _advance(node, event));
    }
    return _advance(node, event);
  }

  /// Moves past [node], except at the end, where every copy stays.
  _Event<T> _advance(_CopyNode<T> node, _Event<T> event) {
    if (!event.isEof && identical(_next, node)) {
      _next = node.next ??= _CopyNode<T>();
    }
    return event;
  }

  @override
  FutureOr<void> _dispose() {
    _next = null;
    return _shared.copyClosed();
  }

  @override
  void setAutomaticClose() => _shared._source.setAutomaticClose();
}
