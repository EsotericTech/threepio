/// Splitting documents where the meaning changes, measured by the distance
/// between the embeddings of neighbouring sentences.
///
/// Port of eino-ext `components/document/transformer/splitter/semantic`.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/document.dart';
import '../../component_type.dart';
import '../../embedding/embedder.dart';
import '../../model/cancel_token.dart';
import '../transformer.dart';
import 'splitter/split_id_generator.dart';

/// The configuration of a [SemanticSplitter].
///
/// Port of eino-ext `semantic.Config`.
@immutable
final class SemanticSplitterConfig {
  /// A configuration that embeds the sentences with [embedding].
  const SemanticSplitterConfig({
    required this.embedding,
    this.bufferSize = 0,
    this.minChunkSize = 0,
    this.separators,
    this.lenFunc,
    this.percentile = 0,
    this.idGenerator,
  });

  /// Embeds the sentences, so that the distance between neighbours can be
  /// measured. Port of `Embedding` (Go rejects a nil one; here the type
  /// rules it out).
  final Embedder embedding;

  /// How many sentences before and after a sentence are embedded together
  /// with it, which gives every vector more context and the distances more
  /// accuracy. Port of `BufferSize`.
  final int bufferSize;

  /// The length (as [lenFunc] measures it) below which a chunk is not cut
  /// off but grows into the next one. The last chunk of a document may stay
  /// shorter. Port of `MinChunkSize`.
  final int minChunkSize;

  /// The separators that cut the text into sentences, each kept at the end
  /// of its sentence. Every separator cuts the pieces the previous ones made.
  /// `null` or empty means `['\n', '.', '?', '!']`. Port of `Separators`.
  final List<String>? separators;

  /// Measures the length of a text. `null` means Go's `len`: the number of
  /// **UTF-8 bytes**, not of characters. Port of `LenFunc`.
  final int Function(String text)? lenFunc;

  /// Where to cut: between two sentences whose distance is at least the
  /// distance at this fraction of the sorted distances (0.9: only the 10 %
  /// largest jumps cut). 0, the default, means 0.9; above 1 means the
  /// largest distance only. Port of `Percentile`.
  ///
  /// A negative value (at or below -1 divided by the number of distances)
  /// or NaN makes `transform` throw [ArgumentError], where Go panics.
  final double percentile;

  /// Makes the ids of the chunks. `null` means every chunk keeps the id of
  /// its document. Port of `IDGenerator`.
  final SplitIdGenerator? idGenerator;
}

/// Cuts documents into chunks of related sentences: it embeds every
/// sentence (with its neighbours) and cuts where the cosine distance between
/// two consecutive sentences is among the largest.
///
/// Port of eino-ext `semantic.NewSplitter`:
///
/// ```dart
/// final splitter = SemanticSplitter(
///   SemanticSplitterConfig(embedding: embedder, bufferSize: 1, minChunkSize: 100),
/// );
/// final chunks = await splitter.transform(documents);
/// ```
///
/// A document's text is cut after every separator, so no text is lost: the
/// chunks of a document, concatenated, are its content. A document that
/// gives one sentence is one chunk and is not embedded. Every chunk is a new
/// document with the id from the config's `idGenerator`, the chunk as its
/// content, a copy of its document's metadata (a shallow one, as Go's
/// `deepCopyMap`) and its document's `source`; the input documents are left
/// as they are.
///
/// The cosine distance between two vectors of which one is all zeros is NaN,
/// as in Go: it never reaches a threshold, and a NaN threshold (more than
/// [SemanticSplitterConfig.percentile] of the distances being NaN, sorted
/// first as Go's `sort.Float64s` sorts them) cuts nowhere.
final class SemanticSplitter implements DocumentTransformer, TypedComponent {
  /// A splitter configured by [config].
  SemanticSplitter(SemanticSplitterConfig config)
      : _embedding = config.embedding,
        _bufferSize = config.bufferSize,
        _minChunkSize = config.minChunkSize,
        _separators = _separatorsOf(config.separators),
        _lenFunc = config.lenFunc ?? splitterUtf8Length,
        _percentile = config.percentile == 0 ? 0.9 : config.percentile,
        _idGenerator = config.idGenerator ?? defaultSplitIdGenerator;

  static const _defaultSeparators = ['\n', '.', '?', '!'];

  static List<String> _separatorsOf(List<String>? separators) =>
      separators == null || separators.isEmpty
          ? _defaultSeparators
          : List.unmodifiable(separators);

  final Embedder _embedding;
  final int _bufferSize;
  final int _minChunkSize;
  final List<String> _separators;
  final int Function(String text) _lenFunc;
  final double _percentile;
  final SplitIdGenerator _idGenerator;

  /// Port of `semantic.splitter.GetType`.
  @override
  String get componentTypeName => 'SemanticSplitter';

  /// Cuts every document into chunks of related sentences. Port of
  /// `splitter.Transform`.
  ///
  /// The `runContext` of [options] (or a background context) is what the
  /// embedder gets, in `EmbedderOptions.runContext`, and what the id
  /// generator gets. The embedder is called once per document that has more
  /// than one sentence.
  ///
  /// Throws [ThreepioException] `split document[<id>] fail: <cause>` when
  /// the embedder fails (its exception is the cause) or returns fewer
  /// vectors than sentences, or a vector shorter than the one before it
  /// (where Go panics). An interrupt, a [CancelledException] and an [Error]
  /// are rethrown as they are.
  @override
  Future<List<Document>> transform(
    List<Document> documents, {
    TransformerOptions? options,
  }) async {
    final ctx = options?.runContext ?? RunContext.background();
    final result = <Document>[];
    for (final doc in documents) {
      final List<String> splits;
      try {
        splits = await _splitText(ctx, doc.content, _separators);
        // Whatever the embedder throws is wrapped, as Go wraps its error.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        if (error is Error ||
            error is CancelledException ||
            isInterrupt(error)) {
          rethrow;
        }
        Error.throwWithStackTrace(
          ThreepioException(
            'split document[${doc.id ?? ''}] fail: ${_messageOf(error)}',
            cause: error,
          ),
          stackTrace,
        );
      }
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

  /// Port of `splitter.splitText`.
  Future<List<String>> _splitText(
    RunContext ctx,
    String text,
    List<String> separators,
  ) async {
    var texts = [text];
    // Split. Go loops over the splitter's separators and indexes the
    // parameter; the two are the same list.
    for (var i = 0; i < _separators.length; i++) {
      texts = _splitTexts(texts, separators[i]);
    }

    // Go measures every sentence here and never uses the lengths; the calls
    // are kept for a lenFunc that counts them.
    for (final sentence in texts) {
      _lenFunc(sentence);
    }

    if (texts.length == 1) return texts;
    // Only an empty text cut with an empty separator gives no sentence at
    // all. Go panics on it after calling the embedder with no texts; here
    // the empty document is one empty chunk, as with any other separator.
    if (texts.isEmpty) return [text];

    // Combine: every sentence with up to bufferSize sentences before and
    // after it. Go appends and prepends them one by one; the result is the
    // window joined in order.
    final reach =
        _bufferSize <= 0 ? 0 : math.min(_bufferSize, texts.length);
    final combinedSentences = List<String>.generate(
      texts.length,
      (i) => texts
          .sublist(math.max(0, i - reach), math.min(texts.length, i + reach + 1))
          .join(),
    );

    // Embed.
    final vectors = await _embedding.embedStrings(
      combinedSentences,
      options: EmbedderOptions(runContext: ctx),
    );
    if (vectors.length < texts.length) {
      throw ThreepioException(
        'embedding returned ${vectors.length} vectors for '
        '${texts.length} texts',
      );
    }

    // Cosine distances.
    final distances = List<double>.filled(texts.length, 0);
    for (var i = 1; i < texts.length; i++) {
      distances[i] = 1 - _cosine(vectors[i - 1], vectors[i]);
    }

    final threshold = _calThreshold(distances.sublist(1), _percentile);
    final splitIndexes = <int>[];
    for (var i = 1; i < distances.length; i++) {
      if (distances[i] >= threshold) splitIndexes.add(i);
    }
    final chunks = <String>[];
    var startIndex = 0;
    for (final splitIndex in splitIndexes) {
      final chunk = texts.sublist(startIndex, splitIndex).join();
      if (_lenFunc(chunk) < _minChunkSize) continue;
      chunks.add(chunk);
      startIndex = splitIndex;
    }
    chunks.add(texts.sublist(startIndex).join());
    return chunks;
  }

  @override
  String toString() => 'SemanticSplitter(bufferSize: $_bufferSize, '
      'minChunkSize: $_minChunkSize, percentile: $_percentile)';
}

/// Port of `cosine`: NaN when either vector is all zeros.
double _cosine(List<double> vec1, List<double> vec2) {
  final dotProduct = _dot(vec1, vec2);
  final normVec1 = math.sqrt(_dot(vec1, vec1));
  final normVec2 = math.sqrt(_dot(vec2, vec2));
  return dotProduct / (normVec1 * normVec2);
}

/// Port of `dot`: the entries of [y] beyond the length of [x] are ignored,
/// and a [y] shorter than [x] throws (Go panics).
double _dot(List<double> x, List<double> y) {
  if (y.length < x.length) {
    throw ThreepioException(
      'embedding returned vectors of different lengths '
      '(${x.length} and ${y.length})',
    );
  }
  var sum = 0.0;
  for (var i = 0; i < x.length; i++) {
    sum += y[i] * x[i];
  }
  return sum;
}

/// Port of `splitTexts`: every text cut after [separator].
List<String> _splitTexts(List<String> texts, String separator) => [
      for (final text in texts) ...splitterGoSplitAfter(text, separator),
    ];

/// The distance at [percentile] of the sorted [distances]. Port of
/// `calThreshold`.
///
/// The distances are sorted as Go's `sort.Float64s` sorts them: NaN first,
/// then increasing. The index is `percentile * length` truncated toward
/// zero, at most the last one. Go indexes out of range (a panic) when the
/// truncated index is negative; that, and a NaN index (which Go turns into
/// a platform-dependent integer), throws [ArgumentError] here.
double _calThreshold(List<double> distances, double percentile) {
  final sorted = List.of(distances)..sort(_compareGoFloat64);
  final length = sorted.length;
  final position = percentile * length;
  if (position.isNaN || position <= -1) {
    throw ArgumentError.value(
      percentile,
      'percentile',
      'gives no index into $length distances',
    );
  }
  final index = position >= length ? length - 1 : position.truncate();
  return sorted[index];
}

/// The order of Go's `sort.Float64Slice`: NaN before every number, the
/// numbers in increasing order (-0.0 and 0.0 equal).
int _compareGoFloat64(double a, double b) {
  if (a < b) return -1;
  if (a > b) return 1;
  if (a.isNaN) return b.isNaN ? 0 : -1;
  if (b.isNaN) return 1;
  return 0;
}

/// How Go's `%w` prints [error]: a threepio exception by its message.
String _messageOf(Object error) =>
    error is ThreepioException ? error.message : '$error';
