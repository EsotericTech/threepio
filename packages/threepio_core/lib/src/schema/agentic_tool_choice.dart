/// How an agentic model may call tools.
///
/// Port of eino `schema.AgenticToolChoice` and its parts (`schema/tool.go`).
/// **Beta**, as the whole agentic path is upstream.
///
/// Go declares these structs without JSON tags, so their JSON form is
/// `encoding/json`'s default: the Go field names as keys, every field
/// written (`null` for an absent pointer). `toJson`/`fromJson` reproduce it.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../errors.dart';
import 'agentic_wire.dart';
import 'tool_info.dart';

/// How an agentic model may use the tools it is given: not at all
/// ([ToolChoice.forbidden]), as it likes ([ToolChoice.allowed]), or at
/// least once ([ToolChoice.forced]), optionally narrowed to some tools.
///
/// Port of eino `schema.AgenticToolChoice`; passed as
/// `ChatModelOptions.agenticToolChoice` (Go `model.WithAgenticToolChoice`).
@immutable
final class AgenticToolChoice {
  const AgenticToolChoice({required this.type, this.allowed, this.forced});

  /// Reads Go's (untagged) JSON form, as [toJson] writes it.
  ///
  /// Throws [ThreepioFormatException] for an unknown `Type`.
  factory AgenticToolChoice.fromJson(Map<String, Object?> json) {
    final typeValue = readString(json, 'Type');
    final type = _toolChoices[typeValue] ??
        (throw ThreepioFormatException('unknown tool choice: "$typeValue"'));
    return AgenticToolChoice(
      type: type,
      allowed: readObject(json, 'Allowed', AgenticAllowedToolChoice.fromJson),
      forced: readObject(json, 'Forced', AgenticForcedToolChoice.fromJson),
    );
  }

  /// The mode.
  final ToolChoice type;

  /// The tools the model may call, with [ToolChoice.allowed].
  final AgenticAllowedToolChoice? allowed;

  /// The tools the model must call, with [ToolChoice.forced].
  final AgenticForcedToolChoice? forced;

  /// Go's JSON form: `{"Type": "allowed", "Allowed": {...}, "Forced": null}`.
  Map<String, Object?> toJson() => {
        'Type': _toolChoiceValue(type),
        'Allowed': allowed?.toJson(),
        'Forced': forced?.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticToolChoice &&
          other.type == type &&
          other.allowed == allowed &&
          other.forced == forced;

  @override
  int get hashCode => Object.hash(type, allowed, forced);

  @override
  String toString() =>
      'AgenticToolChoice(type: ${_toolChoiceValue(type)}, allowed: $allowed, '
      'forced: $forced)';
}

/// The wire values of [ToolChoice] (Go `schema.ToolChoice`).
String _toolChoiceValue(ToolChoice choice) => switch (choice) {
      ToolChoice.forbidden => 'forbidden',
      ToolChoice.allowed => 'allowed',
      ToolChoice.forced => 'forced',
    };

final Map<String, ToolChoice> _toolChoices = {
  for (final choice in ToolChoice.values) _toolChoiceValue(choice): choice,
};

/// Port of eino `schema.AgenticAllowedToolChoice`.
@immutable
final class AgenticAllowedToolChoice {
  AgenticAllowedToolChoice({List<AllowedTool> tools = const []})
      : tools = List.unmodifiable(tools);

  /// Reads Go's (untagged) JSON form.
  factory AgenticAllowedToolChoice.fromJson(Map<String, Object?> json) =>
      AgenticAllowedToolChoice(
        tools: readObjects(json, 'Tools', AllowedTool.fromJson),
      );

  final List<AllowedTool> tools;

  /// Go's JSON form: `{"Tools": [...]}` (`null` when there are none).
  Map<String, Object?> toJson() => {
        'Tools': tools.isEmpty ? null : [for (final t in tools) t.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticAllowedToolChoice &&
          const ListEquality<AllowedTool>().equals(other.tools, tools);

  @override
  int get hashCode => const ListEquality<AllowedTool>().hash(tools);

  @override
  String toString() => 'AgenticAllowedToolChoice(tools: $tools)';
}

/// Port of eino `schema.AgenticForcedToolChoice`.
@immutable
final class AgenticForcedToolChoice {
  AgenticForcedToolChoice({List<AllowedTool> tools = const []})
      : tools = List.unmodifiable(tools);

  /// Reads Go's (untagged) JSON form.
  factory AgenticForcedToolChoice.fromJson(Map<String, Object?> json) =>
      AgenticForcedToolChoice(
        tools: readObjects(json, 'Tools', AllowedTool.fromJson),
      );

  final List<AllowedTool> tools;

  /// Go's JSON form: `{"Tools": [...]}` (`null` when there are none).
  Map<String, Object?> toJson() => {
        'Tools': tools.isEmpty ? null : [for (final t in tools) t.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgenticForcedToolChoice &&
          const ListEquality<AllowedTool>().equals(other.tools, tools);

  @override
  int get hashCode => const ListEquality<AllowedTool>().hash(tools);

  @override
  String toString() => 'AgenticForcedToolChoice(tools: $tools)';
}

/// One tool a model is allowed or forced to call: a function tool
/// ([AllowedFunctionTool]), an MCP tool ([AllowedMcpTool]) or a server tool
/// ([AllowedServerTool]).
///
/// Port of eino `schema.AllowedTool`, whose "exactly one of `FunctionName`,
/// `MCPTool`, `ServerTool`" becomes a sealed class.
@immutable
sealed class AllowedTool {
  const AllowedTool();

  /// Reads Go's (untagged) JSON form:
  /// `{"FunctionName": "", "MCPTool": {...} | null, "ServerTool": {...} | null}`.
  ///
  /// Throws [ThreepioFormatException] when none of the three is set.
  factory AllowedTool.fromJson(Map<String, Object?> json) {
    final mcp = readMap(json, 'MCPTool');
    if (mcp != null) {
      return AllowedMcpTool(
        serverLabel: readString(mcp, 'ServerLabel'),
        name: readString(mcp, 'Name'),
      );
    }
    final server = readMap(json, 'ServerTool');
    if (server != null) return AllowedServerTool(readString(server, 'Name'));
    final function = readString(json, 'FunctionName');
    if (function.isNotEmpty) return AllowedFunctionTool(function);
    throw const ThreepioFormatException(
      'allowed tool names neither a function, an MCP tool nor a server tool',
    );
  }

  /// Go's JSON form: all three fields, the unused ones empty.
  Map<String, Object?> toJson();
}

/// A function tool, by name. Port of `AllowedTool.FunctionName`.
final class AllowedFunctionTool extends AllowedTool {
  const AllowedFunctionTool(this.name);

  final String name;

  @override
  Map<String, Object?> toJson() =>
      {'FunctionName': name, 'MCPTool': null, 'ServerTool': null};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AllowedFunctionTool && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'AllowedFunctionTool($name)';
}

/// An MCP tool of a server the model provider reaches. Port of eino
/// `schema.AllowedMCPTool`.
final class AllowedMcpTool extends AllowedTool {
  const AllowedMcpTool({required this.serverLabel, required this.name});

  final String serverLabel;
  final String name;

  @override
  Map<String, Object?> toJson() => {
        'FunctionName': '',
        'MCPTool': {'ServerLabel': serverLabel, 'Name': name},
        'ServerTool': null,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AllowedMcpTool &&
          other.serverLabel == serverLabel &&
          other.name == name;

  @override
  int get hashCode => Object.hash(serverLabel, name);

  @override
  String toString() => 'AllowedMcpTool(serverLabel: $serverLabel, name: $name)';
}

/// A tool built into the model provider. Port of eino
/// `schema.AllowedServerTool`.
final class AllowedServerTool extends AllowedTool {
  const AllowedServerTool(this.name);

  final String name;

  @override
  Map<String, Object?> toJson() => {
        'FunctionName': '',
        'MCPTool': null,
        'ServerTool': {'Name': name},
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AllowedServerTool && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'AllowedServerTool($name)';
}
