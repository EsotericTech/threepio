import 'dart:convert';
import 'dart:io';

import '../../schema/document.dart';
import 'document_loader.dart';

/// Loads documents from plain text files
///
/// Reads text files from the file system and converts them into Document objects.
/// Supports various text encodings and can add custom metadata.
///
/// Example usage:
/// ```dart
/// // Load a single text file
/// final loader = TextLoader(filePath: 'document.txt');
/// final docs = await loader.load();
///
/// print('Content: ${docs.first.content}');
///
/// // Load with custom encoding and metadata
/// final loaderWithOptions = TextLoader(
///   filePath: 'document-utf16.txt',
/// );
///
/// final docsWithMetadata = await loaderWithOptions.load(
///   options: DocumentLoaderOptions(
///     encoding: 'utf-16',
///     metadata: {'author': 'John Doe', 'category': 'technical'},
///   ),
/// );
/// ```
class TextLoader implements DocumentLoader {
  TextLoader({
    required this.filePath,
    this.autoDetectEncoding = false,
  });

  /// Path to the text file to load
  final String filePath;

  /// Whether to attempt automatic encoding detection
  final bool autoDetectEncoding;

  @override
  Future<List<Document>> load({
    DocumentLoaderOptions? options,
  }) async {
    final file = File(filePath);

    if (!await file.exists()) {
      throw DocumentLoaderException(
        'File not found: $filePath',
      );
    }

    // Read file content
    final encoding = _getEncoding(options?.encoding ?? 'utf-8');
    final content = await file.readAsString(encoding: encoding);

    // Get file metadata
    final stat = await file.stat();
    final metadata = <String, dynamic>{
      'source': filePath,
      'file_size': stat.size,
      'modified': stat.modified.toIso8601String(),
      ...?options?.metadata,
    };

    // Create document
    final document = Document(
      content: content,
      metadata: metadata,
      source: DocumentSource(
        uri: 'file://$filePath',
        metadata: {
          'type': 'text_file',
          'encoding': options?.encoding ?? 'utf-8',
        },
      ),
    );

    return [document];
  }

  @override
  Stream<Document> loadLazy({
    DocumentLoaderOptions? options,
  }) async* {
    // For single file, just load and yield
    final documents = await load(options: options);
    for (final doc in documents) {
      yield doc;
    }
  }

  /// Get encoding from string name
  Encoding _getEncoding(String encodingName) {
    switch (encodingName.toLowerCase()) {
      case 'utf-8':
      case 'utf8':
        return utf8;
      case 'ascii':
        return ascii;
      case 'latin-1':
      case 'latin1':
      case 'iso-8859-1':
        return latin1;
      default:
        // Try to get encoding by name
        final encoding = Encoding.getByName(encodingName);
        if (encoding != null) {
          return encoding;
        }
        throw DocumentLoaderException(
          'Unsupported encoding: $encodingName',
        );
    }
  }
}

/// Loads documents from all text files in a directory
///
/// Recursively scans a directory for text files and loads each one as a
/// separate document. Useful for loading entire document collections.
///
/// Example usage:
/// ```dart
/// // Load all .txt files from a directory
/// final loader = DirectoryLoader(
///   dirPath: 'documents/',
///   glob: '**/*.txt',
/// );
///
/// final docs = await loader.load();
/// print('Loaded ${docs.length} documents');
///
/// // Load lazily for large directories
/// await for (final doc in loader.loadLazy()) {
///   print('Processing: ${doc.source?.uri}');
///   // Process document...
/// }
/// ```
class DirectoryLoader implements DocumentLoader {
  DirectoryLoader({
    required this.dirPath,
    this.glob = '**/*.txt',
    this.recursive = true,
  });

  /// Path to the directory to scan
  final String dirPath;

  /// Glob pattern for matching files (default: all .txt files)
  final String glob;

  /// Whether to scan subdirectories recursively
  final bool recursive;

  @override
  Future<List<Document>> load({
    DocumentLoaderOptions? options,
  }) async {
    final dir = Directory(dirPath);

    if (!await dir.exists()) {
      throw DocumentLoaderException(
        'Directory not found: $dirPath',
      );
    }

    final documents = <Document>[];

    // Get all matching files
    final files = await _findFiles(dir);

    // Load each file
    for (final file in files) {
      try {
        final loader = TextLoader(filePath: file.path);
        final docs = await loader.load(options: options);
        documents.addAll(docs);
      } catch (e) {
        // Skip files that can't be loaded
        // Could add logging here
        continue;
      }
    }

    return documents;
  }

  @override
  Stream<Document> loadLazy({
    DocumentLoaderOptions? options,
  }) async* {
    final dir = Directory(dirPath);

    if (!await dir.exists()) {
      throw DocumentLoaderException(
        'Directory not found: $dirPath',
      );
    }

    // Get all matching files
    final files = await _findFiles(dir);

    // Yield documents as they're loaded
    for (final file in files) {
      try {
        final loader = TextLoader(filePath: file.path);
        final docs = await loader.load(options: options);
        for (final doc in docs) {
          yield doc;
        }
      } catch (e) {
        // Skip files that can't be loaded
        continue;
      }
    }
  }

  /// Find all files matching the pattern
  Future<List<File>> _findFiles(Directory dir) async {
    final files = <File>[];

    await for (final entity in dir.list(recursive: recursive)) {
      if (entity is File) {
        // Simple glob matching (just check extension for now)
        if (_matchesGlob(entity.path)) {
          files.add(entity);
        }
      }
    }

    return files;
  }

  /// Simple glob pattern matching
  bool _matchesGlob(String path) {
    // Extract extension from glob pattern
    if (glob.endsWith('*.txt')) {
      return path.endsWith('.txt');
    } else if (glob.endsWith('*.md')) {
      return path.endsWith('.md');
    } else if (glob.contains('*.*')) {
      // Match all files
      return true;
    }

    // For more complex patterns, could use a proper glob library
    return path.endsWith('.txt');
  }
}

/// Document loader exception
class DocumentLoaderException implements Exception {
  DocumentLoaderException(this.message);

  final String message;

  @override
  String toString() => 'DocumentLoaderException: $message';
}
