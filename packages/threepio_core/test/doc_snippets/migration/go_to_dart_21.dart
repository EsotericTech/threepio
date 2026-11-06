// Mirror of doc/MIGRATION.md, "For Eino (Go) users".
// ignore_for_file: avoid_print
import 'package:threepio_core/compose.dart';

/// The state of a review graph, written to checkpoints as JSON.
final class ReviewState {
  ReviewState(this.round);

  factory ReviewState.fromJson(Map<String, Object?> json) =>
      ReviewState(json['round']! as int);

  final int round;

  Map<String, Object?> toJson() => {'round': round};
}

/// Call once, before a run is interrupted or resumed.
void registerReviewState() {
  // Go: schema.RegisterName[*ReviewState]("review_state")
  TypeRegistry.registerName<ReviewState>(
    'review_state',
    fromJson: ReviewState.fromJson,
    toJson: (state) => state.toJson(),
  );
}

Future<void> goToDart(
  Runnable<String, String> runnable,
  ComponentCallbackHandler handler,
) async {
  // Go: ctx := context.Background()
  final ctx = RunContext.background();

  // Go: out, err := runnable.Invoke(ctx, "hi", compose.WithCallbacks(handler))
  try {
    final out = await runnable.invoke(
      ctx,
      'hi',
      options: [CallOption.callbacks([handler])],
    );
    print(out);
  } on ThreepioException catch (e) {
    print('failed: $e');
  }

  // Go: sr, err := runnable.Stream(ctx, "hi"); for { chunk, err := sr.Recv() … }
  final reader = await runnable.stream(ctx, 'hi');
  try {
    for (var chunk = await reader.nextOrNull();
        chunk != null;
        chunk = await reader.nextOrNull()) {
      print(chunk);
    }
  } finally {
    await reader.close();
  }
}
