/// Lambdas: functions as nodes of a graph.
///
/// Port of eino `compose/types_lambda.go`.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../callbacks/run_info.dart';
import '../core/run_context.dart';
import '../schema/message.dart';
import '../schema/message_parser.dart';
import '../streaming/stream_reader.dart';
import 'composable_runnable.dart';
import 'stream_conversion.dart';

/// How a lambda reports itself.
///
/// Port of eino `compose.LambdaOpt` (`WithLambdaType`,
/// `WithLambdaCallbackEnable`).
@immutable
final class LambdaOptions {
  /// The settings of a lambda.
  const LambdaOptions({this.type = '', this.callbacksEnabled = false});

  /// The implementation name the lambda's callbacks report as `RunInfo.type`.
  final String type;

  /// Whether the function fires its own callbacks (with `onStart` and the
  /// other functions of `callbacks.dart`). When `false`, the graph fires them
  /// around the lambda.
  final bool callbacksEnabled;
}

/// A function as a node of a graph, chain or workflow.
///
/// Port of eino `compose.Lambda`. A lambda is written for one of the four
/// ways to run a node, or for several of them ([Lambda.any]); the graph
/// derives the others (see `Runnable`):
///
/// ```dart
/// final upper = Lambda<String, String>.invokable(
///   (ctx, input) => input.toUpperCase(),
/// );
/// graph.addLambdaNode('upper', upper);
/// ```
///
/// [I] and [O] are the input and output type of the node. The graph checks
/// them against the neighbours of the node when edges are added.
///
/// The variants that also receive call options (`CallOption.lambda`) are the
/// static methods [invokableWithOption], [streamableWithOption],
/// [collectableWithOption], [transformableWithOption] and [anyWithOption]:
/// they have a third type argument, which a constructor cannot have.
final class Lambda<I, O> {
  Lambda._(this.executor);

  /// A lambda from a function that takes a value and returns a value. Port of
  /// eino `compose.InvokableLambda`.
  factory Lambda.invokable(
    FutureOr<O> Function(RunContext ctx, I input) fn, {
    LambdaOptions? options,
  }) =>
      _build<I, O, _NoOption>(
        options,
        invoke: (ctx, input, _) async => fn(ctx, input),
      );

  /// A lambda from a function that takes a value and returns a stream. Port
  /// of eino `compose.StreamableLambda`.
  factory Lambda.streamable(
    FutureOr<StreamReader<O>> Function(RunContext ctx, I input) fn, {
    LambdaOptions? options,
  }) =>
      _build<I, O, _NoOption>(
        options,
        stream: (ctx, input, _) async => fn(ctx, input),
      );

  /// A lambda from a function that takes a stream and returns a value. Port
  /// of eino `compose.CollectableLambda`.
  factory Lambda.collectable(
    FutureOr<O> Function(RunContext ctx, StreamReader<I> input) fn, {
    LambdaOptions? options,
  }) =>
      _build<I, O, _NoOption>(
        options,
        collect: (ctx, input, _) async => fn(ctx, input),
      );

  /// A lambda from a function that takes a stream and returns a stream. Port
  /// of eino `compose.TransformableLambda`.
  factory Lambda.transformable(
    FutureOr<StreamReader<O>> Function(RunContext ctx, StreamReader<I> input)
        fn, {
    LambdaOptions? options,
  }) =>
      _build<I, O, _NoOption>(
        options,
        transform: (ctx, input, _) async => fn(ctx, input),
      );

  /// A lambda from any non-empty subset of the four functions. Port of eino
  /// `compose.AnyLambda`.
  ///
  /// Throws [ArgumentError] when none is given.
  factory Lambda.any({
    FutureOr<O> Function(RunContext ctx, I input)? invoke,
    FutureOr<StreamReader<O>> Function(RunContext ctx, I input)? stream,
    FutureOr<O> Function(RunContext ctx, StreamReader<I> input)? collect,
    FutureOr<StreamReader<O>> Function(RunContext ctx, StreamReader<I> input)?
        transform,
    LambdaOptions? options,
  }) =>
      _build<I, O, _NoOption>(
        options,
        invoke: invoke == null ? null : (ctx, input, _) async => invoke(ctx, input),
        stream: stream == null ? null : (ctx, input, _) async => stream(ctx, input),
        collect:
            collect == null ? null : (ctx, input, _) async => collect(ctx, input),
        transform: transform == null
            ? null
            : (ctx, input, _) async => transform(ctx, input),
      );

  /// Like [Lambda.invokable] for a function that also takes the call options
  /// of type [TOption] aimed at it. Port of eino
  /// `compose.InvokableLambdaWithOption`.
  static Lambda<I, O> invokableWithOption<I, O, TOption>(
    FutureOr<O> Function(RunContext ctx, I input, List<TOption> options) fn, {
    LambdaOptions? options,
  }) =>
      _build<I, O, TOption>(
        options,
        invoke: (ctx, input, callOptions) async => fn(ctx, input, callOptions),
      );

  /// Port of eino `compose.StreamableLambdaWithOption`.
  static Lambda<I, O> streamableWithOption<I, O, TOption>(
    FutureOr<StreamReader<O>> Function(
      RunContext ctx,
      I input,
      List<TOption> options,
    ) fn, {
    LambdaOptions? options,
  }) =>
      _build<I, O, TOption>(
        options,
        stream: (ctx, input, callOptions) async => fn(ctx, input, callOptions),
      );

  /// Port of eino `compose.CollectableLambdaWithOption`.
  static Lambda<I, O> collectableWithOption<I, O, TOption>(
    FutureOr<O> Function(
      RunContext ctx,
      StreamReader<I> input,
      List<TOption> options,
    ) fn, {
    LambdaOptions? options,
  }) =>
      _build<I, O, TOption>(
        options,
        collect: (ctx, input, callOptions) async => fn(ctx, input, callOptions),
      );

  /// Port of eino `compose.TransformableLambdaWithOption`.
  static Lambda<I, O> transformableWithOption<I, O, TOption>(
    FutureOr<StreamReader<O>> Function(
      RunContext ctx,
      StreamReader<I> input,
      List<TOption> options,
    ) fn, {
    LambdaOptions? options,
  }) =>
      _build<I, O, TOption>(
        options,
        transform: (ctx, input, callOptions) async =>
            fn(ctx, input, callOptions),
      );

  /// Like [Lambda.any] for functions that also take call options of type
  /// [TOption]. Port of eino `compose.AnyLambda`.
  static Lambda<I, O> anyWithOption<I, O, TOption>({
    FutureOr<O> Function(RunContext ctx, I input, List<TOption> options)?
        invoke,
    FutureOr<StreamReader<O>> Function(
      RunContext ctx,
      I input,
      List<TOption> options,
    )? stream,
    FutureOr<O> Function(
      RunContext ctx,
      StreamReader<I> input,
      List<TOption> options,
    )? collect,
    FutureOr<StreamReader<O>> Function(
      RunContext ctx,
      StreamReader<I> input,
      List<TOption> options,
    )? transform,
    LambdaOptions? options,
  }) =>
      _build<I, O, TOption>(
        options,
        invoke: invoke == null
            ? null
            : (ctx, input, callOptions) async => invoke(ctx, input, callOptions),
        stream: stream == null
            ? null
            : (ctx, input, callOptions) async => stream(ctx, input, callOptions),
        collect: collect == null
            ? null
            : (ctx, input, callOptions) async =>
                collect(ctx, input, callOptions),
        transform: transform == null
            ? null
            : (ctx, input, callOptions) async =>
                transform(ctx, input, callOptions),
      );

  /// A lambda that wraps its input in a list of one. Port of eino
  /// `compose.ToList`.
  ///
  /// It bridges a node that gives one [I] to a node that takes a list, for
  /// instance a chat model and the next chat model. In a stream every chunk
  /// becomes a list of one chunk.
  static Lambda<I, List<I>> toList<I>({LambdaOptions? options}) =>
      _build<I, List<I>, _NoOption>(
        options,
        invoke: (ctx, input, _) async => [input],
        transform: (ctx, input, _) async =>
            input.convert<List<I>>((chunk) => [chunk]),
      );

  /// A lambda that parses a message into a [T] with [parser]. Port of eino
  /// `compose.MessageParser`.
  static Lambda<Message, T> messageParser<T>(
    MessageParser<T> parser, {
    LambdaOptions? options,
  }) =>
      _build<Message, T, _NoOption>(
        LambdaOptions(
          type: options == null || options.type.isEmpty
              ? 'MessageParse'
              : options.type,
          callbacksEnabled: options?.callbacksEnabled ?? false,
        ),
        invoke: (ctx, input, _) => parser.parse(ctx, input),
      );

  /// What a graph runs for this lambda.
  @internal
  final ComposableRunnable executor;

  static Lambda<I, O> _build<I, O, TOption>(
    LambdaOptions? options, {
    InvokeFn<I, O, TOption>? invoke,
    StreamFn<I, O, TOption>? stream,
    CollectFn<I, O, TOption>? collect,
    TransformFn<I, O, TOption>? transform,
  }) {
    final settings = options ?? const LambdaOptions();
    final executor = RunnablePacker<I, O, TOption>(
      invoke: invoke,
      stream: stream,
      collect: collect,
      transform: transform,
      enableCallbacks: !settings.callbacksEnabled,
    ).toComposableRunnable()
      ..meta = ExecutorMeta(
        component: ComponentType.lambda,
        isComponentCallbackEnabled: settings.callbacksEnabled,
        componentImplType: settings.type,
      );
    return Lambda<I, O>._(executor);
  }

  @override
  String toString() => 'Lambda<$I, $O>';
}

/// The option type of a lambda that takes no options: no call option is a
/// value of it, so none reaches the lambda.
final class _NoOption {
  const _NoOption._();
}
