import 'dart:typed_data';

import 'document_parser.dart';

/// Exception thrown when no suitable parser is found.
class NoParserFoundException implements Exception {
  /// Creates a no parser found exception.
  const NoParserFoundException({
    this.extension,
    this.mimeType,
    this.availableExtensions,
    this.availableMimeTypes,
  });

  /// The extension that couldn't be matched.
  final String? extension;

  /// The MIME type that couldn't be matched.
  final String? mimeType;

  /// Available extensions for reference.
  final List<String>? availableExtensions;

  /// Available MIME types for reference.
  final List<String>? availableMimeTypes;

  @override
  String toString() {
    final buffer = StringBuffer('NoParserFoundException: ');
    if (extension != null) {
      buffer.write('No parser for extension "$extension"');
    } else if (mimeType != null) {
      buffer.write('No parser for MIME type "$mimeType"');
    } else {
      buffer.write('No parser found');
    }
    if (availableExtensions != null) {
      buffer.write('. Available: ${availableExtensions!.join(", ")}');
    }
    return buffer.toString();
  }
}

/// Registry for document parsers with auto-selection.
///
/// Automatically selects the appropriate parser based on file extension
/// or MIME type.
///
/// Example:
/// ```dart
/// final registry = ParserRegistry()
///   ..register(HtmlParser())
///   ..register(MarkdownParser())
///   ..register(PlainTextParser());
///
/// // Parse by extension
/// final result = await registry.parseFile('document.html', bytes);
///
/// // Parse by MIME type
/// final result2 = await registry.parseByMimeType('text/markdown', bytes);
/// ```
class ParserRegistry {
  /// Creates a parser registry.
  ParserRegistry();

  final List<DocumentParser> _parsers = [];
  final Map<String, DocumentParser> _extensionCache = {};
  final Map<String, DocumentParser> _mimeTypeCache = {};

  /// Register a parser.
  void register(DocumentParser parser) {
    _parsers.add(parser);

    // Build extension cache
    for (final ext in parser.supportedExtensions) {
      _extensionCache[ext.toLowerCase()] = parser;
    }

    // Build MIME type cache
    for (final mime in parser.supportedMimeTypes) {
      _mimeTypeCache[mime.toLowerCase()] = parser;
    }
  }

  /// Unregister a parser.
  void unregister(DocumentParser parser) {
    _parsers.remove(parser);

    // Remove from caches
    for (final ext in parser.supportedExtensions) {
      _extensionCache.remove(ext.toLowerCase());
    }
    for (final mime in parser.supportedMimeTypes) {
      _mimeTypeCache.remove(mime.toLowerCase());
    }
  }

  /// Get parser for a file extension.
  DocumentParser? getParserForExtension(String extension) {
    final ext = extension.toLowerCase().replaceFirst('.', '');
    return _extensionCache[ext];
  }

  /// Get parser for a MIME type.
  DocumentParser? getParserForMimeType(String mimeType) {
    return _mimeTypeCache[mimeType.toLowerCase()];
  }

  /// Get parser for a file path (extracts extension).
  DocumentParser? getParserForPath(String path) {
    final ext = _extractExtension(path);
    if (ext != null) {
      return getParserForExtension(ext);
    }
    return null;
  }

  /// Get all registered extensions.
  List<String> get supportedExtensions => _extensionCache.keys.toList();

  /// Get all registered MIME types.
  List<String> get supportedMimeTypes => _mimeTypeCache.keys.toList();

  /// Parse a file by path (uses extension to select parser).
  Future<ParseResult> parseFile(
    String path,
    Uint8List bytes, {
    DocumentParserOptions? options,
  }) async {
    final parser = getParserForPath(path);
    if (parser == null) {
      throw NoParserFoundException(
        extension: _extractExtension(path),
        availableExtensions: supportedExtensions,
      );
    }
    return parser.parse(bytes, options: options);
  }

  /// Parse content by MIME type.
  Future<ParseResult> parseByMimeType(
    String mimeType,
    Uint8List bytes, {
    DocumentParserOptions? options,
  }) async {
    final parser = getParserForMimeType(mimeType);
    if (parser == null) {
      throw NoParserFoundException(
        mimeType: mimeType,
        availableMimeTypes: supportedMimeTypes,
      );
    }
    return parser.parse(bytes, options: options);
  }

  /// Parse string content by extension.
  Future<ParseResult> parseStringByExtension(
    String extension,
    String content, {
    DocumentParserOptions? options,
  }) async {
    final parser = getParserForExtension(extension);
    if (parser == null) {
      throw NoParserFoundException(
        extension: extension,
        availableExtensions: supportedExtensions,
      );
    }
    return parser.parseString(content, options: options);
  }

  /// Parse string content by MIME type.
  Future<ParseResult> parseStringByMimeType(
    String mimeType,
    String content, {
    DocumentParserOptions? options,
  }) async {
    final parser = getParserForMimeType(mimeType);
    if (parser == null) {
      throw NoParserFoundException(
        mimeType: mimeType,
        availableMimeTypes: supportedMimeTypes,
      );
    }
    return parser.parseString(content, options: options);
  }

  /// Check if any parser supports the extension.
  bool supportsExtension(String extension) {
    return getParserForExtension(extension) != null;
  }

  /// Check if any parser supports the MIME type.
  bool supportsMimeType(String mimeType) {
    return getParserForMimeType(mimeType) != null;
  }

  static String? _extractExtension(String path) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot >= 0 && lastDot < path.length - 1) {
      // Handle query strings and fragments in URLs
      var ext = path.substring(lastDot + 1);
      final queryStart = ext.indexOf('?');
      if (queryStart >= 0) {
        ext = ext.substring(0, queryStart);
      }
      final fragmentStart = ext.indexOf('#');
      if (fragmentStart >= 0) {
        ext = ext.substring(0, fragmentStart);
      }
      return ext.isEmpty ? null : ext;
    }
    return null;
  }
}
