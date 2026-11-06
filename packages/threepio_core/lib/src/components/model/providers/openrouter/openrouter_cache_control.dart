/// Prompt-cache breakpoints on single messages and parts for OpenRouter.
///
/// Port of eino-ext `openrouter.EnableMessageContentCacheControl`,
/// `EnableMessageInputPartCacheControl` and
/// `EnableMessageOutputPartCacheControl`. Go sets the marker in place; the
/// schema types are immutable here, so each extension returns a copy.
/// [OpenRouterChatModel] puts the marker into the request as the
/// `cache_control` of the message (plain content) or of the content part.
library;

import '../../../../schema/message.dart';
import 'openrouter_options.dart';

/// Key under `extra` holding a cache breakpoint (eino-ext
/// `openrouter_cache_control_key`).
const String openRouterCacheControlKey = 'openrouter_cache_control_key';

/// Cache breakpoints on a whole [Message].
extension OpenRouterMessageCacheControl on Message {
  /// A copy whose content is a cache breakpoint. Used when the message has
  /// plain content and no multi-part content.
  Message withOpenRouterCacheControl([
    OpenRouterCacheControl control = const OpenRouterCacheControl(),
  ]) =>
      copyWith(extra: {...?extra, openRouterCacheControlKey: control.toJson()});

  /// The breakpoint set with [withOpenRouterCacheControl], if any.
  OpenRouterCacheControl? get openRouterCacheControl =>
      OpenRouterCacheControl.fromJson(extra?[openRouterCacheControlKey]);
}

/// Cache breakpoints on a user input part (text parts, as in Go).
extension OpenRouterInputPartCacheControl on MessageInputPart {
  /// A copy that is a cache breakpoint.
  MessageInputPart withOpenRouterCacheControl([
    OpenRouterCacheControl control = const OpenRouterCacheControl(),
  ]) =>
      copyWith(extra: {...?extra, openRouterCacheControlKey: control.toJson()});

  /// The breakpoint set with [withOpenRouterCacheControl], if any.
  OpenRouterCacheControl? get openRouterCacheControl =>
      OpenRouterCacheControl.fromJson(extra?[openRouterCacheControlKey]);
}

/// Cache breakpoints on an assistant output part (text parts, as in Go).
extension OpenRouterOutputPartCacheControl on MessageOutputPart {
  /// A copy that is a cache breakpoint.
  MessageOutputPart withOpenRouterCacheControl([
    OpenRouterCacheControl control = const OpenRouterCacheControl(),
  ]) =>
      copyWith(extra: {...?extra, openRouterCacheControlKey: control.toJson()});

  /// The breakpoint set with [withOpenRouterCacheControl], if any.
  OpenRouterCacheControl? get openRouterCacheControl =>
      OpenRouterCacheControl.fromJson(extra?[openRouterCacheControlKey]);
}
