/// A checkpoint store on the file system.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../checkpoint_store.dart';

/// Keeps every checkpoint as a file in one directory, so that an interrupted
/// run can be resumed after the process was restarted.
///
/// The compose counterpart of the store the eino examples keep in memory;
/// exported from `package:threepio_core/io.dart` because it needs `dart:io`.
///
/// ```dart
/// final runnable = await graph.compile(
///   ctx,
///   options: GraphCompileOptions(
///     checkpointStore: FileCheckpointStore(Directory('/var/lib/app/checkpoints')),
///   ),
/// );
/// ```
///
/// A checkpoint id becomes a file name: the id itself when it is made of
/// lower-case letters, digits, `-`, `_` and `.` only; otherwise `x-` and its
/// Base32 form. So an id can never leave the directory, and two ids never
/// share a file, also not on a file system that ignores case. An id that
/// would make a file name of more than 180 characters is refused. A
/// checkpoint is written to a temporary file first and then renamed, so a
/// reader never sees half of one.
///
/// The files hold what the serializer of the graph produced, JSON by default.
/// They are as sensitive as the conversation they belong to.
final class FileCheckpointStore implements CheckpointStore, CheckpointDeleter {
  /// A store in [directory], which is created when the first checkpoint is
  /// written.
  FileCheckpointStore(this.directory);

  /// Where the checkpoint files are.
  final Directory directory;

  static final _plainName = RegExp(r'^[a-z0-9_-][a-z0-9._-]*$');

  /// In front of every encoded name. No plain name starts with it.
  static const _encodedPrefix = 'x-';

  /// The longest file name (without extension) a checkpoint gets. File
  /// systems allow 255 bytes; the rest is for the extension and the suffix of
  /// the temporary file.
  static const _maxNameLength = 180;

  /// The file of the checkpoint [key].
  ///
  /// Throws [ArgumentError] for an id that is too long to be a file name:
  /// more than 180 characters, or more than 110 bytes of UTF-8 when it has
  /// characters other than lower-case letters, digits, `-`, `_` and `.`.
  File fileOf(String key) {
    final plain = _plainName.hasMatch(key) && !key.startsWith(_encodedPrefix);
    final name = plain ? key : '$_encodedPrefix${_base32(utf8.encode(key))}';
    if (name.length > _maxNameLength) {
      throw ArgumentError.value(
        key,
        'key',
        'is too long to be the name of a checkpoint file',
      );
    }
    return File('${directory.path}${Platform.pathSeparator}$name.checkpoint');
  }

  /// Base32 (RFC 4648) in lower case, without padding: safe as a file name
  /// whether or not the file system tells upper case from lower case.
  static String _base32(List<int> bytes) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    final encoded = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in bytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        encoded.write(alphabet[(buffer >> bits) & 31]);
      }
      buffer &= (1 << bits) - 1;
    }
    if (bits > 0) encoded.write(alphabet[(buffer << (5 - bits)) & 31]);
    return encoded.toString();
  }

  @override
  Future<Uint8List?> get(String key) async {
    final file = fileOf(key);
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      // Gone, or never there.
      if (!file.existsSync()) return null;
      rethrow;
    }
  }

  @override
  Future<void> set(String key, Uint8List value) async {
    final file = fileOf(key);
    await directory.create(recursive: true);
    // A name no other writer uses: other stores, other isolates, other
    // processes may write the same checkpoint.
    final temporary = File(
      '${file.path}.$pid-${identityHashCode(this)}-${_counter++}-'
      '${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(value, flush: true);
      await temporary.rename(file.path);
    } on FileSystemException {
      if (temporary.existsSync()) await temporary.delete();
      rethrow;
    }
  }

  @override
  Future<void> delete(String key) async {
    final file = fileOf(key);
    try {
      await file.delete();
    } on FileSystemException {
      if (file.existsSync()) rethrow;
    }
  }

  static int _counter = 0;
}
