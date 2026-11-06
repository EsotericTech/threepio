// Mirrors "Runnable: four ways to run" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

Future<List<Object>> runnableModes(RunContext ctx) async {
  // #docregion modes
  final graph = Graph<String, String>()
    ..addLambdaNode(
      'shout',
      Lambda<String, String>.invokable((ctx, input) => input.toUpperCase()),
    )
    ..addEdge(Graph.start, 'shout')
    ..addEdge('shout', Graph.end);
  final runnable = await graph.compile(ctx);

  // Value in, value out (Go: Invoke).
  final shouted = await runnable.invoke(ctx, 'hello'); // 'HELLO'

  // Value in, stream out (Go: Stream). The node answers with a value, so
  // the stream has one chunk.
  final chunks = await (await runnable.stream(ctx, 'hello')).collectAll();
  // chunks == ['HELLO']

  // Stream in, value out (Go: Collect). The chunks are joined first.
  final joined = await runnable.collect(
    ctx,
    StreamReader.fromIterable(['hel', 'lo']),
  ); // 'HELLO'

  // Stream in, stream out (Go: Transform).
  final output = await runnable.transform(
    ctx,
    StreamReader.fromIterable(['hel', 'lo']),
  );
  await output.close();
  // #enddocregion modes
  return [shouted, chunks, joined];
}
