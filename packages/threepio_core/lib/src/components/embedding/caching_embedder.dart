/// An embedder that keeps the vectors it has made and reuses them.
///
/// Port of eino-ext `components/embedding/cache` (`embedding.go`).
library;

import 'package:logging/logging.dart';

import '../../core/interrupt_signal.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import 'embedder.dart';
import 'embedding_cache.dart';

final _log = Logger('threepio.embedding');

/// Wraps an [Embedder] and caches its vectors: a text whose vector is in
/// the [cache] is not embedded again.
///
/// Port of eino-ext `cache.Embedder` (`cache.NewEmbedder` with `WithCacher`,
/// `WithGenerator` and `WithExpiration`). Go returns `ErrCacherRequired` or
/// `ErrGeneratorRequired` when an option is missing; here [cache] and
/// [keyGenerator] are required parameters.
///
/// ```dart
/// final embedder = CachingEmbedder(
///   OpenAIEmbedder(config: config),
///   cache: InMemoryEmbeddingCache(maxEntries: 10000),
///   keyGenerator: const SimpleCacheKeyGenerator(),
/// );
/// ```
///
/// [embedStrings] works as Go's `EmbedStrings`:
/// * it looks up every text, one after the other, under the key
///   [keyGenerator] makes from the text and the model of the call
///   (`options.model`, or the empty string);
/// * the texts that are not cached are embedded with one call to
///   [embedder], in their order and with the options of the call passed on
///   as they are. A text that appears twice and is not cached is embedded
///   twice; nothing is deduplicated;
/// * each new vector is stored for [expiration]; a store that fails is
///   ignored (and logged), the vector is still returned;
/// * a cache lookup that fails, or a failure of [embedder], fails the call.
///
/// The vectors come back in the order of the texts, cached and new ones
/// mixed. When [embedder] returns fewer vectors than it was given texts, the
/// call throws a [ThreepioException] (Go panics with an index out of range);
/// extra vectors are ignored, as in Go.
///
/// Like Go's `cache.Embedder`, this embedder names no implementation type
/// and fires no callbacks of its own: it is neither a `TypedComponent` nor a
/// `CallbackAwareComponent`. A graph therefore reports an embedding node made
/// of it with the start and end callbacks of the node itself; [embedder]
/// reports its own calls, for the texts that missed the cache only, through
/// the run context it is passed in the options.
final class CachingEmbedder implements Embedder {
  /// Caches the vectors of [embedder] in [cache] under the keys
  /// [keyGenerator] makes, each for [expiration].
  CachingEmbedder(
    this.embedder, {
    required this.cache,
    required this.keyGenerator,
    this.expiration = defaultExpiration,
  });

  /// How long a vector stays cached unless [expiration] says otherwise: two
  /// hours, as in Go.
  static const Duration defaultExpiration = Duration(hours: 2);

  /// The embedder that makes the vectors that are not cached.
  final Embedder embedder;

  /// Where the vectors are kept. Port of the `WithCacher` option.
  final EmbeddingCache cache;

  /// Makes the key of a text. Port of the `WithGenerator` option.
  final CacheKeyGenerator keyGenerator;

  /// How long a new vector stays cached. Port of the `WithExpiration`
  /// option; zero or less keeps it without a time limit (see
  /// [EmbeddingCache.set]).
  final Duration expiration;

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    final ctx = options?.runContext ?? RunContext.background();
    final keyOptions = CacheKeyOptions(model: options?.model ?? '');
    final vectors = List<List<double>?>.filled(texts.length, null);
    final missedIndexes = <int>[];
    final missedTexts = <String>[];
    // Go generates every missed key a second time before storing it; the
    // key of the lookup is kept instead (generators are deterministic).
    final missedKeys = <String>[];

    for (var i = 0; i < texts.length; i++) {
      final key = keyGenerator.generate(ctx, texts[i], keyOptions);
      final cached = await cache.get(ctx, key);
      if (cached != null) {
        vectors[i] = cached;
      } else {
        missedIndexes.add(i);
        missedTexts.add(texts[i]);
        missedKeys.add(key);
      }
    }

    if (missedTexts.isNotEmpty) {
      final embedded = await embedder.embedStrings(missedTexts, options: options);
      if (embedded.length < missedTexts.length) {
        throw ThreepioException(
          'embedding/cache: the embedder returned ${embedded.length} '
          'vectors for ${missedTexts.length} texts',
        );
      }
      for (var j = 0; j < missedIndexes.length; j++) {
        final vector = embedded[j];
        try {
          await cache.set(ctx, missedKeys[j], vector, expiration);
        } catch (error, stackTrace) {
          if (isInterrupt(error)) rethrow;
          // Go: "skip caching if there's an error".
          _log.warning(
            'embedding/cache: could not cache a vector, it is returned '
            'uncached',
            error,
            stackTrace,
          );
        }
        vectors[missedIndexes[j]] = vector;
      }
    }

    return [for (final vector in vectors) vector!];
  }
}
