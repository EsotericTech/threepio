/// A callback handler put together from functions.
library;

import 'dart:async';

import '../core/run_context.dart';
import '../streaming/stream_reader.dart';
import 'callback_timing.dart';
import 'component_callback_handler.dart';
import 'run_info.dart';

/// The signature of a start or end hook.
typedef CallbackHook = FutureOr<RunContext> Function(
  RunContext ctx,
  RunInfo info,
  Object? payload,
);

/// The signature of an error hook.
typedef CallbackErrorHook = FutureOr<RunContext> Function(
  RunContext ctx,
  RunInfo info,
  Object error,
  StackTrace stackTrace,
);

/// The signature of a stream hook. The hook has to close [stream].
typedef CallbackStreamHook = FutureOr<RunContext> Function(
  RunContext ctx,
  RunInfo info,
  StreamReader<Object?> stream,
);

/// Builds a [ComponentCallbackHandler] from the functions it is given.
///
/// Port of eino `callbacks.HandlerBuilder`. Set the hooks you need and call
/// [build]:
///
/// ```dart
/// final handler = CallbackHandlerBuilder()
///     .onStart((ctx, info, input) {
///       log.info('${info.name} starts');
///       return ctx;
///     })
///     .onError((ctx, info, error, stackTrace) {
///       log.warning('${info.name} failed', error, stackTrace);
///       return ctx;
///     })
///     .build();
/// ```
///
/// The handler is a [TimingChecker] that asks for exactly the callbacks it
/// has a function for, so it never costs a stream copy it does not read.
final class CallbackHandlerBuilder {
  CallbackHook? _onStart;
  CallbackHook? _onEnd;
  CallbackErrorHook? _onError;
  CallbackStreamHook? _onStartWithStreamInput;
  CallbackStreamHook? _onEndWithStreamOutput;

  /// Sets the function called before a component runs.
  CallbackHandlerBuilder onStart(CallbackHook hook) {
    _onStart = hook;
    return this;
  }

  /// Sets the function called after a component has returned.
  CallbackHandlerBuilder onEnd(CallbackHook hook) {
    _onEnd = hook;
    return this;
  }

  /// Sets the function called after a component has failed.
  CallbackHandlerBuilder onError(CallbackErrorHook hook) {
    _onError = hook;
    return this;
  }

  /// Sets the function called before a component runs on a stream.
  ///
  /// The function is given its own copy of the stream and has to close it.
  CallbackHandlerBuilder onStartWithStreamInput(CallbackStreamHook hook) {
    _onStartWithStreamInput = hook;
    return this;
  }

  /// Sets the function called after a component has returned a stream.
  ///
  /// The function is given its own copy of the stream and has to close it.
  CallbackHandlerBuilder onEndWithStreamOutput(CallbackStreamHook hook) {
    _onEndWithStreamOutput = hook;
    return this;
  }

  /// The handler made of the functions set so far. Changing the builder
  /// afterwards does not change a handler it has built.
  ComponentCallbackHandler build() => _BuiltHandler(
        _onStart,
        _onEnd,
        _onError,
        _onStartWithStreamInput,
        _onEndWithStreamOutput,
      );
}

final class _BuiltHandler extends ComponentCallbackHandler
    implements TimingChecker {
  const _BuiltHandler(
    this._onStart,
    this._onEnd,
    this._onError,
    this._onStartWithStreamInput,
    this._onEndWithStreamOutput,
  );

  final CallbackHook? _onStart;
  final CallbackHook? _onEnd;
  final CallbackErrorHook? _onError;
  final CallbackStreamHook? _onStartWithStreamInput;
  final CallbackStreamHook? _onEndWithStreamOutput;

  @override
  bool needed(RunContext ctx, RunInfo info, CallbackTiming timing) =>
      switch (timing) {
        CallbackTiming.onStart => _onStart != null,
        CallbackTiming.onEnd => _onEnd != null,
        CallbackTiming.onError => _onError != null,
        CallbackTiming.onStartWithStreamInput =>
          _onStartWithStreamInput != null,
        CallbackTiming.onEndWithStreamOutput => _onEndWithStreamOutput != null,
      };

  @override
  FutureOr<RunContext> onStart(RunContext ctx, RunInfo info, Object? input) =>
      _onStart?.call(ctx, info, input) ?? ctx;

  @override
  FutureOr<RunContext> onEnd(RunContext ctx, RunInfo info, Object? output) =>
      _onEnd?.call(ctx, info, output) ?? ctx;

  @override
  FutureOr<RunContext> onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) =>
      _onError?.call(ctx, info, error, stackTrace) ?? ctx;

  @override
  FutureOr<RunContext> onStartWithStreamInput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> input,
  ) {
    final hook = _onStartWithStreamInput;
    return hook == null
        ? super.onStartWithStreamInput(ctx, info, input)
        : hook(ctx, info, input);
  }

  @override
  FutureOr<RunContext> onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) {
    final hook = _onEndWithStreamOutput;
    return hook == null
        ? super.onEndWithStreamOutput(ctx, info, output)
        : hook(ctx, info, output);
  }
}
