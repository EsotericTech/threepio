/// Core abstraction for composable components in Threepio
///
/// Based on Eino's Runnable interface, this provides four execution modes:
/// - invoke: I → Future<O> (basic async execution)
/// - stream: I → Stream<O> (streaming output)
/// - collect: Stream<I> → Future<O> (collect stream input)
/// - transform: Stream<I> → Stream<O> (stream-to-stream transformation)
///
/// This is the foundation for all composable components (chains, graphs, etc.)
abstract class Runnable<I, O> {
  /// Execute with single input, return single output
  ///
  /// This is the most basic execution mode.
  ///
  /// Example:
  /// ```dart
  /// final result = await runnable.invoke({'query': 'Hello'});
  /// ```
  Future<O> invoke(I input, {RunnableOptions? options});

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
  Stream<O> stream(I input, {RunnableOptions? options});

  /// Collect streaming input, return single output
  ///
  /// Useful for aggregating streamed data.
  ///
  /// Example:
  /// ```dart
  /// final result = await runnable.collect(inputStream);
  /// ```
  Future<O> collect(Stream<I> input, {RunnableOptions? options});

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
  Stream<O> transform(Stream<I> input, {RunnableOptions? options});

  /// Compose this runnable with another
  ///
  /// Creates a new runnable that pipes output of this into the next.
  ///
  /// Example:
  /// ```dart
  /// final composed = runnable1.pipe(runnable2).pipe(runnable3);
  /// final result = await composed.invoke(input);
  /// ```
  Runnable<I, O2> pipe<O2>(Runnable<O, O2> next);

  /// Batch process multiple inputs
  ///
  /// Default implementation calls invoke for each input.
  /// Override for optimized batch processing.
  Future<List<O>> batch(List<I> inputs, {RunnableOptions? options}) async {
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
    RunnableOptions? options,
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
class RunnableOptions {
  const RunnableOptions({
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
  /// final options = RunnableOptions(
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
  RunnableOptions copyWith({
    Map<String, dynamic>? metadata,
    List<String>? tags,
    dynamic callbackManager,
    Map<String, dynamic>? context,
  }) {
    return RunnableOptions(
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
class RunnableException implements Exception {
  RunnableException(
    this.message, {
    this.runnableType,
    this.cause,
  });

  final String message;
  final String? runnableType;
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer('RunnableException: $message');
    if (runnableType != null) {
      buffer.write(' [runnable: $runnableType]');
    }
    if (cause != null) {
      buffer.write('\nCause: $cause');
    }
    return buffer.toString();
  }
}
