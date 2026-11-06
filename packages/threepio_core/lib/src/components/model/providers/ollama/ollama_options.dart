/// The per-call options only `OllamaChatModel` understands.
///
/// Port of eino-ext `components/model/ollama/call_option.go`.
library;

import 'package:meta/meta.dart';

import '../../chat_model_options.dart';

/// Options of one call of an `OllamaChatModel`.
///
/// Port of eino-ext `ollama.WithSeed` (the impl-specific `options` struct).
/// Pass them in `ChatModelOptions.extensions`, or add them to existing
/// options with [applyTo]:
///
/// ```dart
/// final answer = await model.generate(
///   messages,
///   options: const ChatModelOptions(
///     temperature: 0,
///     extensions: [OllamaRequestOptions(seed: 42)],
///   ),
/// );
/// ```
@immutable
final class OllamaRequestOptions {
  /// Options with the given fields set.
  const OllamaRequestOptions({this.seed});

  /// The random seed of this call (Go: `WithSeed`), sent as
  /// `options.seed`. It takes precedence over `OllamaOptions.seed` of the
  /// configuration.
  final int? seed;

  /// Returns [options] with these options added to its extensions, ahead of
  /// the ones it already has.
  ChatModelOptions applyTo(ChatModelOptions options) =>
      options.copyWith(extensions: [this, ...options.extensions]);

  @override
  bool operator ==(Object other) =>
      other is OllamaRequestOptions && other.seed == seed;

  @override
  int get hashCode => seed.hashCode;

  @override
  String toString() => 'OllamaRequestOptions(seed: $seed)';
}
