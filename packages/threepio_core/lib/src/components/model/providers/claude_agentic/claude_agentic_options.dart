/// The per-call options of `ClaudeAgenticModel`.
///
/// Port of eino-ext `components/model/agenticclaude/option.go`. **Beta**, as
/// the whole agentic path is upstream.
library;

import 'package:meta/meta.dart';

import '../../chat_model_options.dart';
import 'claude_agentic_config.dart';

/// Options for one call of a `ClaudeAgenticModel`, passed in
/// `ChatModelOptions.extensions`.
///
/// Port of eino-ext agenticclaude's implementation-specific options:
/// `WithServerTools`, `WithCustomHeaders`, `WithExtraFields` and
/// `WithRequestTimeout`. A field left `null` keeps the value of the
/// [ClaudeAgenticConfig] (the server tools: none).
///
/// ```dart
/// await model.generate(
///   messages,
///   options: const ClaudeAgenticOptions(
///     serverTools: [
///       ClaudeServerToolConfig(webSearch20260209: ClaudeWebSearchTool20260209()),
///     ],
///   ).toOptions(),
/// );
/// ```
///
/// When several of these are in the extensions of one call, they apply in
/// the order Go would apply the options: those that come later in the list
/// first, so that the first one wins field by field.
@immutable
final class ClaudeAgenticOptions {
  /// Options that set what they name and leave the rest to the config.
  const ClaudeAgenticOptions({
    this.serverTools,
    this.customHeaders,
    this.extraFields,
    this.requestTimeout,
  });

  /// The server tools available to the model (Go: `WithServerTools`).
  final List<ClaudeServerToolConfig>? serverTools;

  /// Headers for this call, replacing `ClaudeAgenticConfig.customHeaders`
  /// (Go: `WithCustomHeaders`).
  final Map<String, String>? customHeaders;

  /// Body fields for this call, replacing `ClaudeAgenticConfig.extraFields`
  /// (Go: `WithExtraFields`).
  final Map<String, Object?>? extraFields;

  /// The timeout of this call, overriding
  /// `ClaudeAgenticConfig.requestTimeout` when longer than zero (Go:
  /// `WithRequestTimeout`).
  final Duration? requestTimeout;

  /// [options] with these options added to its extensions, ahead of the ones
  /// it has.
  ChatModelOptions applyTo(ChatModelOptions options) =>
      options.copyWith(extensions: [this, ...options.extensions]);

  /// Call options that carry these options and nothing else.
  ChatModelOptions toOptions() => ChatModelOptions(extensions: [this]);

  @override
  String toString() =>
      'ClaudeAgenticOptions(serverTools: $serverTools, '
      'customHeaders: $customHeaders, extraFields: $extraFields, '
      'requestTimeout: $requestTimeout)';
}
