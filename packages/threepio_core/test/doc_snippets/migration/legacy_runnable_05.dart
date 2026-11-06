// Mirror of doc/MIGRATION.md, break 4: LegacyRunnable.
// ignore_for_file: avoid_print
import 'package:threepio_core/legacy_graph.dart';

Future<void> main() async {
  final graph = StateGraph<MapState>()
    ..addNode('greet', (state) async => state.set('greeting', 'hello'))
    ..addEdge('greet', END)
    ..setEntryPoint('greet');

  // Before 0.9 the types were Runnable and Lambda, imported from src/compose/.
  final runnable = graph.toRunnable().pipe(
        LegacyLambda<GraphResult<MapState>, String>(
          invoke: (result, options) async =>
              result.state.get<String>('greeting') ?? '',
        ),
      );
  print(await runnable.invoke(MapState()));
}
