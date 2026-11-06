/// Manual cache breakpoints on the content blocks and tool infos given to
/// `ClaudeAgenticModel`.
///
/// Port of the exported half of eino-ext
/// `components/model/agenticclaude/content_block_extra.go`. **Beta**, as the
/// whole agentic path is upstream. Go sets the value on the block in place;
/// the Dart blocks are immutable, so the setters return a copy. The other
/// half (the caller of a web search or web fetch result, kept in a result
/// block's `extra`) is internal (`claude_agentic_utils.dart`).
library;

import '../../../../schema/agentic_message.dart';
import '../../../../schema/tool_info.dart';
import '../claude/claude_config.dart';
import 'claude_agentic_utils.dart';

/// Manual cache breakpoints on content blocks of agentic messages.
extension ClaudeAgenticContentBlockExtras on ContentBlock {
  /// A copy of this block that carries a cache breakpoint with [control]
  /// (a `null` TTL is the API's default of five minutes), or this block
  /// itself when [control] is `null`.
  ///
  /// Port of eino-ext agenticclaude `SetContentBlockCacheControl`. A block
  /// with a breakpoint of its own is sent with that `cache_control`; the
  /// config's automatic `cacheControl` does not replace it. Only blocks the
  /// API can mark take one (text, images, documents, tool calls and
  /// results); a reasoning block is sent without it.
  ContentBlock withClaudeAgenticCacheControl(ClaudeCacheControl? control) {
    if (control == null) return this;
    return copyWith(
      extra: {
        ...?extra,
        claudeAgenticKeyOfCacheControlTtl: control.ttl?.value ?? '',
      },
    );
  }
}

/// Manual cache breakpoints on tools offered to `ClaudeAgenticModel`.
extension ClaudeAgenticToolInfoExtras on ToolInfo {
  /// A copy of this tool info that carries a cache breakpoint with
  /// [control], or this tool info itself when [control] is `null`.
  ///
  /// Port of eino-ext agenticclaude `SetToolInfoCacheControl`. The classic
  /// `ClaudeChatModel` reads `withClaudeCacheControl` instead: the two models
  /// keep the breakpoint under different keys, as in Go.
  ToolInfo withClaudeAgenticCacheControl(ClaudeCacheControl? control) {
    if (control == null) return this;
    return copyWith(
      extra: {
        ...?extra,
        claudeAgenticKeyOfCacheControlTtl: control.ttl?.value ?? '',
      },
    );
  }
}
