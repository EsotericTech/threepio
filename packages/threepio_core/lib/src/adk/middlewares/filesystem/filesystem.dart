/// A middleware that gives an agent filesystem tools (and optionally a
/// shell).
///
/// Port of eino `adk/middlewares/filesystem/filesystem.go` (`New`,
/// `MiddlewareConfig`). Not ported, because eino deprecates them: the
/// `AgentMiddleware` path (`Config`, `NewMiddleware`) with its large tool
/// result offloading (`large_tool_result.go`; use `ToolReductionMiddleware`
/// instead) and the `Custom*ToolDesc` fields (use
/// [FilesystemToolConfig.desc]).
library;

import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../components/tool/function_tool.dart';
import '../../../components/tool/invokable_tool.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/message.dart';
import '../../../schema/tool_info.dart';
import '../../../schema/tool_result.dart';
import '../../../streaming/stream_reader.dart';
import '../../eino/language.dart';
import '../../eino/middleware.dart';
import '../../eino/middleware_context.dart';
import '../../filesystem/backend.dart';
import '../../filesystem/requests.dart';
import 'prompt.dart';

export 'prompt.dart';

const String _noFilesFound = 'No files found';
const String _noMatchesFound = 'No matches found';

/// The most PDF pages one multimodal read may ask for. Port of
/// `maxPagesPerRequest`.
const int _maxPagesPerRequest = 20;

/// How one filesystem tool is registered. Port of eino
/// `filesystem.ToolConfig`.
@immutable
final class FilesystemToolConfig {
  /// A tool configuration; the defaults register the built-in tool.
  const FilesystemToolConfig({
    this.name = '',
    this.desc,
    this.customTool,
    this.disable = false,
  });

  /// The tool's name; `''` for the default name.
  final String name;

  /// The tool's description; `null` for the default one (see
  /// [FilesystemToolDescriptions]).
  final String? desc;

  /// A tool used instead of the built-in one.
  final BaseTool? customTool;

  /// Leaves the tool out.
  final bool disable;
}

/// Gives the agent tools to work on a [FilesystemBackend]: `ls`,
/// `read_file`, `write_file`, `edit_file`, `glob`, `grep`, and `execute`
/// when a [shell] or [streamingShell] is given.
///
/// Port of eino `filesystem.New`. The tools are added to the agent's tools,
/// and [customSystemPrompt] to its instruction, in `beforeAgent`.
///
/// * `read_file` numbers the lines it returns and reads 2000 lines from line
///   1 unless told otherwise. With [useMultiModalRead] it is an enhanced
///   tool that also returns images and PDF pages; the backend must then be a
///   [MultiModalReader].
/// * `glob` and `grep` sort their results by path (then line), and `grep`
///   supports the output modes `files_with_matches` (default), `content`
///   and `count`, with `head_limit` and `offset`.
/// * `execute` reports the exit code of a failed command and whether the
///   output was truncated.
final class FilesystemMiddleware extends ChatModelAgentMiddleware {
  /// A filesystem middleware on [backend].
  ///
  /// Throws [ArgumentError] when both [shell] and [streamingShell] are given,
  /// or [useMultiModalRead] is set for a backend that is not a
  /// [MultiModalReader].
  FilesystemMiddleware({
    required this.backend,
    this.shell,
    this.streamingShell,
    this.lsToolConfig = const FilesystemToolConfig(),
    this.readFileToolConfig = const FilesystemToolConfig(),
    this.writeFileToolConfig = const FilesystemToolConfig(),
    this.editFileToolConfig = const FilesystemToolConfig(),
    this.globToolConfig = const FilesystemToolConfig(),
    this.grepToolConfig = const FilesystemToolConfig(),
    this.useMultiModalRead = false,
    this.customSystemPrompt,
  }) {
    if (shell != null && streamingShell != null) {
      throw ArgumentError('shell and streaming shell should not be both set');
    }
    tools = List.unmodifiable(_buildTools());
  }

  /// Name of the `ls` tool. Port of eino `ToolNameLs`.
  static const String toolNameLs = 'ls';

  /// Name of the `read_file` tool. Port of eino `ToolNameReadFile`.
  static const String toolNameReadFile = 'read_file';

  /// Name of the `write_file` tool. Port of eino `ToolNameWriteFile`.
  static const String toolNameWriteFile = 'write_file';

  /// Name of the `edit_file` tool. Port of eino `ToolNameEditFile`.
  static const String toolNameEditFile = 'edit_file';

  /// Name of the `glob` tool. Port of eino `ToolNameGlob`.
  static const String toolNameGlob = 'glob';

  /// Name of the `grep` tool. Port of eino `ToolNameGrep`.
  static const String toolNameGrep = 'grep';

  /// Name of the `execute` tool. Port of eino `ToolNameExecute`.
  static const String toolNameExecute = 'execute';

  /// The files the tools work on.
  final FilesystemBackend backend;

  /// Runs `execute` commands.
  final Shell? shell;

  /// Runs `execute` commands with streamed output.
  final StreamingShell? streamingShell;

  /// Configures `ls`.
  final FilesystemToolConfig lsToolConfig;

  /// Configures `read_file` (also the multimodal one).
  final FilesystemToolConfig readFileToolConfig;

  /// Configures `write_file`.
  final FilesystemToolConfig writeFileToolConfig;

  /// Configures `edit_file`.
  final FilesystemToolConfig editFileToolConfig;

  /// Configures `glob`.
  final FilesystemToolConfig globToolConfig;

  /// Configures `grep`.
  final FilesystemToolConfig grepToolConfig;

  /// Makes `read_file` an enhanced tool that returns images and PDF pages.
  final bool useMultiModalRead;

  /// Appended to the agent's instruction (after a newline) when set. As in
  /// eino v0.9.22 there is no default text.
  final String? customSystemPrompt;

  /// The tools this middleware adds. Port of `getFilesystemTools`.
  late final List<BaseTool> tools;

  @override
  FutureOr<(RunContext, ChatModelAgentContext)> beforeAgent(
    RunContext ctx,
    ChatModelAgentContext agent,
  ) {
    final prompt = customSystemPrompt ?? '';
    if (prompt.isNotEmpty) agent.instruction = '${agent.instruction}\n$prompt';
    agent.tools = [...agent.tools, ...tools];
    return (ctx, agent);
  }

  List<BaseTool> _buildTools() {
    BaseTool? fromConfig(FilesystemToolConfig config, BaseTool Function(String name, String desc) create) {
      if (config.disable) return null;
      return config.customTool ?? create(config.name, config.desc ?? '');
    }

    final shell = this.shell;
    final streamingShell = this.streamingShell;
    return [
      ?fromConfig(lsToolConfig, (name, desc) => newLsTool(backend, name, desc)),
      ?fromConfig(
        readFileToolConfig,
        (name, desc) => useMultiModalRead
            ? newMultiModalReadFileTool(backend, name, desc)
            : newReadFileTool(backend, name, desc),
      ),
      ?fromConfig(writeFileToolConfig, (name, desc) => newWriteFileTool(backend, name, desc)),
      ?fromConfig(editFileToolConfig, (name, desc) => newEditFileTool(backend, name, desc)),
      ?fromConfig(globToolConfig, (name, desc) => newGlobTool(backend, name, desc)),
      ?fromConfig(grepToolConfig, (name, desc) => newGrepTool(backend, name, desc)),
      if (streamingShell != null)
        newStreamingExecuteTool(streamingShell, toolNameExecute, '')
      else if (shell != null)
        newExecuteTool(shell, toolNameExecute, ''),
    ];
  }
}

String _selectName(String custom, String fallback) => custom.isNotEmpty ? custom : fallback;

String _selectDesc(String custom, String english, String chinese) =>
    custom.isNotEmpty ? custom : selectPrompt(I18nPrompts(english: english, chinese: chinese));

String _string(Map<String, Object?> json, String key) => switch (json[key]) {
      null => '',
      final String value => value,
      final value => throw FormatException('"$key" must be a string, got ${value.runtimeType}'),
    };

String? _optionalString(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _string(json, key);

int _int(Map<String, Object?> json, String key) => switch (json[key]) {
      null => 0,
      final int value => value,
      final double value when value == value.truncateToDouble() => value.toInt(),
      final value => throw FormatException('"$key" must be an integer, got ${value.runtimeType}'),
    };

int? _optionalInt(Map<String, Object?> json, String key) => json[key] == null ? null : _int(json, key);

bool _bool(Map<String, Object?> json, String key) => switch (json[key]) {
      null => false,
      final bool value => value,
      final value => throw FormatException('"$key" must be a boolean, got ${value.runtimeType}'),
    };

bool? _optionalBool(Map<String, Object?> json, String key) => json[key] == null ? null : _bool(json, key);

/// The `ls` tool. Port of `newLsTool`.
@visibleForTesting
BaseTool newLsTool(FilesystemBackend backend, String name, String desc) =>
    FunctionTool<String, String>(
      name: _selectName(name, FilesystemMiddleware.toolNameLs),
      description: _selectDesc(
        desc,
        FilesystemToolDescriptions.listFiles,
        FilesystemToolDescriptions.listFilesChinese,
      ),
      params: const ParamsOneOf.params({
        'path': ParameterInfo(type: DataType.string, required: true),
      }),
      fromJson: (json) => _string(json, 'path'),
      invoke: (ctx, path, options) async {
        final infos = await backend.lsInfo(ctx, LsInfoRequest(path: path));
        if (infos.isEmpty) return _noFilesFound;
        return infos.map((info) => info.path).join('\n');
      },
    );

typedef _ReadArgs = ({String filePath, int offset, int limit, String pages});

_ReadArgs _readArgs(Map<String, Object?> json) {
  final offset = _int(json, 'offset');
  final limit = _int(json, 'limit');
  return (
    filePath: _string(json, 'file_path'),
    offset: offset <= 0 ? 1 : offset,
    limit: limit <= 0 ? 2000 : limit,
    pages: _string(json, 'pages'),
  );
}

const Map<String, ParameterInfo> _readFileParams = {
  'file_path': ParameterInfo(
    type: DataType.string,
    desc: 'The path to the file to read',
    required: true,
  ),
  'offset': ParameterInfo(
    type: DataType.integer,
    desc: 'The line number to start reading from. Only provide if the file is too large to read at once',
    required: true,
  ),
  'limit': ParameterInfo(
    type: DataType.integer,
    desc: 'The number of lines to read. Only provide if the file is too large to read at once.',
    required: true,
  ),
};

/// The `read_file` tool. Port of `newReadFileTool`.
@visibleForTesting
BaseTool newReadFileTool(FilesystemBackend backend, String name, String desc) =>
    FunctionTool<_ReadArgs, String>(
      name: _selectName(name, FilesystemMiddleware.toolNameReadFile),
      description: _selectDesc(
        desc,
        FilesystemToolDescriptions.readFile,
        FilesystemToolDescriptions.readFileChinese,
      ),
      params: const ParamsOneOf.params(_readFileParams),
      fromJson: _readArgs,
      invoke: (ctx, args, options) async {
        final content = await backend.read(
          ctx,
          ReadRequest(filePath: args.filePath, offset: args.offset, limit: args.limit),
        );
        return formatReadResult(content.content, args.filePath, args.offset);
      },
    );

/// The numbered lines of [content], or a note when it is empty (an empty
/// file, or an offset past the end). Port of `formatReadResult`.
@visibleForTesting
String formatReadResult(String content, String filePath, int startLine) {
  if (content.isEmpty) {
    return 'No content read from $filePath: the file is empty, or offset $startLine is past its last line';
  }
  return formatLineNumbers(content, startLine);
}

/// [content] with each line prefixed by its number (from [startLine]),
/// right-aligned in six places, and a tab. Port of `formatLineNumbers`.
@visibleForTesting
String formatLineNumbers(String content, int startLine) {
  if (content.isEmpty) return '';
  final lines = content.split('\n');
  final out = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    out
      ..write('${startLine + i}'.padLeft(6))
      ..write('\t')
      ..write(lines[i]);
    if (i < lines.length - 1) out.write('\n');
  }
  return out.toString();
}

final RegExp _atoi = RegExp(r'^[+-]?\d+$');

int? _parseGoInt(String text) => _atoi.hasMatch(text) ? int.tryParse(text) : null;

/// Checks a `pages` argument (`"3"` or `"1-10"`, at most 20 pages); throws a
/// [ThreepioException] with eino's text. Port of `validatePages`.
@visibleForTesting
void validatePages(String pages) {
  final format = ThreepioException(
    'invalid pages parameter ${jsonEncode(pages)}: expected format like "3" or "1-10"',
  );
  final dash = pages.indexOf('-');
  final first = dash < 0 ? pages : pages.substring(0, dash);
  final start = _parseGoInt(first);
  if (start == null || start < 1) throw format;
  if (dash < 0) return;
  final rest = pages.substring(dash + 1);
  if (rest.isEmpty) throw format;
  final end = _parseGoInt(rest);
  if (end == null || end < 1) throw format;
  if (end < start) {
    throw ThreepioException(
      'invalid pages parameter ${jsonEncode(pages)}: end page must be >= start page',
    );
  }
  if (end - start + 1 > _maxPagesPerRequest) {
    throw ThreepioException(
      'invalid pages parameter ${jsonEncode(pages)}: range exceeds maximum of $_maxPagesPerRequest pages per request',
    );
  }
}

/// The multimodal `read_file` tool, an enhanced tool on a
/// [MultiModalReader]. Port of `newMultiModalReadFileTool`.
@visibleForTesting
BaseTool newMultiModalReadFileTool(FilesystemBackend backend, String name, String desc) {
  if (backend is! MultiModalReader) {
    throw ArgumentError(
      'UseMultiModalRead is enabled, but backend (type ${backend.runtimeType}) does not '
      'implement filesystem.MultiModalReader interface. Either implement the '
      'MultiModalReader interface on your backend, or set UseMultiModalRead to false',
    );
  }
  final reader = backend as MultiModalReader;
  var description = _selectDesc(
    desc,
    FilesystemToolDescriptions.readFile,
    FilesystemToolDescriptions.readFileChinese,
  );
  if (desc.isEmpty) {
    description += selectPrompt(
      const I18nPrompts(
        english: FilesystemToolDescriptions.enhancedReadFileSuffix,
        chinese: FilesystemToolDescriptions.enhancedReadFileSuffixChinese,
      ),
    );
  }
  ToolResult text(String value) => ToolResult.text(value);
  return EnhancedFunctionTool<_ReadArgs>(
    name: _selectName(name, FilesystemMiddleware.toolNameReadFile),
    description: description,
    params: const ParamsOneOf.params({
      ..._readFileParams,
      'pages': ParameterInfo(
        type: DataType.string,
        desc: 'Page range for PDF files (e.g., "1-5", "3", "10-20"). Only applicable to PDF files. Maximum 20 pages per request.',
      ),
    }),
    fromJson: _readArgs,
    invoke: (ctx, args, options) async {
      if (args.pages.isNotEmpty) {
        try {
          validatePages(args.pages);
        } on ThreepioException catch (error) {
          return text(error.message);
        }
      }
      final content = await reader.multiModalRead(
        ctx,
        MultiModalReadRequest(
          filePath: args.filePath,
          offset: args.offset,
          limit: args.limit,
          pages: args.pages,
        ),
      );
      if (content.parts.isNotEmpty) {
        final parts = <ToolOutputPart>[];
        for (final part in content.parts) {
          if (part.data.isEmpty) {
            throw ThreepioException('FileContentPart.Data is empty for type ${part.type.value}');
          }
          if (part.mimeType.isEmpty) {
            throw ThreepioException('FileContentPart.MIMEType is empty for type ${part.type.value}');
          }
          final common = MessagePartCommon(mimeType: part.mimeType, base64Data: base64Encode(part.data));
          parts.add(switch (part.type) {
            FileContentPartType.image =>
              ToolOutputPart(type: ToolPartType.image, image: ToolOutputImage(common: common)),
            FileContentPartType.pdf =>
              ToolOutputPart(type: ToolPartType.file, file: ToolOutputFile(common: common)),
          });
        }
        return ToolResult(parts);
      }
      final fileContent = content.fileContent;
      if (fileContent == null) return text('No content found at path: ${args.filePath}');
      return text(formatReadResult(fileContent.content, args.filePath, args.offset));
    },
  );
}

/// The `write_file` tool. Port of `newWriteFileTool`.
@visibleForTesting
BaseTool newWriteFileTool(FilesystemBackend backend, String name, String desc) =>
    FunctionTool<({String filePath, String content}), String>(
      name: _selectName(name, FilesystemMiddleware.toolNameWriteFile),
      description: _selectDesc(
        desc,
        FilesystemToolDescriptions.writeFile,
        FilesystemToolDescriptions.writeFileChinese,
      ),
      params: const ParamsOneOf.params({
        'file_path': ParameterInfo(
          type: DataType.string,
          desc: 'The path to the file to write',
          required: true,
        ),
        'content': ParameterInfo(
          type: DataType.string,
          desc: 'The content to write to the file',
          required: true,
        ),
      }),
      fromJson: (json) => (filePath: _string(json, 'file_path'), content: _string(json, 'content')),
      invoke: (ctx, args, options) async {
        await backend.write(ctx, WriteRequest(filePath: args.filePath, content: args.content));
        return 'Updated file ${args.filePath}';
      },
    );

/// The `edit_file` tool. Port of `newEditFileTool`.
@visibleForTesting
BaseTool newEditFileTool(FilesystemBackend backend, String name, String desc) =>
    FunctionTool<EditRequest, String>(
      name: _selectName(name, FilesystemMiddleware.toolNameEditFile),
      description: _selectDesc(
        desc,
        FilesystemToolDescriptions.editFile,
        FilesystemToolDescriptions.editFileChinese,
      ),
      params: const ParamsOneOf.params({
        'file_path': ParameterInfo(
          type: DataType.string,
          desc: 'The path to the file to modify',
          required: true,
        ),
        'old_string': ParameterInfo(
          type: DataType.string,
          desc: 'The text to replace',
          required: true,
        ),
        'new_string': ParameterInfo(
          type: DataType.string,
          desc: 'The text to replace it with (must be different from old_string)',
          required: true,
        ),
        'replace_all': ParameterInfo(
          type: DataType.boolean,
          desc: 'Replace all occurrences of old_string (default false)',
          required: true,
        ),
      }),
      fromJson: (json) => EditRequest(
        filePath: _string(json, 'file_path'),
        oldString: _string(json, 'old_string'),
        newString: _string(json, 'new_string'),
        replaceAll: _bool(json, 'replace_all'),
      ),
      invoke: (ctx, request, options) async {
        await backend.edit(ctx, request);
        return "Successfully replaced the string in '${request.filePath}'";
      },
    );

/// The `glob` tool. Port of `newGlobTool`.
@visibleForTesting
BaseTool newGlobTool(FilesystemBackend backend, String name, String desc) =>
    FunctionTool<GlobInfoRequest, String>(
      name: _selectName(name, FilesystemMiddleware.toolNameGlob),
      description: _selectDesc(
        desc,
        FilesystemToolDescriptions.glob,
        FilesystemToolDescriptions.globChinese,
      ),
      params: const ParamsOneOf.params({
        'pattern': ParameterInfo(
          type: DataType.string,
          desc: 'The glob pattern to match files against',
          required: true,
        ),
        'path': ParameterInfo(
          type: DataType.string,
          desc: "The directory to search in. If not specified, the current working directory will be used. IMPORTANT: Omit this field to use the default directory. DO NOT enter 'undefined' or 'null' - simply omit it for the default behavior. Must be a valid directory path if provided.",
          required: true,
        ),
      }),
      fromJson: (json) => GlobInfoRequest(pattern: _string(json, 'pattern'), path: _string(json, 'path')),
      invoke: (ctx, request, options) async {
        final infos = await backend.globInfo(ctx, request);
        if (infos.isEmpty) return _noFilesFound;
        final paths = infos.map((info) => info.path).toList()..sort();
        return paths.join('\n');
      },
    );

typedef _GrepArgs = ({
  String pattern,
  String? path,
  String? glob,
  String outputMode,
  int? context,
  int? beforeLines,
  int? afterLines,
  bool? showLineNumbers,
  bool? caseInsensitive,
  String? fileType,
  int? headLimit,
  int? offset,
  bool? multiline,
});

_GrepArgs _grepArgs(Map<String, Object?> json) => (
      pattern: _string(json, 'pattern'),
      path: _optionalString(json, 'path'),
      glob: _optionalString(json, 'glob'),
      outputMode: _string(json, 'output_mode'),
      context: _optionalInt(json, '-C'),
      beforeLines: _optionalInt(json, '-B'),
      afterLines: _optionalInt(json, '-A'),
      showLineNumbers: _optionalBool(json, '-n'),
      caseInsensitive: _optionalBool(json, '-i'),
      fileType: _optionalString(json, 'type'),
      headLimit: _optionalInt(json, 'head_limit'),
      offset: _optionalInt(json, 'offset'),
      multiline: _optionalBool(json, 'multiline'),
    );

/// The `grep` tool. Port of `newGrepTool`.
@visibleForTesting
BaseTool newGrepTool(FilesystemBackend backend, String name, String desc) =>
    FunctionTool<_GrepArgs, String>(
      name: _selectName(name, FilesystemMiddleware.toolNameGrep),
      description: _selectDesc(
        desc,
        FilesystemToolDescriptions.grep,
        FilesystemToolDescriptions.grepChinese,
      ),
      params: const ParamsOneOf.params({
        'pattern': ParameterInfo(
          type: DataType.string,
          desc: 'The regular expression pattern to search for in file contents',
          required: true,
        ),
        'path': ParameterInfo(
          type: DataType.string,
          desc: 'File or directory to search in (rg PATH). Defaults to current working directory.',
        ),
        'glob': ParameterInfo(
          type: DataType.string,
          desc: "Glob pattern to filter files (e.g. '*.js', '*.{ts,tsx}') - maps to rg --glob",
        ),
        'output_mode': ParameterInfo(
          type: DataType.string,
          desc: "Output mode: 'content' shows matching lines (supports -A/-B/-C context, -n line numbers, head_limit), 'files_with_matches' shows file paths (supports head_limit), 'count' shows match counts (supports head_limit). Defaults to 'files_with_matches'.",
          enumValues: ['content', 'files_with_matches', 'count'],
        ),
        '-C': ParameterInfo(
          type: DataType.integer,
          desc: "Number of lines to show before and after each match (rg -C). Requires output_mode: 'content', ignored otherwise.",
        ),
        '-B': ParameterInfo(
          type: DataType.integer,
          desc: "Number of lines to show before each match (rg -B). Requires output_mode: 'content', ignored otherwise.",
        ),
        '-A': ParameterInfo(
          type: DataType.integer,
          desc: "Number of lines to show after each match (rg -A). Requires output_mode: 'content', ignored otherwise.",
        ),
        '-n': ParameterInfo(
          type: DataType.boolean,
          desc: "Show line numbers in output (rg -n). Requires output_mode: 'content', ignored otherwise. Defaults to true.",
        ),
        '-i': ParameterInfo(type: DataType.boolean, desc: 'Case insensitive search (rg -i)'),
        'type': ParameterInfo(
          type: DataType.string,
          desc: 'File type to search (rg --type). Common types: js, py, rust, go, java, etc. More efficient than include for standard file types.',
        ),
        'head_limit': ParameterInfo(
          type: DataType.integer,
          desc: "Limit output to first N lines/entries, equivalent to '| head -N'. Works across all output modes: content (limits output lines), files_with_matches (limits file paths), count (limits count entries). Defaults to 0 (unlimited).",
        ),
        'offset': ParameterInfo(
          type: DataType.integer,
          desc: "Skip first N lines/entries before applying head_limit, equivalent to '| tail -n +N | head -N'. Works across all output modes. Defaults to 0.",
        ),
        'multiline': ParameterInfo(
          type: DataType.boolean,
          desc: 'Enable multiline mode where . matches newlines and patterns can span lines (rg -U --multiline-dotall). Default: false.',
        ),
      }),
      fromJson: _grepArgs,
      invoke: (ctx, args, options) async {
        final before = args.context ?? args.beforeLines ?? 0;
        final after = args.context ?? args.afterLines ?? 0;
        final headLimit = args.headLimit ?? 0;
        final offset = args.offset ?? 0;
        final found = await backend.grepRaw(
          ctx,
          GrepRequest(
            pattern: args.pattern,
            path: args.path ?? '',
            glob: args.glob ?? '',
            fileType: args.fileType ?? '',
            caseInsensitive: args.caseInsensitive ?? false,
            afterLines: after,
            beforeLines: before,
            enableMultiline: args.multiline ?? false,
          ),
        );
        final matches = sortGrepMatches(found);
        return switch (args.outputMode) {
          'content' => formatContentMatches(
              applyPagination(matches, offset, headLimit),
              showLineNumbers: args.showLineNumbers ?? true,
            ),
          'count' => formatCountMatches(matches, offset, headLimit),
          _ => formatFileMatches(matches, offset, headLimit),
        };
      },
    );

/// [matches] sorted by path, then line, keeping the order of equal ones (Go
/// `sort.SliceStable`).
@visibleForTesting
List<GrepMatch> sortGrepMatches(List<GrepMatch> matches) {
  final indexed = [for (var i = 0; i < matches.length; i++) (i, matches[i])]
    ..sort((a, b) {
      final byPath = a.$2.path.compareTo(b.$2.path);
      if (byPath != 0) return byPath;
      final byLine = a.$2.line.compareTo(b.$2.line);
      return byLine != 0 ? byLine : a.$1.compareTo(b.$1);
    });
  return [for (final (_, match) in indexed) match];
}

/// [items] without the first [offset], at most [headLimit] of them (0: no
/// limit). Port of `applyPagination`.
@visibleForTesting
List<T> applyPagination<T>(List<T> items, int offset, int headLimit) {
  final start = offset < 0 ? 0 : offset;
  if (start >= items.length) return <T>[];
  final rest = items.sublist(start);
  return headLimit > 0 && headLimit < rest.length ? rest.sublist(0, headLimit) : rest;
}

/// The files with matches. Port of `formatFileMatches`.
@visibleForTesting
String formatFileMatches(List<GrepMatch> matches, int offset, int headLimit) {
  if (matches.isEmpty) return _noFilesFound;
  final unique = <String>[];
  final seen = <String>{};
  for (final match in matches) {
    if (seen.add(match.path)) unique.add(match.path);
  }
  final total = unique.length;
  final page = applyPagination(unique, offset, headLimit);
  return 'Found $total ${total == 1 ? 'file' : 'files'}\n${page.join('\n')}';
}

/// The matching lines, as `path:line:content` (`path:content` without line
/// numbers). Port of `formatContentMatches`.
@visibleForTesting
String formatContentMatches(List<GrepMatch> matches, {required bool showLineNumbers}) {
  if (matches.isEmpty) return _noMatchesFound;
  return [
    for (final match in matches)
      showLineNumbers ? '${match.path}:${match.line}:${match.content}' : '${match.path}:${match.content}',
  ].join('\n');
}

/// The number of matches per file and in total. Port of
/// `formatCountMatches`.
@visibleForTesting
String formatCountMatches(List<GrepMatch> matches, int offset, int headLimit) {
  final counts = <String, int>{};
  for (final match in matches) {
    counts[match.path] = (counts[match.path] ?? 0) + 1;
  }
  final paths = counts.keys.toList()..sort();
  final total = matches.length;
  final files = paths.length;
  final summary = 'Found $total total ${total == 1 ? 'occurrence' : 'occurrences'} '
      'across $files ${files == 1 ? 'file' : 'files'}.';
  if (total == 0) return '$_noMatchesFound\n\n$summary';
  final lines = [for (final path in applyPagination(paths, offset, headLimit)) '$path:${counts[path]}'];
  return '${lines.join('\n')}\n\n$summary';
}

const Map<String, ParameterInfo> _executeParams = {
  'command': ParameterInfo(type: DataType.string, required: true),
};

/// The `execute` tool on a [Shell]. Port of `newExecuteTool`.
@visibleForTesting
BaseTool newExecuteTool(Shell shell, String name, String desc) => FunctionTool<String, String>(
      name: _selectName(name, FilesystemMiddleware.toolNameExecute),
      description: _selectDesc(
        desc,
        FilesystemToolDescriptions.execute,
        FilesystemToolDescriptions.executeChinese,
      ),
      params: const ParamsOneOf.params(_executeParams),
      fromJson: (json) => _string(json, 'command'),
      invoke: (ctx, command, options) async =>
          convExecuteResponse(await shell.execute(ctx, ExecuteRequest(command: command))),
    );

/// The `execute` tool on a [StreamingShell]: the output chunks as they come,
/// then the exit code of a failed command, or a note when there was no
/// output. Port of `newStreamingExecuteTool`.
@visibleForTesting
BaseTool newStreamingExecuteTool(StreamingShell shell, String name, String desc) =>
    StreamFunctionTool<String, String>(
      name: _selectName(name, FilesystemMiddleware.toolNameExecute),
      description: _selectDesc(
        desc,
        FilesystemToolDescriptions.execute,
        FilesystemToolDescriptions.executeChinese,
      ),
      params: const ParamsOneOf.params(_executeParams),
      fromJson: (json) => _string(json, 'command'),
      invoke: (ctx, command, options) async {
        final result = await shell.executeStreaming(ctx, ExecuteRequest(command: command));
        final (reader, writer) = pipe<String>(capacity: 10);
        unawaited(_pumpExecuteOutput(result, writer));
        // A consumer that stops early releases the command's stream too (Go
        // leaves it to the shell).
        unawaited(reader.done.then((_) => result.close()));
        return reader;
      },
    );

Future<void> _pumpExecuteOutput(StreamReader<ExecuteResponse> result, StreamWriter<String> writer) async {
  try {
    var hasSentContent = false;
    int? exitCode;
    while (true) {
      final ExecuteResponse chunk;
      try {
        chunk = await result.recv();
      } on StreamEOFException {
        break;
      } on Object catch (error, stackTrace) {
        writer.sendError(error, stackTrace);
        return;
      }
      if (chunk.exitCode != null) exitCode = chunk.exitCode;
      final parts = [
        if (chunk.output.isNotEmpty) chunk.output,
        if (chunk.truncated) '[Output was truncated due to size limits]',
      ];
      if (parts.isNotEmpty) {
        if (await writer.sendAsync(parts.join('\n'))) return;
        hasSentContent = true;
      }
    }
    if (exitCode != null && exitCode != 0) {
      writer.send('\n[Command failed with exit code $exitCode]');
    } else if (!hasSentContent) {
      writer.send('[Command executed successfully with no output]');
    }
  } finally {
    writer.close();
    unawaited(result.close());
  }
}

/// The text of a command's result: the output, the exit code of a failure,
/// a note on truncation, or a note that there was no output. Port of
/// `convExecuteResponse`.
@visibleForTesting
String convExecuteResponse(ExecuteResponse? response) {
  if (response == null) return '';
  final exitCode = response.exitCode;
  final parts = [
    response.output,
    if (exitCode != null && exitCode != 0) '[Command failed with exit code $exitCode]',
    if (response.truncated) '[Output was truncated due to size limits]',
  ];
  final result = parts.join('\n');
  if (result.isEmpty && (exitCode == null || exitCode == 0)) {
    return '[Command executed successfully with no output]';
  }
  return result;
}
