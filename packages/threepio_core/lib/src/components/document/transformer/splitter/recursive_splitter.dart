/// Splitting documents at a list of separators, tried one after the other,
/// into chunks of a maximum length.
///
/// Port of eino-ext `components/document/transformer/splitter/recursive`.
library;

import 'dart:collection';

import 'package:meta/meta.dart';

import '../../../../core/run_context.dart';
import '../../../../schema/document.dart';
import '../../../component_type.dart';
import '../../transformer.dart';
import 'split_id_generator.dart';

/// Where the recursive splitter puts the separator it cuts a text at.
///
/// Port of eino-ext `recursive.KeepType`.
enum SplitterKeepType {
  /// The separator is dropped: the chunks are joined back with it only
  /// where several pieces end up in one chunk. Port of `KeepTypeNone`.
  none,

  /// The separator stays at the start of the piece that follows it. Port of
  /// `KeepTypeStart`.
  start,

  /// The separator stays at the end of the piece that precedes it. Port of
  /// `KeepTypeEnd`.
  end,
}

/// The configuration of eino-ext's recursive splitter, created with
/// `RecursiveCharacterTextSplitter.fromConfig`.
///
/// Port of eino-ext `recursive.Config`:
///
/// ```dart
/// final splitter = RecursiveCharacterTextSplitter.fromConfig(
///   const RecursiveSplitterConfig(chunkSize: 1000, overlapSize: 100),
/// );
/// final chunks = await splitter.transform(documents);
/// ```
@immutable
final class RecursiveSplitterConfig {
  /// A configuration for chunks of at most [chunkSize] (as [lenFunc]
  /// measures them).
  const RecursiveSplitterConfig({
    required this.chunkSize,
    this.overlapSize = 0,
    this.separators,
    this.lenFunc,
    this.keepType = SplitterKeepType.none,
    this.idGenerator,
  });

  /// The length a chunk should stay below. Must be greater than zero. Port of
  /// `ChunkSize`.
  ///
  /// A piece that no remaining separator can cut becomes a chunk of its own,
  /// whatever its length.
  final int chunkSize;

  /// How much of the end of a chunk may be repeated at the start of the
  /// next one, which keeps a thought that is cut in two readable in both.
  /// Must not be negative; 0 (the default) means no overlap. Port of
  /// `OverlapSize`.
  final int overlapSize;

  /// The separators to cut at, tried in this order: a piece that is still
  /// too long is cut again at the separators after the one that cut it.
  /// `null` or empty means `['\n', '.', '?', '!']`. An empty string cuts
  /// between characters. Port of `Separators`.
  final List<String>? separators;

  /// Measures the length of a text. `null` means Go's `len`: the number of
  /// **UTF-8 bytes**, not of characters, so that a `chunkSize` means what it
  /// means in Eino (`'héllo'` has length 6). Pass `(text) => text.length` to
  /// count UTF-16 code units instead. Port of `LenFunc`.
  final int Function(String text)? lenFunc;

  /// Where the separators go; dropped by default. Port of `KeepType`.
  final SplitterKeepType keepType;

  /// Makes the ids of the chunks. `null` means every chunk keeps the id of
  /// its document. Port of `IDGenerator`.
  final SplitIdGenerator? idGenerator;
}

/// eino-ext's recursive splitter, as `RecursiveCharacterTextSplitter.fromConfig`
/// returns it.
///
/// Port of the unexported `recursive.splitter`. Every chunk is a new document
/// with the id from the config's `idGenerator`, the chunk as its content, a
/// copy of its document's metadata (a shallow one, as Go's `deepCopyMap`)
/// and its document's `source`; the input documents are left as they are.
@internal
final class RecursiveSplitterTransformer
    implements DocumentTransformer, TypedComponent {
  /// The splitter [config] describes.
  ///
  /// Port of eino-ext `recursive.NewSplitter`. Throws [ArgumentError] with
  /// Go's message when `chunkSize` is not positive or `overlapSize` is
  /// negative.
  RecursiveSplitterTransformer(RecursiveSplitterConfig config)
      : _chunkSize = config.chunkSize,
        _overlap = config.overlapSize,
        _separators = _separatorsOf(config.separators),
        _lenFunc = config.lenFunc ?? splitterUtf8Length,
        _keepType = config.keepType,
        _idGenerator = config.idGenerator ?? defaultSplitIdGenerator {
    if (config.chunkSize <= 0) {
      throw ArgumentError('chunk size must be greater than zero');
    }
    if (config.overlapSize < 0) {
      throw ArgumentError('overlap must be greater than or equal to zero');
    }
  }

  static const _defaultSeparators = ['\n', '.', '?', '!'];

  static List<String> _separatorsOf(List<String>? separators) =>
      separators == null || separators.isEmpty
          ? _defaultSeparators
          : List.unmodifiable(separators);

  final int _chunkSize;
  final int _overlap;
  final List<String> _separators;
  final int Function(String text) _lenFunc;
  final SplitterKeepType _keepType;
  final SplitIdGenerator _idGenerator;

  /// Port of `recursive.splitter.GetType`.
  @override
  String get componentTypeName => 'RecursiveSplitter';

  /// Cuts every document into chunks. Port of `splitter.Transform`.
  ///
  /// The `runContext` of [options] (or a background context) is what the
  /// id generator gets.
  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async {
    final ctx = options?.runContext ?? RunContext.background();
    final result = <Document>[];
    for (final doc in documents) {
      final splits = _splitText(doc.content, _separators);
      for (final (i, split) in splits.indexed) {
        result.add(
          Document(
            id: _idGenerator(ctx, doc.id, i),
            content: split,
            metadata: Map<String, dynamic>.of(doc.metadata),
            source: doc.source,
          ),
        );
      }
    }
    return result;
  }

  /// Port of `splitter.splitText`. The recursion goes one level deeper per
  /// separator, and every call works on a shorter list of separators, so it
  /// ends.
  List<String> _splitText(String text, List<String> separators) {
    final finalChunks = <String>[];

    // Find the appropriate separator.
    var separator = separators.last;
    var newSeparators = const <String>[];
    for (var i = 0; i < separators.length; i++) {
      final candidate = separators[i];
      if (candidate.isEmpty || text.contains(candidate)) {
        separator = candidate;
        newSeparators = separators.sublist(i + 1);
        break;
      }
    }

    final splits = _split(text, separator, _keepType);
    var goodSplits = <String>[];

    // Merge the splits, recursively splitting larger texts.
    for (final split in splits) {
      if (_lenFunc(split) < _chunkSize) {
        goodSplits.add(split);
        continue;
      }

      if (goodSplits.isNotEmpty) {
        finalChunks.addAll(_mergeSplits(goodSplits, separator, _keepType));
        goodSplits = <String>[];
      }

      if (newSeparators.isEmpty) {
        finalChunks.add(split);
      } else {
        finalChunks.addAll(_splitText(split, newSeparators));
      }
    }

    if (goodSplits.isNotEmpty) {
      finalChunks.addAll(_mergeSplits(goodSplits, separator, _keepType));
    }

    return finalChunks;
  }

  /// Port of `splitter.split`.
  static List<String> _split(
    String text,
    String separator,
    SplitterKeepType keepType,
  ) {
    switch (keepType) {
      case SplitterKeepType.none:
        return splitterGoSplit(text, separator);
      case SplitterKeepType.end:
        return splitterGoSplitAfter(text, separator);
      case SplitterKeepType.start:
        final splits = splitterGoSplit(text, separator);
        for (var i = 1; i < splits.length; i++) {
          splits[i] = separator + splits[i];
        }
        return splits;
    }
  }

  /// Merges small splits into chunks that come close to the chunk size.
  ///
  /// Port of `splitter.mergeSplits`. The inner loop removes one piece per
  /// round and stops when none is left, so it ends.
  List<String> _mergeSplits(
    List<String> splits,
    String separator,
    SplitterKeepType keepType,
  ) {
    final docs = <String>[];
    final currentDoc = ListQueue<String>();
    var total = 0;

    for (final split in splits) {
      var totalWithSplit = total + _lenFunc(split);
      if (currentDoc.isNotEmpty && keepType == SplitterKeepType.none) {
        totalWithSplit += _lenFunc(separator);
      }

      if (totalWithSplit > _chunkSize && currentDoc.isNotEmpty) {
        final doc = _joinDocs(currentDoc, separator, keepType);
        if (doc.isNotEmpty) docs.add(doc);

        while (_shouldPop(
          total,
          _lenFunc(split),
          _lenFunc(separator),
          currentDoc.length,
        )) {
          total -= _lenFunc(currentDoc.first);
          if (currentDoc.length > 1 && _keepType == SplitterKeepType.none) {
            total -= _lenFunc(separator);
          }
          currentDoc.removeFirst();
        }
      }

      currentDoc.add(split);
      total += _lenFunc(split);
      if (currentDoc.length > 1 && keepType == SplitterKeepType.none) {
        total += _lenFunc(separator);
      }
    }

    final doc = _joinDocs(currentDoc, separator, keepType);
    if (doc.isNotEmpty) docs.add(doc);

    return docs;
  }

  /// Port of `splitter.shouldPop`.
  bool _shouldPop(int total, int splitLen, int separatorLen, int docCount) {
    const docsNeededToAddSep = 2;
    final sepLen = docCount < docsNeededToAddSep ? 0 : separatorLen;
    if (_keepType == SplitterKeepType.none) {
      return docCount > 0 &&
          (total > _overlap ||
              (total + splitLen + sepLen > _chunkSize && total > 0));
    }
    return docCount > 0 &&
        (total > _overlap || (total + splitLen > _chunkSize && total > 0));
  }

  /// Port of `joinDocs`.
  static String _joinDocs(
    Iterable<String> docs,
    String separator,
    SplitterKeepType keepType,
  ) =>
      splitterGoTrimSpace(
        docs.join(keepType == SplitterKeepType.none ? separator : ''),
      );

  @override
  String toString() => 'RecursiveSplitterTransformer(chunkSize: $_chunkSize, '
      'overlapSize: $_overlap, keepType: ${_keepType.name})';
}
