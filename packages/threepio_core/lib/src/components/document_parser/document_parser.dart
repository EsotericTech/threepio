import 'dart:typed_data';

import '../../schema/document.dart';

/// Options for document parsing operations.
class DocumentParserOptions {
  /// Creates parser options.
  const DocumentParserOptions({
    this.encoding = 'utf-8',
    this.extractImages = false,
    this.extractTables = false,
    this.preserveFormatting = true,
    this.metadata,
    this.extra,
  });

  /// Text encoding for the document.
  final String encoding;

  /// Whether to extract images from the document.
  final bool extractImages;

  /// Whether to extract tables from the document.
  final bool extractTables;

  /// Whether to preserve formatting information.
  final bool preserveFormatting;

  /// Additional metadata to include in parsed documents.
  final Map<String, dynamic>? metadata;

  /// Parser-specific options.
  final Map<String, dynamic>? extra;
}

/// Result of parsing a document.
class ParseResult {
  /// Creates a parse result.
  const ParseResult({
    required this.documents,
    this.metadata,
    this.warnings,
    this.extractedImages,
    this.extractedTables,
  });

  /// Parsed documents (may be multiple for multi-page documents).
  final List<Document> documents;

  /// Metadata about the parsing operation.
  final Map<String, dynamic>? metadata;

  /// Any warnings generated during parsing.
  final List<String>? warnings;

  /// Extracted images (if requested).
  final List<ExtractedImage>? extractedImages;

  /// Extracted tables (if requested).
  final List<ExtractedTable>? extractedTables;

  /// Get a single document (for simple parsers that return one document).
  Document get document {
    if (documents.isEmpty) {
      throw StateError('No documents in parse result');
    }
    return documents.first;
  }

  /// Whether parsing produced any warnings.
  bool get hasWarnings => warnings != null && warnings!.isNotEmpty;
}

/// An image extracted from a document.
class ExtractedImage {
  /// Creates an extracted image.
  const ExtractedImage({
    required this.data,
    required this.mimeType,
    this.alt,
    this.caption,
    this.pageNumber,
    this.position,
  });

  /// Image data as bytes.
  final Uint8List data;

  /// MIME type of the image.
  final String mimeType;

  /// Alt text if available.
  final String? alt;

  /// Caption if available.
  final String? caption;

  /// Page number where the image appears.
  final int? pageNumber;

  /// Position in the document.
  final int? position;
}

/// A table extracted from a document.
class ExtractedTable {
  /// Creates an extracted table.
  const ExtractedTable({
    required this.headers,
    required this.rows,
    this.caption,
    this.pageNumber,
  });

  /// Table headers.
  final List<String> headers;

  /// Table rows.
  final List<List<String>> rows;

  /// Table caption if available.
  final String? caption;

  /// Page number where the table appears.
  final int? pageNumber;

  /// Convert to markdown format.
  String toMarkdown() {
    final buffer = StringBuffer();

    // Headers
    buffer.writeln('| ${headers.join(' | ')} |');
    buffer.writeln('| ${headers.map((_) => '---').join(' | ')} |');

    // Rows
    for (final row in rows) {
      buffer.writeln('| ${row.join(' | ')} |');
    }

    return buffer.toString();
  }

  /// Convert to CSV format.
  String toCsv() {
    final buffer = StringBuffer();
    buffer.writeln(headers.map(_escapeCsv).join(','));
    for (final row in rows) {
      buffer.writeln(row.map(_escapeCsv).join(','));
    }
    return buffer.toString();
  }

  static String _escapeCsv(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}

/// Interface for parsing documents from various formats.
///
/// Document parsers convert binary data or text content into structured
/// [Document] objects for further processing.
///
/// Example:
/// ```dart
/// final parser = HtmlParser();
///
/// // Parse from bytes
/// final result = await parser.parse(htmlBytes);
/// print(result.document.content);
///
/// // Parse from string
/// final result2 = await parser.parseString(htmlString);
/// print(result2.document.content);
/// ```
abstract class DocumentParser {
  /// Parse a document from binary data.
  ///
  /// [bytes] - Raw document bytes
  /// [options] - Parsing options
  Future<ParseResult> parse(
    Uint8List bytes, {
    DocumentParserOptions? options,
  });

  /// Parse a document from a string.
  ///
  /// [content] - Document content as string
  /// [options] - Parsing options
  Future<ParseResult> parseString(
    String content, {
    DocumentParserOptions? options,
  });

  /// Check if this parser supports a file extension.
  bool supportsExtension(String extension);

  /// Check if this parser supports a MIME type.
  bool supportsMimeType(String mimeType);

  /// Get the list of supported file extensions.
  List<String> get supportedExtensions;

  /// Get the list of supported MIME types.
  List<String> get supportedMimeTypes;
}

/// Base class with common parser functionality.
abstract class BaseDocumentParser implements DocumentParser {
  /// Create parser options with defaults.
  DocumentParserOptions mergeOptions(DocumentParserOptions? options) {
    return options ?? const DocumentParserOptions();
  }

  /// Create a document from parsed content.
  Document createDocument(
    String content, {
    String? sourceUri,
    Map<String, dynamic>? metadata,
  }) {
    return Document(
      content: content,
      metadata: metadata ?? {},
      source: sourceUri != null ? DocumentSource(uri: sourceUri) : null,
    );
  }
}
