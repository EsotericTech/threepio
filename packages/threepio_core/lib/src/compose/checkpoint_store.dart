/// Where a graph keeps the checkpoints of interrupted runs.
///
/// The contracts live here because the compile options of a graph refer to
/// them. The engine that writes and reads checkpoints arrives with interrupt
/// and resume.
library;

import 'dart:typed_data';

/// Stores checkpoints as bytes under a key.
///
/// Port of eino `compose.CheckPointStore`.
abstract interface class CheckpointStore {
  /// The checkpoint stored under [key], or `null` when there is none.
  Future<Uint8List?> get(String key);

  /// Stores [value] under [key], replacing what was there.
  Future<void> set(String key, Uint8List value);
}

/// A checkpoint store that can also forget a checkpoint.
///
/// Port of eino `compose.CheckPointDeleter`.
// One member is the whole contract, as in Eino.
// ignore: one_member_abstracts
abstract interface class CheckpointDeleter {
  /// Removes the checkpoint stored under [key]. Nothing happens when there is
  /// none.
  Future<void> delete(String key);
}

/// Turns a checkpoint into bytes and back.
///
/// Port of eino `compose.Serializer`.
abstract interface class CheckpointSerializer {
  /// The bytes of [value].
  Uint8List serialize(Object? value);

  /// The value [bytes] were made from.
  Object? deserialize(Uint8List bytes);
}

/// A checkpoint store that lives in memory, for tests and for runs that are
/// resumed within the same process.
///
/// Port of the store the eino examples use (`store.NewInMemoryStore`).
final class InMemoryCheckpointStore
    implements CheckpointStore, CheckpointDeleter {
  /// An empty store.
  InMemoryCheckpointStore();

  final Map<String, Uint8List> _checkpoints = {};

  /// The keys that have a checkpoint.
  Iterable<String> get keys => List.unmodifiable(_checkpoints.keys);

  @override
  Future<Uint8List?> get(String key) async {
    final value = _checkpoints[key];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> set(String key, Uint8List value) async {
    _checkpoints[key] = Uint8List.fromList(value);
  }

  @override
  Future<void> delete(String key) async {
    _checkpoints.remove(key);
  }
}
