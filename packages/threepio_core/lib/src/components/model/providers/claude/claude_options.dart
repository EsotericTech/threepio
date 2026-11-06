/// The per-call options of `ClaudeChatModel`.
///
/// Port of eino-ext `components/model/claude/option.go`.
library;

import 'package:meta/meta.dart';

import '../../chat_model_options.dart';
import 'claude_config.dart';

/// Options for one call of a `ClaudeChatModel`, passed in
/// `ChatModelOptions.extensions`.
///
/// Port of eino-ext claude's implementation-specific options: `WithTopK`,
/// `WithThinkingConfig`, `WithDisableParallelToolUse`,
/// `WithAutoCacheControl`, `WithResponseFormat`, `WithRequestTimeout` and
/// `WithCustomHeaders` (the deprecated `WithThinking` and
/// `WithEnableAutoCache` are not ported). A field left `null` keeps the
/// value of the `ClaudeConfig`.
///
/// ```dart
/// await model.generate(
///   messages,
///   options: const ClaudeRequestOptions(
///     topK: 5,
///     autoCacheControl: ClaudeCacheControl(ttl: ClaudeCacheTtl.oneHour),
///   ).toOptions(),
/// );
/// ```
///
/// When several of these are in the extensions of one call, they apply in
/// the order Go would apply the options: those that come later in the list
/// first, so that the first one wins field by field (`ChatModelOptions.merge`
/// puts the options of the later merge first).
@immutable
final class ClaudeRequestOptions {
  /// Options that set what they name and leave the rest to the config.
  const ClaudeRequestOptions({
    this.topK,
    this.thinkingConfig,
    this.disableParallelToolUse,
    this.autoCacheControl,
    this.disableAutoCacheControl = false,
    this.responseFormat,
    this.requestTimeout,
    this.customHeaders,
  });

  /// Sample from the [topK] most likely tokens only (Go: `WithTopK`).
  final int? topK;

  /// Thinking for this call (Go: `WithThinkingConfig`).
  final ClaudeThinkingConfig? thinkingConfig;

  /// At most one tool call per turn (Go: `WithDisableParallelToolUse`, which
  /// can only set `true`).
  final bool? disableParallelToolUse;

  /// Automatic cache breakpoints for this call (Go:
  /// `WithAutoCacheControl(ctrl)` with a non-nil `ctrl`).
  final ClaudeCacheControl? autoCacheControl;

  /// No automatic cache breakpoints for this call, even when the config asks
  /// for them (Go: `WithAutoCacheControl(nil)`). Ignored when
  /// [autoCacheControl] is set.
  final bool disableAutoCacheControl;

  /// Structured output for this call (Go: `WithResponseFormat`).
  final ClaudeResponseFormat? responseFormat;

  /// The timeout of this call, overriding `ClaudeConfig.timeout` when longer
  /// than zero (Go: `WithRequestTimeout`).
  final Duration? requestTimeout;

  /// Headers added to the request of this call, after the config's
  /// `additionalHeaderFields` and in the same way (Go: `WithCustomHeaders`).
  final Map<String, String>? customHeaders;

  /// [options] with these options added to its extensions, ahead of the ones
  /// it has.
  ChatModelOptions applyTo(ChatModelOptions options) =>
      options.copyWith(extensions: [this, ...options.extensions]);

  /// Call options that carry these options and nothing else.
  ChatModelOptions toOptions() => ChatModelOptions(extensions: [this]);

  @override
  String toString() => 'ClaudeRequestOptions(topK: $topK, thinkingConfig: '
      '$thinkingConfig, disableParallelToolUse: $disableParallelToolUse, '
      'autoCacheControl: $autoCacheControl, disableAutoCacheControl: '
      '$disableAutoCacheControl, responseFormat: $responseFormat, '
      'requestTimeout: $requestTimeout, customHeaders: $customHeaders)';
}
