// Port of eino-ext components/document/transformer/splitter/markdown/
// header_test.go: TestMarkdownHeaderSplitter (case "success"), with Go's
// expected values. Every Go test of the package is ported.
//
// The other tests are written for the port: header lines kept, the code
// fence rules of header.go, header levels, Go's TrimSpace, metadata,
// validation, id generators and the run context, the static entry point
// on MarkdownSplitter, and a bounded property test that the splitting loop
// terminates and loses no line. Their expected values are derived by
// following header.go line by line (see the comments).
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/transformer/splitter/markdown_header_splitter.dart';
import 'package:threepio_core/src/components/document/transformer/splitter/split_id_generator.dart';
import 'package:threepio_core/threepio_core.dart';

/// Go's `fmt.Sprintf("%s_part%d", originalID, splitIndex)`.
String? _partIds(RunContext ctx, String? originalId, int splitIndex) =>
    '${originalId ?? ''}_part$splitIndex';

const _goInput =
    '# Header1\n\n ```code1\ncode2\ncode3\n```\n ## Header2\n\nContent1\n\n '
    '### Header3 \n\n Content2 \n\n ## Header4\n\n Content3';

const _threeLevels = {'#': 'Header1', '##': 'Header2', '###': 'Header3'};

Future<List<Document>> _split(
  MarkdownHeaderSplitterConfig config,
  List<Document> docs, {
  TransformerOptions? options,
}) =>
    MarkdownSplitter.fromHeaderConfig(config)
        .transform(docs, options: options);

/// Splits [content] with headers `#` → `h1`, `##` → `h2` and returns
/// `[content, metadata]` pairs (lists, which `equals` compares deeply).
Future<List<List<Object>>> _pairs(
  String content, {
  bool trimHeaders = false,
  Map<String, String> headers = const {'#': 'h1', '##': 'h2'},
}) async {
  final docs = await _split(
    MarkdownHeaderSplitterConfig(headers: headers, trimHeaders: trimHeaders),
    [Document(content: content)],
  );
  return [
    for (final doc in docs) [doc.content, doc.metadata],
  ];
}

void main() {
  group('TestMarkdownHeaderSplitter', () {
    test('success', () async {
      final ret = await _split(
        const MarkdownHeaderSplitterConfig(
          headers: _threeLevels,
          trimHeaders: true,
          idGenerator: _partIds,
        ),
        [const Document(id: 'id', content: _goInput)],
      );
      expect(ret, const [
        Document(
          id: 'id_part0',
          content: '```code1\ncode2\ncode3\n```',
          metadata: {'Header1': 'Header1'},
        ),
        Document(
          id: 'id_part1',
          content: 'Content1',
          metadata: {'Header1': 'Header1', 'Header2': 'Header2'},
        ),
        Document(
          id: 'id_part2',
          content: 'Content2',
          metadata: {
            'Header1': 'Header1',
            'Header2': 'Header2',
            'Header3': 'Header3',
          },
        ),
        Document(
          id: 'id_part3',
          content: 'Content3',
          metadata: {'Header1': 'Header1', 'Header2': 'Header4'},
        ),
      ]);
    });
  });

  group('MarkdownHeaderSplitter (port)', () {
    test('is reached through MarkdownSplitter.fromHeaderConfig', () {
      final splitter = MarkdownSplitter.fromHeaderConfig(
        const MarkdownHeaderSplitterConfig(headers: {'#': 'h1'}),
      );
      expect(splitter, isA<DocumentTransformer>());
      expect(splitter, isA<MarkdownHeaderSplitterTransformer>());
      expect(componentTypeNameOf(splitter), 'MarkdownHeaderSplitter');
      expect(isCallbacksEnabled(splitter), isFalse);
    });

    test('keeps the header lines unless trimHeaders is set', () async {
      // Go's input again, with TrimHeaders false: every chunk starts with
      // its header line, and the first one with the "# Header1" line.
      final ret = await _split(
        const MarkdownHeaderSplitterConfig(headers: _threeLevels),
        [const Document(content: _goInput)],
      );
      expect([for (final doc in ret) doc.content], [
        '# Header1\n```code1\ncode2\ncode3\n```',
        '## Header2\nContent1',
        '### Header3\nContent2',
        '## Header4\nContent3',
      ]);
      expect(ret.last.metadata, {'Header1': 'Header1', 'Header2': 'Header4'});
    });

    group('code fences', () {
      test('no header inside a fenced block', () async {
        expect(await _pairs('# A\n```\n# not a header\n```\nafter'), [
          ['# A\n```\n# not a header\n```\nafter', {'h1': 'A'}],
        ]);
      });

      test('a line with two ``` does not open a block', () async {
        expect(await _pairs('# A\n```inline```\n# B\nx'), [
          ['# A\n```inline```', {'h1': 'A'}],
          ['# B\nx', {'h1': 'B'}],
        ]);
      });

      test('~~~ opens a block that only ~~~ closes', () async {
        expect(await _pairs('~~~\n# in\n```\n~~~\n# out'), [
          ['~~~\n# in\n```\n~~~', <String, dynamic>{}],
          ['# out', {'h1': 'out'}],
        ]);
      });

      test('``` opens a block that only ``` closes', () async {
        expect(await _pairs('```\n~~~\n# x\n```\n# y'), [
          ['```\n~~~\n# x\n```', <String, dynamic>{}],
          ['# y', {'h1': 'y'}],
        ]);
      });

      test('an unclosed block runs to the end', () async {
        expect(await _pairs('```\n# x\n## y'), [
          ['```\n# x\n## y', <String, dynamic>{}],
        ]);
      });

      test('white space lines inside a block are kept, empty ones dropped',
          () async {
        expect(await _pairs('```\na\n   \n\nb\n```'), [
          ['```\na\n\nb\n```', <String, dynamic>{}],
        ]);
      });
    });

    group('headers', () {
      test('a header needs a space or the end of the line after it',
          () async {
        expect(await _pairs('#NoSpace\n# Yes\n#'), [
          ['#NoSpace', <String, dynamic>{}],
          ['# Yes', {'h1': 'Yes'}],
          ['#', {'h1': ''}],
        ]);
      });

      test('a header of a higher level ends the lower ones', () async {
        expect(await _pairs('## B\nb\n# A\na', trimHeaders: true), [
          ['b', {'h2': 'B'}],
          ['a', {'h1': 'A'}],
        ]);
      });

      test('unconfigured levels are plain lines', () async {
        expect(
          await _pairs('# A\n### C\nc', headers: const {'#': 'h1'}),
          [
            ['# A\n### C\nc', {'h1': 'A'}],
          ],
        );
      });

      test('lines are trimmed as Go trims them', () async {
        // CR LF line ends lose their CR, and indentation goes.
        expect(await _pairs('  # A  \r\n  body\r\n'), [
          ['# A\nbody', {'h1': 'A'}],
        ]);
        // Go's TrimSpace keeps U+FEFF: the line does not start with "#".
        final bom = String.fromCharCode(0xFEFF);
        expect(await _pairs('$bom# A\nx'), [
          ['$bom# A\nx', <String, dynamic>{}],
        ]);
      });

      test('a document ending with a trimmed header gives an empty chunk',
          () async {
        expect(await _pairs('x\n# End', trimHeaders: true), [
          ['x', <String, dynamic>{}],
          ['', {'h1': 'End'}],
        ]);
      });

      test('an empty document gives one empty chunk', () async {
        final ret = await _split(
          const MarkdownHeaderSplitterConfig(headers: {'#': 'h1'}),
          [
            const Document(id: 'e', content: '', metadata: {'k': 1}),
          ],
        );
        expect(ret, const [
          Document(id: 'e', content: '', metadata: {'k': 1}),
        ]);
      });
    });

    group('validation (Go messages)', () {
      test('no headers specified', () {
        expect(
          () => MarkdownSplitter.fromHeaderConfig(
            const MarkdownHeaderSplitterConfig(headers: {}),
          ),
          throwsA(
            isA<ArgumentError>()
                .having((e) => e.message, 'message', 'no headers specified'),
          ),
        );
      });

      test("header can only consist of '#'", () {
        for (final bad in ['h2', '# ', '#a#']) {
          expect(
            () => MarkdownSplitter.fromHeaderConfig(
              MarkdownHeaderSplitterConfig(headers: {'#': 'h1', bad: 'x'}),
            ),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                "header can only consist of '#': $bad",
              ),
            ),
          );
        }
      });
    });

    test('merges the header entries into a copy of the metadata', () async {
      final shared = <String>['tag'];
      final original = Document(
        id: 'doc',
        content: '# Title\nbody\n## Part\nmore',
        metadata: {'h1': 'overwritten', 'keep': shared},
        source: const DocumentSource(uri: 'mem://doc'),
      );
      final input = [original];
      final snapshot = original.copyWith();
      final ret = await _split(
        const MarkdownHeaderSplitterConfig(
          headers: {'#': 'h1', '##': 'h2'},
          trimHeaders: true,
        ),
        input,
      );
      expect(ret, hasLength(2));
      expect(ret[0].metadata, {'h1': 'Title', 'keep': shared});
      expect(ret[1].metadata, {'h1': 'Title', 'keep': shared, 'h2': 'Part'});
      // The document's entries first, then the headers in the order met.
      expect(ret[1].metadata.keys, ['h1', 'keep', 'h2']);
      for (final chunk in ret) {
        expect(identical(chunk.metadata['keep'], shared), isTrue);
        expect(chunk.source, original.source);
        expect(chunk.id, 'doc');
      }
      expect(input, [snapshot]);
    });

    test('the id generator gets the run context of the options', () async {
      final ctx = RunContext.background();
      final seen = <(RunContext, String?, int)>[];
      final ret = await _split(
        MarkdownHeaderSplitterConfig(
          headers: const {'#': 'h1'},
          idGenerator: (ctx, originalId, splitIndex) {
            seen.add((ctx, originalId, splitIndex));
            return '${originalId}_$splitIndex';
          },
        ),
        const [
          Document(id: 'a', content: '# x\n1\n# y\n2'),
          Document(content: 'plain'),
        ],
        options: TransformerOptions(runContext: ctx),
      );
      expect([for (final doc in ret) doc.id], ['a_0', 'a_1', 'null_0']);
      expect(seen.every((call) => identical(call.$1, ctx)), isTrue);
      expect(
        [for (final call in seen) (call.$2, call.$3)],
        [('a', 0), ('a', 1), (null, 0)],
      );
    });

    test('terminates and loses no line on random input (bounded property)',
        () async {
      final random = Random(20261106);
      const linePool = [
        '# a',
        '## b',
        '### c',
        '#### d',
        '#x',
        '#',
        '##',
        '  ## e  ',
        '\t# f',
        '```',
        '```js',
        '``` x ```',
        '````',
        '~~~',
        '~~~~',
        'text',
        'more text',
        '   ',
        '',
        'cr\r',
      ];
      const allHeaders = {'#': 'h1', '##': 'h2', '###': 'h3'};
      for (var round = 0; round < 300; round++) {
        final lineCount = random.nextInt(30);
        final rawLines = [
          for (var i = 0; i < lineCount; i++)
            linePool[random.nextInt(linePool.length)],
        ];
        final content = rawLines.join('\n');
        final headers = {
          for (final entry in allHeaders.entries)
            if (random.nextBool()) entry.key: entry.value,
        };
        if (headers.isEmpty) headers['#'] = 'h1';
        final trimHeaders = random.nextBool();
        final got = await _split(
          MarkdownHeaderSplitterConfig(
            headers: headers,
            trimHeaders: trimHeaders,
          ),
          [Document(content: content)],
        );
        final reason = 'round $round: $rawLines $headers $trimHeaders';
        // One chunk per header line at most, plus the last one.
        expect(got, isNotEmpty, reason: reason);
        expect(
          got.length,
          lessThanOrEqualTo(content.split('\n').length + 1),
          reason: reason,
        );
        for (final chunk in got) {
          expect(headers.values, containsAll(chunk.metadata.keys),
              reason: reason);
        }
        if (trimHeaders) continue;
        // Without trimming, every non-empty line, trimmed, is in exactly
        // one chunk, in order: the chunks joined with "\n" are the lines
        // joined with "\n". Only the last chunk is ambiguous when it is
        // empty: it holds either no line or one white-space line.
        final expected = [
          for (final line in content.split('\n'))
            if (line.isNotEmpty) splitterGoTrimSpace(line),
        ].join('\n');
        final lastEmpty = got.last.content.isEmpty;
        final joined = [
          for (final (i, chunk) in got.indexed)
            if (i < got.length - 1 || !lastEmpty) chunk.content,
        ].join('\n');
        expect(
          expected == joined || (lastEmpty && expected == '$joined\n'),
          isTrue,
          reason: '$reason\nexpected ${expected.codeUnits}\n'
              'joined ${joined.codeUnits}',
        );
      }
    });
  });
}
