import '../../schema/document.dart';
import 'text_splitter.dart';

/// Recursively splits text using multiple separators
///
/// This splitter attempts to keep semantically related text together by
/// trying separators in order of preference:
/// 1. Double newlines (paragraphs)
/// 2. Single newlines (lines)
/// 3. Spaces (words)
/// 4. Characters
///
/// It recursively applies separators until chunks are small enough.
///
/// Example usage:
/// ```dart
/// final splitter = RecursiveCharacterTextSplitter(
///   separators: ['\n\n', '\n', ' ', ''],
/// );
///
/// final text = '''
/// This is the first paragraph.
/// It has multiple sentences.
///
/// This is the second paragraph.
/// It also has content.
/// ''';
///
/// final chunks = splitter.splitText(
///   text,
///   options: TextSplitterOptions(
///     chunkSize: 100,
///     chunkOverlap: 20,
///   ),
/// );
///
/// for (final chunk in chunks) {
///   print('Chunk: $chunk');
/// }
/// ```
class RecursiveCharacterTextSplitter extends TextSplitter {
  RecursiveCharacterTextSplitter({
    List<String>? separators,
  }) : separators = separators ??
            [
              '\n\n', // Paragraphs
              '\n', // Lines
              '. ', // Sentences
              '! ', // Sentences
              '? ', // Sentences
              '; ', // Clauses
              ', ', // Phrases
              ' ', // Words
              '', // Characters
            ];

  /// Separators to try in order
  final List<String> separators;

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

    // Check if text is already small enough
    if (text.length <= opts.chunkSize) {
      return [text];
    }

    // Try each separator recursively
    return _splitTextRecursive(text, separators, opts);
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
            metadata: chunkMetadata,
            source: doc.source,
          ),
        );
      }
    }

    return result;
  }

  /// Recursively split text using the separator list
  List<String> _splitTextRecursive(
    String text,
    List<String> separators,
    TextSplitterOptions options,
  ) {
    final chunks = <String>[];

    // Get the separator to use
    final separator = separators.isNotEmpty ? separators[0] : '';
    final nextSeparators =
        separators.length > 1 ? separators.sublist(1) : <String>[];

    // Split on the separator
    final splits = _splitWithSeparator(text, separator, options.keepSeparator);

    // Process each split
    var currentChunk = '';
    for (final split in splits) {
      // Skip empty splits
      if (split.trim().isEmpty) {
        continue;
      }

      // If this split is too large, try next separator
      if (split.length > options.chunkSize) {
        // First, add current chunk if not empty
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk.trim());
          currentChunk = '';
        }

        // Recursively split this piece if we have more separators
        if (nextSeparators.isNotEmpty) {
          chunks.addAll(_splitTextRecursive(split, nextSeparators, options));
        } else {
          // No more separators, force split by character
          chunks.addAll(
              _forceSplit(split, options.chunkSize, options.chunkOverlap));
        }
        continue;
      }

      // Check if adding this split would exceed chunk size
      final potentialChunk =
          currentChunk.isEmpty ? split : currentChunk + separator + split;

      if (potentialChunk.length <= options.chunkSize) {
        // Fits in current chunk
        currentChunk = potentialChunk;
      } else {
        // Doesn't fit, save current chunk and start new one
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk.trim());
        }

        // Start new chunk with overlap
        if (options.chunkOverlap > 0 && currentChunk.isNotEmpty) {
          // Get overlap from previous chunk
          final overlapText = _getOverlap(currentChunk, options.chunkOverlap);
          currentChunk =
              overlapText.isEmpty ? split : overlapText + separator + split;
        } else {
          currentChunk = split;
        }
      }
    }

    // Add final chunk
    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.trim());
    }

    return chunks;
  }

  /// Split text on separator, optionally keeping it
  List<String> _splitWithSeparator(
    String text,
    String separator,
    bool keepSeparator,
  ) {
    if (separator.isEmpty) {
      // Split into characters
      return text.split('');
    }

    if (!keepSeparator) {
      return text.split(separator);
    }

    // Keep separator with the text
    final splits = text.split(separator);
    final result = <String>[];

    for (var i = 0; i < splits.length; i++) {
      if (i < splits.length - 1) {
        result.add(splits[i] + separator);
      } else {
        result.add(splits[i]);
      }
    }

    return result;
  }

  /// Get overlap text from the end of a chunk
  String _getOverlap(String text, int overlapSize) {
    if (text.length <= overlapSize) {
      return text;
    }

    return text.substring(text.length - overlapSize);
  }

  /// Force split text into chunks when no separators work
  List<String> _forceSplit(String text, int chunkSize, int chunkOverlap) {
    final chunks = <String>[];
    var start = 0;

    while (start < text.length) {
      var end = start + chunkSize;
      if (end > text.length) {
        end = text.length;
      }

      chunks.add(text.substring(start, end));

      // Move start forward, accounting for overlap
      start = end - chunkOverlap;
      if (start <= 0) {
        start = end; // Avoid infinite loop
      }
    }

    return chunks;
  }
}

/// Simple character-based text splitter
///
/// Splits text into fixed-size chunks based purely on character count,
/// without regard for semantic boundaries. Useful when you need
/// predictable chunk sizes.
///
/// Example usage:
/// ```dart
/// final splitter = CharacterTextSplitter();
///
/// final text = 'This is a long document that needs to be split...';
/// final chunks = splitter.splitText(
///   text,
///   options: TextSplitterOptions(
///     chunkSize: 100,
///     chunkOverlap: 10,
///   ),
/// );
/// ```
class CharacterTextSplitter extends TextSplitter {
  CharacterTextSplitter({
    this.separator = '\n',
  });

  /// Separator to use (default: newline)
  final String separator;

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

    // Split on separator first
    final splits = separator.isNotEmpty ? text.split(separator) : [text];

    return _mergeSplits(splits, opts);
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
            metadata: chunkMetadata,
            source: doc.source,
          ),
        );
      }
    }

    return result;
  }

  /// Merge splits into chunks of appropriate size
  List<String> _mergeSplits(List<String> splits, TextSplitterOptions options) {
    final chunks = <String>[];
    var currentChunk = '';

    for (final split in splits) {
      if (split.isEmpty) continue;

      final potentialChunk =
          currentChunk.isEmpty ? split : currentChunk + separator + split;

      if (potentialChunk.length <= options.chunkSize) {
        currentChunk = potentialChunk;
      } else {
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk);
        }

        // Handle overlap
        if (options.chunkOverlap > 0 && currentChunk.isNotEmpty) {
          final overlap = currentChunk.length > options.chunkOverlap
              ? currentChunk
                  .substring(currentChunk.length - options.chunkOverlap)
              : currentChunk;
          currentChunk = overlap + separator + split;
        } else {
          currentChunk = split;
        }
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk);
    }

    return chunks;
  }
}
