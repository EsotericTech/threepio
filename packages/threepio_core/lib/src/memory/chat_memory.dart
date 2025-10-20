import 'dart:async';

import '../schema/message.dart';

/// Base interface for chat memory systems
///
/// ChatMemory manages the storage and retrieval of conversation history.
/// Different implementations can provide different strategies for managing
/// conversation context (e.g., keeping all messages, sliding window, summarization).
///
/// Example:
/// ```dart
/// final memory = ConversationBufferMemory();
///
/// // Add messages
/// await memory.saveContext(
///   inputMessage: Message.user('Hello'),
///   outputMessage: Message.assistant('Hi there!'),
/// );
///
/// // Load history
/// final messages = await memory.loadMemoryMessages();
/// ```
abstract class ChatMemory {
  /// Load the conversation history as a list of messages
  Future<List<Message>> loadMemoryMessages();

  /// Load the conversation history as a formatted string
  ///
  /// Useful for inserting into prompts or for display.
  Future<String> loadMemoryString({
    String separator = '\n',
    String humanPrefix = 'Human',
    String aiPrefix = 'AI',
  });

  /// Save a conversation turn (input and output) to memory
  ///
  /// [inputMessage] - The user's input message
  /// [outputMessage] - The assistant's response message
  Future<void> saveContext({
    required Message inputMessage,
    required Message outputMessage,
  });

  /// Add a single message to memory
  ///
  /// Lower-level method for adding arbitrary messages.
  Future<void> addMessage(Message message);

  /// Clear all messages from memory
  Future<void> clear();

  /// Get the number of messages currently in memory
  Future<int> get messageCount;
}

/// Options for configuring memory behavior
class MemoryOptions {
  const MemoryOptions({
    this.returnMessages = true,
    this.inputKey = 'input',
    this.outputKey = 'output',
    this.memoryKey = 'history',
    this.humanPrefix = 'Human',
    this.aiPrefix = 'AI',
  });

  /// Whether to return messages as List<Message> or formatted string
  final bool returnMessages;

  /// Key to use for input in context dictionaries
  final String inputKey;

  /// Key to use for output in context dictionaries
  final String outputKey;

  /// Key to use for memory when loading into prompts
  final String memoryKey;

  /// Prefix for human messages when formatting
  final String humanPrefix;

  /// Prefix for AI messages when formatting
  final String aiPrefix;

  MemoryOptions copyWith({
    bool? returnMessages,
    String? inputKey,
    String? outputKey,
    String? memoryKey,
    String? humanPrefix,
    String? aiPrefix,
  }) {
    return MemoryOptions(
      returnMessages: returnMessages ?? this.returnMessages,
      inputKey: inputKey ?? this.inputKey,
      outputKey: outputKey ?? this.outputKey,
      memoryKey: memoryKey ?? this.memoryKey,
      humanPrefix: humanPrefix ?? this.humanPrefix,
      aiPrefix: aiPrefix ?? this.aiPrefix,
    );
  }
}

/// Base class for memory implementations
///
/// Provides common functionality for message formatting and context management.
abstract class BaseMemory implements ChatMemory {
  BaseMemory({
    MemoryOptions? options,
  }) : options = options ?? const MemoryOptions();

  final MemoryOptions options;

  @override
  Future<String> loadMemoryString({
    String? separator,
    String? humanPrefix,
    String? aiPrefix,
  }) async {
    final messages = await loadMemoryMessages();

    final humanPfx = humanPrefix ?? options.humanPrefix;
    final aiPfx = aiPrefix ?? options.aiPrefix;
    final sep = separator ?? '\n';

    return messages.map((message) {
      final prefix = message.role == RoleType.user ? humanPfx : aiPfx;
      return '$prefix: ${message.content}';
    }).join(sep);
  }

  /// Load memory as a dictionary for use in chains
  ///
  /// Returns a map with the memory key pointing to either a list of messages
  /// or a formatted string, depending on [options.returnMessages].
  Future<Map<String, dynamic>> loadMemoryVariables() async {
    if (options.returnMessages) {
      final messages = await loadMemoryMessages();
      return {options.memoryKey: messages};
    } else {
      final memoryString = await loadMemoryString();
      return {options.memoryKey: memoryString};
    }
  }

  /// Helper to format a message for display
  String formatMessage(Message message) {
    final prefix =
        message.role == RoleType.user ? options.humanPrefix : options.aiPrefix;
    return '$prefix: ${message.content}';
  }
}
