import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../graph_state.dart';
import '../checkpoint.dart';
import '../checkpoint_store.dart';
import '../serializer.dart';

/// File-system based checkpoint store.
///
/// Persists checkpoints to the local file system for durability.
/// Each checkpoint is stored as a separate file within a directory structure
/// organized by thread ID.
///
/// Directory structure:
/// ```
/// {directory}/
///   {threadId}/
///     {checkpointId}.checkpoint
///     {checkpointId}.checkpoint
///   {threadId}/
///     {checkpointId}.checkpoint
/// ```
///
/// Features:
/// - Thread-based directory isolation
/// - Optional gzip compression
/// - Configurable max checkpoints per thread
///
/// Example:
/// ```dart
/// final serializer = JsonCheckpointSerializer<MyState>(
///   stateToJson: (s) => s.toJson(),
///   stateFromJson: (j) => MyState.fromJson(j),
/// );
///
/// final store = FileCheckpointStore<MyState>(
///   directory: '/app/checkpoints',
///   serializer: serializer,
///   config: CheckpointStoreConfig(
///     compressData: true,
///   ),
/// );
///
/// await store.save(checkpoint, threadId: 'user-123');
/// ```
class FileCheckpointStore<S extends GraphState>
    implements CheckpointStore<S> {
  /// Creates a file-based checkpoint store.
  ///
  /// [directory] - Root directory for checkpoint storage
  /// [serializer] - Serializer for converting checkpoints to bytes
  /// [config] - Optional configuration
  FileCheckpointStore({
    required this.directory,
    required this.serializer,
    this.config = const CheckpointStoreConfig(),
  });

  /// Root directory for checkpoint storage.
  final String directory;

  /// Serializer for checkpoint data.
  final CheckpointSerializer<S> serializer;

  /// Store configuration.
  final CheckpointStoreConfig config;

  /// Default thread ID for checkpoints without explicit thread.
  static const String _defaultThreadId = '__default__';

  /// File extension for checkpoint files.
  static const String _fileExtension = '.checkpoint';

  final _uuid = const Uuid();

  @override
  Future<String> save(
    Checkpoint<S> checkpoint, {
    String? threadId,
    String? checkpointId,
  }) async {
    final thread = threadId ?? checkpoint.threadId ?? _defaultThreadId;
    final id = checkpointId ?? checkpoint.id ?? _uuid.v4();

    // Ensure checkpoint has ID and threadId
    final checkpointToSave = Checkpoint<S>(
      id: id,
      threadId: thread,
      state: checkpoint.state,
      currentNode: checkpoint.currentNode,
      path: checkpoint.path,
      iteration: checkpoint.iteration,
      timestamp: checkpoint.timestamp ?? DateTime.now(),
      metadata: checkpoint.metadata,
      address: checkpoint.address,
      interruptType: checkpoint.interruptType,
      interruptReason: checkpoint.interruptReason,
      pendingInput: checkpoint.pendingInput,
    );

    // Ensure thread directory exists
    final threadDir = Directory('$directory/$thread');
    await threadDir.create(recursive: true);

    // Serialize checkpoint
    var data = await serializer.serialize(checkpointToSave);

    // Compress if configured
    if (config.compressData) {
      data = gzip.encode(data);
    }

    // Write to file
    final file = File('${threadDir.path}/$id$_fileExtension');
    await file.writeAsBytes(data);

    // Enforce max checkpoints per thread
    await _enforceLimit(thread);

    return id;
  }

  @override
  Future<Checkpoint<S>?> load(String checkpointId, {String? threadId}) async {
    if (threadId != null) {
      return _loadFromThread(checkpointId, threadId);
    }

    // Search all thread directories
    final dir = Directory(directory);
    if (!await dir.exists()) return null;

    await for (final entity in dir.list()) {
      if (entity is Directory) {
        final thread = entity.path.split(Platform.pathSeparator).last;
        final checkpoint = await _loadFromThread(checkpointId, thread);
        if (checkpoint != null) return checkpoint;
      }
    }

    return null;
  }

  /// Loads a checkpoint from a specific thread directory.
  Future<Checkpoint<S>?> _loadFromThread(
    String checkpointId,
    String threadId,
  ) async {
    final file = File('$directory/$threadId/$checkpointId$_fileExtension');

    if (!await file.exists()) return null;

    var data = await file.readAsBytes();

    // Decompress if needed
    if (config.compressData) {
      data = Uint8List.fromList(gzip.decode(data));
    }

    return serializer.deserialize(data);
  }

  @override
  Future<Checkpoint<S>?> loadLatest({required String threadId}) async {
    final threadDir = Directory('$directory/$threadId');
    if (!await threadDir.exists()) return null;

    File? latestFile;
    DateTime? latestTime;

    await for (final entity in threadDir.list()) {
      if (entity is File && entity.path.endsWith(_fileExtension)) {
        final stat = await entity.stat();
        if (latestTime == null || stat.modified.isAfter(latestTime)) {
          latestFile = entity;
          latestTime = stat.modified;
        }
      }
    }

    if (latestFile == null) return null;

    var data = await latestFile.readAsBytes();
    if (config.compressData) {
      data = Uint8List.fromList(gzip.decode(data));
    }

    return serializer.deserialize(data);
  }

  @override
  Future<void> delete(String checkpointId, {String? threadId}) async {
    if (threadId != null) {
      final file = File('$directory/$threadId/$checkpointId$_fileExtension');
      if (await file.exists()) {
        await file.delete();
      }
    } else {
      // Search all thread directories
      final dir = Directory(directory);
      if (!await dir.exists()) return;

      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final file = File(
            '${entity.path}/$checkpointId$_fileExtension',
          );
          if (await file.exists()) {
            await file.delete();
          }
        }
      }
    }
  }

  @override
  Future<List<CheckpointMetadata>> list({String? threadId}) async {
    final results = <CheckpointMetadata>[];

    if (threadId != null) {
      results.addAll(await _listThread(threadId));
    } else {
      final dir = Directory(directory);
      if (!await dir.exists()) return results;

      await for (final entity in dir.list()) {
        if (entity is Directory) {
          final thread = entity.path.split(Platform.pathSeparator).last;
          results.addAll(await _listThread(thread));
        }
      }
    }

    // Sort by timestamp descending
    results.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return results;
  }

  /// Lists checkpoints for a specific thread.
  Future<List<CheckpointMetadata>> _listThread(String threadId) async {
    final results = <CheckpointMetadata>[];
    final threadDir = Directory('$directory/$threadId');

    if (!await threadDir.exists()) return results;

    await for (final entity in threadDir.list()) {
      if (entity is File && entity.path.endsWith(_fileExtension)) {
        try {
          var data = await entity.readAsBytes();
          if (config.compressData) {
            data = Uint8List.fromList(gzip.decode(data));
          }

          final checkpoint = await serializer.deserialize(data);
          results.add(CheckpointMetadata(
            id: checkpoint.id ?? '',
            threadId: checkpoint.threadId ?? threadId,
            currentNode: checkpoint.currentNode,
            iteration: checkpoint.iteration,
            timestamp: checkpoint.timestamp ?? DateTime.now(),
            interruptType: checkpoint.interruptType,
            interruptReason: checkpoint.interruptReason,
            metadata: checkpoint.metadata,
          ));
        } catch (_) {
          // Skip corrupted files
        }
      }
    }

    return results;
  }

  @override
  Future<void> clear({String? threadId}) async {
    if (threadId != null) {
      final threadDir = Directory('$directory/$threadId');
      if (await threadDir.exists()) {
        await threadDir.delete(recursive: true);
      }
    } else {
      final dir = Directory(directory);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  }

  @override
  Future<List<Checkpoint<S>>> getHistory({
    required String threadId,
    int? limit,
    DateTime? before,
    DateTime? after,
  }) async {
    final results = <Checkpoint<S>>[];
    final threadDir = Directory('$directory/$threadId');

    if (!await threadDir.exists()) return results;

    await for (final entity in threadDir.list()) {
      if (entity is File && entity.path.endsWith(_fileExtension)) {
        try {
          var data = await entity.readAsBytes();
          if (config.compressData) {
            data = Uint8List.fromList(gzip.decode(data));
          }

          final checkpoint = await serializer.deserialize(data);
          final time = checkpoint.timestamp;

          // Filter by time range
          if (before != null && time != null && !time.isBefore(before)) {
            continue;
          }
          if (after != null && time != null && !time.isAfter(after)) {
            continue;
          }

          results.add(checkpoint);
        } catch (_) {
          // Skip corrupted files
        }
      }
    }

    // Sort by timestamp descending
    results.sort((a, b) {
      final timeA = a.timestamp ?? DateTime(0);
      final timeB = b.timestamp ?? DateTime(0);
      return timeB.compareTo(timeA);
    });

    // Apply limit
    if (limit != null && results.length > limit) {
      return results.sublist(0, limit);
    }

    return results;
  }

  @override
  Future<bool> exists(String checkpointId, {String? threadId}) async {
    if (threadId != null) {
      final file = File('$directory/$threadId/$checkpointId$_fileExtension');
      return file.exists();
    }

    final dir = Directory(directory);
    if (!await dir.exists()) return false;

    await for (final entity in dir.list()) {
      if (entity is Directory) {
        final file = File(
          '${entity.path}/$checkpointId$_fileExtension',
        );
        if (await file.exists()) return true;
      }
    }

    return false;
  }

  @override
  Future<int> count({String? threadId}) async {
    if (threadId != null) {
      return _countThread(threadId);
    }

    var total = 0;
    final dir = Directory(directory);
    if (!await dir.exists()) return 0;

    await for (final entity in dir.list()) {
      if (entity is Directory) {
        final thread = entity.path.split(Platform.pathSeparator).last;
        total += await _countThread(thread);
      }
    }

    return total;
  }

  /// Counts checkpoints for a specific thread.
  Future<int> _countThread(String threadId) async {
    var count = 0;
    final threadDir = Directory('$directory/$threadId');

    if (!await threadDir.exists()) return 0;

    await for (final entity in threadDir.list()) {
      if (entity is File && entity.path.endsWith(_fileExtension)) {
        count++;
      }
    }

    return count;
  }

  /// Enforces the max checkpoints per thread limit.
  Future<void> _enforceLimit(String threadId) async {
    final maxPerThread = config.maxCheckpointsPerThread;
    if (maxPerThread == null) return;

    final threadDir = Directory('$directory/$threadId');
    if (!await threadDir.exists()) return;

    // Collect all checkpoint files with their timestamps
    final files = <File, DateTime>{};

    await for (final entity in threadDir.list()) {
      if (entity is File && entity.path.endsWith(_fileExtension)) {
        final stat = await entity.stat();
        files[entity] = stat.modified;
      }
    }

    // Remove oldest files if over limit
    while (files.length > maxPerThread) {
      File? oldestFile;
      DateTime? oldestTime;

      for (final entry in files.entries) {
        if (oldestTime == null || entry.value.isBefore(oldestTime)) {
          oldestFile = entry.key;
          oldestTime = entry.value;
        }
      }

      if (oldestFile != null) {
        await oldestFile.delete();
        files.remove(oldestFile);
      } else {
        break;
      }
    }
  }
}
