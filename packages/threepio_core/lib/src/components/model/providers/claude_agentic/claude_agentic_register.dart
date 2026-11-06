/// The registrations of `ClaudeAgenticModel`'s server tool types.
///
/// Port of eino-ext `components/model/agenticclaude/register.go`. **Beta**,
/// as the whole agentic path is upstream.
library;

import '../../../../schema/concat.dart';
import '../../../../schema/type_registry.dart';
import 'claude_agentic_extension.dart';
import 'claude_agentic_utils.dart';

/// Registers [ClaudeServerToolCallArguments] and [ClaudeServerToolResult]
/// with `TypeRegistry`, under Go's names
/// (`_eino_ext_claude_server_tool_call_arguments`,
/// `_eino_ext_claude_server_tool_result`), so that agentic messages holding
/// them survive a checkpoint; and a `StreamConcat` function for the
/// arguments, so that the chunks of a streamed server tool call can be
/// joined. Idempotent.
///
/// Port of eino-ext agenticclaude `register.go`, which registers the names
/// when the package is loaded; a `ClaudeAgenticModel` calls this when it is
/// created. Call it yourself before reading such a checkpoint back in a
/// process that has not created a model yet. The concat function is not in
/// Go (see `concatClaudeServerToolCallArguments`).
void ensureClaudeAgenticTypesRegistered() {
  if (!TypeRegistry.isRegistered<ClaudeServerToolCallArguments>()) {
    TypeRegistry.registerName<ClaudeServerToolCallArguments>(
      '_eino_ext_claude_server_tool_call_arguments',
      fromJson: ClaudeServerToolCallArguments.fromJson,
      toJson: (arguments) => arguments.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<ClaudeServerToolResult>()) {
    TypeRegistry.registerName<ClaudeServerToolResult>(
      '_eino_ext_claude_server_tool_result',
      fromJson: ClaudeServerToolResult.fromJson,
      toJson: (result) => result.toJson(),
    );
  }
  if (StreamConcat.resolve<ClaudeServerToolCallArguments>() == null) {
    StreamConcat.register<ClaudeServerToolCallArguments>(
      concatClaudeServerToolCallArguments,
    );
  }
}
