// Mirrors "Checkpoints" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

// #docregion register
/// The state of an order run; written into checkpoints.
final class OrderState {
  OrderState({this.approved = false});

  factory OrderState.fromJson(Map<String, Object?> json) =>
      OrderState(approved: json['approved']! as bool);

  bool approved;

  Map<String, Object?> toJson() => {'approved': approved};
}

void registerOrderState() {
  // Go: schema.RegisterName. Keep the name stable across releases: stored
  // checkpoints refer to it.
  TypeRegistry.registerName<OrderState>(
    'shop.order_state',
    fromJson: OrderState.fromJson,
    toJson: (state) => state.toJson(),
  );
}
// #enddocregion register

Future<String> interruptBefore(
  RunContext ctx,
  CheckpointStore store,
  Graph<String, String> graph,
) async {
  // #docregion before
  final runnable = await graph.compile(
    ctx,
    options: GraphCompileOptions(
      checkpointStore: store,
      // Go: compose.WithInterruptBeforeNodes / WithInterruptAfterNodes.
      interruptBeforeNodes: const ['send'],
    ),
  );

  final options = [CallOption.checkpointId('order-7')];
  try {
    return await runnable.invoke(ctx, 'order 7', options: options);
  } on GraphInterruptedException catch (interrupted) {
    final info = interrupted.info;
    assert(info.beforeNodes.contains('send'), 'stopped in front of send');
  }

  // Later, possibly in another process with a persistent store: the same
  // id goes on from the checkpoint. The modifier changes the saved state of
  // the graph (path []) before it continues.
  return runnable.invoke(
    ctx,
    '',
    options: [
      ...options,
      CallOption.stateModifier((ctx, path, state) {
        if (path.path.isEmpty) (state as OrderState).approved = true;
      }),
    ],
  );
  // #enddocregion before
}

Future<String> fromOutside(
  RunContext ctx,
  Runnable<String, String> runnable,
) async {
  // #docregion outside
  // Go: compose.WithGraphInterrupt.
  final (runCtx, interrupter) = ctx.withGraphInterrupt();
  final run = runnable.invoke(
    runCtx,
    'long job',
    options: [CallOption.checkpointId('job-1')],
  );

  // For example when the user presses "stop": wait up to two seconds for
  // the running nodes, then save what there is.
  interrupter.interrupt(timeout: const Duration(seconds: 2));

  try {
    return await run;
  } on GraphInterruptedException catch (interrupted) {
    // The nodes that had not finished run again, with their input, when
    // the run is resumed with 'job-1'.
    return 'stopped at ${interrupted.info.rerunNodes}';
  }
  // #enddocregion outside
}

Future<String> compositeExample(
  RunContext ctx,
  Runnable<String, String> inner,
) async {
  // #docregion composite
  // A lambda that runs a compiled graph of its own (compiled with a store).
  final runsInner = Lambda<String, String>.invokable((ctx, input) async {
    try {
      return await inner.invoke(
        ctx,
        input,
        options: [CallOption.checkpointId('inner')],
      );
    } on GraphInterruptedException catch (interrupted) {
      // Go: compose.CompositeInterrupt. The outer graph then checkpoints
      // too, and its caller sees the inner interrupt points.
      throw compositeInterrupt(ctx, null, null, [interrupted]);
    }
  });
  // #enddocregion composite
  final graph = Graph<String, String>()
    ..addLambdaNode('inner', runsInner)
    ..addEdge(Graph.start, 'inner')
    ..addEdge('inner', Graph.end);
  final runnable = await graph.compile(ctx);
  return runnable.invoke(ctx, 'x');
}

List<String> extract(Object error) {
  // #docregion extract
  // Go: compose.ExtractInterruptInfo. Also finds an interrupt that is the
  // cause of another exception.
  final info = extractInterruptInfo(error);
  if (info == null) return const [];
  return [
    // point.id is what ctx.resume and ctx.resumeWithData take; the address
    // says where, e.g. 'runnable:g;node:tools;tool:ask:call_2'.
    for (final point in info.interruptContexts) '${point.address}: ${point.info}',
  ];
  // #enddocregion extract
}
