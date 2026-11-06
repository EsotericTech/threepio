// Mirror of doc/MIGRATION.md, legacy: StateGraph (before).
// ignore_for_file: avoid_print
import 'package:threepio_core/threepio_core.dart';

class DraftState implements GraphState {
  const DraftState({this.text = '', this.round = 0});

  final String text;
  final int round;

  @override
  DraftState copyWith({String? text, int? round}) =>
      DraftState(text: text ?? this.text, round: round ?? this.round);
}

Future<String> reviseWithStateGraph(String draft) async {
  final graph = StateGraph<DraftState>()
    ..addNode(
      'write',
      (state) async =>
          state.copyWith(text: '${state.text}, revised', round: state.round + 1),
    )
    ..addConditionalEdge('write', (state) => state.round >= 3 ? END : 'write')
    ..setEntryPoint('write');
  final result = await graph.invoke(DraftState(text: draft));
  return result.state.text;
}
