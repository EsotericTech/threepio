/// A node that runs one graph once for every item of a list.
///
/// Port of `compose/batch/batch` of the eino examples (`node.go`, `types.go`,
/// `options.go`, `store.go`).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../callbacks/callback_context.dart';
import '../callbacks/component_callbacks.dart' as callbacks;
import '../callbacks/run_info.dart';
import '../components/component_type.dart';
import '../core/run_context.dart';
import '../errors.dart';
import '../schema/type_registry.dart';
import 'address.dart';
import 'call_options.dart';
import 'checkpoint_serializer.dart';
import 'checkpoint_store.dart';
import 'graph.dart';
import 'graph_options.dart';
import 'interrupt.dart';
import 'lambda.dart';
import 'resume.dart';
import 'type_ref.dart';

/// What the start callback of a [BatchNode] reports.
///
/// Port of `batch.CallbackInput`.
@immutable
final class BatchCallbackInput<I> {
  /// The input of a batch.
  const BatchCallbackInput({required this.inputs, required this.maxConcurrency});

  /// All items of the batch.
  final List<I> inputs;

  /// How many items are processed side by side; 0 for one after the other.
  final int maxConcurrency;
}

/// What the end callback of a [BatchNode] reports.
///
/// Port of `batch.CallbackOutput`.
@immutable
final class BatchCallbackOutput<O> {
  /// The output of a batch.
  const BatchCallbackOutput({required this.outputs});

  /// The result for every item, in the order of the inputs.
  final List<O> outputs;
}

/// What a batch keeps when some of its items interrupted.
///
/// Port of `batch.NodeInterruptState`.
final class _BatchInterruptState {
  _BatchInterruptState({
    required this.originalInputs,
    required this.completedResults,
    required this.interruptedIndices,
    required this.totalCount,
  });

  factory _BatchInterruptState.fromJson(Map<String, Object?> json) =>
      _BatchInterruptState(
        originalInputs: [
          for (final input in json['original_inputs']! as List<Object?>)
            TypeRegistry.decode(input),
        ],
        completedResults: {
          for (final MapEntry(:key, :value)
              in (json['completed_results']! as Map<String, Object?>).entries)
            int.parse(key): TypeRegistry.decode(value),
        },
        interruptedIndices:
            (json['interrupted_indices']! as List<Object?>).cast<int>(),
        totalCount: json['total_count']! as int,
      );

  /// Every input of the batch: on the resumed run the node gets none.
  final List<Object?> originalInputs;

  /// The results of the items that finished, by index.
  final Map<int, Object?> completedResults;

  /// The items that interrupted; only they run again.
  final List<int> interruptedIndices;

  /// The number of items.
  final int totalCount;

  Map<String, Object?> toJson() => {
        'original_inputs': [
          for (final input in originalInputs) TypeRegistry.encode(input),
        ],
        'completed_results': {
          for (final MapEntry(:key, :value) in completedResults.entries)
            '$key': TypeRegistry.encode(value),
        },
        'interrupted_indices': interruptedIndices,
        'total_count': totalCount,
      };
}

void _ensureRegistered() {
  if (TypeRegistry.isRegistered<_BatchInterruptState>()) return;
  ensureComposeTypesRegistered();
  TypeRegistry.registerName<_BatchInterruptState>(
    'batch.NodeInterruptState',
    fromJson: _BatchInterruptState.fromJson,
    toJson: (state) => state.toJson(),
  );
}

/// The checkpoints of the runs of one batch, one per item.
///
/// Port of `batchBridgeStore`.
final class _BatchStore implements CheckpointStore {
  final Map<String, Uint8List> _checkpoints = {};

  @override
  Future<Uint8List?> get(String key) async => _checkpoints[key];

  @override
  Future<void> set(String key, Uint8List value) async {
    _checkpoints[key] = value;
  }
}

/// Runs a graph, chain or workflow once for every item of a list and returns
/// the results in the order of the items.
///
/// Port of `batch.Node` of the eino examples. The items run one after the
/// other, or up to [maxConcurrency] of them side by side. Every item runs at
/// an address of its own ([segmentType] with the index of the item), so each
/// can interrupt on its own: the batch then interrupts as a whole, with one
/// interrupt point per interrupted item, and keeps the results of the items
/// that finished. When the run is resumed, only the interrupted items run
/// again, however often that happens. (The node of the eino examples loses
/// the results of earlier runs when it is interrupted a second time.)
///
/// ```dart
/// final review = BatchNode<Document, Verdict>(innerTask: reviewWorkflow, maxConcurrency: 3);
/// graph.addLambdaNode('review_all', review.toLambda());
/// ```
///
/// Because the batch saves its inputs and the results it has when it
/// interrupts, [I] and [O] must be JSON or registered with
/// `TypeRegistry.registerName` when the graph around it writes checkpoints.
final class BatchNode<I, O> implements TypedComponent, CallbackAwareComponent {
  /// A batch node that runs [innerTask] for every item.
  ///
  /// [innerTask] is a `Graph<I, O>`, `Chain<I, O>` or `Workflow<I, O>` that
  /// is not compiled yet; the node compiles it, with [innerCompileOptions],
  /// each time it is invoked. Throws [ArgumentError] when its input or output
  /// type is not [I] or [O].
  BatchNode({
    required AnyGraph innerTask,
    this.name = 'Node',
    this.maxConcurrency = 0,
    this.innerCompileOptions,
  }) : _innerTask = innerTask {
    final engine = innerTask.engine;
    if (!engine.inputType.isSameAs(TypeRef<I>()) ||
        !engine.outputType.isSameAs(TypeRef<O>())) {
      throw ArgumentError.value(
        innerTask,
        'innerTask',
        'runs from ${engine.inputType.name} to ${engine.outputType.name}, '
            'not from $I to $O',
      );
    }
    if (maxConcurrency < 0) {
      throw ArgumentError.value(maxConcurrency, 'maxConcurrency', 'is negative');
    }
    // Here and not only when the node runs: after a restart the checkpoint
    // of the graph around the node is read, with the state of the batch in
    // it, before the node is reached.
    _ensureRegistered();
  }

  /// The kind of address segment the runs of the items get, with the index
  /// of the item as id. Port of `batch.AddressSegmentBatchProcess`.
  static const segmentType = AddressSegmentType('batch_process');

  final AnyGraph _innerTask;

  /// The name callbacks report the node under.
  final String name;

  /// How many items run side by side; 0 runs them one after the other.
  final int maxConcurrency;

  /// The options the inner task is compiled with (a graph name, interrupt
  /// nodes). The node adds a checkpoint store of its own.
  final GraphCompileOptions? innerCompileOptions;

  @override
  String get componentTypeName => name;

  @override
  bool get isCallbacksEnabled => true;

  /// The node as a lambda from the list of items to the list of results, to
  /// add to a graph.
  Lambda<List<I>, List<O>> toLambda({List<CallOption> innerOptions = const []}) =>
      Lambda<List<I>, List<O>>.invokable(
        (ctx, inputs) => invoke(ctx, inputs, innerOptions: innerOptions),
        options: LambdaOptions(type: name, callbacksEnabled: true),
      );

  /// Runs the inner task for every item of [inputs].
  ///
  /// Port of `Node.Invoke`. [innerOptions] are the call options of every run
  /// of the inner task (`batch.WithInnerOptions`). Throws the first failure
  /// of an item, or the interrupt of the batch when items interrupted.
  Future<List<O>> invoke(
    RunContext ctx,
    List<I> inputs, {
    List<CallOption> innerOptions = const [],
  }) async {
    final started = await callbacks.onStart(
      ensureRunInfo(ctx, name, ComponentType.custom),
      BatchCallbackInput<I>(inputs: inputs, maxConcurrency: maxConcurrency),
    );
    final List<O> outputs;
    try {
      outputs = await _invoke(started, inputs, innerOptions);
      // Reported to the handlers and thrown on.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      await callbacks.onError(started, error, stackTrace);
      rethrow;
    }
    await callbacks.onEnd(started, BatchCallbackOutput<O>(outputs: outputs));
    return outputs;
  }

  Future<List<O>> _invoke(
    RunContext ctx,
    List<I> inputs,
    List<CallOption> innerOptions,
  ) async {
    _ensureRegistered();
    final previous = getInterruptState<_BatchInterruptState>(ctx).state;

    // On a resumed run the inputs come from the state the batch saved, and
    // only the items that interrupted run.
    final effective = previous == null
        ? inputs
        : [
            for (final input in previous.originalInputs)
              _typed<I>(input, 'input'),
          ];
    final indices = previous == null
        ? [for (var i = 0; i < inputs.length; i++) i]
        : previous.interruptedIndices;
    final results = <int, O>{
      if (previous != null)
        for (final MapEntry(key: index, :value)
            in previous.completedResults.entries)
          if (index < effective.length) index: _typed<O>(value, 'result'),
    };

    final runner = await compileAnyGraph<I, O>(
      ctx,
      _innerTask.engine,
      (innerCompileOptions ?? const GraphCompileOptions())
          .copyWith(checkpointStore: _BatchStore()),
    );

    Object? failure;
    StackTrace? failedAt;
    final interrupts = <int, Object>{};

    Future<void> runItem(int index) async {
      try {
        results[index] = await runner.invoke(
          // An address of its own, so that the interrupt points of the items
          // differ.
          ctx.appendAddressSegment(segmentType, '$index'),
          effective[index],
          options: [CallOption.checkpointId('batch_$index'), ...innerOptions],
        );
        // What an item throws is sorted below.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        if (extractInterruptInfo(error) != null) {
          interrupts[index] = error;
        } else if (failure == null) {
          failure = BatchItemException(index, error);
          failedAt = stackTrace;
        }
      }
    }

    if (maxConcurrency == 0) {
      for (final index in indices) {
        await runItem(index);
      }
    } else {
      final pending = indices.iterator;
      Future<void> worker() async {
        while (pending.moveNext()) {
          await runItem(pending.current);
        }
      }

      await Future.wait([
        for (var i = 0; i < maxConcurrency && i < indices.length; i++) worker(),
      ]);
    }

    final failed = failure;
    if (failed != null) {
      Error.throwWithStackTrace(failed, failedAt ?? StackTrace.current);
    }

    if (interrupts.isNotEmpty) {
      final interrupted = interrupts.keys.toList()..sort();
      throw compositeInterrupt(
        ctx,
        null,
        _BatchInterruptState(
          originalInputs: List<Object?>.of(effective),
          completedResults: Map<int, Object?>.of(results),
          interruptedIndices: interrupted,
          totalCount: effective.length,
        ),
        [for (final index in interrupted) interrupts[index]!],
      );
    }

    return [for (var i = 0; i < effective.length; i++) results[i] as O];
  }

  static T _typed<T>(Object? value, String what) {
    final revived = reviveFor<T>(value);
    if (revived is T) return revived;
    throw StateError(
      'a saved $what of the batch is a ${value.runtimeType}, not a $T',
    );
  }
}

/// One item of a batch failed. [cause] is what its run threw.
///
/// Port of the error `batch.Node` wraps the first failed item in. The other
/// items of the batch are run to their end before it is thrown.
class BatchItemException extends ThreepioException {
  /// The failure of the item at [index].
  BatchItemException(this.index, Object cause)
      : super('task $index failed: $cause', cause: cause);

  /// The position of the failed item in the input list.
  final int index;

  @override
  String toString() => 'BatchItemException: $message';
}
