/// The callback handlers every run calls.
library;

import 'component_callback_handler.dart';

/// The callback handlers that are called for every component of every run,
/// whatever handlers the run itself was given.
///
/// Port of eino `callbacks.AppendGlobalHandlers`. Register the handlers once,
/// when the application starts (a tracing handler, for example):
///
/// ```dart
/// GlobalCallbacks.append([langfuseHandler]);
/// ```
///
/// A run takes the list as it is when its callbacks are set up; handlers
/// added later are seen by the runs that start after that. Global handlers
/// are called after the handlers of the run when a component ends or fails,
/// and before them when it starts.
///
/// This is one of the few pieces of global state in the library. Tests that
/// register handlers call [clear] when they are done.
abstract final class GlobalCallbacks {
  static final List<ComponentCallbackHandler> _handlers = [];

  /// The registered handlers, in the order they were added.
  static List<ComponentCallbackHandler> get handlers =>
      List.unmodifiable(_handlers);

  /// Whether no handler is registered.
  static bool get isEmpty => _handlers.isEmpty;

  /// Adds [handlers] after the ones already registered.
  static void append(Iterable<ComponentCallbackHandler> handlers) =>
      _handlers.addAll(handlers);

  /// Takes [handler] out again. Returns whether it was registered.
  static bool remove(ComponentCallbackHandler handler) =>
      _handlers.remove(handler);

  /// Removes every handler.
  static void clear() => _handlers.clear();
}
