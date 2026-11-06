// Tests written for the port: `FileEmbeddingCache` is this package's
// substitute for eino-ext's Redis backend (`components/embedding/cache/redis`,
// skipped by the parity plan because it needs a Redis server over TCP). The Go
// tests of that backend (cacher_test.go, codec_test.go) mock the Redis client
// and the sonic codec, so none of them is ported; what they check (a stored
// vector comes back, a missing key is a miss, an undecodable value is an
// error) is checked here against a temporary directory.
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/embedding/caching_embedder.dart';
import 'package:threepio_core/src/components/embedding/embedding_cache.dart';
import 'package:threepio_core/src/components/embedding/file_embedding_cache.dart';
import 'package:threepio_core/threepio_core.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _entryName(String key) => 'k${_hex(utf8.encode(key))}.json';

void main() {
  final ctx = RunContext.background();
  const hour = Duration(hours: 1);
  late Directory temp;
  late Directory dir;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('threepio_p11_');
    dir = Directory(p.join(temp.path, 'cache', 'embeddings'));
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  List<String> names() => dir.existsSync()
      ? (dir.listSync().map((e) => p.basename(e.path)).toList()..sort())
      : const [];

  test('a missing directory is an empty cache, created by the first set',
      () async {
    final cache = FileEmbeddingCache(dir);
    expect(await cache.get(ctx, 'k'), isNull);
    expect(dir.existsSync(), isFalse);

    await cache.set(ctx, 'k', [1.1, 2.2], hour);

    expect(dir.existsSync(), isTrue);
    expect(await cache.get(ctx, 'k'), [1.1, 2.2]);
  });

  test('a later set replaces the entry', () async {
    final cache = FileEmbeddingCache(dir);
    await cache.set(ctx, 'k', [1.0], hour);
    await cache.set(ctx, 'k', [2.0, 3.0], hour);

    expect(await cache.get(ctx, 'k'), [2.0, 3.0]);
    expect(names(), [_entryName('k')]);
  });

  test('writes one JSON file per key: key, vector and expiry, no temp file',
      () async {
    final start = DateTime.utc(2026, 11, 5, 12);
    await withClock(Clock.fixed(start), () async {
      await FileEmbeddingCache(dir).set(ctx, 'hello-', [0.5, -1.0, 3.0], hour);
    });

    expect(names(), ['k${_hex(utf8.encode('hello-'))}.json']);
    final json = jsonDecode(
      File(p.join(dir.path, _entryName('hello-'))).readAsStringSync(),
    );
    expect(json, {
      'key': 'hello-',
      'vector': [0.5, -1.0, 3.0],
      'expiresAt': '2026-11-05T13:00:00.000Z',
    });
  });

  test('an entry expires exactly when its expiration has elapsed, and the '
      'read deletes it', () async {
    var now = DateTime.utc(2026, 11, 5, 12);
    final cache = FileEmbeddingCache(dir);
    await withClock(Clock(() => now), () async {
      await cache.set(ctx, 'k', [1.0], const Duration(minutes: 1));

      now = now.add(const Duration(seconds: 59));
      expect(await cache.get(ctx, 'k'), [1.0]);

      now = now.add(const Duration(seconds: 1));
      expect(await cache.get(ctx, 'k'), isNull);
    });
    expect(names(), isEmpty);
  });

  test('an expiration of 10,000 years or more is stored without a limit',
      () async {
    final cache = FileEmbeddingCache(dir);
    // About 280,000 years: past the range of DateTime.
    await cache.set(ctx, 'k', [1.0], const Duration(days: 102000000));
    await cache.set(ctx, 'j', [2.0], const Duration(days: 3652500));

    for (final key in ['k', 'j']) {
      final json = jsonDecode(
        File(p.join(dir.path, _entryName(key))).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(json['expiresAt'], isNull);
    }
    expect(await cache.get(ctx, 'k'), [1.0]);
  });

  test('an expiration of zero or less never expires', () async {
    var now = DateTime.utc(2026, 11, 5, 12);
    final cache = FileEmbeddingCache(dir);
    await withClock(Clock(() => now), () async {
      await cache.set(ctx, 'zero', [1.0], Duration.zero);
      await cache.set(ctx, 'negative', [2.0], const Duration(seconds: -5));
      now = now.add(const Duration(days: 1000));

      expect(await cache.get(ctx, 'zero'), [1.0]);
      expect(await cache.get(ctx, 'negative'), [2.0]);
    });
    final json = jsonDecode(
      File(p.join(dir.path, _entryName('zero'))).readAsStringSync(),
    ) as Map<String, Object?>;
    expect(json['expiresAt'], isNull);
  });

  test('a key longer than 64 bytes gets a hashed file name', () async {
    final cache = FileEmbeddingCache(dir);
    final short = 'x' * 64;
    final long = 'x' * 65;
    final eAcute = String.fromCharCode(0xe9);
    final multiByte = eAcute * 33; // 66 bytes in UTF-8

    await cache.set(ctx, short, [1.0], hour);
    await cache.set(ctx, long, [2.0], hour);
    await cache.set(ctx, multiByte, [3.0], hour);

    expect(await cache.get(ctx, short), [1.0]);
    expect(await cache.get(ctx, long), [2.0]);
    expect(await cache.get(ctx, multiByte), [3.0]);
    final hashed = names().where((n) => n.startsWith('f')).toList();
    expect(hashed, hasLength(2));
    for (final name in hashed) {
      expect(name, matches(RegExp(r'^f[0-9a-f]{16}\.json$')));
    }
    expect(names(), contains(_entryName(short)));
    // The 64-bit FNV-1a of 65 'x' bytes: file names are a persistent format.
    expect(names(), contains('f7d70a52549704607.json'));
  });

  test('a key with path characters is a plain file in the directory',
      () async {
    final cache = FileEmbeddingCache(dir);
    const key = '../../etc/passwd-/model';

    await cache.set(ctx, key, [7.0], hour);

    expect(await cache.get(ctx, key), [7.0]);
    expect(names(), [_entryName(key)]);
    expect(temp.listSync().map((e) => p.basename(e.path)), ['cache']);
  });

  test('an injected hash names every file', () async {
    final cache = FileEmbeddingCache(
      dir,
      hash: (bytes) => [bytes.length, 0xab],
    );

    await cache.set(ctx, 'abc', [1.0], hour);

    expect(cache.hash, isNotNull);
    expect(names(), ['h03ab.json']);
    expect(await cache.get(ctx, 'abc'), [1.0]);
  });

  test("keys that share a file name never get each other's vector",
      () async {
    final cache = FileEmbeddingCache(dir, hash: (_) => const [1]);
    await cache.set(ctx, 'first', [1.0], hour);

    expect(await cache.get(ctx, 'second'), isNull);
    expect(await cache.get(ctx, 'first'), [1.0]);

    await cache.set(ctx, 'second', [2.0], hour);
    expect(await cache.get(ctx, 'first'), isNull);
    expect(await cache.get(ctx, 'second'), [2.0]);
    expect(names(), ['h01.json']);
  });

  group('an unreadable entry', () {
    Future<void> write(String key, String content) async {
      await dir.create(recursive: true);
      await File(p.join(dir.path, _entryName(key))).writeAsString(content);
    }

    for (final (name, content) in [
      ('not JSON', '{"key": "k", "vec'),
      ('not an object', '[1, 2]'),
      ('no vector', '{"key": "k", "expiresAt": null}'),
      ('a value that is not a number', '{"key": "k", "vector": [1, "x"], "expiresAt": null}'),
      ('a bad expiry', '{"key": "k", "vector": [1], "expiresAt": "soon"}'),
    ]) {
      test('$name: a format error, then the file is gone', () async {
        await write('k', content);
        final cache = FileEmbeddingCache(dir);

        await expectLater(
          cache.get(ctx, 'k'),
          throwsA(isA<ThreepioFormatException>()
              .having((e) => e.message, 'message', contains('not a vector'))),
        );
        expect(names(), isEmpty);
        expect(await cache.get(ctx, 'k'), isNull);
      });
    }

    test('not UTF-8: a format error, then the file is gone', () async {
      await dir.create(recursive: true);
      File(p.join(dir.path, _entryName('k')))
          .writeAsBytesSync(const [0xff, 0xfe, 0x00]);
      final cache = FileEmbeddingCache(dir);

      await expectLater(
        cache.get(ctx, 'k'),
        throwsA(isA<ThreepioFormatException>()),
      );
      expect(names(), isEmpty);
      expect(await cache.get(ctx, 'k'), isNull);
    });

    test('whole numbers are read as doubles', () async {
      await write('k', '{"key": "k", "vector": [1, 2.5], "expiresAt": null}');
      final vector = await FileEmbeddingCache(dir).get(ctx, 'k');
      expect(vector, [1.0, 2.5]);
      expect(vector, isA<List<double>>());
    });
  });

  test('a vector JSON cannot hold is refused before anything is written',
      () async {
    final cache = FileEmbeddingCache(dir);

    await expectLater(
      cache.set(ctx, 'k', [double.nan], hour),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    expect(names(), isEmpty);
  });

  test('a write that cannot be renamed into place leaves no temp file',
      () async {
    final cache = FileEmbeddingCache(dir);
    // A directory where the entry file should go makes the rename fail.
    Directory(p.join(dir.path, _entryName('k'), 'inside'))
        .createSync(recursive: true);

    await expectLater(
      cache.set(ctx, 'k', [1.0], hour),
      throwsA(isA<FileSystemException>()),
    );
    expect(names(), [_entryName('k')]);
  });

  test('removeExpired deletes expired and unreadable entries and stale temp '
      'files, nothing else', () async {
    var now = DateTime.utc(2026, 11, 5, 12);
    final cache = FileEmbeddingCache(dir);
    expect(await cache.removeExpired(), 0); // no directory yet

    await withClock(Clock(() => now), () async {
      await cache.set(ctx, 'short', [1.0], const Duration(minutes: 1));
      await cache.set(ctx, 'long', [2.0], hour);
      await cache.set(ctx, 'forever', [3.0], Duration.zero);
    });
    File(p.join(dir.path, _entryName('broken'))).writeAsStringSync('nope');
    File(p.join(dir.path, _entryName('binary')))
        .writeAsBytesSync(const [0xff, 0xfe]);
    File(p.join(dir.path, 'notes.txt')).writeAsStringSync('not an entry');
    File(p.join(dir.path, 'other.json')).writeAsStringSync('{"mine": true}');
    File(p.join(dir.path, 'k00.json.bak')).writeAsStringSync('nope');
    now = now.add(const Duration(minutes: 2));
    File(p.join(dir.path, '.k00.json.1234.tmp'))
      ..writeAsStringSync('{')
      ..setLastModifiedSync(now.subtract(const Duration(minutes: 30)));
    File(p.join(dir.path, '.k01.json.abcd.tmp'))
      ..writeAsStringSync('{')
      ..setLastModifiedSync(now.subtract(const Duration(hours: 2)));
    File(p.join(dir.path, '.unrelated.tmp'))
      ..writeAsStringSync('{')
      ..setLastModifiedSync(now.subtract(const Duration(hours: 2)));

    final removed = await withClock(Clock(() => now), cache.removeExpired);

    // short (expired), broken, binary, the stale temp file.
    expect(removed, 4);
    expect(
      names(),
      [
        '.k00.json.1234.tmp',
        '.unrelated.tmp',
        _entryName('forever'),
        _entryName('long'),
        'k00.json.bak',
        'notes.txt',
        'other.json',
      ]..sort(),
    );
  });

  test('concurrent stores of one key leave one whole entry and no temp file',
      () async {
    final cache = FileEmbeddingCache(dir);

    await Future.wait([
      for (var i = 0; i < 8; i++) cache.set(ctx, 'k', [i.toDouble(), i * 2.0], hour),
    ]);

    final vector = await cache.get(ctx, 'k');
    expect(vector, hasLength(2));
    expect(vector![1], vector[0] * 2);
    expect(names(), [_entryName('k')]);
  });

  test('two caches on one directory share their entries', () async {
    await FileEmbeddingCache(dir).set(ctx, 'k', [4.0], hour);
    expect(await FileEmbeddingCache(dir).get(ctx, 'k'), [4.0]);
  });

  test('a caching embedder over a file cache survives a restart', () async {
    final calls = <List<String>>[];
    CachingEmbedder embedderOver(Directory directory) => CachingEmbedder(
          _CountingEmbedder(calls),
          cache: FileEmbeddingCache(directory),
          keyGenerator: const SimpleCacheKeyGenerator(),
        );

    final first = await embedderOver(dir).embedStrings(['hello', 'world']);
    final second = await embedderOver(dir).embedStrings(['world', 'again']);

    expect(first, [
      [5.0],
      [5.0],
    ]);
    expect(second, [
      [5.0],
      [5.0],
    ]);
    expect(calls, [
      ['hello', 'world'],
      ['again'],
    ]);
  });
}

final class _CountingEmbedder extends Embedder {
  _CountingEmbedder(this.calls);

  final List<List<String>> calls;

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    calls.add(List.of(texts));
    return [
      for (final text in texts) [text.length.toDouble()],
    ];
  }
}
