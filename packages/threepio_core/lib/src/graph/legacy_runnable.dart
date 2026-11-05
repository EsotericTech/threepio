import '../errors.dart';

/// Core abstraction for composable components in Threepio
///
/// The pre-parity runnable over Dart `Stream`s, kept for
/// `StateGraph.toRunnable()`. The port of eino `compose.Runnable` is
/// `Runnable` in `package:threepio_core/compose.dart`. Four execution modes:
/// - invoke: I → Future<O> (basic async execution)
/// - stream: I → Stream<O> (streaming output)
/// - collect: Stream<I> → Future<O> (collect stream input)
/// - transform: Stream<I> → Stream<O> (stream-to-stream transformation)
///
/// This is the foundation for all composable components (chains, graphs, etc.)
abstract class LegacyRunnable<I, O> {
  /// Execute with single input, return single output
  ///
  /// This is the most basic execution mode.
  ///
  /// Example:
  /// ```dart
  /// final result = await runnable.invoke({'query': 'Hello'});
  /// ```
  Future<O> invoke(I input, {LegacyRunnableOptions? options});

  /// Execute with single input, stream multiple outputs
  ///
  /// Useful for real-time responses from LLMs.
  ///
  /// Example:
  /// ```dart
  /// await for (final chunk in runnable.stream({'query': 'Hello'})) {
  ///   print(chunk);
  /// }
  /// ```
  Stream<O> stream(I input, {LegacyRunnableOptions? options});

  /// Collect streaming input, return single output
  ///
  /// Useful for aggregating streamed data.
  ///
  /// Example:
  /// ```dart
  /// final result = await runnable.collect(inputStream);
  /// ```
  Future<O> collect(Stream<I> input, {LegacyRunnableOptions? options});

  /// Transform streaming input to streaming output
  ///
  /// Most flexible mode for stream processing.
  ///
  /// Example:
  /// ```dart
  /// final outputStream = runnable.transform(inputStream);
  /// await for (final chunk in outputStream) {
  ///   print(chunk);
  /// }
  /// ```
  Stream<O> transform(Stream<I> input, {LegacyRunnableOptions? options});

  /// Compose this runnable with another
  ///
  /// Creates a new runnable that pipes output of this into the next.
  ///
  /// Example:
  /// ```dart
  /// final composed = runnable1.pipe(runnable2).pipe(runnable3);
  /// final result = await composed.invoke(input);
  /// ```
  LegacyRunnable<I, O2> pipe<O2>(LegacyRunnable<O, O2> next);

  /// Batch process multiple inputs
  ///
  /// Default implementation calls invoke for each input.
  /// Override for optimized batch processing.
  Future<List<O>> batch(List<I> inputs, {LegacyRunnableOptions? options}) async {
    final results = <O>[];
    for (final input in inputs) {
      results.add(await invoke(input, options: options));
    }
    return results;
  }

  /// Batch process multiple inputs in parallel
  ///
  /// Default implementation uses Future.wait.
  /// Override for custom concurrency control.
  Future<List<O>> batchParallel(
    List<I> inputs, {
    LegacyRunnableOptions? options,
  }) async {
    return Future.wait(
      inputs.map((input) => invoke(input, options: options)),
    );
  }
}

/// Options for runnable execution
///
/// This can be extended by specific runnables to add custom options.
/// Includes support for callbacks, metadata, and execution context.
class LegacyRunnableOptions {
  const LegacyRunnableOptions({
    this.metadata,
    this.tags,
    this.callbackManager,
    this.context,
  });

  /// Arbitrary metadata to pass through execution
  final Map<String, dynamic>? metadata;

  /// Tags for categorizing/filtering executions
  final List<String>? tags;

  /// Callback manager for execution lifecycle events
  ///
  /// Use this to attach callbacks that track execution, log information,
  /// collect metrics, or perform other cross-cutting concerns.
  ///
  /// Example:
  /// ```dart
  /// import 'package:threepio_core/src/callbacks/callback_manager.dart';
  ///
  /// final options = LegacyRunnableOptions(
  ///   callbackManager: CallbackManager([
  ///     LoggingHandler(),
  ///     MetricsHandler(),
  ///   ]),
  /// );
  /// ```
  final dynamic
      callbackManager; // CallbackManager - keeping dynamic to avoid circular import

  /// Execution context that flows through callbacks
  ///
  /// This context is threaded through all callback invocations,
  /// allowing handlers to store and retrieve request-level information.
  final Map<String, dynamic>? context;

  /// Create a copy with updated fields
  LegacyRunnableOptions copyWith({
    Map<String, dynamic>? metadata,
    List<String>? tags,
    dynamic callbackManager,
    Map<String, dynamic>? context,
  }) {
    return LegacyRunnableOptions(
      metadata: metadata ?? this.metadata,
      tags: tags ?? this.tags,
      callbackManager: callbackManager ?? this.callbackManager,
      context: context ?? this.context,
    );
  }

  /// Get the context, creating an empty one if null
  Map<String, dynamic> getOrCreateContext() {
    return context ?? {};
  }
}

/// Exception thrown by runnables
class LegacyRunnableException implements ThreepioException {
  LegacyRunnableException(
    this.message, {
    this.runnableType,
    this.cause,
  });

  @override
  final String message;
  final String? runnableType;
  @override
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer('LegacyRunnableException: $message');
    if (runnableType != null) {
      buffer.write(' [runnable: $runnableType]');
    }
    if (cause != null) {
      buffer.write('\nCause: $cause');
    }
    return buffer.toString();
  }
}

/// LegacyLambda wraps custom functions into a LegacyRunnable
///
/// This allows you to create runnables from simple functions without
/// implementing the full LegacyRunnable interface.
///
/// You can provide implementations for any of the 4 execution modes.
/// If a mode is not provided, a default implementation will be used.
///
/// Example:
/// ```dart
/// // Simple invoke-only lambda
/// final lambda = LegacyLambda<String, String>(
///   invoke: (input, options) async => input.toUpperCase(),
/// );
///
/// // LegacyLambda with streaming support
/// final streamingLambda = LegacyLambda<String, String>(
///   invoke: (input, options) async => input.toUpperCase(),
///   stream: (input, options) async* {
///     for (final char in input.split('')) {
///       yield char.toUpperCase();
///     }
///   },
/// );
/// ```
class LegacyLambda<I, O> implements LegacyRunnable<I, O> {
  LegacyLambda({
    Future<O> Function(I input, LegacyRunnableOptions? options)? invoke,
    Stream<O> Function(I input, LegacyRunnableOptions? options)? stream,
    Future<O> Function(Stream<I> input, LegacyRunnableOptions? options)? collect,
    Stream<O> Function(Stream<I> input, LegacyRunnableOptions? options)? transform,
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
        'LegacyLambda must have at least one execution mode defined',
      );
    }
  }

  final Future<O> Function(I input, LegacyRunnableOptions? options)? _invokeFunc;
  final Stream<O> Function(I input, LegacyRunnableOptions? options)? _streamFunc;
  final Future<O> Function(Stream<I> input, LegacyRunnableOptions? options)?
      _collectFunc;
  final Stream<O> Function(Stream<I> input, LegacyRunnableOptions? options)?
      _transformFunc;

  @override
  Future<O> invoke(I input, {LegacyRunnableOptions? options}) async {
    if (_invokeFunc != null) {
      return _invokeFunc(input, options);
    }

    // Fallback: if stream is available, collect first result
    if (_streamFunc != null) {
      return await _streamFunc(input, options).first;
    }

    // Fallback: if collect is available, create single-item stream
    if (_collectFunc != null) {
      return await _collectFunc(Stream.value(input), options);
    }

    // Fallback: if transform is available, use it
    if (_transformFunc != null) {
      return await _transformFunc(Stream.value(input), options).first;
    }

    throw LegacyRunnableException(
      'No suitable execution mode available for invoke',
      runnableType: 'LegacyLambda',
    );
  }

  @override
  Stream<O> stream(I input, {LegacyRunnableOptions? options}) {
    if (_streamFunc != null) {
      return _streamFunc(input, options);
    }

    // Fallback: if invoke is available, wrap result in stream
    if (_invokeFunc != null) {
      return Stream.fromFuture(_invokeFunc(input, options));
    }

    // Fallback: if transform is available, create single-item stream
    if (_transformFunc != null) {
      return _transformFunc(Stream.value(input), options);
    }

    // Fallback: if collect is available, use transform fallback
    if (_collectFunc != null) {
      return Stream.fromFuture(
        _collectFunc(Stream.value(input), options),
      );
    }

    throw LegacyRunnableException(
      'No suitable execution mode available for stream',
      runnableType: 'LegacyLambda',
    );
  }

  @override
  Future<O> collect(Stream<I> input, {LegacyRunnableOptions? options}) async {
    if (_collectFunc != null) {
      return _collectFunc(input, options);
    }

    // Fallback: if transform is available, take first result
    if (_transformFunc != null) {
      return await _transformFunc(input, options).first;
    }

    // Fallback: if invoke is available, use first input item
    if (_invokeFunc != null) {
      final firstInput = await input.first;
      return await _invokeFunc(firstInput, options);
    }

    // Fallback: if stream is available, use first input item
    if (_streamFunc != null) {
      final firstInput = await input.first;
      return await _streamFunc(firstInput, options).first;
    }

    throw LegacyRunnableException(
      'No suitable execution mode available for collect',
      runnableType: 'LegacyLambda',
    );
  }

  @override
  Stream<O> transform(Stream<I> input, {LegacyRunnableOptions? options}) {
    if (_transformFunc != null) {
      return _transformFunc(input, options);
    }

    // Fallback: if collect is available, wrap result in stream
    if (_collectFunc != null) {
      return Stream.fromFuture(_collectFunc(input, options));
    }

    // Fallback: if stream is available, transform each input
    if (_streamFunc != null) {
      return input.asyncExpand((item) => _streamFunc(item, options));
    }

    // Fallback: if invoke is available, transform each input
    if (_invokeFunc != null) {
      return input.asyncMap((item) => _invokeFunc(item, options));
    }

    throw LegacyRunnableException(
      'No suitable execution mode available for transform',
      runnableType: 'LegacyLambda',
    );
  }

  @override
  LegacyRunnable<I, O2> pipe<O2>(LegacyRunnable<O, O2> next) {
    return LegacyRunnableSequence<I, O, O2>(first: this, second: next);
  }

  @override
  Future<List<O>> batch(List<I> inputs, {LegacyRunnableOptions? options}) async {
    final results = <O>[];
    for (final input in inputs) {
      results.add(await invoke(input, options: options));
    }
    return results;
  }

  @override
  Future<List<O>> batchParallel(
    List<I> inputs, {
    LegacyRunnableOptions? options,
  }) async {
    return Future.wait(
      inputs.map((input) => invoke(input, options: options)),
    );
  }
}

/// Internal class for composing two runnables in sequence
class LegacyRunnableSequence<I, M, O> implements LegacyRunnable<I, O> {
  LegacyRunnableSequence({
    required this.first,
    required this.second,
  });

  final LegacyRunnable<I, M> first;
  final LegacyRunnable<M, O> second;

  @override
  Future<O> invoke(I input, {LegacyRunnableOptions? options}) async {
    final intermediate = await first.invoke(input, options: options);
    return await second.invoke(intermediate, options: options);
  }

  @override
  Stream<O> stream(I input, {LegacyRunnableOptions? options}) {
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
  Future<O> collect(Stream<I> input, {LegacyRunnableOptions? options}) async {
    final intermediate = await first.collect(input, options: options);
    return await second.invoke(intermediate, options: options);
  }

  @override
  Stream<O> transform(Stream<I> input, {LegacyRunnableOptions? options}) {
    final intermediateStream = first.transform(input, options: options);
    return second.transform(intermediateStream, options: options);
  }

  @override
  LegacyRunnable<I, O2> pipe<O2>(LegacyRunnable<O, O2> next) {
    return LegacyRunnableSequence<I, O, O2>(first: this, second: next);
  }

  @override
  Future<List<O>> batch(List<I> inputs, {LegacyRunnableOptions? options}) async {
    final results = <O>[];
    for (final input in inputs) {
      results.add(await invoke(input, options: options));
    }
    return results;
  }

  @override
  Future<List<O>> batchParallel(
    List<I> inputs, {
    LegacyRunnableOptions? options,
  }) async {
    return Future.wait(
      inputs.map((input) => invoke(input, options: options)),
    );
  }
}

/// Helper function to create a simple LegacyLambda from an invoke function
LegacyLambda<I, O> lambda<I, O>(
  Future<O> Function(I input) func,
) {
  return LegacyLambda<I, O>(
    invoke: (input, options) => func(input),
  );
}

/// Helper function to create a streaming LegacyLambda
LegacyLambda<I, O> streamingLambda<I, O>(
  Stream<O> Function(I input) func,
) {
  return LegacyLambda<I, O>(
    stream: (input, options) => func(input),
  );
}

/// Helper function to create a synchronous LegacyLambda
LegacyLambda<I, O> syncLambda<I, O>(
  O Function(I input) func,
) {
  return LegacyLambda<I, O>(
    invoke: (input, options) async => func(input),
  );
}
