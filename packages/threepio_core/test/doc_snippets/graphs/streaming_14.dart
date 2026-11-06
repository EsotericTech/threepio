// Mirrors "Streaming" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

// #docregion concat
/// A running count that a node streams as it goes.
final class Tally {
  const Tally(this.count);
  final int count;
}

void registerTally() {
  // Go: compose.RegisterStreamChunkConcatFunc. Tells the graph how chunks of
  // a Tally stream become one Tally, for a node that takes a whole value.
  StreamConcat.register<Tally>(
    (chunks) => Tally(chunks.fold(0, (sum, chunk) => sum + chunk.count)),
  );
}
// #enddocregion concat

Future<String> streamRun(
  RunContext ctx,
  Runnable<Map<String, dynamic>, Message> runnable,
) async {
  // #docregion stream
  final chunks = await runnable.stream(ctx, {'topic': 'streams'});
  final buffer = StringBuffer();
  for (var chunk = await chunks.nextOrNull();
      chunk != null;
      chunk = await chunks.nextOrNull()) {
    buffer.write(chunk.content);
  }
  await chunks.close();
  // #enddocregion stream
  return buffer.toString();
}
