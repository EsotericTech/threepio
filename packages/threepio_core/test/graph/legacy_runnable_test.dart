import 'package:test/test.dart';
import 'package:threepio_core/src/graph/legacy_runnable.dart';

void main() {
  group('LegacyLambda', () {
    test('invoke-only lambda works', () async {
      final lambda = LegacyLambda<String, String>(
        invoke: (input, options) async => input.toUpperCase(),
      );

      final result = await lambda.invoke('hello');
      expect(result, equals('HELLO'));
    });

    test('stream-only lambda works', () async {
      final lambda = LegacyLambda<String, String>(
        stream: (input, options) async* {
          for (final char in input.split('')) {
            yield char.toUpperCase();
          }
        },
      );

      final results = await lambda.stream('abc').toList();
      expect(results, equals(['A', 'B', 'C']));
    });

    test('invoke falls back to stream.first', () async {
      final lambda = LegacyLambda<String, String>(
        stream: (input, options) async* {
          yield input.toUpperCase();
        },
      );

      final result = await lambda.invoke('hello');
      expect(result, equals('HELLO'));
    });

    test('stream falls back to wrapping invoke', () async {
      final lambda = LegacyLambda<String, String>(
        invoke: (input, options) async => input.toUpperCase(),
      );

      final results = await lambda.stream('hello').toList();
      expect(results, equals(['HELLO']));
    });

    test('collect works with custom function', () async {
      final lambda = LegacyLambda<String, String>(
        collect: (input, options) async {
          final items = await input.toList();
          return items.join('');
        },
      );

      final result = await lambda.collect(Stream.fromIterable(['a', 'b', 'c']));
      expect(result, equals('abc'));
    });

    test('transform works with stream mapping', () async {
      final lambda = LegacyLambda<String, String>(
        transform: (input, options) {
          return input.map((s) => s.toUpperCase());
        },
      );

      final results =
          await lambda.transform(Stream.fromIterable(['a', 'b', 'c'])).toList();
      expect(results, equals(['A', 'B', 'C']));
    });

    test('throws when no execution mode provided', () {
      expect(
        () => LegacyLambda<String, String>(),
        throwsArgumentError,
      );
    });

    test('pipe composes lambdas', () async {
      final lambda1 = LegacyLambda<String, String>(
        invoke: (input, options) async => input.toUpperCase(),
      );

      final lambda2 = LegacyLambda<String, int>(
        invoke: (input, options) async => input.length,
      );

      final piped = lambda1.pipe(lambda2);

      final result = await piped.invoke('hello');
      expect(result, equals(5)); // 'HELLO'.length
    });

    test('batch processes multiple inputs', () async {
      final lambda = LegacyLambda<int, int>(
        invoke: (input, options) async => input * 2,
      );

      final results = await lambda.batch([1, 2, 3, 4, 5]);
      expect(results, equals([2, 4, 6, 8, 10]));
    });

    test('batchParallel processes multiple inputs in parallel', () async {
      final lambda = LegacyLambda<int, int>(
        invoke: (input, options) async {
          // Simulate async work
          await Future.delayed(Duration(milliseconds: 10));
          return input * 2;
        },
      );

      final results = await lambda.batchParallel([1, 2, 3, 4, 5]);
      expect(results, equals([2, 4, 6, 8, 10]));
    });
  });

  group('LegacyLambda helper functions', () {
    test('lambda() creates invoke-only lambda', () async {
      final l = lambda<String, String>((input) async => input.toUpperCase());

      final result = await l.invoke('hello');
      expect(result, equals('HELLO'));
    });

    test('streamingLambda() creates stream-only lambda', () async {
      final l = streamingLambda<String, String>(
        (input) async* {
          for (final char in input.split('')) {
            yield char.toUpperCase();
          }
        },
      );

      final results = await l.stream('abc').toList();
      expect(results, equals(['A', 'B', 'C']));
    });

    test('syncLambda() creates synchronous lambda', () async {
      final l = syncLambda<String, String>((input) => input.toUpperCase());

      final result = await l.invoke('hello');
      expect(result, equals('HELLO'));
    });
  });

  group('LegacyRunnableSequence', () {
    test('composes two runnables in sequence', () async {
      final first = LegacyLambda<String, String>(
        invoke: (input, options) async => input.toUpperCase(),
      );

      final second = LegacyLambda<String, int>(
        invoke: (input, options) async => input.length,
      );

      final sequence = LegacyRunnableSequence(first: first, second: second);

      final result = await sequence.invoke('hello');
      expect(result, equals(5));
    });

    test('stream mode chains properly', () async {
      final first = LegacyLambda<String, String>(
        stream: (input, options) async* {
          yield input.toUpperCase();
          yield input.toLowerCase();
        },
      );

      final second = LegacyLambda<String, int>(
        invoke: (input, options) async => input.length,
      );

      final sequence = LegacyRunnableSequence(first: first, second: second);

      final results = await sequence.stream('HELLO').toList();
      expect(results, hasLength(2));
      expect(results[0], equals(5));
      expect(results[1], equals(5));
    });

    test('collect mode works', () async {
      final first = LegacyLambda<String, String>(
        collect: (input, options) async {
          final items = await input.toList();
          return items.join('');
        },
      );

      final second = LegacyLambda<String, String>(
        invoke: (input, options) async => input.toUpperCase(),
      );

      final sequence = LegacyRunnableSequence(first: first, second: second);

      final result =
          await sequence.collect(Stream.fromIterable(['a', 'b', 'c']));
      expect(result, equals('ABC'));
    });

    test('transform mode chains streams', () async {
      final first = LegacyLambda<String, String>(
        transform: (input, options) => input.map((s) => s.toUpperCase()),
      );

      final second = LegacyLambda<String, int>(
        transform: (input, options) => input.map((s) => s.length),
      );

      final sequence = LegacyRunnableSequence(first: first, second: second);

      final results = await sequence
          .transform(Stream.fromIterable(['a', 'bb', 'ccc']))
          .toList();
      expect(results, equals([1, 2, 3]));
    });
  });

  group('LegacyRunnableOptions', () {
    test('copyWith creates new instance with updated values', () {
      final options = LegacyRunnableOptions(
        metadata: {'key': 'value'},
        tags: ['tag1'],
      );

      final updated = options.copyWith(
        metadata: {'new': 'data'},
        tags: ['tag2'],
      );

      expect(updated.metadata, equals({'new': 'data'}));
      expect(updated.tags, equals(['tag2']));

      // Original unchanged
      expect(options.metadata, equals({'key': 'value'}));
      expect(options.tags, equals(['tag1']));
    });

    test('copyWith preserves unspecified values', () {
      final options = LegacyRunnableOptions(
        metadata: {'key': 'value'},
        tags: ['tag1'],
      );

      final updated = options.copyWith(
        metadata: {'new': 'data'},
      );

      expect(updated.metadata, equals({'new': 'data'}));
      expect(updated.tags, equals(['tag1'])); // Preserved
    });
  });

  group('LegacyRunnableException', () {
    test('toString includes message', () {
      final ex = LegacyRunnableException('Test error');
      expect(ex.toString(), contains('Test error'));
    });

    test('toString includes runnable type', () {
      final ex = LegacyRunnableException(
        'Test error',
        runnableType: 'TestRunnable',
      );
      expect(ex.toString(), contains('TestRunnable'));
    });

    test('toString includes cause', () {
      final cause = Exception('Root cause');
      final ex = LegacyRunnableException('Test error', cause: cause);
      expect(ex.toString(), contains('Root cause'));
    });
  });
}
