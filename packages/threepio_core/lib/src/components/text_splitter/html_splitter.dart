import '../../schema/document.dart';
import 'text_splitter.dart';

/// HTML-aware text splitter.
///
/// Splits HTML content while respecting document structure, preserving
/// semantic boundaries defined by HTML tags.
///
/// Splitting hierarchy (from largest to smallest):
/// 1. Major sections (article, section, main)
/// 2. Structural divs with IDs/classes
/// 3. Headers (h1-h6)
/// 4. Paragraphs (p)
/// 5. Other block elements (div, blockquote, li)
/// 6. Fallback to character splitting
///
/// Example:
/// ```dart
/// final splitter = HtmlSplitter(
///   stripTags: true, // Return plain text chunks
/// );
///
/// final html = '''
/// <article>
///   <h1>Title</h1>
///   <p>First paragraph...</p>
///   <p>Second paragraph...</p>
/// </article>
/// ''';
///
/// final chunks = splitter.splitText(html);
/// ```
class HtmlSplitter extends TextSplitter {
  /// Creates an HTML splitter.
  HtmlSplitter({
    this.stripTags = true,
    this.preserveLinks = false,
    this.splitByHeaders = true,
    List<String>? headerTags,
    List<String>? sectionTags,
    List<String>? blockTags,
  })  : headerTags = headerTags ?? ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'],
        sectionTags = sectionTags ?? ['article', 'section', 'main', 'aside', 'nav'],
        blockTags = blockTags ?? ['p', 'div', 'blockquote', 'li', 'pre', 'figure'];

  /// Whether to strip HTML tags from output chunks.
  final bool stripTags;

  /// Whether to preserve link URLs in output.
  final bool preserveLinks;

  /// Whether to split at header boundaries.
  final bool splitByHeaders;

  /// HTML header tags that define section boundaries.
  final List<String> headerTags;

  /// HTML tags that define major sections.
  final List<String> sectionTags;

  /// HTML block-level tags to split on.
  final List<String> blockTags;

  @override
  List<String> splitText(
    String text, {
    TextSplitterOptions? options,
  }) {
    final opts = options ?? const TextSplitterOptions();
    opts.validate();

    if (text.isEmpty) {
      return [];
    }

    // Remove scripts, styles, and comments first
    var cleaned = _removeScriptsAndStyles(text);
    cleaned = _removeComments(cleaned);

    // Extract sections based on hierarchy
    final sections = _extractSections(cleaned);

    // Process and merge sections into appropriately sized chunks
    final chunks = <String>[];
    var currentChunk = '';

    for (final section in sections) {
      var processed = section;

      // Process the section content
      if (preserveLinks) {
        processed = _preserveLinks(processed);
      }

      if (stripTags) {
        processed = _stripHtmlTags(processed);
      }

      processed = _cleanWhitespace(processed);

      if (processed.isEmpty) continue;

      // Check if section fits in current chunk
      if (currentChunk.isEmpty) {
        currentChunk = processed;
      } else if (currentChunk.length + processed.length + 2 <= opts.chunkSize) {
        currentChunk = '$currentChunk\n\n$processed';
      } else {
        // Save current chunk and start new one
        if (currentChunk.length > opts.chunkSize) {
          // Current chunk is too large, need to split it
          chunks.addAll(_splitLargeSection(currentChunk, opts));
        } else {
          chunks.add(currentChunk.trim());
        }

        // Apply overlap if configured
        if (opts.chunkOverlap > 0 && currentChunk.isNotEmpty) {
          final overlap = _getOverlapText(currentChunk, opts.chunkOverlap);
          currentChunk = overlap.isEmpty ? processed : '$overlap\n\n$processed';
        } else {
          currentChunk = processed;
        }
      }
    }

    // Handle remaining content
    if (currentChunk.isNotEmpty) {
      if (currentChunk.length > opts.chunkSize) {
        chunks.addAll(_splitLargeSection(currentChunk, opts));
      } else {
        chunks.add(currentChunk.trim());
      }
    }

    return chunks.where((c) => c.isNotEmpty).toList();
  }

  @override
  Future<List<Document>> splitDocuments(
    List<Document> documents, {
    TextSplitterOptions? options,
  }) async {
    final result = <Document>[];

    for (final doc in documents) {
      final chunks = splitText(doc.content, options: options);

      for (var i = 0; i < chunks.length; i++) {
        final chunkMetadata = createChunkMetadata(
          originalDoc: doc,
          chunkIndex: i,
          totalChunks: chunks.length,
        );

        result.add(
          Document(
            content: chunks[i],
            metadata: {
              ...chunkMetadata,
              'content_type': 'html',
            },
            source: doc.source,
          ),
        );
      }
    }

    return result;
  }

  String _removeScriptsAndStyles(String html) {
    var result = html;
    result = result.replaceAll(
      RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true),
      '',
    );
    result = result.replaceAll(
      RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true),
      '',
    );
    result = result.replaceAll(
      RegExp(r'<noscript[^>]*>.*?</noscript>', caseSensitive: false, dotAll: true),
      '',
    );
    return result;
  }

  String _removeComments(String html) {
    return html.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  }

  List<String> _extractSections(String html) {
    final sections = <String>[];

    // Build regex for all section-level tags
    final allSectionTags = [...sectionTags, ...headerTags];
    final sectionRegex = _buildTagRegex(allSectionTags);

    // Find all section boundaries
    final matches = sectionRegex.allMatches(html).toList();

    if (matches.isEmpty) {
      // No sections found, split by block elements
      return _splitByBlockElements(html);
    }

    // Extract content between section boundaries
    var lastEnd = 0;
    for (final match in matches) {
      // Add content before this section
      if (match.start > lastEnd) {
        final before = html.substring(lastEnd, match.start).trim();
        if (before.isNotEmpty) {
          sections.addAll(_splitByBlockElements(before));
        }
      }

      // Add the section itself
      sections.add(match.group(0) ?? '');
      lastEnd = match.end;
    }

    // Add remaining content
    if (lastEnd < html.length) {
      final remaining = html.substring(lastEnd).trim();
      if (remaining.isNotEmpty) {
        sections.addAll(_splitByBlockElements(remaining));
      }
    }

    return sections;
  }

  List<String> _splitByBlockElements(String html) {
    final blocks = <String>[];
    final blockRegex = _buildTagRegex(blockTags);

    final matches = blockRegex.allMatches(html).toList();

    if (matches.isEmpty) {
      // No block elements, return trimmed content
      final trimmed = html.trim();
      if (trimmed.isNotEmpty) {
        blocks.add(trimmed);
      }
      return blocks;
    }

    var lastEnd = 0;
    for (final match in matches) {
      // Add content before this block
      if (match.start > lastEnd) {
        final before = html.substring(lastEnd, match.start).trim();
        if (before.isNotEmpty) {
          blocks.add(before);
        }
      }

      // Add the block itself
      blocks.add(match.group(0) ?? '');
      lastEnd = match.end;
    }

    // Add remaining content
    if (lastEnd < html.length) {
      final remaining = html.substring(lastEnd).trim();
      if (remaining.isNotEmpty) {
        blocks.add(remaining);
      }
    }

    return blocks;
  }

  RegExp _buildTagRegex(List<String> tags) {
    final tagPattern = tags.join('|');
    return RegExp(
      '<($tagPattern)[^>]*>.*?</\\1>',
      caseSensitive: false,
      dotAll: true,
    );
  }

  String _preserveLinks(String html) {
    return html.replaceAllMapped(
      RegExp(r'<a[^>]*href="([^"]*)"[^>]*>(.*?)</a>', caseSensitive: false, dotAll: true),
      (match) {
        final url = match.group(1) ?? '';
        final text = _stripHtmlTags(match.group(2) ?? '');
        return '$text ($url)';
      },
    );
  }

  String _stripHtmlTags(String html) {
    // Replace block elements with newlines
    var result = html;

    // Add newlines for block elements
    final blockElements = ['p', 'div', 'br', 'li', 'tr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'];
    for (final tag in blockElements) {
      result = result.replaceAll(
        RegExp('</$tag>', caseSensitive: false),
        '\n',
      );
    }

    // Handle <br>
    result = result.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');

    // Strip all remaining tags
    result = result.replaceAll(RegExp(r'<[^>]*>'), '');

    // Decode common HTML entities
    result = _decodeHtmlEntities(result);

    return result;
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
        );
  }

  String _cleanWhitespace(String text) {
    // Normalize line endings
    var result = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // Replace multiple spaces/tabs with single space
    result = result.replaceAll(RegExp(r'[ \t]+'), ' ');

    // Replace multiple newlines with double newline
    result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    // Trim each line
    result = result.split('\n').map((line) => line.trim()).join('\n');

    return result.trim();
  }

  List<String> _splitLargeSection(String text, TextSplitterOptions options) {
    final chunks = <String>[];
    final lines = text.split('\n');
    var currentChunk = '';

    for (final line in lines) {
      if (line.isEmpty) continue;

      final potential = currentChunk.isEmpty ? line : '$currentChunk\n$line';

      if (potential.length <= options.chunkSize) {
        currentChunk = potential;
      } else {
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk.trim());
        }

        // Handle lines that are themselves too long
        if (line.length > options.chunkSize) {
          chunks.addAll(_forceSplitText(line, options.chunkSize, options.chunkOverlap));
          currentChunk = '';
        } else {
          // Apply overlap
          if (options.chunkOverlap > 0 && currentChunk.isNotEmpty) {
            final overlap = _getOverlapText(currentChunk, options.chunkOverlap);
            currentChunk = overlap.isEmpty ? line : '$overlap\n$line';
          } else {
            currentChunk = line;
          }
        }
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.trim());
    }

    return chunks;
  }

  String _getOverlapText(String text, int overlapSize) {
    if (text.length <= overlapSize) {
      return text;
    }
    return text.substring(text.length - overlapSize);
  }

  List<String> _forceSplitText(String text, int chunkSize, int chunkOverlap) {
    final chunks = <String>[];
    var start = 0;

    while (start < text.length) {
      var end = start + chunkSize;
      if (end > text.length) {
        end = text.length;
      }

      chunks.add(text.substring(start, end));
      start = end - chunkOverlap;
      if (start <= 0) {
        start = end;
      }
    }

    return chunks;
  }
}
