// ignore_for_file: avoid_print

/// A graph with state: a translation assistant that loops "translate →
/// review" until the quality is good enough or the round limit is reached.
///
/// Port of eino-examples `compose/graph/state/state_graph.go`. What it shows:
///
/// * `LocalState.of` (Go `compose.WithGenLocalState`): the graph creates a
///   `TranslateState` for every run.
/// * `NodeOptions.statePreHandler` / `statePostHandler` (Go
///   `compose.WithStatePreHandler` / `WithStatePostHandler`): handlers that
///   get the state before and after a node runs.
/// * `processState` (Go `compose.ProcessState`): a lambda and a branch
///   condition reach the state themselves.
/// * `GraphCompileOptions(maxRunSteps: 10)` (Go `compose.WithMaxRunSteps(10)`)
///   to bound the loop.
///
/// It needs no model or key:
///
/// ```bash
/// dart run example/eino_examples/compose_graph_state.dart
/// ```
///
/// It prints what the Go program prints, line for line. The loop ends after
/// round 2: the review of round 2 contains the round-1 entry of the history,
/// so `[reviewed]` appears twice and the quality reaches 7.
///
/// ```text
/// === Input: "The quick brown fox jumps over the lazy dog" ===
///
///   [State] round incremented to 1
///   [State] history saved, total 1 entries
///   [Branch] round=1, quality=5/10
///   [Branch] → translate
///   [State] round incremented to 2
///   [State] history saved, total 2 entries
///   [Branch] round=2, quality=7/10
///   [Branch] → END
///
/// === Final Result ===
/// [Round 2 translation]
///
/// Previous translations:
/// [Round 1 translation]
///   快速的棕色狐狸跳过了懒狗 [reviewed]
///   快速的棕色狐狸跳过了懒狗 [reviewed]
/// ```
library;

import 'package:threepio_core/compose.dart';

// ============================================================
// State graph example: a multi-round translation assistant
//
// Loops "translate → review" until the quality is good enough or the
// maximum number of rounds is reached.
// What state is for: a branch makes a decision that depends on the state
// (a closure variable cannot do that).
//
//   START → translate ──→ review ──→ Branch(quality ok?) ──→ END
//             ↑                          │ no
//             └──────────────────────────┘
//
// Two ways to reach the state:
//   - way 1: statePreHandler / statePostHandler — given to the handler before
//     / after the node runs
//   - way 2: processState — called from inside a lambda or a branch
// ============================================================

/// The state of one run.
final class TranslateState {
  /// The current round.
  int round = 0;

  /// The translations so far.
  final List<String> history = [];
}

/// The key of the translate node.
const nodeTranslate = 'translate';

/// The key of the review node.
const nodeReview = 'review';

/// Way 2, `processState`: the lambda reads the state itself.
Lambda<String, String> newTranslateNode() =>
    Lambda.invokable((ctx, String input) async {
      var roundNum = 0;
      var historyStr = '';

      await processState<TranslateState>(ctx, (ctx, s) {
        roundNum = s.round;
        if (s.history.isNotEmpty) {
          historyStr = '\n\nPrevious translations:\n${s.history.join('\n')}';
        }
      });

      return '[Round $roundNum translation]$historyStr\n  '
          '${mockTranslate(input)}';
    });

/// The review node: a lambda without state.
Lambda<String, String> newReviewNode() =>
    Lambda.invokable((ctx, String input) => mockReview(input));

/// Way 1, a state pre-handler: changes the state before the node runs.
String roundIncrement(RunContext ctx, String input, TranslateState state) {
  state.round++;
  print('  [State] round incremented to ${state.round}');
  return input;
}

/// Way 1, a state post-handler: changes the state after the node has run.
String saveHistory(RunContext ctx, String output, TranslateState state) {
  state.history.add(output);
  print('  [State] history saved, total ${state.history.length} entries');
  return output;
}

/// ★ Where state cannot be replaced: a branch condition reads it with
/// `processState` (a branch has no other way to reach per-run data).
Future<String> qualityBranch(RunContext ctx, String output) async {
  var next = '';
  await processState<TranslateState>(ctx, (ctx, s) {
    final quality = mockQualityCheck(output);
    print('  [Branch] round=${s.round}, quality=$quality/10');

    if (quality >= 6 || s.round >= 3) {
      next = Graph.end;
      print('  [Branch] → END');
    } else {
      next = nodeTranslate;
      print('  [Branch] → translate');
    }
  });
  return next;
}

/// Builds and compiles the translate → review loop.
///
/// Go: `buildGraph`. Dart takes the state factory and the handlers as
/// objects (`LocalState.of`, `NodeOptions`) where Go takes option functions
/// (`WithGenLocalState`, `WithStatePreHandler`, `WithStatePostHandler`), and
/// a building mistake throws instead of being returned.
Future<Runnable<String, String>> buildGraph(RunContext ctx) {
  final g = Graph<String, String>(
    localState: LocalState.of<TranslateState>((ctx) => TranslateState()),
  )
    ..addLambdaNode(
      nodeTranslate,
      newTranslateNode(),
      options: NodeOptions(
        statePreHandler: StateHandler.pre<String, TranslateState>(
          roundIncrement,
        ),
      ),
    )
    ..addLambdaNode(
      nodeReview,
      newReviewNode(),
      options: NodeOptions(
        statePostHandler: StateHandler.post<String, TranslateState>(
          saveHistory,
        ),
      ),
    )
    ..addBranch(
      nodeReview,
      GraphBranch.single<String>(qualityBranch, {Graph.end, nodeTranslate}),
    )
    ..addEdge(Graph.start, nodeTranslate)
    ..addEdge(nodeTranslate, nodeReview);

  return g.compile(ctx, options: const GraphCompileOptions(maxRunSteps: 10));
}

/// The "translation": always the same Chinese sentence, as in Go.
String mockTranslate(String input) => '快速的棕色狐狸跳过了懒狗';

/// The "review": marks the text as reviewed.
String mockReview(String input) => '$input [reviewed]';

/// The "quality": the more often the text was reviewed, the better.
int mockQualityCheck(String input) {
  final reviewed = '[reviewed]'.allMatches(input).length;
  return switch (reviewed) {
    >= 3 => 9,
    >= 2 => 7,
    _ => 5,
  };
}

/// Runs the graph on the sentence of the Go program and prints what happens.
/// Returns the final result.
Future<String> runStateGraph() async {
  final ctx = RunContext.background();

  final run = await buildGraph(ctx);

  print('=== Input: "The quick brown fox jumps over the lazy dog" ===');
  print('');

  final result =
      await run.invoke(ctx, 'The quick brown fox jumps over the lazy dog');

  print('\n=== Final Result ===\n$result');
  return result;
}

/// Unlike the other examples this one needs no model, so `main` runs it
/// directly. Go exits with status 1 on an error; here the error is thrown.
Future<void> main() async {
  await runStateGraph();
}
