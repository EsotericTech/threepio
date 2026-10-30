import '../../schema/message.dart';
import '../../schema/tool_info.dart';
import 'tool_call_context.dart';

/// Mutable state a [ChatModelAgent] run carries between iterations and
/// exposes to handlers (Eino's `ChatModelAgentState`).
class ChatModelAgentState {
  ChatModelAgentState({
    required this.messages,
    required this.toolInfos,
    this.instruction,
  });

  /// Full history sent to the model (system instruction first when set).
  List<Message> messages;

  /// Tools advertised to the model this iteration.
  List<ToolInfo> toolInfos;

  /// System instruction (may be rewritten per iteration).
  String? instruction;

  /// 0-based iteration counter.
  int iteration = 0;

  /// Scratch space shared by handlers.
  final Map<String, dynamic> values = {};
}

/// Continuation for [AgentHandler.wrapToolCall].
typedef ToolCallNext = Future<ToolOutput> Function(
  ToolCallContext context,
  String argumentsJson,
);

/// Cross-cutting hooks around a [ChatModelAgent] run (Eino's
/// `ChatModelAgentMiddleware`). Override only what you need.
abstract class AgentHandler {
  const AgentHandler();

  /// Runs before each model call; may rewrite history, instruction or tools.
  Future<void> beforeModel(ChatModelAgentState state) async {}

  /// Runs after each model call with the assembled assistant message.
  Future<void> afterModel(ChatModelAgentState state, Message response) async {}

  /// Wraps each tool invocation (approval, logging, timeouts…).
  Future<ToolOutput> wrapToolCall(
    ToolCallContext context,
    String argumentsJson,
    ToolCallNext next,
  ) =>
      next(context, argumentsJson);
}

/// Keeps the prompt within a character budget by dropping the oldest
/// non-system turns while keeping tool-call / tool-result pairs intact
/// (Eino's "reduction" hygiene middleware, character-based).
class HistoryBudgetHandler extends AgentHandler {
  const HistoryBudgetHandler({
    this.maxChars = 200000,
    this.keepLastTurns = 4,
  });

  /// Approximate prompt budget in characters (~4 chars per token).
  final int maxChars;

  /// Never drop these many most-recent non-system messages.
  final int keepLastTurns;

  @override
  Future<void> beforeModel(ChatModelAgentState state) async {
    state.messages = trim(state.messages);
  }

  /// Returns [messages] trimmed to the budget.
  List<Message> trim(List<Message> messages) {
    int size(Message m) =>
        m.content.length +
        (m.reasoningContent?.length ?? 0) +
        (m.toolCalls?.fold<int>(
              0,
              (n, c) => n + c.function.arguments.length + c.function.name.length,
            ) ??
            0) +
        (m.userInputMultiContent?.fold<int>(
              0,
              (n, p) => n + (p.text?.length ?? 64),
            ) ??
            0);

    var total = messages.fold<int>(0, (n, m) => n + size(m));
    if (total <= maxChars) return messages;

    final result = [...messages];
    // Index of the first droppable message (skip leading system messages).
    var cursor = 0;
    while (cursor < result.length && result[cursor].role == RoleType.system) {
      cursor++;
    }
    while (total > maxChars && result.length - cursor > keepLastTurns) {
      final removed = result.removeAt(cursor);
      total -= size(removed);
      // Dropping an assistant turn with tool calls orphans its results:
      // drop the matching tool messages too.
      if (removed.toolCalls != null && removed.toolCalls!.isNotEmpty) {
        final ids = removed.toolCalls!.map((c) => c.id).toSet();
        result.removeWhere((m) {
          final orphan = m.role == RoleType.tool && ids.contains(m.toolCallId);
          if (orphan) total -= size(m);
          return orphan;
        });
      }
    }
    return result;
  }
}
