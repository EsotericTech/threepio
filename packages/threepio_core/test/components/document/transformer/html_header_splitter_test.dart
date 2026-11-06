// Port of eino-ext components/document/transformer/splitter/html/
// header_test.go: TestHTMLHeaderSplitter (case "success", on
// commonSuccessHTML), with Go's expected values. Every Go test of the
// package is ported.
//
// The other tests are written for the port: the tree package:html builds for
// Go's input (implied html/head/body, text nodes) is the one x/net/html
// builds, the places where package:html's tree is known to differ from
// x/net/html v0.41 (<main> next to an unclosed <p>, <isindex>; pinned, with
// Go's result in a comment), header text extraction, header scope, levels, the
// "calculate header level fail" error, metadata, id generators and the run
// context, deep nesting, the static entry point on HtmlSplitter, and a
// bounded property test that the walk terminates and loses no text. Their
// expected values are derived by following header.go's dfs over the HTML5
// tree (see the comments).
import 'dart:math';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/transformer/splitter/html_header_splitter.dart';
import 'package:threepio_core/src/components/document/transformer/splitter/split_id_generator.dart';
import 'package:threepio_core/threepio_core.dart';

/// Go's `fmt.Sprintf("%s_part%d", originalID, splitIndex)`.
String? _partIds(RunContext ctx, String? originalId, int splitIndex) =>
    '${originalId ?? ''}_part$splitIndex';

// Go's commonSuccessHTML, byte for byte (tabs included).
const _commonSuccessHtml = '<!DOCTYPE html>\n'
    '<html>\n'
    '<body>\n'
    '    <div>\n'
    '        <h1>H1</h1>\n'
    '        <p>H1 content1</p>\n'
    '        <div>\n'
    '            <h2>H2.1</h2>\n'
    '            <p>H2.1 content</p>\n'
    '            <h3>H3.1</h3>\n'
    '            <p>H3.1 content</p>\n'
    '            <h3>H3.2</h3>\n'
    '            <p>H3.2 content</p>\n'
    '            <h2>H2.2</h2>\n'
    '            <p>H2.2 content</p>\n'
    '        </div>\n'
    '        <div>\n'
    '            <h2>H2.3</h2>\n'
    '            <p>H2.3 content</p>\n'
    '        </div>\n'
    '\t\t<div>\n'
    '\t\t\t<p>H1 content2</p>\n'
    '\t\t</div>\n'
    '        <br>\n'
    '        <p>H1 content3</p>\n'
    '    </div>\n'
    '\t<div>\n'
    '\t\t<h2>H2.4</h2>\n'
    '\t\t<p>H2.4 content</p>\n'
    '\t</div>\n'
    '\t<div>\n'
    '\t\t<p>content</p>\n'
    '\t</div>\n'
    '</body>\n'
    '</html>';

const _threeLevels = {'h1': 'Header1', 'h2': 'Header2', 'h3': 'Header3'};

Future<List<Document>> _split(
  HtmlHeaderSplitterConfig config,
  List<Document> docs, {
  TransformerOptions? options,
}) =>
    HtmlSplitter.fromHeaderConfig(config).transform(docs, options: options);

/// Splits [content] with [headers] and returns `[content, metadata]` pairs.
Future<List<List<Object>>> _pairs(
  String content, {
  Map<String, String> headers = _threeLevels,
}) async {
  final docs = await _split(
    HtmlHeaderSplitterConfig(headers: headers),
    [Document(content: content)],
  );
  return [
    for (final doc in docs) [doc.content, doc.metadata],
  ];
}

void main() {
  group('TestHTMLHeaderSplitter', () {
    test('success', () async {
      final ret = await _split(
        const HtmlHeaderSplitterConfig(
          headers: _threeLevels,
          idGenerator: _partIds,
        ),
        [const Document(id: 'id', content: _commonSuccessHtml)],
      );
      expect(ret, const [
        Document(
          id: 'id_part0',
          content: 'H1 content1',
          metadata: {'Header1': 'H1'},
        ),
        Document(
          id: 'id_part1',
          content: 'H2.1 content',
          metadata: {'Header1': 'H1', 'Header2': 'H2.1'},
        ),
        Document(
          id: 'id_part2',
          content: 'H3.1 content',
          metadata: {'Header1': 'H1', 'Header2': 'H2.1', 'Header3': 'H3.1'},
        ),
        Document(
          id: 'id_part3',
          content: 'H3.2 content',
          metadata: {'Header1': 'H1', 'Header2': 'H2.1', 'Header3': 'H3.2'},
        ),
        Document(
          id: 'id_part4',
          content: 'H2.2 content',
          metadata: {'Header1': 'H1', 'Header2': 'H2.2'},
        ),
        Document(
          id: 'id_part5',
          content: 'H2.3 content',
          metadata: {'Header1': 'H1', 'Header2': 'H2.3'},
        ),
        Document(
          id: 'id_part6',
          content: 'H1 content2H1 content3',
          metadata: {'Header1': 'H1'},
        ),
        Document(
          id: 'id_part7',
          content: 'H2.4 content',
          metadata: {'Header2': 'H2.4'},
        ),
        Document(id: 'id_part8', content: 'content'),
      ]);
    });
  });

  group('HtmlHeaderSplitter (port)', () {
    test('is reached through HtmlSplitter.fromHeaderConfig', () {
      final splitter = HtmlSplitter.fromHeaderConfig(
        const HtmlHeaderSplitterConfig(headers: {'h1': 'h1'}),
      );
      expect(splitter, isA<DocumentTransformer>());
      expect(splitter, isA<HtmlHeaderSplitterTransformer>());
      expect(componentTypeNameOf(splitter), 'HTMLHeaderSplitter');
      expect(isCallbacksEnabled(splitter), isFalse);
    });

    test("package:html builds x/net/html's tree for Go's input", () {
      // HTML5: the white space after the doctype and after <html> is
      // dropped, <head> is implied, the white space between and after the
      // three top-level divs becomes text nodes of <body> (also the line
      // break after </body>, which goes into <body> as in x/net/html's
      // afterBodyIM).
      final tree = html_parser.parse(_commonSuccessHtml);
      expect(
        [for (final node in tree.nodes) node.nodeType],
        [dom.Node.DOCUMENT_TYPE_NODE, dom.Node.ELEMENT_NODE],
      );
      final html = tree.nodes[1] as dom.Element;
      expect(html.localName, 'html');
      expect(
        [for (final node in html.nodes) (node as dom.Element).localName],
        ['head', 'body'],
      );
      expect(html.nodes[0].nodes, isEmpty);
      final body = html.nodes[1];
      expect(
        [
          for (final node in body.nodes)
            node is dom.Element ? node.localName : 'text',
        ],
        ['text', 'div', 'text', 'div', 'text', 'div', 'text'],
      );
      for (final node in body.nodes.whereType<dom.Text>()) {
        expect(node.data.trim(), isEmpty);
      }
      expect((body.nodes[0] as dom.Text).data, '\n    ');
      // The first div holds h1, p, div, div, div, br, p between white space.
      expect(
        [
          for (final node in body.nodes[1].nodes)
            if (node is dom.Element) node.localName,
        ],
        ['h1', 'p', 'div', 'div', 'div', 'br', 'p'],
      );
    });

    test('a header text is all the text inside the header element',
        () async {
      // Text nodes are kept untrimmed; only white-space-only ones go.
      expect(
        await _pairs('<h1>Hello <b>World</b>\n  </h1><p>x</p>'),
        [
          ['x', {'Header1': 'Hello World'}],
        ],
      );
    });

    test('text before the first header has no header metadata', () async {
      expect(await _pairs('<p>intro</p><h1>T</h1><p>x</p>'), [
        ['intro', <String, dynamic>{}],
        ['x', {'Header1': 'T'}],
      ]);
    });

    test('a header applies to what follows it within its parent', () async {
      // The div's level ends after "a" and emits it; "after" is outside the
      // div, where no header is in effect.
      expect(
        await _pairs('<div><h1>A</h1><p>a</p></div><p>after</p>'),
        [
          ['a', {'Header1': 'A'}],
          ['after', <String, dynamic>{}],
        ],
      );
    });

    test('unconfigured header elements are plain text', () async {
      expect(
        await _pairs(
          '<h1>A</h1><p>a</p><h2>B</h2><p>b</p>',
          headers: const {'h2': 'S'},
        ),
        [
          ['Aa', <String, dynamic>{}],
          ['b', {'S': 'B'}],
        ],
      );
    });

    test('the level is the whole number after the first letter', () async {
      // h10 is level 10: it is nested below h2 and ended by the next h2.
      expect(
        await _pairs(
          '<h2>A</h2><h10>B</h10><p>c</p><h2>D</h2><p>e</p>',
          headers: const {'h10': 'X', 'h2': 'Y'},
        ),
        [
          ['c', {'Y': 'A', 'X': 'B'}],
          ['e', {'Y': 'D'}],
        ],
      );
    });

    test('without headers everything is one chunk', () async {
      expect(await _pairs('<p>a</p><p>b</p>', headers: const {}), [
        ['ab', <String, dynamic>{}],
      ]);
    });

    test('text is kept untrimmed; comments and white space are dropped',
        () async {
      expect(await _pairs('<p>  a  </p>'), [
        ['  a  ', <String, dynamic>{}],
      ]);
      expect(await _pairs('<p>a<!-- c -->b</p>\n\n<p> </p>'), [
        ['ab', <String, dynamic>{}],
      ]);
    });

    test('text outside any element and script text count, as in Go',
        () async {
      expect(await _pairs('hello'), [
        ['hello', <String, dynamic>{}],
      ]);
      // <script> goes into the implied <head>; its text is a text node.
      expect(await _pairs('<script>var x</script><p>a</p>'), [
        ['var xa', <String, dynamic>{}],
      ]);
    });

    test('a document without text gives no chunk', () async {
      expect(await _pairs(''), isEmpty);
      expect(await _pairs('<h1>Only</h1>'), isEmpty);
    });

    test('a configured element without a level fails as in Go', () async {
      await expectLater(
        _pairs('<p>a</p><div>b</div>', headers: const {'div': 'D'}),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'calculate header level fail: div',
          ),
        ),
      );
      // Nothing is checked before an element with that name is met.
      expect(
        await _pairs('<p>a</p>', headers: const {'div': 'D'}),
        [
          ['a', <String, dynamic>{}],
        ],
      );
    });

    test('merges the header entries into a copy of the metadata', () async {
      final shared = <String>['tag'];
      final original = Document(
        id: 'doc',
        content: '<h1>T</h1><p>a</p><h2>S</h2><p>b</p>',
        metadata: {'Header1': 'overwritten', 'keep': shared},
        source: const DocumentSource(uri: 'mem://doc.html'),
      );
      final input = [original];
      final snapshot = original.copyWith();
      final ret = await _split(
        const HtmlHeaderSplitterConfig(headers: _threeLevels),
        input,
      );
      expect(ret, hasLength(2));
      expect(ret[0].metadata, {'Header1': 'T', 'keep': shared});
      expect(
        ret[1].metadata,
        {'Header1': 'T', 'keep': shared, 'Header2': 'S'},
      );
      expect(ret[1].metadata.keys, ['Header1', 'keep', 'Header2']);
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
        HtmlHeaderSplitterConfig(
          headers: const {'h1': 'h1'},
          idGenerator: (ctx, originalId, splitIndex) {
            seen.add((ctx, originalId, splitIndex));
            return '$originalId/$splitIndex';
          },
        ),
        const [
          Document(id: 'a', content: '<h1>x</h1>1<h1>y</h1>2'),
          Document(id: 'b', content: '<p>only</p>'),
        ],
        options: TransformerOptions(runContext: ctx),
      );
      expect([for (final doc in ret) doc.id], ['a/0', 'a/1', 'b/0']);
      expect([for (final doc in ret) doc.content], ['1', '2', 'only']);
      expect(seen.every((call) => identical(call.$1, ctx)), isTrue);
    });

    group('known parser deviations (package:html vs x/net/html v0.41)', () {
      test('<main> does not close an open <p>, nor </main> an inner one',
          () async {
        // x/net/html closes the <p> at </main>, so "y" follows the <main>
        // and Go gives [("x", {Header1: T}), ("y", {})]. package:html ignores
        // </main> while the <p> is open, and "y" joins "x" in the <p>.
        expect(await _pairs('<main><h1>T</h1><p>x</main>y'), [
          ['xy', {'Header1': 'T'}],
        ]);
      });

      test('<isindex> is expanded into a prompt text', () async {
        // x/net/html treats <isindex> as an ordinary element: Go gives no
        // chunk at all.
        expect(await _pairs('<isindex>'), [
          [
            'This is a searchable index. Enter search keywords: ',
            <String, dynamic>{},
          ],
        ]);
      });
    });

    test('a deeply nested document does not overflow the stack', () async {
      const depth = 6000;
      final content = '${'<div>' * depth}<h1>T</h1><p>x</p>${'</div>' * depth}';
      expect(await _pairs(content), [
        ['x', {'Header1': 'T'}],
      ]);
    });

    test('terminates and loses no text on random input (bounded property)',
        () async {
      final random = Random(20261106);
      const tokenPool = [
        '<h1>',
        '</h1>',
        '<h2>',
        '</h2>',
        '<h3>',
        '</h3>',
        '<div>',
        '</div>',
        '<p>',
        '</p>',
        '<b>',
        '</b>',
        '<section>',
        '</section>',
        '<table>',
        '<td>',
        '<li>',
        '<br>',
        '<!-- c -->',
        '<script>s</script>',
        'x',
        'y z',
        '&amp;',
        ' ',
        '\n',
      ];
      const allHeaders = {'h1': 'A', 'h2': 'B', 'h3': 'C'};
      for (var round = 0; round < 300; round++) {
        final tokenCount = random.nextInt(40);
        final content = [
          for (var i = 0; i < tokenCount; i++)
            tokenPool[random.nextInt(tokenPool.length)],
        ].join();
        final headers = {
          for (final entry in allHeaders.entries)
            if (random.nextBool()) entry.key: entry.value,
        };
        final got = await _split(
          HtmlHeaderSplitterConfig(headers: headers),
          [Document(content: content)],
        );
        final reason = 'round $round: $content $headers';
        // Every text node outside a configured header element (and not
        // white space only) is in exactly one chunk, in document order;
        // no chunk is empty.
        final expected = StringBuffer();
        void walk(dom.Node node) {
          if (node is dom.Element && headers.containsKey(node.localName)) {
            return;
          }
          if (node is dom.Text && splitterGoTrimSpace(node.data).isNotEmpty) {
            expected.write(node.data);
          }
          node.nodes.forEach(walk);
        }

        walk(html_parser.parse(content));
        expect(
          got.map((doc) => doc.content).join(),
          expected.toString(),
          reason: reason,
        );
        for (final chunk in got) {
          expect(chunk.content, isNotEmpty, reason: reason);
          expect(headers.values, containsAll(chunk.metadata.keys),
              reason: reason);
        }
      }
    });
  });
}
