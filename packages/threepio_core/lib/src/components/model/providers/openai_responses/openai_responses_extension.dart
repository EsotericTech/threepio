/// The payloads of OpenAI server tool blocks: what a web search, file
/// search, code interpreter, image generation, shell or tool search call was
/// given and what it returned.
///
/// Port of eino-ext `components/model/agenticopenai/responses_extension.go`.
/// **Beta**, as the whole agentic path is upstream. An `OpenAIResponsesModel`
/// puts an [OpenAIResponsesServerToolCallArguments] in
/// `ServerToolCall.arguments` and an [OpenAIResponsesServerToolResult] in
/// `ServerToolResult.content`; `toJson`/`fromJson` give Go's JSON shape
/// (snake_case keys, empty fields left out), and a JSON map in either field
/// is read back as Go reads it (Go: `getServerToolCallArguments`).
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import '../../../../schema/tool_info.dart';
import 'openai_responses_consts.dart';
import 'openai_responses_utils.dart';

const _equality = DeepCollectionEquality();

/// What an OpenAI server tool call was given; the field of the tool that was
/// called is set.
///
/// Port of eino-ext `agenticopenai.ServerToolCallArguments`.
@immutable
final class OpenAIResponsesServerToolCallArguments {
  /// Arguments of one tool.
  const OpenAIResponsesServerToolCallArguments({
    this.webSearch,
    this.fileSearch,
    this.codeInterpreter,
    this.imageGeneration,
    this.shell,
    this.toolSearch,
  });

  /// Reads Go's JSON shape (`{"web_search": {...}}`).
  factory OpenAIResponsesServerToolCallArguments.fromJson(
    Map<String, Object?> json,
  ) {
    T? read<T>(String key, T Function(Map<String, Object?> json) fromJson) =>
        switch (asJsonObject(json[key])) {
          final Map<String, Object?> object => fromJson(object),
          _ => null,
        };
    return OpenAIResponsesServerToolCallArguments(
      webSearch: read('web_search', OpenAIResponsesWebSearchArguments.fromJson),
      fileSearch:
          read('file_search', OpenAIResponsesFileSearchArguments.fromJson),
      codeInterpreter: read(
        'code_interpreter',
        (_) => const OpenAIResponsesCodeInterpreterArguments(),
      ),
      imageGeneration: read(
        'image_generation',
        (_) => const OpenAIResponsesImageGenerationArguments(),
      ),
      shell: read('shell', OpenAIResponsesShellArguments.fromJson),
      toolSearch:
          read('tool_search', OpenAIResponsesToolSearchArguments.fromJson),
    );
  }

  final OpenAIResponsesWebSearchArguments? webSearch;
  final OpenAIResponsesFileSearchArguments? fileSearch;
  final OpenAIResponsesCodeInterpreterArguments? codeInterpreter;
  final OpenAIResponsesImageGenerationArguments? imageGeneration;
  final OpenAIResponsesShellArguments? shell;
  final OpenAIResponsesToolSearchArguments? toolSearch;

  /// Go's JSON shape.
  Map<String, Object?> toJson() => {
        if (webSearch case final v?) 'web_search': v.toJson(),
        if (fileSearch case final v?) 'file_search': v.toJson(),
        if (codeInterpreter case final v?) 'code_interpreter': v.toJson(),
        if (imageGeneration case final v?) 'image_generation': v.toJson(),
        if (shell case final v?) 'shell': v.toJson(),
        if (toolSearch case final v?) 'tool_search': v.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesServerToolCallArguments &&
      other.webSearch == webSearch &&
      other.fileSearch == fileSearch &&
      other.codeInterpreter == codeInterpreter &&
      other.imageGeneration == imageGeneration &&
      other.shell == shell &&
      other.toolSearch == toolSearch;

  @override
  int get hashCode => Object.hash(
        webSearch,
        fileSearch,
        codeInterpreter,
        imageGeneration,
        shell,
        toolSearch,
      );

  @override
  String toString() => 'OpenAIResponsesServerToolCallArguments(${toJson()})';
}

/// What an OpenAI server tool returned; the field of the tool that was
/// called is set.
///
/// Port of eino-ext `agenticopenai.ServerToolResult`.
@immutable
final class OpenAIResponsesServerToolResult {
  /// The result of one tool.
  const OpenAIResponsesServerToolResult({
    this.webSearch,
    this.fileSearch,
    this.codeInterpreter,
    this.imageGeneration,
    this.shell,
    this.toolSearch,
  });

  /// Reads Go's JSON shape (`{"web_search": {...}}`).
  factory OpenAIResponsesServerToolResult.fromJson(Map<String, Object?> json) {
    T? read<T>(String key, T Function(Map<String, Object?> json) fromJson) =>
        switch (asJsonObject(json[key])) {
          final Map<String, Object?> object => fromJson(object),
          _ => null,
        };
    return OpenAIResponsesServerToolResult(
      webSearch: read('web_search', OpenAIResponsesWebSearchResult.fromJson),
      fileSearch: read('file_search', OpenAIResponsesFileSearchResult.fromJson),
      codeInterpreter: read(
        'code_interpreter',
        OpenAIResponsesCodeInterpreterResult.fromJson,
      ),
      imageGeneration: read(
        'image_generation',
        OpenAIResponsesImageGenerationResult.fromJson,
      ),
      shell: read('shell', OpenAIResponsesShellResult.fromJson),
      toolSearch: read('tool_search', OpenAIResponsesToolSearchResult.fromJson),
    );
  }

  final OpenAIResponsesWebSearchResult? webSearch;
  final OpenAIResponsesFileSearchResult? fileSearch;
  final OpenAIResponsesCodeInterpreterResult? codeInterpreter;
  final OpenAIResponsesImageGenerationResult? imageGeneration;
  final OpenAIResponsesShellResult? shell;
  final OpenAIResponsesToolSearchResult? toolSearch;

  /// Go's JSON shape.
  Map<String, Object?> toJson() => {
        if (webSearch case final v?) 'web_search': v.toJson(),
        if (fileSearch case final v?) 'file_search': v.toJson(),
        if (codeInterpreter case final v?) 'code_interpreter': v.toJson(),
        if (imageGeneration case final v?) 'image_generation': v.toJson(),
        if (shell case final v?) 'shell': v.toJson(),
        if (toolSearch case final v?) 'tool_search': v.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesServerToolResult &&
      other.webSearch == webSearch &&
      other.fileSearch == fileSearch &&
      other.codeInterpreter == codeInterpreter &&
      other.imageGeneration == imageGeneration &&
      other.shell == shell &&
      other.toolSearch == toolSearch;

  @override
  int get hashCode => Object.hash(
        webSearch,
        fileSearch,
        codeInterpreter,
        imageGeneration,
        shell,
        toolSearch,
      );

  @override
  String toString() => 'OpenAIResponsesServerToolResult(${toJson()})';
}

/// The arguments of a web search call. Port of eino-ext
/// `agenticopenai.WebSearchArguments`.
@immutable
final class OpenAIResponsesWebSearchArguments {
  const OpenAIResponsesWebSearchArguments({
    this.actionType,
    this.search,
    this.openPage,
    this.find,
  });

  factory OpenAIResponsesWebSearchArguments.fromJson(
    Map<String, Object?> json,
  ) {
    final action = jsonString(json, 'action_type');
    final search = jsonObject(json, 'search');
    final openPage = jsonObject(json, 'open_page');
    final find = jsonObject(json, 'find');
    return OpenAIResponsesWebSearchArguments(
      actionType:
          action.isEmpty ? null : OpenAIResponsesWebSearchAction(action),
      search: search == null
          ? null
          : OpenAIResponsesWebSearchQuery(
              queries: jsonStringList(search, 'queries'),
            ),
      openPage: openPage == null
          ? null
          : OpenAIResponsesWebSearchOpenPage(url: jsonString(openPage, 'url')),
      find: find == null
          ? null
          : OpenAIResponsesWebSearchFind(
              url: jsonString(find, 'url'),
              pattern: jsonString(find, 'pattern'),
            ),
    );
  }

  /// What the call did: search, open_page or find.
  final OpenAIResponsesWebSearchAction? actionType;

  /// The queries, for a search.
  final OpenAIResponsesWebSearchQuery? search;

  /// The page, for open_page.
  final OpenAIResponsesWebSearchOpenPage? openPage;

  /// The page and pattern, for find.
  final OpenAIResponsesWebSearchFind? find;

  Map<String, Object?> toJson() => {
        if (actionType case final v? when v.value.isNotEmpty)
          'action_type': v.value,
        if (search case final v?) 'search': v.toJson(),
        if (openPage case final v?) 'open_page': v.toJson(),
        if (find case final v?) 'find': v.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesWebSearchArguments &&
      other.actionType == actionType &&
      other.search == search &&
      other.openPage == openPage &&
      other.find == find;

  @override
  int get hashCode => Object.hash(actionType, search, openPage, find);
}

/// The queries of a web search. Port of eino-ext
/// `agenticopenai.WebSearchQuery`.
@immutable
final class OpenAIResponsesWebSearchQuery {
  OpenAIResponsesWebSearchQuery({List<String> queries = const []})
      : queries = List.unmodifiable(queries);

  final List<String> queries;

  Map<String, Object?> toJson() => {if (queries.isNotEmpty) 'queries': queries};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesWebSearchQuery &&
      _equality.equals(other.queries, queries);

  @override
  int get hashCode => _equality.hash(queries);
}

/// The page a web search opened. Port of eino-ext
/// `agenticopenai.WebSearchOpenPage`.
@immutable
final class OpenAIResponsesWebSearchOpenPage {
  const OpenAIResponsesWebSearchOpenPage({this.url = ''});

  final String url;

  Map<String, Object?> toJson() => {if (url.isNotEmpty) 'url': url};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesWebSearchOpenPage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// The page and pattern of a find in page. Port of eino-ext
/// `agenticopenai.WebSearchFind`.
@immutable
final class OpenAIResponsesWebSearchFind {
  const OpenAIResponsesWebSearchFind({this.url = '', this.pattern = ''});

  final String url;
  final String pattern;

  Map<String, Object?> toJson() => {
        if (url.isNotEmpty) 'url': url,
        if (pattern.isNotEmpty) 'pattern': pattern,
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesWebSearchFind &&
      other.url == url &&
      other.pattern == pattern;

  @override
  int get hashCode => Object.hash(url, pattern);
}

/// The arguments of a file search call. Port of eino-ext
/// `agenticopenai.FileSearchArguments`.
@immutable
final class OpenAIResponsesFileSearchArguments {
  OpenAIResponsesFileSearchArguments({List<String> queries = const []})
      : queries = List.unmodifiable(queries);

  factory OpenAIResponsesFileSearchArguments.fromJson(
    Map<String, Object?> json,
  ) =>
      OpenAIResponsesFileSearchArguments(
        queries: jsonStringList(json, 'queries'),
      );

  final List<String> queries;

  Map<String, Object?> toJson() => {if (queries.isNotEmpty) 'queries': queries};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesFileSearchArguments &&
      _equality.equals(other.queries, queries);

  @override
  int get hashCode => _equality.hash(queries);
}

/// The sources a web search found. Port of eino-ext
/// `agenticopenai.WebSearchQueryResult`.
@immutable
final class OpenAIResponsesWebSearchQueryResult {
  OpenAIResponsesWebSearchQueryResult({
    List<OpenAIResponsesWebSearchQuerySource> sources = const [],
  }) : sources = List.unmodifiable(sources);

  final List<OpenAIResponsesWebSearchQuerySource> sources;

  Map<String, Object?> toJson() => {
        if (sources.isNotEmpty)
          'sources': [for (final s in sources) s.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesWebSearchQueryResult &&
      _equality.equals(other.sources, sources);

  @override
  int get hashCode => _equality.hash(sources);
}

/// One source of a web search. Port of eino-ext
/// `agenticopenai.WebSearchQuerySource`.
@immutable
final class OpenAIResponsesWebSearchQuerySource {
  const OpenAIResponsesWebSearchQuerySource({this.url = ''});

  final String url;

  Map<String, Object?> toJson() => {if (url.isNotEmpty) 'url': url};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesWebSearchQuerySource && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// The result of a web search call. Port of eino-ext
/// `agenticopenai.WebSearchResult`.
@immutable
final class OpenAIResponsesWebSearchResult {
  const OpenAIResponsesWebSearchResult({this.actionType, this.search});

  factory OpenAIResponsesWebSearchResult.fromJson(Map<String, Object?> json) {
    final action = jsonString(json, 'action_type');
    final search = jsonObject(json, 'search');
    return OpenAIResponsesWebSearchResult(
      actionType:
          action.isEmpty ? null : OpenAIResponsesWebSearchAction(action),
      search: search == null
          ? null
          : OpenAIResponsesWebSearchQueryResult(
              sources: [
                for (final source in jsonObjectList(search, 'sources'))
                  OpenAIResponsesWebSearchQuerySource(
                    url: jsonString(source, 'url'),
                  ),
              ],
            ),
    );
  }

  final OpenAIResponsesWebSearchAction? actionType;
  final OpenAIResponsesWebSearchQueryResult? search;

  Map<String, Object?> toJson() => {
        if (actionType case final v? when v.value.isNotEmpty)
          'action_type': v.value,
        if (search case final v?) 'search': v.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesWebSearchResult &&
      other.actionType == actionType &&
      other.search == search;

  @override
  int get hashCode => Object.hash(actionType, search);
}

/// The result of a file search call. Port of eino-ext
/// `agenticopenai.FileSearchResult`.
@immutable
final class OpenAIResponsesFileSearchResult {
  OpenAIResponsesFileSearchResult({
    List<OpenAIResponsesFileSearchResultItem> results = const [],
  }) : results = List.unmodifiable(results);

  factory OpenAIResponsesFileSearchResult.fromJson(Map<String, Object?> json) =>
      OpenAIResponsesFileSearchResult(
        results: [
          for (final item in jsonObjectList(json, 'results'))
            OpenAIResponsesFileSearchResultItem.fromJson(item),
        ],
      );

  final List<OpenAIResponsesFileSearchResultItem> results;

  Map<String, Object?> toJson() => {
        if (results.isNotEmpty)
          'results': [for (final r in results) r.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesFileSearchResult &&
      _equality.equals(other.results, results);

  @override
  int get hashCode => _equality.hash(results);
}

/// One file a file search matched. Port of eino-ext
/// `agenticopenai.FileSearchResultItem`.
@immutable
final class OpenAIResponsesFileSearchResultItem {
  OpenAIResponsesFileSearchResultItem({
    this.fileId = '',
    this.fileName = '',
    this.score = 0,
    this.text = '',
    Map<String, OpenAIResponsesFileSearchAttribute> attributes = const {},
  }) : attributes = Map.unmodifiable(attributes);

  factory OpenAIResponsesFileSearchResultItem.fromJson(
    Map<String, Object?> json,
  ) =>
      OpenAIResponsesFileSearchResultItem(
        fileId: jsonString(json, 'file_id'),
        fileName: jsonString(json, 'file_name'),
        score: jsonDouble(json, 'score'),
        text: jsonString(json, 'text'),
        attributes: {
          for (final MapEntry(:key, :value)
              in (jsonObject(json, 'attributes') ?? const {}).entries)
            if (asJsonObject(value) case final attribute?)
              key: OpenAIResponsesFileSearchAttribute.fromJson(attribute),
        },
      );

  final String fileId;
  final String fileName;

  /// The relevance, between 0 and 1.
  final double score;
  final String text;

  /// The metadata attached to the file.
  final Map<String, OpenAIResponsesFileSearchAttribute> attributes;

  Map<String, Object?> toJson() => {
        if (fileId.isNotEmpty) 'file_id': fileId,
        if (fileName.isNotEmpty) 'file_name': fileName,
        if (score != 0) 'score': score,
        if (text.isNotEmpty) 'text': text,
        if (attributes.isNotEmpty)
          'attributes': {
            for (final MapEntry(:key, :value) in attributes.entries)
              key: value.toJson(),
          },
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesFileSearchResultItem &&
      other.fileId == fileId &&
      other.fileName == fileName &&
      other.score == score &&
      other.text == text &&
      _equality.equals(other.attributes, attributes);

  @override
  int get hashCode =>
      Object.hash(fileId, fileName, score, text, _equality.hash(attributes));
}

/// An attribute value of a matched file: a string, a number or a bool.
/// Port of eino-ext `agenticopenai.FileSearchAttribute`.
@immutable
final class OpenAIResponsesFileSearchAttribute {
  const OpenAIResponsesFileSearchAttribute({
    this.ofString,
    this.ofFloat,
    this.ofBool,
  });

  factory OpenAIResponsesFileSearchAttribute.fromJson(
    Map<String, Object?> json,
  ) =>
      OpenAIResponsesFileSearchAttribute(
        ofString: json['of_string'] is String ? json['of_string']! as String : null,
        ofFloat: (json['of_float'] as num?)?.toDouble(),
        ofBool: json['of_bool'] is bool ? json['of_bool']! as bool : null,
      );

  final String? ofString;
  final double? ofFloat;
  final bool? ofBool;

  Map<String, Object?> toJson() => {
        if (ofString case final v?) 'of_string': v,
        if (ofFloat case final v?) 'of_float': v,
        if (ofBool case final v?) 'of_bool': v,
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesFileSearchAttribute &&
      other.ofString == ofString &&
      other.ofFloat == ofFloat &&
      other.ofBool == ofBool;

  @override
  int get hashCode => Object.hash(ofString, ofFloat, ofBool);
}

/// The arguments of a code interpreter call (none). Port of eino-ext
/// `agenticopenai.CodeInterpreterArguments`.
@immutable
final class OpenAIResponsesCodeInterpreterArguments {
  const OpenAIResponsesCodeInterpreterArguments();

  Map<String, Object?> toJson() => const {};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesCodeInterpreterArguments;

  @override
  int get hashCode => (OpenAIResponsesCodeInterpreterArguments).hashCode;
}

/// The result of a code interpreter call. Port of eino-ext
/// `agenticopenai.CodeInterpreterResult`.
@immutable
final class OpenAIResponsesCodeInterpreterResult {
  OpenAIResponsesCodeInterpreterResult({
    this.code = '',
    this.containerId = '',
    List<OpenAIResponsesCodeInterpreterOutput> outputs = const [],
  }) : outputs = List.unmodifiable(outputs);

  factory OpenAIResponsesCodeInterpreterResult.fromJson(
    Map<String, Object?> json,
  ) =>
      OpenAIResponsesCodeInterpreterResult(
        code: jsonString(json, 'code'),
        containerId: jsonString(json, 'container_id'),
        outputs: [
          for (final output in jsonObjectList(json, 'outputs'))
            OpenAIResponsesCodeInterpreterOutput.fromJson(output),
        ],
      );

  /// The code that ran.
  final String code;
  final String containerId;
  final List<OpenAIResponsesCodeInterpreterOutput> outputs;

  Map<String, Object?> toJson() => {
        if (code.isNotEmpty) 'code': code,
        if (containerId.isNotEmpty) 'container_id': containerId,
        if (outputs.isNotEmpty)
          'outputs': [for (final o in outputs) o.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesCodeInterpreterResult &&
      other.code == code &&
      other.containerId == containerId &&
      _equality.equals(other.outputs, outputs);

  @override
  int get hashCode => Object.hash(code, containerId, _equality.hash(outputs));
}

/// One output of a code interpreter call: logs or an image. Port of
/// eino-ext `agenticopenai.CodeInterpreterOutput`.
@immutable
final class OpenAIResponsesCodeInterpreterOutput {
  const OpenAIResponsesCodeInterpreterOutput({this.type, this.logs, this.image});

  factory OpenAIResponsesCodeInterpreterOutput.fromJson(
    Map<String, Object?> json,
  ) {
    final type = jsonString(json, 'type');
    final logs = jsonObject(json, 'logs');
    final image = jsonObject(json, 'image');
    return OpenAIResponsesCodeInterpreterOutput(
      type: type.isEmpty ? null : OpenAIResponsesCodeInterpreterOutputType(type),
      logs: logs == null
          ? null
          : OpenAIResponsesCodeInterpreterOutputLogs(
              logs: jsonString(logs, 'logs'),
            ),
      image: image == null
          ? null
          : OpenAIResponsesCodeInterpreterOutputImage(
              url: jsonString(image, 'url'),
            ),
    );
  }

  final OpenAIResponsesCodeInterpreterOutputType? type;
  final OpenAIResponsesCodeInterpreterOutputLogs? logs;
  final OpenAIResponsesCodeInterpreterOutputImage? image;

  Map<String, Object?> toJson() => {
        if (type case final v? when v.value.isNotEmpty) 'type': v.value,
        if (logs case final v?) 'logs': v.toJson(),
        if (image case final v?) 'image': v.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesCodeInterpreterOutput &&
      other.type == type &&
      other.logs == logs &&
      other.image == image;

  @override
  int get hashCode => Object.hash(type, logs, image);
}

/// The logs of a code interpreter run. Port of eino-ext
/// `agenticopenai.CodeInterpreterOutputLogs`.
@immutable
final class OpenAIResponsesCodeInterpreterOutputLogs {
  const OpenAIResponsesCodeInterpreterOutputLogs({this.logs = ''});

  final String logs;

  Map<String, Object?> toJson() => {if (logs.isNotEmpty) 'logs': logs};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesCodeInterpreterOutputLogs && other.logs == logs;

  @override
  int get hashCode => logs.hashCode;
}

/// An image a code interpreter run produced. Port of eino-ext
/// `agenticopenai.CodeInterpreterOutputImage`.
@immutable
final class OpenAIResponsesCodeInterpreterOutputImage {
  const OpenAIResponsesCodeInterpreterOutputImage({this.url = ''});

  final String url;

  Map<String, Object?> toJson() => {if (url.isNotEmpty) 'url': url};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesCodeInterpreterOutputImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// The arguments of an image generation call (none). Port of eino-ext
/// `agenticopenai.ImageGenerationArguments`.
@immutable
final class OpenAIResponsesImageGenerationArguments {
  const OpenAIResponsesImageGenerationArguments();

  Map<String, Object?> toJson() => const {};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesImageGenerationArguments;

  @override
  int get hashCode => (OpenAIResponsesImageGenerationArguments).hashCode;
}

/// The result of an image generation call. Port of eino-ext
/// `agenticopenai.ImageGenerationResult`.
@immutable
final class OpenAIResponsesImageGenerationResult {
  const OpenAIResponsesImageGenerationResult({this.imageBase64 = ''});

  factory OpenAIResponsesImageGenerationResult.fromJson(
    Map<String, Object?> json,
  ) =>
      OpenAIResponsesImageGenerationResult(
        imageBase64: jsonString(json, 'image_base64'),
      );

  /// The image, base64-encoded.
  final String imageBase64;

  Map<String, Object?> toJson() =>
      {if (imageBase64.isNotEmpty) 'image_base64': imageBase64};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesImageGenerationResult &&
      other.imageBase64 == imageBase64;

  @override
  int get hashCode => imageBase64.hashCode;
}

/// The arguments of a shell call. Port of eino-ext
/// `agenticopenai.ShellArguments`.
@immutable
final class OpenAIResponsesShellArguments {
  const OpenAIResponsesShellArguments({
    this.action,
    this.environment,
    this.createdBy = '',
  });

  factory OpenAIResponsesShellArguments.fromJson(Map<String, Object?> json) {
    final action = jsonObject(json, 'action');
    final environment = jsonObject(json, 'environment');
    return OpenAIResponsesShellArguments(
      action: action == null ? null : OpenAIResponsesShellAction.fromJson(action),
      environment: environment == null
          ? null
          : OpenAIResponsesShellEnvironment.fromJson(environment),
      createdBy: jsonString(json, 'created_by'),
    );
  }

  /// The commands to run.
  final OpenAIResponsesShellAction? action;

  /// Where to run them.
  final OpenAIResponsesShellEnvironment? environment;

  /// The id of whoever created the call.
  final String createdBy;

  Map<String, Object?> toJson() => {
        if (action case final v?) 'action': v.toJson(),
        if (environment case final v?) 'environment': v.toJson(),
        if (createdBy.isNotEmpty) 'created_by': createdBy,
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellArguments &&
      other.action == action &&
      other.environment == environment &&
      other.createdBy == createdBy;

  @override
  int get hashCode => Object.hash(action, environment, createdBy);
}

/// The commands of a shell call and their limits. Port of eino-ext
/// `agenticopenai.ShellAction`.
@immutable
final class OpenAIResponsesShellAction {
  OpenAIResponsesShellAction({
    List<String> commands = const [],
    this.timeoutMs = 0,
    this.maxOutputLength = 0,
  }) : commands = List.unmodifiable(commands);

  factory OpenAIResponsesShellAction.fromJson(Map<String, Object?> json) =>
      OpenAIResponsesShellAction(
        commands: jsonStringList(json, 'commands'),
        timeoutMs: jsonInt(json, 'timeout_ms'),
        maxOutputLength: jsonInt(json, 'max_output_length'),
      );

  final List<String> commands;

  /// The timeout of the commands, in milliseconds.
  final int timeoutMs;

  /// The most characters returned per command.
  final int maxOutputLength;

  Map<String, Object?> toJson() => {
        if (commands.isNotEmpty) 'commands': commands,
        if (timeoutMs != 0) 'timeout_ms': timeoutMs,
        if (maxOutputLength != 0) 'max_output_length': maxOutputLength,
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellAction &&
      _equality.equals(other.commands, commands) &&
      other.timeoutMs == timeoutMs &&
      other.maxOutputLength == maxOutputLength;

  @override
  int get hashCode =>
      Object.hash(_equality.hash(commands), timeoutMs, maxOutputLength);
}

/// Where shell commands run. Port of eino-ext
/// `agenticopenai.ShellEnvironment`.
@immutable
final class OpenAIResponsesShellEnvironment {
  const OpenAIResponsesShellEnvironment({
    this.type,
    this.local,
    this.containerReference,
  });

  factory OpenAIResponsesShellEnvironment.fromJson(Map<String, Object?> json) {
    final type = jsonString(json, 'type');
    final local = jsonObject(json, 'local');
    final container = jsonObject(json, 'container_reference');
    return OpenAIResponsesShellEnvironment(
      type: type.isEmpty ? null : OpenAIResponsesShellEnvironmentType(type),
      local: local == null
          ? null
          : OpenAIResponsesShellEnvironmentLocal(
              skills: [
                for (final skill in jsonObjectList(local, 'skills'))
                  OpenAIResponsesShellEnvironmentLocalSkill(
                    name: jsonString(skill, 'name'),
                    description: jsonString(skill, 'description'),
                    path: jsonString(skill, 'path'),
                  ),
              ],
            ),
      containerReference: container == null
          ? null
          : OpenAIResponsesShellEnvironmentContainerReference(
              containerId: jsonString(container, 'container_id'),
            ),
    );
  }

  final OpenAIResponsesShellEnvironmentType? type;

  /// Set when [type] is `local`.
  final OpenAIResponsesShellEnvironmentLocal? local;

  /// Set when [type] is `container_reference`.
  final OpenAIResponsesShellEnvironmentContainerReference? containerReference;

  Map<String, Object?> toJson() => {
        if (type case final v? when v.value.isNotEmpty) 'type': v.value,
        if (local case final v?) 'local': v.toJson(),
        if (containerReference case final v?) 'container_reference': v.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellEnvironment &&
      other.type == type &&
      other.local == local &&
      other.containerReference == containerReference;

  @override
  int get hashCode => Object.hash(type, local, containerReference);
}

/// A local shell environment. Port of eino-ext
/// `agenticopenai.ShellEnvironmentLocal`.
@immutable
final class OpenAIResponsesShellEnvironmentLocal {
  OpenAIResponsesShellEnvironmentLocal({
    List<OpenAIResponsesShellEnvironmentLocalSkill> skills = const [],
  }) : skills = List.unmodifiable(skills);

  /// The skills available in the environment.
  final List<OpenAIResponsesShellEnvironmentLocalSkill> skills;

  Map<String, Object?> toJson() => {
        if (skills.isNotEmpty) 'skills': [for (final s in skills) s.toJson()],
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellEnvironmentLocal &&
      _equality.equals(other.skills, skills);

  @override
  int get hashCode => _equality.hash(skills);
}

/// A skill of a local shell environment. Port of eino-ext
/// `agenticopenai.ShellEnvironmentLocalSkill`.
@immutable
final class OpenAIResponsesShellEnvironmentLocalSkill {
  const OpenAIResponsesShellEnvironmentLocalSkill({
    this.name = '',
    this.description = '',
    this.path = '',
  });

  final String name;
  final String description;

  /// The directory that holds the skill.
  final String path;

  Map<String, Object?> toJson() => {
        if (name.isNotEmpty) 'name': name,
        if (description.isNotEmpty) 'description': description,
        if (path.isNotEmpty) 'path': path,
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellEnvironmentLocalSkill &&
      other.name == name &&
      other.description == description &&
      other.path == path;

  @override
  int get hashCode => Object.hash(name, description, path);
}

/// The container shell commands run in. Port of eino-ext
/// `agenticopenai.ShellEnvironmentContainerReference`.
@immutable
final class OpenAIResponsesShellEnvironmentContainerReference {
  const OpenAIResponsesShellEnvironmentContainerReference({
    this.containerId = '',
  });

  final String containerId;

  Map<String, Object?> toJson() =>
      {if (containerId.isNotEmpty) 'container_id': containerId};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellEnvironmentContainerReference &&
      other.containerId == containerId;

  @override
  int get hashCode => containerId.hashCode;
}

/// The result of a shell call. Port of eino-ext
/// `agenticopenai.ShellResult`.
@immutable
final class OpenAIResponsesShellResult {
  OpenAIResponsesShellResult({
    this.maxOutputLength = 0,
    List<OpenAIResponsesShellOutputItem> outputs = const [],
    this.createdBy = '',
  }) : outputs = List.unmodifiable(outputs);

  factory OpenAIResponsesShellResult.fromJson(Map<String, Object?> json) =>
      OpenAIResponsesShellResult(
        maxOutputLength: jsonInt(json, 'max_output_length'),
        outputs: [
          for (final output in jsonObjectList(json, 'outputs'))
            OpenAIResponsesShellOutputItem.fromJson(output),
        ],
        createdBy: jsonString(json, 'created_by'),
      );

  /// The most characters returned per command.
  final int maxOutputLength;

  /// The output of each command.
  final List<OpenAIResponsesShellOutputItem> outputs;
  final String createdBy;

  Map<String, Object?> toJson() => {
        if (maxOutputLength != 0) 'max_output_length': maxOutputLength,
        if (outputs.isNotEmpty) 'outputs': [for (final o in outputs) o.toJson()],
        if (createdBy.isNotEmpty) 'created_by': createdBy,
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellResult &&
      other.maxOutputLength == maxOutputLength &&
      _equality.equals(other.outputs, outputs) &&
      other.createdBy == createdBy;

  @override
  int get hashCode =>
      Object.hash(maxOutputLength, _equality.hash(outputs), createdBy);
}

/// The output of one shell command. Port of eino-ext
/// `agenticopenai.ShellOutputItem`.
@immutable
final class OpenAIResponsesShellOutputItem {
  const OpenAIResponsesShellOutputItem({
    this.stdout = '',
    this.stderr = '',
    this.outcome,
    this.createdBy = '',
  });

  factory OpenAIResponsesShellOutputItem.fromJson(Map<String, Object?> json) {
    final outcome = jsonObject(json, 'outcome');
    return OpenAIResponsesShellOutputItem(
      stdout: jsonString(json, 'stdout'),
      stderr: jsonString(json, 'stderr'),
      outcome:
          outcome == null ? null : OpenAIResponsesShellOutputOutcome.fromJson(outcome),
      createdBy: jsonString(json, 'created_by'),
    );
  }

  final String stdout;
  final String stderr;

  /// How the command finished.
  final OpenAIResponsesShellOutputOutcome? outcome;
  final String createdBy;

  Map<String, Object?> toJson() => {
        if (stdout.isNotEmpty) 'stdout': stdout,
        if (stderr.isNotEmpty) 'stderr': stderr,
        if (outcome case final v?) 'outcome': v.toJson(),
        if (createdBy.isNotEmpty) 'created_by': createdBy,
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellOutputItem &&
      other.stdout == stdout &&
      other.stderr == stderr &&
      other.outcome == outcome &&
      other.createdBy == createdBy;

  @override
  int get hashCode => Object.hash(stdout, stderr, outcome, createdBy);
}

/// How a shell command finished: it exited or timed out. Port of eino-ext
/// `agenticopenai.ShellOutputOutcome`.
@immutable
final class OpenAIResponsesShellOutputOutcome {
  const OpenAIResponsesShellOutputOutcome({this.type, this.exit});

  factory OpenAIResponsesShellOutputOutcome.fromJson(
    Map<String, Object?> json,
  ) {
    final type = jsonString(json, 'type');
    final exit = jsonObject(json, 'exit');
    return OpenAIResponsesShellOutputOutcome(
      type: type.isEmpty ? null : OpenAIResponsesShellOutputOutcomeType(type),
      exit: exit == null
          ? null
          : OpenAIResponsesShellOutputOutcomeExit(
              exitCode: jsonInt(exit, 'exit_code'),
            ),
    );
  }

  final OpenAIResponsesShellOutputOutcomeType? type;

  /// Set when [type] is `exit`.
  final OpenAIResponsesShellOutputOutcomeExit? exit;

  Map<String, Object?> toJson() => {
        if (type case final v? when v.value.isNotEmpty) 'type': v.value,
        if (exit case final v?) 'exit': v.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellOutputOutcome &&
      other.type == type &&
      other.exit == exit;

  @override
  int get hashCode => Object.hash(type, exit);
}

/// The exit code of a shell command. Port of eino-ext
/// `agenticopenai.ShellOutputOutcomeExit`.
@immutable
final class OpenAIResponsesShellOutputOutcomeExit {
  const OpenAIResponsesShellOutputOutcomeExit({this.exitCode = 0});

  final int exitCode;

  Map<String, Object?> toJson() => {if (exitCode != 0) 'exit_code': exitCode};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesShellOutputOutcomeExit &&
      other.exitCode == exitCode;

  @override
  int get hashCode => exitCode.hashCode;
}

/// The arguments of a server-side tool search call: the JSON value the
/// model sent.
///
/// Port of eino-ext `agenticopenai.ToolSearchArguments`. Go keeps the raw
/// JSON bytes (`json.RawMessage`); here [arguments] is the decoded JSON
/// value, which [toJson] embeds as it is, as Go does.
@immutable
final class OpenAIResponsesToolSearchArguments {
  const OpenAIResponsesToolSearchArguments({this.arguments});

  factory OpenAIResponsesToolSearchArguments.fromJson(
    Map<String, Object?> json,
  ) =>
      OpenAIResponsesToolSearchArguments(arguments: json['arguments']);

  final Object? arguments;

  Map<String, Object?> toJson() =>
      {if (arguments != null) 'arguments': arguments};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesToolSearchArguments &&
      _equality.equals(other.arguments, arguments);

  @override
  int get hashCode => _equality.hash(arguments);
}

/// The tools a server-side tool search found. Port of eino-ext
/// `agenticopenai.ToolSearchResult`; a tool's JSON is threepio's
/// `ToolInfo.toJson`.
@immutable
final class OpenAIResponsesToolSearchResult {
  OpenAIResponsesToolSearchResult({List<ToolInfo> tools = const []})
      : tools = List.unmodifiable(tools);

  factory OpenAIResponsesToolSearchResult.fromJson(Map<String, Object?> json) =>
      OpenAIResponsesToolSearchResult(
        tools: [
          for (final tool in jsonObjectList(json, 'tools'))
            ToolInfo.fromJson(tool),
        ],
      );

  final List<ToolInfo> tools;

  Map<String, Object?> toJson() =>
      {'tools': [for (final t in tools) t.toJson()]};

  @override
  bool operator ==(Object other) =>
      other is OpenAIResponsesToolSearchResult &&
      _equality.equals(other.tools, tools);

  @override
  int get hashCode => _equality.hash(tools);
}
