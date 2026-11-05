/// The type-erased runnable every node of a graph is compiled to.
@internal
library;

import 'package:meta/meta.dart';

import '../callbacks/run_info.dart';
import '../core/run_context.dart';
import '../streaming/stream_reader.dart';
import 'errors.dart';
import 'graph_options.dart';
import 'type_ref.dart';

/// Runs a node on a value. Port of eino `invoke`.
typedef ErasedInvoke = Future<Object?> Function(
  RunContext ctx,
  Object? input,
  List<Object?> options,
);

/// Runs a node on a stream. Port of eino `transform`.
typedef ErasedTransform = Future<StreamReader<Object?>> Function(
  RunContext ctx,
  StreamReader<Object?> input,
  List<Object?> options,
);

/// What kind of thing a node runs. Port of eino `executorMeta`.
final class ExecutorMeta {
  /// The description of an executor.
  const ExecutorMeta({
    required this.component,
    this.isComponentCallbackEnabled = false,
    this.componentImplType = '',
    this.isPassthrough = false,
  });

  /// The kind of component.
  final ComponentType component;

  /// Whether the component fires its own callbacks. When it does not, the
  /// graph fires them around the node.
  final bool isComponentCallbackEnabled;

  /// The implementation, as [RunInfo.type] reports it.
  final String componentImplType;

  /// Whether this is a passthrough node. Eino has a component kind for it;
  /// here it is a flag, because the kinds are an enum other code relies on.
  final bool isPassthrough;
}

/// What a graph knows about one of its nodes besides how to run it.
///
/// Port of eino `nodeInfo`.
final class NodeInfo {
  /// The information of a node.
  NodeInfo({
    this.name = '',
    this.inputKey = '',
    this.outputKey = '',
    this.preProcessor,
    this.postProcessor,
    this.compileOptions,
  });

  /// The display name, [RunInfo.name] of the node's callbacks.
  final String name;

  /// The key the node's input is taken from when its predecessor gives a map.
  final String inputKey;

  /// The key the node's output is wrapped under.
  String outputKey;

  /// The state handler that runs before the node.
  final ComposableRunnable? preProcessor;

  /// The state handler that runs after the node.
  final ComposableRunnable? postProcessor;

  /// The options a nested graph is compiled with.
  GraphCompileOptions? compileOptions;
}

/// A runnable without its types: values travel as `Object?`, streams as
/// `StreamReader<Object?>`.
///
/// Port of eino `composableRunnable`. It is what a graph runs; the typed
/// functions it was made from are captured in [invoke] and [transform].
final class ComposableRunnable {
  /// A runnable made of [invoke] and [transform].
  ComposableRunnable({
    required this.invoke,
    required this.transform,
    this.inputType,
    this.outputType,
    this.optionType,
    this.helper,
    this.isPassthrough = false,
    this.meta,
    this.nodeInfo,
  });

  /// Runs on a value.
  final ErasedInvoke invoke;

  /// Runs on a stream.
  final ErasedTransform transform;

  /// The input type. `null` for a passthrough node until its neighbours tell.
  TypeRef<Object?>? inputType;

  /// The output type. `null` for a passthrough node until its neighbours tell.
  TypeRef<Object?>? outputType;

  /// The type of the call options the runnable takes. `null` for a graph,
  /// which takes the call options of the run as they are.
  final TypeRef<Object?>? optionType;

  /// The type-dependent operations for input and output.
  GenericHelper? helper;

  /// Whether this is a passthrough node.
  final bool isPassthrough;

  /// What kind of component this runs.
  ExecutorMeta? meta;

  /// The node this runs as.
  NodeInfo? nodeInfo;

  /// The same runnable as a separate object, so that a graph can give it a
  /// node of its own without changing the original.
  ComposableRunnable copy({ErasedInvoke? invoke, ErasedTransform? transform}) =>
      ComposableRunnable(
        invoke: invoke ?? this.invoke,
        transform: transform ?? this.transform,
        inputType: inputType,
        outputType: outputType,
        optionType: optionType,
        helper: helper,
        isPassthrough: isPassthrough,
        meta: meta,
        nodeInfo: nodeInfo,
      );
}

/// A node that hands its input on unchanged.
///
/// Port of eino `composablePassthrough`.
ComposableRunnable composablePassthrough() => ComposableRunnable(
      invoke: (ctx, input, options) async => input,
      transform: (ctx, input, options) async => input,
      isPassthrough: true,
      nodeInfo: NodeInfo(),
      meta: const ExecutorMeta(
        component: ComponentType.custom,
        componentImplType: 'Passthrough',
        isPassthrough: true,
      ),
    );

/// [runnable] behind an input key: it takes a map and runs on the value under
/// [key].
///
/// Port of eino `inputKeyedComposableRunnable`.
ComposableRunnable inputKeyedComposableRunnable(
  String key,
  ComposableRunnable runnable,
) {
  final valueType = runnable.inputType ?? const TypeRef<Object?>();
  return runnable.copy(
    invoke: (ctx, input, options) async {
      if (input is! Map<Object?, Object?> || !input.containsKey(key)) {
        throw ComposeTypeException('cannot find input key: $key');
      }
      return runnable.invoke(ctx, input[key], options);
    },
    transform: (ctx, input, options) async =>
        runnable.transform(ctx, valueType.streamOfKey(key, input), options),
  )
    ..inputType = mapType
    ..helper = runnable.helper?.forMapInput();
}

/// [runnable] behind an output key: what it gives is wrapped in a map under
/// [key].
///
/// Port of eino `outputKeyedComposableRunnable`.
ComposableRunnable outputKeyedComposableRunnable(
  String key,
  ComposableRunnable runnable,
) =>
    runnable.copy(
      invoke: (ctx, input, options) async =>
          <String, Object?>{key: await runnable.invoke(ctx, input, options)},
      transform: (ctx, input, options) async {
        final output = await runnable.transform(ctx, input, options);
        return output.convert<Map<String, Object?>>(
          (chunk) => <String, Object?>{key: chunk},
        );
      },
    )
      ..outputType = mapType
      ..helper = runnable.helper?.forMapOutput();
