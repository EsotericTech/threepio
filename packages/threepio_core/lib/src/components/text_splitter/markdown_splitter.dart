import '../../schema/document.dart';
import 'fixed_size_split.dart';
import 'text_splitter.dart';

/// Markdown-aware text splitter.
///
/// Splits markdown content while respecting document structure:
/// - Heading hierarchy (h1-h6)
/// - Code blocks (preserved intact when possible)
/// - Paragraphs
/// - Lists
///
/// Example:
/// ```dart
/// final splitter = MarkdownSplitter(
///   preserveCodeBlocks: true,
/// );
///
/// final markdown = '''
/// # Main Title
///
/// Some introduction text.
///
/// ## Section 1
///
/// Content for section 1...
///
/// ```dart
/// code example
/// ```
///
/// ## Section 2
///
/// More content...
/// ''';
///
/// final chunks = splitter.splitText(markdown);
/// ```
class MarkdownSplitter extends TextSplitter {
  /// Creates a markdown splitter.
  MarkdownSplitter({
    this.preserveCodeBlocks = true,
    this.splitOnHeaders = true,
    this.minHeaderLevel = 1,
    this.maxHeaderLevel = 6,
    this.returnEachLine = false,
  });

  /// Whether to try to keep code blocks intact.
  final bool preserveCodeBlocks;

  /// Whether to split at header boundaries.
  final bool splitOnHeaders;

  /// Minimum header level to split on (1 = h1).
  final int minHeaderLevel;

  /// Maximum header level to split on (6 = h6).
  final int maxHeaderLevel;

  /// Whether to return each line as a separate chunk (for embedding).
  final bool returnEachLine;


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

    if (returnEachLine) {
      return _splitByLines(text, opts);
    }

    // Extract and protect code blocks
    final protectedText = preserveCodeBlocks ? _protectCodeBlocks(text) : text;

    // Split using markdown-aware separators
    final sections = _splitMarkdown(protectedText, opts);

    // Restore code blocks and build final chunks
    final chunks = <String>[];
    var currentChunk = '';

    for (var section in sections) {
      // Restore code blocks if protected
      if (preserveCodeBlocks) {
        section = _restoreCodeBlocks(section);
      }

      section = section.trim();
      if (section.isEmpty) continue;

      if (currentChunk.isEmpty) {
        currentChunk = section;
      } else if (currentChunk.length + section.length + 2 <= opts.chunkSize) {
        currentChunk = '$currentChunk\n\n$section';
      } else {
        // Save current chunk
        if (currentChunk.length > opts.chunkSize) {
          chunks.addAll(_splitLargeSection(currentChunk, opts));
        } else {
          chunks.add(currentChunk);
        }

        // Start new chunk with overlap
        if (opts.chunkOverlap > 0 && currentChunk.isNotEmpty) {
          final overlap = _getOverlap(currentChunk, opts.chunkOverlap);
          currentChunk = overlap.isEmpty ? section : '$overlap\n\n$section';
        } else {
          currentChunk = section;
        }
      }
    }

    // Handle remaining content
    if (currentChunk.isNotEmpty) {
      if (currentChunk.length > opts.chunkSize) {
        chunks.addAll(_splitLargeSection(currentChunk, opts));
      } else {
        chunks.add(currentChunk);
      }
    }

    return chunks.where((c) => c.trim().isNotEmpty).toList();
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

        // Extract header context if present
        final headerContext = _extractHeaderContext(chunks[i]);

        result.add(
          Document(
            content: chunks[i],
            metadata: {
              ...chunkMetadata,
              'content_type': 'markdown',
              if (headerContext != null) 'header_context': headerContext,
            },
            source: doc.source,
          ),
        );
      }
    }

    return result;
  }

  // Code block protection
  final _codeBlockPlaceholders = <String, String>{};
  int _placeholderCounter = 0;

  String _protectCodeBlocks(String text) {
    _codeBlockPlaceholders.clear();
    _placeholderCounter = 0;

    // Protect fenced code blocks
    return text.replaceAllMapped(
      RegExp(r'```[\s\S]*?```', dotAll: true),
      (match) {
        final placeholder = '<<<CODEBLOCK_${_placeholderCounter++}>>>';
        _codeBlockPlaceholders[placeholder] = match.group(0)!;
        return placeholder;
      },
    );
  }

  String _restoreCodeBlocks(String text) {
    var result = text;
    for (final entry in _codeBlockPlaceholders.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }

  List<String> _splitMarkdown(String text, TextSplitterOptions options) {
    // Build separators based on configuration
    final separators = <String>[];

    if (splitOnHeaders) {
      for (var level = minHeaderLevel; level <= maxHeaderLevel; level++) {
        separators.add('\n${'#' * level} ');
      }
    }

    // Add other separators
    separators.addAll([
      '\n---', '\n***', '\n___', // Horizontal rules
      '\n\n', // Paragraphs
      '\n', // Lines
    ]);

    return _splitWithSeparators(text, separators, options);
  }

  List<String> _splitWithSeparators(
    String text,
    List<String> separators,
    TextSplitterOptions options,
  ) {
    if (separators.isEmpty || text.length <= options.chunkSize) {
      return [text];
    }

    final separator = separators.first;
    final remainingSeparators = separators.sublist(1);

    // Split on this separator
    final parts = _splitKeepingSeparator(text, separator);

    final result = <String>[];
    for (final part in parts) {
      if (part.length <= options.chunkSize) {
        result.add(part);
      } else if (remainingSeparators.isNotEmpty) {
        // Recursively split with remaining separators
        result.addAll(_splitWithSeparators(part, remainingSeparators, options));
      } else {
        // No more separators, force split
        result.addAll(
          splitByLength(
            part,
            chunkSize: options.chunkSize,
            chunkOverlap: options.chunkOverlap,
          ),
        );
      }
    }

    return result;
  }

  List<String> _splitKeepingSeparator(String text, String separator) {
    if (!text.contains(separator)) {
      return [text];
    }

    final result = <String>[];
    final parts = text.split(separator);

    for (var i = 0; i < parts.length; i++) {
      if (i == 0) {
        // First part doesn't get separator prefix
        if (parts[i].isNotEmpty) {
          result.add(parts[i]);
        }
      } else {
        // Subsequent parts get the separator prepended
        result.add(separator.trimLeft() + parts[i]);
      }
    }

    return result;
  }

  List<String> _splitByLines(String text, TextSplitterOptions options) {
    return text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  List<String> _splitLargeSection(String text, TextSplitterOptions options) {
    final chunks = <String>[];

    // Try splitting by paragraphs first
    final paragraphs = text.split('\n\n');

    var currentChunk = '';
    for (final para in paragraphs) {
      if (para.trim().isEmpty) continue;

      if (currentChunk.isEmpty) {
        currentChunk = para;
      } else if (currentChunk.length + para.length + 2 <= options.chunkSize) {
        currentChunk = '$currentChunk\n\n$para';
      } else {
        if (currentChunk.length > options.chunkSize) {
          chunks.addAll(_splitByLines(currentChunk, options));
        } else {
          chunks.add(currentChunk);
        }

        if (options.chunkOverlap > 0) {
          final overlap = _getOverlap(currentChunk, options.chunkOverlap);
          currentChunk = overlap.isEmpty ? para : '$overlap\n\n$para';
        } else {
          currentChunk = para;
        }
      }
    }

    if (currentChunk.isNotEmpty) {
      if (currentChunk.length > options.chunkSize) {
        chunks.addAll(
          splitByLength(
            currentChunk,
            chunkSize: options.chunkSize,
            chunkOverlap: options.chunkOverlap,
          ),
        );
      } else {
        chunks.add(currentChunk);
      }
    }

    return chunks;
  }

  String _getOverlap(String text, int overlapSize) {
    if (text.length <= overlapSize) {
      return text;
    }
    return text.substring(text.length - overlapSize);
  }

  String? _extractHeaderContext(String chunk) {
    // Extract the first header in the chunk for context
    final headerMatch = RegExp(r'^(#{1,6})\s+(.+)$', multiLine: true).firstMatch(chunk);
    if (headerMatch != null) {
      final level = headerMatch.group(1)!.length;
      final title = headerMatch.group(2)!.trim();
      return 'h$level: $title';
    }
    return null;
  }
}

/// Markdown splitter optimized for RAG applications.
///
/// Creates smaller, more focused chunks that work well with
/// embedding models and retrieval systems.
///
/// Example:
/// ```dart
/// final splitter = MarkdownRAGSplitter();
///
/// final chunks = await splitter.splitDocuments(
///   documents,
///   options: TextSplitterOptions(
///     chunkSize: 512,
///     chunkOverlap: 50,
///   ),
/// );
/// ```
class MarkdownRAGSplitter extends MarkdownSplitter {
  /// Creates a markdown RAG splitter.
  MarkdownRAGSplitter({
    super.preserveCodeBlocks = true,
    this.includeHeadersInChunks = true,
    this.addHeaderBreadcrumbs = true,
  });

  /// Whether to include the relevant header at the start of each chunk.
  final bool includeHeadersInChunks;

  /// Whether to add header breadcrumbs to chunk metadata.
  final bool addHeaderBreadcrumbs;

  @override
  Future<List<Document>> splitDocuments(
    List<Document> documents, {
    TextSplitterOptions? options,
  }) async {
    final result = <Document>[];

    for (final doc in documents) {
      final chunks = _splitWithHeaderTracking(doc.content, options);

      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        final chunkMetadata = createChunkMetadata(
          originalDoc: doc,
          chunkIndex: i,
          totalChunks: chunks.length,
        );

        result.add(
          Document(
            content: chunk.content,
            metadata: {
              ...chunkMetadata,
              'content_type': 'markdown',
              if (chunk.headerBreadcrumbs.isNotEmpty)
                'header_breadcrumbs': chunk.headerBreadcrumbs,
              if (chunk.currentHeader != null)
                'current_header': chunk.currentHeader,
            },
            source: doc.source,
          ),
        );
      }
    }

    return result;
  }

  List<_MarkdownChunk> _splitWithHeaderTracking(
    String text,
    TextSplitterOptions? options,
  ) {
    final opts = options ?? const TextSplitterOptions();
    final chunks = <_MarkdownChunk>[];

    // Track header stack
    final headerStack = <_HeaderInfo>[];
    String? currentHeader;

    // Split by any header
    final headerPattern = RegExp(r'^(#{1,6})\s+(.+)$', multiLine: true);
    final lines = text.split('\n');

    var currentContent = StringBuffer();

    for (final line in lines) {
      final headerMatch = headerPattern.firstMatch(line);

      if (headerMatch != null) {
        // Save current content as a chunk
        if (currentContent.isNotEmpty) {
          final content = currentContent.toString().trim();
          if (content.isNotEmpty) {
            final chunkContent = includeHeadersInChunks && currentHeader != null
                ? '$currentHeader\n\n$content'
                : content;

            // Split if too large
            final splitChunks = splitText(chunkContent, options: opts);
            for (final splitChunk in splitChunks) {
              chunks.add(_MarkdownChunk(
                content: splitChunk,
                headerBreadcrumbs: headerStack.map((h) => h.title).toList(),
                currentHeader: currentHeader,
              ));
            }
          }
          currentContent.clear();
        }

        // Update header stack
        final level = headerMatch.group(1)!.length;
        final title = headerMatch.group(2)!.trim();

        // Pop headers of same or lower level
        while (headerStack.isNotEmpty && headerStack.last.level >= level) {
          headerStack.removeLast();
        }

        headerStack.add(_HeaderInfo(level: level, title: title));
        currentHeader = line;
      } else {
        if (currentContent.isNotEmpty) {
          currentContent.writeln();
        }
        currentContent.write(line);
      }
    }

    // Handle remaining content
    if (currentContent.isNotEmpty) {
      final content = currentContent.toString().trim();
      if (content.isNotEmpty) {
        final chunkContent = includeHeadersInChunks && currentHeader != null
            ? '$currentHeader\n\n$content'
            : content;

        final splitChunks = splitText(chunkContent, options: opts);
        for (final splitChunk in splitChunks) {
          chunks.add(_MarkdownChunk(
            content: splitChunk,
            headerBreadcrumbs: headerStack.map((h) => h.title).toList(),
            currentHeader: currentHeader,
          ));
        }
      }
    }

    return chunks;
  }
}

class _MarkdownChunk {
  const _MarkdownChunk({
    required this.content,
    required this.headerBreadcrumbs,
    this.currentHeader,
  });

  final String content;
  final List<String> headerBreadcrumbs;
  final String? currentHeader;
}

class _HeaderInfo {
  const _HeaderInfo({required this.level, required this.title});

  final int level;
  final String title;
}
