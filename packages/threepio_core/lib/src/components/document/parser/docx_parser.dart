/// eino-ext's DOCX parser: the text of a Word document as Markdown, by
/// section.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/parser_utils.dart';
import '../../../schema/document.dart';
import '../../model/cancel_token.dart';
import 'go_runewidth.dart';
import 'go_text.dart';
import 'parser.dart';

/// The metadata key of the section a document holds: `headers`, `main`,
/// `tables` or `footers` for a document per section, `fullContent` for the
/// one document of the whole file.
///
/// Port of eino-ext `docx.SectionTypeKey`.
const String docxMetaKeySectionType = 'sectionType';

/// The configuration of [DocxParser].
///
/// Port of eino-ext `docx.Config`. Its `IncludeComments` is deprecated in
/// eino-ext (comments were never read) and is not ported.
@immutable
final class DocxParserConfig {
  /// A configuration; everything is off by default, as in Go.
  const DocxParserConfig({
    this.toSections = false,
    this.includeHeaders = false,
    this.includeFooters = false,
    this.includeTables = false,
  });

  /// Whether every non-empty section becomes a document of its own (Go:
  /// `ToSections`). The default returns one document with all of them.
  final bool toSections;

  /// Whether the page headers are read (section `headers`).
  final bool includeHeaders;

  /// Whether the page footers are read (section `footers`).
  final bool includeFooters;

  /// Whether the tables are read, as Markdown tables (section `tables`).
  final bool includeTables;
}

/// Parses a Word document (`.docx`) into Markdown-like text.
///
/// Port of eino-ext `parser/docx` (`docx.NewDocxParser`,
/// `DocxParser.Parse`) and of the conversion it delegates to,
/// `github.com/eino-contrib/docx2md` v0.0.1 (`DocxConvert` and its
/// `docx_parser` package), on `package:archive` and `package:xml`.
///
/// The document is cut into sections: `headers` (the page headers, with
/// [DocxParserConfig.includeHeaders]), `main` (the body), `tables` (every
/// table as a Markdown table, with [DocxParserConfig.includeTables]) and
/// `footers` (with [DocxParserConfig.includeFooters]). A paragraph is the
/// text of its runs; it becomes a heading (`#` to `####`) when its smallest
/// font size is large, by docx2md's rules (sizes in half-points: 48 for `#`,
/// 36 for `##`, 28 for `###`, 24 for `####` when the paragraph is numbered
/// or starts like a numbered heading, short headings only for the smaller
/// levels). Each section's text is trimmed and introduced by a title line:
/// `=== HEADERS ===`, `=== MAIN CONTENT ===`, `=== TABLES ===`,
/// `=== FOOTERS ===`.
///
/// With [DocxParserConfig.toSections] every non-empty section is a document
/// whose metadata names it under [docxMetaKeySectionType]; otherwise one
/// document holds the sections one after the other, each followed by `\n`,
/// with the section type `fullContent` (and there is no document when every
/// section is empty). Go puts the sections in a map and walks it in random
/// order; here the order is always headers, main, tables, footers. Every
/// document has a random UUID as its id and the [ParserOptions.extraMeta]
/// of the call in its metadata.
///
/// What is read is what docx2md's struct decoding reads: the runs that are
/// direct children of a paragraph (not those inside hyperlinks, insertions
/// or content controls), their `w:t` texts (not tabs or breaks), the cell
/// texts of a table's direct rows (`w:tc/w:p/w:r/w:t`, joined without a
/// separator). Paragraphs and tables are found anywhere in a part outside
/// another paragraph or table.
///
/// A file that is not a DOCX archive throws a [ThreepioException] `open Docx
/// document failed: <reason>` with docx2md's reasons (`zip: not a valid zip
/// file`, `word/document.xml not found in docx`, `failed to parse
/// document.xml: strconv.ParseInt: parsing "abc": invalid syntax`, ...);
/// bytes that cannot be read throw `docx parser failed to write to
/// temporary file: <error>` (Go copies them to a temporary file first; this
/// port reads them into memory). A cancellation or an interrupt raised by
/// the byte stream gets through as it is.
///
/// Where this differs from Go: a document without `word/styles.xml` is read
/// without styles (docx2md dereferences a nil style sheet and panics); XML
/// syntax errors carry `package:xml`'s message, not encoding/xml's; the
/// CRC-32 of the archive entries is not checked.
final class DocxParser implements Parser {
  /// A parser configured by [config].
  ///
  /// Port of eino-ext `docx.NewDocxParser`.
  const DocxParser([this.config = const DocxParserConfig()]);

  /// The configuration of this parser.
  final DocxParserConfig config;

  /// The section type of [doc] (see [docxMetaKeySectionType]), or `null`
  /// when it has none.
  ///
  /// Port of eino-ext `docx.GetSectionType`.
  static String? sectionTypeOf(Document? doc) {
    final type = doc?.metadata[docxMetaKeySectionType];
    return type is String ? type : null;
  }

  static const _uuid = Uuid();

  @override
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  }) async {
    final Uint8List data;
    try {
      data = await readAllBytes(bytes);
    } on Exception catch (error) {
      if (error is CancelledException || isInterrupt(error)) rethrow;
      // Go copies the input to a temporary file first; this is its message
      // for input that cannot be read.
      throw ThreepioException(
        'docx parser failed to write to temporary file: ${goErrorText(error)}',
        cause: error,
      );
    }

    final List<(String, String)> sections;
    try {
      sections = _DocxConverter(config).convert(data);
    } on Exception catch (error) {
      throw ThreepioException(
        'open Docx document failed: ${goErrorText(error)}',
        cause: error,
      );
    }

    final extraMeta = options?.extraMeta;
    if (config.toSections) {
      return [
        for (final (key, section) in sections)
          if (goTrimSpace(section) case final content when content.isNotEmpty)
            Document(
              id: _uuid.v4(),
              content: '=== ${_sectionTitle(key)} ===\n$content',
              metadata: {...?extraMeta, docxMetaKeySectionType: key},
            ),
      ];
    }

    final content = StringBuffer();
    for (final (key, section) in sections) {
      final trimmed = goTrimSpace(section);
      if (trimmed.isEmpty) continue;
      content
        ..write('=== ${_sectionTitle(key)} ===\n')
        ..write(trimmed)
        ..write('\n');
    }
    if (content.isEmpty) return const [];
    return [
      Document(
        id: _uuid.v4(),
        content: content.toString(),
        metadata: {...?extraMeta, docxMetaKeySectionType: 'fullContent'},
      ),
    ];
  }

  /// Port of eino-ext's `getSectionTitle`.
  static String _sectionTitle(String key) =>
      key == 'main' ? 'MAIN CONTENT' : key.toUpperCase();
}

// --- docx2md --------------------------------------------------------------

/// A failure of the conversion, with docx2md's message.
final class _DocxException implements Exception {
  const _DocxException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A paragraph (`w:p`): its runs, whether it is numbered (`w:numPr`), its
/// style (`w:pStyle`).
final class _Paragraph {
  _Paragraph(this.runs, {required this.numbered, required this.styleId});

  final List<_Run> runs;
  final bool numbered;
  final String styleId;
}

/// A run (`w:r`): its font size (`w:sz`, half-points) and texts (`w:t`).
final class _Run {
  _Run(this.fontSize, this.texts);

  int fontSize;
  final List<String> texts;
}

/// A table (`w:tbl`): the texts of each cell of each row.
final class _Table {
  const _Table(this.rows);

  final List<List<String>> rows;
}

/// The content of a part: paragraphs and tables, in document order. Each
/// item is a [_Paragraph] or a [_Table].
typedef _Body = List<Object>;

/// Port of docx2md's `DocxConvert` with `docx_parser.ReadDocx`.
final class _DocxConverter {
  const _DocxConverter(this.config);

  final DocxParserConfig config;

  static const _relationshipsNamespace =
      'http://schemas.openxmlformats.org/package/2006/relationships';

  /// The sections of the DOCX file in [data], in the fixed order headers,
  /// main, tables, footers, each only when the configuration asks for it
  /// (main always).
  List<(String, String)> convert(Uint8List data) {
    final entries = _readZip(data);

    ZipFileHeader? relsFile;
    ZipFileHeader? stylesFile;
    ZipFileHeader? docFile;
    final headerFiles = <ZipFileHeader>[];
    final footerFiles = <ZipFileHeader>[];
    for (final entry in entries) {
      final name = entry.filename;
      switch (name) {
        case 'word/_rels/document.xml.rels':
          if (relsFile != null) throw _duplicate(name);
          relsFile = entry;
        case 'word/styles.xml':
          if (stylesFile != null) throw _duplicate(name);
          stylesFile = entry;
        case 'word/document.xml':
          if (docFile != null) throw _duplicate(name);
          docFile = entry;
        default:
          if (name.startsWith('word/header') && name.endsWith('.xml')) {
            headerFiles.add(entry);
          } else if (name.startsWith('word/footer') && name.endsWith('.xml')) {
            footerFiles.add(entry);
          }
      }
    }
    if (docFile == null) {
      throw const _DocxException('word/document.xml not found in docx');
    }
    if (relsFile == null) {
      throw const _DocxException(
        'word/_rels/document.xml.rels not found in docx',
      );
    }

    // The relationships are only checked: docx2md decodes them but uses
    // them for images, which it does not extract.
    // encoding/xml fails with io.EOF on a part without any element.
    final rels = (_parseXml(relsFile) ?? (throw const _DocxException('EOF')))
        .rootElement;
    if (rels.name.local != 'Relationships') {
      throw _DocxException(
        'expected element type <Relationships> but have <${rels.name.local}>',
      );
    }
    final namespace = rels.name.namespaceUri ?? '';
    if (namespace != _relationshipsNamespace) {
      throw _DocxException(
        'expected element <Relationships> in name space '
        '$_relationshipsNamespace but have '
        '${namespace.isEmpty ? 'no name space' : namespace}',
      );
    }

    final styleSizes = stylesFile == null ? const <String, int>{} : _readStyles(stylesFile);

    final body = _parsePart(docFile, 'document.xml', styleSizes);
    final headers = [
      for (final file in headerFiles) _parsePart(file, file.filename, styleSizes),
    ];
    final footers = [
      for (final file in footerFiles) _parsePart(file, file.filename, styleSizes),
    ];

    final headerText = StringBuffer();
    final bodyText = StringBuffer();
    final tableText = StringBuffer();
    final footerText = StringBuffer();
    if (config.includeHeaders) {
      for (final header in headers) {
        for (final item in header) {
          _processContentItem(item, headerText, tableText);
        }
      }
    }
    for (final item in body) {
      _processContentItem(item, bodyText, tableText);
    }
    if (config.includeFooters) {
      for (final footer in footers) {
        for (final item in footer) {
          _processContentItem(item, footerText, tableText);
        }
      }
    }

    return [
      if (config.includeHeaders) ('headers', headerText.toString()),
      ('main', bodyText.toString()),
      if (config.includeTables) ('tables', tableText.toString()),
      if (config.includeFooters) ('footers', footerText.toString()),
    ];
  }

  static _DocxException _duplicate(String name) =>
      _DocxException('duplicate file found in docx archive: $name');

  /// The entries of the zip archive in [data], in the order of its central
  /// directory, duplicates included.
  static List<ZipFileHeader> _readZip(Uint8List data) {
    final decoder = ZipDecoder();
    try {
      decoder.decodeBytes(data);
      // Bytes that are not a zip archive fail in the decoder, with an
      // exception or an error (a range error on truncated data).
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      throw _ZipException(error);
    }
    // Without an end of central directory record the decoder returns an
    // empty archive; Go's zip reader rejects the bytes.
    if (decoder.directory.filePosition < 0) throw const _ZipException(null);
    return decoder.directory.fileHeaders;
  }

  /// The XML of [entry], or `null` when it has no element at all (only a
  /// declaration, comments or white space), which encoding/xml reads as
  /// `io.EOF`.
  static XmlDocument? _parseXml(ZipFileHeader entry) {
    final file = entry.file;
    if (file == null) throw _DocxException('cannot read ${entry.filename}');
    final Uint8List bytes;
    try {
      bytes = file.getStream().toUint8List();
      // A broken entry fails in the decompressor, with an exception or an
      // error (a range error on truncated data).
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      throw _DocxException('${entry.filename}: ${goErrorText(error)}');
    }
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);
    try {
      return XmlDocument.parse(text);
    } on XmlException catch (error) {
      if (_hasNoElement(text)) return null;
      throw _DocxException(error.message);
    }
  }

  /// Whether [text] reads as XML without any element.
  static bool _hasNoElement(String text) {
    try {
      for (final event in parseEvents(text)) {
        if (event is XmlStartElementEvent) return false;
      }
      return true;
    } on XmlException {
      return false;
    }
  }

  /// The font size of every style with an id (`w:style/@w:styleId` →
  /// `w:rPr/w:sz/@w:val`, 0 when the style has none). Port of `ReadStyle`
  /// and the map `stylizedBody` builds.
  static Map<String, int> _readStyles(ZipFileHeader entry) {
    final root =
        (_parseXml(entry) ?? (throw const _DocxException('EOF'))).rootElement;
    final sizes = <String, int>{};
    for (final style in _children(root, 'style')) {
      final id = _attr(style, 'styleId') ?? '';
      if (id.isEmpty) continue;
      sizes[id] = _fontSize(style);
    }
    return sizes;
  }

  /// The paragraphs and tables of a part, styled. Port of `parseContent`
  /// and `stylizedBody`.
  _Body _parsePart(
    ZipFileHeader entry,
    String name,
    Map<String, int> styleSizes,
  ) {
    try {
      // docx2md walks the tokens of a part: one without any element is an
      // empty part.
      final document = _parseXml(entry);
      return document == null ? <Object>[] : _parseBody(document, styleSizes);
    } on _DocxException catch (error) {
      throw _DocxException('failed to parse $name: ${error.message}');
    }
  }

  static _Body _parseBody(XmlDocument document, Map<String, int> styleSizes) {
    final body = <Object>[];
    // Every w:p and w:tbl outside another one, in document order, as Go's
    // token loop finds them.
    final pending = <XmlElement>[document.rootElement];
    while (pending.isNotEmpty) {
      final element = pending.removeLast();
      switch (element.name.local) {
        case 'p':
          body.add(_paragraph(element, styleSizes));
        case 'tbl':
          body.add(_table(element));
        default:
          pending.addAll(element.childElements.toList().reversed);
      }
    }
    return body;
  }

  static _Paragraph _paragraph(XmlElement p, Map<String, int> styleSizes) {
    final pPr = _children(p, 'pPr').toList();
    // Go decodes `pPr>numPr` into a *bool: the element makes it non-nil, and
    // the text directly inside it has to be a Go boolean (or nothing).
    var numbered = false;
    for (final e in pPr) {
      for (final numPr in _children(e, 'numPr')) {
        _goDecodeBool(_charData(numPr));
        numbered = true;
      }
    }
    var styleId = '';
    for (final e in pPr) {
      for (final style in _children(e, 'pStyle')) {
        styleId = _attr(style, 'val') ?? styleId;
      }
    }
    final runs = [
      for (final r in _children(p, 'r'))
        _Run(_fontSize(r), [for (final t in _children(r, 't')) _charData(t)]),
    ];
    if (styleId.isNotEmpty) {
      final size = styleSizes[styleId];
      if (size != null) {
        for (final run in runs) {
          run.fontSize = size;
        }
      }
    }
    return _Paragraph(runs, numbered: numbered, styleId: styleId);
  }

  static _Table _table(XmlElement tbl) => _Table([
        for (final tr in _children(tbl, 'tr'))
          [
            for (final tc in _children(tr, 'tc'))
              [
                for (final p in _children(tc, 'p'))
                  for (final r in _children(p, 'r'))
                    for (final t in _children(r, 't')) _charData(t),
              ].join(),
          ],
      ]);

  /// The `w:val` of `rPr/sz` under [element], 0 when there is none (or
  /// when it is empty). Go decodes it into an `int` and fails on anything
  /// else.
  static int _fontSize(XmlElement element) {
    var size = 0;
    for (final rPr in _children(element, 'rPr')) {
      for (final sz in _children(rPr, 'sz')) {
        final value = _attr(sz, 'val');
        if (value == null) continue;
        size = value.isEmpty ? 0 : _goParseInt(goTrimSpace(value));
      }
    }
    return size;
  }

  /// Go's `strconv.ParseInt(value, 10, 64)`, failing with its message.
  static int _goParseInt(String value) {
    final parsed = RegExp(r'^[+-]?[0-9]+$').hasMatch(value)
        ? int.tryParse(value, radix: 10)
        : null;
    if (parsed != null) return parsed;
    final reason = RegExp(r'^[+-]?[0-9]+$').hasMatch(value)
        ? 'value out of range'
        : 'invalid syntax';
    throw _DocxException(
      'strconv.ParseInt: parsing ${_goQuote(value)}: $reason',
    );
  }

  /// What encoding/xml does with the text of an element it decodes into a
  /// `bool`: nothing when the text is empty, otherwise Go's
  /// `strconv.ParseBool` of the trimmed text, failing with its message.
  static void _goDecodeBool(String text) {
    if (text.isEmpty) return;
    final trimmed = goTrimSpace(text);
    const accepted = {
      '1', 't', 'T', 'TRUE', 'true', 'True', //
      '0', 'f', 'F', 'FALSE', 'false', 'False',
    };
    if (accepted.contains(trimmed)) return;
    throw _DocxException(
      'strconv.ParseBool: parsing ${_goQuote(trimmed)}: invalid syntax',
    );
  }

  /// [value] quoted as Go's `strconv.Quote` quotes the text of an error:
  /// backslash escapes for quotes, backslashes and control characters.
  static String _goQuote(String value) {
    final out = StringBuffer('"');
    for (final rune in value.runes) {
      switch (rune) {
        case 0x22:
          out.write(r'\"');
        case 0x5C:
          out.write(r'\\');
        case 0x07:
          out.write(r'\a');
        case 0x08:
          out.write(r'\b');
        case 0x0C:
          out.write(r'\f');
        case 0x0A:
          out.write(r'\n');
        case 0x0D:
          out.write(r'\r');
        case 0x09:
          out.write(r'\t');
        case 0x0B:
          out.write(r'\v');
        default:
          if (rune < 0x20 || rune == 0x7F) {
            out.write('\\x${rune.toRadixString(16).padLeft(2, '0')}');
          } else {
            out.writeCharCode(rune);
          }
      }
    }
    out.write('"');
    return out.toString();
  }

  static Iterable<XmlElement> _children(XmlElement element, String local) =>
      element.childElements.where((child) => child.name.local == local);

  /// The value of the last attribute of [element] whose local name is
  /// [local], whatever its namespace, as Go matches attributes.
  static String? _attr(XmlElement element, String local) {
    String? value;
    for (final attribute in element.attributes) {
      if (attribute.name.local == local) value = attribute.value;
    }
    return value;
  }

  /// The character data directly inside [element] (Go: `,chardata`).
  static String _charData(XmlElement element) {
    final out = StringBuffer();
    for (final node in element.children) {
      if (node is XmlText) {
        out.write(node.value);
      } else if (node is XmlCDATA) {
        out.write(node.value);
      }
    }
    return out.toString();
  }

  /// Port of docx2md's `processContentItem`: a paragraph is written to
  /// [buffer], a table (when tables are included) to [tables]; either way
  /// [buffer] gets a newline.
  void _processContentItem(
    Object item,
    StringBuffer buffer,
    StringBuffer tables,
  ) {
    if (item is _Paragraph) {
      final text = StringBuffer();
      var fontSize = item.runs.isEmpty ? 0 : item.runs.first.fontSize;
      for (final run in item.runs) {
        if (run.fontSize < fontSize) fontSize = run.fontSize;
        run.texts.forEach(text.write);
      }
      buffer.write(_word2Heading(text.toString(), fontSize, item.numbered));
    } else if (item is _Table && config.includeTables) {
      tables
        ..write(_table2Markdown(item))
        ..write('\n');
    }
    buffer.write('\n');
  }
}

/// The error of a zip archive that cannot be read: Go's `zip.ErrFormat`.
final class _ZipException implements Exception {
  const _ZipException(this.cause);

  final Object? cause;

  @override
  String toString() => 'zip: not a valid zip file';
}

/// Port of docx2md's `word2Heading`. The length limits count UTF-8 bytes,
/// as Go's `len` does.
String _word2Heading(String raw, int fontSize, bool numbered) {
  final value = goTrimSpace(raw);
  if (value.isEmpty) return '\n';
  final length = utf8.encode(value).length;
  if (numbered || _checkString(value)) {
    if (fontSize >= 48) return '# $value';
    if (fontSize >= 36) return '## $value';
    if (fontSize >= 28) return '### $value';
    if (fontSize >= 24 && length < 45) return '#### $value';
    return value;
  }
  if (fontSize >= 48) return '# $value';
  if (fontSize >= 36) return '## $value';
  if (fontSize >= 28 && length < 15) return '### $value';
  return value;
}

/// The Chinese numerals one to ten.
const Set<int> _chineseNumerals = {
  0x4E00, 0x4E8C, 0x4E09, 0x56DB, 0x4E94, 0x516D, 0x4E03, 0x516B, 0x4E5D, //
  0x5341,
};

/// The character that starts an ordinal in Chinese ("第").
const int _di = 0x7B2C;

/// Port of docx2md's `CheckString`: the text starts with a digit, with "第"
/// and a digit, or contains a Chinese numeral anywhere (docx2md's
/// `startsWithChineseNumber` is not anchored).
bool _checkString(String value) {
  final first = value.codeUnitAt(0);
  if (first >= 0x30 && first <= 0x39) return true;
  if (first == _di && value.length > 1) {
    final second = value.codeUnitAt(1);
    if (second >= 0x30 && second <= 0x39) return true;
  }
  return value.runes.any(_chineseNumerals.contains);
}

/// Port of docx2md's `Table2markdown`: the first row is the header. The
/// spacing is docx2md's, uneven as it is (a cell narrower than its column is
/// padded to the column width, the widest cell gets one space).
String _table2Markdown(_Table table) {
  var tableWidth = 0;
  for (final row in table.rows) {
    if (row.length > tableWidth) tableWidth = row.length;
  }
  final align = List<int>.filled(tableWidth, 0);
  for (final row in table.rows) {
    for (final (j, cell) in row.indexed) {
      final width = goStringWidth(cell);
      if (align[j] < width) align[j] = width;
    }
  }

  final out = StringBuffer();
  void writeCells(List<String> row) {
    for (final (j, cell) in row.indexed) {
      out.write('| $cell');
      final diff = align[j] - goStringWidth(cell);
      out.write(diff > 0 ? ' ' * diff : ' ');
    }
    for (var j = row.length; j < tableWidth; j++) {
      out
        ..write('| ')
        ..write(' ' * align[j]);
    }
    out.write('|\n');
  }

  for (final (i, row) in table.rows.indexed) {
    writeCells(row);
    if (i == 0) {
      for (var j = 0; j < tableWidth; j++) {
        out.write('| ${'-' * align[j]} ');
      }
      out.write('|\n');
    }
  }
  return out.toString();
}
