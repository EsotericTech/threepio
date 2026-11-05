import 'dart:async';

import 'package:threepio_core/threepio_core.dart';

/// Listens to the events of a run from the moment it is created, so a test
/// can react to a particular event and inspect all of them afterwards.
class EventCollector {
  EventCollector(this.handle) {
    _subscription = handle.events.listen(
      _onEvent,
      onError: (Object error, StackTrace stackTrace) => errors.add(error),
      onDone: () {
        for (final waiter in _waiters) {
          waiter.fail(events);
        }
        _waiters.clear();
        _done.complete();
      },
    );
  }

  final RunHandle handle;

  /// Every event received so far, in order.
  final List<AgentEvent> events = [];

  /// Errors the event stream itself reported.
  final List<Object> errors = [];

  final List<_Waiter<AgentEvent>> _waiters = [];
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<AgentEvent> _subscription;

  /// The first event of type [T] accepted by [where], whether it has already
  /// arrived or is still to come.
  ///
  /// Fails if the run ends without such an event.
  Future<T> first<T extends AgentEvent>({bool Function(T event)? where}) {
    bool matches(AgentEvent event) =>
        event is T && (where == null || where(event));

    for (final event in events) {
      if (matches(event)) return Future.value(event as T);
    }

    final waiter = _Waiter<AgentEvent>(matches, '$T');
    _waiters.add(waiter);
    return waiter.completer.future.then((event) => event as T);
  }

  /// Completes with all events once the run has ended, then with its result.
  Future<(List<AgentEvent>, RunResult)> finished() async {
    await _done.future;
    return (List.of(events), await handle.result);
  }

  /// Stops listening.
  Future<void> cancel() => _subscription.cancel();

  void _onEvent(AgentEvent event) {
    events.add(event);
    _waiters.removeWhere((waiter) {
      if (!waiter.matches(event)) return false;
      waiter.completer.complete(event);
      return true;
    });
  }
}

class _Waiter<E> {
  _Waiter(this.matches, this.description);

  final bool Function(E event) matches;
  final String description;
  final Completer<E> completer = Completer<E>();

  void fail(List<AgentEvent> seen) {
    completer.completeError(
      StateError(
        'The run ended without a $description event. '
        'Events: ${seen.map((e) => e.eventType).join(', ')}',
      ),
    );
  }
}
