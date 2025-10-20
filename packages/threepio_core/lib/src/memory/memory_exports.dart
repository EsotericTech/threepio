/// Memory and conversation history management
///
/// This module provides tools for managing conversation history in LLM applications.
/// Different memory types offer various strategies for balancing context retention
/// with resource usage:
///
/// - **ConversationBufferMemory**: Keep all messages (simple, complete history)
/// - **ConversationBufferWindowMemory**: Keep last N messages (sliding window)
/// - **ConversationTokenBufferMemory**: Keep messages within token limit
/// - **ConversationSummaryMemory**: Summarize old messages, keep recent ones
///
/// Example:
/// ```dart
/// // Simple buffer memory
/// final memory = ConversationBufferMemory(sessionId: 'user-123');
///
/// // Window memory (keep last 10 messages)
/// final windowMemory = ConversationBufferWindowMemory(
///   sessionId: 'user-123',
///   k: 10,
/// );
///
/// // Summary memory (auto-summarize after 20 messages)
/// final summaryMemory = ConversationSummaryMemory(
///   sessionId: 'user-123',
///   chatModel: chatModel,
///   maxMessagesBeforeSummary: 20,
/// );
///
/// // Use with file persistence
/// final fileStore = FileMessageStore(
///   baseDirectory: Directory('conversations'),
/// );
/// final persistentMemory = ConversationBufferMemory(
///   sessionId: 'user-123',
///   store: fileStore,
/// );
/// ```
export 'chat_memory.dart';
export 'conversation_buffer_memory.dart';
export 'conversation_summary_memory.dart';
export 'conversation_window_memory.dart';
export 'message_store.dart';
