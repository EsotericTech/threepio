/// The four ways to run something, and how each is derived from the others.
///
/// Port of the conversion half of eino `compose/runnable.go` and of
/// `compose/stream_concat.go`.
@internal
library;

import 'package:meta/meta.dart';

import '../callbacks/component_callbacks.dart' as callbacks;
import '../core/run_context.dart';
import '../schema/concat.dart';
import '../streaming/stream_reader.dart';
import 'composable_runnable.dart';
import 'errors.dart';
import 'type_ref.dart';

/// Value in, value out. Port of eino `Invoke`.
typedef InvokeFn<I, O, TOption> = Future<O> Function(
  RunContext ctx,
  I input,
  List<TOption> options,
);

/// Value in, stream out. Port of eino `Stream`.
typedef StreamFn<I, O, TOption> = Future<StreamReader<O>> Function(
  RunContext ctx,
  I input,
  List<TOption> options,
);

/// Stream in, value out. Port of eino `Collect`.
typedef CollectFn<I, O, TOption> = Future<O> Function(
  RunContext ctx,
  StreamReader<I> input,
  List<TOption> options,
);

/// Stream in, stream out. Port of eino `Transform`.
typedef TransformFn<I, O, TOption> = Future<StreamReader<O>> Function(
  RunContext ctx,
  StreamReader<I> input,
  List<TOption> options,
);

/// Reads [stream] to its end, closes it, and joins the chunks into one value.
///
/// Port of eino `concatStreamReader`. The end-of-source markers of a named
/// merge are skipped. One chunk is returned as it is; several are joined with
/// the function [StreamConcat] has for them. Throws [StreamReadException] when
/// the stream is empty or fails.
///
/// With [ignoreError] (eino `concatStreamReaderWithErrorFilter`), an error in
/// the stream for which it returns `true` ends the reading as the end of the
/// stream would.
Future<T> concatStreamReader<T>(
  StreamReader<T> stream, {
  bool Function(Object error)? ignoreError,
}) async {
  final items = <T>[];
  try {
    while (true) {
      try {
        items.add(await stream.recv());
      } on StreamEOFException {
        break;
      } on SourceEOFException {
        continue;
        // Whatever the stream fails with is reported as a read failure.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        if (ignoreError != null && ignoreError(error)) break;
        Error.throwWithStackTrace(
          StreamReadException(
            'failed to read from stream. error: ${_text(error)}',
            cause: error,
          ),
          stackTrace,
        );
      }
    }
  } finally {
    await stream.close();
  }

  if (items.isEmpty) throw const StreamReadException.empty();
  if (items.length == 1) return items.single;
  return concatItems<T>(items);
}

/// Joins the chunks of a stream of [T].
///
/// `null` chunks carry nothing and are left out.
T concatItems<T>(List<T> items) {
  final present = [
    for (final item in items)
      if (item != null) item as Object,
  ];
  if (present.isEmpty) return items.first;
  final Object? joined =
      present.length == 1 ? present.single : StreamConcat.concatItems(present);
  if (joined is T) return joined;
  throw ComposeTypeException(
    'the chunks of a stream of $T were joined into a ${joined.runtimeType}; '
    'register a function for $T with StreamConcat.register',
  );
}

String _text(Object error) =>
    error is StreamReadException ? error.message : error.toString();

/// The options of a call as the list of [TOption] a node takes.
///
/// Port of eino `convertOption`.
List<TOption> convertOptions<TOption>(List<Object?> options) {
  if (options.isEmpty) return const [];
  return [
    for (final option in options)
      if (option is TOption)
        option
      else
        throw ComposeTypeException(
          'unexpected component option type, expected: $TOption, '
          'actual: ${option.runtimeType}',
        ),
  ];
}

/// [fn] with the callbacks of its component fired around it.
///
/// Port of eino `invokeWithCallbacks`.
InvokeFn<I, O, TOption> invokeWithCallbacks<I, O, TOption>(
  InvokeFn<I, O, TOption> fn,
) =>
    (ctx, input, options) async {
      final started = await callbacks.onStart(ctx, input);
      final O output;
      try {
        output = await fn(started, input, options);
        // Reported to the handlers and thrown on.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        await callbacks.onError(started, error, stackTrace);
        rethrow;
      }
      await callbacks.onEnd(started, output);
      return output;
    };

/// Port of eino `streamWithCallbacks`.
StreamFn<I, O, TOption> streamWithCallbacks<I, O, TOption>(
  StreamFn<I, O, TOption> fn,
) =>
    (ctx, input, options) async {
      final started = await callbacks.onStart(ctx, input);
      final StreamReader<O> output;
      try {
        output = await fn(started, input, options);
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        await callbacks.onError(started, error, stackTrace);
        rethrow;
      }
      final (_, rest) =
          await callbacks.onEndWithStreamOutput<O>(started, output);
      return rest;
    };

/// Port of eino `collectWithCallbacks`.
CollectFn<I, O, TOption> collectWithCallbacks<I, O, TOption>(
  CollectFn<I, O, TOption> fn,
) =>
    (ctx, input, options) async {
      final (started, rest) =
          await callbacks.onStartWithStreamInput<I>(ctx, input);
      final O output;
      try {
        output = await fn(started, rest, options);
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        await callbacks.onError(started, error, stackTrace);
        rethrow;
      }
      await callbacks.onEnd(started, output);
      return output;
    };

/// Port of eino `transformWithCallbacks`.
TransformFn<I, O, TOption> transformWithCallbacks<I, O, TOption>(
  TransformFn<I, O, TOption> fn,
) =>
    (ctx, input, options) async {
      final (started, rest) =
          await callbacks.onStartWithStreamInput<I>(ctx, input);
      final StreamReader<O> output;
      try {
        output = await fn(started, rest, options);
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        await callbacks.onError(started, error, stackTrace);
        rethrow;
      }
      final (_, out) =
          await callbacks.onEndWithStreamOutput<O>(started, output);
      return out;
    };

/// Something that can be run in all four ways, whichever of them it was
/// written for.
///
/// Port of eino `runnablePacker` and `newRunnablePacker`. At least one of the
/// four functions must be given; the others are derived:
///
/// * a missing `invoke` comes from `stream`, then `collect`, then `transform`;
/// * a missing `stream` from `transform`, then `invoke`, then `collect`;
/// * a missing `collect` from `transform`, then `invoke`, then `stream`;
/// * a missing `transform` from `stream`, then `collect`, then `invoke`.
///
/// Where a value is needed and a stream is there, the stream is read to its
/// end and its chunks are joined ([concatStreamReader]); where a stream is
/// needed and a value is there, it becomes a stream of one chunk.
final class RunnablePacker<I, O, TOption> {
  /// Packs the given functions. With [enableCallbacks], each given function
  /// fires the callbacks of its component.
  factory RunnablePacker({
    InvokeFn<I, O, TOption>? invoke,
    StreamFn<I, O, TOption>? stream,
    CollectFn<I, O, TOption>? collect,
    TransformFn<I, O, TOption>? transform,
    bool enableCallbacks = false,
  }) {
    var i = invoke;
    var s = stream;
    var c = collect;
    var t = transform;
    if (i == null && s == null && c == null && t == null) {
      throw ArgumentError(
        'needs to have at least one of four lambda types: '
        'invoke/stream/collect/transform, got none',
      );
    }

    if (enableCallbacks) {
      if (i != null) i = invokeWithCallbacks(i);
      if (s != null) s = streamWithCallbacks(s);
      if (c != null) c = collectWithCallbacks(c);
      if (t != null) t = transformWithCallbacks(t);
    }

    return RunnablePacker._(
      i ??
          (s != null
              ? _invokeByStream(s)
              : c != null
                  ? _invokeByCollect(c)
                  : _invokeByTransform(t!)),
      s ??
          (t != null
              ? _streamByTransform(t)
              : i != null
                  ? _streamByInvoke(i)
                  : _streamByCollect(c!)),
      c ??
          (t != null
              ? _collectByTransform(t)
              : i != null
                  ? _collectByInvoke(i)
                  : _collectByStream(s!)),
      t ??
          (s != null
              ? _transformByStream(s)
              : c != null
                  ? _transformByCollect(c)
                  : _transformByInvoke(i!)),
    );
  }

  RunnablePacker._(this.invoke, this.stream, this.collect, this.transform);

  /// Value in, value out.
  final InvokeFn<I, O, TOption> invoke;

  /// Value in, stream out.
  final StreamFn<I, O, TOption> stream;

  /// Stream in, value out.
  final CollectFn<I, O, TOption> collect;

  /// Stream in, stream out.
  final TransformFn<I, O, TOption> transform;

  /// This runnable with every call going through [wrap] first.
  ///
  /// Port of eino `runnablePacker.wrapRunnableCtx`.
  RunnablePacker<I, O, TOption> withContext(
    RunContext Function(RunContext ctx, List<TOption> options) wrap,
  ) =>
      RunnablePacker._(
        (ctx, input, options) => invoke(wrap(ctx, options), input, options),
        (ctx, input, options) => stream(wrap(ctx, options), input, options),
        (ctx, input, options) => collect(wrap(ctx, options), input, options),
        (ctx, input, options) => transform(wrap(ctx, options), input, options),
      );

  /// This runnable without its types.
  ///
  /// Port of eino `runnablePacker.toComposableRunnable`.
  ComposableRunnable toComposableRunnable() {
    final inputType = TypeRef<I>();
    return ComposableRunnable(
      invoke: (ctx, input, options) async {
        if (input is! I) {
          throw ComposeTypeException(
            'unexpected input type. expected: $I, got: ${input.runtimeType}',
          );
        }
        return invoke(ctx, input, convertOptions<TOption>(options));
      },
      transform: (ctx, input, options) async => transform(
        ctx,
        inputType.stream(input),
        convertOptions<TOption>(options),
      ),
      inputType: inputType,
      outputType: TypeRef<O>(),
      optionType: TypeRef<TOption>(),
      helper: GenericHelper.of<I, O>(),
    );
  }
}

InvokeFn<I, O, T> _invokeByStream<I, O, T>(StreamFn<I, O, T> s) =>
    (ctx, input, options) async =>
        concatStreamReader(await s(ctx, input, options));

InvokeFn<I, O, T> _invokeByCollect<I, O, T>(CollectFn<I, O, T> c) =>
    (ctx, input, options) =>
        c(ctx, StreamReader<I>.fromIterable([input]), options);

InvokeFn<I, O, T> _invokeByTransform<I, O, T>(TransformFn<I, O, T> t) =>
    (ctx, input, options) async => concatStreamReader(
          await t(ctx, StreamReader<I>.fromIterable([input]), options),
        );

StreamFn<I, O, T> _streamByTransform<I, O, T>(TransformFn<I, O, T> t) =>
    (ctx, input, options) =>
        t(ctx, StreamReader<I>.fromIterable([input]), options);

StreamFn<I, O, T> _streamByInvoke<I, O, T>(InvokeFn<I, O, T> i) =>
    (ctx, input, options) async =>
        StreamReader<O>.fromIterable([await i(ctx, input, options)]);

StreamFn<I, O, T> _streamByCollect<I, O, T>(CollectFn<I, O, T> c) =>
    (ctx, input, options) async => StreamReader<O>.fromIterable([
          await c(ctx, StreamReader<I>.fromIterable([input]), options),
        ]);

CollectFn<I, O, T> _collectByTransform<I, O, T>(TransformFn<I, O, T> t) =>
    (ctx, input, options) async =>
        concatStreamReader(await t(ctx, input, options));

CollectFn<I, O, T> _collectByInvoke<I, O, T>(InvokeFn<I, O, T> i) =>
    (ctx, input, options) async =>
        i(ctx, await concatStreamReader(input), options);

CollectFn<I, O, T> _collectByStream<I, O, T>(StreamFn<I, O, T> s) =>
    (ctx, input, options) async => concatStreamReader(
          await s(ctx, await concatStreamReader(input), options),
        );

TransformFn<I, O, T> _transformByStream<I, O, T>(StreamFn<I, O, T> s) =>
    (ctx, input, options) async =>
        s(ctx, await concatStreamReader(input), options);

TransformFn<I, O, T> _transformByCollect<I, O, T>(CollectFn<I, O, T> c) =>
    (ctx, input, options) async =>
        StreamReader<O>.fromIterable([await c(ctx, input, options)]);

TransformFn<I, O, T> _transformByInvoke<I, O, T>(InvokeFn<I, O, T> i) =>
    (ctx, input, options) async => StreamReader<O>.fromIterable([
          await i(ctx, await concatStreamReader(input), options),
        ]);
