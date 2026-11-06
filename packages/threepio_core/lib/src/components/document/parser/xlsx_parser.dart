/// eino-ext's XLSX parser: one document per row of a worksheet.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/parser_utils.dart';
import '../../../schema/document.dart';
import 'go_text.dart';
import 'parser.dart';

/// The metadata key of the row's values by column header (a
/// `Map<String, Object?>`, empty when the sheet has no header row).
///
/// Port of eino-ext `xlsx.MetaDataRow`.
const String xlsxMetaKeyRow = '_row';

/// The metadata key under which every document carries the
/// [ParserOptions.extraMeta] of the call (when the call has some).
///
/// Port of eino-ext `xlsx.MetaDataExt`.
const String xlsxMetaKeyExt = '_ext';

/// The configuration of [XlsxParser].
///
/// Port of eino-ext `xlsx.Config`.
@immutable
final class XlsxParserConfig {
  /// A configuration; every field has a default.
  const XlsxParserConfig({
    this.sheetName,
    this.noHeader = false,
    this.idPrefix,
  });

  /// The name of the worksheet to read, compared without regard to case.
  /// `null` or empty reads the first worksheet of the workbook.
  final String? sheetName;

  /// Whether the first row is data rather than the column headers (Go:
  /// `NoHeader`). With headers (the default) the first row is not a document
  /// and every document has its values by header under [xlsxMetaKeyRow].
  final bool noHeader;

  /// What the document ids start with (Go: `IDPrefix`): the id is the prefix
  /// and the row's index in the sheet. `null` or empty gives the bare index.
  final String? idPrefix;
}

/// Parses an Excel workbook (`.xlsx`): every non-empty row of one worksheet
/// becomes a document.
///
/// Port of eino-ext `parser/xlsx` (`xlsx.NewXlsxParser`,
/// `XlsxParser.Parse`), with what it uses of excelize v2.9.0 (`OpenReader`,
/// `GetSheetList`, `GetRows`) written on `package:archive` and
/// `package:xml`.
///
/// The content of a document is the row's cells, trimmed, joined by tabs.
/// Its id is the row's index among the rows of the sheet (counting the
/// header row and empty rows: the first data row under a header is `1`),
/// after [XlsxParserConfig.idPrefix]. Its metadata has the row's values by
/// header under [xlsxMetaKeyRow] (cells past the last header, and headers
/// past the last cell, are left out) and the [ParserOptions.extraMeta] of
/// the call under [xlsxMetaKeyExt].
///
/// The rows are read as excelize's `GetRows` reads them: cells by their
/// reference (`r="C2"`), missing cells as empty strings, trailing empty
/// cells and rows dropped; shared strings and inline strings (rich text
/// runs joined, `_xHHHH_` escapes decoded), booleans as `TRUE`/`FALSE`,
/// formula results as stored, numbers in their shortest form (more than 15
/// significant digits are rounded to 15), and numbers whose style has the
/// General format (number format 0) with more than 11 significant digits
/// in Go's `%.10G` form. Not covered: other number formats (excelize
/// applies built-in and custom formats such as dates, percentages and
/// thousands separators; here such cells keep the number as stored),
/// cells of type `d` (excelize turns the ISO 8601 date into a serial number;
/// here it stays as stored), hexadecimal floating-point literals, and
/// encrypted workbooks (rejected, as by excelize without a password).
///
/// A workbook without worksheets, or a sheet without rows, gives no
/// documents. A sheet that does not exist throws a [ThreepioException]
/// `sheet <name> does not exist`; bytes that are not a workbook throw a
/// [ThreepioFormatException] (`zip: not a valid zip file`, `unsupported
/// workbook file format`), as do a workbook, workbook relationships or
/// style sheet that do not decode (with encoding/xml's messages for a wrong
/// root element, `expected element <workbook> in name space ... but have
/// ...`, and for a number format id that is not a number); shared strings
/// that do not decode leave the sheet without rows, as in excelize. Errors
/// of the byte stream are rethrown as they are, as Go returns them.
///
/// Also different from excelize: rows are not read past Excel's last row
/// (1048576), where excelize would loop up to any row number; when two
/// sheets have names that differ only in case, the first in workbook order
/// is read (excelize picks one at random); the calculation chain and the
/// theme are not decoded (excelize fails on a broken one), and of the style
/// sheet only the number format ids of the cell styles are; the CRC-32 of
/// the archive entries is not checked; XML syntax errors carry
/// `package:xml`'s message.
final class XlsxParser implements Parser {
  /// A parser configured by [config].
  ///
  /// Port of eino-ext `xlsx.NewXlsxParser`.
  const XlsxParser([this.config = const XlsxParserConfig()]);

  /// The configuration of this parser.
  final XlsxParserConfig config;

  @override
  Future<List<Document>> parse(
    RunContext ctx,
    Stream<List<int>> bytes, {
    ParserOptions? options,
  }) async {
    final workbook = _Workbook.open(await readAllBytes(bytes));

    final sheets = workbook.sheetNames;
    if (sheets.isEmpty) return const [];
    final configured = config.sheetName;
    final sheetName =
        configured == null || configured.isEmpty ? sheets.first : configured;

    final rows = workbook.rows(sheetName);
    if (rows.isEmpty) return const [];

    var start = 0;
    var headers = const <String>[];
    if (!config.noHeader) {
      headers = rows.first;
      start = 1;
    }

    final extraMeta = options?.extraMeta;
    final docs = <Document>[];
    for (var i = start; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;
      final rowMeta = <String, Object?>{};
      if (!config.noHeader) {
        for (final (j, header) in headers.indexed) {
          if (j < row.length) rowMeta[header] = row[j];
        }
      }
      docs.add(
        Document(
          id: '${config.idPrefix ?? ''}$i',
          content: row.map(goTrimSpace).join('\t'),
          metadata: {
            xlsxMetaKeyRow: rowMeta,
            if (extraMeta != null) xlsxMetaKeyExt: extraMeta,
          },
        ),
      );
    }
    return docs;
  }
}

// --- excelize -------------------------------------------------------------

const _relationshipsNamespaces = {
  'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
  'http://purl.oclc.org/ooxml/officeDocument/relationships',
};

const _officeDocumentTypes = {
  'http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument',
  'http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument',
};

/// The first bytes of an OLE compound file: an encrypted workbook.
const _oleIdentifier = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

/// The largest value of a Go `uint` (64 bits).
final _maxUint64 = (BigInt.one << 64) - BigInt.one;

/// The texts Go's `strconv.ParseBool` accepts.
const _goBools = {
  '1', 't', 'T', 'TRUE', 'true', 'True', //
  '0', 'f', 'F', 'FALSE', 'false', 'False',
};

/// Excel's last row (excelize `TotalRows`).
const _totalRows = 1048576;

/// Excel's last column (excelize `MaxColumns`).
const _maxColumns = 16384;

/// A workbook opened as excelize's `OpenReader` opens it.
final class _Workbook {
  _Workbook._(this._files, this.sheetNames, this._sheetPaths, this._numFmts);

  /// Port of excelize `OpenReader` and what it reads up front (the sheet
  /// map, the styles).
  factory _Workbook.open(Uint8List data) {
    if (_contains(data, _oleIdentifier)) {
      throw const ThreepioFormatException('unsupported workbook file format');
    }
    final files = _readZip(data);

    var workbookPath = '';
    List<_Relationship> rootRels;
    try {
      rootRels = _relationships(files, '_rels/.rels');
    } on ThreepioFormatException {
      // excelize's getWorkbookPath ignores the error: no workbook path.
      rootRels = const [];
    }
    for (final rel in rootRels) {
      if (_officeDocumentTypes.contains(rel.type)) {
        workbookPath = _trimLeadingSlash(rel.target);
        break;
      }
    }

    final sheetNames = <String>[];
    final sheetPaths = <String, String>{};
    final workbook = _parseXml(files, workbookPath);
    if (workbook != null) {
      final root = _expectRoot(workbook, 'workbook', _spreadsheetNamespaces);
      final rels = _relationships(files, _workbookRelsPath(workbookPath));
      for (final sheets in _children(root, 'sheets')) {
        for (final sheet in _children(sheets, 'sheet')) {
          final name = _attr(sheet, 'name') ?? '';
          sheetNames.add(name);
          final id = _relationshipId(sheet);
          for (final rel in rels) {
            if (rel.id != id) continue;
            final path = _worksheetPath(workbookPath, rel.target);
            if (files.containsKey(path)) sheetPaths[name] = path;
          }
        }
      }
    }

    final numFmts = <int>[];
    final styles = _parseXml(files, 'xl/styles.xml');
    if (styles != null) {
      final root = _expectRoot(styles, 'styleSheet', _spreadsheetNamespaces);
      for (final cellXfs in _children(root, 'cellXfs')) {
        for (final xf in _children(cellXfs, 'xf')) {
          final id = _attr(xf, 'numFmtId');
          numFmts.add(
            id == null || id.isEmpty ? 0 : _goParseInt(goTrimSpace(id)),
          );
        }
      }
    }
    return _Workbook._(files, sheetNames, sheetPaths, numFmts);
  }

  final Map<String, ZipFile> _files;

  /// The names of the worksheets, in workbook order (excelize
  /// `GetSheetList`).
  final List<String> sheetNames;

  final Map<String, String> _sheetPaths;

  /// The number format of every cell style (`cellXfs`), by style index.
  final List<int> _numFmts;

  List<String>? _sharedStrings;

  /// The rows of [sheet], as excelize's `GetRows` returns them.
  List<List<String>> rows(String sheet) {
    _checkSheetName(sheet);
    String? path;
    for (final name in sheetNames) {
      if (name.toLowerCase() == sheet.toLowerCase() &&
          _sheetPaths.containsKey(name)) {
        path = _sheetPaths[name];
        break;
      }
    }
    if (path == null) throw ThreepioException('sheet $sheet does not exist');
    final bytes = _bytesOf(_files[path]!);
    return _RowReader(this, _decode(bytes)).readAll();
  }

  /// The shared strings, or `null` when `xl/sharedStrings.xml` cannot be
  /// read (excelize's `GetRows` then stops at its first row).
  List<String>? get sharedStrings {
    final cached = _sharedStrings;
    if (cached != null) return cached;
    final XmlDocument? document;
    try {
      document = _parseXml(_files, 'xl/sharedStrings.xml');
    } on ThreepioFormatException {
      return null;
    }
    final XmlElement? root;
    try {
      root = document == null
          ? null
          : _expectRoot(document, 'sst', _spreadsheetNamespaces);
    } on ThreepioFormatException {
      return null;
    }
    final strings = <String>[
      if (root != null)
        for (final si in _children(root, 'si')) _stringItem(si),
    ];
    return _sharedStrings = strings;
  }

  /// The value of a cell (excelize `xlsxC.getValueFrom` without raw values).
  String valueOf(_Cell cell) {
    switch (cell.type) {
      case 'b':
        if (cell.value == '1') return 'TRUE';
        if (cell.value == '0') return 'FALSE';
        return cell.value;
      case 's':
        if (cell.value.isEmpty) return '';
        final index = _atoi(goTrimSpace(cell.value)) ?? 0;
        final strings = sharedStrings ?? const [];
        if (index >= 0 && index < strings.length) return strings[index];
        return cell.value;
      case 'str':
        return cell.value;
      case 'inlineStr':
        return cell.inlineString ?? cell.value;
      case 'd':
        // excelize converts the ISO 8601 date to a serial number and formats
        // it; not ported.
        return cell.value;
      default:
        var value = cell.value;
        final number = _parseNumber(value);
        if (number != null) {
          value = _precision(number) > 15
              ? _formatG(number, 15)
              : _formatShortest(number);
        }
        return _formatGeneral(value, cell.style);
    }
  }

  /// excelize's `formattedValue` for a number: the General format shows a
  /// number of more than 11 significant digits as `%.10G`. Other formats
  /// are not applied.
  String _formatGeneral(String value, int style) {
    if (style <= 0 || style >= _numFmts.length || _numFmts[style] != 0) {
      return value;
    }
    final number = _parseNumber(value);
    if (number == null || _precision(number) <= 11) return value;
    return _formatG(number, 10);
  }
}

/// The relationships of a `.rels` part.
typedef _Relationship = ({String id, String type, String target});

List<_Relationship> _relationships(Map<String, ZipFile> files, String path) {
  final document = _parseXml(files, path);
  if (document == null) return const [];
  final root = _expectRoot(document, 'Relationships', const {
    _packageRelationshipsNamespace,
  });
  return [
    for (final rel in _children(root, 'Relationship'))
      (
        id: _attr(rel, 'Id') ?? '',
        type: _attr(rel, 'Type') ?? '',
        target: _attr(rel, 'Target') ?? '',
      ),
  ];
}

const _packageRelationshipsNamespace =
    'http://schemas.openxmlformats.org/package/2006/relationships';

/// The SpreadsheetML namespace, transitional first (the one Go names in its
/// errors) and strict (which excelize rewrites to the transitional one).
const _spreadsheetNamespaces = {
  'http://schemas.openxmlformats.org/spreadsheetml/2006/main',
  'http://purl.oclc.org/ooxml/spreadsheetml/main',
};

/// The root element of [document], after the check encoding/xml makes of
/// the `XMLName` of the struct excelize decodes it into: its local name has
/// to be [local] and its namespace one of [namespaces] (the first is the
/// one in the message).
XmlElement _expectRoot(
  XmlDocument document,
  String local,
  Set<String> namespaces,
) {
  final root = document.rootElement;
  if (root.name.local != local) {
    throw ThreepioFormatException(
      'expected element type <$local> but have <${root.name.local}>',
    );
  }
  final namespace = root.name.namespaceUri ?? '';
  if (!namespaces.contains(namespace)) {
    throw ThreepioFormatException(
      'expected element <$local> in name space ${namespaces.first} but have '
      '${namespace.isEmpty ? 'no name space' : namespace}',
    );
  }
  return root;
}

/// Go's `strconv.ParseInt(value, 10, 64)` as encoding/xml runs it on an
/// `int` attribute, failing with its message.
int _goParseInt(String value) {
  final syntax = RegExp(r'^[+-]?[0-9]+$').hasMatch(value);
  final parsed = syntax ? int.tryParse(value, radix: 10) : null;
  if (parsed != null) return parsed;
  throw ThreepioFormatException(
    'strconv.ParseInt: parsing "$value": '
    '${syntax ? 'value out of range' : 'invalid syntax'}',
  );
}

/// The `r:id` of a `sheet` element.
String _relationshipId(XmlElement sheet) {
  for (final attribute in sheet.attributes) {
    if (attribute.name.local == 'id' &&
        _relationshipsNamespaces.contains(attribute.name.namespaceUri)) {
      return attribute.value;
    }
  }
  return '';
}

/// Port of excelize `getWorkbookRelsPath`.
String _workbookRelsPath(String workbookPath) {
  final dir = p.posix.dirname(workbookPath);
  final base = workbookPath.isEmpty ? '.' : p.posix.basename(workbookPath);
  if (dir == '.') return '_rels/$base.rels';
  return _trimLeadingSlash('$dir/_rels/$base.rels');
}

/// Port of excelize `getWorksheetPath`.
String _worksheetPath(String workbookPath, String target) {
  final normalized = target.replaceAll(r'\', '/');
  if (normalized.startsWith('/')) {
    return _trimLeadingSlash(p.posix.normalize(normalized));
  }
  return _trimLeadingSlash(
    p.posix.normalize('${p.posix.dirname(workbookPath)}/$normalized'),
  );
}

String _trimLeadingSlash(String path) =>
    path.startsWith('/') ? path.substring(1) : path;

/// The checks of excelize `checkSheetName`, with its messages.
void _checkSheetName(String name) {
  final String? problem;
  if (name.isEmpty) {
    problem = 'the sheet name can not be blank';
  } else if (name.runes.length > 31) {
    problem = 'the sheet name length exceeds the 31 characters limit';
  } else if (name.startsWith("'") || name.endsWith("'")) {
    problem =
        'the first or last character of the sheet name can not be a single quote';
  } else if (name.contains(RegExp(r'[:\\/?*\[\]]'))) {
    problem = r'the sheet can not contain any of the characters :\/?*[or]';
  } else {
    problem = null;
  }
  if (problem != null) throw ThreepioException(problem);
}

/// The files of the zip archive in [data] by name, as excelize's
/// `ReadZipReader` keeps them: backslashes as slashes, the shared strings
/// and content types under their canonical names whatever their case, and a
/// later entry of the same name replacing an earlier one.
Map<String, ZipFile> _readZip(Uint8List data) {
  final decoder = ZipDecoder();
  try {
    decoder.decodeBytes(data);
    // Bytes that are not a zip archive fail in the decoder, with an
    // exception or an error (a range error on truncated data).
    // ignore: avoid_catches_without_on_clauses
  } catch (error) {
    throw ThreepioFormatException('zip: not a valid zip file', cause: error);
  }
  // Without an end of central directory record the decoder returns an empty
  // archive; Go's zip reader rejects the bytes.
  if (decoder.directory.filePosition < 0) {
    throw const ThreepioFormatException('zip: not a valid zip file');
  }
  final files = <String, ZipFile>{};
  for (final header in decoder.directory.fileHeaders) {
    final file = header.file;
    if (file == null) continue;
    var name = header.filename.replaceAll(r'\', '/');
    switch (name.toLowerCase()) {
      case '[content_types].xml':
        name = '[Content_Types].xml';
      case 'xl/sharedstrings.xml':
        name = 'xl/sharedStrings.xml';
    }
    files[name] = file;
  }
  return files;
}

Uint8List _bytesOf(ZipFile file) {
  try {
    return file.getStream().toUint8List();
    // A broken entry fails in the decompressor, with an exception or an
    // error (a range error on truncated data).
    // ignore: avoid_catches_without_on_clauses
  } catch (error) {
    throw ThreepioFormatException(
      'cannot read ${file.filename}: ${goErrorText(error)}',
      cause: error,
    );
  }
}

String _decode(Uint8List bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  return text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF
      ? text.substring(1)
      : text;
}

/// The part at [path] as XML, or `null` when the archive has no such part
/// or the part has no element (excelize reads a missing part as empty, and
/// ignores the `io.EOF` encoding/xml reports for a part with nothing but a
/// declaration, comments or white space).
XmlDocument? _parseXml(Map<String, ZipFile> files, String path) {
  final file = files[path];
  if (file == null) return null;
  final text = _decode(_bytesOf(file));
  if (text.trim().isEmpty) return null;
  try {
    return XmlDocument.parse(text);
  } on XmlException catch (error) {
    if (_hasNoElement(text)) return null;
    throw ThreepioFormatException(
      'XML syntax error in $path: ${error.message}',
      cause: error,
    );
  }
}

/// Whether [text] reads as XML without any element: what encoding/xml
/// reports as `io.EOF` when it decodes a struct from it.
bool _hasNoElement(String text) {
  try {
    for (final event in parseEvents(text)) {
      if (event is XmlStartElementEvent) return false;
    }
    return true;
  } on XmlException {
    return false;
  }
}

Iterable<XmlElement> _children(XmlElement element, String local) =>
    element.childElements.where((child) => child.name.local == local);

/// The value of the last attribute of [element] whose local name is
/// [local], as Go matches attributes.
String? _attr(XmlElement element, String local) {
  String? value;
  for (final attribute in element.attributes) {
    if (attribute.name.local == local) value = attribute.value;
  }
  return value;
}

/// The text of a string item (`si` or `is`): its `t` and the `t` of its
/// rich text runs, with the `_xHHHH_` escapes decoded. Port of excelize
/// `xlsxSI.String`.
String _stringItem(XmlElement item) => _stringItemText(
      _textOf(_children(item, 't').lastOrNull),
      [
        for (final r in _children(item, 'r'))
          _textOf(_children(r, 't').lastOrNull),
      ],
    );

/// The text of a string item from the text of its `t` and the texts of its
/// runs.
String _stringItemText(String? text, List<String?> runs) {
  final out = StringBuffer(text ?? '');
  for (final run in runs) {
    if (run != null) out.write(run);
  }
  return out.isEmpty ? '' : _bstrUnmarshal(out.toString());
}

String? _textOf(XmlElement? element) =>
    element == null ? null : _charData(element);

String _charData(XmlElement element) {
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

final _bstrPattern = RegExp('_x[a-fA-F0-9]{4}_');

/// Port of excelize `bstrUnmarshal`: `_xHHHH_` is the character U+HHHH,
/// `_x005F_` an underscore (which escapes a literal `_xHHHH_`).
String _bstrUnmarshal(String value) {
  final out = StringBuffer();
  var cursor = 0;
  for (final match in _bstrPattern.allMatches(value)) {
    out.write(value.substring(cursor, match.start));
    cursor = match.end;
    final code = int.parse(value.substring(match.start + 2, match.end - 1), radix: 16);
    // Go's strconv.Unquote rejects a surrogate half: the escape is dropped.
    if (code < 0xD800 || code > 0xDFFF) out.writeCharCode(code);
  }
  out.write(value.substring(cursor));
  return out.toString();
}

bool _contains(Uint8List data, List<int> pattern) {
  outer:
  for (var i = 0; i + pattern.length <= data.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Go's `strconv.Atoi`, or `null` when it fails.
int? _atoi(String value) =>
    RegExp(r'^[+-]?[0-9]+$').hasMatch(value) ? int.tryParse(value, radix: 10) : null;

// --- Reading the rows -------------------------------------------------------

/// A cell (`c`): its reference, style, type, value, inline string, and
/// whether it has a formula.
final class _Cell {
  _Cell({
    required this.ref,
    required this.style,
    required this.type,
    required this.value,
    required this.inlineString,
    required this.hasFormula,
  });

  final String ref;
  final int style;
  final String type;
  final String value;
  final String? inlineString;
  final bool hasFormula;
}

/// Port of excelize's `GetRows` with the `Rows` iterator (`Next`,
/// `Columns`, `rowXMLHandler`) it runs on, over the events of a worksheet.
final class _RowReader {
  _RowReader(this._workbook, String xml) : _events = parseEvents(xml).iterator;

  final _Workbook _workbook;
  final Iterator<XmlEvent> _events;
  bool _ended = false;

  // The state of excelize's Rows.
  int _curRow = 0;
  int _seekRow = 0;
  XmlStartElementEvent? _token;

  /// The next event, or `null` at the end of the sheet or at the first
  /// event that cannot be parsed (excelize stops at a decoder error too).
  XmlEvent? _nextEvent() {
    if (_ended) return null;
    try {
      if (_events.moveNext()) return _events.current;
    } on XmlException {
      // As excelize: a token that cannot be read ends the sheet.
    }
    _ended = true;
    return null;
  }

  List<List<String>> readAll() {
    final results = <List<String>>[];
    var cur = 0;
    var maxVal = 0;
    while (_next()) {
      cur++;
      final row = _columns();
      if (row == null) break;
      if (row.isNotEmpty) {
        final emptyRows = cur - maxVal - 1;
        if (emptyRows > 0) results.addAll(List.filled(emptyRows, const []));
        results.add(row);
        maxVal = cur;
      }
    }
    return results;
  }

  /// excelize `Rows.Next`.
  bool _next() {
    _seekRow++;
    if (_curRow >= _seekRow) return true;
    while (true) {
      final event = _nextEvent();
      if (event == null) return false;
      if (event is XmlStartElementEvent && event.localName == 'row') {
        _curRow++;
        final rowNum = _rowNumber(event) ?? 0;
        if (rowNum != 0) _curRow = rowNum;
        // Not in excelize, which would walk up to any row number: a row past
        // Excel's last one ends the sheet.
        if (_curRow > _totalRows) return false;
        _token = event;
        return true;
      }
      if (event is XmlEndElementEvent && event.localName == 'sheetData') {
        return false;
      }
    }
  }

  /// excelize `Rows.Columns`: the cells of the current row, or `null` when
  /// excelize returns an error (which makes `GetRows` stop).
  List<String>? _columns() {
    if (_curRow > _seekRow) return const [];
    // excelize reads the shared strings here; failing to fails the row.
    if (_workbook.sharedStrings == null) return null;
    final cells = <String>[];
    var cellCol = 0;
    while (true) {
      final XmlEvent event;
      final pending = _token;
      if (pending != null) {
        event = pending;
      } else {
        final next = _nextEvent();
        if (next == null) break;
        event = next;
      }
      if (event is XmlStartElementEvent) {
        final local = event.localName;
        if (local == 'row') {
          final rowNum = _rowNumber(event);
          if (rowNum != null && rowNum > _totalRows) {
            // Not in excelize: a row past Excel's last one ends the sheet.
            _ended = true;
            _token = null;
            return cells;
          }
          if (rowNum != null && rowNum != 0) {
            _curRow = rowNum;
          } else if (_token == null) {
            _curRow++;
          }
          _token = event;
          if (_curRow > _seekRow || rowNum == null) {
            _token = null;
            return rowNum == null ? null : cells;
          }
        } else if (local == 'c') {
          final cell = _readCell(event);
          cellCol++;
          if (cell.ref.isNotEmpty) {
            final column = _columnOf(cell.ref);
            if (column == null) {
              _token = null;
              return null;
            }
            cellCol = column;
          }
          final blank = cellCol - cells.length;
          final value = _workbook.valueOf(cell);
          if (value.isNotEmpty || cell.hasFormula) {
            for (var i = 1; i < blank; i++) {
              cells.add('');
            }
            cells.add(value);
          }
        }
        _token = null;
      } else if (event is XmlEndElementEvent && event.localName == 'sheetData') {
        return cells;
      }
    }
    return cells;
  }

  /// The `r` of a row: 0 when it has none, `null` when it is not a number
  /// (excelize's `attrValToInt` error).
  static int? _rowNumber(XmlStartElementEvent row) {
    String? value;
    for (final attribute in row.attributes) {
      if (attribute.localName == 'r') value = attribute.value;
    }
    return value == null ? 0 : _atoi(value);
  }

  /// The column of a cell reference (`C2` is 3), or `null` when it is not
  /// one. Port of excelize `CellNameToCoordinates`.
  static int? _columnOf(String ref) {
    bool isAlpha(int c) =>
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x24;
    if (ref.isEmpty || !isAlpha(ref.codeUnitAt(0))) return null;
    var last = 0;
    for (var i = 0; i < ref.length; i++) {
      if (isAlpha(ref.codeUnitAt(i))) last = i;
    }
    if (last >= ref.length - 1) return null;
    final row = _atoi(ref.substring(last + 1));
    if (row == null || row <= 0 || row > _totalRows) return null;
    final name = ref.substring(0, last + 1).replaceAll(r'$', '');
    if (name.isEmpty) return null;
    var column = 0;
    var multi = 1;
    for (var i = name.length - 1; i >= 0; i--) {
      final c = name.codeUnitAt(i);
      if (c >= 0x41 && c <= 0x5A) {
        column += (c - 0x41 + 1) * multi;
      } else if (c >= 0x61 && c <= 0x7A) {
        column += (c - 0x61 + 1) * multi;
      } else {
        return null;
      }
      multi *= 26;
      if (column > _maxColumns) return null;
    }
    return column;
  }

  /// Reads the cell that [start] opens, up to its end: its attributes, its
  /// value (`v`), its formula (`f`, only whether there is one) and its
  /// inline string (`is`). Port of the decoding of excelize's `xlsxC`.
  _Cell _readCell(XmlStartElementEvent start) {
    var ref = '';
    var style = 0;
    var type = '';
    // encoding/xml decodes the attributes in their order and gives up at the
    // first that does not parse (`s` is an int, `cm` and `vm` uints, `ph` a
    // bool), before the children: what it stored up to there is kept.
    var failed = false;
    for (final attribute in start.attributes) {
      final value = attribute.value;
      final trimmed = goTrimSpace(value);
      switch (attribute.localName) {
        case 'r':
          ref = value;
        case 's':
          final parsed = value.isEmpty
              ? 0
              : (RegExp(r'^[+-]?[0-9]+$').hasMatch(trimmed)
                  ? int.tryParse(trimmed, radix: 10)
                  : null);
          if (parsed == null) {
            failed = true;
          } else {
            style = parsed;
          }
        case 't':
          type = value;
        case 'cm' || 'vm':
          if (value.isNotEmpty &&
              (!RegExp(r'^[0-9]+$').hasMatch(trimmed) ||
                  BigInt.parse(trimmed) > _maxUint64)) {
            failed = true;
          }
        case 'ph':
          if (value.isNotEmpty && !_goBools.contains(trimmed)) failed = true;
      }
      if (failed) break;
    }
    final cell = _MiniElement('c');
    final complete = start.isSelfClosing || _readChildren(cell);
    if (failed || !complete) {
      // Nothing of the children is stored; a sheet that breaks off inside
      // the cell fails Go's decoder before it stores anything of it either.
      return _Cell(
        ref: ref,
        style: style,
        type: type,
        value: '',
        inlineString: null,
        hasFormula: false,
      );
    }
    final inline = cell.lastChild('is');
    return _Cell(
      ref: ref,
      style: style,
      type: type,
      value: cell.lastChild('v')?.text.toString() ?? '',
      inlineString: inline == null
          ? null
          : _stringItemText(
              inline.lastChild('t')?.text.toString(),
              [
                for (final run in inline.children)
                  if (run.local == 'r') run.lastChild('t')?.text.toString(),
              ],
            ),
      hasFormula: cell.lastChild('f') != null,
    );
  }

  /// Reads the events up to the end of [parent] into a small tree; `false`
  /// when the sheet ends first.
  bool _readChildren(_MiniElement parent) {
    final stack = [parent];
    while (stack.isNotEmpty) {
      final event = _nextEvent();
      if (event == null) return false;
      if (event is XmlStartElementEvent) {
        final child = _MiniElement(event.localName);
        stack.last.children.add(child);
        if (!event.isSelfClosing) stack.add(child);
      } else if (event is XmlEndElementEvent) {
        stack.removeLast();
      } else if (event is XmlTextEvent) {
        stack.last.text.write(event.value);
      } else if (event is XmlCDATAEvent) {
        stack.last.text.write(event.value);
      }
    }
    return true;
  }
}

/// An element of a cell: its local name, its child elements and the text
/// directly inside it.
final class _MiniElement {
  _MiniElement(this.local);

  final String local;
  final List<_MiniElement> children = [];
  final StringBuffer text = StringBuffer();

  _MiniElement? lastChild(String name) =>
      children.lastWhereOrNull((child) => child.local == name);
}

// --- Go's number formatting ------------------------------------------------

// Written so that Dart's backtracking matcher fails in linear time on a
// long run of digits that is not a number (`[0-9]+\.?[0-9]*` would be
// quadratic).
final _decimalPattern =
    RegExp(r'^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$');
final _infinityPattern = RegExp(r'^([+-]?)(?:inf|Inf)$');
final _prefixedPattern = RegExp(r'^([+-]?)0([xXbBoO])([0-9a-fA-F]+)$');

/// The number [value] is, as excelize's `isNumeric` reads it with Go's
/// `big.Float.SetString`, or `null`. Decimal and scientific notation,
/// `inf`, and integers with a `0x`, `0b` or `0o` prefix are numbers;
/// hexadecimal floating-point literals are not recognized here.
double? _parseNumber(String value) {
  if (value.isEmpty || value.contains('_')) return null;
  if (_decimalPattern.hasMatch(value)) return double.parse(value);
  final infinity = _infinityPattern.firstMatch(value);
  if (infinity != null) {
    return infinity.group(1) == '-' ? double.negativeInfinity : double.infinity;
  }
  final prefixed = _prefixedPattern.firstMatch(value);
  if (prefixed != null) {
    final radix = switch (prefixed.group(2)!.toLowerCase()) {
      'x' => 16,
      'b' => 2,
      _ => 8,
    };
    final magnitude = BigInt.tryParse(prefixed.group(3)!, radix: radix);
    if (magnitude == null) return null;
    final number = magnitude.toDouble();
    return prefixed.group(1) == '-' ? -number : number;
  }
  return null;
}

/// excelize's precision of a number: the length of Go's
/// `FormatFloat(x, 'f', -1, 64)` without its decimal point.
int _precision(double number) =>
    _formatShortest(number).replaceAll('.', '').length;

/// The shortest decimal digits of the finite, non-negative [x] that read
/// back as [x], and the position of the decimal point among them.
(String, int) _shortestDigits(double x) {
  if (x == 0) return ('', 0);
  return _digitsOf(x.toStringAsExponential());
}

/// The digits (without trailing zeros) and decimal point position of a
/// number Dart wrote in exponential notation (`1.25e+3`).
(String, int) _digitsOf(String exponential) {
  final e = exponential.indexOf('e');
  var digits = exponential.substring(0, e).replaceAll('.', '');
  final exponent = int.parse(exponential.substring(e + 1));
  var end = digits.length;
  while (end > 0 && digits.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  digits = digits.substring(0, end);
  return digits.isEmpty ? ('', 0) : (digits, exponent + 1);
}

/// Go's `strconv.FormatFloat(x, 'f', -1, 64)`.
String _formatShortest(double x) {
  if (x.isNaN) return 'NaN';
  if (x.isInfinite) return x > 0 ? '+Inf' : '-Inf';
  final (digits, dp) = _shortestDigits(x.abs());
  final precision = digits.length - dp > 0 ? digits.length - dp : 0;
  return _fmtF(x.isNegative, digits, dp, precision);
}

/// Go's `strconv.FormatFloat(x, 'G', precision, 64)`.
String _formatG(double x, int precision) {
  if (x.isNaN) return 'NaN';
  if (x.isInfinite) return x > 0 ? '+Inf' : '-Inf';
  final neg = x.isNegative;
  final (digits, dp) = x == 0
      ? ('', 0)
      : _roundDigits(_exactDigits(x.abs()), precision);
  final nd = digits.length;
  var eprec = precision;
  if (eprec > nd && nd >= dp) eprec = nd;
  final exp = dp - 1;
  if (exp < -4 || exp >= eprec) {
    final prec = precision > nd ? nd : precision;
    return _fmtE(neg, digits, dp, prec - 1);
  }
  final prec = precision > dp ? nd : precision;
  return _fmtF(neg, digits, dp, prec - dp > 0 ? prec - dp : 0);
}

/// The exact decimal digits of the finite, positive [x] (without trailing
/// zeros) and the position of the decimal point among them: Go's
/// `decimal.Assign` of the binary value, written with BigInt arithmetic.
(String, int) _exactDigits(double x) {
  final bits = ByteData(8)..setFloat64(0, x);
  final high = bits.getUint32(0);
  final low = bits.getUint32(4);
  final biasedExponent = (high >> 20) & 0x7FF;
  var mantissa = (BigInt.from(high & 0xFFFFF) << 32) | BigInt.from(low);
  final int exponent;
  if (biasedExponent == 0) {
    exponent = -1074; // subnormal
  } else {
    mantissa |= BigInt.one << 52;
    exponent = biasedExponent - 1075;
  }
  var digits = exponent >= 0
      ? (mantissa << exponent).toString()
      : (mantissa * BigInt.from(5).pow(-exponent)).toString();
  final dp = exponent >= 0 ? digits.length : digits.length + exponent;
  var end = digits.length;
  while (end > 0 && digits.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  digits = digits.substring(0, end);
  return (digits, dp);
}

/// [exact] (digits and decimal point position) rounded to [nd] significant
/// digits the way Go rounds: half to even on the exact value (Go's
/// `decimal.Round` with `shouldRoundUp`), trailing zeros dropped.
(String, int) _roundDigits((String, int) exact, int nd) {
  final (digits, dp) = exact;
  if (nd < 0 || nd >= digits.length) return exact;
  final next = digits.codeUnitAt(nd);
  final bool up;
  if (next == 0x35 && nd + 1 == digits.length) {
    // Exactly halfway: round to even.
    up = nd > 0 && (digits.codeUnitAt(nd - 1) - 0x30).isOdd;
  } else {
    up = next >= 0x35;
  }
  if (up) {
    for (var i = nd - 1; i >= 0; i--) {
      final c = digits.codeUnitAt(i);
      if (c < 0x39) {
        return ('${digits.substring(0, i)}${String.fromCharCode(c + 1)}', dp);
      }
    }
    return ('1', dp + 1); // all nines
  }
  var end = nd;
  while (end > 0 && digits.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  return (digits.substring(0, end), dp);
}

/// Go's `fmtF`: [digits] with the decimal point after [dp] of them and
/// [precision] digits after it.
String _fmtF(bool neg, String digits, int dp, int precision) {
  final out = StringBuffer(neg ? '-' : '');
  if (dp > 0) {
    final m = dp < digits.length ? dp : digits.length;
    out.write(digits.substring(0, m));
    for (var i = m; i < dp; i++) {
      out.write('0');
    }
  } else {
    out.write('0');
  }
  if (precision > 0) {
    out.write('.');
    for (var i = 0; i < precision; i++) {
      final j = dp + i;
      out.write(j >= 0 && j < digits.length ? digits[j] : '0');
    }
  }
  return out.toString();
}

/// Go's `fmtE` with `E`: one digit, [precision] more after the point, and
/// an exponent of at least two digits.
String _fmtE(bool neg, String digits, int dp, int precision) {
  final out = StringBuffer(neg ? '-' : '')
    ..write(digits.isEmpty ? '0' : digits[0]);
  if (precision > 0) {
    out.write('.');
    var i = 1;
    final m = digits.length < precision + 1 ? digits.length : precision + 1;
    if (i < m) {
      out.write(digits.substring(i, m));
      i = m;
    }
    for (; i <= precision; i++) {
      out.write('0');
    }
  }
  var exp = digits.isEmpty ? 0 : dp - 1;
  out.write(exp < 0 ? 'E-' : 'E+');
  if (exp < 0) exp = -exp;
  out.write(exp < 10 ? '0$exp' : '$exp');
  return out.toString();
}
