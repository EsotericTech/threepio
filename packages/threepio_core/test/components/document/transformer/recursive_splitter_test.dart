// Port of eino-ext components/document/transformer/splitter/recursive/
// recursive_test.go: TestRecursiveSplitter (cases "none", "start", "end"),
// with Go's expected values. Every Go test of the package is ported.
//
// The other tests are written for the port: the UTF-8 length default, a
// custom lenFunc, overlap, the empty separator, validation, id generators
// and the run context, metadata, the static entry point on
// RecursiveCharacterTextSplitter, and a bounded property test that the
// splitter terminates on random input. Their expected values are derived by
// following recursive.go step by step (see the comments).
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/transformer/splitter/recursive_splitter.dart';
import 'package:threepio_core/src/components/document/transformer/splitter/split_id_generator.dart';
import 'package:threepio_core/threepio_core.dart';

/// Go's `fmt.Sprintf("%s_part%d", originalID, splitIndex)`.
String? _partIds(RunContext ctx, String? originalId, int splitIndex) =>
    '${originalId ?? ''}_part$splitIndex';

Future<List<Document>> _split(
  RecursiveSplitterConfig config,
  List<Document> docs, {
  TransformerOptions? options,
}) =>
    RecursiveCharacterTextSplitter.fromConfig(config)
        .transform(docs, options: options);

List<String> _contents(List<Document> docs) =>
    [for (final doc in docs) doc.content];

void main() {
  group('TestRecursiveSplitter', () {
    final input = [const Document(content: '1a23a45a67890c1a234b5678a90')];

    test('none', () async {
      final got = await _split(
        const RecursiveSplitterConfig(
          chunkSize: 5,
          overlapSize: 2,
          separators: ['a', 'b', 'c'],
        ),
        input,
      );
      expect(got, const [
        Document(content: '1a23'),
        Document(content: '23a45'),
        Document(content: '67890'),
        Document(content: '1'),
        Document(content: '234'),
        Document(content: '5678'),
        Document(content: '90'),
      ]);
    });

    test('start', () async {
      final got = await _split(
        const RecursiveSplitterConfig(
          chunkSize: 5,
          overlapSize: 2,
          separators: ['a', 'b', 'c'],
          keepType: SplitterKeepType.start,
          idGenerator: _partIds,
        ),
        input,
      );
      expect(got, const [
        Document(id: '_part0', content: '1a23'),
        Document(id: '_part1', content: 'a45'),
        Document(id: '_part2', content: 'a67890'),
        Document(id: '_part3', content: 'c1'),
        Document(id: '_part4', content: 'a234'),
        Document(id: '_part5', content: 'b5678'),
        Document(id: '_part6', content: 'a90'),
      ]);
    });

    test('end', () async {
      final got = await _split(
        const RecursiveSplitterConfig(
          chunkSize: 5,
          overlapSize: 2,
          separators: ['a', 'b', 'c'],
          keepType: SplitterKeepType.end,
        ),
        input,
      );
      expect(got, const [
        Document(content: '1a23a'),
        Document(content: '45a'),
        Document(content: '67890c'),
        Document(content: '1a'),
        Document(content: '234b'),
        Document(content: '5678a'),
        Document(content: '90'),
      ]);
    });
  });

  group('RecursiveSplitter (port)', () {
    test('is reached through RecursiveCharacterTextSplitter.fromConfig', () {
      final splitter = RecursiveCharacterTextSplitter.fromConfig(
        const RecursiveSplitterConfig(chunkSize: 10),
      );
      expect(splitter, isA<DocumentTransformer>());
      expect(splitter, isA<RecursiveSplitterTransformer>());
      expect(componentTypeNameOf(splitter), 'RecursiveSplitter');
      expect(isCallbacksEnabled(splitter), isFalse);
    });

    test('without overlap, a chunk starts where the previous one ended',
        () async {
      // As "none", with OverlapSize 0: after "1a23" is emitted, both "1" and
      // "23" are popped (total 2 > overlap 0), so "45" starts a new chunk.
      final got = await _split(
        const RecursiveSplitterConfig(
          chunkSize: 5,
          separators: ['a', 'b', 'c'],
        ),
        [const Document(content: '1a23a45a67890c1a234b5678a90')],
      );
      expect(
        _contents(got),
        ['1a23', '45', '67890', '1', '234', '5678', '90'],
      );
    });

    test('measures length in UTF-8 bytes by default, as Go', () async {
      // "héllo" and "wörld" are 6 bytes but 5 characters each. In bytes,
      // 6 + 1 + 6 = 13 > 12, so they stay apart; in characters,
      // 5 + 1 + 5 = 11 <= 12, so they merge.
      const doc = Document(content: 'héllo\nwörld');
      final inBytes =
          await _split(const RecursiveSplitterConfig(chunkSize: 12), [doc]);
      expect(_contents(inBytes), ['héllo', 'wörld']);

      final inCharacters = await _split(
        RecursiveSplitterConfig(chunkSize: 12, lenFunc: (text) => text.length),
        [doc],
      );
      expect(_contents(inCharacters), ['héllo\nwörld']);
    });

    test('uses the default separators when none or an empty list is given',
        () async {
      // "\n" is tried first: "ab\ncd" is cut there and the pieces (2 bytes
      // each, 2 + 1 + 2 = 5 > 4) are not merged back.
      for (final separators in [null, const <String>[]]) {
        final got = await _split(
          RecursiveSplitterConfig(chunkSize: 4, separators: separators),
          [const Document(content: 'ab\ncd')],
        );
        expect(_contents(got), ['ab', 'cd'], reason: '$separators');
      }
    });

    test('a piece no separator can cut becomes a chunk of its own', () async {
      // No separator occurs: the last one is used, the text stays whole,
      // and it is emitted although it is longer than the chunk size.
      final got = await _split(
        const RecursiveSplitterConfig(chunkSize: 3, separators: ['x', 'y']),
        [const Document(content: 'abcdefgh')],
      );
      expect(_contents(got), ['abcdefgh']);
    });

    test('the empty separator cuts between code points', () async {
      // U+1F600 is one code point, two UTF-16 code units and four UTF-8
      // bytes; it is never cut in two.
      final emoji = String.fromCharCode(0x1F600);
      final text = 'a${emoji}b';
      final single = await _split(
        const RecursiveSplitterConfig(chunkSize: 1, separators: ['']),
        [Document(content: text)],
      );
      expect(_contents(single), ['a', emoji, 'b']);

      // With room for 5 bytes, "a" (1) and the emoji (4) fit together; "b"
      // starts the next chunk once both are popped (overlap 0).
      final merged = await _split(
        const RecursiveSplitterConfig(chunkSize: 5, separators: ['']),
        [Document(content: text)],
      );
      expect(_contents(merged), ['a$emoji', 'b']);
    });

    test('chunks are trimmed as Go trims them, and empty ones are dropped',
        () async {
      // The text is cut at "." into ["  ", " x ", "  "]; all are short, so
      // they merge back with the separator into "  . x .  "
      // (2 + 1 + 3 + 1 + 2 = 9 <= 10), which is trimmed to ". x .".
      final got = await _split(
        const RecursiveSplitterConfig(chunkSize: 10, separators: ['.']),
        [const Document(content: '  . x .  ')],
      );
      expect(_contents(got), ['. x .']);

      // A text of white space only gives no chunk at all.
      final none = await _split(
        const RecursiveSplitterConfig(chunkSize: 10),
        [const Document(content: '  \n  ')],
      );
      expect(none, isEmpty);

      // Go's TrimSpace keeps U+FEFF, which Dart's trim would remove.
      final bom = String.fromCharCode(0xFEFF);
      final kept = await _split(
        const RecursiveSplitterConfig(chunkSize: 10),
        [Document(content: ' ${bom}x ')],
      );
      expect(_contents(kept), ['${bom}x']);
    });

    test('an empty document gives no chunk', () async {
      final got = await _split(
        const RecursiveSplitterConfig(chunkSize: 10),
        [const Document(id: 'empty', content: '')],
      );
      expect(got, isEmpty);
    });

    group('validation (Go messages)', () {
      test('chunk size must be greater than zero', () {
        for (final size in [0, -1]) {
          expect(
            () => RecursiveCharacterTextSplitter.fromConfig(
              RecursiveSplitterConfig(chunkSize: size),
            ),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                'chunk size must be greater than zero',
              ),
            ),
          );
        }
      });

      test('overlap must be greater than or equal to zero', () {
        expect(
          () => RecursiveCharacterTextSplitter.fromConfig(
            const RecursiveSplitterConfig(chunkSize: 5, overlapSize: -1),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'overlap must be greater than or equal to zero',
            ),
          ),
        );
      });

      test('the chunk size is checked first', () {
        expect(
          () => RecursiveSplitterTransformer(
            const RecursiveSplitterConfig(chunkSize: 0, overlapSize: -1),
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'chunk size must be greater than zero',
            ),
          ),
        );
      });

      test('an overlap as large as the chunk size is accepted, as in Go',
          () async {
        final got = await _split(
          const RecursiveSplitterConfig(
            chunkSize: 3,
            overlapSize: 3,
            separators: [' '],
          ),
          [const Document(content: 'a b c d')],
        );
        // "a b" (3) is emitted when "c" would exceed 3; total 3 is not above
        // the overlap 3, but 3 + 1 + 1 > 3 with total > 0, so "a" is popped;
        // then total 1, 1 + 1 + 0 <= 3 and 1 <= 3: "b" stays. And so on.
        expect(_contents(got), ['a b', 'b c', 'c d']);
      });
    });

    group('ids and run context', () {
      test('the id generator gets the run context of the options', () async {
        final ctx = RunContext.background();
        final seen = <(RunContext, String?, int)>[];
        final got = await _split(
          RecursiveSplitterConfig(
            chunkSize: 2,
            separators: const [','],
            idGenerator: (ctx, originalId, splitIndex) {
              seen.add((ctx, originalId, splitIndex));
              return '$originalId#$splitIndex';
            },
          ),
          const [
            Document(id: 'a', content: 'x,y'),
            Document(id: 'b', content: 'z,w,v'),
          ],
          options: TransformerOptions(runContext: ctx),
        );
        expect(
          [for (final doc in got) doc.id],
          ['a#0', 'a#1', 'b#0', 'b#1', 'b#2'],
        );
        expect(_contents(got), ['x', 'y', 'z', 'w', 'v']);
        expect(seen.every((call) => identical(call.$1, ctx)), isTrue);
        expect(
          [for (final call in seen) (call.$2, call.$3)],
          [('a', 0), ('a', 1), ('b', 0), ('b', 1), ('b', 2)],
        );
      });

      test('without options the id generator gets a background context',
          () async {
        RunContext? seen;
        await _split(
          RecursiveSplitterConfig(
            chunkSize: 5,
            idGenerator: (ctx, originalId, splitIndex) {
              seen = ctx;
              return originalId;
            },
          ),
          const [Document(content: 'x')],
        );
        expect(seen, isNotNull);
        expect(seen!.cancelToken.isCancelled, isFalse);
      });

      test('by default every chunk keeps the id of its document', () async {
        final got = await _split(
          const RecursiveSplitterConfig(chunkSize: 2, separators: [',']),
          const [Document(id: 'doc', content: 'x,y,z')],
        );
        expect([for (final doc in got) doc.id], ['doc', 'doc', 'doc']);
        expect(
          defaultSplitIdGenerator(RunContext.background(), 'id', 7),
          'id',
        );
        expect(defaultSplitIdGenerator(RunContext.background(), null, 0),
            isNull);
      });
    });

    test('copies the metadata per chunk and leaves the input untouched',
        () async {
      final shared = <int>[1, 2];
      final original = Document(
        id: 'doc',
        content: 'x,y',
        metadata: {'k': 'v', 'list': shared},
        source: const DocumentSource(uri: 'file:///doc.txt'),
        embedding: const [0.5, 0.5],
        score: 0.7,
      );
      final input = [original];
      final snapshot = original.copyWith();
      final got = await _split(
        const RecursiveSplitterConfig(chunkSize: 2, separators: [',']),
        input,
      );
      expect(got, hasLength(2));
      for (final chunk in got) {
        expect(chunk.metadata, {'k': 'v', 'list': shared});
        expect(identical(chunk.metadata, original.metadata), isFalse);
        // A shallow copy, as Go's deepCopyMap: the values are shared.
        expect(identical(chunk.metadata['list'], shared), isTrue);
        // The source describes the chunk too; the embedding and the score
        // of the whole document do not, and are not carried over.
        expect(chunk.source, original.source);
        expect(chunk.embedding, isNull);
        expect(chunk.score, isNull);
      }
      expect(input, [snapshot]);
      expect(identical(input.single, original), isTrue);
    });

    test('terminates on random input (bounded property test)', () async {
      final random = Random(20261105);
      const alphabet = ['a', 'b', ' ', '.', '\n', 'é', ','];
      const separatorPool = ['.', ' ', '\n', ',', 'ab', '', 'é'];
      for (var round = 0; round < 300; round++) {
        final length = random.nextInt(60);
        final text = [
          for (var i = 0; i < length; i++)
            alphabet[random.nextInt(alphabet.length)],
        ].join();
        final separators = [
          for (var i = 0; i < 1 + random.nextInt(4); i++)
            separatorPool[random.nextInt(separatorPool.length)],
        ];
        final chunkSize = 1 + random.nextInt(12);
        final config = RecursiveSplitterConfig(
          chunkSize: chunkSize,
          overlapSize: random.nextInt(chunkSize + 3),
          separators: separators,
          keepType: SplitterKeepType
              .values[random.nextInt(SplitterKeepType.values.length)],
          lenFunc: random.nextBool() ? null : (s) => s.length,
        );
        final got = await _split(config, [Document(content: text)]);
        final reason = 'round $round: ${text.codeUnits} $separators '
            'size $chunkSize overlap ${config.overlapSize} '
            '${config.keepType}';
        // Every chunk is a non-empty, contiguous piece of the text.
        for (final chunk in got) {
          expect(chunk.content, isNotEmpty, reason: reason);
          expect(text.contains(chunk.content), isTrue, reason: reason);
        }
        // Every merge emits at most one chunk per piece it is given, and
        // each level of separators cuts the text into at most
        // (length + 1) more pieces.
        expect(
          got.length,
          lessThanOrEqualTo((text.length + 1) * (separators.length + 1)),
          reason: reason,
        );
      }
    });
  });

  group('Go string helpers', () {
    test('splitterUtf8Length counts UTF-8 bytes', () {
      expect(splitterUtf8Length(''), 0);
      expect(splitterUtf8Length('abc'), 3);
      expect(splitterUtf8Length('é'), 2);
      expect(splitterUtf8Length(String.fromCharCode(0x20AC)), 3);
      expect(splitterUtf8Length(String.fromCharCode(0x1F600)), 4);
      // A lone surrogate counts as the U+FFFD utf8.encode writes for it.
      expect(splitterUtf8Length(String.fromCharCode(0xD800)), 3);
      expect(splitterUtf8Length('${String.fromCharCode(0xDC00)}a'), 4);
    });

    test('splitterGoTrimSpace trims what Go trims', () {
      final nbsp = String.fromCharCode(0xA0);
      final ideographic = String.fromCharCode(0x3000);
      final bom = String.fromCharCode(0xFEFF);
      expect(splitterGoTrimSpace(' \t\r\n x \v\f'), 'x');
      expect(splitterGoTrimSpace('${nbsp}x$ideographic'), 'x');
      expect(splitterGoTrimSpace('${bom}x$bom'), '${bom}x$bom');
      expect(splitterGoTrimSpace('   '), '');
    });

    test('splitterGoSplit and splitterGoSplitAfter cut as Go', () {
      expect(splitterGoSplit('a,b,', ','), ['a', 'b', '']);
      expect(splitterGoSplit('', ','), ['']);
      expect(splitterGoSplit('', ''), isEmpty);
      expect(splitterGoSplit('aaa', 'aa'), ['', 'a']);
      expect(splitterGoSplitAfter('a,b,', ','), ['a,', 'b,', '']);
      expect(splitterGoSplitAfter('ab', ','), ['ab']);
      expect(splitterGoSplitAfter('', ','), ['']);
      final emoji = String.fromCharCode(0x1F600);
      expect(splitterGoSplitAfter('x$emoji', ''), ['x', emoji]);
    });
  });
}
