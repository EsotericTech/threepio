/// The functions a component fires its callbacks with.
///
/// Port of eino `callbacks/aspect_inject.go`.
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../core/run_context.dart';
import '../streaming/stream_reader.dart';
import 'callback_context.dart';
import 'callback_timing.dart';
import 'component_callback_handler.dart';
import 'run_info.dart';

final _log = Logger('threepio.callbacks');

/// Tells the handlers of [ctx] that the component is about to run with
/// [input], and returns the context the component goes on with.
///
/// Port of eino `callbacks.OnStart`. A component that fires its own callbacks
/// brackets its work like this:
///
/// ```dart
/// var ctx = ensureRunInfo(callerCtx, componentTypeName, ComponentType.tool);
/// ctx = await onStart(ctx, input);
/// try {
///   final output = await work(ctx, input);
///   await onEnd(ctx, output);
///   return output;
/// } catch (error, stackTrace) {
///   await onError(ctx, error, stackTrace);
///   rethrow;
/// }
/// ```
///
/// The handlers are called last to first (the global ones before the ones of
/// the run), each with the context the one before returned. The run info the
/// context was given by `ensureRunInfo` or `reuseHandlers` is used up by this
/// call: a component run inside has to report itself before it fires its own
/// start callback.
///
/// On a context without callbacks this does nothing and returns [ctx].
Future<RunContext> onStart(RunContext ctx, Object? input) async {
  if (handlerChainOf(ctx) == null) return ctx;
  const timing = CallbackTiming.onStart;
  return _fire(ctx, timing, start: true, (ctx, info, handlers) async {
    var current = ctx;
    for (final handler in handlers.reversed) {
      current = await _guarded(
        handler,
        timing,
        current,
        (ctx) => handler.onStart(ctx, info, input),
      );
    }
    return current;
  });
}

/// Tells the handlers of [ctx] that the component has returned [output].
///
/// Port of eino `callbacks.OnEnd`. [ctx] is the context [onStart] returned.
/// The handlers are called first to last, the global ones at the end.
Future<RunContext> onEnd(RunContext ctx, Object? output) async {
  if (handlerChainOf(ctx) == null) return ctx;
  const timing = CallbackTiming.onEnd;
  return _fire(ctx, timing, start: false, (ctx, info, handlers) async {
    var current = ctx;
    for (final handler in handlers) {
      current = await _guarded(
        handler,
        timing,
        current,
        (ctx) => handler.onEnd(ctx, info, output),
      );
    }
    return current;
  });
}

/// [onEnd] for an output that every handler needs a copy of its own of, such
/// as an object that holds a stream.
///
/// Port of eino's internal `callbacks.BuildOnEndHandleWithCopy`. [copy] is
/// called once, when at least one handler wants the callback, with the number
/// of handlers, and returns that many copies of [output]; each handler gets
/// one. [output] itself is spent by the copying.
Future<RunContext> onEndWithCopies<T>(
  RunContext ctx,
  T output,
  List<T> Function(T output, int count) copy,
) async {
  if (handlerChainOf(ctx) == null) return ctx;
  const timing = CallbackTiming.onEnd;
  return _fire(ctx, timing, start: false, (ctx, info, handlers) async {
    if (handlers.isEmpty) return ctx;
    final copies = copy(output, handlers.length);
    var current = ctx;
    for (final (index, handler) in handlers.indexed) {
      current = await _guarded(
        handler,
        timing,
        current,
        (ctx) => handler.onEnd(ctx, info, copies[index]),
      );
    }
    return current;
  });
}

/// Tells the handlers of [ctx] that the component has failed with [error].
///
/// Port of eino `callbacks.OnError`. [ctx] is the context [onStart] returned.
/// The error itself still has to be rethrown by the component.
Future<RunContext> onError(
  RunContext ctx,
  Object error,
  StackTrace stackTrace,
) async {
  if (handlerChainOf(ctx) == null) return ctx;
  const timing = CallbackTiming.onError;
  return _fire(ctx, timing, start: false, (ctx, info, handlers) async {
    var current = ctx;
    for (final handler in handlers) {
      current = await _guarded(
        handler,
        timing,
        current,
        (ctx) => handler.onError(ctx, info, error, stackTrace),
      );
    }
    return current;
  });
}

/// Tells the handlers of [ctx] that the component is about to run with the
/// stream [input], and returns the context and the stream the component goes
/// on with.
///
/// Port of eino `callbacks.OnStartWithStreamInput`. [input] is handed over:
/// every handler that wants the callback gets a copy of its own and the
/// component reads the returned reader instead. Without such a handler the
/// returned reader is [input] itself.
Future<(RunContext, StreamReader<T>)> onStartWithStreamInput<T>(
  RunContext ctx,
  StreamReader<T> input,
) async {
  if (handlerChainOf(ctx) == null) return (ctx, input);
  const timing = CallbackTiming.onStartWithStreamInput;
  var stream = input;
  final next = await _fire(ctx, timing, start: true, (ctx, info, handlers) async {
    final (current, rest) = await _withCopies<T>(
      ctx,
      input,
      handlers.reversed.toList(growable: false),
      timing,
      (ctx, handler, copy) => handler.onStartWithStreamInput(ctx, info, copy),
    );
    stream = rest;
    return current;
  });
  return (next, stream);
}

/// Tells the handlers of [ctx] that the component has returned the stream
/// [output], and returns the context and the stream to give to the caller.
///
/// Port of eino `callbacks.OnEndWithStreamOutput`. [output] is handed over:
/// every handler that wants the callback gets a copy of its own and the
/// caller reads the returned reader instead. Without such a handler the
/// returned reader is [output] itself.
Future<(RunContext, StreamReader<T>)> onEndWithStreamOutput<T>(
  RunContext ctx,
  StreamReader<T> output,
) async {
  if (handlerChainOf(ctx) == null) return (ctx, output);
  const timing = CallbackTiming.onEndWithStreamOutput;
  var stream = output;
  final next = await _fire(ctx, timing, start: false, (ctx, info, handlers) async {
    final (current, rest) = await _withCopies<T>(
      ctx,
      output,
      handlers,
      timing,
      (ctx, handler, copy) => handler.onEndWithStreamOutput(ctx, info, copy),
    );
    stream = rest;
    return current;
  });
  return (next, stream);
}

/// Port of eino's internal `callbacks.On`: works out the run info and the
/// handlers that want [timing], lets [handle] call them, and returns the
/// context for what comes next.
Future<RunContext> _fire(
  RunContext ctx,
  CallbackTiming timing,
  Future<RunContext> Function(
    RunContext ctx,
    RunInfo info,
    List<ComponentCallbackHandler> handlers,
  ) handle, {
  required bool start,
}) async {
  final chain = handlerChainOf(ctx);
  if (chain == null) return ctx;

  var current = ctx;
  var next = chain;
  final RunInfo? known;
  if (start) {
    // The pending run info belongs to this component. It is remembered for
    // the end callback and taken off the chain, so that a component run
    // inside does not report under this one's name.
    known = chain.runInfo;
    next = chain.withRunInfo(null);
    current = withStartedRunInfo(current, known);
  } else {
    known = chain.runInfo ?? startedRunInfoOf(ctx);
  }
  final info = known ?? RunInfo.unknown;

  final handlers = [
    for (final handler in chain.all)
      if (_wants(handler, current, info, timing)) handler,
  ];

  current = await handle(current, info, handlers);
  return withHandlerChain(current, next);
}

/// Whether [handler] is to be called at [timing]. A handler that is not a
/// [TimingChecker] is called every time; one whose check throws is logged
/// and left out.
bool _wants(
  Object handler,
  RunContext ctx,
  RunInfo info,
  CallbackTiming timing,
) {
  if (handler is! TimingChecker) return true;
  try {
    return handler.needed(ctx, info, timing);
    // ignore: avoid_catches_without_on_clauses
  } catch (error, stackTrace) {
    _log.warning(
      'Callback handler ${handler.runtimeType} failed in needed '
      '(${timing.name})',
      error,
      stackTrace,
    );
    return false;
  }
}

/// Calls one hook. A hook that throws is logged and changes nothing.
Future<RunContext> _guarded(
  ComponentCallbackHandler handler,
  CallbackTiming timing,
  RunContext ctx,
  FutureOr<RunContext> Function(RunContext ctx) hook,
) async {
  try {
    return await hook(ctx);
    // A handler observes a run. Whatever goes wrong in it, the run goes on.
    // ignore: avoid_catches_without_on_clauses
  } catch (error, stackTrace) {
    _log.warning(
      'Callback handler ${handler.runtimeType} failed in ${timing.name}',
      error,
      stackTrace,
    );
    return ctx;
  }
}

/// Port of eino's internal `callbacks.OnWithStreamHandle`: one copy of
/// [stream] per handler and one more for whoever reads the stream itself.
Future<(RunContext, StreamReader<T>)> _withCopies<T>(
  RunContext ctx,
  StreamReader<T> stream,
  List<ComponentCallbackHandler> handlers,
  CallbackTiming timing,
  FutureOr<RunContext> Function(
    RunContext ctx,
    ComponentCallbackHandler handler,
    StreamReader<T> copy,
  ) hook,
) async {
  if (handlers.isEmpty) return (ctx, stream);

  final copies = stream.copy(handlers.length + 1);
  var current = ctx;
  for (final (index, handler) in handlers.indexed) {
    final copy = copies[index];
    try {
      current = await hook(current, handler, copy);
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      _log.warning(
        'Callback handler ${handler.runtimeType} failed in ${timing.name}',
        error,
        stackTrace,
      );
      // The handler will not read its copy any more. Left open, it would
      // keep every item of the stream in memory and the source from being
      // released.
      await copy.close();
    }
  }
  return (current, copies.last);
}
