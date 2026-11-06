// Port of eino-ext `components/document/parser/docx/docx_parser_test.go`
// (TestDocxParser_Parse: DocxParser_Parse_with_section,
// DocxParser_Parse_without_section), with the full content of the fixture
// (derived from eino-ext `docx_parser.go` and docx2md v0.0.1 `convert.go`,
// `docx_parser/*.go` read against the fixture's XML; Go walks its sections
// in random order, the port in the fixed order headers, main, tables,
// footers), and tests written for the port: docx2md's heading rules,
// styles, tables (go-runewidth v0.0.16 widths over rivo/uniseg v0.2.0
// grapheme clusters), what Go's struct decoding reads and misses (and
// where it fails: numPr decoded into a *bool, sizes into an int), the
// errors with docx2md's messages, and the options. The documents beyond
// the fixture are built in memory with package:archive. Expected values
// are derived from the Go sources; none is copied from a Go test beyond
// the two cases of TestDocxParser_Parse.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/parser/docx_parser.dart';
import 'package:threepio_core/src/components/document/parser/go_runewidth.dart';
import 'package:threepio_core/threepio_core.dart';

const _fixture =
    'test/components/document/testdata/eino_ext/parser/docx/test_docx.docx';

const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _rels = '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>';

/// A paragraph of runs, each a text and an optional font size.
String _p(List<(String, int?)> runs, {String pPr = ''}) => '<w:p>'
    '${pPr.isEmpty ? '' : '<w:pPr>$pPr</w:pPr>'}'
    '${[
      for (final (text, size) in runs)
        '<w:r>${size == null ? '' : '<w:rPr><w:sz w:val="$size"/></w:rPr>'}'
            '<w:t xml:space="preserve">$text</w:t></w:r>',
    ].join()}'
    '</w:p>';

/// A table of cell texts.
String _tbl(List<List<String>> rows) => '<w:tbl>'
    '${[
      for (final row in rows)
        '<w:tr>${[for (final cell in row) '<w:tc><w:p><w:r><w:t>$cell</w:t></w:r></w:p></w:tc>'].join()}</w:tr>',
    ].join()}'
    '</w:tbl>';

/// A DOCX archive with [body] in its document and the given parts.
Uint8List _docx(
  String body, {
  String? styles,
  List<String> headers = const [],
  List<String> footers = const [],
  String? rels = _rels,
  bool withDocument = true,
}) {
  final archive = Archive();
  if (withDocument) {
    archive.addFile(
      ArchiveFile.string(
        'word/document.xml',
        '<w:document xmlns:w="$_w"><w:body>$body</w:body></w:document>',
      ),
    );
  }
  if (rels != null) {
    archive.addFile(ArchiveFile.string('word/_rels/document.xml.rels', rels));
  }
  if (styles != null) {
    archive.addFile(
      ArchiveFile.string('word/styles.xml', '<w:styles xmlns:w="$_w">$styles</w:styles>'),
    );
  }
  for (final (i, header) in headers.indexed) {
    archive.addFile(
      ArchiveFile.string('word/header${i + 1}.xml', '<w:hdr xmlns:w="$_w">$header</w:hdr>'),
    );
  }
  for (final (i, footer) in footers.indexed) {
    archive.addFile(
      ArchiveFile.string('word/footer${i + 1}.xml', '<w:ftr xmlns:w="$_w">$footer</w:ftr>'),
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

Future<List<Document>> _parse(
  Uint8List bytes, [
  DocxParserConfig config = const DocxParserConfig(),
  ParserOptions? options,
]) =>
    DocxParser(config).parse(
      RunContext.background(),
      Stream.value(bytes),
      options: options,
    );

/// The main content of a document of [body], without its title line.
Future<String> _main(String body, {String? styles}) async {
  final docs = await _parse(
    _docx(body, styles: styles),
    const DocxParserConfig(toSections: true),
  );
  if (docs.isEmpty) return '';
  return docs.single.content.substring('=== MAIN CONTENT ===\n'.length);
}

Matcher _failsWith(String message) => throwsA(
      isA<ThreepioException>().having((e) => e.message, 'message', message),
    );

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

const _all = DocxParserConfig(
  includeHeaders: true,
  includeFooters: true,
  includeTables: true,
);

void main() {
  final ctx = RunContext.background();

  group('TestDocxParser_Parse', () {
    test('DocxParser_Parse_with_section', () async {
      const p = DocxParser(
        DocxParserConfig(
          toSections: true,
          includeHeaders: true,
          includeFooters: true,
          includeTables: true,
        ),
      );

      final docs = await p.parse(
        ctx,
        File(_fixture).openRead(),
        options: const ParserOptions(extraMeta: {'test': 'test'}),
      );

      expect(docs, hasLength(4));
      for (final doc in docs) {
        final typ = DocxParser.sectionTypeOf(doc);
        expect(typ, doc.metadata[docxMetaKeySectionType]);
      }
    });

    test('DocxParser_Parse_without_section', () async {
      const p = DocxParser(
        DocxParserConfig(
          includeHeaders: true,
          includeFooters: true,
          includeTables: true,
        ),
      );

      final docs = await p.parse(
        ctx,
        File(_fixture).openRead(),
        options: const ParserOptions(extraMeta: {'test': 'test'}),
      );

      expect(docs, hasLength(1));
      final typ = DocxParser.sectionTypeOf(docs[0]);
      expect(typ, docs[0].metadata[docxMetaKeySectionType]);
    });
  });

  group('the fixture in full', () {
    const table = '| Head1 | Head2 | Head3 |\n'
        '| ----- | ----- | ----- |\n'
        '| 1    | 3    | 5    |\n'
        '| 2    | 4    | 6    |';

    test('a document per section, in the fixed order', () async {
      final docs = await const DocxParser(
        DocxParserConfig(
          toSections: true,
          includeHeaders: true,
          includeFooters: true,
          includeTables: true,
        ),
      ).parse(
        ctx,
        File(_fixture).openRead(),
        options: const ParserOptions(extraMeta: {'test': 'test'}),
      );

      expect([for (final doc in docs) doc.content], [
        '=== HEADERS ===\nHeader',
        '=== MAIN CONTENT ===\nHello world\n\n=== test ===\nss',
        '=== TABLES ===\n$table',
        '=== FOOTERS ===\nfooter',
      ]);
      expect([for (final doc in docs) DocxParser.sectionTypeOf(doc)], [
        'headers',
        'main',
        'tables',
        'footers',
      ]);
      for (final doc in docs) {
        expect(doc.metadata['test'], 'test');
        expect(doc.id, matches(_uuid));
      }
      expect({for (final doc in docs) doc.id}, hasLength(4));
    });

    test('one document of every section', () async {
      final docs = await const DocxParser(_all).parse(
        ctx,
        File(_fixture).openRead(),
        options: const ParserOptions(extraMeta: {'test': 'test'}),
      );

      expect(
        docs.single.content,
        '=== HEADERS ===\nHeader\n'
        '=== MAIN CONTENT ===\nHello world\n\n=== test ===\nss\n'
        '=== TABLES ===\n$table\n'
        '=== FOOTERS ===\nfooter\n',
      );
      expect(docs.single.metadata, {
        'test': 'test',
        docxMetaKeySectionType: 'fullContent',
      });
      expect(docs.single.id, matches(_uuid));
    });

    test('by default only the main content', () async {
      final docs = await const DocxParser().parse(ctx, File(_fixture).openRead());

      expect(
        docs.single.content,
        '=== MAIN CONTENT ===\nHello world\n\n=== test ===\nss\n',
      );
    });
  });

  group('headings (docx2md word2Heading)', () {
    test('by the smallest font size of the paragraph', () async {
      expect(
        await _main(
          [
            _p([('Big', 48)]),
            _p([('Medium', 36)]),
            _p([('Short', 28)]),
            _p([('A rather long line', 28)]),
            _p([('Mixed', 48), (' sizes', 20)]),
            _p([('Small', 24)]),
          ].join(),
        ),
        '# Big\n## Medium\n### Short\nA rather long line\nMixed sizes\nSmall',
      );
    });

    test('numbered paragraphs get a fourth level, and longer headings',
        () async {
      // The fourth level takes headings of less than 45 bytes.
      const under = '2. Forty-four bytes are still under the cap!';
      const at = '3. A heading that is long but under the limit';
      expect(utf8.encode(under), hasLength(44));
      expect(utf8.encode(at), hasLength(45));

      expect(
        await _main(
          [
            _p([('Numbered', 24)], pPr: '<w:numPr><w:ilvl w:val="0"/></w:numPr>'),
            _p([('1. Introduction', 24)]),
            _p([(under, 24)]),
            _p([(at, 24)]),
            _p([('Not numbered', 24)]),
            _p([('A long numbered heading at size 28', 28)], pPr: '<w:numPr/>'),
          ].join(),
        ),
        '#### Numbered\n#### 1. Introduction\n'
        '#### $under\n'
        '$at\n'
        'Not numbered\n### A long numbered heading at size 28',
      );
    });

    test('the text inside numPr has to be a Go boolean, as encoding/xml '
        'decodes it into a *bool', () async {
      expect(
        await _main(
          [
            _p([('One', 36)], pPr: '<w:numPr>true</w:numPr>'),
            _p([('Two', 36)], pPr: '<w:numPr> 0 </w:numPr>'),
          ].join(),
        ),
        '## One\n## Two',
      );
      // Pretty-printed XML puts white space there, which Go rejects.
      await expectLater(
        _parse(_docx(_p([('x', null)], pPr: '<w:numPr>\n  <w:ilvl w:val="0"/>\n</w:numPr>'))),
        _failsWith(
          'open Docx document failed: failed to parse document.xml: '
          'strconv.ParseBool: parsing "": invalid syntax',
        ),
      );
      await expectLater(
        _parse(_docx(_p([('x', null)], pPr: '<w:numPr>yes</w:numPr>'))),
        _failsWith(
          'open Docx document failed: failed to parse document.xml: '
          'strconv.ParseBool: parsing "yes": invalid syntax',
        ),
      );
    });

    test('Chinese numerals anywhere count as numbering', () async {
      expect(
        await _main(
          [
            _p([('第一章', 28)]),
            _p([('总结三点', 24)]),
            _p([('第3节', 24)]),
          ].join(),
        ),
        '### 第一章\n#### 总结三点\n#### 第3节',
      );
    });

    test('the length limits count UTF-8 bytes', () async {
      // Five Chinese characters are 15 bytes: not under the limit of 15.
      expect(await _main(_p([('汉字汉字汉', 28)])), '汉字汉字汉');
      expect(await _main(_p([('汉字汉字', 28)])), '### 汉字汉字');
    });

    test('empty paragraphs become blank lines; text is trimmed', () async {
      expect(
        await _main([_p([('  a  ', null)]), _p([]), _p([('b', null)])].join()),
        'a\n\n\nb',
      );
    });
  });

  group('styles', () {
    test('a paragraph style sets the font size of every run', () async {
      const styles = '<w:style w:styleId="H"><w:rPr><w:sz w:val="48"/></w:rPr></w:style>'
          '<w:style w:styleId="Plain"/>';
      expect(
        await _main(
          [
            _p([('Styled', 20)], pPr: '<w:pStyle w:val="H"/>'),
            _p([('Reset', 48)], pPr: '<w:pStyle w:val="Plain"/>'),
            _p([('Unknown', 48)], pPr: '<w:pStyle w:val="Nope"/>'),
          ].join(),
          styles: styles,
        ),
        '# Styled\nReset\n# Unknown',
      );
    });

    test('a document without styles.xml is read (Go dereferences nil)',
        () async {
      expect(await _main(_p([('Big', 48)])), '# Big');
    });
  });

  group('what Go struct decoding reads', () {
    test('only runs that are children of the paragraph', () async {
      expect(
        await _main(
          '<w:p><w:r><w:t>kept</w:t></w:r>'
          '<w:hyperlink><w:r><w:t> lost</w:t></w:r></w:hyperlink>'
          '<w:r><w:tab/><w:t> too</w:t></w:r></w:p>',
        ),
        'kept too',
      );
    });

    test('paragraphs anywhere outside another paragraph or table', () async {
      expect(
        await _main(
          '<w:sdt><w:sdtContent>${_p([('in sdt', null)])}</w:sdtContent></w:sdt>',
        ),
        'in sdt',
      );
    });

    test('a cell is the text of its own paragraphs, joined', () async {
      final docs = await _parse(
        _docx(
          '<w:tbl><w:tr><w:tc>'
          '${_tbl([
            ['inner'],
          ])}'
          '${_p([('a', null)])}${_p([('b', null)])}'
          '</w:tc></w:tr></w:tbl>',
        ),
        const DocxParserConfig(toSections: true, includeTables: true),
      );

      expect(docs.map((d) => d.content), ['=== TABLES ===\n| ab |\n| -- |']);
    });

    test('headers in the order of the archive', () async {
      final archive = ZipDecoder().decodeBytes(_docx(_p([('body', null)])));
      final ordered = Archive();
      for (final file in archive.files) {
        ordered.addFile(file);
      }
      ordered
        ..addFile(
          ArchiveFile.string(
            'word/header2.xml',
            '<w:hdr xmlns:w="$_w">${_p([('second', null)])}</w:hdr>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'word/header1.xml',
            '<w:hdr xmlns:w="$_w">${_p([('first', null)])}</w:hdr>',
          ),
        );

      final docs = await _parse(
        ZipEncoder().encodeBytes(ordered),
        const DocxParserConfig(toSections: true, includeHeaders: true),
      );

      expect(docs.first.content, '=== HEADERS ===\nsecond\nfirst');
    });

    test('entities and CDATA in the text', () async {
      expect(
        await _main('<w:p><w:r><w:t>a &amp; b <![CDATA[<c>]]></w:t></w:r></w:p>'),
        'a & b <c>',
      );
    });
  });

  group('tables (docx2md Table2markdown)', () {
    test('uneven rows, and widths of wide characters', () async {
      final docs = await _parse(
        _docx(
          _tbl([
            ['名前', 'x'],
            ['a'],
          ]),
        ),
        const DocxParserConfig(toSections: true, includeTables: true),
      );

      expect(docs.map((d) => d.content), [
        '=== TABLES ===\n| 名前 | x |\n| ---- | - |\n| a   |  |',
      ]);
    });

    test('the tables of headers come first; footers last', () async {
      final docs = await _parse(
        _docx(
          _tbl([
            ['body'],
          ]),
          headers: [
            _tbl([
              ['head'],
            ]),
          ],
          footers: [
            _tbl([
              ['foot'],
            ]),
          ],
        ),
        const DocxParserConfig(toSections: true, includeTables: true, includeHeaders: true, includeFooters: true),
      );

      expect(
        docs.single.content,
        '=== TABLES ===\n| head |\n| ---- |\n\n| body |\n| ---- |\n\n| foot |\n| ---- |',
      );
    });

    test('without includeTables a table leaves only a blank line', () async {
      expect(
        await _main(
          [
            _p([('before', null)]),
            _tbl([
              ['x'],
            ]),
            _p([('after', null)]),
          ].join(),
        ),
        'before\n\nafter',
      );
    });

    test('emoji and combining marks', () async {
      final docs = await _parse(
        _docx(
          _tbl([
            ['e${String.fromCharCode(0x301)}', 'ab'],
            ['😀', '👍🏽'],
          ]),
        ),
        const DocxParserConfig(toSections: true, includeTables: true),
      );

      // é is one column wide, the emoji two each (the skin tone modifier
      // joins the thumb): the columns are 2 wide, é is padded by one space,
      // the cells as wide as their column get one space.
      expect(
        docs.single.content,
        '=== TABLES ===\n| e${String.fromCharCode(0x301)} | ab |\n'
        '| -- | -- |\n| 😀 | 👍🏽 |',
      );
    });
  });

  group('widths (go-runewidth StringWidth over uniseg grapheme clusters)', () {
    String chars(List<int> codes) => String.fromCharCodes(codes);

    test('a cluster counts as its first rune of non-zero width', () {
      expect(goStringWidth(''), 0);
      expect(goStringWidth('abc'), 3);
      expect(goStringWidth(chars([0x540D, 0x524D])), 4); // two CJK ideographs
      expect(goStringWidth(chars([0x65, 0x301])), 1); // e + combining acute
      // Hebrew points are not zero-width for go-runewidth, but extend the
      // cluster of their letter.
      expect(goStringWidth(chars([0x5E9, 0x5B8, 0x5C1])), 1);
      // A spacing mark (Devanagari vowel sign I) joins its consonant.
      expect(goStringWidth(chars([0x915, 0x93F])), 1);
      // A prepended concatenation mark joins what follows it.
      expect(goStringWidth(chars([0x600, 0x31])), 1);
    });

    test('emoji sequences, flags and Hangul syllables', () {
      expect(goStringWidth(chars([0x1F44D, 0x1F3FD])), 2); // skin tone
      expect(goStringWidth(chars([0x1F469, 0x200D, 0x1F4BB])), 2); // ZWJ
      expect(goStringWidth(chars([0x1F1EF, 0x1F1F5])), 1); // one flag
      expect(goStringWidth(chars([0x1F1EF, 0x1F1F5, 0x1F1FA])), 2);
      expect(goStringWidth(chars([0x1100, 0x1161, 0x11A8])), 2); // L V T
      expect(goStringWidth(chars([0xAC01])), 2); // the same, precomposed
    });

    test('controls are clusters of their own, of width 0', () {
      expect(goStringWidth('a\tb'), 2);
      expect(goStringWidth('\r\n'), 0);
      // A Hebrew point after a tab starts a cluster of its own (GB4), of
      // width 1; a combining acute there has width 0.
      expect(goStringWidth(chars([0x9, 0x5B8])), 1);
      expect(goStringWidth(chars([0x9, 0x301])), 0);
    });

    test('in a table', () async {
      final hebrew = chars([0x5E9, 0x5B8, 0x5C1]);
      final docs = await _parse(
        _docx(
          _tbl([
            [hebrew, 'x'],
            ['abc', 'y'],
          ]),
        ),
        const DocxParserConfig(toSections: true, includeTables: true),
      );

      expect(
        docs.single.content,
        '=== TABLES ===\n| $hebrew  | x |\n| --- | - |\n| abc | y |',
      );
    });
  });

  group('sections', () {
    test('headers and footers only when asked for', () async {
      final bytes = _docx(
        _p([('body', null)]),
        headers: [_p([('head', null)])],
        footers: [_p([('foot', null)])],
      );

      final none = await _parse(bytes, const DocxParserConfig(toSections: true));
      final all = await _parse(
        bytes,
        const DocxParserConfig(toSections: true, includeHeaders: true, includeFooters: true),
      );

      expect(none.map(DocxParser.sectionTypeOf), ['main']);
      expect(all.map((d) => d.content), [
        '=== HEADERS ===\nhead',
        '=== MAIN CONTENT ===\nbody',
        '=== FOOTERS ===\nfoot',
      ]);
    });

    test('empty sections are left out; an empty document gives nothing',
        () async {
      expect(await _parse(_docx(_p([]))), isEmpty);
      expect(await _parse(_docx(''), _all.copyWithSections()), isEmpty);
    });

    test('the section type wins over the extra metadata', () async {
      final docs = await _parse(
        _docx(_p([('x', null)])),
        const DocxParserConfig(toSections: true),
        const ParserOptions(extraMeta: {docxMetaKeySectionType: 'mine', 'k': 1}),
      );

      expect(docs.single.metadata, {docxMetaKeySectionType: 'main', 'k': 1});
    });
  });

  group('sectionTypeOf', () {
    test('reads the section type, or null', () {
      expect(
        DocxParser.sectionTypeOf(
          const Document(content: '', metadata: {docxMetaKeySectionType: 'main'}),
        ),
        'main',
      );
      expect(DocxParser.sectionTypeOf(const Document(content: '')), isNull);
      expect(
        DocxParser.sectionTypeOf(
          const Document(content: '', metadata: {docxMetaKeySectionType: 3}),
        ),
        isNull,
      );
      expect(DocxParser.sectionTypeOf(null), isNull);
    });
  });

  group('errors', () {
    test('bytes that are not a zip archive', () async {
      await expectLater(
        _parse(Uint8List.fromList(utf8.encode('not a docx'))),
        _failsWith('open Docx document failed: zip: not a valid zip file'),
      );
    });

    test('a zip archive without the document or its relationships', () async {
      await expectLater(
        _parse(_docx('', withDocument: false)),
        _failsWith('open Docx document failed: word/document.xml not found in docx'),
      );
      await expectLater(
        _parse(_docx('', rels: null)),
        _failsWith(
          'open Docx document failed: '
          'word/_rels/document.xml.rels not found in docx',
        ),
      );
    });

    test('a part that is in the archive twice', () async {
      final encoder = ZipEncoder();
      final output = OutputMemoryStream();
      encoder
        ..startEncode(output)
        ..add(ArchiveFile.string('word/document.xml', '<w:document xmlns:w="$_w"/>'))
        ..add(ArchiveFile.string('word/document.xml', '<w:document xmlns:w="$_w"/>'))
        ..add(ArchiveFile.string('word/_rels/document.xml.rels', _rels))
        ..endEncode();

      await expectLater(
        _parse(output.getBytes()),
        _failsWith(
          'open Docx document failed: '
          'duplicate file found in docx archive: word/document.xml',
        ),
      );
    });

    test('relationships that are not relationships', () async {
      await expectLater(
        _parse(_docx('', rels: '<Foo/>')),
        _failsWith(
          'open Docx document failed: '
          'expected element type <Relationships> but have <Foo>',
        ),
      );
      await expectLater(
        _parse(_docx('', rels: '<Relationships/>')),
        _failsWith(
          'open Docx document failed: expected element <Relationships> in '
          'name space http://schemas.openxmlformats.org/package/2006/'
          'relationships but have no name space',
        ),
      );
    });

    test('parts without any element read as encoding/xml reads them (io.EOF)',
        () async {
      const declaration = '<?xml version="1.0" encoding="UTF-8"?>';
      Uint8List archive(Map<String, String> parts) {
        final archive = Archive();
        parts.forEach((name, content) {
          archive.addFile(ArchiveFile.string(name, content));
        });
        return ZipEncoder().encodeBytes(archive);
      }

      final document = '<w:document xmlns:w="$_w"><w:body>'
          '${_p([('Body', null)])}</w:body></w:document>';
      // Relationships and styles are decoded into structs: Decode fails
      // with io.EOF.
      await expectLater(
        _parse(
          archive({
            'word/document.xml': document,
            'word/_rels/document.xml.rels': declaration,
          }),
        ),
        _failsWith('open Docx document failed: EOF'),
      );
      await expectLater(
        _parse(
          archive({
            'word/document.xml': document,
            'word/_rels/document.xml.rels': _rels,
            'word/styles.xml': '$declaration<!-- no styles -->',
          }),
        ),
        _failsWith('open Docx document failed: EOF'),
      );
      // The content parts are walked token by token: an empty part.
      expect(
        await _parse(
          archive({
            'word/document.xml': declaration,
            'word/_rels/document.xml.rels': _rels,
          }),
        ),
        isEmpty,
      );
      expect(
        await _parse(
          archive({
            'word/document.xml': '',
            'word/_rels/document.xml.rels': _rels,
          }),
        ),
        isEmpty,
      );
      final docs = await _parse(
        archive({
          'word/document.xml': document,
          'word/_rels/document.xml.rels': _rels,
          'word/header1.xml': declaration,
        }),
        const DocxParserConfig(includeHeaders: true),
      );
      expect(docs.single.content, '=== MAIN CONTENT ===\nBody\n');
    });

    test('XML that does not parse', () async {
      final archive = ZipDecoder().decodeBytes(_docx(''));
      final broken = Archive();
      for (final file in archive.files) {
        broken.addFile(
          file.name == 'word/document.xml'
              ? ArchiveFile.string(file.name, '<w:document><w:body>')
              : file,
        );
      }

      await expectLater(
        _parse(ZipEncoder().encodeBytes(broken)),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            startsWith('open Docx document failed: failed to parse document.xml: '),
          ),
        ),
      );
    });

    test('a font size that is not a number', () async {
      await expectLater(
        _parse(_docx('<w:p><w:r><w:rPr><w:sz w:val="abc"/></w:rPr><w:t>x</w:t></w:r></w:p>')),
        _failsWith(
          'open Docx document failed: failed to parse document.xml: '
          'strconv.ParseInt: parsing "abc": invalid syntax',
        ),
      );
    });

    test('a failing byte stream', () async {
      await expectLater(
        const DocxParser().parse(ctx, Stream.error(const ThreepioException('gone'))),
        _failsWith('docx parser failed to write to temporary file: gone'),
      );
      // Go prints the error of the reader; Dart's text of an I/O error is
      // its toString.
      const error = FileSystemException('gone');
      await expectLater(
        const DocxParser().parse(ctx, Stream.error(error)),
        throwsA(
          isA<ThreepioException>()
              .having(
                (e) => e.message,
                'message',
                'docx parser failed to write to temporary file: $error',
              )
              .having((e) => e.cause, 'cause', same(error)),
        ),
      );
    });

    test('a cancellation or an interrupt of the byte stream gets through',
        () async {
      await expectLater(
        const DocxParser().parse(ctx, Stream.error(const CancelledException('stop'))),
        throwsA(isA<CancelledException>()),
      );
    });

    test('a font size out of range, empty or padded', () async {
      await expectLater(
        _parse(_docx('<w:p><w:r><w:rPr><w:sz w:val="99999999999999999999"/></w:rPr><w:t>x</w:t></w:r></w:p>')),
        _failsWith(
          'open Docx document failed: failed to parse document.xml: '
          'strconv.ParseInt: parsing "99999999999999999999": value out of range',
        ),
      );
      expect(
        await _main(
          '<w:p><w:r><w:rPr><w:sz w:val=" 48 "/></w:rPr><w:t>Padded</w:t></w:r></w:p>'
          '<w:p><w:r><w:rPr><w:sz w:val=""/></w:rPr><w:t>Empty</w:t></w:r></w:p>',
        ),
        '# Padded\nEmpty',
      );
    });

    test('a style sheet with a font size that is not a number', () async {
      await expectLater(
        _parse(
          _docx(
            _p([('x', null)]),
            styles: '<w:style w:styleId="S"><w:rPr><w:sz w:val="big"/></w:rPr></w:style>',
          ),
        ),
        _failsWith(
          'open Docx document failed: strconv.ParseInt: parsing "big": invalid syntax',
        ),
      );
    });

    test('a header that does not parse fails even when headers are off',
        () async {
      final archive = ZipDecoder().decodeBytes(_docx(_p([('x', null)])));
      final broken = Archive();
      for (final file in archive.files) {
        broken.addFile(file);
      }
      broken.addFile(ArchiveFile.string('word/header1.xml', '<w:hdr>'));

      await expectLater(
        _parse(ZipEncoder().encodeBytes(broken)),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            startsWith('open Docx document failed: failed to parse word/header1.xml: '),
          ),
        ),
      );
    });
  });

  test('is a plain Parser, without a type name (Go has no GetType)', () {
    expect(const DocxParser(), isA<Parser>());
    expect(const DocxParser(), isNot(isA<TypedComponent>()));
  });
}

extension on DocxParserConfig {
  DocxParserConfig copyWithSections() => DocxParserConfig(
        toSections: true,
        includeHeaders: includeHeaders,
        includeFooters: includeFooters,
        includeTables: includeTables,
      );
}
