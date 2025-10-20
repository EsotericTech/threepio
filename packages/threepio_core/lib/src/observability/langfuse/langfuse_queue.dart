/// Event queue for buffering Langfuse events before batch processing
///
/// **Framework Source: Eino (CloudWeGo)** - Queue implementation patterns

import 'dart:async';
import 'dart:collection';

import 'models/langfuse_event.dart';

/// Thread-safe queue for buffering events
///
/// Provides:
/// - Bounded queue with configurable max size
/// - Non-blocking put (returns false if full)
/// - Blocking get with timeout
/// - Join mechanism to wait for all tasks to complete
class LangfuseEventQueue {
  final int _maxSize;
  final Queue<LangfuseIngestionEvent> _queue = Queue();
  final _controller = StreamController<LangfuseIngestionEvent>.broadcast();
  int _unfinished = 0;
  final _emptyCompleter = Completer<void>();

  LangfuseEventQueue(int maxSize) : _maxSize = maxSize > 0 ? maxSize : 100;

  /// Add an event to the queue
  ///
  /// Returns true if added successfully, false if queue is full
  bool put(LangfuseIngestionEvent event) {
    if (_queue.length >= _maxSize) {
      return false;
    }

    _queue.add(event);
    _unfinished++;
    _controller.add(event);
    return true;
  }

  /// Get an event from the queue with timeout
  ///
  /// Returns the event or null if timeout expires
  Future<LangfuseIngestionEvent?> get(Duration timeout) async {
    if (_queue.isNotEmpty) {
      return _queue.removeFirst();
    }

    try {
      return await _controller.stream.first.timeout(timeout,
          onTimeout: () => throw TimeoutException('Queue timeout'));
    } on TimeoutException {
      return null;
    }
  }

  /// Mark a task as done
  ///
  /// Should be called after processing each event from get()
  void done() {
    if (_unfinished > 0) {
      _unfinished--;
      if (_unfinished == 0 && !_emptyCompleter.isCompleted) {
        _emptyCompleter.complete();
      }
    }
  }

  /// Wait for all tasks to be processed
  ///
  /// Blocks until all events added with put() have been processed with done()
  Future<void> join() async {
    if (_unfinished == 0) {
      return;
    }
    await _emptyCompleter.future;
  }

  /// Get current queue length
  int get length => _queue.length;

  /// Get number of unfinished tasks
  int get unfinished => _unfinished;

  /// Dispose resources
  Future<void> dispose() async {
    await _controller.close();
  }
}
