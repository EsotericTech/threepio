/// Splitting markdown documents at their headers, with the text of the
/// enclosing headers as metadata of every chunk.
///
/// Port of eino-ext `components/document/transformer/splitter/markdown`.
library;

import 'package:meta/meta.dart';

import '../../../../core/run_context.dart';
import '../../../../schema/document.dart';
import '../../../component_type.dart';
import '../../transformer.dart';
import 'split_id_generator.dart';

/// The configuration of eino-ext's markdown header splitter, created with
/// `MarkdownSplitter.fromHeaderConfig`.
///
/// Port of eino-ext `markdown.HeaderConfig`. With
///
/// ```dart
/// final splitter = MarkdownSplitter.fromHeaderConfig(
///   const MarkdownHeaderSplitterConfig(
///     headers: {'#': 'title', '##': 'section'},
///   ),
/// );
/// ```
///
/// the document `'# Guide\nintro\n## Setup\nsteps'` gives the chunks
/// `'# Guide\nintro'` with metadata `{'title': 'Guide'}` and
/// `'## Setup\nsteps'` with `{'title': 'Guide', 'section': 'Setup'}`.
@immutable
final class MarkdownHeaderSplitterConfig {
  /// A configuration that cuts at the headers named in [headers].
  const MarkdownHeaderSplitterConfig({
    required this.headers,
    this.trimHeaders = false,
    this.idGenerator,
  });

  /// The headers to cut at, each a run of `#` (its level is its length),
  /// mapped to the metadata key under which the chunks below it get the
  /// header's text. Must not be empty. Port of `Headers`.
  ///
  /// A line is a header when, after trimming, it starts with exactly one of
  /// these runs followed by a space or by nothing. Lines inside a fenced code
  /// block (```` ``` ```` or `~~~`) are never headers.
  final Map<String, String> headers;

  /// Whether the header lines are left out of the chunks. Port of
  /// `TrimHeaders`.
  final bool trimHeaders;

  /// Makes the ids of the chunks. `null` means every chunk keeps the id of
  /// its document. Port of `IDGenerator`.
  final SplitIdGenerator? idGenerator;
}

/// eino-ext's markdown header splitter, as `MarkdownSplitter.fromHeaderConfig`
/// returns it.
///
/// Port of the unexported `markdown.headerSplitter`. Every chunk is a new
/// document with the id from the config's `idGenerator`, the chunk as its
/// content, a copy of its document's metadata (a shallow one, as Go's
/// `deepCopyAnyMap`) with the texts of the headers above the chunk added,
/// and its document's `source`; the input documents are left as they are.
///
/// Lines are trimmed (Go's `strings.TrimSpace`), empty lines are dropped, and
/// every document gives at least one chunk: the text after its last header,
/// which may be empty.
@internal
final class MarkdownHeaderSplitterTransformer
    implements DocumentTransformer, TypedComponent {
  /// The splitter [config] describes.
  ///
  /// Port of eino-ext `markdown.NewHeaderSplitter`. Throws [ArgumentError]
  /// with Go's message when `headers` is empty (`no headers specified`) or a
  /// header is not made of `#` only (`header can only consist of '#': …`;
  /// the first such header in the map's order, where Go names a random one).
  MarkdownHeaderSplitterTransformer(MarkdownHeaderSplitterConfig config)
      : _headers = Map.unmodifiable(config.headers),
        _trimHeaders = config.trimHeaders,
        _idGenerator = config.idGenerator ?? defaultSplitIdGenerator {
    if (config.headers.isEmpty) {
      throw ArgumentError('no headers specified');
    }
    for (final header in config.headers.keys) {
      for (final unit in header.codeUnits) {
        if (unit != _hash) {
          throw ArgumentError("header can only consist of '#': $header");
        }
      }
    }
  }

  static const _hash = 0x23; // '#'
  static const _space = 0x20; // ' '
  static const _codeSep1 = '```';
  static const _codeSep2 = '~~~';

  final Map<String, String> _headers;
  final bool _trimHeaders;
  final SplitIdGenerator _idGenerator;

  /// Port of `markdown.headerSplitter.GetType`.
  @override
  String get componentTypeName => 'MarkdownHeaderSplitter';

  /// Cuts every document at its headers. Port of `headerSplitter.Transform`.
  ///
  /// The `runContext` of [options] (or a background context) is what the
  /// id generator gets. The metadata of a chunk holds its document's entries
  /// first and then the header entries, in the order the headers were met
  /// (an entry of the document with the same key as a header is
  /// overwritten, as in Go).
  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async {
    final ctx = options?.runContext ?? RunContext.background();
    final result = <Document>[];
    for (final doc in documents) {
      final splits = _splitText(doc.content);
      for (final (i, split) in splits.indexed) {
        result.add(
          Document(
            id: _idGenerator(ctx, doc.id, i),
            content: split.chunk,
            metadata: <String, dynamic>{...doc.metadata, ...split.meta},
            source: doc.source,
          ),
        );
      }
    }
    return result;
  }

  /// Port of `headerSplitter.splitText`.
  List<_SplitResult> _splitText(String text) {
    final recordedMetaList = <_MetaRecord>[];
    final recordedMetaMap = <String, String>{};
    final currentLines = <String>[];
    var inCodeBlock = false;
    var openingFence = '';
    final result = <_SplitResult>[];
    for (final rawLine in text.split('\n')) {
      if (rawLine.isEmpty) continue;
      final line = splitterGoTrimSpace(rawLine);
      if (!inCodeBlock) {
        if (line.startsWith(_codeSep1) && _count(line, _codeSep1) == 1) {
          inCodeBlock = true;
          openingFence = _codeSep1;
        } else if (line.startsWith(_codeSep2)) {
          inCodeBlock = true;
          openingFence = _codeSep2;
        }
      } else if (line.startsWith(openingFence)) {
        inCodeBlock = false;
        openingFence = '';
      }
      if (inCodeBlock) {
        currentLines.add(line);
        continue;
      }
      // Check whether the line starts with a header. At most one header can
      // match (they are runs of '#' and must be followed by a space or the
      // end of the line), so the order of the map does not matter.
      var newHeader = false;
      for (final MapEntry(key: header, value: name) in _headers.entries) {
        if (line.startsWith(header) &&
            (line.length == header.length ||
                line.codeUnitAt(header.length) == _space)) {
          if (currentLines.isNotEmpty) {
            result.add(
              _SplitResult(currentLines.join('\n'), Map.of(recordedMetaMap)),
            );
            currentLines.clear();
          }

          if (!_trimHeaders) currentLines.add(line);

          final newLevel = header.length;
          for (var i = recordedMetaList.length - 1; i >= 0; i--) {
            if (recordedMetaList[i].level >= newLevel) {
              recordedMetaMap.remove(recordedMetaList[i].name);
              recordedMetaList.removeRange(i, recordedMetaList.length);
            } else {
              break;
            }
          }

          final data = splitterGoTrimSpace(line.substring(header.length));
          recordedMetaList.add(_MetaRecord(name, newLevel));
          recordedMetaMap[name] = data;

          newHeader = true;
          break;
        }
      }
      if (!newHeader) currentLines.add(line);
    }
    result.add(_SplitResult(currentLines.join('\n'), Map.of(recordedMetaMap)));
    return result;
  }

  /// The number of non-overlapping occurrences of [pattern] in [text] (Go's
  /// `strings.Count` for a non-empty pattern).
  static int _count(String text, String pattern) {
    var count = 0;
    var start = 0;
    while (true) {
      final index = text.indexOf(pattern, start);
      if (index < 0) return count;
      count++;
      start = index + pattern.length;
    }
  }

  @override
  String toString() => 'MarkdownHeaderSplitterTransformer(headers: $_headers, '
      'trimHeaders: $_trimHeaders)';
}

/// One chunk and the header texts above it. Port of `splitResult`.
final class _SplitResult {
  const _SplitResult(this.chunk, this.meta);

  final String chunk;
  final Map<String, String> meta;
}

/// A header that is in effect. Port of `metaRecord` (whose `data` field Go
/// writes but never reads).
final class _MetaRecord {
  const _MetaRecord(this.name, this.level);

  final String name;
  final int level;
}
