import 'dart:convert';
import 'dart:typed_data';

import 'document_parser.dart';

/// Parser for Markdown documents.
///
/// Parses Markdown content, extracting frontmatter metadata and
/// providing both raw and processed text options.
///
/// Example:
/// ```dart
/// final parser = MarkdownParser();
///
/// final markdown = '''
/// ---
/// title: My Document
/// author: John Doe
/// ---
///
/// # Introduction
///
/// This is the content.
/// ''';
///
/// final result = await parser.parseString(markdown);
/// print(result.document.metadata['title']); // "My Document"
/// print(result.document.content);
/// ```
class MarkdownParser extends BaseDocumentParser {
  /// Creates a Markdown parser.
  MarkdownParser({
    this.parseFrontmatter = true,
    this.removeFrontmatter = true,
    this.extractCodeBlocks = false,
    this.preserveFormatting = true,
  });

  /// Whether to parse YAML frontmatter.
  final bool parseFrontmatter;

  /// Whether to remove frontmatter from content.
  final bool removeFrontmatter;

  /// Whether to extract code blocks separately.
  final bool extractCodeBlocks;

  /// Whether to preserve markdown formatting.
  final bool preserveFormatting;

  @override
  List<String> get supportedExtensions => ['md', 'markdown', 'mdown', 'mkd'];

  @override
  List<String> get supportedMimeTypes => [
        'text/markdown',
        'text/x-markdown',
        'text/plain', // Sometimes markdown is served as plain text
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

    var processedContent = content;
    final metadata = <String, dynamic>{};

    // Parse frontmatter
    if (parseFrontmatter) {
      final frontmatterResult = _extractFrontmatter(processedContent);
      if (frontmatterResult.frontmatter != null) {
        final parsed = _parseYamlFrontmatter(frontmatterResult.frontmatter!);
        metadata.addAll(parsed);
        if (parsed['title'] != null && parsed['title'] is! String) {
          warnings.add('Title should be a string');
        }
      }
      if (removeFrontmatter && frontmatterResult.contentWithoutFrontmatter != null) {
        processedContent = frontmatterResult.contentWithoutFrontmatter!;
      }
    }

    // Extract code blocks if requested
    List<ExtractedCodeBlock>? codeBlocks;
    if (extractCodeBlocks) {
      final result = _extractCodeBlocks(processedContent);
      codeBlocks = result.codeBlocks;
    }

    // Convert to plain text if not preserving formatting
    if (!preserveFormatting) {
      processedContent = _stripMarkdownFormatting(processedContent);
    }

    // Clean up
    processedContent = processedContent.trim();

    // Add parser metadata
    metadata['parser'] = 'markdown';
    if (opts.metadata != null) {
      metadata.addAll(opts.metadata!);
    }

    final document = createDocument(
      processedContent,
      metadata: metadata,
    );

    return ParseResult(
      documents: [document],
      metadata: {
        'original_length': content.length,
        'parsed_length': processedContent.length,
        if (codeBlocks != null) 'code_block_count': codeBlocks.length,
      },
      warnings: warnings.isEmpty ? null : warnings,
    );
  }

  _FrontmatterResult _extractFrontmatter(String content) {
    // Check for YAML frontmatter (--- delimited)
    final yamlMatch = RegExp(
      r'^---\s*\n(.*?)\n---\s*\n',
      dotAll: true,
    ).firstMatch(content);

    if (yamlMatch != null) {
      return _FrontmatterResult(
        frontmatter: yamlMatch.group(1),
        contentWithoutFrontmatter: content.substring(yamlMatch.end),
      );
    }

    // Check for TOML frontmatter (+++ delimited)
    final tomlMatch = RegExp(
      r'^\+\+\+\s*\n(.*?)\n\+\+\+\s*\n',
      dotAll: true,
    ).firstMatch(content);

    if (tomlMatch != null) {
      return _FrontmatterResult(
        frontmatter: tomlMatch.group(1),
        contentWithoutFrontmatter: content.substring(tomlMatch.end),
        format: 'toml',
      );
    }

    return const _FrontmatterResult();
  }

  Map<String, dynamic> _parseYamlFrontmatter(String yaml) {
    // Simple YAML parser for frontmatter (key: value pairs)
    final result = <String, dynamic>{};
    final lines = yaml.split('\n');

    String? currentKey;
    final currentList = <String>[];
    var inList = false;

    for (var line in lines) {
      // Skip empty lines
      if (line.trim().isEmpty) continue;

      // Check for list item
      if (inList && line.startsWith('  - ')) {
        currentList.add(line.substring(4).trim());
        continue;
      } else if (inList) {
        result[currentKey!] = currentList.toList();
        currentList.clear();
        inList = false;
      }

      // Check for key: value
      final colonIndex = line.indexOf(':');
      if (colonIndex > 0) {
        final key = line.substring(0, colonIndex).trim();
        var value = line.substring(colonIndex + 1).trim();

        // Check for list start
        if (value.isEmpty) {
          currentKey = key;
          inList = true;
          continue;
        }

        // Parse value
        result[key] = _parseYamlValue(value);
      }
    }

    // Handle trailing list
    if (inList && currentKey != null) {
      result[currentKey] = currentList;
    }

    return result;
  }

  dynamic _parseYamlValue(String value) {
    // Remove quotes
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      return value.substring(1, value.length - 1);
    }

    // Check for boolean
    final lower = value.toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
    if (lower == 'null') return null;

    // Check for number
    final num = int.tryParse(value) ?? double.tryParse(value);
    if (num != null) return num;

    // Check for inline list
    if (value.startsWith('[') && value.endsWith(']')) {
      final inner = value.substring(1, value.length - 1);
      return inner.split(',').map((e) => e.trim()).toList();
    }

    // Return as string
    return value;
  }

  _CodeBlockResult _extractCodeBlocks(String content) {
    final codeBlocks = <ExtractedCodeBlock>[];
    var processedContent = content;

    // Extract fenced code blocks
    final fencedRegex = RegExp(
      r'```(\w*)\n(.*?)```',
      dotAll: true,
    );

    final matches = fencedRegex.allMatches(content).toList();
    for (var i = matches.length - 1; i >= 0; i--) {
      final match = matches[i];
      final language = match.group(1) ?? '';
      final code = match.group(2) ?? '';

      codeBlocks.insert(
        0,
        ExtractedCodeBlock(
          code: code.trim(),
          language: language.isEmpty ? null : language,
          position: match.start,
        ),
      );
    }

    return _CodeBlockResult(
      codeBlocks: codeBlocks,
      contentWithoutCodeBlocks: processedContent,
    );
  }

  String _stripMarkdownFormatting(String content) {
    var result = content;

    // Remove code blocks
    result = result.replaceAll(RegExp(r'```.*?```', dotAll: true), '');
    result = result.replaceAll(RegExp(r'`[^`]+`'), '');

    // Remove headers
    result = result.replaceAllMapped(
      RegExp(r'^#{1,6}\s+(.+)$', multiLine: true),
      (m) => m.group(1) ?? '',
    );

    // Remove bold and italic
    result = result.replaceAll(RegExp(r'\*\*\*(.+?)\*\*\*'), r'$1');
    result = result.replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1');
    result = result.replaceAll(RegExp(r'\*(.+?)\*'), r'$1');
    result = result.replaceAll(RegExp(r'___(.+?)___'), r'$1');
    result = result.replaceAll(RegExp(r'__(.+?)__'), r'$1');
    result = result.replaceAll(RegExp(r'_(.+?)_'), r'$1');

    // Remove links but keep text
    result = result.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^\)]+\)'),
      (m) => m.group(1) ?? '',
    );

    // Remove images
    result = result.replaceAll(RegExp(r'!\[([^\]]*)\]\([^\)]+\)'), '');

    // Remove horizontal rules
    result = result.replaceAll(RegExp(r'^[-*_]{3,}\s*$', multiLine: true), '');

    // Remove blockquotes marker
    result = result.replaceAll(RegExp(r'^>\s*', multiLine: true), '');

    // Remove list markers
    result = result.replaceAll(RegExp(r'^[\s]*[-*+]\s+', multiLine: true), '');
    result = result.replaceAll(RegExp(r'^[\s]*\d+\.\s+', multiLine: true), '');

    return result.trim();
  }
}

class _FrontmatterResult {
  const _FrontmatterResult({
    this.frontmatter,
    this.contentWithoutFrontmatter,
    this.format = 'yaml',
  });

  final String? frontmatter;
  final String? contentWithoutFrontmatter;
  final String format;
}

class _CodeBlockResult {
  const _CodeBlockResult({
    required this.codeBlocks,
    required this.contentWithoutCodeBlocks,
  });

  final List<ExtractedCodeBlock> codeBlocks;
  final String contentWithoutCodeBlocks;
}

/// A code block extracted from a markdown document.
class ExtractedCodeBlock {
  /// Creates an extracted code block.
  const ExtractedCodeBlock({
    required this.code,
    this.language,
    this.position,
  });

  /// The code content.
  final String code;

  /// Programming language (if specified).
  final String? language;

  /// Position in the original document.
  final int? position;
}

/// Parser for plain text documents.
///
/// Simple parser that treats the entire content as a document.
class PlainTextParser extends BaseDocumentParser {
  @override
  List<String> get supportedExtensions => ['txt', 'text'];

  @override
  List<String> get supportedMimeTypes => ['text/plain'];

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

    final document = createDocument(
      content,
      metadata: {
        'parser': 'plain_text',
        if (opts.metadata != null) ...opts.metadata!,
      },
    );

    return ParseResult(
      documents: [document],
      metadata: {
        'length': content.length,
      },
    );
  }
}
