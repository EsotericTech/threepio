// Mirrors "Chain" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

Future<String> chainParallelBranch(RunContext ctx) async {
  // #docregion parallel-branch
  final chain = Chain<String, String>()
    // Both lambdas get the input; the next node gets a map with each
    // output under its key. Go: compose.NewParallel, AppendParallel.
    ..appendParallel(
      Parallel()
        ..addLambda(
          'upper',
          Lambda<String, String>.invokable((ctx, s) => s.toUpperCase()),
        )
        ..addLambda(
          'length',
          Lambda<String, int>.invokable((ctx, s) => s.length),
        ),
    )
    ..appendLambda(
      Lambda<Map<String, Object?>, String>.invokable(
        (ctx, m) => '${m['upper']}:${m['length']}',
      ),
    )
    // The condition returns the key of the node that runs next.
    // Go: compose.NewChainBranch, AppendBranch.
    ..appendBranch(
      ChainBranch.single<String>(
        (ctx, input) => input.length > 4 ? 'long' : 'short',
      )
        ..addLambda(
          'long',
          Lambda<String, String>.invokable((ctx, s) => 'long($s)'),
        )
        ..addLambda(
          'short',
          Lambda<String, String>.invokable((ctx, s) => 'short($s)'),
        ),
    );
  final runnable = await chain.compile(ctx);
  final short = await runnable.invoke(ctx, 'ab'); // 'short(AB:2)'
  final long = await runnable.invoke(ctx, 'abc'); // 'long(ABC:3)'
  // #enddocregion parallel-branch
  return '$short $long';
}
