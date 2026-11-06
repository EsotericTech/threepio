/// The buffer of items a `TurnLoop` has been given and not processed yet.
///
/// Port of eino `adk/turn_buffer.go`.
library;

import 'dart:async';

import 'package:meta/meta.dart';

/// A queue of items with one waiting reader: [receive] waits until there is
/// an item, the buffer is closed, or [wakeup] is called.
///
/// Port of eino's unexported `turnBuffer` (a slice guarded by a mutex and a
/// condition variable).
@internal
final class TurnBuffer<T> {
  final List<T> _items = [];
  bool _closed = false;
  bool _woken = false;
  Completer<void>? _waiter;

  /// Whether [close] was called.
  bool get isClosed => _closed;

  /// The number of buffered items.
  int get length => _items.length;

  void _notify() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  /// Adds [value]; throws [StateError] when the buffer is closed. Port of
  /// `Send`.
  void send(T value) {
    if (_closed) throw StateError('turnBuffer: send on closed buffer');
    _items.add(value);
    _notify();
  }

  /// Adds [value]; `false` when the buffer is closed. Port of `TrySend`.
  bool trySend(T value) {
    if (_closed) return false;
    _items.add(value);
    _notify();
    return true;
  }

  /// The first item, waiting for one if there is none; `(false, null)` when
  /// the buffer is empty and closed, or when [wakeup] interrupted the wait.
  /// One reader at a time. Port of `Receive`.
  Future<(bool, T?)> receive() async {
    while (_items.isEmpty && !_closed && !_woken) {
      await (_waiter ??= Completer<void>()).future;
    }
    _woken = false;
    if (_items.isEmpty) return (false, null);
    return (true, _items.removeAt(0));
  }

  /// Closes the buffer: [receive] returns what is left, then `false`. Port of
  /// `Close`.
  void close() {
    if (_closed) return;
    _closed = true;
    _notify();
  }

  /// Takes every buffered item out. Port of `TakeAll`.
  List<T> takeAll() {
    final values = List<T>.of(_items);
    _items.clear();
    return values;
  }

  /// Puts [values] back in front, in their order. Port of `PushFront`.
  void pushFront(List<T> values) {
    if (values.isEmpty) return;
    _items.insertAll(0, values);
    _notify();
  }

  /// Makes a waiting (or the next) [receive] return without an item. Port of
  /// `Wakeup`.
  void wakeup() {
    _woken = true;
    _notify();
  }

  /// Forgets a [wakeup] nobody has seen yet. Port of `ClearWakeup`.
  void clearWakeup() => _woken = false;
}
