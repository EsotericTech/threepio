// Port of eino-ext `components/embedding/cache/generator_test.go`
// (TestGenerator_UniquenessAndDifference, TestGenerator_SimpleGenerator,
// TestGenerator_HashGenerator), plus tests written for the port of the
// in-memory cache (eino-ext has none; its Redis backend, `cache/redis`, is not
// ported) with fake_async driving the expiry.
//
// The Go tests hash with crypto/sha256 and crypto/md5; this package has no
// cryptography dependency, so they use the FNV-1a hashes below (8 and 16
// bytes) in their place. What the Go tests assert does not depend on the
// hash.
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/embedding/embedding_cache.dart';
import 'package:threepio_core/threepio_core.dart' show RunContext;

/// 64-bit FNV-1a of [bytes] as 8 bytes, big-endian.
List<int> _fnv64(List<int> bytes) {
  var hash = (0xcbf29ce4 << 32) | 0x84222325;
  for (final byte in bytes) {
    hash = (hash ^ byte) * 0x100000001b3;
  }
  return [for (var shift = 56; shift >= 0; shift -= 8) (hash >> shift) & 0xff];
}

/// 16 bytes: the FNV-1a of [bytes] and of [bytes] reversed.
List<int> _fnv128(List<int> bytes) =>
    [..._fnv64(bytes), ..._fnv64(bytes.reversed.toList())];

/// The value [future] has completed with once the microtasks have run.
T _now<T>(FakeAsync async, Future<T> future) {
  late T value;
  var done = false;
  future.then((v) {
    value = v;
    done = true;
  });
  async.flushMicrotasks();
  expect(done, isTrue, reason: 'the future did not complete');
  return value;
}

void main() {
  final ctx = RunContext.background();

  group('TestGenerator_UniquenessAndDifference', () {
    const opt = CacheKeyOptions();
    final generators = <String, CacheKeyGenerator>{
      'SimpleGenerator': const SimpleCacheKeyGenerator(),
      'HashGenerator': const HashCacheKeyGenerator(_fnv128),
    };

    for (final MapEntry(key: name, value: generator) in generators.entries) {
      group(name, () {
        test('Generate uniqueness', () {
          final callbacks = <String Function()>[
            () => generator.generate(ctx, 'foo', opt),
            () => generator.generate(
                  ctx,
                  'foo',
                  const CacheKeyOptions(model: 'bar'),
                ),
          ];
          for (final callback in callbacks) {
            expect(callback(), callback());
          }
        });

        test('Generate different keys', () {
          expect(
            generator.generate(ctx, 'foo', opt),
            isNot(generator.generate(ctx, 'bar', opt)),
          );
          expect(
            generator.generate(ctx, 'foo', opt),
            isNot(generator.generate(
              ctx,
              'foo',
              const CacheKeyOptions(model: 'bar'),
            )),
          );
          expect(
            generator.generate(ctx, 'foo', const CacheKeyOptions(model: 'bar')),
            isNot(generator.generate(
              ctx,
              'foo',
              const CacheKeyOptions(model: 'baz'),
            )),
          );
        });
      });
    }
  });

  test('TestGenerator_SimpleGenerator', () {
    const text = 'test text';
    const model = 'test-model';
    const opt = CacheKeyOptions();
    const generator = SimpleCacheKeyGenerator();

    expect(
      generator.generate(ctx, text, const CacheKeyOptions(model: model)),
      '$text-$model',
    );
    expect(generator.generate(ctx, text, opt), '$text-');
    expect(generator.generate(ctx, '', opt), '-');
  });

  group('TestGenerator_HashGenerator', () {
    const text = 'test text';
    const model = 'test-model';
    final hashes = <String, List<int> Function(List<int>)>{
      // Go: sha256.New() and md5.New().
      'sha256': _fnv64,
      'md5': _fnv128,
    };
    for (final MapEntry(key: name, value: hash) in hashes.entries) {
      test(name, () {
        final generator = HashCacheKeyGenerator(hash);
        expect(
          generator.generate(ctx, text, const CacheKeyOptions(model: model)),
          isNotEmpty,
        );
      });
    }
  });

  group('HashCacheKeyGenerator', () {
    test('is the lowercase hex of the hash of the UTF-8 plain key', () {
      final seen = <List<int>>[];
      final generator = HashCacheKeyGenerator((bytes) {
        seen.add(bytes);
        return [0x00, 0x0f, 0xab, 0xff];
      });
      final eAcute = String.fromCharCode(0xe9);

      final key = generator.generate(
        ctx,
        'caf$eAcute',
        const CacheKeyOptions(model: 'm'),
      );

      expect(key, '000fabff');
      // 'café-m': the e-acute is two bytes in UTF-8.
      expect(seen.single, utf8.encode('caf$eAcute-m'));
      expect(seen.single.sublist(3, 5), [0xc3, 0xa9]);
    });

    test('hashes the text instead of appending to it (unlike Go)', () {
      // Go's `hasher.Sum(plain)` would give hex(plain) + hex(hash of nothing).
      const generator = HashCacheKeyGenerator(_fnv64);
      final key = generator.generate(ctx, 'foo', const CacheKeyOptions());

      expect(key, hasLength(16));
      final hexOfPlain =
          utf8.encode('foo-').map((b) => b.toRadixString(16)).join();
      expect(key, isNot(startsWith(hexOfPlain)));
      expect(
        generator.generate(ctx, 'a much longer text ' * 50, const CacheKeyOptions()),
        hasLength(16),
      );
    });

    test('an empty digest gives the empty key, as %x does in Go', () {
      final generator = HashCacheKeyGenerator((_) => const []);
      expect(generator.generate(ctx, 'foo', const CacheKeyOptions()), '');
    });

    test('a digest value that is not a byte is an ArgumentError', () {
      final tooBig = HashCacheKeyGenerator((_) => const [256]);
      final negative = HashCacheKeyGenerator((_) => const [-1]);
      expect(
        () => tooBig.generate(ctx, 'foo', const CacheKeyOptions()),
        throwsArgumentError,
      );
      expect(
        () => negative.generate(ctx, 'foo', const CacheKeyOptions()),
        throwsArgumentError,
      );
    });
  });

  group('CacheKeyOptions', () {
    test('defaults to the empty model, Go zero value', () {
      expect(const CacheKeyOptions().model, '');
    });

    test('is a value', () {
      expect(const CacheKeyOptions(model: 'a'), const CacheKeyOptions(model: 'a'));
      expect(
        const CacheKeyOptions(model: 'a').hashCode,
        const CacheKeyOptions(model: 'a').hashCode,
      );
      expect(const CacheKeyOptions(model: 'a'), isNot(const CacheKeyOptions()));
      expect(const CacheKeyOptions(model: 'a').toString(), contains('a'));
    });
  });

  group('InMemoryEmbeddingCache', () {
    const hour = Duration(hours: 1);

    test('a key that was never stored is a miss', () async {
      expect(await InMemoryEmbeddingCache().get(ctx, 'nope'), isNull);
    });

    test('returns what was stored, and a later set replaces it', () async {
      final cache = InMemoryEmbeddingCache();
      await cache.set(ctx, 'k', [1.1, 2.2], hour);
      expect(await cache.get(ctx, 'k'), [1.1, 2.2]);

      await cache.set(ctx, 'k', [3.3], hour);
      expect(await cache.get(ctx, 'k'), [3.3]);
      expect(cache.length, 1);
    });

    test('keeps its own copy of a vector and hands out fresh copies', () async {
      final cache = InMemoryEmbeddingCache();
      final stored = [1.0, 2.0];
      await cache.set(ctx, 'k', stored, hour);
      stored[0] = 99;

      final first = (await cache.get(ctx, 'k'))!;
      expect(first, [1.0, 2.0]);
      first[1] = 42; // the copy is modifiable and detached
      expect(await cache.get(ctx, 'k'), [1.0, 2.0]);
    });

    test('a vector expires exactly when its expiration has elapsed', () {
      fakeAsync((async) {
        final cache = InMemoryEmbeddingCache();
        _now(async, cache.set(ctx, 'k', [1.0], const Duration(minutes: 1)));

        async.elapse(const Duration(seconds: 59));
        expect(_now(async, cache.get(ctx, 'k')), [1.0]);

        async.elapse(const Duration(seconds: 1));
        expect(_now(async, cache.get(ctx, 'k')), isNull);
        // The expired entry was dropped by the read.
        expect(cache.length, 0);
      });
    });

    test('storing again restarts the expiration', () {
      fakeAsync((async) {
        final cache = InMemoryEmbeddingCache();
        _now(async, cache.set(ctx, 'k', [1.0], const Duration(minutes: 1)));
        async.elapse(const Duration(seconds: 50));
        _now(async, cache.set(ctx, 'k', [2.0], const Duration(minutes: 1)));
        async.elapse(const Duration(seconds: 50));

        expect(_now(async, cache.get(ctx, 'k')), [2.0]);
      });
    });

    test('an expiration of zero or less never expires', () {
      fakeAsync((async) {
        final cache = InMemoryEmbeddingCache();
        _now(async, cache.set(ctx, 'zero', [1.0], Duration.zero));
        _now(async, cache.set(ctx, 'negative', [2.0], const Duration(seconds: -1)));

        async.elapse(const Duration(days: 1000));

        expect(_now(async, cache.get(ctx, 'zero')), [1.0]);
        expect(_now(async, cache.get(ctx, 'negative')), [2.0]);
        expect(cache.removeExpired(), 0);
      });
    });

    test('an expiration of 10,000 years or more is no limit', () {
      fakeAsync((async) {
        final cache = InMemoryEmbeddingCache();
        // About 280,000 years, past the range of DateTime: adding it to now
        // would throw.
        _now(async, cache.set(ctx, 'k', [1.0], const Duration(days: 102000000)));
        _now(async, cache.set(ctx, 'j', [2.0], const Duration(days: 3652500)));
        async.elapse(const Duration(days: 3652501));
        expect(_now(async, cache.get(ctx, 'k')), [1.0]);
        expect(_now(async, cache.get(ctx, 'j')), [2.0]);
        expect(cache.removeExpired(), 0);
      });
    });

    test('removeExpired drops the expired vectors and counts them', () {
      fakeAsync((async) {
        final cache = InMemoryEmbeddingCache();
        _now(async, cache.set(ctx, 'short', [1.0], const Duration(minutes: 1)));
        _now(async, cache.set(ctx, 'long', [2.0], hour));
        _now(async, cache.set(ctx, 'forever', [3.0], Duration.zero));

        async.elapse(const Duration(minutes: 2));

        expect(cache.removeExpired(), 1);
        expect(cache.length, 2);
        expect(_now(async, cache.get(ctx, 'long')), [2.0]);
        expect(_now(async, cache.get(ctx, 'forever')), [3.0]);
      });
    });

    group('maxEntries', () {
      test('evicts the least recently used vector', () async {
        final cache = InMemoryEmbeddingCache(maxEntries: 2);
        await cache.set(ctx, 'a', [1.0], hour);
        await cache.set(ctx, 'b', [2.0], hour);
        expect(await cache.get(ctx, 'a'), [1.0]); // a is now the most recent

        await cache.set(ctx, 'c', [3.0], hour);

        expect(cache.length, 2);
        expect(await cache.get(ctx, 'b'), isNull);
        expect(await cache.get(ctx, 'a'), [1.0]);
        expect(await cache.get(ctx, 'c'), [3.0]);
      });

      test('drops expired vectors before live ones', () {
        fakeAsync((async) {
          final cache = InMemoryEmbeddingCache(maxEntries: 2);
          _now(async, cache.set(ctx, 'live', [1.0], hour));
          _now(async, cache.set(ctx, 'short', [2.0], const Duration(minutes: 1)));
          async.elapse(const Duration(minutes: 2));

          _now(async, cache.set(ctx, 'new', [3.0], hour));

          expect(cache.length, 2);
          expect(_now(async, cache.get(ctx, 'live')), [1.0]);
          expect(_now(async, cache.get(ctx, 'new')), [3.0]);
        });
      });

      test('replacing a key does not evict another one', () async {
        final cache = InMemoryEmbeddingCache(maxEntries: 2);
        await cache.set(ctx, 'a', [1.0], hour);
        await cache.set(ctx, 'b', [2.0], hour);
        await cache.set(ctx, 'a', [1.5], hour);

        expect(cache.length, 2);
        expect(await cache.get(ctx, 'a'), [1.5]);
        expect(await cache.get(ctx, 'b'), [2.0]);
      });

      test('must be at least one', () {
        expect(() => InMemoryEmbeddingCache(maxEntries: 0), throwsArgumentError);
        expect(InMemoryEmbeddingCache(maxEntries: 1).maxEntries, 1);
        expect(InMemoryEmbeddingCache().maxEntries, isNull);
      });
    });
  });
}
