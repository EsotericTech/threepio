// Port of eino-ext components/document/transformer/reranker/score/
// score_test.go: TestScoreReranker (cases "5cases", "10cases"), with Go's
// expected orders. Go shuffles the input once with math/rand before each
// case; here each case runs on several shuffles from seeded Randoms. Every
// Go test of the package is ported.
//
// The other tests are written for the port: the default score (field,
// `_score` metadata, 0), metadata keys holding ints and non-numbers, the
// stable order of equal scores, NaN scores, the input left untouched, and
// the component type.
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/transformer/score_reorder.dart';
import 'package:threepio_core/threepio_core.dart';

const _scoreKey = 'score';

final _scoredDocs = [
  for (var i = 0; i < 10; i++)
    Document(id: '$i', content: '', metadata: {_scoreKey: i.toDouble()}),
];

List<String?> _ids(List<Document> docs) => [for (final doc in docs) doc.id];

void main() {
  group('TestScoreReranker', () {
    final cases = <(String, List<int>, List<int>)>[
      ('5cases', [0, 1, 2, 3, 4], [4, 2, 0, 1, 3]),
      (
        '10cases',
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [9, 7, 5, 3, 1, 0, 2, 4, 6, 8],
      ),
    ];
    for (final (name, input, wanted) in cases) {
      test(name, () async {
        const reranker = ScoreReorderTransformer(scoreFieldKey: _scoreKey);
        for (var seed = 0; seed < 8; seed++) {
          final shuffled = [for (final i in input) _scoredDocs[i]]
            ..shuffle(Random(seed));
          final result = await reranker.transform(shuffled);
          expect(result, [for (final i in wanted) _scoredDocs[i]],
              reason: 'seed $seed');
          for (final (i, doc) in result.indexed) {
            expect(identical(doc, _scoredDocs[wanted[i]]), isTrue);
          }
        }
      });
    }
  });

  group('ScoreReorderTransformer (port)', () {
    test('is a typed DocumentTransformer', () {
      const reranker = ScoreReorderTransformer();
      expect(reranker, isA<DocumentTransformer>());
      expect(componentTypeNameOf(reranker), 'ScoreReranker');
      expect(isCallbacksEnabled(reranker), isFalse);
    });

    test("without a key, uses the document's score (Go: Score())", () async {
      final docs = [
        const Document(id: 'none', content: ''),
        const Document(id: 'field', content: '', score: 3),
        const Document(id: 'meta', content: '', metadata: {'_score': 2.0}),
        const Document(
          id: 'both',
          content: '',
          score: 4,
          metadata: {'_score': -1.0},
        ),
        const Document(id: 'neg', content: '', score: -1),
      ];
      final result = await const ScoreReorderTransformer().transform(docs);
      // By score: both 4, field 3, meta 2, none 0, neg -1.
      // Interleaved: [both, meta, neg, none, field].
      expect(_ids(result), ['both', 'meta', 'neg', 'none', 'field']);
    });

    test('with a key, a number there is the score, anything else 0',
        () async {
      final docs = [
        const Document(id: 'int', content: '', metadata: {'s': 5}),
        const Document(id: 'string', content: '', metadata: {'s': '9'}),
        const Document(id: 'missing', content: '', score: 8),
        const Document(id: 'double', content: '', metadata: {'s': 2.5}),
        const Document(id: 'negative', content: '', metadata: {'s': -2}),
      ];
      final result =
          await const ScoreReorderTransformer(scoreFieldKey: 's').transform(
        docs,
      );
      // By score: int 5, double 2.5, string 0, missing 0 (stable), negative
      // -2. Interleaved: [int, string, negative, missing, double].
      expect(
        _ids(result),
        ['int', 'string', 'negative', 'missing', 'double'],
      );
    });

    test('equal scores keep their order (a stable sort)', () async {
      final docs = [
        for (final id in ['a', 'b', 'c', 'd', 'e'])
          Document(id: id, content: '', score: 1),
      ];
      final result = await const ScoreReorderTransformer().transform(docs);
      // Sorted a, b, c, d, e; interleaved [a, c, e, d, b].
      expect(_ids(result), ['a', 'c', 'e', 'd', 'b']);
    });

    test('a NaN score counts as the lowest', () async {
      final docs = [
        const Document(id: 'nan', content: '', score: double.nan),
        const Document(id: 'two', content: '', score: 2),
        const Document(id: 'one', content: '', score: 1),
        const Document(id: 'minus', content: '', score: -5),
      ];
      final result = await const ScoreReorderTransformer().transform(docs);
      // Sorted two, one, minus, nan; interleaved [two, minus, nan, one].
      expect(_ids(result), ['two', 'minus', 'nan', 'one']);
    });

    test('leaves the input list as it is and returns a new one', () async {
      final input = [_scoredDocs[1], _scoredDocs[3], _scoredDocs[2]];
      final before = List.of(input);
      final result =
          await const ScoreReorderTransformer(scoreFieldKey: _scoreKey)
              .transform(input, options: const TransformerOptions());
      expect(input, before);
      expect(identical(result, input), isFalse);
      expect(_ids(result), ['3', '1', '2']);
    });

    test('empty and single inputs', () async {
      const reranker = ScoreReorderTransformer();
      expect(await reranker.transform(const []), isEmpty);
      const only = Document(id: 'x', content: 'x');
      expect(await reranker.transform(const [only]), [only]);
    });
  });
}
