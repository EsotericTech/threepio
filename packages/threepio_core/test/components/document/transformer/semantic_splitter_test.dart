// Port of eino-ext components/document/transformer/splitter/semantic/
// semantic_test.go: TestSemanticSplitter (cases "success", "corner case:
// text has not exceeded MinChunkSize", "corner case: percentile is too big",
// "corner case: percentile is too small"), with Go's expected output
// lengths, each run 10 times as in Go. Go's randomEmbedding draws from
// math/rand; here it draws from a seeded Random, so the runs are
// reproducible (the expected lengths hold for any vectors whose distances
// differ). Every Go test of the package is ported.
//
// The other tests are written for the port, with a fake embedder returning
// fixed vectors: exact chunks, minChunkSize, bufferSize, separators, the
// UTF-8 length default, NaN distances (zero vectors) and Go's NaN-first sort,
// percentile edge cases, errors (Go's "split document[%s] fail: %w"),
// cancellation and interrupts, the run context reaching the embedder and the
// id generator, several documents, metadata, and a bounded property test that
// the splitter terminates and loses no text. Their expected values are
// derived by following semantic.go step by step (see the comments).
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/transformer/semantic_splitter.dart';
import 'package:threepio_core/threepio_core.dart';

/// Port of Go's `randomEmbedding`: random vectors of [vecLen] entries.
final class _RandomEmbedding implements Embedder {
  _RandomEmbedding(this.vecLen, this.random);

  final int vecLen;
  final Random random;

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async =>
      [
        for (final _ in texts)
          [for (var j = 0; j < vecLen; j++) random.nextDouble()],
      ];
}

/// Returns the vector [vectors] has for each text, and records every call.
final class _FixedEmbedding implements Embedder {
  _FixedEmbedding(this.vectors);

  final Map<String, List<double>> vectors;
  final List<(List<String>, EmbedderOptions?)> calls = [];

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    calls.add((texts, options));
    return [
      for (final text in texts)
        vectors[text] ?? (throw StateError('no vector for "$text"')),
    ];
  }
}

/// Returns [result] (or throws [error]) whatever it is asked.
final class _ScriptedEmbedding implements Embedder {
  _ScriptedEmbedding({this.result = const [], this.error});

  final List<List<double>> result;
  final Object? error;

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    final error = this.error;
    // The fake throws whatever the test gives it, exceptions or not.
    // ignore: only_throw_errors
    if (error != null) throw error;
    return result;
  }
}

/// Answers every call with what [answer] returns for its texts.
final class _CallbackEmbedding implements Embedder {
  _CallbackEmbedding(this.answer);

  final List<List<double>> Function(List<String> texts) answer;
  final List<List<String>> calls = [];

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    calls.add(texts);
    return answer(texts);
  }
}

final class _Interrupt implements InterruptSignal {
  const _Interrupt();
}

/// Go's `fmt.Sprintf("%s_part%d", originalID, splitIndex)`.
String? _partIds(RunContext ctx, String? originalId, int splitIndex) =>
    '${originalId ?? ''}_part$splitIndex';

/// Vectors for the sentences "a.", "b.", "c.", "d": a and b point one way,
/// c and d the other, so the distances are 0, 1, 0.
final _abcd = <String, List<double>>{
  'a.': [1, 0],
  'b.': [1, 0],
  'c.': [0, 1],
  'd': [0, 1],
};

Future<List<String>> _chunks(
  SemanticSplitterConfig config,
  String content,
) async {
  final docs = await SemanticSplitter(config)
      .transform([Document(content: content)]);
  return [for (final doc in docs) doc.content];
}

void main() {
  group('TestSemanticSplitter', () {
    const sixSentences = '1234567890.1234567890.1234567890.1234567890.'
        '1234567890.1234567890';
    final cases = <(String, SemanticSplitterConfig, String, int)>[
      (
        'success',
        SemanticSplitterConfig(
          embedding: _RandomEmbedding(5, Random(1)),
          bufferSize: 1,
          minChunkSize: 9,
          separators: const ['.'],
          percentile: 0.5,
          idGenerator: _partIds,
        ),
        sixSentences,
        4,
      ),
      (
        'corner case: text has not exceeded MinChunkSize',
        SemanticSplitterConfig(
          embedding: _RandomEmbedding(5, Random(2)),
          bufferSize: 1,
          minChunkSize: 9,
          separators: const ['.'],
          percentile: 0.5,
        ),
        '1.1.1.1',
        1,
      ),
      (
        'corner case: percentile is too big',
        SemanticSplitterConfig(
          embedding: _RandomEmbedding(5, Random(3)),
          bufferSize: 1,
          minChunkSize: 9,
          separators: const ['.'],
          percentile: 0.9999,
        ),
        sixSentences,
        2,
      ),
      (
        'corner case: percentile is too small',
        SemanticSplitterConfig(
          embedding: _RandomEmbedding(5, Random(4)),
          bufferSize: 1,
          minChunkSize: 9,
          separators: const ['.'],
          percentile: 0.00001,
        ),
        sixSentences,
        6,
      ),
    ];
    for (final (name, config, content, outputLen) in cases) {
      test(name, () async {
        final splitter = SemanticSplitter(config);
        for (var i = 0; i < 10; i++) {
          final got = await splitter.transform([Document(content: content)]);
          expect(got, hasLength(outputLen), reason: 'run $i: $got');
          expect(got.map((doc) => doc.content).join(), content);
        }
      });
    }
  });

  group('SemanticSplitter (port)', () {
    test('is a typed DocumentTransformer', () {
      final splitter = SemanticSplitter(
        SemanticSplitterConfig(embedding: _FixedEmbedding(const {})),
      );
      expect(splitter, isA<DocumentTransformer>());
      expect(componentTypeNameOf(splitter), 'SemanticSplitter');
      expect(isCallbacksEnabled(splitter), isFalse);
    });

    test('cuts where the distance reaches the percentile', () async {
      // Distances 0, 1, 0, sorted [0, 0, 1].
      // 0.9: index int(2.7) = 2, threshold 1: one cut, before "c.".
      final embedding = _FixedEmbedding(_abcd);
      expect(
        await _chunks(
          SemanticSplitterConfig(
            embedding: embedding,
            separators: const ['.'],
            percentile: 0.9,
          ),
          'a.b.c.d',
        ),
        ['a.b.', 'c.d'],
      );
      // Without buffer, every sentence is embedded on its own, in one call.
      expect(embedding.calls, hasLength(1));
      expect(embedding.calls.single.$1, ['a.', 'b.', 'c.', 'd']);

      // 0.5: index int(1.5) = 1, threshold 0: every distance reaches it.
      expect(
        await _chunks(
          SemanticSplitterConfig(
            embedding: _FixedEmbedding(_abcd),
            separators: const ['.'],
            percentile: 0.5,
          ),
          'a.b.c.d',
        ),
        ['a.', 'b.', 'c.', 'd'],
      );
    });

    test('percentile 0 means 0.9', () async {
      expect(
        await _chunks(
          SemanticSplitterConfig(
            embedding: _FixedEmbedding(_abcd),
            separators: const ['.'],
          ),
          'a.b.c.d',
        ),
        ['a.b.', 'c.d'],
      );
    });

    test('a chunk below minChunkSize grows into the next one', () async {
      // Cuts at 1, 2, 3 (percentile 0.5). "a." (2) < 3: no cut; "a.b." (4)
      // is cut off; "c." (2) < 3: no cut; the rest "c.d" is the last chunk.
      expect(
        await _chunks(
          SemanticSplitterConfig(
            embedding: _FixedEmbedding(_abcd),
            separators: const ['.'],
            percentile: 0.5,
            minChunkSize: 3,
          ),
          'a.b.c.d',
        ),
        ['a.b.', 'c.d'],
      );
      // The last chunk may stay below the minimum.
      expect(
        await _chunks(
          SemanticSplitterConfig(
            embedding: _FixedEmbedding(_abcd),
            separators: const ['.'],
            percentile: 0.5,
            minChunkSize: 5,
          ),
          'a.b.c.d',
        ),
        ['a.b.c.', 'd'],
      );
    });

    test('measures length in UTF-8 bytes by default, as Go', () async {
      // "é." is 3 bytes but 2 characters; the cut before "x" is kept only
      // when "é." reaches minChunkSize 3.
      final vectors = <String, List<double>>{
        'é.': [1, 0],
        'x': [0, 1],
      };
      expect(
        await _chunks(
          SemanticSplitterConfig(
            embedding: _FixedEmbedding(vectors),
            separators: const ['.'],
            minChunkSize: 3,
          ),
          'é.x',
        ),
        ['é.', 'x'],
      );
      expect(
        await _chunks(
          SemanticSplitterConfig(
            embedding: _FixedEmbedding(vectors),
            separators: const ['.'],
            minChunkSize: 3,
            lenFunc: (text) => text.length,
          ),
          'é.x',
        ),
        ['é.x'],
      );
    });

    test('embeds every sentence with bufferSize neighbours on each side',
        () async {
      final embedding = _FixedEmbedding({
        'a.b.': [1, 0],
        'a.b.c.': [1, 0],
        'b.c.d': [0, 1],
        'c.d': [0, 1],
      });
      await _chunks(
        SemanticSplitterConfig(
          embedding: embedding,
          separators: const ['.'],
          bufferSize: 1,
        ),
        'a.b.c.d',
      );
      expect(embedding.calls.single.$1, ['a.b.', 'a.b.c.', 'b.c.d', 'c.d']);

      final wide = _FixedEmbedding({
        'a.b.c.d': [1, 0],
      });
      await _chunks(
        SemanticSplitterConfig(
          embedding: wide,
          separators: const ['.'],
          bufferSize: 1 << 62,
        ),
        'a.b.c.d',
      );
      expect(wide.calls.single.$1, List.filled(4, 'a.b.c.d'));
    });

    test('cuts after every separator, each in turn, keeping them', () async {
      // Default separators "\n", ".", "?", "!"; a trailing separator leaves
      // an empty last sentence, which is embedded too.
      final embedding = _FixedEmbedding({
        'x\n': [1, 0],
        'y.': [1, 0],
        'z?': [1, 0],
        'w!': [1, 0],
        '': [1, 0],
      });
      final chunks = await _chunks(
        SemanticSplitterConfig(embedding: embedding),
        'x\ny.z?w!',
      );
      expect(embedding.calls.single.$1, ['x\n', 'y.', 'z?', 'w!', '']);
      // All distances are 0, the threshold is 0, every boundary is a cut.
      expect(chunks, ['x\n', 'y.', 'z?', 'w!', '']);
    });

    test('one sentence is one chunk, and the embedder is not called',
        () async {
      final embedding = _FixedEmbedding(const {});
      expect(
        await _chunks(SemanticSplitterConfig(embedding: embedding), 'abc'),
        ['abc'],
      );
      expect(
        await _chunks(SemanticSplitterConfig(embedding: embedding), ''),
        [''],
      );
      // An empty text cut with an empty separator gives no sentence (Go
      // panics); it is one empty chunk here.
      expect(
        await _chunks(
          SemanticSplitterConfig(embedding: embedding, separators: const ['']),
          '',
        ),
        [''],
      );
      expect(embedding.calls, isEmpty);
    });

    group('NaN distances (zero vectors)', () {
      test('all NaN: the threshold is NaN and nothing is cut', () async {
        expect(
          await _chunks(
            SemanticSplitterConfig(
              embedding: _FixedEmbedding({
                'a.': [0, 0],
                'b.': [0, 0],
                'c.': [0, 0],
                'd': [0, 0],
              }),
              separators: const ['.'],
              percentile: 0.5,
            ),
            'a.b.c.d',
          ),
          ['a.b.c.d'],
        );
      });

      test('NaN sorts first, as in Go', () async {
        // Distances NaN, NaN, 1. Go sorts them [NaN, NaN, 1] (Dart's own
        // sort would put NaN last); 0.9 picks index 2, threshold 1, one cut
        // before "d". 0.5 picks index 1, threshold NaN, no cut.
        final vectors = <String, List<double>>{
          'a.': [1, 0],
          'b.': [0, 0],
          'c.': [1, 0],
          'd': [0, 1],
        };
        expect(
          await _chunks(
            SemanticSplitterConfig(
              embedding: _FixedEmbedding(vectors),
              separators: const ['.'],
              percentile: 0.9,
            ),
            'a.b.c.d',
          ),
          ['a.b.c.', 'd'],
        );
        expect(
          await _chunks(
            SemanticSplitterConfig(
              embedding: _FixedEmbedding(vectors),
              separators: const ['.'],
              percentile: 0.5,
            ),
            'a.b.c.d',
          ),
          ['a.b.c.d'],
        );
      });
    });

    group('percentile edge cases', () {
      test('above 1: only the largest distance cuts', () async {
        expect(
          await _chunks(
            SemanticSplitterConfig(
              embedding: _FixedEmbedding(_abcd),
              separators: const ['.'],
              percentile: 7,
            ),
            'a.b.c.d',
          ),
          ['a.b.', 'c.d'],
        );
        expect(
          await _chunks(
            SemanticSplitterConfig(
              embedding: _FixedEmbedding(_abcd),
              separators: const ['.'],
              percentile: double.infinity,
            ),
            'a.b.c.d',
          ),
          ['a.b.', 'c.d'],
        );
      });

      test('slightly negative truncates to index 0, as in Go', () async {
        // -0.1 * 3 = -0.3, int() gives 0: the smallest distance, 0.
        expect(
          await _chunks(
            SemanticSplitterConfig(
              embedding: _FixedEmbedding(_abcd),
              separators: const ['.'],
              percentile: -0.1,
            ),
            'a.b.c.d',
          ),
          ['a.', 'b.', 'c.', 'd'],
        );
      });

      test('a negative index or NaN throws ArgumentError (Go panics)',
          () async {
        for (final percentile in [-1.0, -0.5, double.nan]) {
          await expectLater(
            SemanticSplitter(
              SemanticSplitterConfig(
                embedding: _FixedEmbedding(_abcd),
                separators: const ['.'],
                percentile: percentile,
              ),
            ).transform([const Document(content: 'a.b.c.d')]),
            throwsA(isA<ArgumentError>()),
            reason: '$percentile',
          );
        }
      });
    });

    group('errors', () {
      Future<void> expectFailure(
        Embedder embedding,
        Matcher matcher, {
        String? id = 'doc1',
      }) =>
          expectLater(
            SemanticSplitter(
              SemanticSplitterConfig(
                embedding: embedding,
                separators: const ['.'],
              ),
            ).transform([Document(id: id, content: 'a.b.c.d')]),
            throwsA(matcher),
          );

      test("an embedder failure is wrapped with Go's message", () async {
        const cause = ThreepioException('quota exceeded');
        await expectFailure(
          _ScriptedEmbedding(error: cause),
          isA<ThreepioException>()
              .having(
                (e) => e.message,
                'message',
                'split document[doc1] fail: quota exceeded',
              )
              .having((e) => e.cause, 'cause', same(cause)),
        );
        const format = FormatException('bad');
        await expectFailure(
          _ScriptedEmbedding(error: format),
          isA<ThreepioException>()
              .having(
                (e) => e.message,
                'message',
                'split document[] fail: FormatException: bad',
              )
              .having((e) => e.cause, 'cause', same(format)),
          id: null,
        );
      });

      test('too few vectors, or a shorter vector, fail (Go panics)',
          () async {
        await expectFailure(
          _ScriptedEmbedding(
            result: const [
              [1, 0],
            ],
          ),
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'split document[doc1] fail: embedding returned 1 vectors for 4 '
                'texts',
          ),
        );
        await expectFailure(
          _ScriptedEmbedding(
            result: const [
              [1, 0],
              [1],
              [1, 0],
              [1, 0],
            ],
          ),
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'split document[doc1] fail: embedding returned vectors of '
                'different lengths (2 and 1)',
          ),
        );
        // Extra vectors and longer vectors are ignored, as in Go.
        final chunks = await SemanticSplitter(
          SemanticSplitterConfig(
            embedding: _ScriptedEmbedding(
              result: const [
                [1, 0],
                [1, 0, 5],
                [1, 0, 5],
                [1, 0, 5],
                [9, 9],
              ],
            ),
            separators: const ['.'],
          ),
        ).transform([const Document(content: 'a.b.c.d')]);
        expect(chunks.map((doc) => doc.content).join(), 'a.b.c.d');
      });

      test('cancellation, interrupts and errors are not wrapped', () async {
        const cancelled = CancelledException('stop');
        await expectFailure(
          _ScriptedEmbedding(error: cancelled),
          same(cancelled),
        );
        const interrupt = _Interrupt();
        await expectFailure(
          _ScriptedEmbedding(error: interrupt),
          same(interrupt),
        );
        final error = StateError('bug');
        await expectFailure(_ScriptedEmbedding(error: error), same(error));
      });
    });

    test('the run context reaches the embedder and the id generator',
        () async {
      final ctx = RunContext.background();
      final embedding = _FixedEmbedding(_abcd);
      final seen = <(RunContext, String?, int)>[];
      final got = await SemanticSplitter(
        SemanticSplitterConfig(
          embedding: embedding,
          separators: const ['.'],
          idGenerator: (ctx, originalId, splitIndex) {
            seen.add((ctx, originalId, splitIndex));
            return '$originalId-$splitIndex';
          },
        ),
      ).transform(
        const [Document(id: 'd', content: 'a.b.c.d')],
        options: TransformerOptions(runContext: ctx),
      );
      expect([for (final doc in got) doc.id], ['d-0', 'd-1']);
      expect(identical(embedding.calls.single.$2?.runContext, ctx), isTrue);
      expect(seen.every((call) => identical(call.$1, ctx)), isTrue);

      // Without options both get one background context.
      final background = _FixedEmbedding(_abcd);
      RunContext? idContext;
      await SemanticSplitter(
        SemanticSplitterConfig(
          embedding: background,
          separators: const ['.'],
          idGenerator: (ctx, originalId, splitIndex) {
            idContext = ctx;
            return originalId;
          },
        ),
      ).transform(const [Document(content: 'a.b.c.d')]);
      final embedContext = background.calls.single.$2?.runContext;
      expect(embedContext, isNotNull);
      expect(identical(embedContext, idContext), isTrue);
    });

    test('embeds once per document; ids are counted per document', () async {
      // "solo" is one sentence and is not embedded. "x.y": distances [1],
      // threshold index int(0.9 * 1) = 0, one cut.
      final embedding = _FixedEmbedding({
        ..._abcd,
        'x.': [1, 0],
        'y': [0, 1],
      });
      final got = await SemanticSplitter(
        SemanticSplitterConfig(
          embedding: embedding,
          separators: const ['.'],
          idGenerator: _partIds,
        ),
      ).transform(const [
        Document(id: 'one', content: 'a.b.c.d'),
        Document(id: 'two', content: 'solo'),
        Document(id: 'three', content: 'x.y'),
      ]);
      expect([for (final doc in got) (doc.id, doc.content)], [
        ('one_part0', 'a.b.'),
        ('one_part1', 'c.d'),
        ('two_part0', 'solo'),
        ('three_part0', 'x.'),
        ('three_part1', 'y'),
      ]);
      expect([for (final call in embedding.calls) call.$1], [
        ['a.', 'b.', 'c.', 'd'],
        ['x.', 'y'],
      ]);
    });

    test('a failing document fails the call and is named in the message',
        () async {
      // Go returns nil and the error: the chunks of the first document are
      // not returned either.
      final embedding = _CallbackEmbedding((texts) {
        if (texts.first == 'x.') throw const ThreepioException('down');
        return [for (final text in texts) _abcd[text]!];
      });
      await expectLater(
        SemanticSplitter(
          SemanticSplitterConfig(
            embedding: embedding,
            separators: const ['.'],
          ),
        ).transform(const [
          Document(id: 'one', content: 'a.b.c.d'),
          Document(id: 'two', content: 'x.y'),
        ]),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'split document[two] fail: down',
          ),
        ),
      );
      expect(embedding.calls, hasLength(2));
    });

    test('copies the metadata per chunk and leaves the input untouched',
        () async {
      final shared = <int>[1];
      final original = Document(
        id: 'doc',
        content: 'a.b.c.d',
        metadata: {'k': 'v', 'list': shared},
        source: const DocumentSource(uri: 'mem://doc'),
        score: 0.4,
      );
      final input = [original];
      final snapshot = original.copyWith();
      final got = await SemanticSplitter(
        SemanticSplitterConfig(
          embedding: _FixedEmbedding(_abcd),
          separators: const ['.'],
        ),
      ).transform(input);
      expect(got, hasLength(2));
      for (final chunk in got) {
        expect(chunk.id, 'doc');
        expect(chunk.metadata, {'k': 'v', 'list': shared});
        expect(identical(chunk.metadata['list'], shared), isTrue);
        expect(chunk.source, original.source);
        expect(chunk.score, isNull);
      }
      expect(input, [snapshot]);
    });

    test('terminates and loses no text on random input (bounded)', () async {
      final random = Random(20261106);
      const alphabet = ['a', 'b', '.', '\n', '?', '!', 'é'];
      const separatorPool = ['.', '\n', '?', '!', '', 'ab'];
      for (var round = 0; round < 300; round++) {
        final length = random.nextInt(40);
        final text = [
          for (var i = 0; i < length; i++)
            alphabet[random.nextInt(alphabet.length)],
        ].join();
        final separators = random.nextBool()
            ? null
            : [
                for (var i = 0; i < 1 + random.nextInt(3); i++)
                  separatorPool[random.nextInt(separatorPool.length)],
              ];
        // Random vectors, sometimes all zeros (NaN distances).
        final zeros = random.nextInt(5) == 0;
        final config = SemanticSplitterConfig(
          embedding: zeros ? _ZeroEmbedding() : _RandomEmbedding(3, Random(round)),
          bufferSize: random.nextInt(4),
          minChunkSize: random.nextInt(12),
          separators: separators,
          percentile: random.nextDouble() * 1.5,
        );
        final got = await SemanticSplitter(config)
            .transform([Document(content: text)]);
        final reason = 'round $round: ${text.codeUnits} $separators';
        expect(got, isNotEmpty, reason: reason);
        expect(got.map((doc) => doc.content).join(), text, reason: reason);
        // Each separator adds at most one sentence per character (an empty
        // one turns every piece into its code points), so there are at most
        // 1 + length * separators sentences, repeated separators included.
        expect(
          got.length,
          lessThanOrEqualTo(1 + text.length * (separators?.length ?? 4)),
          reason: reason,
        );
      }
    });
  });
}

/// Returns all-zero vectors: every cosine distance is NaN.
final class _ZeroEmbedding implements Embedder {
  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async =>
      [
        for (final _ in texts) [0.0, 0.0, 0.0],
      ];
}
