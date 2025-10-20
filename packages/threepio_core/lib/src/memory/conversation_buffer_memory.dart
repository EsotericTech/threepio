import '../schema/message.dart';
import 'chat_memory.dart';
import 'message_store.dart';

/// Simple conversation memory that stores all messages
///
/// This is the most basic memory type that keeps all conversation messages
/// in order. Best for short conversations or when you need complete history.
///
/// Example:
/// ```dart
/// final memory = ConversationBufferMemory(
///   sessionId: 'user-123',
/// );
///
/// // Save a conversation turn
/// await memory.saveContext(
///   inputMessage: Message.user('What is Flutter?'),
///   outputMessage: Message.assistant('Flutter is...'),
/// );
///
/// // Load history
/// final messages = await memory.loadMemoryMessages();
/// print('History length: ${messages.length}');
/// ```
class ConversationBufferMemory extends BaseMemory {
  ConversationBufferMemory({
    String? sessionId,
    MessageStore? store,
    super.options,
  })  : sessionId = sessionId ?? 'default',
        store = store ?? InMemoryMessageStore();

  /// Unique identifier for this conversation session
  final String sessionId;

  /// Storage backend for persisting messages
  final MessageStore store;

  @override
  Future<List<Message>> loadMemoryMessages() async {
    return await store.getMessages(sessionId);
  }

  @override
  Future<void> saveContext({
    required Message inputMessage,
    required Message outputMessage,
  }) async {
    await store.addMessage(sessionId, inputMessage);
    await store.addMessage(sessionId, outputMessage);
  }

  @override
  Future<void> addMessage(Message message) async {
    await store.addMessage(sessionId, message);
  }

  @override
  Future<void> clear() async {
    await store.deleteMessages(sessionId);
  }

  @override
  Future<int> get messageCount => store.getMessageCount(sessionId);

  /// Get messages as a formatted conversation string
  ///
  /// Useful for debugging or displaying conversation history.
  Future<String> getConversationString() async {
    return await loadMemoryString();
  }

  /// Get the last N messages
  Future<List<Message>> getLastMessages(int count) async {
    return await store.getLastMessages(sessionId, count);
  }
}
