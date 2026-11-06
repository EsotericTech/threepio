/// The arguments and results of Claude's server tools, as `ClaudeAgenticModel`
/// puts them in `ServerToolCall.arguments` and `ServerToolResult.content`.
///
/// Port of eino-ext `components/model/agenticclaude/extension.go`. **Beta**,
/// as the whole agentic path is upstream.
///
/// Every class has value equality, a `toJson` in Go's JSON shape (snake_case
/// keys as Go's tags, zero values left out as `omitempty` does) and a
/// `fromJson` that reads that shape back with the rules of Go's
/// `mapstructure.Decode` (a number for an integer field is truncated, any
/// other type mismatch is an error). A checkpoint or a JSON round trip of an
/// agentic message therefore gives either these classes or plain maps, and
/// the model accepts both when the message is sent back, as Go does.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../../../errors.dart';
import 'claude_agentic_consts.dart';
import 'claude_agentic_utils.dart';

const _equality = DeepCollectionEquality();

/// Value equality, hash code and `toString` from `toJson`: two values of the
/// same class are equal when their JSON is. As every field defaults to its
/// Go zero value, which `toJson` leaves out, this is field equality.
mixin _JsonValue {
  Map<String, Object?> toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other.runtimeType == runtimeType &&
          other is _JsonValue &&
          _equality.equals(other.toJson(), toJson());

  @override
  int get hashCode => Object.hash(runtimeType, _equality.hash(toJson()));

  @override
  String toString() => '$runtimeType(${toJson()})';
}

// ---------------------------------------------------------------------------
// Decoding (mapstructure rules)
// ---------------------------------------------------------------------------

/// Reads the fields of one JSON object as `mapstructure.Decode` does.
final class _Fields {
  _Fields(this._json, this._path);

  final Map<String, Object?> _json;
  final String _path;

  String _at(String key) => _path.isEmpty ? key : '$_path.$key';

  ThreepioFormatException _mismatch(String key, String want, Object? got) =>
      ThreepioFormatException(
        "'${_at(key)}' expected type '$want', got unconvertible type "
        "'${claudeGoTypeName(got)}'",
      );

  String string(String key) => switch (_json[key]) {
    null => '',
    final String value => value,
    final value => throw _mismatch(key, 'string', value),
  };

  int integer(String key) => switch (_json[key]) {
    null => 0,
    final num value => value.toInt(),
    final value => throw _mismatch(key, 'int64', value),
  };

  bool boolean(String key) => switch (_json[key]) {
    null => false,
    final bool value => value,
    final value => throw _mismatch(key, 'bool', value),
  };

  T? object<T>(String key, T Function(_Fields fields) decode) =>
      switch (_json[key]) {
        null => null,
        final Map<Object?, Object?> value => decode(
          _Fields(value.cast<String, Object?>(), _at(key)),
        ),
        final value => throw ThreepioFormatException(
          "'${_at(key)}' expected a map, got '${claudeGoTypeName(value)}'",
        ),
      };

  List<T> objects<T>(String key, T Function(_Fields fields) decode) {
    final value = _json[key];
    if (value == null) return const [];
    if (value is! List<Object?>) {
      throw ThreepioFormatException(
        "'${_at(key)}': source data must be an array or slice, got "
        '${claudeGoTypeName(value)}',
      );
    }
    return [
      for (var i = 0; i < value.length; i++)
        if (value[i] case final Map<Object?, Object?> item)
          decode(_Fields(item.cast<String, Object?>(), '${_at(key)}[$i]'))
        else if (value[i] != null)
          throw ThreepioFormatException(
            "'${_at(key)}[$i]' expected a map, got "
            "'${claudeGoTypeName(value[i])}'",
          ),
    ];
  }

  List<String> strings(String key) {
    final value = _json[key];
    if (value == null) return const [];
    if (value is! List<Object?>) {
      throw ThreepioFormatException(
        "'${_at(key)}': source data must be an array or slice, got "
        '${claudeGoTypeName(value)}',
      );
    }
    return [
      for (var i = 0; i < value.length; i++)
        switch (value[i]) {
          final String item => item,
          final item => throw ThreepioFormatException(
            "'${_at(key)}[$i]' expected type 'string', got unconvertible "
            "type '${claudeGoTypeName(item)}'",
          ),
        },
    ];
  }
}

void _put(Map<String, Object?> json, String key, Object? value) {
  switch (value) {
    case null:
      return;
    case final String text when text.isEmpty:
      return;
    case final int number when number == 0:
      return;
    case final bool flag when !flag:
      return;
    case final List<Object?> list when list.isEmpty:
      return;
    case final _JsonValue object:
      json[key] = object.toJson();
    case final List<_JsonValue> objects:
      json[key] = [for (final object in objects) object.toJson()];
    default:
      json[key] = value;
  }
}

// ---------------------------------------------------------------------------
// Call arguments
// ---------------------------------------------------------------------------

/// The arguments of a Claude server tool call; the field of the tool that
/// was called is set.
///
/// Port of eino-ext agenticclaude `ServerToolCallArguments`.
@immutable
final class ClaudeServerToolCallArguments with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeServerToolCallArguments({
    this.webSearch,
    this.webFetch,
    this.codeExecution,
    this.bashCodeExecution,
    this.textEditorCodeExecution,
    this.toolSearchToolBm25,
    this.toolSearchToolRegex,
  });

  /// Reads [json] (Go's JSON shape, `{"web_search": {"query": …}}`).
  /// Throws a [ThreepioFormatException] for a field of the wrong type.
  factory ClaudeServerToolCallArguments.fromJson(Map<String, Object?> json) =>
      ClaudeServerToolCallArguments._read(_Fields(json, ''));

  factory ClaudeServerToolCallArguments._read(_Fields f) =>
      ClaudeServerToolCallArguments(
        webSearch: f.object('web_search', ClaudeWebSearchArguments._read),
        webFetch: f.object('web_fetch', ClaudeWebFetchArguments._read),
        codeExecution: f.object(
          'code_execution',
          ClaudeCodeExecutionArguments._read,
        ),
        bashCodeExecution: f.object(
          'bash_code_execution',
          ClaudeBashCodeExecutionArguments._read,
        ),
        textEditorCodeExecution: f.object(
          'text_editor_code_execution',
          ClaudeTextEditorCodeExecutionArguments._read,
        ),
        toolSearchToolBm25: f.object(
          'tool_search_tool_bm25',
          ClaudeToolSearchToolBm25Arguments._read,
        ),
        toolSearchToolRegex: f.object(
          'tool_search_tool_regex',
          ClaudeToolSearchToolRegexArguments._read,
        ),
      );

  /// Go: `WebSearch`, JSON `web_search`.
  final ClaudeWebSearchArguments? webSearch;

  /// Go: `WebFetch`, JSON `web_fetch`.
  final ClaudeWebFetchArguments? webFetch;

  /// Go: `CodeExecution`, JSON `code_execution`.
  final ClaudeCodeExecutionArguments? codeExecution;

  /// Go: `BashCodeExecution`, JSON `bash_code_execution`.
  final ClaudeBashCodeExecutionArguments? bashCodeExecution;

  /// Go: `TextEditorCodeExecution`, JSON `text_editor_code_execution`.
  final ClaudeTextEditorCodeExecutionArguments? textEditorCodeExecution;

  /// Go: `ToolSearchToolBm25`, JSON `tool_search_tool_bm25`.
  final ClaudeToolSearchToolBm25Arguments? toolSearchToolBm25;

  /// Go: `ToolSearchToolRegex`, JSON `tool_search_tool_regex`.
  final ClaudeToolSearchToolRegexArguments? toolSearchToolRegex;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'web_search', webSearch);
    _put(json, 'web_fetch', webFetch);
    _put(json, 'code_execution', codeExecution);
    _put(json, 'bash_code_execution', bashCodeExecution);
    _put(json, 'text_editor_code_execution', textEditorCodeExecution);
    _put(json, 'tool_search_tool_bm25', toolSearchToolBm25);
    _put(json, 'tool_search_tool_regex', toolSearchToolRegex);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebSearchArguments`.
@immutable
final class ClaudeWebSearchArguments with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebSearchArguments({this.query = ''});

  /// Reads Go's JSON shape.
  factory ClaudeWebSearchArguments.fromJson(Map<String, Object?> json) =>
      ClaudeWebSearchArguments._read(_Fields(json, ''));

  factory ClaudeWebSearchArguments._read(_Fields f) =>
      ClaudeWebSearchArguments(query: f.string('query'));

  /// Go: `Query`, JSON `query`.
  final String query;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'query', query);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebFetchArguments`.
@immutable
final class ClaudeWebFetchArguments with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebFetchArguments({this.url = ''});

  /// Reads Go's JSON shape.
  factory ClaudeWebFetchArguments.fromJson(Map<String, Object?> json) =>
      ClaudeWebFetchArguments._read(_Fields(json, ''));

  factory ClaudeWebFetchArguments._read(_Fields f) =>
      ClaudeWebFetchArguments(url: f.string('url'));

  /// Go: `URL`, JSON `url`.
  final String url;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'url', url);
    return json;
  }
}

/// Port of eino-ext agenticclaude `CodeExecutionArguments`.
@immutable
final class ClaudeCodeExecutionArguments with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeCodeExecutionArguments({this.code = ''});

  /// Reads Go's JSON shape.
  factory ClaudeCodeExecutionArguments.fromJson(Map<String, Object?> json) =>
      ClaudeCodeExecutionArguments._read(_Fields(json, ''));

  factory ClaudeCodeExecutionArguments._read(_Fields f) =>
      ClaudeCodeExecutionArguments(code: f.string('code'));

  /// Go: `Code`, JSON `code`.
  final String code;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'code', code);
    return json;
  }
}

/// Port of eino-ext agenticclaude `BashCodeExecutionArguments`.
@immutable
final class ClaudeBashCodeExecutionArguments with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeBashCodeExecutionArguments({this.command = ''});

  /// Reads Go's JSON shape.
  factory ClaudeBashCodeExecutionArguments.fromJson(
    Map<String, Object?> json,
  ) => ClaudeBashCodeExecutionArguments._read(_Fields(json, ''));

  factory ClaudeBashCodeExecutionArguments._read(_Fields f) =>
      ClaudeBashCodeExecutionArguments(command: f.string('command'));

  /// Go: `Command`, JSON `command`.
  final String command;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'command', command);
    return json;
  }
}

/// Port of eino-ext agenticclaude `TextEditorCodeExecutionArguments`.
@immutable
final class ClaudeTextEditorCodeExecutionArguments with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeTextEditorCodeExecutionArguments({
    this.command = '',
    this.path = '',
    this.fileText = '',
    this.oldStr = '',
    this.newStr = '',
  });

  /// Reads Go's JSON shape.
  factory ClaudeTextEditorCodeExecutionArguments.fromJson(
    Map<String, Object?> json,
  ) => ClaudeTextEditorCodeExecutionArguments._read(_Fields(json, ''));

  factory ClaudeTextEditorCodeExecutionArguments._read(_Fields f) =>
      ClaudeTextEditorCodeExecutionArguments(
        command: f.string('command'),
        path: f.string('path'),
        fileText: f.string('file_text'),
        oldStr: f.string('old_str'),
        newStr: f.string('new_str'),
      );

  /// Go: `Command`, JSON `command`.
  final String command;

  /// Go: `Path`, JSON `path`.
  final String path;

  /// Go: `FileText`, JSON `file_text`.
  final String fileText;

  /// Go: `OldStr`, JSON `old_str`.
  final String oldStr;

  /// Go: `NewStr`, JSON `new_str`.
  final String newStr;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'command', command);
    _put(json, 'path', path);
    _put(json, 'file_text', fileText);
    _put(json, 'old_str', oldStr);
    _put(json, 'new_str', newStr);
    return json;
  }
}

/// Port of eino-ext agenticclaude `ToolSearchToolBm25Arguments`.
@immutable
final class ClaudeToolSearchToolBm25Arguments with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeToolSearchToolBm25Arguments({this.query = ''});

  /// Reads Go's JSON shape.
  factory ClaudeToolSearchToolBm25Arguments.fromJson(
    Map<String, Object?> json,
  ) => ClaudeToolSearchToolBm25Arguments._read(_Fields(json, ''));

  factory ClaudeToolSearchToolBm25Arguments._read(_Fields f) =>
      ClaudeToolSearchToolBm25Arguments(query: f.string('query'));

  /// Go: `Query`, JSON `query`.
  final String query;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'query', query);
    return json;
  }
}

/// Port of eino-ext agenticclaude `ToolSearchToolRegexArguments`.
@immutable
final class ClaudeToolSearchToolRegexArguments with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeToolSearchToolRegexArguments({this.query = ''});

  /// Reads Go's JSON shape.
  factory ClaudeToolSearchToolRegexArguments.fromJson(
    Map<String, Object?> json,
  ) => ClaudeToolSearchToolRegexArguments._read(_Fields(json, ''));

  factory ClaudeToolSearchToolRegexArguments._read(_Fields f) =>
      ClaudeToolSearchToolRegexArguments(query: f.string('query'));

  /// Go: `Query`, JSON `query`.
  final String query;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'query', query);
    return json;
  }
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// The result of a Claude server tool call; the field of the tool that was
/// called is set.
///
/// Port of eino-ext agenticclaude `ServerToolResult` (renamed: eino's
/// `ServerToolResult` is the content block).
@immutable
final class ClaudeServerToolResult with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeServerToolResult({
    this.webSearch,
    this.webFetch,
    this.codeExecution,
    this.bashCodeExecution,
    this.textEditorCodeExecution,
    this.toolSearchToolBm25,
    this.toolSearchToolRegex,
  });

  /// Reads [json] (Go's JSON shape, `{"web_fetch": {"type": …}}`). Throws a
  /// [ThreepioFormatException] for a field of the wrong type.
  factory ClaudeServerToolResult.fromJson(Map<String, Object?> json) =>
      ClaudeServerToolResult._read(_Fields(json, ''));

  factory ClaudeServerToolResult._read(_Fields f) => ClaudeServerToolResult(
    webSearch: f.object('web_search', ClaudeWebSearchResult._read),
    webFetch: f.object('web_fetch', ClaudeWebFetchResult._read),
    codeExecution: f.object('code_execution', ClaudeCodeExecutionResult._read),
    bashCodeExecution: f.object(
      'bash_code_execution',
      ClaudeBashCodeExecutionResult._read,
    ),
    textEditorCodeExecution: f.object(
      'text_editor_code_execution',
      ClaudeTextEditorCodeExecutionResult._read,
    ),
    toolSearchToolBm25: f.object(
      'tool_search_tool_bm25',
      ClaudeToolSearchToolResult._read,
    ),
    toolSearchToolRegex: f.object(
      'tool_search_tool_regex',
      ClaudeToolSearchToolResult._read,
    ),
  );

  /// Go: `WebSearch`, JSON `web_search`.
  final ClaudeWebSearchResult? webSearch;

  /// Go: `WebFetch`, JSON `web_fetch`.
  final ClaudeWebFetchResult? webFetch;

  /// Go: `CodeExecution`, JSON `code_execution`.
  final ClaudeCodeExecutionResult? codeExecution;

  /// Go: `BashCodeExecution`, JSON `bash_code_execution`.
  final ClaudeBashCodeExecutionResult? bashCodeExecution;

  /// Go: `TextEditorCodeExecution`, JSON `text_editor_code_execution`.
  final ClaudeTextEditorCodeExecutionResult? textEditorCodeExecution;

  /// Go: `ToolSearchToolBm25`, JSON `tool_search_tool_bm25`.
  final ClaudeToolSearchToolResult? toolSearchToolBm25;

  /// Go: `ToolSearchToolRegex`, JSON `tool_search_tool_regex`.
  final ClaudeToolSearchToolResult? toolSearchToolRegex;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'web_search', webSearch);
    _put(json, 'web_fetch', webFetch);
    _put(json, 'code_execution', codeExecution);
    _put(json, 'bash_code_execution', bashCodeExecution);
    _put(json, 'text_editor_code_execution', textEditorCodeExecution);
    _put(json, 'tool_search_tool_bm25', toolSearchToolBm25);
    _put(json, 'tool_search_tool_regex', toolSearchToolRegex);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebSearchResult`.
@immutable
final class ClaudeWebSearchResult with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebSearchResult({this.type, this.result, this.error});

  /// Reads Go's JSON shape.
  factory ClaudeWebSearchResult.fromJson(Map<String, Object?> json) =>
      ClaudeWebSearchResult._read(_Fields(json, ''));

  factory ClaudeWebSearchResult._read(_Fields f) => ClaudeWebSearchResult(
    type: _type(f.string('type'), ClaudeWebSearchResultType.new),
    result: f.object('result', ClaudeWebSearchResultBlock._read),
    error: f.object('error', ClaudeWebSearchResultError._read),
  );

  /// Which of [result] and [error] is set.
  final ClaudeWebSearchResultType? type;

  /// Go: `Result`, JSON `result`.
  final ClaudeWebSearchResultBlock? result;

  /// Go: `Error`, JSON `error`.
  final ClaudeWebSearchResultError? error;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'type', type?.value);
    _put(json, 'result', result);
    _put(json, 'error', error);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebSearchResultBlock`.
@immutable
final class ClaudeWebSearchResultBlock with _JsonValue {
  ClaudeWebSearchResultBlock({
    List<ClaudeWebSearchResultItem> content = const [],
  }) : content = List.unmodifiable(content);

  /// Reads Go's JSON shape.
  factory ClaudeWebSearchResultBlock.fromJson(Map<String, Object?> json) =>
      ClaudeWebSearchResultBlock._read(_Fields(json, ''));

  factory ClaudeWebSearchResultBlock._read(_Fields f) =>
      ClaudeWebSearchResultBlock(
        content: f.objects('content', ClaudeWebSearchResultItem._read),
      );

  /// Go: `Content`, JSON `content`.
  final List<ClaudeWebSearchResultItem> content;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'content', content);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebSearchResultItem`.
@immutable
final class ClaudeWebSearchResultItem with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebSearchResultItem({
    this.title = '',
    this.url = '',
    this.encryptedContent = '',
    this.pageAge = '',
  });

  /// Reads Go's JSON shape.
  factory ClaudeWebSearchResultItem.fromJson(Map<String, Object?> json) =>
      ClaudeWebSearchResultItem._read(_Fields(json, ''));

  factory ClaudeWebSearchResultItem._read(_Fields f) =>
      ClaudeWebSearchResultItem(
        title: f.string('title'),
        url: f.string('url'),
        encryptedContent: f.string('encrypted_content'),
        pageAge: f.string('page_age'),
      );

  /// Go: `Title`, JSON `title`.
  final String title;

  /// Go: `URL`, JSON `url`.
  final String url;

  /// Go: `EncryptedContent`, JSON `encrypted_content`.
  final String encryptedContent;

  /// Go: `PageAge`, JSON `page_age`.
  final String pageAge;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'title', title);
    _put(json, 'url', url);
    _put(json, 'encrypted_content', encryptedContent);
    _put(json, 'page_age', pageAge);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebSearchResultError`.
@immutable
final class ClaudeWebSearchResultError with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebSearchResultError({this.code = ''});

  /// Reads Go's JSON shape.
  factory ClaudeWebSearchResultError.fromJson(Map<String, Object?> json) =>
      ClaudeWebSearchResultError._read(_Fields(json, ''));

  factory ClaudeWebSearchResultError._read(_Fields f) =>
      ClaudeWebSearchResultError(code: f.string('code'));

  /// Go: `Code`, JSON `code`.
  final String code;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'code', code);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebFetchResult`.
@immutable
final class ClaudeWebFetchResult with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebFetchResult({this.type, this.result, this.error});

  /// Reads Go's JSON shape.
  factory ClaudeWebFetchResult.fromJson(Map<String, Object?> json) =>
      ClaudeWebFetchResult._read(_Fields(json, ''));

  factory ClaudeWebFetchResult._read(_Fields f) => ClaudeWebFetchResult(
    type: _type(f.string('type'), ClaudeWebFetchResultType.new),
    result: f.object('result', ClaudeWebFetchResultBlock._read),
    error: f.object('error', ClaudeWebFetchResultError._read),
  );

  /// Which of [result] and [error] is set.
  final ClaudeWebFetchResultType? type;

  /// Go: `Result`, JSON `result`.
  final ClaudeWebFetchResultBlock? result;

  /// Go: `Error`, JSON `error`.
  final ClaudeWebFetchResultError? error;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'type', type?.value);
    _put(json, 'result', result);
    _put(json, 'error', error);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebFetchResultBlock`.
@immutable
final class ClaudeWebFetchResultBlock with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebFetchResultBlock({
    this.url = '',
    this.retrievedAt = '',
    this.content,
  });

  /// Reads Go's JSON shape.
  factory ClaudeWebFetchResultBlock.fromJson(Map<String, Object?> json) =>
      ClaudeWebFetchResultBlock._read(_Fields(json, ''));

  factory ClaudeWebFetchResultBlock._read(_Fields f) =>
      ClaudeWebFetchResultBlock(
        url: f.string('url'),
        retrievedAt: f.string('retrieved_at'),
        content: f.object('content', ClaudeWebFetchDocument._read),
      );

  /// Go: `URL`, JSON `url`.
  final String url;

  /// Go: `RetrievedAt`, JSON `retrieved_at`.
  final String retrievedAt;

  /// Go: `Content`, JSON `content`.
  final ClaudeWebFetchDocument? content;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'url', url);
    _put(json, 'retrieved_at', retrievedAt);
    _put(json, 'content', content);
    return json;
  }
}

/// The page a web fetch returned. Port of eino-ext agenticclaude
/// `WebFetchDocument`.
@immutable
final class ClaudeWebFetchDocument with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebFetchDocument({this.source, this.title = '', this.citations});

  /// Reads Go's JSON shape.
  factory ClaudeWebFetchDocument.fromJson(Map<String, Object?> json) =>
      ClaudeWebFetchDocument._read(_Fields(json, ''));

  factory ClaudeWebFetchDocument._read(_Fields f) => ClaudeWebFetchDocument(
    source: f.object('source', ClaudeWebFetchDocumentSource._read),
    title: f.string('title'),
    citations: f.object('citations', ClaudeWebFetchDocumentCitations._read),
  );

  /// Go: `Source`, JSON `source`.
  final ClaudeWebFetchDocumentSource? source;

  /// Go: `Title`, JSON `title`.
  final String title;

  /// Go: `Citations`, JSON `citations`.
  final ClaudeWebFetchDocumentCitations? citations;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'source', source);
    _put(json, 'title', title);
    _put(json, 'citations', citations);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebFetchDocumentSource`.
@immutable
final class ClaudeWebFetchDocumentSource with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebFetchDocumentSource({this.mimeType = '', this.data = ''});

  /// Reads Go's JSON shape.
  factory ClaudeWebFetchDocumentSource.fromJson(Map<String, Object?> json) =>
      ClaudeWebFetchDocumentSource._read(_Fields(json, ''));

  factory ClaudeWebFetchDocumentSource._read(_Fields f) =>
      ClaudeWebFetchDocumentSource(
        mimeType: f.string('media_type'),
        data: f.string('data'),
      );

  /// `text/plain` or `application/pdf` (JSON key `media_type`, as Go's).
  final String mimeType;

  /// Go: `Data`, JSON `data`.
  final String data;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'media_type', mimeType);
    _put(json, 'data', data);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebFetchDocumentCitations`.
@immutable
final class ClaudeWebFetchDocumentCitations with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebFetchDocumentCitations({this.enabled = false});

  /// Reads Go's JSON shape.
  factory ClaudeWebFetchDocumentCitations.fromJson(Map<String, Object?> json) =>
      ClaudeWebFetchDocumentCitations._read(_Fields(json, ''));

  factory ClaudeWebFetchDocumentCitations._read(_Fields f) =>
      ClaudeWebFetchDocumentCitations(enabled: f.boolean('enabled'));

  /// Go: `Enabled`, JSON `enabled`.
  final bool enabled;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'enabled', enabled);
    return json;
  }
}

/// Port of eino-ext agenticclaude `WebFetchResultError`.
@immutable
final class ClaudeWebFetchResultError with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeWebFetchResultError({this.code = ''});

  /// Reads Go's JSON shape.
  factory ClaudeWebFetchResultError.fromJson(Map<String, Object?> json) =>
      ClaudeWebFetchResultError._read(_Fields(json, ''));

  factory ClaudeWebFetchResultError._read(_Fields f) =>
      ClaudeWebFetchResultError(code: f.string('code'));

  /// Go: `Code`, JSON `code`.
  final String code;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'code', code);
    return json;
  }
}

/// A file a code execution produced. Port of eino-ext agenticclaude
/// `CodeExecutionOutput`.
@immutable
final class ClaudeCodeExecutionOutput with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeCodeExecutionOutput({this.fileId = ''});

  /// Reads Go's JSON shape.
  factory ClaudeCodeExecutionOutput.fromJson(Map<String, Object?> json) =>
      ClaudeCodeExecutionOutput._read(_Fields(json, ''));

  factory ClaudeCodeExecutionOutput._read(_Fields f) =>
      ClaudeCodeExecutionOutput(fileId: f.string('file_id'));

  /// Go: `FileID`, JSON `file_id`.
  final String fileId;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'file_id', fileId);
    return json;
  }
}

/// Port of eino-ext agenticclaude `CodeExecutionResult`.
@immutable
final class ClaudeCodeExecutionResult with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeCodeExecutionResult({
    this.type,
    this.result,
    this.encryptedResult,
    this.error,
  });

  /// Reads Go's JSON shape.
  factory ClaudeCodeExecutionResult.fromJson(Map<String, Object?> json) =>
      ClaudeCodeExecutionResult._read(_Fields(json, ''));

  factory ClaudeCodeExecutionResult._read(_Fields f) =>
      ClaudeCodeExecutionResult(
        type: _type(f.string('type'), ClaudeCodeExecutionResultType.new),
        result: f.object('result', ClaudeCodeExecutionResultBlock._read),
        encryptedResult: f.object(
          'encrypted_result',
          ClaudeEncryptedCodeExecutionResultBlock._read,
        ),
        error: f.object('error', ClaudeCodeExecutionResultError._read),
      );

  /// Which of [result], [encryptedResult] and [error] is set.
  final ClaudeCodeExecutionResultType? type;

  /// Go: `Result`, JSON `result`.
  final ClaudeCodeExecutionResultBlock? result;

  /// Go: `EncryptedResult`, JSON `encrypted_result`.
  final ClaudeEncryptedCodeExecutionResultBlock? encryptedResult;

  /// Go: `Error`, JSON `error`.
  final ClaudeCodeExecutionResultError? error;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'type', type?.value);
    _put(json, 'result', result);
    _put(json, 'encrypted_result', encryptedResult);
    _put(json, 'error', error);
    return json;
  }
}

/// Port of eino-ext agenticclaude `CodeExecutionResultBlock`.
@immutable
final class ClaudeCodeExecutionResultBlock with _JsonValue {
  ClaudeCodeExecutionResultBlock({
    List<ClaudeCodeExecutionOutput> content = const [],
    this.stdout = '',
    this.stderr = '',
    this.returnCode = 0,
  }) : content = List.unmodifiable(content);

  /// Reads Go's JSON shape.
  factory ClaudeCodeExecutionResultBlock.fromJson(Map<String, Object?> json) =>
      ClaudeCodeExecutionResultBlock._read(_Fields(json, ''));

  factory ClaudeCodeExecutionResultBlock._read(_Fields f) =>
      ClaudeCodeExecutionResultBlock(
        content: f.objects('content', ClaudeCodeExecutionOutput._read),
        stdout: f.string('stdout'),
        stderr: f.string('stderr'),
        returnCode: f.integer('return_code'),
      );

  /// Go: `Content`, JSON `content`.
  final List<ClaudeCodeExecutionOutput> content;

  /// Go: `Stdout`, JSON `stdout`.
  final String stdout;

  /// Go: `Stderr`, JSON `stderr`.
  final String stderr;

  /// Go: `ReturnCode`, JSON `return_code`.
  final int returnCode;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'content', content);
    _put(json, 'stdout', stdout);
    _put(json, 'stderr', stderr);
    _put(json, 'return_code', returnCode);
    return json;
  }
}

/// Port of eino-ext agenticclaude `EncryptedCodeExecutionResultBlock`.
@immutable
final class ClaudeEncryptedCodeExecutionResultBlock with _JsonValue {
  ClaudeEncryptedCodeExecutionResultBlock({
    List<ClaudeCodeExecutionOutput> content = const [],
    this.encryptedStdout = '',
    this.stderr = '',
    this.returnCode = 0,
  }) : content = List.unmodifiable(content);

  /// Reads Go's JSON shape.
  factory ClaudeEncryptedCodeExecutionResultBlock.fromJson(
    Map<String, Object?> json,
  ) => ClaudeEncryptedCodeExecutionResultBlock._read(_Fields(json, ''));

  factory ClaudeEncryptedCodeExecutionResultBlock._read(_Fields f) =>
      ClaudeEncryptedCodeExecutionResultBlock(
        content: f.objects('content', ClaudeCodeExecutionOutput._read),
        encryptedStdout: f.string('encrypted_stdout'),
        stderr: f.string('stderr'),
        returnCode: f.integer('return_code'),
      );

  /// Go: `Content`, JSON `content`.
  final List<ClaudeCodeExecutionOutput> content;

  /// Go: `EncryptedStdout`, JSON `encrypted_stdout`.
  final String encryptedStdout;

  /// Go: `Stderr`, JSON `stderr`.
  final String stderr;

  /// Go: `ReturnCode`, JSON `return_code`.
  final int returnCode;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'content', content);
    _put(json, 'encrypted_stdout', encryptedStdout);
    _put(json, 'stderr', stderr);
    _put(json, 'return_code', returnCode);
    return json;
  }
}

/// Port of eino-ext agenticclaude `CodeExecutionResultError`.
@immutable
final class ClaudeCodeExecutionResultError with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeCodeExecutionResultError({this.code = ''});

  /// Reads Go's JSON shape.
  factory ClaudeCodeExecutionResultError.fromJson(Map<String, Object?> json) =>
      ClaudeCodeExecutionResultError._read(_Fields(json, ''));

  factory ClaudeCodeExecutionResultError._read(_Fields f) =>
      ClaudeCodeExecutionResultError(code: f.string('code'));

  /// Go: `Code`, JSON `code`.
  final String code;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'code', code);
    return json;
  }
}

/// Port of eino-ext agenticclaude `BashCodeExecutionResult`.
@immutable
final class ClaudeBashCodeExecutionResult with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeBashCodeExecutionResult({this.type, this.result, this.error});

  /// Reads Go's JSON shape.
  factory ClaudeBashCodeExecutionResult.fromJson(Map<String, Object?> json) =>
      ClaudeBashCodeExecutionResult._read(_Fields(json, ''));

  factory ClaudeBashCodeExecutionResult._read(_Fields f) =>
      ClaudeBashCodeExecutionResult(
        type: _type(f.string('type'), ClaudeBashCodeExecutionResultType.new),
        result: f.object('result', ClaudeBashCodeExecutionResultBlock._read),
        error: f.object('error', ClaudeBashCodeExecutionResultError._read),
      );

  /// Which of [result] and [error] is set.
  final ClaudeBashCodeExecutionResultType? type;

  /// Go: `Result`, JSON `result`.
  final ClaudeBashCodeExecutionResultBlock? result;

  /// Go: `Error`, JSON `error`.
  final ClaudeBashCodeExecutionResultError? error;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'type', type?.value);
    _put(json, 'result', result);
    _put(json, 'error', error);
    return json;
  }
}

/// Port of eino-ext agenticclaude `BashCodeExecutionResultBlock`.
@immutable
final class ClaudeBashCodeExecutionResultBlock with _JsonValue {
  ClaudeBashCodeExecutionResultBlock({
    List<ClaudeCodeExecutionOutput> content = const [],
    this.stdout = '',
    this.stderr = '',
    this.returnCode = 0,
  }) : content = List.unmodifiable(content);

  /// Reads Go's JSON shape.
  factory ClaudeBashCodeExecutionResultBlock.fromJson(
    Map<String, Object?> json,
  ) => ClaudeBashCodeExecutionResultBlock._read(_Fields(json, ''));

  factory ClaudeBashCodeExecutionResultBlock._read(_Fields f) =>
      ClaudeBashCodeExecutionResultBlock(
        content: f.objects('content', ClaudeCodeExecutionOutput._read),
        stdout: f.string('stdout'),
        stderr: f.string('stderr'),
        returnCode: f.integer('return_code'),
      );

  /// Go: `Content`, JSON `content`.
  final List<ClaudeCodeExecutionOutput> content;

  /// Go: `Stdout`, JSON `stdout`.
  final String stdout;

  /// Go: `Stderr`, JSON `stderr`.
  final String stderr;

  /// Go: `ReturnCode`, JSON `return_code`.
  final int returnCode;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'content', content);
    _put(json, 'stdout', stdout);
    _put(json, 'stderr', stderr);
    _put(json, 'return_code', returnCode);
    return json;
  }
}

/// Port of eino-ext agenticclaude `BashCodeExecutionResultError`.
@immutable
final class ClaudeBashCodeExecutionResultError with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeBashCodeExecutionResultError({this.code = ''});

  /// Reads Go's JSON shape.
  factory ClaudeBashCodeExecutionResultError.fromJson(
    Map<String, Object?> json,
  ) => ClaudeBashCodeExecutionResultError._read(_Fields(json, ''));

  factory ClaudeBashCodeExecutionResultError._read(_Fields f) =>
      ClaudeBashCodeExecutionResultError(code: f.string('code'));

  /// Go: `Code`, JSON `code`.
  final String code;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'code', code);
    return json;
  }
}

/// Port of eino-ext agenticclaude `TextEditorCodeExecutionResult`.
@immutable
final class ClaudeTextEditorCodeExecutionResult with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeTextEditorCodeExecutionResult({
    this.type,
    this.view,
    this.create,
    this.strReplace,
    this.error,
  });

  /// Reads Go's JSON shape.
  factory ClaudeTextEditorCodeExecutionResult.fromJson(
    Map<String, Object?> json,
  ) => ClaudeTextEditorCodeExecutionResult._read(_Fields(json, ''));

  factory ClaudeTextEditorCodeExecutionResult._read(
    _Fields f,
  ) => ClaudeTextEditorCodeExecutionResult(
    type: _type(f.string('type'), ClaudeTextEditorCodeExecutionResultType.new),
    view: f.object('view', ClaudeTextEditorCodeExecutionViewResult._read),
    create: f.object('create', ClaudeTextEditorCodeExecutionCreateResult._read),
    strReplace: f.object(
      'str_replace',
      ClaudeTextEditorCodeExecutionStrReplaceResult._read,
    ),
    error: f.object('error', ClaudeTextEditorCodeExecutionResultError._read),
  );

  /// Which of [view], [create], [strReplace] and [error] is set.
  final ClaudeTextEditorCodeExecutionResultType? type;

  /// Go: `View`, JSON `view`.
  final ClaudeTextEditorCodeExecutionViewResult? view;

  /// Go: `Create`, JSON `create`.
  final ClaudeTextEditorCodeExecutionCreateResult? create;

  /// Go: `StrReplace`, JSON `str_replace`.
  final ClaudeTextEditorCodeExecutionStrReplaceResult? strReplace;

  /// Go: `Error`, JSON `error`.
  final ClaudeTextEditorCodeExecutionResultError? error;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'type', type?.value);
    _put(json, 'view', view);
    _put(json, 'create', create);
    _put(json, 'str_replace', strReplace);
    _put(json, 'error', error);
    return json;
  }
}

/// Port of eino-ext agenticclaude `TextEditorCodeExecutionViewResult`. The
/// line counts have Go's camelCase JSON keys (`numLines`, …).
@immutable
final class ClaudeTextEditorCodeExecutionViewResult with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeTextEditorCodeExecutionViewResult({
    this.fileType = '',
    this.content = '',
    this.numLines = 0,
    this.startLine = 0,
    this.totalLines = 0,
  });

  /// Reads Go's JSON shape.
  factory ClaudeTextEditorCodeExecutionViewResult.fromJson(
    Map<String, Object?> json,
  ) => ClaudeTextEditorCodeExecutionViewResult._read(_Fields(json, ''));

  factory ClaudeTextEditorCodeExecutionViewResult._read(_Fields f) =>
      ClaudeTextEditorCodeExecutionViewResult(
        fileType: f.string('file_type'),
        content: f.string('content'),
        numLines: f.integer('numLines'),
        startLine: f.integer('startLine'),
        totalLines: f.integer('totalLines'),
      );

  /// Go: `FileType`, JSON `file_type`.
  final String fileType;

  /// Go: `Content`, JSON `content`.
  final String content;

  /// Go: `NumLines`, JSON `numLines`.
  final int numLines;

  /// Go: `StartLine`, JSON `startLine`.
  final int startLine;

  /// Go: `TotalLines`, JSON `totalLines`.
  final int totalLines;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'file_type', fileType);
    _put(json, 'content', content);
    _put(json, 'numLines', numLines);
    _put(json, 'startLine', startLine);
    _put(json, 'totalLines', totalLines);
    return json;
  }
}

/// Port of eino-ext agenticclaude `TextEditorCodeExecutionCreateResult`.
@immutable
final class ClaudeTextEditorCodeExecutionCreateResult with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeTextEditorCodeExecutionCreateResult({this.isFileUpdate = false});

  /// Reads Go's JSON shape.
  factory ClaudeTextEditorCodeExecutionCreateResult.fromJson(
    Map<String, Object?> json,
  ) => ClaudeTextEditorCodeExecutionCreateResult._read(_Fields(json, ''));

  factory ClaudeTextEditorCodeExecutionCreateResult._read(_Fields f) =>
      ClaudeTextEditorCodeExecutionCreateResult(
        isFileUpdate: f.boolean('is_file_update'),
      );

  /// Go: `IsFileUpdate`, JSON `is_file_update`.
  final bool isFileUpdate;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'is_file_update', isFileUpdate);
    return json;
  }
}

/// Port of eino-ext agenticclaude `TextEditorCodeExecutionStrReplaceResult`.
/// The line numbers have Go's camelCase JSON keys (`oldStart`, …).
@immutable
final class ClaudeTextEditorCodeExecutionStrReplaceResult with _JsonValue {
  ClaudeTextEditorCodeExecutionStrReplaceResult({
    this.oldStart = 0,
    this.oldLines = 0,
    this.newStart = 0,
    this.newLines = 0,
    List<String> lines = const [],
  }) : lines = List.unmodifiable(lines);

  /// Reads Go's JSON shape.
  factory ClaudeTextEditorCodeExecutionStrReplaceResult.fromJson(
    Map<String, Object?> json,
  ) => ClaudeTextEditorCodeExecutionStrReplaceResult._read(_Fields(json, ''));

  factory ClaudeTextEditorCodeExecutionStrReplaceResult._read(_Fields f) =>
      ClaudeTextEditorCodeExecutionStrReplaceResult(
        oldStart: f.integer('oldStart'),
        oldLines: f.integer('oldLines'),
        newStart: f.integer('newStart'),
        newLines: f.integer('newLines'),
        lines: f.strings('lines'),
      );

  /// Go: `OldStart`, JSON `oldStart`.
  final int oldStart;

  /// Go: `OldLines`, JSON `oldLines`.
  final int oldLines;

  /// Go: `NewStart`, JSON `newStart`.
  final int newStart;

  /// Go: `NewLines`, JSON `newLines`.
  final int newLines;

  /// Go: `Lines`, JSON `lines`.
  final List<String> lines;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'oldStart', oldStart);
    _put(json, 'oldLines', oldLines);
    _put(json, 'newStart', newStart);
    _put(json, 'newLines', newLines);
    _put(json, 'lines', lines);
    return json;
  }
}

/// Port of eino-ext agenticclaude `TextEditorCodeExecutionResultError`.
@immutable
final class ClaudeTextEditorCodeExecutionResultError with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeTextEditorCodeExecutionResultError({
    this.code = '',
    this.message = '',
  });

  /// Reads Go's JSON shape.
  factory ClaudeTextEditorCodeExecutionResultError.fromJson(
    Map<String, Object?> json,
  ) => ClaudeTextEditorCodeExecutionResultError._read(_Fields(json, ''));

  factory ClaudeTextEditorCodeExecutionResultError._read(_Fields f) =>
      ClaudeTextEditorCodeExecutionResultError(
        code: f.string('code'),
        message: f.string('message'),
      );

  /// Go: `Code`, JSON `code`.
  final String code;

  /// Go: `Message`, JSON `message`.
  final String message;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'code', code);
    _put(json, 'message', message);
    return json;
  }
}

/// The result of a BM25 or regex tool search. Port of eino-ext
/// agenticclaude `ToolSearchToolResult`.
@immutable
final class ClaudeToolSearchToolResult with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeToolSearchToolResult({this.type, this.searchResult, this.error});

  /// Reads Go's JSON shape.
  factory ClaudeToolSearchToolResult.fromJson(Map<String, Object?> json) =>
      ClaudeToolSearchToolResult._read(_Fields(json, ''));

  factory ClaudeToolSearchToolResult._read(_Fields f) =>
      ClaudeToolSearchToolResult(
        type: _type(f.string('type'), ClaudeToolSearchToolResultType.new),
        searchResult: f.object(
          'search_result',
          ClaudeToolSearchToolSearchResult._read,
        ),
        error: f.object('error', ClaudeToolSearchToolResultError._read),
      );

  /// Which of [searchResult] and [error] is set.
  final ClaudeToolSearchToolResultType? type;

  /// Go: `SearchResult`, JSON `search_result`.
  final ClaudeToolSearchToolSearchResult? searchResult;

  /// Go: `Error`, JSON `error`.
  final ClaudeToolSearchToolResultError? error;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'type', type?.value);
    _put(json, 'search_result', searchResult);
    _put(json, 'error', error);
    return json;
  }
}

/// Port of eino-ext agenticclaude `ToolSearchToolSearchResult`.
@immutable
final class ClaudeToolSearchToolSearchResult with _JsonValue {
  ClaudeToolSearchToolSearchResult({
    List<ClaudeToolSearchToolReference> toolReferences = const [],
  }) : toolReferences = List.unmodifiable(toolReferences);

  /// Reads Go's JSON shape.
  factory ClaudeToolSearchToolSearchResult.fromJson(
    Map<String, Object?> json,
  ) => ClaudeToolSearchToolSearchResult._read(_Fields(json, ''));

  factory ClaudeToolSearchToolSearchResult._read(_Fields f) =>
      ClaudeToolSearchToolSearchResult(
        toolReferences: f.objects(
          'tool_references',
          ClaudeToolSearchToolReference._read,
        ),
      );

  /// Go: `ToolReferences`, JSON `tool_references`.
  final List<ClaudeToolSearchToolReference> toolReferences;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'tool_references', toolReferences);
    return json;
  }
}

/// Port of eino-ext agenticclaude `ToolSearchToolReference`.
@immutable
final class ClaudeToolSearchToolReference with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeToolSearchToolReference({this.toolName = ''});

  /// Reads Go's JSON shape.
  factory ClaudeToolSearchToolReference.fromJson(Map<String, Object?> json) =>
      ClaudeToolSearchToolReference._read(_Fields(json, ''));

  factory ClaudeToolSearchToolReference._read(_Fields f) =>
      ClaudeToolSearchToolReference(toolName: f.string('tool_name'));

  /// Go: `ToolName`, JSON `tool_name`.
  final String toolName;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'tool_name', toolName);
    return json;
  }
}

/// Port of eino-ext agenticclaude `ToolSearchToolResultError`.
@immutable
final class ClaudeToolSearchToolResultError with _JsonValue {
  /// A value with the fields that are given; the others keep Go's zero
  /// value.
  const ClaudeToolSearchToolResultError({this.code = '', this.message = ''});

  /// Reads Go's JSON shape.
  factory ClaudeToolSearchToolResultError.fromJson(Map<String, Object?> json) =>
      ClaudeToolSearchToolResultError._read(_Fields(json, ''));

  factory ClaudeToolSearchToolResultError._read(_Fields f) =>
      ClaudeToolSearchToolResultError(
        code: f.string('code'),
        message: f.string('message'),
      );

  /// Go: `Code`, JSON `code`.
  final String code;

  /// Go: `Message`, JSON `message`.
  final String message;

  @override
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    _put(json, 'code', code);
    _put(json, 'message', message);
    return json;
  }
}

/// The open value [make] builds from [value], or `null` for Go's empty
/// string.
T? _type<T>(String value, T Function(String value) make) =>
    value.isEmpty ? null : make(value);
