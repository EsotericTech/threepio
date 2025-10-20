import 'dart:async';

import 'callback_handler.dart';
import 'run_info.dart';

/// Exception thrown when callback execution fails
class CallbackException implements Exception {
  CallbackException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause != null) {
      return 'CallbackException: $message\nCaused by: $cause';
    }
    return 'CallbackException: $message';
  }
}

/// Manages and orchestrates multiple callback handlers
///
/// The CallbackManager maintains a list of callback handlers and provides
/// convenience methods for triggering callbacks across all handlers.
/// It ensures callbacks are called in order and handles errors gracefully.
///
/// Example:
/// ```dart
/// final manager = CallbackManager([
///   LoggingHandler(),
///   MetricsHandler(),
///   TracingHandler(),
/// ]);
///
/// // Trigger callbacks
/// var context = <String, dynamic>{};
/// context = await manager.triggerStart(
///   context,
///   runInfo,
///   CallbackInput(input),
/// );
/// ```
class CallbackManager {
  CallbackManager([List<CallbackHandler>? handlers])
      : _handlers = List.from(handlers ?? []);

  final List<CallbackHandler> _handlers;

  /// Global handlers applied to all CallbackManagers
  static final List<CallbackHandler> _globalHandlers = [];

  /// Get all handlers (instance + global)
  List<CallbackHandler> get handlers => [..._handlers, ..._globalHandlers];

  /// Add a handler to this manager
  void addHandler(CallbackHandler handler) {
    _handlers.add(handler);
  }

  /// Remove a handler from this manager
  bool removeHandler(CallbackHandler handler) {
    return _handlers.remove(handler);
  }

  /// Add a global handler that applies to all managers
  static void addGlobalHandler(CallbackHandler handler) {
    _globalHandlers.add(handler);
  }

  /// Remove a global handler
  static bool removeGlobalHandler(CallbackHandler handler) {
    return _globalHandlers.remove(handler);
  }

  /// Clear all global handlers
  static void clearGlobalHandlers() {
    _globalHandlers.clear();
  }

  /// Create a copy with additional handlers
  CallbackManager withHandlers(List<CallbackHandler> additionalHandlers) {
    return CallbackManager([..._handlers, ...additionalHandlers]);
  }

  /// Trigger onStart callbacks across all handlers
  ///
  /// Calls each handler's onStart method in sequence, threading the context
  /// through each call. If any handler throws, the error is wrapped in a
  /// CallbackException but execution continues.
  ///
  /// Returns the final context after all handlers have run.
  Future<Map<String, dynamic>> triggerStart(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackInput input,
  ) async {
    var currentContext = context;

    for (final handler in handlers) {
      try {
        currentContext = await handler.onStart(currentContext, info, input);
      } catch (e, stackTrace) {
        // Log but don't fail - callbacks shouldn't break the main flow
        print(
            'Warning: Callback handler ${handler.runtimeType} failed in onStart: $e');
        print(stackTrace);
      }
    }

    return currentContext;
  }

  /// Trigger onEnd callbacks across all handlers
  ///
  /// Calls each handler's onEnd method in sequence, threading the context
  /// through each call.
  ///
  /// Returns the final context after all handlers have run.
  Future<Map<String, dynamic>> triggerEnd(
    Map<String, dynamic> context,
    RunInfo info,
    CallbackOutput output,
  ) async {
    var currentContext = context;

    for (final handler in handlers) {
      try {
        currentContext = await handler.onEnd(currentContext, info, output);
      } catch (e, stackTrace) {
        print(
            'Warning: Callback handler ${handler.runtimeType} failed in onEnd: $e');
        print(stackTrace);
      }
    }

    return currentContext;
  }

  /// Trigger onError callbacks across all handlers
  ///
  /// Calls each handler's onError method in sequence, threading the context
  /// through each call.
  ///
  /// Returns the final context after all handlers have run.
  Future<Map<String, dynamic>> triggerError(
    Map<String, dynamic> context,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) async {
    var currentContext = context;

    for (final handler in handlers) {
      try {
        currentContext = await handler.onError(
          currentContext,
          info,
          error,
          stackTrace,
        );
      } catch (e, st) {
        print(
            'Warning: Callback handler ${handler.runtimeType} failed in onError: $e');
        print(st);
      }
    }

    return currentContext;
  }

  /// Trigger onStartWithStreamInput callbacks
  ///
  /// Specialized method for components that accept streaming input.
  Future<Map<String, dynamic>> triggerStartWithStreamInput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> input,
  ) async {
    var currentContext = context;

    for (final handler in handlers) {
      try {
        currentContext = await handler.onStartWithStreamInput(
          currentContext,
          info,
          input,
        );
      } catch (e, stackTrace) {
        print(
            'Warning: Callback handler ${handler.runtimeType} failed in onStartWithStreamInput: $e');
        print(stackTrace);
      }
    }

    return currentContext;
  }

  /// Trigger onEndWithStreamOutput callbacks
  ///
  /// Specialized method for components that produce streaming output.
  /// Note: The stream is NOT consumed by this method.
  Future<Map<String, dynamic>> triggerEndWithStreamOutput(
    Map<String, dynamic> context,
    RunInfo info,
    Stream<dynamic> output,
  ) async {
    var currentContext = context;

    for (final handler in handlers) {
      try {
        currentContext = await handler.onEndWithStreamOutput(
          currentContext,
          info,
          output,
        );
      } catch (e, stackTrace) {
        print(
            'Warning: Callback handler ${handler.runtimeType} failed in onEndWithStreamOutput: $e');
        print(stackTrace);
      }
    }

    return currentContext;
  }

  /// Execute a function with automatic callback wrapping
  ///
  /// This is a convenience method that:
  /// 1. Triggers onStart before execution
  /// 2. Executes the function
  /// 3. Triggers onEnd on success
  /// 4. Triggers onError on failure
  /// 5. Re-throws any errors
  ///
  /// Example:
  /// ```dart
  /// final result = await manager.runWithCallbacks(
  ///   context,
  ///   runInfo,
  ///   input,
  ///   () async {
  ///     // Your component logic here
  ///     return await doSomething(input);
  ///   },
  /// );
  /// ```
  Future<T> runWithCallbacks<T>(
    Map<String, dynamic> context,
    RunInfo info,
    dynamic input,
    Future<T> Function() fn,
  ) async {
    var currentContext = context;

    try {
      // Trigger start
      currentContext = await triggerStart(
        currentContext,
        info,
        CallbackInput(input),
      );

      // Execute function
      final result = await fn();

      // Trigger end
      await triggerEnd(
        currentContext,
        info,
        CallbackOutput(result),
      );

      return result;
    } catch (error, stackTrace) {
      // Trigger error
      await triggerError(currentContext, info, error, stackTrace);

      // Re-throw to maintain error flow
      rethrow;
    }
  }

  /// Execute a streaming function with automatic callback wrapping
  ///
  /// Similar to runWithCallbacks but for functions that return streams.
  /// The returned stream is wrapped to trigger onEnd when complete.
  Stream<T> runStreamWithCallbacks<T>(
    Map<String, dynamic> context,
    RunInfo info,
    dynamic input,
    Stream<T> Function() fn,
  ) async* {
    var currentContext = context;

    try {
      // Trigger start
      currentContext = await triggerStart(
        currentContext,
        info,
        CallbackInput(input),
      );

      // Get the stream
      final stream = fn();

      // Trigger stream output callback
      await triggerEndWithStreamOutput(currentContext, info, stream);

      // Yield items and trigger end when done
      await for (final item in stream) {
        yield item;
      }

      // Trigger normal end callback after stream completes
      await triggerEnd(
        currentContext,
        info,
        const CallbackOutput(null, metadata: {'streamCompleted': true}),
      );
    } catch (error, stackTrace) {
      await triggerError(currentContext, info, error, stackTrace);
      rethrow;
    }
  }
}
