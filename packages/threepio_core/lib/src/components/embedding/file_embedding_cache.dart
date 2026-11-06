/// An embedding cache that keeps its vectors in a directory.
///
/// The substitute of this port for eino-ext's Redis backend
/// (`components/embedding/cache/redis`), which needs a Redis server over TCP.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;

import '../../core/run_context.dart';
import '../../errors.dart';
import 'embedding_cache.dart';

/// Keeps vectors in [directory], one JSON file per key.
///
/// The substitute for eino-ext `cache/redis.Cacher`, whose value is the
/// vector as a JSON array; here a file holds the key, the vector (the same
/// JSON array) and the expiry time:
///
/// ```json
/// {"key": "hello-", "vector": [0.1, 0.2], "expiresAt": "2026-11-05T12:00:00.000Z"}
/// ```
///
/// `expiresAt` is `null` for a vector stored without a time limit (an
/// expiration of zero or less, or of 10,000 years or more). Expiry follows
/// `clock` from `package:clock`.
///
/// * **File names.** A key of up to 64 UTF-8 bytes is stored as `k` and the
///   hex of those bytes; a longer key as `f` and the 64-bit FNV-1a hash of
///   them, or, when [hash] is given, as `h` and the hex of `hash(bytes)` for
///   every key. Since the key is stored in the file as well, two keys that
///   share a file name never get each other's vector: reading one finds the
///   other's key and reports a miss, and storing one replaces the other.
/// * **Plain text on disk.** The key is stored as it is, and a short key is
///   readable from the file name, too. With a [SimpleCacheKeyGenerator] the
///   key contains the whole text; use a [HashCacheKeyGenerator] for texts
///   that should not be kept on disk.
/// * **Writes are atomic** on POSIX file systems: [set] writes a temporary
///   file in [directory] and renames it over the entry, so a reader sees the
///   old entry or the new one, never half of one. (On Windows, replacing a
///   file another process has open can fail; `CachingEmbedder` ignores
///   failed stores.) The directory is created on the first [set].
/// * **Expiry.** [get] deletes an expired entry it finds and reports a miss.
///   Entries that are never read again stay on disk until [removeExpired]
///   (Redis drops expired keys itself; call it now and then).
/// * **Unreadable entries.** As the Go contract asks, [get] throws a
///   [ThreepioFormatException] when an entry is not a vector in this format
///   (or not UTF-8). It deletes the file first, so the next call misses and
///   stores the entry again instead of failing for good.
///
/// Several caches, also in several processes, may share a directory. An
/// entry deleted because it was expired or unreadable may have been replaced
/// by a fresh one between the read and the delete; that costs a miss, never
/// a wrong vector.
final class FileEmbeddingCache implements EmbeddingCache {
  /// A cache in [directory], which need not exist yet. [hash] names the
  /// files when it is given (see the class documentation).
  FileEmbeddingCache(this.directory, {this.hash});

  /// The directory the entries are kept in.
  final Directory directory;

  /// The hash that turns a key's UTF-8 bytes into its file name, or `null`
  /// for the built-in naming. It must return bytes (values from 0 to 255),
  /// at most 64 of them so that the file names stay short (every common
  /// hash does).
  final List<int> Function(List<int> bytes)? hash;

  static const _maxDirectKeyBytes = 64;
  static const _entrySuffix = '.json';
  static const _tempSuffix = '.tmp';

  /// How old a temporary file must be before [removeExpired] takes it for
  /// the leftover of a write that never finished.
  static const _staleTempAge = Duration(hours: 1);

  static final _entryName = RegExp(r'^[kfh][0-9a-f]*\.json$');
  static final _tempName = RegExp(r'^\.[kfh][0-9a-f]*\.json\.[0-9a-f]+\.tmp$');

  final Random _random = Random();

  /// Writes [vector] to the entry of [key], replacing it atomically.
  ///
  /// Throws a [JsonUnsupportedObjectError] when [vector] contains a NaN or
  /// an infinity, which JSON cannot represent, and a [FileSystemException]
  /// when the file cannot be written.
  @override
  Future<void> set(
    RunContext ctx,
    String key,
    List<double> vector,
    Duration expiration,
  ) async {
    final expiresAt = _expiryAfter(expiration);
    final content = jsonEncode(<String, Object?>{
      'key': key,
      'vector': vector,
      'expiresAt': expiresAt?.toUtc().toIso8601String(),
    });
    await directory.create(recursive: true);
    final name = _fileName(key);
    final target = p.join(directory.path, name);
    final temp = File(
      p.join(
        directory.path,
        '.$name.${_random.nextInt(1 << 32).toRadixString(16)}$_tempSuffix',
      ),
    );
    try {
      await temp.writeAsString(content, flush: true);
      await temp.rename(target);
    } catch (_) {
      await _deleteQuietly(temp);
      rethrow;
    }
  }

  /// Reads the entry of [key].
  ///
  /// Throws a [ThreepioFormatException] when the entry cannot be read as a
  /// vector, and a [FileSystemException] when the file exists but cannot be
  /// read.
  @override
  Future<List<double>?> get(RunContext ctx, String key) async {
    final file = File(p.join(directory.path, _fileName(key)));
    final List<int> bytes;
    try {
      // Bytes, not readAsString: that reports bad UTF-8 as a
      // FileSystemException, which would make the entry fail for good.
      bytes = await file.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
    final _FileEntry entry;
    try {
      entry = _FileEntry.decode(bytes);
    } on FormatException catch (error) {
      await _deleteQuietly(file);
      throw ThreepioFormatException(
        'embedding/cache: the cache entry ${file.path} is not a vector',
        cause: error,
      );
    }
    if (entry.key != key) return null;
    if (entry.isExpiredAt(clock.now())) {
      await _deleteQuietly(file);
      return null;
    }
    return entry.vector;
  }

  /// Deletes every expired or unreadable entry in [directory], and the
  /// temporary files of writes that never finished (an hour old or more),
  /// and returns how many files it deleted.
  ///
  /// Only files named like the entries and temporary files of this class are
  /// looked at; anything else in [directory] is left alone.
  Future<int> removeExpired() async {
    if (!directory.existsSync()) return 0;
    final now = clock.now();
    var removed = 0;
    await for (final item in directory.list(followLinks: false)) {
      if (item is! File) continue;
      final name = p.basename(item.path);
      final bool delete;
      if (_tempName.hasMatch(name)) {
        try {
          final age = now.difference(item.lastModifiedSync());
          delete = age >= _staleTempAge;
        } on FileSystemException {
          continue; // renamed into place meanwhile
        }
      } else if (_entryName.hasMatch(name)) {
        final List<int> bytes;
        try {
          bytes = await item.readAsBytes();
        } on FileSystemException {
          continue; // deleted meanwhile
        }
        try {
          delete = _FileEntry.decode(bytes).isExpiredAt(now);
        } on FormatException {
          if (await _deleteQuietly(item)) removed++;
          continue;
        }
      } else {
        continue;
      }
      if (delete && await _deleteQuietly(item)) removed++;
    }
    return removed;
  }

  String _fileName(String key) {
    final bytes = utf8.encode(key);
    final hash = this.hash;
    if (hash != null) return 'h${_hex(hash(bytes))}$_entrySuffix';
    if (bytes.length <= _maxDirectKeyBytes) {
      return 'k${_hex(bytes)}$_entrySuffix';
    }
    return 'f${_fnv1a64(bytes)}$_entrySuffix';
  }

  /// Deletes [file] and says whether it did; a file that is already gone or
  /// cannot be deleted is not an error here.
  static Future<bool> _deleteQuietly(File file) async {
    try {
      await file.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }
}

final class _FileEntry {
  const _FileEntry(this.key, this.vector, this.expiresAt);

  /// Throws a [FormatException] when [bytes] are not an entry.
  factory _FileEntry.decode(List<int> bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json case {
      'key': final String key,
      'vector': final List<Object?> vector,
      'expiresAt': final String? expiresAt,
    }) {
      return _FileEntry(
        key,
        [
          for (final value in vector)
            if (value is num)
              value.toDouble()
            else
              throw const FormatException('a vector value is not a number'),
        ],
        expiresAt == null ? null : DateTime.parse(expiresAt),
      );
    }
    throw const FormatException('not a cache entry');
  }

  final String key;
  final List<double> vector;

  /// `null`: never expires.
  final DateTime? expiresAt;

  bool isExpiredAt(DateTime now) {
    final at = expiresAt;
    return at != null && !now.isBefore(at);
  }
}

/// When a vector stored now for [expiration] expires, or `null` for no time
/// limit: an expiration of zero or less (as Redis `SET` without `EX`), or
/// one so long that the date would be absurd or out of range.
DateTime? _expiryAfter(Duration expiration) =>
    expiration > Duration.zero && expiration < const Duration(days: 3652500)
        ? clock.now().add(expiration)
        : null;

/// Lowercase hex, two digits per byte.
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

/// The 64-bit FNV-1a hash of [bytes] as 16 hex digits. Relies on the
/// wrap-around of 64-bit integers, which this `dart:io` library always has.
String _fnv1a64(List<int> bytes) {
  const prime = 0x100000001b3;
  var hash = (0xcbf29ce4 << 32) | 0x84222325;
  for (final byte in bytes) {
    hash = (hash ^ byte) * prime;
  }
  String half(int value) => (value & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return '${half(hash >> 32)}${half(hash)}';
}
