/// The call options of a tools node.
library;

import 'package:meta/meta.dart';

import '../components/tool/invokable_tool.dart';
import '../components/tool/tool_options.dart';

/// Other names a model may use for a tool and for its arguments.
///
/// Port of eino `compose.ToolAliasConfig`. Models sometimes call a tool by a
/// name of their own, or name an argument differently than the schema does;
/// aliases let the tools node run the call anyway.
@immutable
final class ToolAliasConfig {
  /// The aliases of one tool.
  const ToolAliasConfig({
    this.nameAliases = const [],
    this.argumentsAliases = const {},
  });

  /// Other names for the tool.
  final List<String> nameAliases;

  /// For an argument of the tool (the key), other names for it (the value).
  /// Only top-level arguments can have aliases.
  final Map<String, List<String>> argumentsAliases;
}

/// What a single call of a tools node changes about it.
///
/// Port of eino `compose.ToolsNodeOption` (`WithToolOption`, `WithToolList`,
/// `WithToolAliases`).
@immutable
final class ToolsNodeOptions {
  /// The options of one call.
  const ToolsNodeOptions({this.toolOptions, this.toolList, this.toolAliases});

  /// The options every tool of this call is run with.
  final ToolOptions? toolOptions;

  /// The tools of this call, in place of the ones the node was created with.
  final List<BaseTool>? toolList;

  /// The aliases of this call, in place of the ones the node was created
  /// with. They are applied to [toolList] when that is given as well.
  final Map<String, ToolAliasConfig>? toolAliases;

  /// These options with those of [other] on top: its [toolList] and
  /// [toolAliases] replace these, its [toolOptions] are merged in.
  ToolsNodeOptions merge(ToolsNodeOptions? other) => other == null
      ? this
      : ToolsNodeOptions(
          toolOptions:
              toolOptions?.merge(other.toolOptions) ?? other.toolOptions,
          toolList: other.toolList ?? toolList,
          toolAliases: other.toolAliases ?? toolAliases,
        );
}
