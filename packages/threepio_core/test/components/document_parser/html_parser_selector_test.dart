// Tests of the `selector` of the legacy `HtmlParser` (the plan item
// "rebuild the existing HtmlParser on package:html with selector support";
// the regex pipeline is kept, the selector picks the HTML it runs on). Not
// a port of a Go test: eino-ext's selector belongs to its own HTML parser,
// tested in test/components/document/eino_html_parser_test.dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/document_parser/document_parser.dart';
import 'package:threepio_core/src/components/document_parser/html_parser.dart';
import 'package:threepio_core/threepio_core.dart' show ThreepioFormatException;

const _page = '''
<html>
<head>
  <title>Page &amp; title</title>
  <style>p { color: red; }</style>
</head>
<body>
  <nav>Menu</nav>
  <article id="main">
    <h1>Heading</h1>
    <script>track();</script>
    <p class="x">First paragraph</p>
    <!-- a comment -->
    <table><tr><th>K</th></tr><tr><td>v</td></tr></table>
    <img src="in.png" alt="inside">
  </article>
  <p class="x">Outside paragraph</p>
  <table><tr><th>Other</th></tr><tr><td>w</td></tr></table>
  <img src="out.png" alt="outside">
  <footer>Foot</footer>
</body>
</html>
''';

Future<ParseResult> _parse(
  String html, {
  String? selector,
  DocumentParserOptions? options,
}) =>
    HtmlParser(selector: selector).parseString(html, options: options);

void main() {
  test('a selector restricts the content to the element it matches',
      () async {
    final result = await _parse(_page, selector: '#main');
    final content = result.documents.single.content;

    expect(content, contains('Heading'));
    expect(content, contains('First paragraph'));
    expect(content, isNot(contains('Menu')));
    expect(content, isNot(contains('Outside paragraph')));
    expect(content, isNot(contains('Foot')));
    // The steps of the whole page run on the selection.
    expect(content, isNot(contains('track()')));
    expect(content, isNot(contains('a comment')));
  });

  test('several matches are joined in document order', () async {
    final result = await _parse(
      '<p class="x">one</p><div>skip</div><p class="x">two</p>',
      selector: '.x',
    );

    expect(result.documents.single.content, 'one\ntwo');
  });

  test('an element inside another match is not taken twice', () async {
    final result = await _parse(
      '<div class="c">outer <div class="c">inner</div> tail</div>',
      selector: '.c',
    );

    final content = result.documents.single.content;
    expect(content, 'outer inner\ntail');
    expect('inner'.allMatches(content), hasLength(1));
  });

  test('a selector that matches nothing gives empty content', () async {
    final result = await _parse(_page, selector: '#none');

    expect(result.documents.single.content, '');
    expect(result.documents.single.metadata['title'], 'Page & title');
  });

  test('the title comes from the whole page', () async {
    final result = await _parse(_page, selector: 'article');

    expect(result.documents.single.metadata['title'], 'Page & title');
    expect(result.documents.single.metadata['parser'], 'html');
  });

  test('tables and images are extracted from the selection only', () async {
    final result = await _parse(
      _page,
      selector: 'article',
      options: const DocumentParserOptions(
        extractTables: true,
        extractImages: true,
      ),
    );

    expect(result.extractedTables, hasLength(1));
    expect(result.extractedTables!.single.headers, ['K']);
    expect(result.extractedImages, hasLength(1));
    expect(result.extractedImages!.single.alt, 'inside');
  });

  test('parse reads the bytes with the selector too', () async {
    final result = await HtmlParser(selector: '.x').parse(
      Uint8List.fromList(utf8.encode('<p class="x">bytes</p><p>no</p>')),
    );

    expect(result.documents.single.content, 'bytes');
  });

  test('an invalid selector throws a ThreepioFormatException', () async {
    await expectLater(
      _parse(_page, selector: '<<'),
      throwsA(
        isA<ThreepioFormatException>()
            .having((e) => e.source, 'source', '<<')
            .having((e) => e.cause, 'cause', isA<FormatException>()),
      ),
    );
  });

  test('a selector package:html cannot evaluate throws a '
      'ThreepioFormatException', () async {
    await expectLater(
      _parse('<p>x</p>', selector: 'p:hover'),
      throwsA(
        isA<ThreepioFormatException>()
            .having((e) => e.message, 'message', startsWith('unsupported CSS selector')),
      ),
    );
  });

  test('a page nested too deeply for package:html throws a '
      'ThreepioFormatException', () async {
    // Spans: package:html builds nested divs in quadratic time.
    const depth = 15000;
    final page = '<html><body>${'<span>' * depth}x${'</span>' * depth}'
        '</body></html>';

    await expectLater(
      _parse(page, selector: 'span'),
      throwsA(
        isA<ThreepioFormatException>()
            .having((e) => e.source, 'source', 'span')
            .having((e) => e.cause, 'cause', isA<StackOverflowError>()),
      ),
    );
    // Without a selector the regex pipeline reads it.
    expect((await _parse(page)).documents.single.content, 'x');
  });

  test('without a selector the output is the one of the whole page',
      () async {
    const options = DocumentParserOptions(
      extractTables: true,
      extractImages: true,
    );
    final plain = await HtmlParser().parseString(_page, options: options);
    final withNull = await _parse(_page, options: options);

    expect(withNull.documents.single.content, plain.documents.single.content);
    expect(withNull.documents.single.metadata, plain.documents.single.metadata);
    expect(withNull.metadata, plain.metadata);
    expect(withNull.extractedTables, hasLength(plain.extractedTables!.length));
    expect(withNull.extractedImages, hasLength(plain.extractedImages!.length));
    expect(plain.documents.single.content, contains('Outside paragraph'));
    expect(HtmlParser().selector, isNull);
  });
}
