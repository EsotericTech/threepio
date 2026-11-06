// Mirrors "Lambda" of doc/GRAPHS.md.
import 'package:threepio_core/compose.dart';

List<Lambda<Object?, Object?>> lambdaKinds() {
  // #docregion kinds
  // Value in, value out. Go: compose.InvokableLambda.
  final upper = Lambda<String, String>.invokable(
    (ctx, input) => input.toUpperCase(),
  );

  // Value in, stream out. Go: compose.StreamableLambda.
  final words = Lambda<String, String>.streamable(
    (ctx, input) => StreamReader.fromIterable(input.split(' ')),
  );

  // Stream in, value out. Go: compose.CollectableLambda.
  final length = Lambda<String, int>.collectable(
    (ctx, input) async => (await input.collectAll()).join().length,
  );

  // Stream in, stream out. Go: compose.TransformableLambda.
  final lower = Lambda<String, String>.transformable(
    (ctx, input) => input.convert((chunk) => chunk.toLowerCase()),
  );

  // Several at once. Go: compose.AnyLambda.
  final trim = Lambda<String, String>.any(
    invoke: (ctx, input) => input.trim(),
    transform: (ctx, input) => input.convert((chunk) => chunk.trim()),
  );
  // #enddocregion kinds
  return [upper, words, length, lower, trim];
}

// #docregion options
/// The option type of the lambda below.
final class Greeting {
  const Greeting(this.salutation);
  final String salutation;
}

final greet = Lambda.invokableWithOption<String, String, Greeting>(
  (ctx, name, options) {
    final salutation =
        options.isEmpty ? 'Hello' : options.last.salutation;
    return '$salutation, $name';
  },
  options: const LambdaOptions(type: 'Greeter'),
);
// #enddocregion options

Future<String> greetWithOption(RunContext ctx) async {
  final graph = Graph<String, String>()
    ..addLambdaNode('greet', greet)
    ..addEdge(Graph.start, 'greet')
    ..addEdge('greet', Graph.end);
  final runnable = await graph.compile(ctx);
  // #docregion option-call
  final answer = await runnable.invoke(
    ctx,
    'Ada',
    options: [CallOption.lambda<Greeting>([const Greeting('Welcome')])],
  ); // 'Welcome, Ada'
  // #enddocregion option-call
  return answer;
}
