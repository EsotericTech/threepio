// Port of the four tests of eino `adk/middlewares/summarization/
// finalizer_builder_test.go` that append raw handlers to the builder
// (`b.handlers = append(...)`): TestBuildStepChaining, TestBuildStepError,
// TestBuildHandlerReturnsEmpty, TestBuildPostProcessError. Dart reaches the
// handler list through the test-only `SummaryFinalizerBuilder.addStep`.
// (`eino_summarization_finalizer_test.dart` has the other tests of the file,
// and versions of the first three built on `preserveSkills`.)
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';

void main() {
  final ctx = RunContext.background();

  test('TestBuildStepChaining', () async {
    final builder = SummaryFinalizerBuilder()
      ..addStep(
        (ctx, original, summary) => [summary.copyWith(content: '${summary.content} | step1')],
      )
      ..addStep(
        (ctx, original, summary) => [summary.copyWith(content: '${summary.content} | step2')],
      );
    final finalizer = builder.build();
    final result = await finalizer(ctx, const [], Message.assistant('start'));
    expect(result, hasLength(1));
    expect(result.single.role, RoleType.user);
    expect(result.single.content, contains('start | step1 | step2'));
  });

  test('TestBuildStepError', () async {
    final finalizer = (SummaryFinalizerBuilder()
          ..addStep((ctx, original, summary) => throw const ThreepioException('step failed')))
        .build();
    await expectLater(
      finalizer(ctx, const [], Message.user('test')),
      throwsA(predicate((e) => '$e'.contains('step failed'))),
    );
  });

  test('TestBuildHandlerReturnsEmpty', () async {
    final finalizer =
        (SummaryFinalizerBuilder()..addStep((ctx, original, summary) => const [])).build();
    await expectLater(
      finalizer(ctx, const [], Message.assistant('test')),
      throwsA(predicate((e) => '$e'.contains('finalizer handler returned no messages'))),
    );
  });

  test('TestBuildPostProcessError', () async {
    final finalizer = (SummaryFinalizerBuilder()
          ..addStep((ctx, original, summary) => [Message.user('not assistant')]))
        .build();
    await expectLater(
      finalizer(ctx, const [], Message.assistant('test')),
      throwsA(predicate((e) => '$e'.contains('summary content is empty'))),
    );
  });

  test('extra messages of the steps go between the system messages and the summary', () async {
    final finalizer = (SummaryFinalizerBuilder()
          ..addStep((ctx, original, summary) => [Message.user('extra 1'), summary])
          ..addStep((ctx, original, summary) => [Message.user('extra 2'), summary]))
        .build();
    final result = await finalizer(
      ctx,
      [Message.system('sys'), Message.user('question')],
      Message.assistant('<summary>s</summary>'),
    );
    expect(result.map((m) => m.content).take(3), ['sys', 'extra 1', 'extra 2']);
    expect(result.last.extra?['_eino_summarization_content_type'], 'summary');
  });
}
