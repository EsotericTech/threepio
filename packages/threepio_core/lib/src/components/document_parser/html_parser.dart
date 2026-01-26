import 'dart:convert';
import 'dart:typed_data';

import 'document_parser.dart';

/// Parser for HTML documents.
///
/// Extracts text content from HTML, preserving structure and optionally
/// extracting images and tables.
///
/// Example:
/// ```dart
/// final parser = HtmlParser();
///
/// final html = '<html><body><h1>Title</h1><p>Content</p></body></html>';
/// final result = await parser.parseString(html);
///
/// print(result.document.content);
/// // Output: Title\n\nContent
/// ```
class HtmlParser extends BaseDocumentParser {
  /// Creates an HTML parser.
  HtmlParser({
    this.removeScripts = true,
    this.removeStyles = true,
    this.removeComments = true,
    this.preserveLinks = false,
    this.preserveLineBreaks = true,
  });

  /// Whether to remove script tags and their content.
  final bool removeScripts;

  /// Whether to remove style tags and their content.
  final bool removeStyles;

  /// Whether to remove HTML comments.
  final bool removeComments;

  /// Whether to preserve link URLs in the output.
  final bool preserveLinks;

  /// Whether to preserve line breaks from block elements.
  final bool preserveLineBreaks;

  @override
  List<String> get supportedExtensions => ['html', 'htm', 'xhtml'];

  @override
  List<String> get supportedMimeTypes => [
        'text/html',
        'application/xhtml+xml',
      ];

  @override
  bool supportsExtension(String extension) {
    return supportedExtensions.contains(extension.toLowerCase());
  }

  @override
  bool supportsMimeType(String mimeType) {
    return supportedMimeTypes.contains(mimeType.toLowerCase());
  }

  @override
  Future<ParseResult> parse(
    Uint8List bytes, {
    DocumentParserOptions? options,
  }) async {
    final opts = mergeOptions(options);
    final content = utf8.decode(bytes, allowMalformed: true);
    return parseString(content, options: opts);
  }

  @override
  Future<ParseResult> parseString(
    String content, {
    DocumentParserOptions? options,
  }) async {
    final opts = mergeOptions(options);
    final warnings = <String>[];

    // Extract title if present
    String? title;
    final titleMatch = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true)
        .firstMatch(content);
    if (titleMatch != null) {
      title = _decodeHtmlEntities(titleMatch.group(1)?.trim() ?? '');
    }

    // Process the HTML
    var processed = content;

    // Remove scripts
    if (removeScripts) {
      processed = processed.replaceAll(
        RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true),
        '',
      );
      processed = processed.replaceAll(
        RegExp(r'<script[^>]*/>', caseSensitive: false),
        '',
      );
    }

    // Remove styles
    if (removeStyles) {
      processed = processed.replaceAll(
        RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true),
        '',
      );
    }

    // Remove comments
    if (removeComments) {
      processed = processed.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    }

    // Extract tables if requested
    List<ExtractedTable>? tables;
    if (opts.extractTables) {
      tables = _extractTables(processed);
    }

    // Extract images if requested
    List<ExtractedImage>? images;
    if (opts.extractImages) {
      images = await _extractImages(processed);
    }

    // Convert to plain text
    var text = _htmlToPlainText(processed);

    // Clean up whitespace
    text = _cleanWhitespace(text);

    // Build metadata
    final metadata = <String, dynamic>{
      if (title != null) 'title': title,
      if (opts.metadata != null) ...opts.metadata!,
      'parser': 'html',
    };

    final document = createDocument(
      text,
      metadata: metadata,
    );

    return ParseResult(
      documents: [document],
      metadata: {
        'original_length': content.length,
        'parsed_length': text.length,
      },
      warnings: warnings.isEmpty ? null : warnings,
      extractedTables: tables,
      extractedImages: images,
    );
  }

  String _htmlToPlainText(String html) {
    var result = html;

    // Handle line breaks
    if (preserveLineBreaks) {
      // Add line breaks after block elements
      final blockElements = [
        'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
        'li', 'tr', 'br', 'hr', 'article', 'section',
        'header', 'footer', 'nav', 'aside', 'blockquote',
        'pre', 'figure', 'figcaption',
      ];

      for (final tag in blockElements) {
        result = result.replaceAll(
          RegExp('</$tag>', caseSensitive: false),
          '\n',
        );
        result = result.replaceAll(
          RegExp('<$tag[^>]*/>', caseSensitive: false),
          '\n',
        );
      }

      // Handle <br> and <hr>
      result = result.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
      result = result.replaceAll(RegExp(r'<hr\s*/?>', caseSensitive: false), '\n---\n');
    }

    // Handle links
    if (preserveLinks) {
      result = result.replaceAllMapped(
        RegExp(r'<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>', caseSensitive: false, dotAll: true),
        (match) {
          final url = match.group(1) ?? '';
          final text = match.group(2) ?? '';
          final cleanText = _stripTags(text);
          return '$cleanText ($url)';
        },
      );
    }

    // Handle list items
    result = result.replaceAllMapped(
      RegExp(r'<li[^>]*>(.*?)</li>', caseSensitive: false, dotAll: true),
      (match) => '• ${_stripTags(match.group(1) ?? '')}\n',
    );

    // Handle headers with extra spacing
    for (var i = 1; i <= 6; i++) {
      result = result.replaceAllMapped(
        RegExp('<h$i[^>]*>(.*?)</h$i>', caseSensitive: false, dotAll: true),
        (match) => '\n${_stripTags(match.group(1) ?? '')}\n\n',
      );
    }

    // Strip remaining tags
    result = _stripTags(result);

    // Decode HTML entities
    result = _decodeHtmlEntities(result);

    return result;
  }

  String _stripTags(String html) {
    return html.replaceAll(RegExp(r'<[^>]*>'), '');
  }

  String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAllMapped(
          RegExp(r'&#(\d+);'),
          (match) {
            final code = int.tryParse(match.group(1) ?? '');
            if (code != null) {
              return String.fromCharCode(code);
            }
            return match.group(0)!;
          },
        )
        .replaceAllMapped(
          RegExp(r'&#x([0-9a-fA-F]+);'),
          (match) {
            final code = int.tryParse(match.group(1) ?? '', radix: 16);
            if (code != null) {
              return String.fromCharCode(code);
            }
            return match.group(0)!;
          },
        );
  }

  String _cleanWhitespace(String text) {
    // Normalize line endings
    var result = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // Replace multiple spaces with single space
    result = result.replaceAll(RegExp(r'[ \t]+'), ' ');

    // Replace multiple newlines with double newline
    result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    // Trim lines
    result = result.split('\n').map((line) => line.trim()).join('\n');

    return result.trim();
  }

  List<ExtractedTable> _extractTables(String html) {
    final tables = <ExtractedTable>[];

    final tableMatches = RegExp(
      r'<table[^>]*>(.*?)</table>',
      caseSensitive: false,
      dotAll: true,
    ).allMatches(html);

    for (final tableMatch in tableMatches) {
      final tableHtml = tableMatch.group(1) ?? '';

      // Extract caption
      String? caption;
      final captionMatch = RegExp(
        r'<caption[^>]*>(.*?)</caption>',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(tableHtml);
      if (captionMatch != null) {
        caption = _stripTags(captionMatch.group(1) ?? '').trim();
      }

      // Extract headers
      final headers = <String>[];
      final headerRow = RegExp(
        r'<tr[^>]*>(.*?)</tr>',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(tableHtml);

      if (headerRow != null) {
        final headerCells = RegExp(
          r'<th[^>]*>(.*?)</th>',
          caseSensitive: false,
          dotAll: true,
        ).allMatches(headerRow.group(1) ?? '');

        for (final cell in headerCells) {
          headers.add(_stripTags(_decodeHtmlEntities(cell.group(1) ?? '')).trim());
        }
      }

      // Extract rows
      final rows = <List<String>>[];
      final rowMatches = RegExp(
        r'<tr[^>]*>(.*?)</tr>',
        caseSensitive: false,
        dotAll: true,
      ).allMatches(tableHtml);

      var isFirstRow = true;
      for (final rowMatch in rowMatches) {
        final rowHtml = rowMatch.group(1) ?? '';

        // Skip header row
        if (isFirstRow && headers.isNotEmpty) {
          isFirstRow = false;
          continue;
        }
        isFirstRow = false;

        final cells = <String>[];
        final cellMatches = RegExp(
          r'<td[^>]*>(.*?)</td>',
          caseSensitive: false,
          dotAll: true,
        ).allMatches(rowHtml);

        for (final cell in cellMatches) {
          cells.add(_stripTags(_decodeHtmlEntities(cell.group(1) ?? '')).trim());
        }

        if (cells.isNotEmpty) {
          rows.add(cells);
        }
      }

      // If no headers found, use first row
      if (headers.isEmpty && rows.isNotEmpty) {
        headers.addAll(rows.removeAt(0));
      }

      if (headers.isNotEmpty || rows.isNotEmpty) {
        tables.add(ExtractedTable(
          headers: headers,
          rows: rows,
          caption: caption,
        ));
      }
    }

    return tables;
  }

  Future<List<ExtractedImage>> _extractImages(String html) async {
    final images = <ExtractedImage>[];

    final imgMatches = RegExp(
      r'<img[^>]*>',
      caseSensitive: false,
    ).allMatches(html);

    for (final match in imgMatches) {
      final imgTag = match.group(0) ?? '';

      // Extract alt
      String? alt;
      final altMatch = RegExp(r'alt="([^"]*)"', caseSensitive: false).firstMatch(imgTag);
      if (altMatch != null) {
        alt = _decodeHtmlEntities(altMatch.group(1) ?? '');
      }

      // Extract src
      String? src;
      final srcMatch = RegExp(r'src="([^"]*)"', caseSensitive: false).firstMatch(imgTag);
      if (srcMatch != null) {
        src = srcMatch.group(1);
      }

      // We don't actually fetch images here - just record metadata
      // Actual image fetching would require external dependencies
      if (src != null) {
        images.add(ExtractedImage(
          data: Uint8List(0), // Empty - actual fetching would happen elsewhere
          mimeType: _guessMimeTypeFromUrl(src),
          alt: alt,
        ));
      }
    }

    return images;
  }

  String _guessMimeTypeFromUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    return 'image/unknown';
  }
}
