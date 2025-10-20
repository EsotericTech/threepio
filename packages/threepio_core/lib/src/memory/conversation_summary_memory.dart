import '../components/model/base_chat_model.dart';
import '../schema/message.dart';
import 'chat_memory.dart';
import 'message_store.dart';

/// Conversation memory that summarizes old messages
///
/// This memory type keeps recent messages in full and summarizes older ones.
/// The summary is updated as new messages are added. This allows maintaining
/// long-term context while keeping token usage manageable.
///
/// Example:
/// ```dart
/// final memory = ConversationSummaryMemory(
///   sessionId: 'user-123',
///   chatModel: chatModel,
///   maxMessagesBeforeSummary: 10,
/// );
///
/// // After 10 messages, older ones get summarized
/// await memory.saveContext(
///   inputMessage: Message.user('Tell me about Flutter'),
///   outputMessage: Message.assistant('Flutter is...'),
/// );
///
/// // Summary is maintained automatically
/// final summary = await memory.getSummary();
/// ```
class ConversationSummaryMemory extends BaseMemory {
  ConversationSummaryMemory({
    String? sessionId,
    MessageStore? store,
    this.maxMessagesBeforeSummary = 10,
    this.summaryPrompt,
    required this.chatModel,
    super.options,
  })  : assert(
          maxMessagesBeforeSummary > 0,
          'maxMessagesBeforeSummary must be greater than 0',
        ),
        sessionId = sessionId ?? 'default',
        store = store ?? InMemoryMessageStore();

  /// Unique identifier for this conversation session
  final String sessionId;

  /// Storage backend for persisting messages
  final MessageStore store;

  /// Chat model used for generating summaries
  final BaseChatModel chatModel;

  /// Number of messages to keep before summarizing
  final int maxMessagesBeforeSummary;

  /// Custom prompt template for summarization
  ///
  /// The prompt should contain a placeholder for the messages to summarize.
  /// Default: "Progressively summarize the lines of conversation provided..."
  final String? summaryPrompt;

  /// Current summary of the conversation
  String? _summary;

  /// Get the current summary
  String? get summary => _summary;

  @override
  Future<List<Message>> loadMemoryMessages() async {
    final messages = await store.getMessages(sessionId);

    // Build result with summary first (if exists) then recent messages
    final result = <Message>[];

    if (_summary != null && _summary!.isNotEmpty) {
      result.add(Message(
        role: RoleType.system,
        content: 'Summary of previous conversation:\n$_summary',
      ));
    }

    // Keep the most recent messages
    final recentCount = maxMessagesBeforeSummary;
    if (messages.length <= recentCount) {
      result.addAll(messages);
    } else {
      result.addAll(messages.sublist(messages.length - recentCount));
    }

    return result;
  }

  @override
  Future<void> saveContext({
    required Message inputMessage,
    required Message outputMessage,
  }) async {
    await store.addMessage(sessionId, inputMessage);
    await store.addMessage(sessionId, outputMessage);

    // Check if we need to summarize
    final count = await store.getMessageCount(sessionId);
    if (count > maxMessagesBeforeSummary) {
      await _updateSummary();
    }
  }

  @override
  Future<void> addMessage(Message message) async {
    await store.addMessage(sessionId, message);

    final count = await store.getMessageCount(sessionId);
    if (count > maxMessagesBeforeSummary) {
      await _updateSummary();
    }
  }

  @override
  Future<void> clear() async {
    await store.deleteMessages(sessionId);
    _summary = null;
  }

  @override
  Future<int> get messageCount => store.getMessageCount(sessionId);

  /// Update the summary with old messages
  Future<void> _updateSummary() async {
    final allMessages = await store.getMessages(sessionId);

    // Messages to summarize (all except the most recent)
    final toSummarize = allMessages.sublist(
      0,
      allMessages.length - maxMessagesBeforeSummary,
    );

    if (toSummarize.isEmpty) {
      return;
    }

    // Build conversation text
    final conversationText = toSummarize.map((msg) {
      final prefix =
          msg.role == RoleType.user ? options.humanPrefix : options.aiPrefix;
      return '$prefix: ${msg.content}';
    }).join('\n');

    // Generate new summary
    final prompt = summaryPrompt ?? _getDefaultSummaryPrompt();
    final fullPrompt = prompt.replaceAll('{conversation}', conversationText);

    if (_summary != null && _summary!.isNotEmpty) {
      // Progressive summarization - include previous summary
      final progressivePrompt = '''
Current summary:
$_summary

New lines of conversation:
$conversationText

Provide an updated summary:
''';

      final response = await chatModel.generate([
        Message.user(progressivePrompt),
      ]);

      _summary = response.content;
    } else {
      // First summary
      final response = await chatModel.generate([
        Message.user(fullPrompt),
      ]);

      _summary = response.content;
    }

    // Delete the summarized messages
    await store.deleteMessagesRange(
      sessionId,
      start: 0,
      end: toSummarize.length,
    );
  }

  /// Get the default summarization prompt
  String _getDefaultSummaryPrompt() {
    return '''
Progressively summarize the lines of conversation provided, adding onto the previous summary.

Conversation:
{conversation}

Provide a concise summary of the conversation:
''';
  }

  /// Get the current summary
  Future<String?> getSummary() async {
    return _summary;
  }

  /// Manually trigger summarization
  ///
  /// Useful if you want to summarize before hitting the message limit.
  Future<void> summarize() async {
    final count = await messageCount;
    if (count > 0) {
      await _updateSummary();
    }
  }

  /// Get all messages including those that have been summarized
  ///
  /// Note: Messages that have been summarized and deleted cannot be retrieved.
  /// Only the summary and recent messages are available.
  Future<List<Message>> getAllAvailableMessages() async {
    return await store.getMessages(sessionId);
  }
}

/// Predicts when summarization will occur
class SummaryMemoryStats {
  const SummaryMemoryStats({
    required this.currentMessageCount,
    required this.maxBeforeSummary,
    required this.messagesUntilSummary,
    required this.hasSummary,
  });

  final int currentMessageCount;
  final int maxBeforeSummary;
  final int messagesUntilSummary;
  final bool hasSummary;

  bool get willSummarizeSoon => messagesUntilSummary <= 2;
  bool get needsSummary => messagesUntilSummary <= 0;
}
