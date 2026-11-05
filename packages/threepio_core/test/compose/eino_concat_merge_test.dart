// Port of eino `compose/stream_concat_test.go` and
// `compose/values_merge_test.go`.

import 'dart:async';

import 'package:test/test.dart';
import 'package:threepio_core/src/compose/stream_conversion.dart'
    show concatItems, concatStreamReader;
import 'package:threepio_core/src/compose/values_merge.dart' show mergeValues;
import 'package:threepio_core/threepio_core.dart';

/// Go: `tStreamConcatItemForTest`.
final class _ConcatItem {
  const _ConcatItem(this.s);
  final String s;
}

/// Go: `concatTStreamForTest`.
_ConcatItem _concatItems(List<_ConcatItem> items) =>
    _ConcatItem(items.map((item) => item.s).join());

/// Go: `concatIntForTest`.
int _concatInts(List<int> items) => items.fold(0, (sum, item) => sum + item);

/// Go: `tConcatErrForTest`.
final class _ConcatErr {
  const _ConcatErr();
}

/// Go: `testStruct{A string}` of TestConcatSliceValue.
final class _SliceStruct {
  const _SliceStruct(this.a);
  final String a;
}

/// Go: `TestType{A int; B []string}` of Test_mergeValues.
final class _TestType {
  _TestType(this.a, this.b);
  int a;
  List<String> b;
}

/// Go: `type Unregistered TestType`.
final class _Unregistered {
  const _Unregistered();
}

/// A pipe that a task of its own fills with [items], like the goroutine of
/// the Go tests.
StreamReader<T> _piped<T>(Iterable<T> items) {
  final (reader, writer) = pipe<T>(capacity: 10);
  unawaited(() async {
    for (final item in items) {
      await writer.sendAsync(item);
    }
    await writer.close();
  }());
  return reader;
}

Matcher _composeTypeError(String text) => throwsA(
      isA<ComposeTypeException>().having(
        (e) => e.toString(),
        'text',
        contains(text),
      ),
    );

Matcher _isTestType(int a, List<String> b) => isA<_TestType>()
    .having((value) => value.a, 'a', a)
    .having((value) => value.b, 'b', b);

void main() {
  tearDown(() {
    StreamConcat.reset();
    ValuesMerge.reset();
  });

  // --------------------------------------------------------------------------
  // stream_concat_test.go
  // --------------------------------------------------------------------------

  test('TestConcatRegistry', () async {
    StreamConcat.register<_ConcatItem>(_concatItems);

    final sr = _piped([for (var i = 0; i < 10; i++) _ConcatItem('$i')]);

    final lastVal = await concatStreamReader(sr);
    expect(lastVal.s, '0123456789');
  });

  test('TestStringConcat', () async {
    final sr = _piped([for (var i = 0; i < 10; i++) '$i']);

    final lastVal = await concatStreamReader(sr);
    expect(lastVal, '0123456789');
  });

  test('TestMessageConcat', () async {
    final sr = _piped([
      for (var i = 0; i < 10; i++)
        if (i % 4 == 0)
          Message(
            role: RoleType.user,
            content: '$i',
            extra: {'key_1': '$i', '$i': '$i'},
          )
        else
          Message.user('$i'),
    ]);

    final lastVal = await concatStreamReader(sr);
    expect(lastVal.content, '0123456789');
    expect(lastVal.extra, hasLength(4));
    expect(lastVal.extra, {
      'key_1': '048',
      '0': '0',
      '4': '4',
      '8': '8',
    });
  });

  group('TestMapConcat', () {
    setUp(() {
      StreamConcat.register<_ConcatItem>(_concatItems);
      StreamConcat.register<int>(_concatInts);
    });

    test('simple map', () async {
      final sr = _piped<Map<String, Object?>>([
        for (var i = 0; i < 10; i++)
          {
            'string': '$i',
            'custom_concat': _ConcatItem('${9 - i}'),
            'count': i,
          },
      ]);

      final lastVal = await concatStreamReader(sr);

      expect(lastVal['string'], '0123456789');
      expect((lastVal['custom_concat']! as _ConcatItem).s, '9876543210');
      expect(lastVal['count'], 45);
    });

    test('complex map', () async {
      final sr = _piped<Map<String, Object?>>([
        for (var i = 0; i < 10; i++)
          {
            'string': '$i',
            // A nested map.
            'deep_map': <String, Object?>{
              'message': Message(role: RoleType.assistant, content: '$i'),
              'custom_concat_deep': _ConcatItem('${9 - i}'),
              'count': i,
            },
            'custom_concat': _ConcatItem('${9 - i}'),
            'count': i,
          },
      ]);

      final lastVal = await concatStreamReader(sr);

      expect(lastVal['string'], '0123456789');
      expect(lastVal['count'], 45);
      final deepMap = lastVal['deep_map']! as Map<String, Object?>;
      expect((deepMap['message']! as Message).content, '0123456789');
      expect(
        (deepMap['custom_concat_deep']! as _ConcatItem).s,
        '9876543210',
      );
      expect(deepMap['count'], 45);
    });
  });

  group('TestConcatError', () {
    test('map type not equal', () {
      final a = <String, Object?>{
        'str': 'string_01',
        'x': 'string_in_a',
      };
      final b = <String, Object?>{
        'str': 'string_02',
        'x': 123,
      };

      expect(
        () => StreamConcat.concatItems<Map<String, Object?>>([a, b]),
        throwsStateError,
      );
    });

    test('merge error', () {
      StreamConcat.register<_ConcatErr>(
        (items) => throw Exception('test error'),
      );

      expect(
        () => StreamConcat.concatItems<_ConcatErr>(
          const [_ConcatErr(), _ConcatErr()],
        ),
        throwsA(
          predicate<Object>((e) => e.toString().contains('test error')),
        ),
      );
    });
  });

  group('TestConcatSliceValue', () {
    // Go joins `{}, {A: "123"}, {}` into `{A: "123"}` and three `{}` into
    // `{}`: of a type without a concat function, the one chunk that is not
    // the zero value wins. A Dart object has no zero value, so the empty
    // chunk of such a type is `null`.
    test('a type without a concat function: null is the zero value', () {
      const value = _SliceStruct('123');
      expect(
        concatItems<_SliceStruct?>([null, value, null]),
        same(value),
      );
      expect(concatItems<_SliceStruct?>([null, null, null]), isNull);
    });

    // The same rule where Dart has an empty value: collections.
    test('a type without a concat function: empty is the zero value', () {
      expect(
        StreamConcat.concatItems<List<int>>([
          [],
          [1, 2, 3],
          [],
        ]),
        [1, 2, 3],
      );
      expect(
        StreamConcat.concatItems<List<int>>([[], [], []]),
        isEmpty,
      );
    });
  });

  // Not a Go test of its own: `emptyStreamConcatErr` of stream_concat.go.
  test('concatStreamReader: an empty stream cannot be joined', () async {
    await expectLater(
      concatStreamReader(_piped<String>(const [])),
      throwsA(
        isA<StreamReadException>().having(
          (e) => e.toString(),
          'text',
          contains('stream reader is empty, concat fail'),
        ),
      ),
    );
  });

  // --------------------------------------------------------------------------
  // values_merge_test.go
  // --------------------------------------------------------------------------

  group('Test_mergeValues', () {
    void registerTestType() {
      ValuesMerge.register<_TestType>((vs) {
        final ret = _TestType(0, []);
        for (final v in vs) {
          if (ret.a < 0) {
            throw Exception('test error: ${ret.a}');
          }
          ret.a += v.a;
          ret.b.addAll(v.b);
        }
        ret.b.sort();
        return ret;
      });
    }

    group('merge maps', () {
      final m1 = <int, int>{1: 1, 2: 2, 3: 3, 4: 4};
      final m2 = <int, int>{5: 5, 6: 6, 7: 7, 8: 8};
      final m3 = <int, int>{9: 9, 10: 10, 11: 11};

      test('regular', () {
        final mergedM = mergeValues([m1, m2, m3]);

        // Go gets a map[int]int back. The default merge of Dart gives the
        // wide map type (`Map<String, Object?>` for string keys), as
        // `ValuesMerge` documents.
        final m = mergedM! as Map<Object?, Object?>;

        // len(m) == len(m1) + len(m2) + len(m3)
        expect(m.length, m1.length + m2.length + m3.length);
        expect(m, {...m1, ...m2, ...m3});
      });

      test('duplicated key', () {
        expect(
          () => mergeValues([
            m1,
            m2,
            m3,
            <int, int>{1: 1},
          ]),
          _composeTypeError('duplicated key'),
        );
      });

      test(
        'type mismatch',
        () {
          expect(
            () => mergeValues([
              m1,
              m2,
              m3,
              <int, String>{1: '1'},
            ]),
            _composeTypeError('type mismatch'),
          );
        },
      );

      // Not in Go: without a common key the mismatch is still an error.
      test('type mismatch without a common key', () {
        expect(
          () => mergeValues([
            m1,
            <int, String>{99: '99'},
          ]),
          _composeTypeError('type mismatch'),
        );
      });

      // Not in Go: maps whose entries fit the first map's types do merge.
      test('a map of a subtype merges into the others', () {
        expect(
          mergeValues([
            <int, num>{1: 1},
            <int, int>{2: 2},
          ]),
          {1: 1, 2: 2},
        );
      });

      // Not in Go: the mismatch the Dart merge of maps does report.
      test('type mismatch (a value that is not a map)', () {
        expect(
          () => mergeValues([m1, m2, m3, 'test3']),
          _composeTypeError('type mismatch'),
        );
      });
    });

    test('merge stream', () async {
      final ass = <Object?>[
        StreamReader<Map<int, String>>.fromIterable([
          {1: '1'},
        ]),
        StreamReader<Map<int, String>>.fromIterable([
          {2: '2'},
        ]),
        StreamReader<Map<int, String>>.fromIterable([
          {3: '3', 4: '4'},
        ]),
      ];
      final isr = mergeValues(ass);
      // Go unpacks a stream of map[int]string; see 'merge maps' / 'regular'.
      expect(isr, isA<StreamReader<Map<Object?, Object?>>>());
      final ret = isr! as StreamReader<Map<Object?, Object?>>;
      addTearDown(ret.close);

      final got = <Object?, Object?>{};
      for (var i = 0; i < 3; i++) {
        got.addAll(await ret.recv());
      }
      await expectLater(ret.recv(), throwsA(isA<StreamEOFException>()));

      expect(got, {1: '1', 2: '2', 3: '3', 4: '4'});
    });

    test('merge stream with source EOF', () async {
      final ass = <Object?>[
        StreamReader<Map<int, String>>.fromIterable([
          {1: '1'},
        ]),
        StreamReader<Map<int, String>>.fromIterable([
          {2: '2'},
        ]),
        StreamReader<Map<int, String>>.fromIterable([
          {3: '3', 4: '4'},
        ]),
      ];
      const names = ['source0', 'source1', 'source2'];
      final isr = mergeValues(
        ass,
        streamMergeWithSourceEof: true,
        names: names,
      );
      expect(isr, isA<StreamReader<Map<Object?, Object?>>>());
      final ret = isr! as StreamReader<Map<Object?, Object?>>;
      addTearDown(ret.close);

      final got = <Object?, Object?>{};
      final endedSources = <String>{};

      // Bounded: three chunks, three source ends and the end of the stream.
      var ended = false;
      for (var i = 0; i < 10 && !ended; i++) {
        try {
          got.addAll(await ret.recv());
        } on SourceEOFException catch (e) {
          endedSources.add(e.sourceName);
        } on StreamEOFException {
          ended = true;
        }
      }
      expect(ended, isTrue, reason: 'the merged stream did not end');

      // Every source has reported its end.
      expect(endedSources, names.toSet());
      expect(got, {1: '1', 2: '2', 3: '3', 4: '4'});
    });

    group('custom merge', () {
      setUp(registerTestType);

      test('regular', () {
        final vs = <Object?>[
          _TestType(0, []),
          _TestType(1, ['1']),
          _TestType(2, ['2', '22']),
          _TestType(3, ['3', '33', '333']),
        ];
        final ret = mergeValues(vs);
        expect(ret, _isTestType(6, ['1', '2', '22', '3', '33', '333']));
      });

      test('custom error', () {
        final vs = <Object?>[
          _TestType(0, []),
          _TestType(1, ['1']),
          _TestType(-2, ['2', '22']),
          _TestType(3, ['3', '33', '333']),
        ];
        expect(
          () => mergeValues(vs),
          throwsA(
            predicate<Object>((e) => e.toString().contains('test error')),
          ),
        );
      });

      test('type mismatch', () {
        final vs = <Object?>[
          _TestType(0, []),
          _TestType(1, ['1']),
          _TestType(2, ['2', '22']),
          'test3',
        ];
        expect(() => mergeValues(vs), _composeTypeError('type mismatch'));
      });

      test('stream', () async {
        final ass = <Object?>[
          StreamReader<_TestType>.fromIterable([_TestType(0, [])]),
          StreamReader<_TestType>.fromIterable([
            _TestType(1, ['1']),
          ]),
          StreamReader<_TestType>.fromIterable([
            _TestType(2, ['2', '22']),
          ]),
          StreamReader<_TestType>.fromIterable([
            _TestType(3, ['3', '33', '333']),
          ]),
        ];
        final isr = mergeValues(ass);
        expect(isr, isA<StreamReader<_TestType>>());
        final ret = isr! as StreamReader<_TestType>;
        addTearDown(ret.close);

        final vs = <Object?>[];
        for (var i = 0; i < 4; i++) {
          vs.add(await ret.recv());
        }
        await expectLater(ret.recv(), throwsA(isA<StreamEOFException>()));

        final merged = mergeValues(vs);
        expect(merged, _isTestType(6, ['1', '2', '22', '3', '33', '333']));
      });
    });

    test('unregistered type', () {
      // In Go the function for TestType is registered by now.
      registerTestType();
      expect(
        () => mergeValues(const [_Unregistered()]),
        _composeTypeError('unsupported type'),
      );
    });
  });
}
