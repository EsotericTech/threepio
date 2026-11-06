/// What `ClaudeAgenticModel` keeps in the `extra` of its messages.
///
/// Port of eino-ext `components/model/agenticclaude/message_extra.go`.
/// **Beta**, as the whole agentic path is upstream.
library;

import '../../../../schema/agentic_message.dart';
import 'claude_agentic_utils.dart';

/// Claude-specific values of an agentic message.
extension ClaudeAgenticMessageExtras on AgenticMessage {
  /// The number of input tokens written into a new prompt cache entry
  /// (Anthropic's `cache_creation_input_tokens`), or `null` when the message
  /// does not say.
  ///
  /// Port of eino-ext agenticclaude `GetCacheCreationInputTokens`, whose
  /// `(int, bool)` becomes a nullable int. The model sets it only when the
  /// count is above zero. The tokens read from the cache are in
  /// `responseMeta.tokenUsage.promptTokenDetails.cachedTokens`. A stream
  /// reports the count once (with `message_start` or `message_delta`), and
  /// joining the chunks keeps it.
  int? get claudeCacheCreationInputTokens {
    final value = extra?[claudeAgenticKeyOfCacheCreationInputTokens];
    return value is int ? value : null;
  }
}
