// Mirrors the stream functions in "Firing callbacks from your own
// component" of doc/CALLBACKS.md.
import 'package:threepio_core/callbacks.dart' as callbacks;
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/streaming.dart';

Future<StreamReader<String>> streamOut(
  RunContext ctx,
  StreamReader<String> output,
) async {
  // #docregion stream
  // The stream is handed over: every interested handler gets a copy, and
  // the caller reads the returned reader instead of `output`.
  final (_, forCaller) = await callbacks.onEndWithStreamOutput<String>(
    ctx,
    output,
  );
  return forCaller;
  // #enddocregion stream
}
