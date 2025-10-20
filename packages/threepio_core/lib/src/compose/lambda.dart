import 'runnable.dart';

/// Lambda wraps custom functions into a Runnable
///
/// This allows you to create runnables from simple functions without
/// implementing the full Runnable interface.
///
/// You can provide implementations for any of the 4 execution modes.
/// If a mode is not provided, a default implementation will be used.
///
/// Example:
/// ```dart
/// // Simple invoke-only lambda
/// final lambda = Lambda<String, String>(
///   invoke: (input, options) async => input.toUpperCase(),
/// );
///
/// // Lambda with streaming support
/// final streamingLambda = Lambda<String, String>(
///   invoke: (input, options) async => input.toUpperCase(),
///   stream: (input, options) async* {
///     for (final char in input.split('')) {
///       yield char.toUpperCase();
///     }
///   },
/// );
/// ```
class Lambda<I, O> implements Runnable<I, O> {
  Lambda({
    Future<O> Function(I input, RunnableOptions? options)? invoke,
    Stream<O> Function(I input, RunnableOptions? options)? stream,
    Future<O> Function(Stream<I> input, RunnableOptions? options)? collect,
    Stream<O> Function(Stream<I> input, RunnableOptions? options)? transform,
  })  : _invokeFunc = invoke,
        _streamFunc = stream,
        _collectFunc = collect,
        _transformFunc = transform {
    // At least one execution mode must be provided
    if (invoke == null &&
        stream == null &&
        collect == null &&
        transform == null) {
      throw ArgumentError(
        'Lambda must have at least one execution mode defined',
      );
    }
  }

  final Future<O> Function(I input, RunnableOptions? options)? _invokeFunc;
  final Stream<O> Function(I input, RunnableOptions? options)? _streamFunc;
  final Future<O> Function(Stream<I> input, RunnableOptions? options)?
      _collectFunc;
  final Stream<O> Function(Stream<I> input, RunnableOptions? options)?
      _transformFunc;

  @override
  Future<O> invoke(I input, {RunnableOptions? options}) async {
    if (_invokeFunc != null) {
      return _invokeFunc!(input, options);
    }

    // Fallback: if stream is available, collect first result
    if (_streamFunc != null) {
      return await _streamFunc!(input, options).first;
    }

    // Fallback: if collect is available, create single-item stream
    if (_collectFunc != null) {
      return await _collectFunc!(Stream.value(input), options);
    }

    // Fallback: if transform is available, use it
    if (_transformFunc != null) {
      return await _transformFunc!(Stream.value(input), options).first;
    }

    throw RunnableException(
      'No suitable execution mode available for invoke',
      runnableType: 'Lambda',
    );
  }

  @override
  Stream<O> stream(I input, {RunnableOptions? options}) {
    if (_streamFunc != null) {
      return _streamFunc!(input, options);
    }

    // Fallback: if invoke is available, wrap result in stream
    if (_invokeFunc != null) {
      return Stream.fromFuture(_invokeFunc!(input, options));
    }

    // Fallback: if transform is available, create single-item stream
    if (_transformFunc != null) {
      return _transformFunc!(Stream.value(input), options);
    }

    // Fallback: if collect is available, use transform fallback
    if (_collectFunc != null) {
      return Stream.fromFuture(
        _collectFunc!(Stream.value(input), options),
      );
    }

    throw RunnableException(
      'No suitable execution mode available for stream',
      runnableType: 'Lambda',
    );
  }

  @override
  Future<O> collect(Stream<I> input, {RunnableOptions? options}) async {
    if (_collectFunc != null) {
      return _collectFunc!(input, options);
    }

    // Fallback: if transform is available, take first result
    if (_transformFunc != null) {
      return await _transformFunc!(input, options).first;
    }

    // Fallback: if invoke is available, use first input item
    if (_invokeFunc != null) {
      final firstInput = await input.first;
      return await _invokeFunc!(firstInput, options);
    }

    // Fallback: if stream is available, use first input item
    if (_streamFunc != null) {
      final firstInput = await input.first;
      return await _streamFunc!(firstInput, options).first;
    }

    throw RunnableException(
      'No suitable execution mode available for collect',
      runnableType: 'Lambda',
    );
  }

  @override
  Stream<O> transform(Stream<I> input, {RunnableOptions? options}) {
    if (_transformFunc != null) {
      return _transformFunc!(input, options);
    }

    // Fallback: if collect is available, wrap result in stream
    if (_collectFunc != null) {
      return Stream.fromFuture(_collectFunc!(input, options));
    }

    // Fallback: if stream is available, transform each input
    if (_streamFunc != null) {
      return input.asyncExpand((item) => _streamFunc!(item, options));
    }

    // Fallback: if invoke is available, transform each input
    if (_invokeFunc != null) {
      return input.asyncMap((item) => _invokeFunc!(item, options));
    }

    throw RunnableException(
      'No suitable execution mode available for transform',
      runnableType: 'Lambda',
    );
  }

  @override
  Runnable<I, O2> pipe<O2>(Runnable<O, O2> next) {
    return RunnableSequence<I, O, O2>(first: this, second: next);
  }

  @override
  Future<List<O>> batch(List<I> inputs, {RunnableOptions? options}) async {
    final results = <O>[];
    for (final input in inputs) {
      results.add(await invoke(input, options: options));
    }
    return results;
  }

  @override
  Future<List<O>> batchParallel(
    List<I> inputs, {
    RunnableOptions? options,
  }) async {
    return Future.wait(
      inputs.map((input) => invoke(input, options: options)),
    );
  }
}

/// Internal class for composing two runnables in sequence
class RunnableSequence<I, M, O> implements Runnable<I, O> {
  RunnableSequence({
    required this.first,
    required this.second,
  });

  final Runnable<I, M> first;
  final Runnable<M, O> second;

  @override
  Future<O> invoke(I input, {RunnableOptions? options}) async {
    final intermediate = await first.invoke(input, options: options);
    return await second.invoke(intermediate, options: options);
  }

  @override
  Stream<O> stream(I input, {RunnableOptions? options}) {
    // For streaming, we need to handle the intermediate streaming carefully
    // We'll use transform mode on second if first produces a stream
    try {
      final intermediateStream = first.stream(input, options: options);
      return second.transform(intermediateStream, options: options);
    } catch (e) {
      // Fallback to invoke + stream if transform not available
      return Stream.fromFuture(first.invoke(input, options: options))
          .asyncExpand(
              (intermediate) => second.stream(intermediate, options: options));
    }
  }

  @override
  Future<O> collect(Stream<I> input, {RunnableOptions? options}) async {
    final intermediate = await first.collect(input, options: options);
    return await second.invoke(intermediate, options: options);
  }

  @override
  Stream<O> transform(Stream<I> input, {RunnableOptions? options}) {
    final intermediateStream = first.transform(input, options: options);
    return second.transform(intermediateStream, options: options);
  }

  @override
  Runnable<I, O2> pipe<O2>(Runnable<O, O2> next) {
    return RunnableSequence<I, O, O2>(first: this, second: next);
  }

  @override
  Future<List<O>> batch(List<I> inputs, {RunnableOptions? options}) async {
    final results = <O>[];
    for (final input in inputs) {
      results.add(await invoke(input, options: options));
    }
    return results;
  }

  @override
  Future<List<O>> batchParallel(
    List<I> inputs, {
    RunnableOptions? options,
  }) async {
    return Future.wait(
      inputs.map((input) => invoke(input, options: options)),
    );
  }
}

/// Helper function to create a simple Lambda from an invoke function
Lambda<I, O> lambda<I, O>(
  Future<O> Function(I input) func,
) {
  return Lambda<I, O>(
    invoke: (input, options) => func(input),
  );
}

/// Helper function to create a streaming Lambda
Lambda<I, O> streamingLambda<I, O>(
  Stream<O> Function(I input) func,
) {
  return Lambda<I, O>(
    stream: (input, options) => func(input),
  );
}

/// Helper function to create a synchronous Lambda
Lambda<I, O> syncLambda<I, O>(
  O Function(I input) func,
) {
  return Lambda<I, O>(
    invoke: (input, options) async => func(input),
  );
}
