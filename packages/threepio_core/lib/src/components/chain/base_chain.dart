import '../../callbacks/callback_handler.dart';
import '../../callbacks/callback_manager.dart';
import '../../callbacks/run_info.dart';
import '../../compose/runnable.dart';

/// Base interface for composable processing chains
///
/// Chains are Runnables that work with Map<String, dynamic> inputs and outputs.
/// This provides a convenient interface for composing operations with named parameters.
///
/// Chains extend the Runnable interface with input/output key validation.
///
/// Example usage:
/// ```dart
/// class SimpleChain extends BaseChain {
///   @override
///   List<String> get inputKeys => ['text'];
///
///   @override
///   List<String> get outputKeys => ['result'];
///
///   @override
///   Future<Map<String, dynamic>> call(Map<String, dynamic> inputs) async {
///     final text = inputs['text'] as String;
///     return {'result': text.toUpperCase()};
///   }
/// }
/// ```
abstract class BaseChain
    implements Runnable<Map<String, dynamic>, Map<String, dynamic>> {
  /// Input keys expected by this chain
  List<String> get inputKeys;

  /// Output keys produced by this chain
  List<String> get outputKeys;

  /// Execute the chain with the given inputs
  ///
  /// This is the core method that subclasses must implement.
  /// It backs the Runnable.invoke() method.
  Future<Map<String, dynamic>> call(Map<String, dynamic> inputs);

  // Runnable implementation

  @override
  Future<Map<String, dynamic>> invoke(
    Map<String, dynamic> input, {
    RunnableOptions? options,
  }) async {
    // Validate inputs
    _validateInputs(input);

    // Get callback manager if available
    final callbackManager = options?.callbackManager as CallbackManager?;

    if (callbackManager != null) {
      // Execute with callbacks
      final runInfo = RunInfo(
        name: runtimeType.toString(),
        type: runtimeType.toString(),
        componentType: ComponentType.chain,
        metadata: options?.metadata,
      );

      return await callbackManager.runWithCallbacks(
        options?.getOrCreateContext() ?? {},
        runInfo,
        input,
        () => call(input).then((outputs) {
          _validateOutputs(outputs);
          return outputs;
        }),
      );
    } else {
      // Execute without callbacks
      final outputs = await call(input);
      _validateOutputs(outputs);
      return outputs;
    }
  }

  @override
  Stream<Map<String, dynamic>> stream(
    Map<String, dynamic> input, {
    RunnableOptions? options,
  }) async* {
    // Get callback manager if available
    final callbackManager = options?.callbackManager as CallbackManager?;

    if (callbackManager != null) {
      // Execute with streaming callbacks
      final runInfo = RunInfo(
        name: runtimeType.toString(),
        type: runtimeType.toString(),
        componentType: ComponentType.chain,
        metadata: options?.metadata,
      );

      yield* callbackManager.runStreamWithCallbacks(
        options?.getOrCreateContext() ?? {},
        runInfo,
        input,
        () => Stream.fromFuture(call(input).then((outputs) {
          _validateOutputs(outputs);
          return outputs;
        })),
      );
    } else {
      // Execute without callbacks
      yield await invoke(input, options: options);
    }
  }

  @override
  Future<Map<String, dynamic>> collect(
    Stream<Map<String, dynamic>> input, {
    RunnableOptions? options,
  }) async {
    // Default implementation: take first input and invoke
    // Subclasses can override for collecting multiple inputs
    final firstInput = await input.first;
    return invoke(firstInput, options: options);
  }

  @override
  Stream<Map<String, dynamic>> transform(
    Stream<Map<String, dynamic>> input, {
    RunnableOptions? options,
  }) {
    // Default implementation: map each input through invoke
    // Subclasses can override for true streaming transformation
    return input.asyncMap((item) => invoke(item, options: options));
  }

  @override
  Runnable<Map<String, dynamic>, O2> pipe<O2>(
      Runnable<Map<String, dynamic>, O2> next) {
    return _ChainPipe<O2>(first: this, second: next);
  }

  @override
  Future<List<Map<String, dynamic>>> batch(
    List<Map<String, dynamic>> inputs, {
    RunnableOptions? options,
  }) async {
    final results = <Map<String, dynamic>>[];
    for (final input in inputs) {
      results.add(await invoke(input, options: options));
    }
    return results;
  }

  @override
  Future<List<Map<String, dynamic>>> batchParallel(
    List<Map<String, dynamic>> inputs, {
    RunnableOptions? options,
  }) async {
    return Future.wait(
      inputs.map((input) => invoke(input, options: options)),
    );
  }

  /// Execute the chain and return only the specified output keys
  Future<Map<String, dynamic>> run(
    Map<String, dynamic> inputs, {
    List<String>? returnOnlyOutputs,
    RunnableOptions? options,
  }) async {
    final outputs = await invoke(inputs, options: options);

    // Filter outputs if requested
    if (returnOnlyOutputs != null) {
      return Map.fromEntries(
        outputs.entries.where((e) => returnOnlyOutputs.contains(e.key)),
      );
    }

    return outputs;
  }

  /// Validate that all required inputs are present
  void _validateInputs(Map<String, dynamic> inputs) {
    for (final key in inputKeys) {
      if (!inputs.containsKey(key)) {
        throw ArgumentError(
          'Missing required input: $key. Required inputs: $inputKeys',
        );
      }
    }
  }

  /// Validate that all expected outputs are present
  void _validateOutputs(Map<String, dynamic> outputs) {
    for (final key in outputKeys) {
      if (!outputs.containsKey(key)) {
        throw StateError(
          'Chain did not produce expected output: $key. '
          'Expected outputs: $outputKeys',
        );
      }
    }
  }

  /// Compose this chain with another chain in sequence
  SequentialChain pipeChain(BaseChain nextChain) {
    return SequentialChain(chains: [this, nextChain]);
  }
}

/// Internal class for composing a chain with a generic runnable
class _ChainPipe<O> implements Runnable<Map<String, dynamic>, O> {
  _ChainPipe({
    required this.first,
    required this.second,
  });

  final BaseChain first;
  final Runnable<Map<String, dynamic>, O> second;

  @override
  Future<O> invoke(
    Map<String, dynamic> input, {
    RunnableOptions? options,
  }) async {
    final intermediate = await first.invoke(input, options: options);
    return await second.invoke(intermediate, options: options);
  }

  @override
  Stream<O> stream(
    Map<String, dynamic> input, {
    RunnableOptions? options,
  }) {
    final intermediateStream = first.stream(input, options: options);
    return second.transform(intermediateStream, options: options);
  }

  @override
  Future<O> collect(
    Stream<Map<String, dynamic>> input, {
    RunnableOptions? options,
  }) async {
    final intermediate = await first.collect(input, options: options);
    return await second.invoke(intermediate, options: options);
  }

  @override
  Stream<O> transform(
    Stream<Map<String, dynamic>> input, {
    RunnableOptions? options,
  }) {
    final intermediateStream = first.transform(input, options: options);
    return second.transform(intermediateStream, options: options);
  }

  @override
  Runnable<Map<String, dynamic>, O2> pipe<O2>(Runnable<O, O2> next) {
    return _ChainPipe<O2>(first: first, second: second.pipe(next));
  }

  @override
  Future<List<O>> batch(
    List<Map<String, dynamic>> inputs, {
    RunnableOptions? options,
  }) async {
    final results = <O>[];
    for (final input in inputs) {
      results.add(await invoke(input, options: options));
    }
    return results;
  }

  @override
  Future<List<O>> batchParallel(
    List<Map<String, dynamic>> inputs, {
    RunnableOptions? options,
  }) async {
    return Future.wait(
      inputs.map((input) => invoke(input, options: options)),
    );
  }
}

/// Exception thrown when chain execution fails
class ChainException implements Exception {
  ChainException(this.message, {this.chainName, this.cause});

  final String message;
  final String? chainName;
  final dynamic cause;

  @override
  String toString() {
    final buffer = StringBuffer('ChainException: $message');
    if (chainName != null) {
      buffer.write(' (chain: $chainName)');
    }
    if (cause != null) {
      buffer.write('\nCaused by: $cause');
    }
    return buffer.toString();
  }
}

/// Chain that runs multiple chains in sequence
///
/// Each chain's outputs are passed as inputs to the next chain.
///
/// Example usage:
/// ```dart
/// final chain1 = ChainA(); // outputs: {text: '...'}
/// final chain2 = ChainB(); // inputs: {text: '...'}, outputs: {result: '...'}
///
/// final sequential = SequentialChain(chains: [chain1, chain2]);
/// final result = await sequential.invoke({});
/// print(result['result']);
/// ```
class SequentialChain extends BaseChain {
  SequentialChain({
    required this.chains,
    this.returnAll = false,
  }) {
    if (chains.isEmpty) {
      throw ArgumentError('SequentialChain requires at least one chain');
    }
  }

  /// Chains to execute in sequence
  final List<BaseChain> chains;

  /// Whether to return outputs from all chains or just the last
  final bool returnAll;

  @override
  List<String> get inputKeys => chains.first.inputKeys;

  @override
  List<String> get outputKeys {
    if (returnAll) {
      // Return all output keys from all chains
      final allKeys = <String>{};
      for (final chain in chains) {
        allKeys.addAll(chain.outputKeys);
      }
      return allKeys.toList();
    }
    // Return only output keys from last chain
    return chains.last.outputKeys;
  }

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> inputs) async {
    var currentInputs = Map<String, dynamic>.from(inputs);
    var allOutputs = <String, dynamic>{};

    for (var i = 0; i < chains.length; i++) {
      try {
        final outputs = await chains[i].invoke(currentInputs);

        // Merge outputs with current inputs for next chain
        currentInputs = {
          ...currentInputs,
          ...outputs,
        };

        // Store outputs if returning all
        if (returnAll) {
          allOutputs.addAll(outputs);
        }
      } catch (e) {
        throw ChainException(
          'Chain $i failed',
          chainName: chains[i].runtimeType.toString(),
          cause: e,
        );
      }
    }

    // Return either all outputs or just the last chain's outputs
    if (returnAll) {
      return allOutputs;
    } else {
      // Return only the outputs from the last chain
      return Map.fromEntries(
        currentInputs.entries.where(
          (e) => chains.last.outputKeys.contains(e.key),
        ),
      );
    }
  }

  @override
  Stream<Map<String, dynamic>> stream(
    Map<String, dynamic> input, {
    RunnableOptions? options,
  }) {
    // For sequential chains with streaming, we need to handle it carefully
    // We'll execute chains sequentially and stream the final result
    return Stream.fromFuture(invoke(input, options: options));
  }

  @override
  Stream<Map<String, dynamic>> transform(
    Stream<Map<String, dynamic>> input, {
    RunnableOptions? options,
  }) {
    // For transform mode, chain the transformations
    var stream = input;
    for (final chain in chains) {
      stream = chain.transform(stream, options: options);
    }
    return stream;
  }
}

/// Chain that runs multiple chains in parallel
///
/// All chains receive the same inputs and their outputs are merged.
///
/// Example usage:
/// ```dart
/// final chain1 = ChainA(); // outputs: {result_a: '...'}
/// final chain2 = ChainB(); // outputs: {result_b: '...'}
///
/// final parallel = ParallelChain(chains: [chain1, chain2]);
/// final result = await parallel.invoke({'input': 'test'});
/// // result: {result_a: '...', result_b: '...'}
/// ```
class ParallelChain extends BaseChain {
  ParallelChain({required this.chains}) {
    if (chains.isEmpty) {
      throw ArgumentError('ParallelChain requires at least one chain');
    }

    // All chains must have the same input keys
    final firstInputKeys = chains.first.inputKeys.toSet();
    for (final chain in chains.skip(1)) {
      if (!firstInputKeys.containsAll(chain.inputKeys)) {
        throw ArgumentError(
          'All chains in ParallelChain must have the same input keys',
        );
      }
    }
  }

  /// Chains to execute in parallel
  final List<BaseChain> chains;

  @override
  List<String> get inputKeys => chains.first.inputKeys;

  @override
  List<String> get outputKeys {
    // Collect all output keys from all chains
    final allKeys = <String>{};
    for (final chain in chains) {
      allKeys.addAll(chain.outputKeys);
    }
    return allKeys.toList();
  }

  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> inputs) async {
    // Run all chains in parallel
    final futures = chains.map((chain) => chain.invoke(inputs)).toList();

    try {
      final results = await Future.wait(futures);

      // Merge all outputs
      final mergedOutputs = <String, dynamic>{};
      for (final result in results) {
        mergedOutputs.addAll(result);
      }

      return mergedOutputs;
    } catch (e) {
      throw ChainException(
        'One or more parallel chains failed',
        cause: e,
      );
    }
  }

  @override
  Stream<Map<String, dynamic>> stream(
    Map<String, dynamic> input, {
    RunnableOptions? options,
  }) {
    // For parallel chains with streaming, merge the streams
    return Stream.fromFuture(invoke(input, options: options));
  }

  @override
  Stream<Map<String, dynamic>> transform(
    Stream<Map<String, dynamic>> input, {
    RunnableOptions? options,
  }) async* {
    // For transform mode with parallel chains, we need to handle carefully
    // Broadcast the input to all chains and merge outputs
    await for (final item in input) {
      final result = await invoke(item, options: options);
      yield result;
    }
  }
}
