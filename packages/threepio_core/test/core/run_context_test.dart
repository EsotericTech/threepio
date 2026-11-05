import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/core/run_context.dart';

final _name = ContextKey<String>('name');
final _count = ContextKey<int>('count');

void main() {
  group('RunContext', () {
    test('background has no values and a token of its own', () {
      final ctx = RunContext.background();

      expect(ctx.value(_name), isNull);
      expect(ctx.cancelToken.isCancelled, isFalse);
      expect(
        RunContext.background().cancelToken,
        isNot(same(ctx.cancelToken)),
      );
    });

    test('background takes a cancel token', () {
      final token = CancelToken();

      expect(RunContext.background(cancelToken: token).cancelToken, same(token));
    });

    test('withValue returns a copy and leaves the original alone', () {
      final root = RunContext.background();

      final named = root.withValue(_name, 'eino');

      expect(named, isNot(same(root)));
      expect(named.value(_name), 'eino');
      expect(root.value(_name), isNull);
    });

    test('copies made from the same context do not see each other', () {
      final root = RunContext.background().withValue(_name, 'root');

      final left = root.withValue(_name, 'left').withValue(_count, 1);
      final right = root.withValue(_count, 2);

      expect(root.value(_name), 'root');
      expect(root.value(_count), isNull);
      expect(left.value(_name), 'left');
      expect(left.value(_count), 1);
      expect(right.value(_name), 'root');
      expect(right.value(_count), 2);
    });

    test('a value can be replaced in a copy', () {
      final first = RunContext.background().withValue(_count, 1);
      final second = first.withValue(_count, 2);

      expect(first.value(_count), 1);
      expect(second.value(_count), 2);
    });

    test('values are typed by their key', () {
      final ctx = RunContext.background()
          .withValue(_name, 'eino')
          .withValue(_count, 3);

      final String? name = ctx.value(_name);
      final int? count = ctx.value(_count);

      expect(name, 'eino');
      expect(count, 3);
    });

    test('keys are compared by identity, not by name', () {
      final one = ContextKey<String>('same');
      final other = ContextKey<String>('same');

      final ctx = RunContext.background().withValue(one, 'value');

      expect(ctx.value(one), 'value');
      expect(ctx.value(other), isNull);
    });

    test('const keys with the same type and name are one key', () {
      const one = ContextKey<String>('same');
      const other = ContextKey<String>('same');
      const otherType = ContextKey<int>('same');

      final ctx = RunContext.background().withValue(one, 'value');

      expect(ctx.value(other), 'value');
      expect(ctx.value(otherType), isNull);
    });

    test('withCancelToken replaces the token and keeps the values', () {
      final first = CancelToken();
      final second = CancelToken();
      final root =
          RunContext.background(cancelToken: first).withValue(_name, 'eino');

      final replaced = root.withCancelToken(second);

      expect(replaced.cancelToken, same(second));
      expect(replaced.value(_name), 'eino');
      expect(root.cancelToken, same(first));

      second.cancel();
      expect(root.cancelToken.isCancelled, isFalse);
    });

    test('withValue keeps the cancel token', () {
      final token = CancelToken();
      final ctx =
          RunContext.background(cancelToken: token).withValue(_count, 1);

      token.cancel('stop');

      expect(ctx.cancelToken.isCancelled, isTrue);
      expect(ctx.cancelToken.reason, 'stop');
    });

    test('toString names the keys', () {
      final ctx = RunContext.background().withValue(_name, 'eino');

      expect('$ctx', contains('name'));
      expect('$_name', 'ContextKey<String>(name)');
    });
  });

  group('CancelToken.any', () {
    test('returns null when there is no token', () {
      expect(CancelToken.any([]), isNull);
      expect(CancelToken.any([null, null]), isNull);
    });

    test('returns a single token as it is', () {
      final token = CancelToken();

      expect(CancelToken.any([token]), same(token));
      expect(CancelToken.any([null, token, null]), same(token));
      expect(CancelToken.any([token, token]), same(token));
    });

    test('is cancelled in the same call that cancels one of its tokens', () {
      final first = CancelToken();
      final second = CancelToken();
      final combined = CancelToken.any([first, second])!;
      expect(combined.isCancelled, isFalse);

      second.cancel('second fired');

      // No await in between: a check right after the cancel must see it.
      expect(combined.isCancelled, isTrue);
      expect(combined.reason, 'second fired');
      expect(combined.throwIfCancelled, throwsA(isA<CancelledException>()));
      expect(first.isCancelled, isFalse);
    });

    test('completes whenCancelled', () async {
      final first = CancelToken();
      final combined = CancelToken.any([first, CancelToken()])!;

      first.cancel('done');

      await expectLater(combined.whenCancelled, completes);
    });

    test('combined tokens can be combined again', () {
      final a = CancelToken();
      final b = CancelToken();
      final c = CancelToken();
      final inner = CancelToken.any([a, b])!;
      final outer = CancelToken.any([inner, c])!;

      a.cancel('a');

      expect(inner.isCancelled, isTrue);
      expect(outer.isCancelled, isTrue);
      expect(outer.reason, 'a');
      expect(c.isCancelled, isFalse);
    });

    test('many short-lived combinations of one token all hear of its cancel',
        () {
      final session = CancelToken();
      final calls = [
        for (var i = 0; i < 1000; i++)
          CancelToken.any([session, CancelToken()])!,
      ];
      // Calls that ended on their own no longer depend on the session token.
      for (final call in calls.take(500)) {
        call.cancel('call over');
      }

      session.cancel('session over');

      expect(calls.every((call) => call.isCancelled), isTrue);
      expect(calls.first.reason, 'call over');
      expect(calls.last.reason, 'session over');
    });

    test('keeps the reason of the token that fired first', () async {
      final first = CancelToken();
      final second = CancelToken();
      final combined = CancelToken.any([first, second])!;

      second.cancel('second');
      first.cancel('first');
      await combined.whenCancelled;

      expect(combined.reason, 'second');
    });

    test('is cancelled from the start when a token already was', () {
      final first = CancelToken();
      final second = CancelToken()..cancel('earlier');

      final combined = CancelToken.any([first, null, second])!;

      expect(combined, isNot(same(second)));
      expect(combined.isCancelled, isTrue);
      expect(combined.reason, 'earlier');
      expect(combined.throwIfCancelled, throwsA(isA<CancelledException>()));
    });

    test('cancelling the combined token leaves its sources alone', () {
      final first = CancelToken();
      final second = CancelToken();

      CancelToken.any([first, second])!.cancel('only me');

      expect(first.isCancelled, isFalse);
      expect(second.isCancelled, isFalse);
    });

    test('combines the token of the options with the one of the context',
        () async {
      // What a provider does with ChatModelOptions.cancelToken and
      // options.runContext?.cancelToken.
      final fromOptions = CancelToken();
      final ctx = RunContext.background();

      final effective =
          CancelToken.any([fromOptions, ctx.cancelToken])!;
      ctx.cancelToken.cancel('run cancelled');

      expect(effective.isCancelled, isTrue);
      expect(effective.reason, 'run cancelled');
    });
  });
}
