import '../schema/message.dart';
import 'chat_memory.dart';
import 'message_store.dart';

/// Conversation memory that keeps only the last K messages
///
/// This memory type uses a sliding window approach, keeping only the most
/// recent N messages. Useful when you want to limit context size while
/// maintaining recent conversation flow.
///
/// Example:
/// ```dart
/// final memory = ConversationBufferWindowMemory(
///   sessionId: 'user-123',
///   k: 10, // Keep last 10 messages
/// );
///
/// // After 20 messages, only the last 10 are kept
/// await memory.saveContext(
///   inputMessage: Message.user('Hello'),
///   outputMessage: Message.assistant('Hi!'),
/// );
/// ```
class ConversationBufferWindowMemory extends BaseMemory {
  ConversationBufferWindowMemory({
    String? sessionId,
    MessageStore? store,
    this.k = 5,
    super.options,
  })  : assert(k > 0, 'k must be greater than 0'),
        sessionId = sessionId ?? 'default',
        store = store ?? InMemoryMessageStore();

  /// Unique identifier for this conversation session
  final String sessionId;

  /// Storage backend for persisting messages
  final MessageStore store;

  /// Number of messages to keep in the window
  final int k;

  @override
  Future<List<Message>> loadMemoryMessages() async {
    return await store.getLastMessages(sessionId, k);
  }

  @override
  Future<void> saveContext({
    required Message inputMessage,
    required Message outputMessage,
  }) async {
    await store.addMessage(sessionId, inputMessage);
    await store.addMessage(sessionId, outputMessage);

    // Trim old messages if we exceed the window
    await _trimIfNeeded();
  }

  @override
  Future<void> addMessage(Message message) async {
    await store.addMessage(sessionId, message);
    await _trimIfNeeded();
  }

  @override
  Future<void> clear() async {
    await store.deleteMessages(sessionId);
  }

  @override
  Future<int> get messageCount => store.getMessageCount(sessionId);

  /// Trim messages to maintain window size
  Future<void> _trimIfNeeded() async {
    final count = await store.getMessageCount(sessionId);

    if (count > k) {
      // Delete the oldest messages
      final toDelete = count - k;
      await store.deleteMessagesRange(sessionId, start: 0, end: toDelete);
    }
  }

  /// Get all messages (including those outside the window)
  ///
  /// Useful for debugging or analytics.
  Future<List<Message>> getAllMessages() async {
    return await store.getMessages(sessionId);
  }

  /// Get the total number of messages ever saved (including deleted)
  ///
  /// Note: This only works with stores that maintain a count.
  Future<int> getTotalMessageCount() async {
    return await store.getMessageCount(sessionId);
  }
}

/// Conversation memory based on token count limits
///
/// Keeps messages within a specified token budget. Older messages are
/// removed to stay under the limit. Useful for managing API costs and
/// context limits.
///
/// Example:
/// ```dart
/// final memory = ConversationTokenBufferMemory(
///   sessionId: 'user-123',
///   maxTokenLimit: 2000,
///   tokensPerMessage: 100, // Rough estimate
/// );
/// ```
class ConversationTokenBufferMemory extends BaseMemory {
  ConversationTokenBufferMemory({
    String? sessionId,
    MessageStore? store,
    this.maxTokenLimit = 2000,
    this.tokensPerMessage = 100,
    super.options,
  })  : assert(maxTokenLimit > 0, 'maxTokenLimit must be greater than 0'),
        assert(tokensPerMessage > 0, 'tokensPerMessage must be greater than 0'),
        sessionId = sessionId ?? 'default',
        store = store ?? InMemoryMessageStore();

  /// Unique identifier for this conversation session
  final String sessionId;

  /// Storage backend for persisting messages
  final MessageStore store;

  /// Maximum number of tokens to keep
  final int maxTokenLimit;

  /// Estimated tokens per message
  ///
  /// This is a rough estimate. For more accuracy, you could integrate
  /// with a tokenizer like tiktoken.
  final int tokensPerMessage;

  @override
  Future<List<Message>> loadMemoryMessages() async {
    final allMessages = await store.getMessages(sessionId);

    // Calculate how many messages fit within token limit
    final maxMessages = (maxTokenLimit / tokensPerMessage).floor();

    if (allMessages.length <= maxMessages) {
      return allMessages;
    }

    // Return the most recent messages that fit
    return allMessages.sublist(allMessages.length - maxMessages);
  }

  @override
  Future<void> saveContext({
    required Message inputMessage,
    required Message outputMessage,
  }) async {
    await store.addMessage(sessionId, inputMessage);
    await store.addMessage(sessionId, outputMessage);

    await _trimToTokenLimit();
  }

  @override
  Future<void> addMessage(Message message) async {
    await store.addMessage(sessionId, message);
    await _trimToTokenLimit();
  }

  @override
  Future<void> clear() async {
    await store.deleteMessages(sessionId);
  }

  @override
  Future<int> get messageCount => store.getMessageCount(sessionId);

  /// Trim messages to stay within token limit
  Future<void> _trimToTokenLimit() async {
    final allMessages = await store.getMessages(sessionId);

    // Calculate how many messages we can keep
    final maxMessages = (maxTokenLimit / tokensPerMessage).floor();

    if (allMessages.length > maxMessages) {
      // Delete oldest messages
      final toDelete = allMessages.length - maxMessages;
      await store.deleteMessagesRange(sessionId, start: 0, end: toDelete);
    }
  }

  /// Estimate total tokens in current memory
  Future<int> estimateTokenCount() async {
    final count = await messageCount;
    return count * tokensPerMessage;
  }

  /// Get all messages (including those outside token limit)
  Future<List<Message>> getAllMessages() async {
    return await store.getMessages(sessionId);
  }
}
