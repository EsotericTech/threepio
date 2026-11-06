// Port of eino-ext `components/document/parser/xlsx/xlsx_parser_test.go`
// (TestXlsxParser_Parse: TestXlsxParser_WithDefault, _WithAnotherSheet,
// _WithIDPrefix, _WithNoHeader), and tests written for the port: what
// excelize v2.9.0 `GetRows` returns for sparse cells, empty rows, booleans,
// numbers, shared and inline strings, formulas and broken references
// (expected values derived from excelize `rows.go`, `cell.go`, `lib.go` and
// Go's `strconv.FormatFloat`), the errors, and the options. The workbooks
// beyond the fixture are built in memory with package:archive.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/document/parser/xlsx_parser.dart';
import 'package:threepio_core/threepio_core.dart';

const _fixture = 'test/components/document/testdata/eino_ext/parser/xlsx/test.xlsx';

const _main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const _rel =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

/// A workbook with [sheets] (name → the XML inside `<sheetData>`), and
/// optionally shared strings (the XML inside `<sst>`) and the number format
/// of every cell style.
Uint8List _workbook(
  Map<String, String> sheets, {
  String? sharedStrings,
  List<int>? numFmts,
  bool rawSharedStrings = false,
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        '_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="$_rel/officeDocument" Target="xl/workbook.xml"/>'
            '</Relationships>',
      ),
    );
  final names = sheets.keys.toList();
  archive
    ..addFile(
      ArchiveFile.string(
        'xl/workbook.xml',
        '<workbook xmlns="$_main" xmlns:r="$_rel"><sheets>'
            '${[for (final (i, name) in names.indexed) '<sheet name="$name" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}'
            '</sheets></workbook>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/_rels/workbook.xml.rels',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '${[for (final (i, _) in names.indexed) '<Relationship Id="rId${i + 1}" Type="$_rel/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'].join()}'
            '</Relationships>',
      ),
    );
  for (final (i, name) in names.indexed) {
    archive.addFile(
      ArchiveFile.string(
        'xl/worksheets/sheet${i + 1}.xml',
        '<worksheet xmlns="$_main"><sheetData>${sheets[name]}</sheetData></worksheet>',
      ),
    );
  }
  if (sharedStrings != null) {
    archive.addFile(
      ArchiveFile.string(
        'xl/sharedStrings.xml',
        rawSharedStrings ? sharedStrings : '<sst xmlns="$_main">$sharedStrings</sst>',
      ),
    );
  }
  if (numFmts != null) {
    archive.addFile(
      ArchiveFile.string(
        'xl/styles.xml',
        '<styleSheet xmlns="$_main"><cellXfs>'
            '${[for (final id in numFmts) '<xf numFmtId="$id"/>'].join()}'
            '</cellXfs></styleSheet>',
      ),
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

Future<List<Document>> _parse(
  Uint8List bytes, {
  XlsxParserConfig config = const XlsxParserConfig(noHeader: true),
  ParserOptions? options,
}) =>
    XlsxParser(config).parse(
      RunContext.background(),
      Stream.value(bytes),
      options: options,
    );

void main() {
  final ctx = RunContext.background();

  group('TestXlsxParser_Parse', () {
    test('TestXlsxParser_WithDefault', () async {
      const p = XlsxParser();

      final docs = await p.parse(
        ctx,
        File(_fixture).openRead(),
        options: const ParserOptions(extraMeta: {'test': 'test'}),
      );

      expect(docs, isNotEmpty);
      expect(docs[0].content, isNotEmpty);
      expect(docs[0].metadata[xlsxMetaKeyRow], {'年龄': '21', '性别': '男', '姓名': '张三'});
      expect(docs[0].metadata[xlsxMetaKeyExt], {'test': 'test'});
    });

    test('TestXlsxParser_WithAnotherSheet', () async {
      const p = XlsxParser(XlsxParserConfig(sheetName: 'Sheet2'));

      final docs = await p.parse(
        ctx,
        File(_fixture).openRead(),
        options: const ParserOptions(extraMeta: {'test': 'test'}),
      );

      expect(docs, isNotEmpty);
      expect(docs[0].content, isNotEmpty);
      expect(docs[0].metadata[xlsxMetaKeyRow], {'年龄': '21', '性别': '男', '姓名': '张三'});
      expect(docs[0].metadata[xlsxMetaKeyExt], {'test': 'test'});
    });

    test('TestXlsxParser_WithIDPrefix', () async {
      const p = XlsxParser(
        XlsxParserConfig(sheetName: 'Sheet2', idPrefix: '_xlsx_row_'),
      );

      final docs = await p.parse(
        ctx,
        File(_fixture).openRead(),
        options: const ParserOptions(extraMeta: {'test': 'test'}),
      );

      expect(docs, isNotEmpty);
      expect(docs[0].content, isNotEmpty);
      expect(docs[0].metadata[xlsxMetaKeyRow], {'年龄': '21', '性别': '男', '姓名': '张三'});
      expect(docs[0].metadata[xlsxMetaKeyExt], {'test': 'test'});
    });

    test('TestXlsxParser_WithNoHeader', () async {
      const p = XlsxParser(XlsxParserConfig(sheetName: 'Sheet3', noHeader: true));

      final docs = await p.parse(
        ctx,
        File(_fixture).openRead(),
        options: const ParserOptions(extraMeta: {'test': 'test'}),
      );

      expect(docs, isNotEmpty);
      expect(docs[0].content, isNotEmpty);
      expect(docs[0].metadata[xlsxMetaKeyRow], <String, Object?>{});
      expect(docs[0].metadata[xlsxMetaKeyExt], {'test': 'test'});
    });
  });

  group('the fixture in full', () {
    test('the first sheet: a document per data row, ids from 1', () async {
      final docs = await const XlsxParser().parse(ctx, File(_fixture).openRead());

      expect([for (final doc in docs) doc.id], ['1', '2', '3', '4']);
      expect([for (final doc in docs) doc.content], [
        '张三\t男\t21',
        '李四\t男\t22',
        '李华\t男\t23',
        '王丽\t女\t22',
      ]);
      expect(docs[3].metadata, {
        xlsxMetaKeyRow: {'姓名': '王丽', '性别': '女', '年龄': '22'},
      });
    });

    test('ids with a prefix', () async {
      final docs = await const XlsxParser(
        XlsxParserConfig(sheetName: 'Sheet2', idPrefix: '_xlsx_row_'),
      ).parse(ctx, File(_fixture).openRead());

      expect(docs.first.id, '_xlsx_row_1');
      expect(docs.last.id, '_xlsx_row_4');
    });

    test('without a header every row is a document, ids from 0', () async {
      final docs = await const XlsxParser(
        XlsxParserConfig(sheetName: 'Sheet3', noHeader: true),
      ).parse(ctx, File(_fixture).openRead());

      expect([for (final doc in docs) (doc.id, doc.content)], [
        ('0', 'hello\tworld'),
        ('1', 'good\tgame'),
      ]);
    });

    test('the sheet name is compared without regard to case', () async {
      final docs = await const XlsxParser(
        XlsxParserConfig(sheetName: 'sheet3', noHeader: true),
      ).parse(ctx, File(_fixture).openRead());

      expect(docs.first.content, 'hello\tworld');
    });
  });

  group('GetRows', () {
    test('cells are placed by their reference', () async {
      final docs = await _parse(
        _workbook({
          'S': '<row r="1"><c r="A1" t="inlineStr"><is><t>a</t></is></c>'
              '<c r="C1"><v>3</v></c></row>',
        }),
      );

      expect(docs.single.content, 'a\t\t3');
    });

    test('empty rows keep their place, trailing empty cells go', () async {
      final docs = await _parse(
        _workbook({
          'S': '<row r="1"><c r="A1"><v>1</v></c><c r="B1" s="0"/></row>'
              '<row r="3"><c r="B3"><v>2</v></c></row>'
              '<row r="4"><c r="A4"/></row>',
        }),
      );

      expect([for (final doc in docs) (doc.id, doc.content)], [
        ('0', '1'),
        ('2', '\t2'),
      ]);
    });

    test('rows without a reference follow each other', () async {
      final docs = await _parse(
        _workbook({
          'S': '<row><c><v>1</v></c><c><v>2</v></c></row><row><c><v>3</v></c></row>',
        }),
      );

      expect([for (final doc in docs) doc.content], ['1\t2', '3']);
    });

    test('booleans, formula strings and errors', () async {
      final docs = await _parse(
        _workbook({
          'S': '<row r="1"><c r="A1" t="b"><v>1</v></c><c r="B1" t="b"><v>0</v></c>'
              '<c r="C1" t="str"><f>A1</f><v>x</v></c><c r="D1" t="e"><v>#DIV/0!</v></c></row>',
        }),
      );

      expect(docs.single.content, 'TRUE\tFALSE\tx\t#DIV/0!');
    });

    test('a formula without a value still takes its place', () async {
      final docs = await _parse(
        _workbook({
          'S': '<row r="1"><c r="A1"><f>1+1</f></c></row>'
              '<row r="2"><c r="A2"><v>z</v></c></row>',
        }),
      );

      expect([for (final doc in docs) (doc.id, doc.content)], [
        ('0', ''),
        ('1', 'z'),
      ]);
    });

    test('numbers in their shortest form, rounded past 15 digits', () async {
      final docs = await _parse(
        _workbook({
          'S': '<row r="1"><c r="A1"><v>0.30000000000000004</v></c>'
              '<c r="B1"><v>1E-3</v></c><c r="C1"><v>3.0</v></c>'
              '<c r="D1"><v>123456789012</v></c><c r="E1"><v>-1.5</v></c>'
              '<c r="F1"><v>1e21</v></c></row>',
        }),
      );

      expect(
        docs.single.content,
        '0.3\t0.001\t3\t123456789012\t-1.5\t1E+21',
      );
    });

    test('what reads as a number, as big.Float.SetString reads it, in linear '
        'time', () async {
      // A long run of digits that is not a number stays as it is, found out
      // in linear time (a backtracking [0-9]+\.?[0-9]* would take minutes).
      final digits = '1' * 200000;
      final docs = await _parse(
        _workbook({
          'S': '<row r="1"><c r="A1"><v>1.</v></c><c r="B1"><v>.5</v></c>'
              '<c r="C1"><v>1.e2</v></c><c r="D1"><v>+2</v></c>'
              '<c r="E1"><v>1e</v></c><c r="F1"><v>${digits}x</v></c></row>',
        }),
      );

      expect(docs.single.content, '1\t0.5\t100\t2\t1e\t${digits}x');
    });

    test('the General format of a style shows long numbers as %.10G', () async {
      final docs = await _parse(
        _workbook(
          {
            'S': '<row r="1"><c r="A1" s="1"><v>123456789012</v></c>'
                '<c r="B1" s="1"><v>12345678901</v></c>'
                '<c r="C1" s="1"><v>0.000123456789012</v></c>'
                '<c r="D1" s="2"><v>123456789012</v></c>'
                '<c r="E1" s="1" t="s"><v>0</v></c></row>',
          },
          numFmts: [0, 0, 164],
          sharedStrings: '<si><t>123456789012</t></si>',
        ),
      );

      // C1: excelize's precision counts the leading zeros of 0.000…
      expect(
        docs.single.content,
        '1.23456789E+11\t12345678901\t0.000123456789\t123456789012'
        '\t123456789012',
      );
    });

    test('rounding to 10 and 15 digits is half to even on the exact value',
        () async {
      final docs = await _parse(
        _workbook(
          {
            'S': '<row r="1"><c r="A1" s="1"><v>123456789050</v></c>'
                '<c r="B1" s="1"><v>123456789150</v></c>'
                '<c r="C1"><v>1234567890123.125</v></c>'
                '<c r="D1"><v>1234567890123.375</v></c>'
                '<c r="E1"><v>0.1234567890123456789</v></c></row>',
          },
          numFmts: [0, 0],
        ),
      );

      // A1, C1: exactly halfway, the digit before is even: down. B1, D1:
      // odd: up. E1: 0.123456789012346 (Go's shortest form of the double
      // has 17 digits, rounded to 15).
      expect(
        docs.single.content,
        '1.23456789E+11\t1.234567892E+11\t1234567890123.12'
        '\t1234567890123.38\t0.123456789012346',
      );
    });

    test('a cell attribute that does not decode drops the cell', () async {
      final docs = await _parse(
        _workbook(
          {
            'S': '<row r="1"><c r="A1"><v>1</v></c>'
                '<c r="B1" s="x"><v>2</v></c>'
                '<c r="C1" s=" 1 "><v>3</v></c>'
                '<c r="D1" cm="-1"><v>4</v></c>'
                '<c r="E1" ph="maybe"><v>5</v></c>'
                '<c r="F1" ph="1" vm="2"><v>6</v></c></row>',
          },
          numFmts: [0, 0],
        ),
      );

      // encoding/xml stops at the attribute (s is an int, cm a uint, ph a
      // bool) and never reads the value; a padded number is trimmed.
      expect(docs.single.content, '1\t\t3\t\t\t6');
    });

    test('shared strings: rich text runs, escapes, bad indexes', () async {
      final docs = await _parse(
        _workbook(
          {
            'S': '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c>'
                '<c r="C1" t="s"><v>7</v></c><c r="D1" t="s"><v>2</v></c></row>',
          },
          sharedStrings: '<si><r><t>ab</t></r><r><t>c_x0041_d</t></r></si>'
              '<si><t>x_x005F_x0041_y</t><rPh><t>skip</t></rPh></si>'
              '<si><t>&lt;tag&gt; &amp;</t></si>',
        ),
      );

      expect(docs.single.content, 'abcAd\tx_x0041_y\t7\t<tag> &');
    });

    test('shared strings with another root element leave no rows', () async {
      final docs = await _parse(
        _workbook(
          {'S': '<row r="1"><c r="A1"><v>1</v></c></row>'},
          sharedStrings: '<sst><si><t>a</t></si></sst>',
          rawSharedStrings: true,
        ),
      );

      expect(docs, isEmpty);
    });

    test('shared strings that cannot be read leave no rows', () async {
      final docs = await _parse(
        _workbook(
          {'S': '<row r="1"><c r="A1"><v>1</v></c></row>'},
          sharedStrings: '<sst><si><t>unclosed</si>',
          rawSharedStrings: true,
        ),
      );

      expect(docs, isEmpty);
    });

    test('a broken cell reference ends the rows before it', () async {
      final docs = await _parse(
        _workbook({
          'S': '<row r="1"><c r="A1"><v>1</v></c></row>'
              '<row r="2"><c r="A0"><v>2</v></c></row>'
              '<row r="3"><c r="A3"><v>3</v></c></row>',
        }),
      );

      expect([for (final doc in docs) doc.content], ['1']);
    });

    test('a row number that is not a number also loses the row before it',
        () async {
      final docs = await _parse(
        _workbook({
          'S': '<row r="1"><c r="A1"><v>1</v></c></row>'
              '<row r="x"><c r="A2"><v>2</v></c></row>',
        }),
      );

      expect(docs, isEmpty);
    });

    test('a row past the last Excel row ends the sheet', () async {
      final docs = await _parse(
        _workbook({
          'S': '<row r="1"><c r="A1"><v>1</v></c></row>'
              '<row r="99999999"><c r="A99999999"><v>2</v></c></row>'
              '<row r="3"><c r="A3"><v>3</v></c></row>',
        }),
      );

      expect([for (final doc in docs) doc.content], ['1']);
    });

    test('XML that breaks off ends the sheet where it breaks', () async {
      final archive = ZipDecoder().decodeBytes(
        _workbook({'S': '<row r="1"><c r="A1"><v>1</v></c></row>'}),
      );
      final broken = Archive();
      for (final file in archive.files) {
        broken.addFile(
          file.name == 'xl/worksheets/sheet1.xml'
              ? ArchiveFile.string(
                  file.name,
                  '<worksheet xmlns="$_main"><sheetData><row r="1">'
                  '<c r="A1"><v>1</v></c></row><row r="2"><c r="A2"><v>2<',
                )
              : file,
        );
      }

      final docs = await _parse(ZipEncoder().encodeBytes(broken));

      expect([for (final doc in docs) doc.content], ['1']);
    });
  });

  group('metadata', () {
    test('headers and cells are paired as far as both go', () async {
      final docs = await _parse(
        _workbook({
          'S': '<row r="1"><c r="A1" t="inlineStr"><is><t>h1</t></is></c>'
              '<c r="B1" t="inlineStr"><is><t>h2</t></is></c>'
              '<c r="C1" t="inlineStr"><is><t>h3</t></is></c></row>'
              '<row r="2"><c r="A2"><v>1</v></c><c r="B2" t="inlineStr"><is><t> 2 </t></is></c></row>'
              '<row r="3"><c r="A3"><v>1</v></c><c r="B3"><v>2</v></c><c r="C3"><v>3</v></c>'
              '<c r="D3"><v>4</v></c></row>',
        }),
        config: const XlsxParserConfig(),
      );

      expect(docs[0].metadata, {
        xlsxMetaKeyRow: {'h1': '1', 'h2': ' 2 '},
      });
      expect(docs[0].content, '1\t2');
      expect(docs[1].metadata[xlsxMetaKeyRow], {'h1': '1', 'h2': '2', 'h3': '3'});
      expect(docs[1].content, '1\t2\t3\t4');
    });

    test('an empty extra metadata map is still added', () async {
      final docs = await _parse(
        _workbook({'S': '<row r="1"><c r="A1"><v>1</v></c></row>'}),
        options: const ParserOptions(extraMeta: {}),
      );

      expect(docs.single.metadata, {
        xlsxMetaKeyRow: <String, Object?>{},
        xlsxMetaKeyExt: <String, Object?>{},
      });
    });
  });

  group('errors', () {
    test('a sheet that does not exist', () async {
      await expectLater(
        _parse(
          _workbook({'S': ''}),
          config: const XlsxParserConfig(sheetName: 'Nope'),
        ),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'sheet Nope does not exist'),
        ),
      );
    });

    test('a sheet name excelize rejects', () async {
      await expectLater(
        _parse(
          _workbook({'S': ''}),
          config: const XlsxParserConfig(sheetName: 'a:b'),
        ),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            r'the sheet can not contain any of the characters :\/?*[or]',
          ),
        ),
      );
      await expectLater(
        _parse(
          _workbook({'S': ''}),
          config: XlsxParserConfig(sheetName: 'x' * 32),
        ),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'the sheet name length exceeds the 31 characters limit',
          ),
        ),
      );
    });

    test('bytes that are not a zip archive', () async {
      await expectLater(
        _parse(Uint8List.fromList(utf8.encode('not a workbook'))),
        throwsA(
          isA<ThreepioFormatException>()
              .having((e) => e.message, 'message', 'zip: not a valid zip file'),
        ),
      );
    });

    test('parts that do not decode, with encoding/xml\'s messages', () async {
      final good = ZipDecoder().decodeBytes(_workbook({'S': '<row r="1"><c r="A1"><v>1</v></c></row>'}));
      Uint8List replaced(String name, String content) {
        final archive = Archive();
        for (final file in good.files) {
          archive.addFile(
            file.name == name ? ArchiveFile.string(name, content) : file,
          );
        }
        if (archive.findFile(name) == null) {
          archive.addFile(ArchiveFile.string(name, content));
        }
        return ZipEncoder().encodeBytes(archive);
      }

      Matcher failsWith(String message) => throwsA(
            isA<ThreepioFormatException>()
                .having((e) => e.message, 'message', message),
          );

      await expectLater(
        _parse(replaced('xl/workbook.xml', '<workbook><sheets/></workbook>')),
        failsWith(
          'expected element <workbook> in name space $_main but have no name space',
        ),
      );
      await expectLater(
        _parse(replaced('xl/workbook.xml', '<book xmlns="$_main"/>')),
        failsWith('expected element type <workbook> but have <book>'),
      );
      await expectLater(
        _parse(replaced('xl/_rels/workbook.xml.rels', '<Relationships/>')),
        failsWith(
          'expected element <Relationships> in name space '
          'http://schemas.openxmlformats.org/package/2006/relationships '
          'but have no name space',
        ),
      );
      await expectLater(
        _parse(
          replaced(
            'xl/styles.xml',
            '<styleSheet xmlns="$_main"><cellXfs><xf numFmtId="x"/></cellXfs></styleSheet>',
          ),
        ),
        failsWith('strconv.ParseInt: parsing "x": invalid syntax'),
      );
    });

    test('the strict namespace is read like the transitional one', () async {
      const strict = 'http://purl.oclc.org/ooxml/spreadsheetml/main';
      final archive = Archive();
      for (final file in ZipDecoder().decodeBytes(_workbook({'S': ''})).files) {
        archive.addFile(file);
      }
      archive
        ..addFile(
          ArchiveFile.string(
            'xl/workbook.xml',
            '<workbook xmlns="$strict" xmlns:r="$_rel"><sheets>'
                '<sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'xl/worksheets/sheet1.xml',
            '<worksheet xmlns="$strict"><sheetData><row r="1"><c r="A1" t="s">'
                '<v>0</v></c></row></sheetData></worksheet>',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'xl/sharedStrings.xml',
            '<sst xmlns="$strict"><si><t>strict</t></si></sst>',
          ),
        );

      final docs = await _parse(ZipEncoder().encodeBytes(archive));

      expect(docs.single.content, 'strict');
    });

    test('broken root relationships leave the workbook without sheets',
        () async {
      // excelize's getWorkbookPath ignores the error of _rels/.rels.
      final archive = Archive();
      for (final file in ZipDecoder().decodeBytes(_workbook({'S': '<row r="1"><c r="A1"><v>1</v></c></row>'})).files) {
        archive.addFile(
          file.name == '_rels/.rels'
              ? ArchiveFile.string('_rels/.rels', '<Relationships')
              : file,
        );
      }

      expect(await _parse(ZipEncoder().encodeBytes(archive)), isEmpty);
    });

    test('an encrypted workbook (an OLE file)', () async {
      await expectLater(
        _parse(
          Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0]),
        ),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'unsupported workbook file format',
          ),
        ),
      );
    });
  });

  test('parts without any element are read as missing, as excelize ignores '
      'the io.EOF of encoding/xml', () async {
    const declaration = '<?xml version="1.0" encoding="UTF-8"?>';
    final good = ZipDecoder().decodeBytes(
      _workbook(
        {'S': '<row r="1"><c r="A1"><v>1</v></c><c r="B1" t="s"><v>0</v></c></row>'},
        sharedStrings: '<si><t>x</t></si>',
        numFmts: [0],
      ),
    );
    Uint8List replaced(String name, String content) {
      final archive = Archive();
      for (final file in good.files) {
        archive.addFile(
          file.name == name ? ArchiveFile.string(name, content) : file,
        );
      }
      return ZipEncoder().encodeBytes(archive);
    }

    // A workbook without elements has no sheets.
    expect(await _parse(replaced('xl/workbook.xml', declaration)), isEmpty);
    // Shared strings without elements are no shared strings: the rows are
    // read (the index stays as it is).
    expect(
      [
        for (final doc
            in await _parse(replaced('xl/sharedStrings.xml', declaration)))
          doc.content,
      ],
      ['1\t0'],
    );
    // A style sheet of comments only is an empty one.
    expect(
      [
        for (final doc in await _parse(
          replaced('xl/styles.xml', '$declaration<!-- no styles -->'),
        ))
          doc.content,
      ],
      ['1\tx'],
    );
    // Empty workbook relationships: the sheet is listed but has no part, so
    // GetRows fails as for a sheet that does not exist.
    await expectLater(
      _parse(replaced('xl/_rels/workbook.xml.rels', declaration)),
      throwsA(
        isA<ThreepioException>()
            .having((e) => e.message, 'message', 'sheet S does not exist'),
      ),
    );
  });

  test('a workbook without sheets, and a sheet without rows, give nothing',
      () async {
    expect(await _parse(_workbook({})), isEmpty);
    expect(await _parse(_workbook({'S': ''})), isEmpty);
    expect(
      await _parse(_workbook({'S': '<row r="1"><c r="A1"/></row>'})),
      isEmpty,
    );
  });

  test('is a plain Parser, without a type name (Go has no GetType)', () {
    expect(const XlsxParser(), isA<Parser>());
    expect(const XlsxParser(), isNot(isA<TypedComponent>()));
  });

  test('works under ExtParser, which adds the extra metadata on top', () async {
    final parser = ExtParser(parsers: {'.xlsx': const XlsxParser()});

    final docs = await parser.parse(
      ctx,
      File(_fixture).openRead(),
      options: const ParserOptions(uri: 'data/test.xlsx', extraMeta: {'k': 1}),
    );

    expect(docs, hasLength(4));
    expect(docs.first.metadata[xlsxMetaKeyExt], {'k': 1});
    expect(docs.first.metadata['k'], 1);
  });
}
