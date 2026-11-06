/// The names and wire values of `ClaudeAgenticModel`: the server tools, the
/// kinds of their results, and the constants of the requests.
///
/// Port of eino-ext `components/model/agenticclaude/consts.go`. **Beta**, as
/// the whole agentic path is upstream. Go's string types (`ServerToolName`,
/// `WebSearchResultType`, …) are open value classes here: the API may send
/// a value this version does not know, and it is kept as it is.
library;

import 'package:meta/meta.dart';

/// The name of a Claude server tool, as it appears in `server_tool_use`
/// blocks and in `AllowedServerTool` choices. An open set.
///
/// Port of eino-ext agenticclaude `ServerToolName`.
@immutable
final class ClaudeServerToolName {
  /// The server tool named [value].
  const ClaudeServerToolName(this.value);

  /// `web_search` (Go: `ServerToolNameWebSearch`).
  static const webSearch = ClaudeServerToolName('web_search');

  /// `web_fetch` (Go: `ServerToolNameWebFetch`).
  static const webFetch = ClaudeServerToolName('web_fetch');

  /// `code_execution` (Go: `ServerToolNameCodeExecution`).
  static const codeExecution = ClaudeServerToolName('code_execution');

  /// `bash_code_execution` (Go: `ServerToolNameBashCodeExecution`), one of
  /// the runtime names of the code execution tool.
  static const bashCodeExecution = ClaudeServerToolName('bash_code_execution');

  /// `text_editor_code_execution` (Go:
  /// `ServerToolNameTextEditorCodeExecution`), one of the runtime names of
  /// the code execution tool.
  static const textEditorCodeExecution = ClaudeServerToolName(
    'text_editor_code_execution',
  );

  /// `tool_search_tool_bm25` (Go: `ServerToolNameToolSearchToolBm25`).
  static const toolSearchToolBm25 = ClaudeServerToolName(
    'tool_search_tool_bm25',
  );

  /// `tool_search_tool_regex` (Go: `ServerToolNameToolSearchToolRegex`).
  static const toolSearchToolRegex = ClaudeServerToolName(
    'tool_search_tool_regex',
  );

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ClaudeServerToolName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The kind of a web search result. Port of eino-ext agenticclaude
/// `WebSearchResultType`.
@immutable
final class ClaudeWebSearchResultType {
  /// The result type whose wire value is [value].
  const ClaudeWebSearchResultType(this.value);

  /// `web_search_result`: the search found results.
  static const result = ClaudeWebSearchResultType('web_search_result');

  /// `web_search_tool_result_error`: the search failed.
  static const error = ClaudeWebSearchResultType(
    'web_search_tool_result_error',
  );

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ClaudeWebSearchResultType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The kind of a web fetch result. Port of eino-ext agenticclaude
/// `WebFetchResultType`.
@immutable
final class ClaudeWebFetchResultType {
  /// The result type whose wire value is [value].
  const ClaudeWebFetchResultType(this.value);

  /// `web_fetch_result`: the page was fetched.
  static const result = ClaudeWebFetchResultType('web_fetch_result');

  /// `web_fetch_tool_result_error`: the fetch failed.
  static const error = ClaudeWebFetchResultType('web_fetch_tool_result_error');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ClaudeWebFetchResultType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The kind of a code execution result. Port of eino-ext agenticclaude
/// `CodeExecutionResultType`.
@immutable
final class ClaudeCodeExecutionResultType {
  /// The result type whose wire value is [value].
  const ClaudeCodeExecutionResultType(this.value);

  /// `code_execution_result`.
  static const result = ClaudeCodeExecutionResultType('code_execution_result');

  /// `encrypted_code_execution_result`.
  static const encrypted = ClaudeCodeExecutionResultType(
    'encrypted_code_execution_result',
  );

  /// `code_execution_tool_result_error`.
  static const error = ClaudeCodeExecutionResultType(
    'code_execution_tool_result_error',
  );

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ClaudeCodeExecutionResultType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The kind of a bash code execution result. Port of eino-ext agenticclaude
/// `BashCodeExecutionResultType`.
@immutable
final class ClaudeBashCodeExecutionResultType {
  /// The result type whose wire value is [value].
  const ClaudeBashCodeExecutionResultType(this.value);

  /// `bash_code_execution_result`.
  static const result = ClaudeBashCodeExecutionResultType(
    'bash_code_execution_result',
  );

  /// `bash_code_execution_tool_result_error`.
  static const error = ClaudeBashCodeExecutionResultType(
    'bash_code_execution_tool_result_error',
  );

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ClaudeBashCodeExecutionResultType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The kind of a text editor code execution result. Port of eino-ext
/// agenticclaude `TextEditorCodeExecutionResultType`.
@immutable
final class ClaudeTextEditorCodeExecutionResultType {
  /// The result type whose wire value is [value].
  const ClaudeTextEditorCodeExecutionResultType(this.value);

  /// `text_editor_code_execution_tool_result_error`.
  static const error = ClaudeTextEditorCodeExecutionResultType(
    'text_editor_code_execution_tool_result_error',
  );

  /// `text_editor_code_execution_create_result`.
  static const create = ClaudeTextEditorCodeExecutionResultType(
    'text_editor_code_execution_create_result',
  );

  /// `text_editor_code_execution_str_replace_result`.
  static const strReplace = ClaudeTextEditorCodeExecutionResultType(
    'text_editor_code_execution_str_replace_result',
  );

  /// `text_editor_code_execution_view_result`.
  static const view = ClaudeTextEditorCodeExecutionResultType(
    'text_editor_code_execution_view_result',
  );

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ClaudeTextEditorCodeExecutionResultType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The kind of a tool search result. Port of eino-ext agenticclaude
/// `ToolSearchToolResultType`.
@immutable
final class ClaudeToolSearchToolResultType {
  /// The result type whose wire value is [value].
  const ClaudeToolSearchToolResultType(this.value);

  /// `tool_search_tool_search_result`: the tools the search found.
  static const searchResult = ClaudeToolSearchToolResultType(
    'tool_search_tool_search_result',
  );

  /// `tool_search_tool_result_error`: the search failed.
  static const error = ClaudeToolSearchToolResultType(
    'tool_search_tool_result_error',
  );

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is ClaudeToolSearchToolResultType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
