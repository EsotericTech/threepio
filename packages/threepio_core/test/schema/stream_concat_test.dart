// The stream concat registry: a port of TestConcat of eino
// `internal/concat_test.go` (v0.9.22), the built-in functions, and the rule
// that a registration is matched with `is`, never by `runtimeType`.
import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/streaming.dart';

class Tally {
  const Tally(this.count);

  final int count;

  @override
  bool operator ==(Object other) => other is Tally && other.count == count;

  @override
  int get hashCode => count;

  @override
  String toString() => 'Tally($count)';
}

class LabelledTally extends Tally {
  const LabelledTally(super.count, this.label);

  final String label;
}

Tally sumTallies(List<Tally> chunks) =>
    Tally(chunks.fold(0, (sum, chunk) => sum + chunk.count));

void main() {
  setUp(StreamConcat.reset);
  tearDownAll(StreamConcat.reset);

  // TestConcat
  test('concat map chunks with nil value', () {
    final c1 = <String, Object?>{
      'a': {
        'b': {'c1': null},
      },
    };
    final c2 = <String, Object?>{
      'a': {
        'b': {'c2': 'c2'},
      },
    };

    expect(StreamConcat.concatItems([c1, c2]), {
      'a': {
        'b': {'c1': null, 'c2': 'c2'},
      },
    });
  });

  group('built-in functions', () {
    test('strings are concatenated', () {
      expect(StreamConcat.concatItems(['a', 'b', 'c']), 'abc');
    });

    test('of numbers, bools, dates and durations the last one wins', () {
      expect(StreamConcat.concatItems([1, 2, 3]), 3);
      expect(StreamConcat.concatItems([1.5, 2.5]), 2.5);
      expect(StreamConcat.concatItems<num>([1, 2.5]), 2.5);
      expect(StreamConcat.concatItems([true, false]), isFalse);
      expect(
        StreamConcat.concatItems([DateTime(2026), DateTime(2027)]),
        DateTime(2027),
      );
      expect(
        StreamConcat.concatItems([Duration.zero, const Duration(seconds: 2)]),
        const Duration(seconds: 2),
      );
    });

    test('maps are merged key by key, values by the same rules', () {
      final merged = StreamConcat.concatItems<Map<String, Object?>>([
        {
          'text': 'ab',
          'n': 1,
          'only': true,
          'nested': {'x': 'p'},
        },
        {
          'text': 'cd',
          'n': 2,
          'nested': {'x': 'q', 'y': 1},
        },
      ]);

      expect(merged, {
        'text': 'abcd',
        'n': 2,
        'only': true,
        'nested': {'x': 'pq', 'y': 1},
      });
    });

    test('lists inside maps cannot be joined, as in Eino', () {
      expect(
        () => StreamConcat.concatItems<Map<String, Object?>>([
          {
            'items': [1],
          },
          {
            'items': [2],
          },
        ]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cannot concat multiple non-zero value'),
          ),
        ),
      );
      // One of them empty is fine: the other one is the value.
      expect(
        StreamConcat.concatItems<Map<String, Object?>>([
          {'items': <int>[]},
          {
            'items': [2],
          },
        ]),
        {
          'items': [2],
        },
      );
    });

    test('messages use concatMessages', () {
      expect(
        StreamConcat.concatItems([
          Message.assistant('Hel'),
          Message.assistant('lo'),
        ]),
        Message.assistant('Hello'),
      );
    });

    test('lists of messages use concatMessageArray', () {
      expect(
        StreamConcat.concatItems([
          [Message.assistant('a'), Message.user('1')],
          [Message.assistant('b'), Message.user('2')],
        ]),
        [Message.assistant('ab'), Message.user('12')],
      );
    });

    test('tool results use concatToolResults', () {
      expect(
        StreamConcat.concatItems([
          ToolResult.text('Hello '),
          ToolResult.text('World'),
        ]),
        ToolResult.text('Hello World'),
      );
    });
  });

  group('concatItems', () {
    test('returns a single item as it is', () {
      final only = Message.assistant('only');
      const tally = Tally(1);

      expect(StreamConcat.concatItems([only]), same(only));
      expect(StreamConcat.concatItems([tally]), same(tally));
    });

    test('rejects an empty list', () {
      expect(() => StreamConcat.concatItems(<String>[]), throwsArgumentError);
    });

    test('without a function, at most one chunk may carry a value', () {
      const tally = Tally(1);

      expect(
        () => StreamConcat.concatItems([tally, const Tally(2)]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Tally'), contains('StreamConcat.register')),
          ),
        ),
      );
      expect(StreamConcat.concatItems<Object>(['', tally, 0]), same(tally));
      expect(
        StreamConcat.concatItems<List<int>>([[], [], []]),
        isEmpty,
      );
    });
  });

  group('register', () {
    test('adds a function for a type', () {
      StreamConcat.register<Tally>(sumTallies);

      expect(
        StreamConcat.concatItems([const Tally(1), const Tally(2)]),
        const Tally(3),
      );
    });

    test('a later registration replaces an earlier one and a built-in', () {
      StreamConcat.register<Tally>(sumTallies);
      StreamConcat.register<Tally>((chunks) => chunks.first);
      StreamConcat.register<String>((chunks) => chunks.join('|'));

      expect(
        StreamConcat.concatItems([const Tally(1), const Tally(2)]),
        const Tally(1),
      );
      expect(StreamConcat.concatItems(['a', 'b']), 'a|b');
    });

    test('reset brings the built-in functions back', () {
      StreamConcat.register<String>((chunks) => chunks.join('|'));
      StreamConcat.register<Tally>(sumTallies);

      StreamConcat.reset();

      expect(StreamConcat.concatItems(['a', 'b']), 'ab');
      expect(StreamConcat.resolve<Tally>(), isNull);
    });

    test('a function for a supertype can be followed by one for a subtype',
        () {
      StreamConcat.register<Tally>(sumTallies);
      StreamConcat.register<LabelledTally>(
        (chunks) => LabelledTally(
          chunks.last.count,
          chunks.map((chunk) => chunk.label).join('+'),
        ),
      );

      final labelled = StreamConcat.concatItems([
        const LabelledTally(1, 'a'),
        const LabelledTally(2, 'b'),
      ]);
      final plain = StreamConcat.concatItems<Tally>([
        const Tally(1),
        const LabelledTally(2, 'b'),
      ]);

      expect(labelled.label, 'a+b');
      expect(plain, const Tally(3));
    });
  });

  group('values are matched with is, not by runtimeType', () {
    test('freezed values, whose class is private', () {
      final chunks = [Message.assistant('a'), Message.assistant('b')];

      expect(chunks.first.runtimeType, isNot(Message));
      // Declared as Message, and declared as nothing in particular.
      expect(StreamConcat.concatItems(chunks), Message.assistant('ab'));
      expect(
        StreamConcat.concatItems<Object>(chunks),
        Message.assistant('ab'),
      );
    });

    test('lists, whatever their implementation', () {
      final growable = [Message.assistant('a')];
      final fixed = List<Message>.unmodifiable([Message.assistant('b')]);

      expect(
        StreamConcat.concatItems([growable, fixed]),
        [Message.assistant('ab')],
      );
      expect(
        StreamConcat.concatItems<Object>([growable, fixed]),
        [Message.assistant('ab')],
      );
    });

    test('maps, whatever their implementation and declared type', () {
      final plain = <String, Object?>{'a': 'x'};
      final dynamicMap = <String, dynamic>{'a': 'y'};
      final unmodifiable = Map<String, Object?>.unmodifiable({'b': 1});

      expect(
        StreamConcat.concatItems([plain, unmodifiable]),
        {'a': 'x', 'b': 1},
      );
      expect(
        StreamConcat.concatItems<Map<String, dynamic>>([dynamicMap, plain]),
        {'a': 'yx'},
      );
      expect(
        StreamConcat.concatItems<Object>([plain, dynamicMap]),
        {'a': 'xy'},
      );
    });

    test('a subtype is joined by the function of its supertype', () {
      StreamConcat.register<Tally>(sumTallies);

      expect(
        StreamConcat.concatItems<Tally>([
          const LabelledTally(1, 'a'),
          const LabelledTally(2, 'b'),
        ]),
        const Tally(3),
      );
      expect(StreamConcat.concatItems<int>([1, 2]), 2);
    });

    test('a result of the wrong type is reported, not passed on', () {
      StreamConcat.register<Tally>(sumTallies);

      expect(
        () => StreamConcat.concatItems<LabelledTally>([
          const LabelledTally(1, 'a'),
          const LabelledTally(2, 'b'),
        ]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('which is not a LabelledTally'),
          ),
        ),
      );
    });
  });

  group('resolve', () {
    test('finds the function for a declared type once', () {
      final concatMessages = StreamConcat.resolve<Message>();
      final concatStrings = StreamConcat.resolve<String>();
      final concatDynamicMaps = StreamConcat.resolve<Map<String, dynamic>>();

      expect(
        concatMessages!([Message.user('a'), Message.user('b')]),
        Message.user('ab'),
      );
      expect(concatStrings!(['a', 'b']), 'ab');
      expect(
        concatDynamicMaps!([
          {'k': 'a'},
          {'k': 'b'},
        ]),
        {'k': 'ab'},
      );
    });

    test('returns null for a type without a function', () {
      expect(StreamConcat.resolve<Tally>(), isNull);
      expect(StreamConcat.resolve<Object>(), isNull);
      expect(StreamConcat.resolve<List<String>>(), isNull);
    });
  });

  group('concat', () {
    test('reads the stream to its end, joins and closes', () async {
      final (reader, writer) = pipe<String>();
      writer
        ..send('a')
        ..send('b');
      await writer.close();

      expect(await StreamConcat.concat(reader), 'ab');
      await expectLater(reader.done, completes);
    });

    test('returns the only chunk of a stream as it is', () async {
      const tally = Tally(1);

      expect(
        await StreamConcat.concat(StreamReader.fromIterable([tally])),
        same(tally),
      );
    });

    test('fails for an empty stream', () async {
      await expectLater(
        StreamConcat.concat(StreamReader.fromIterable(<String>[])),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'stream reader is empty, concat failed',
          ),
        ),
      );
    });

    test('rethrows an error of the stream and closes it', () async {
      final (reader, writer) = pipe<String>();
      writer
        ..send('a')
        ..sendError(const FormatException('broken'));

      await expectLater(StreamConcat.concat(reader), throwsFormatException);
      expect(writer.isClosed, isTrue);
    });

    test('joins a stream of messages', () async {
      final stream = StreamReader.fromIterable([
        Message.assistant('Hel'),
        Message.assistant('lo'),
      ]);

      expect(await StreamConcat.concat(stream), Message.assistant('Hello'));
    });
  });
}
