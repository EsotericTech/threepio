/// The contract of a callback handler.
library;

import 'dart:async';

import '../core/run_context.dart';
import '../streaming/stream_reader.dart';
import 'run_info.dart';

/// Watches the components of a run: called when one starts, ends or fails.
///
/// Port of eino `callbacks.Handler`. Extend it and override the hooks you
/// need; the others do nothing.
///
/// ```dart
/// final class Stopwatches extends ComponentCallbackHandler {
///   static final _started = ContextKey<DateTime>('started');
///
///   @override
///   RunContext onStart(RunContext ctx, RunInfo info, Object? input) =>
///       ctx.withValue(_started, DateTime.now());
///
///   @override
///   RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
///     final took = DateTime.now().difference(ctx.value(_started)!);
///     log.info('${info.name} took $took');
///     return ctx;
///   }
/// }
/// ```
///
/// **The context.** Every hook returns a context. What [onStart] (or
/// [onStartWithStreamInput]) returns is the context the component runs with,
/// and the one its end or error hook is called with later, so a value stored
/// there is how a handler recognises a call again. Return [ctx] itself when
/// there is nothing to add.
///
/// **Payloads.** [input] and [output] are what the component reports. A
/// component that fires its own callbacks reports a typed payload
/// (`ModelCallbackInput`, `ToolCallbackOutput`, ...); a graph that fires them
/// for a node reports the node's plain input and output. The `from` function
/// of each payload type accepts both: `ModelCallbackInput.from(input)`.
/// `HandlerHelper` does that conversion for you.
///
/// **Streams.** The stream hooks are given a copy of the stream that belongs
/// to the handler alone, and **the handler has to close it**, also when it
/// does not read it. Read it in the background and return at once: a hook
/// that waits for the end of the stream holds the component's caller up until
/// the stream is over.
///
/// **Errors.** A hook that throws does not fail the component: the error is
/// logged (logger `threepio.callbacks`) and the run goes on with the context
/// it had.
///
/// Implement `TimingChecker` as well to be left out of callbacks the handler
/// does not need.
abstract class ComponentCallbackHandler {
  /// Constant constructor, so that subclasses can have one.
  const ComponentCallbackHandler();

  /// Called before a component runs, with its [input].
  FutureOr<RunContext> onStart(RunContext ctx, RunInfo info, Object? input) =>
      ctx;

  /// Called after a component has returned its [output].
  FutureOr<RunContext> onEnd(RunContext ctx, RunInfo info, Object? output) =>
      ctx;

  /// Called after a component has failed with [error].
  FutureOr<RunContext> onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) =>
      ctx;

  /// Called before a component runs whose input is a stream.
  ///
  /// [input] is this handler's own copy of the stream; close it when done.
  /// The default implementation closes it unread.
  FutureOr<RunContext> onStartWithStreamInput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> input,
  ) async {
    await input.close();
    return ctx;
  }

  /// Called after a component has returned a stream as its output.
  ///
  /// [output] is this handler's own copy of the stream; close it when done.
  /// The default implementation closes it unread.
  FutureOr<RunContext> onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) async {
    await output.close();
    return ctx;
  }
}
