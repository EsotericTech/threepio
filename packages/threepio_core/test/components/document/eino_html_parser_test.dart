// Port of eino-ext `components/document/parser/html/html_test.go`
// (TestHTMLParser: "Test normal Parser", "test only text", "test with
// selector"), and tests written for the port: the metadata, the entry point
// on `HtmlParser`, the extra metadata of the call, selectors goquery treats
// specially, the raw text of <noscript>, a deeply nested page (walked
// without recursion), and bluemonday's UGC policy applied to the extracted text
// (bluemonday v1.0.27 `sanitize.go`, `policies.go`; expected values derived
// from the Go sources, the tokenizer of golang.org/x/net/html v0.41.0 and
// Go's net/url included).
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/parser/eino_html_parser.dart';
import 'package:threepio_core/src/components/document/parser/html_ugc_sanitizer.dart';
import 'package:threepio_core/threepio_core.dart';

const _testdata = 'test/components/document/testdata/eino_ext/parser/html';

Stream<List<int>> _bytes(String text) => Stream.value(utf8.encode(text));

void main() {
  final ctx = RunContext.background();

  group('TestHTMLParser', () {
    const p = HtmlContentParser();

    test('Test normal Parser', () async {
      final docs = await p.parse(
        ctx,
        File('$_testdata/normal.html').openRead(),
        options: const ParserOptions(
          extraMeta: {'key': 'value'},
          uri: 'http://localhost/testdata/normal.html',
        ),
      );

      expect(docs, hasLength(1));
      expect(docs[0].metadata[htmlMetaKeyTitle], 'Test Document');
      expect(
        docs[0].content,
        'Test Document\n\n\n    hello world!\n    content in xid',
      );
      expect(docs[0].metadata[htmlMetaKeyLanguage], 'en');
      expect(docs[0].metadata[htmlMetaKeyCharset], 'UTF-8');
      expect(
        docs[0].metadata[metaKeySource],
        'http://localhost/testdata/normal.html',
      );
      expect(docs[0].metadata['key'], 'value');
    });

    test('test only text', () async {
      final docs = await p.parse(ctx, File('$_testdata/text.html').openRead());

      expect(docs, hasLength(1));
      expect(docs[0].content, 'hello world');
    });

    test('test with selector', () async {
      const parser = HtmlContentParser(HtmlParserConfig(selector: '#xid'));

      final docs =
          await parser.parse(ctx, File('$_testdata/normal.html').openRead());

      expect(docs, hasLength(1));
      expect(docs[0].content, 'content in xid');
    });
  });

  group('metadata', () {
    test('has the description, and the source even without a URI', () async {
      final docs = await const HtmlContentParser()
          .parse(ctx, File('$_testdata/normal.html').openRead());

      expect(docs.single.metadata, {
        htmlMetaKeyTitle: 'Test Document',
        htmlMetaKeyDescription: 'this is a test html',
        htmlMetaKeyLanguage: 'en',
        htmlMetaKeyCharset: 'UTF-8',
        metaKeySource: '',
      });
    });

    test('leaves out what the page does not have', () async {
      final docs = await const HtmlContentParser()
          .parse(ctx, _bytes('<p>plain</p>'));

      expect(docs.single.metadata, {metaKeySource: ''});
      expect(docs.single.content, 'plain');
    });

    test('the title is the text of every <title>, as goquery reads it',
        () async {
      final docs = await const HtmlContentParser().parse(
        ctx,
        _bytes('<html><head><title>One</title></head><body>'
            '<svg><title>Two</title></svg></body></html>'),
      );

      expect(docs.single.metadata[htmlMetaKeyTitle], 'OneTwo');
    });

    test('the description and charset of the first meta that has them, the '
        'attribute value matched exactly', () async {
      final docs = await const HtmlContentParser().parse(
        ctx,
        _bytes('<html lang=""><head><meta charset="">'
            '<meta charset="utf-8"><meta name="Description" content="a">'
            '<meta name="description"><meta name="description" content="c">'
            '</head></html>'),
      );

      // goquery's AttrOr reads the first match only: an empty charset, a
      // description without content, an empty lang leave the keys out.
      expect(docs.single.metadata, {metaKeySource: ''});
    });

    test('the extra metadata of the call wins over the page', () async {
      final docs = await const HtmlContentParser().parse(
        ctx,
        File('$_testdata/normal.html').openRead(),
        options: const ParserOptions(
          uri: 'u',
          extraMeta: {htmlMetaKeyTitle: 'mine', metaKeySource: 'other'},
        ),
      );

      expect(docs.single.metadata[htmlMetaKeyTitle], 'mine');
      expect(docs.single.metadata[metaKeySource], 'other');
    });
  });

  group('content', () {
    test('the body selector of the URL loader', () async {
      const parser =
          HtmlContentParser(HtmlParserConfig(selector: htmlBodySelector));

      final docs = await parser.parse(
        ctx,
        File('test/components/document/testdata/eino_ext/loader/url/test.html')
            .openRead(),
      );

      expect(
        docs.single.content,
        'this is title\n    this is paragraph\n    \n     \n\n    \n'
        '        hello world in div\n    \n\n    a link from href tag',
      );
      expect(docs.single.metadata[htmlMetaKeyTitle], 'Test html in url loader');
    });

    test('the text of scripts stays and is HTML-escaped', () async {
      final docs = await const HtmlContentParser().parse(
        ctx,
        _bytes('<p>Tom &amp; "Jerry"</p><script>if (a > b) x = \'y\';</script>'),
      );

      expect(
        docs.single.content,
        'Tom &amp; &#34;Jerry&#34;if (a &gt; b) x = &#39;y&#39;;',
      );
    });

    test('escaped markup in the page is sanitized as markup', () async {
      final docs = await const HtmlContentParser().parse(
        ctx,
        _bytes('<pre>&lt;b&gt;bold&lt;/b&gt; &lt;script&gt;alert(1)'
            '&lt;/script&gt;done</pre>'),
      );

      expect(docs.single.content, '<b>bold</b> done');
    });

    test('noscript holds raw text, which is sanitized as markup (a tag '
        'manager snippet and a tracking pixel)', () async {
      // Go's parser runs with scripting on: the content of <noscript> is a
      // text node. Derived: the iframe and its (empty) content are dropped
      // as content bluemonday skips, the img keeps its allowed attributes,
      // its src written back by url.URL.String.
      final docs = await const HtmlContentParser(
        HtmlParserConfig(selector: htmlBodySelector),
      ).parse(
        ctx,
        _bytes('<html><head><title>T</title></head><body><noscript>'
            '<iframe src="https://www.googletagmanager.com/ns.html?id=GTM-X" '
            'height="0" width="0" style="display:none;visibility:hidden">'
            '</iframe></noscript><p>Hello &amp; <b>bye</b></p><noscript>'
            '<img src="https://x.example/y.gif?a=1&amp;b=2" alt="" width="1"/>'
            '</noscript></body></html>'),
      );

      expect(
        docs.single.content,
        'Hello &amp; bye'
        '<img src="https://x.example/y.gif?a=1&amp;b=2" alt="" width="1"/>',
      );
    });

    test('a deeply nested page is walked without recursion', () async {
      // Spans, not divs: package:html builds a tree of nested divs in
      // quadratic time (as Go's parser does), nested spans in linear time.
      const depth = 15000;
      final page = '<html><head><title>Deep</title>'
          '<meta name="description" content="d"></head><body>'
          '${'<span>' * depth}x${'</span>' * depth}</body></html>';

      for (final parser in [
        const HtmlContentParser(),
        const HtmlContentParser(HtmlParserConfig(selector: htmlBodySelector)),
        const HtmlContentParser(HtmlParserConfig(selector: 'BODY')),
      ]) {
        final docs = await parser.parse(ctx, _bytes(page));
        expect(docs.single.content, endsWith('x'));
        expect(docs.single.metadata[htmlMetaKeyTitle], 'Deep');
        expect(docs.single.metadata[htmlMetaKeyDescription], 'd');
      }

      // Other selectors are evaluated by package:html, recursively: past
      // what the stack holds, a ThreepioFormatException.
      await expectLater(
        const HtmlContentParser(HtmlParserConfig(selector: 'body > span'))
            .parse(ctx, _bytes(page)),
        throwsA(
          isA<ThreepioFormatException>()
              .having((e) => e.source, 'source', 'body > span')
              .having((e) => e.cause, 'cause', isA<StackOverflowError>()),
        ),
      );
    });

    test('nested matches give their text twice, as goquery does', () async {
      const parser = HtmlContentParser(HtmlParserConfig(selector: 'div'));

      final docs =
          await parser.parse(ctx, _bytes('<div>a<div>b</div></div>'));

      expect(docs.single.content, 'abb');
    });

    test('a selector that matches nothing gives empty content', () async {
      const parser = HtmlContentParser(HtmlParserConfig(selector: '#none'));

      final docs = await parser.parse(ctx, _bytes('<p>x</p>'));

      expect(docs.single.content, '');
    });

    test('an invalid selector matches nothing', () async {
      const parser = HtmlContentParser(HtmlParserConfig(selector: '<<'));

      final docs = await parser.parse(ctx, _bytes('<p>x</p>'));

      expect(docs.single.content, '');
    });

    test('bytes that are not UTF-8 become U+FFFD', () async {
      final docs = await const HtmlContentParser().parse(
        ctx,
        Stream.value([0x61, 0xFF, 0x62]),
      );

      expect(docs.single.content, 'a${String.fromCharCode(0xFFFD)}b');
    });

    test('the bytes may arrive in pieces', () async {
      final all = utf8.encode('<p>hello pieces</p>');
      final docs = await const HtmlContentParser().parse(
        ctx,
        Stream.fromIterable([all.sublist(0, 5), all.sublist(5)]),
      );

      expect(docs.single.content, 'hello pieces');
    });
  });

  group('HtmlParser.fromConfig', () {
    test('returns the Eino parser', () async {
      final parser =
          HtmlParser.fromConfig(const HtmlParserConfig(selector: '#xid'));

      expect(parser, isA<HtmlContentParser>());
      expect(parser, isNot(isA<TypedComponent>()));
      final docs =
          await parser.parse(ctx, File('$_testdata/normal.html').openRead());
      expect(docs.single.content, 'content in xid');
    });

    test('takes the whole document by default', () async {
      final parser = HtmlParser.fromConfig();

      final docs =
          await parser.parse(ctx, File('$_testdata/normal.html').openRead());
      expect(
        docs.single.content,
        'Test Document\n\n\n    hello world!\n    content in xid',
      );
    });

    test('works under ExtParser', () async {
      final parser = ExtParser(parsers: {'.html': HtmlParser.fromConfig()});

      final docs = await parser.parse(
        ctx,
        File('$_testdata/normal.html').openRead(),
        options: const ParserOptions(uri: 'site/normal.html', extraMeta: {'k': 1}),
      );

      expect(docs.single.metadata[htmlMetaKeyTitle], 'Test Document');
      expect(docs.single.metadata[metaKeySource], 'site/normal.html');
      expect(docs.single.metadata['k'], 1);
    });
  });

  group('sanitizeUgcText (bluemonday UGCPolicy)', () {
    test('escapes the characters HTML escapes', () {
      expect(sanitizeUgcText('a & b'), 'a &amp; b');
      expect(sanitizeUgcText('it\'s "q"'), 'it&#39;s &#34;q&#34;');
      expect(sanitizeUgcText('x < y > z'), 'x &lt; y &gt; z');
    });

    test('decodes entity references before escaping', () {
      expect(
        sanitizeUgcText('AT&T &copy 2024 &amp;lt;'),
        'AT&amp;T ${String.fromCharCode(0xA9)} 2024 &amp;lt;',
      );
    });

    test('returns input that is only white space as it is', () {
      expect(sanitizeUgcText('  \n '), '  \n ');
      expect(sanitizeUgcText(''), '');
    });

    test('normalizes newlines', () {
      expect(sanitizeUgcText('a\r\nb\rc'), 'a\nb\nc');
    });

    test('keeps allowed elements and drops their other attributes', () {
      expect(
        sanitizeUgcText('<b>bold</b> <i class="x">it</i>'),
        '<b>bold</b> <i>it</i>',
      );
      expect(sanitizeUgcText('<div onclick="x()">d</div>'), '<div>d</div>');
      expect(sanitizeUgcText('<br/>'), '<br/>');
      expect(sanitizeUgcText('<p title="A title">t</p>'), '<p title="A title">t</p>');
    });

    test('drops unknown elements but keeps their text', () {
      expect(sanitizeUgcText('<unknown>u</unknown>'), 'u');
      expect(
        sanitizeUgcText('<textarea><b>x</b></textarea>'),
        '&lt;b&gt;x&lt;/b&gt;',
      );
    });

    test('drops scripts, styles, titles and comments with their content', () {
      expect(sanitizeUgcText('<script>alert(1)</script>after'), 'after');
      expect(sanitizeUgcText('<style>p{}</style>after'), 'after');
      expect(sanitizeUgcText('<title>t</title>rest'), 'rest');
      expect(sanitizeUgcText('<!-- c -->x<!DOCTYPE html>y'), 'xy');
      expect(sanitizeUgcText('<iframe>i</iframe>z'), 'z');
    });

    test('links keep a valid href and get rel="nofollow"', () {
      expect(
        sanitizeUgcText('<a href="http://x.com/p">l</a>'),
        '<a href="http://x.com/p" rel="nofollow">l</a>',
      );
      expect(
        sanitizeUgcText('<a href="http://x.com/?a=1&amp;b=2">l</a>'),
        '<a href="http://x.com/?a=1&amp;b=2" rel="nofollow">l</a>',
      );
      expect(
        sanitizeUgcText('<a href="/rel">l</a>'),
        '<a href="/rel" rel="nofollow">l</a>',
      );
    });

    test('a link without an allowed href is dropped, its text kept', () {
      expect(sanitizeUgcText('<a href="javascript:alert(1)">l</a>'), 'l');
      expect(sanitizeUgcText('<a name="x">l</a>'), 'l');
      expect(sanitizeUgcText('<a href="a b">l</a>'), 'l');
    });

    test('images keep their allowed attributes', () {
      expect(
        sanitizeUgcText('<img src="a.png" alt="A" onerror="x">'),
        '<img src="a.png" alt="A">',
      );
      expect(sanitizeUgcText('<img onerror="x">'), '');
    });

    test('attribute values are matched against the policy patterns', () {
      expect(
        sanitizeUgcText('<td colspan="2" rowspan="x">c</td>'),
        '<td colspan="2">c</td>',
      );
      expect(
        sanitizeUgcText('<ol type="I"><li value="3">v</li></ol>'),
        '<ol type="I"><li value="3">v</li></ol>',
      );
    });

    test('numbers of meter and progress match bluemonday\'s Number pattern, '
        'in linear time', () {
      expect(
        sanitizeUgcText(
          '<meter value="1.5e3" min=".5" max="-2" low="1." high="+7">m</meter>',
        ),
        '<meter value="1.5e3" min=".5" max="-2" high="+7">m</meter>',
      );
      // Go's RE2 rejects a long run of digits that is not a number in linear
      // time; so does the pattern here (a backtracking [0-9]*\.?[0-9]+
      // would take minutes).
      final digits = '1' * 200000;
      expect(sanitizeUgcText('<progress value="${digits}x">p</progress>'), 'p');
      expect(
        sanitizeUgcText('<progress value="$digits">p</progress>'),
        '<progress value="$digits">p</progress>',
      );
    });

    test('script data follows the escape states of the tokenizer', () {
      // Inside `<!--`, a `<script>` makes the next `</script>` part of the
      // script; the one after it ends the script.
      expect(sanitizeUgcText('<script><!--<script>x</script>y</script>z'), 'z');
      expect(sanitizeUgcText('<script><!-- a --></script>b'), 'b');
      expect(sanitizeUgcText('<script>a<!-</script>b'), 'b');
      // A script that never ends takes the rest of the text with it.
      expect(sanitizeUgcText('a<script><!--<script>x</script>'), 'a');
    });

    test('URLs are written back as Go\'s url.URL.String writes them', () {
      final u = String.fromCharCode(0xFC);
      expect(
        sanitizeUgcText('<a href="HTTP://Example.com/#">l</a>'),
        '<a href="http://Example.com/" rel="nofollow">l</a>',
      );
      expect(
        sanitizeUgcText('<a href="http://x.com/$u?q=$u#f$u">l</a>'),
        '<a href="http://x.com/%C3%BC?q=$u#f%C3%BC" rel="nofollow">l</a>',
      );
      expect(
        sanitizeUgcText('<a href="http://$u.de/%7e">l</a>'),
        '<a href="http://%C3%BC.de/%7e" rel="nofollow">l</a>',
      );
      expect(
        sanitizeUgcText('<a href="http://a%2fb:p@x.com/">l</a>'),
        '<a href="http://a%2Fb:p@x.com/" rel="nofollow">l</a>',
      );
      // An opaque URL is not checked; an empty host leaves only the scheme.
      expect(
        sanitizeUgcText('<a href="mailto:100%">l</a>'),
        '<a href="mailto:100%" rel="nofollow">l</a>',
      );
      expect(
        sanitizeUgcText('<a href="http://">l</a>'),
        '<a href="http:" rel="nofollow">l</a>',
      );
      expect(sanitizeUgcText('<a href="?">l</a>'), '<a href="?" rel="nofollow">l</a>');
    });

    test('URLs Go rejects', () {
      expect(sanitizeUgcText('<a href="#">l</a>'), 'l');
      expect(sanitizeUgcText('<a href="http://x.com:80a/">l</a>'), 'l');
      expect(sanitizeUgcText('<a href="http://[::1/">l</a>'), 'l');
      expect(sanitizeUgcText('<a href="http://x%41.com/">l</a>'), 'l');
      expect(sanitizeUgcText('<a href="http://x.com/%zz">l</a>'), 'l');
      expect(sanitizeUgcText('<a href="http://u{x}@x.com/">l</a>'), 'l');
      expect(sanitizeUgcText('<a href="a:b/c:d">l</a>'), 'l');
      expect(sanitizeUgcText('<a href="ftp://x.com/">l</a>'), 'l');
      expect(
        sanitizeUgcText('<blockquote cite="javascript:x">q</blockquote>'),
        '<blockquote>q</blockquote>',
      );
      expect(sanitizeUgcText('<img src="a b.png" alt="A">'), '<img alt="A">');
    });

    test('text after a tag that is never closed is lost, as in Go', () {
      expect(sanitizeUgcText('1 <b and c'), '1 ');
      expect(sanitizeUgcText('end <'), 'end &lt;');
    });
  });
}
