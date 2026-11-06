/// Where a caching embedder keeps its vectors, and how it names them.
///
/// Port of eino-ext `components/embedding/cache` (`cacher.go`,
/// `generator.go`). The embedder itself is `CachingEmbedder`; a backend that
/// keeps the vectors on disk is `FileEmbeddingCache` (`package:threepio_core/
/// io.dart`).
library;

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:meta/meta.dart';

import '../../core/run_context.dart';

/// Stores embedding vectors under a key, each for a limited time.
///
/// Port of eino-ext `cache.Cacher`. [InMemoryEmbeddingCache] keeps the
/// vectors in memory, `FileEmbeddingCache` in a directory. The Redis backend
/// of eino-ext (`cache/redis`) is not ported.
///
/// Both methods take the context of the call first, as Go's do; a
/// `CachingEmbedder` passes the run context of its options (or a background
/// context when there is none).
abstract interface class EmbeddingCache {
  /// Stores [vector] under [key] for [expiration], replacing whatever was
  /// stored under [key] before.
  ///
  /// An [expiration] of zero or less stores the vector without a time limit,
  /// as Redis `SET` without `EX` does for the Go backend. The caches of this
  /// package also treat an expiration of 10,000 years or more as no limit
  /// (such dates are out of the range of `DateTime` or close to it).
  Future<void> set(
    RunContext ctx,
    String key,
    List<double> vector,
    Duration expiration,
  );

  /// The vector stored under [key], or `null` when there is none or it has
  /// expired.
  ///
  /// Throws when what is stored under [key] cannot be read as a vector (Go:
  /// "If the value is not of type []float64, it returns an error").
  Future<List<double>?> get(RunContext ctx, String key);
}

/// What a [CacheKeyGenerator] takes into account besides the text.
///
/// Port of eino-ext `cache.GeneratorOption`.
@immutable
final class CacheKeyOptions {
  /// Options for the vectors of [model]; the empty string (Go's zero value)
  /// when the call names no model.
  const CacheKeyOptions({this.model = ''});

  /// The embedding model the vector is made with, as the options of the
  /// embedding call name it.
  final String model;

  @override
  bool operator ==(Object other) =>
      other is CacheKeyOptions && other.model == model;

  @override
  int get hashCode => model.hashCode;

  @override
  String toString() => 'CacheKeyOptions(model: $model)';
}

/// Turns a text and the options of an embedding call into the key its vector
/// is cached under.
///
/// Port of eino-ext `cache.Generator`. The same text and options must always
/// give the same key, and different ones should give different keys.
// One member is the whole contract, as in eino-ext.
// ignore: one_member_abstracts
abstract interface class CacheKeyGenerator {
  /// The cache key of the vector of [text] made with [options].
  String generate(RunContext ctx, String text, CacheKeyOptions options);
}

/// The key `'<text>-<model>'`, the text and the model as they are.
///
/// Port of eino-ext `cache.SimpleGenerator` (`cache.NewSimpleGenerator`).
/// The key contains the whole text, so long texts make long keys; use a
/// [HashCacheKeyGenerator] where that matters.
final class SimpleCacheKeyGenerator implements CacheKeyGenerator {
  /// The generator. It has no state.
  const SimpleCacheKeyGenerator();

  @override
  String generate(RunContext ctx, String text, CacheKeyOptions options) =>
      '$text-${options.model}';
}

/// The lowercase hex of a hash of the [SimpleCacheKeyGenerator] key.
///
/// Port of eino-ext `cache.HashGenerator` (`cache.NewHashGenerator`). Go
/// takes a `hash.Hash`; this package has no cryptography dependency, so the
/// hash function is passed in: `HashCacheKeyGenerator((bytes) =>
/// sha256.convert(bytes).bytes)` with `package:crypto`, for example. It is
/// given the UTF-8 bytes of `'<text>-<model>'` and must return bytes (values
/// from 0 to 255).
///
/// As in Go, two different texts can hash to the same key, and then one
/// text is given the other's vector; choose a hash whose collisions do not
/// matter for your data.
///
/// Deviation: Go's `Generate` returns `fmt.Sprintf("%x",
/// g.hasher.Sum([]byte(plainText)))`. `hash.Hash.Sum(b)` appends the hash of
/// what has been written to the hasher (nothing, here) to `b`, so the Go key
/// is the hex of the plain text followed by the hex of the hash of no input:
/// the text is never hashed, and the key grows with it. The Go tests only
/// pin that keys are stable, distinct and not empty, so this port does what
/// the type documents and returns the hex of the hash of the plain text.
/// Keys made by Go's generator therefore differ from the keys made here.
final class HashCacheKeyGenerator implements CacheKeyGenerator {
  /// A generator that hashes keys with [hash].
  const HashCacheKeyGenerator(this.hash);

  /// The hash function: the bytes of a plain key in, the digest out.
  final List<int> Function(List<int> bytes) hash;

  static const _plain = SimpleCacheKeyGenerator();

  /// Throws an [ArgumentError] when [hash] returns a value that is not a
  /// byte.
  @override
  String generate(RunContext ctx, String text, CacheKeyOptions options) {
    final plain = _plain.generate(ctx, text, options);
    return _hex(hash(utf8.encode(plain)));
  }
}

/// Keeps vectors in memory, each until it expires.
///
/// An implementation of [EmbeddingCache] written for the port (eino-ext only
/// has a Redis backend). Expiry follows `clock` from `package:clock`, so
/// `package:fake_async` can drive it in tests.
///
/// An expired vector is dropped when it is read, when [removeExpired] runs,
/// or when the cache is full. With [maxEntries] the cache holds at most that
/// many vectors: to make room it drops the expired ones, then the least
/// recently used one (read or stored). Without it the cache grows with every
/// new key.
///
/// The cache keeps its own copy of every vector and [get] returns a fresh
/// copy, so neither the caller nor the cache sees the other change a vector.
final class InMemoryEmbeddingCache implements EmbeddingCache {
  /// An empty cache that holds at most [maxEntries] vectors, or any number
  /// when it is `null`.
  ///
  /// Throws an [ArgumentError] when [maxEntries] is less than one.
  InMemoryEmbeddingCache({this.maxEntries}) {
    final max = maxEntries;
    if (max != null && max < 1) {
      throw ArgumentError.value(max, 'maxEntries', 'must be at least 1');
    }
  }

  /// The most vectors the cache holds, or `null` for no limit.
  final int? maxEntries;

  /// 10,000 years: from here on an expiration means no time limit.
  static const _noLimitFrom = Duration(days: 3652500);

  // A LinkedHashMap: iteration order is the order of last use, oldest first.
  final Map<String, _MemoryEntry> _entries = {};

  /// The number of vectors held, expired ones that have not been dropped yet
  /// included.
  int get length => _entries.length;

  @override
  Future<void> set(
    RunContext ctx,
    String key,
    List<double> vector,
    Duration expiration,
  ) async {
    _entries
      ..remove(key)
      ..[key] = _MemoryEntry(
        List<double>.unmodifiable(vector),
        expiration > Duration.zero && expiration < _noLimitFrom
            ? clock.now().add(expiration)
            : null,
      );
    final max = maxEntries;
    if (max == null || _entries.length <= max) return;
    removeExpired();
    while (_entries.length > max) {
      _entries.remove(_entries.keys.first);
    }
  }

  @override
  Future<List<double>?> get(RunContext ctx, String key) async {
    final entry = _entries.remove(key);
    if (entry == null || entry.isExpiredAt(clock.now())) return null;
    _entries[key] = entry;
    return List<double>.of(entry.vector);
  }

  /// Drops every expired vector and returns how many there were.
  int removeExpired() {
    final now = clock.now();
    final before = _entries.length;
    _entries.removeWhere((_, entry) => entry.isExpiredAt(now));
    return before - _entries.length;
  }
}

final class _MemoryEntry {
  const _MemoryEntry(this.vector, this.expiresAt);

  final List<double> vector;

  /// `null`: never expires.
  final DateTime? expiresAt;

  bool isExpiredAt(DateTime now) {
    final at = expiresAt;
    return at != null && !now.isBefore(at);
  }
}

/// Lowercase hex, two digits per byte, like Go's `%x` on a `[]byte`.
String _hex(List<int> bytes) {
  final out = StringBuffer();
  for (final byte in bytes) {
    if (byte < 0 || byte > 0xff) {
      throw ArgumentError.value(byte, 'hash', 'returned a value that is not a byte');
    }
    out.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}
