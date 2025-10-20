import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../schema/message.dart';

/// Abstract interface for persistent message storage
///
/// MessageStore provides the persistence layer for chat memory.
/// Different implementations can store messages in memory, files, databases, etc.
abstract class MessageStore {
  /// Add a message to the store
  Future<void> addMessage(String sessionId, Message message);

  /// Get all messages for a session
  Future<List<Message>> getMessages(String sessionId);

  /// Get the last N messages for a session
  Future<List<Message>> getLastMessages(String sessionId, int count);

  /// Get messages within a specific range
  Future<List<Message>> getMessagesRange(
    String sessionId, {
    int? offset,
    int? limit,
  });

  /// Count total messages in a session
  Future<int> getMessageCount(String sessionId);

  /// Delete messages for a session
  Future<void> deleteMessages(String sessionId);

  /// Delete a specific range of messages
  Future<void> deleteMessagesRange(
    String sessionId, {
    int? start,
    int? end,
  });

  /// Clear all messages across all sessions
  Future<void> clear();

  /// Get all session IDs
  Future<List<String>> getAllSessionIds();
}

/// In-memory message store
///
/// Stores messages in memory. Data is lost when the application terminates.
/// Useful for development and testing.
class InMemoryMessageStore implements MessageStore {
  final Map<String, List<Message>> _store = {};

  @override
  Future<void> addMessage(String sessionId, Message message) async {
    _store.putIfAbsent(sessionId, () => []);
    _store[sessionId]!.add(message);
  }

  @override
  Future<List<Message>> getMessages(String sessionId) async {
    return List.from(_store[sessionId] ?? []);
  }

  @override
  Future<List<Message>> getLastMessages(String sessionId, int count) async {
    final messages = _store[sessionId] ?? [];
    if (messages.length <= count) {
      return List.from(messages);
    }
    return messages.sublist(messages.length - count);
  }

  @override
  Future<List<Message>> getMessagesRange(
    String sessionId, {
    int? offset,
    int? limit,
  }) async {
    final messages = _store[sessionId] ?? [];
    final start = offset ?? 0;
    final end = limit != null ? start + limit : messages.length;

    if (start >= messages.length) {
      return [];
    }

    return messages.sublist(start, end.clamp(0, messages.length));
  }

  @override
  Future<int> getMessageCount(String sessionId) async {
    return _store[sessionId]?.length ?? 0;
  }

  @override
  Future<void> deleteMessages(String sessionId) async {
    _store.remove(sessionId);
  }

  @override
  Future<void> deleteMessagesRange(
    String sessionId, {
    int? start,
    int? end,
  }) async {
    final messages = _store[sessionId];
    if (messages == null) return;

    final startIdx = start ?? 0;
    final endIdx = end ?? messages.length;

    messages.removeRange(
      startIdx.clamp(0, messages.length),
      endIdx.clamp(0, messages.length),
    );

    if (messages.isEmpty) {
      _store.remove(sessionId);
    }
  }

  @override
  Future<void> clear() async {
    _store.clear();
  }

  @override
  Future<List<String>> getAllSessionIds() async {
    return List.from(_store.keys);
  }

  /// Get the total number of sessions
  int get sessionCount => _store.length;

  /// Get the total number of messages across all sessions
  int get totalMessageCount {
    return _store.values.fold(0, (sum, messages) => sum + messages.length);
  }
}

/// File-based message store
///
/// Persists messages to JSON files on disk. Each session has its own file.
/// Useful for local persistence without a database.
class FileMessageStore implements MessageStore {
  FileMessageStore({
    required this.baseDirectory,
  });

  final Directory baseDirectory;

  /// Get the file for a session
  File _getSessionFile(String sessionId) {
    // Sanitize session ID for filename
    final sanitized = sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return File('${baseDirectory.path}/$sanitized.json');
  }

  /// Ensure base directory exists
  Future<void> _ensureDirectory() async {
    if (!await baseDirectory.exists()) {
      await baseDirectory.create(recursive: true);
    }
  }

  @override
  Future<void> addMessage(String sessionId, Message message) async {
    await _ensureDirectory();

    final messages = await getMessages(sessionId);
    messages.add(message);

    final file = _getSessionFile(sessionId);
    final jsonList = messages.map((m) => _messageToJson(m)).toList();
    await file.writeAsString(jsonEncode(jsonList));
  }

  @override
  Future<List<Message>> getMessages(String sessionId) async {
    final file = _getSessionFile(sessionId);

    if (!await file.exists()) {
      return [];
    }

    try {
      final content = await file.readAsString();
      final jsonList = jsonDecode(content) as List<dynamic>;
      return jsonList
          .map((json) => _messageFromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // If file is corrupted or empty, return empty list
      return [];
    }
  }

  @override
  Future<List<Message>> getLastMessages(String sessionId, int count) async {
    final messages = await getMessages(sessionId);
    if (messages.length <= count) {
      return messages;
    }
    return messages.sublist(messages.length - count);
  }

  @override
  Future<List<Message>> getMessagesRange(
    String sessionId, {
    int? offset,
    int? limit,
  }) async {
    final messages = await getMessages(sessionId);
    final start = offset ?? 0;
    final end = limit != null ? start + limit : messages.length;

    if (start >= messages.length) {
      return [];
    }

    return messages.sublist(start, end.clamp(0, messages.length));
  }

  @override
  Future<int> getMessageCount(String sessionId) async {
    final messages = await getMessages(sessionId);
    return messages.length;
  }

  @override
  Future<void> deleteMessages(String sessionId) async {
    final file = _getSessionFile(sessionId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> deleteMessagesRange(
    String sessionId, {
    int? start,
    int? end,
  }) async {
    final messages = await getMessages(sessionId);
    if (messages.isEmpty) return;

    final startIdx = start ?? 0;
    final endIdx = end ?? messages.length;

    messages.removeRange(
      startIdx.clamp(0, messages.length),
      endIdx.clamp(0, messages.length),
    );

    if (messages.isEmpty) {
      await deleteMessages(sessionId);
    } else {
      final file = _getSessionFile(sessionId);
      final jsonList = messages.map((m) => _messageToJson(m)).toList();
      await file.writeAsString(jsonEncode(jsonList));
    }
  }

  @override
  Future<void> clear() async {
    await _ensureDirectory();

    final files = baseDirectory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'));

    for (final file in files) {
      await file.delete();
    }
  }

  @override
  Future<List<String>> getAllSessionIds() async {
    await _ensureDirectory();

    final files = baseDirectory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'));

    return files.map((f) {
      final filename = f.path.split('/').last;
      return filename.replaceAll('.json', '');
    }).toList();
  }

  /// Convert Message to JSON
  Map<String, dynamic> _messageToJson(Message message) {
    return {
      'role': message.role.toString().split('.').last,
      'content': message.content,
      if (message.name != null) 'name': message.name,
      if (message.toolCallId != null) 'tool_call_id': message.toolCallId,
      if (message.toolCalls != null)
        'tool_calls': message.toolCalls!
            .map((tc) => {
                  'id': tc.id,
                  'type': tc.type,
                  'function': {
                    'name': tc.function.name,
                    'arguments': tc.function.arguments,
                  },
                })
            .toList(),
    };
  }

  /// Convert JSON to Message
  Message _messageFromJson(Map<String, dynamic> json) {
    final roleStr = json['role'] as String;
    final role = RoleType.values.firstWhere(
      (r) => r.toString().split('.').last == roleStr,
    );

    return Message(
      role: role,
      content: json['content'] as String? ?? '',
      name: json['name'] as String?,
      toolCallId: json['tool_call_id'] as String?,
      toolCalls: (json['tool_calls'] as List<dynamic>?)
          ?.map((tc) => ToolCall(
                id: tc['id'] as String,
                type: tc['type'] as String,
                function: FunctionCall(
                  name: tc['function']['name'] as String,
                  arguments: tc['function']['arguments'] as String,
                ),
              ))
          .toList(),
    );
  }
}
