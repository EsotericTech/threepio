/// The names and kinds the OpenAI Responses agentic model writes into server
/// tool blocks.
///
/// Port of eino-ext `components/model/agenticopenai/consts.go`. **Beta**, as
/// the whole agentic path is upstream. Go's string types are open value
/// classes here: a value the API adds later is kept as it comes.
library;

import 'package:meta/meta.dart';

/// The name of an OpenAI server tool, as it appears in `ServerToolCall.name`
/// and `ServerToolResult.name`.
///
/// Port of eino-ext `agenticopenai.ServerToolName`.
@immutable
final class OpenAIResponsesServerToolName {
  /// The tool name whose wire value is [value].
  const OpenAIResponsesServerToolName(this.value);

  /// `web_search`.
  static const webSearch = OpenAIResponsesServerToolName('web_search');

  /// `file_search`.
  static const fileSearch = OpenAIResponsesServerToolName('file_search');

  /// `code_interpreter`.
  static const codeInterpreter =
      OpenAIResponsesServerToolName('code_interpreter');

  /// `image_generation`.
  static const imageGeneration =
      OpenAIResponsesServerToolName('image_generation');

  /// `shell`.
  static const shell = OpenAIResponsesServerToolName('shell');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesServerToolName && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// What a web search call did. Port of eino-ext
/// `agenticopenai.WebSearchAction`.
@immutable
final class OpenAIResponsesWebSearchAction {
  /// The action whose wire value is [value].
  const OpenAIResponsesWebSearchAction(this.value);

  /// `search`: a search query.
  static const search = OpenAIResponsesWebSearchAction('search');

  /// `open_page`: a page was opened.
  static const openPage = OpenAIResponsesWebSearchAction('open_page');

  /// `find`: a pattern was looked up in a page.
  static const find = OpenAIResponsesWebSearchAction('find');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesWebSearchAction && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// How a shell command finished. Port of eino-ext
/// `agenticopenai.ShellOutputOutcomeType`.
@immutable
final class OpenAIResponsesShellOutputOutcomeType {
  /// The outcome whose wire value is [value].
  const OpenAIResponsesShellOutputOutcomeType(this.value);

  /// `timeout`.
  static const timeout = OpenAIResponsesShellOutputOutcomeType('timeout');

  /// `exit`.
  static const exit = OpenAIResponsesShellOutputOutcomeType('exit');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellOutputOutcomeType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Where shell commands run. Port of eino-ext
/// `agenticopenai.ShellEnvironmentType`.
@immutable
final class OpenAIResponsesShellEnvironmentType {
  /// The environment type whose wire value is [value].
  const OpenAIResponsesShellEnvironmentType(this.value);

  /// `local`.
  static const local = OpenAIResponsesShellEnvironmentType('local');

  /// `container_reference`.
  static const containerReference =
      OpenAIResponsesShellEnvironmentType('container_reference');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellEnvironmentType && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The kind of a code interpreter output. Port of eino-ext
/// `agenticopenai.CodeInterpreterOutputType`.
@immutable
final class OpenAIResponsesCodeInterpreterOutputType {
  /// The output type whose wire value is [value].
  const OpenAIResponsesCodeInterpreterOutputType(this.value);

  /// `logs`.
  static const logs = OpenAIResponsesCodeInterpreterOutputType('logs');

  /// `image`.
  static const image = OpenAIResponsesCodeInterpreterOutputType('image');

  /// The wire value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesCodeInterpreterOutputType &&
      other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
