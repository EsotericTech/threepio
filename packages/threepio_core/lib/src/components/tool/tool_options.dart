/// The options of a single tool call.
library;

import 'package:meta/meta.dart';

import '../../internal/option_extensions.dart';

/// Options passed to one call of a tool.
///
/// Port of eino `tool.Option`. The framework defines no option of its own for
/// tools. A tool that wants to be configured per call defines a class for its
/// options, the caller puts an instance into [extensions], and the tool reads
/// it back with [extension]:
///
/// ```dart
/// final class SearchOptions {
///   const SearchOptions({this.region = 'us'});
///   final String region;
/// }
///
/// // In the tool:
/// final region = (options?.extension<SearchOptions>() ?? const SearchOptions()).region;
///
/// // At the call:
/// await tool.invokableRun(
///   ctx,
///   arguments,
///   options: const ToolOptions(extensions: [SearchOptions(region: 'de')]),
/// );
/// ```
///
/// This replaces `tool.WrapImplSpecificOptFn` and
/// `tool.GetImplSpecificOptions`. A tool ignores extensions that are not its
/// own, so one options object can serve the calls of several tools.
@immutable
final class ToolOptions {
  /// Options that carry [extensions].
  const ToolOptions({this.extensions = const []});

  /// Implementation-specific options, each an instance of a class the tool it
  /// is meant for defines.
  final List<Object> extensions;

  /// The first of the [extensions] that is a [T], or `null`.
  T? extension<T extends Object>() => findExtension<T>(extensions);

  /// These options with those of [other] added. Where both carry an
  /// extension of the same type, [extension] returns the one of [other].
  ToolOptions merge(ToolOptions? other) => other == null
      ? this
      : ToolOptions(extensions: mergeExtensions(extensions, other.extensions));

  /// A copy with the given fields replaced.
  ToolOptions copyWith({List<Object>? extensions}) =>
      ToolOptions(extensions: extensions ?? this.extensions);
}
