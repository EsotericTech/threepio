/// The `str_replace_editor` tool.
///
/// Port of eino-ext `components/tool/commandline/editor.go`.
library;

import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/tool_info.dart';
import '../invokable_tool.dart';
import '../tool_options.dart';
import 'command_line_operator.dart';

/// A command of the `str_replace_editor` tool.
///
/// Port of eino-ext `commandline.Command` and its constants.
enum StrReplaceEditorCommand {
  /// Shows a file with line numbers, or lists a directory (Go:
  /// `ViewCommand`).
  view('view'),

  /// Creates a file (Go: `CreateCommand`).
  create('create'),

  /// Replaces a string that occurs once in a file (Go:
  /// `StrReplaceCommand`).
  strReplace('str_replace'),

  /// Inserts lines after a line of a file (Go: `InsertCommand`).
  insert('insert'),

  /// Reverts the last edit of a file (Go: `UndoEditCommand`).
  undoEdit('undo_edit');

  const StrReplaceEditorCommand(this.value);

  /// The name of the command in the tool's arguments.
  final String value;

  /// The command called [value], or `null` when there is none.
  static StrReplaceEditorCommand? tryParse(String value) =>
      values.firstWhereOrNull((command) => command.value == value);
}

/// The arguments of the `str_replace_editor` tool.
///
/// Port of eino-ext `commandline.StrReplaceEditorParams`. Which fields a
/// command needs is checked when it runs, as in Go.
@immutable
final class StrReplaceEditorParams {
  /// Arguments that run [command] on [path].
  StrReplaceEditorParams({
    required this.command,
    required this.path,
    this.fileText,
    List<int>? viewRange,
    this.oldStr,
    this.newStr,
    this.insertLine,
  }) : viewRange = viewRange == null ? null : List.unmodifiable(viewRange);

  /// Reads the tool's arguments the way Go's `encoding/json` does: keys
  /// match the field names ignoring case (`bytes.EqualFold`) and a later key
  /// overwrites an earlier one, missing or `null` fields are absent (`path`
  /// is empty), other fields are ignored, a `null` element of `view_range` is
  /// 0, and the first field of the wrong type is a
  /// [ThreepioFormatException] with Go's message. A `command` that is not
  /// one of the [StrReplaceEditorCommand]s is one too, with the message Go's
  /// `Execute` gives it: `unrecognized command <command>. Allowed commands
  /// are: view, create, str_replace, insert, undo_edit`.
  factory StrReplaceEditorParams.fromJson(Map<String, Object?> json) {
    var command = '';
    var path = '';
    String? fileText;
    List<int>? viewRange;
    String? oldStr;
    String? newStr;
    int? insertLine;
    // Go decodes the fields in the order of the document and reports the
    // first one of the wrong type. `null` leaves a string field as it is and
    // sets a pointer or slice field to nil.
    for (final MapEntry(:key, :value) in json.entries) {
      switch (_goFoldedKey(key)) {
        case 'command':
          if (value != null) {
            command = _string('command', value, 'commandline.Command');
          }
        case 'path':
          if (value != null) path = _string('path', value, 'string');
        case 'file_text':
          fileText =
              value == null ? null : _string('file_text', value, 'string');
        case 'view_range':
          viewRange = value == null ? null : _intList('view_range', value);
        case 'old_str':
          oldStr = value == null ? null : _string('old_str', value, 'string');
        case 'new_str':
          newStr = value == null ? null : _string('new_str', value, 'string');
        case 'insert_line':
          insertLine = value == null ? null : _int('insert_line', value, 'int');
      }
    }
    final parsed = StrReplaceEditorCommand.tryParse(command);
    if (parsed == null) {
      throw ThreepioFormatException(
        'unrecognized command $command. Allowed commands are: view, create, '
        'str_replace, insert, undo_edit',
      );
    }
    return StrReplaceEditorParams(
      command: parsed,
      path: path,
      fileText: fileText,
      viewRange: viewRange,
      oldStr: oldStr,
      newStr: newStr,
      insertLine: insertLine,
    );
  }

  /// What to do.
  final StrReplaceEditorCommand command;

  /// The file or directory to work on; the model is asked for an absolute
  /// path.
  final String path;

  /// The content of the file `create` makes; required by it.
  final String? fileText;

  /// The lines `view` shows of a file: `[first, last]`, counted from 1, with
  /// `-1` as `last` for "to the end". `null` or empty shows the whole file.
  final List<int>? viewRange;

  /// The text `str_replace` replaces; required by it.
  final String? oldStr;

  /// The text `str_replace` puts in place of [oldStr] (nothing when `null`),
  /// or the lines `insert` inserts (required by it).
  final String? newStr;

  /// The line after which `insert` inserts [newStr] (0: before the first);
  /// required by it.
  final int? insertLine;

  /// The JSON form (Go's field names; absent fields are left out).
  Map<String, Object?> toJson() => {
        'command': command.value,
        'path': path,
        if (fileText != null) 'file_text': fileText,
        if (viewRange != null && viewRange!.isNotEmpty) 'view_range': viewRange,
        if (oldStr != null) 'old_str': oldStr,
        if (newStr != null) 'new_str': newStr,
        if (insertLine != null) 'insert_line': insertLine,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StrReplaceEditorParams &&
          other.command == command &&
          other.path == path &&
          other.fileText == fileText &&
          const ListEquality<int>().equals(other.viewRange, viewRange) &&
          other.oldStr == oldStr &&
          other.newStr == newStr &&
          other.insertLine == insertLine;

  @override
  int get hashCode => Object.hash(
        command,
        path,
        fileText,
        const ListEquality<int>().hash(viewRange),
        oldStr,
        newStr,
        insertLine,
      );

  @override
  String toString() => 'StrReplaceEditorParams(${toJson()})';
}

/// The configuration of a [StrReplaceEditorTool].
///
/// Port of eino-ext `commandline.EditorConfig`.
@immutable
final class StrReplaceEditorConfig {
  /// Edits the files of [operator].
  const StrReplaceEditorConfig({required this.operator});

  /// Where the files are.
  final CommandLineOperator operator;
}

/// A tool that views, creates and edits files.
///
/// Port of eino-ext `commandline.StrReplaceEditor`
/// (`NewStrReplaceEditor`), itself modelled on OpenManus. The model picks
/// one of the [StrReplaceEditorCommand]s:
///
/// * `view` shows a file as `cat -n` would (lines numbered from 1, tabs
///   expanded to four spaces, cut after [maxResponseLen] bytes with
///   [truncatedMessage]), or lists a directory two levels deep with
///   `find <path> -maxdepth 2 -not -path */\.*` run by the operator.
/// * `create` writes `file_text` to `path`.
/// * `str_replace` replaces `old_str`, which must occur exactly once, with
///   `new_str` and shows the edited lines with [snippetLines] lines around
///   them.
/// * `insert` inserts `new_str` after line `insert_line` and shows the
///   lines around it.
/// * `undo_edit` restores the content the file had before the last
///   `str_replace` or `insert` (or, after `create`, writes the created
///   content again: Go records it too).
///
/// The edit history is kept in the tool, per path, for as long as the tool
/// lives: one instance is one editing session, as in Go.
///
/// Everything the operator throws is passed on unchanged. The tool's own
/// errors are [ThreepioException]s with Go's messages; arguments that do not
/// decode are [ThreepioFormatException]s (`failed to extract input: …`, or
/// `unrecognized command …`). As in Go, the tool does not check paths:
/// relative paths, missing files and `create` over an existing file are
/// left to the operator. [validatePath] is Go's check, for callers who want
/// it.
///
/// One difference from Go, on purpose: a `view` with a `view_range` numbers
/// the lines it shows from the first line of the range, as the tool's
/// description promises. Go numbers them from 1 because its
/// `initLine, finalLine :=` declares a second `initLine` that the output
/// never sees, which shows a model wrong line numbers.
///
/// Another, where Go panics: a `str_replace` of an empty `old_str` in an
/// empty file writes `new_str` (Go's `strings.Split` returns no parts there
/// and indexing them panics).
///
/// Go quirk kept: `str_replace` and `insert` expand the tabs of the whole
/// file they write.
final class StrReplaceEditorTool extends InvokableTool {
  /// A tool configured by [config].
  ///
  /// Port of eino-ext `commandline.NewStrReplaceEditor`. Go's checks for a
  /// missing config or operator are done by the type system here.
  StrReplaceEditorTool(StrReplaceEditorConfig config)
      : operator = config.operator;

  /// The name of the tool.
  static const String toolName = 'str_replace_editor';

  /// The description of the tool, as the model sees it (Go:
  /// `StrReplaceEditorDescription`).
  static const String description = """
Custom editing tool for viewing, creating and editing files
* State is persistent across command calls and discussions with the user
* If 'path' is a file, 'view' displays the result of applying 'cat -n'. If 'path' is a directory, 'view' lists non-hidden files and directories up to 2 levels deep
* The 'create' command cannot be used if the specified 'path' already exists as a file
* If a 'command' generates a long output, it will be truncated and marked with '<response clipped>'
* The 'undo_edit' command will revert the last edit made to the file at 'path'

Notes for using the 'str_replace' command:
* The 'old_str' parameter should match EXACTLY one or more consecutive lines from the original file. Be mindful of whitespaces!
* If the 'old_str' parameter is not unique in the file, the replacement will not be performed. Make sure to include enough context in 'old_str' to make it unique
* The 'new_str' parameter should contain the edited lines that should replace the 'old_str'""";

  /// How many lines before and after an edit its snippet shows (Go:
  /// `SnippetLines`).
  static const int snippetLines = 4;

  /// The number of bytes (UTF-8, as Go counts) of a file's content the tool
  /// shows at most (Go: `MaxResponseLen`).
  static const int maxResponseLen = 16000;

  /// What follows content that was cut after [maxResponseLen] bytes (Go:
  /// `TruncatedMessage`).
  static const String truncatedMessage =
      '<response clipped><NOTE>To save on context only part of this file has '
      'been shown to you. You should retry this tool after you have searched '
      'inside the file with `grep -n` in order to find the line numbers of '
      'what you are looking for.</NOTE>';

  /// Go's `ToolInfo` literal: `command` and `path` are required, and there
  /// is no `additionalProperties` (Go's `jsonschema.Schema` writes none).
  /// Kept as a JSON Schema document, with the keys in the order Go writes
  /// them (`type` last), so that every provider sends the schema Go sends.
  static final ToolInfo _info = ToolInfo.fromJsonSchemaMap(
    name: toolName,
    desc: description,
    schema: {
      'properties': {
        'command': {
          'enum': [
            for (final command in StrReplaceEditorCommand.values) command.value,
          ],
          'description': 'The commands to run. Allowed options are: `view`, '
              '`create`, `str_replace`, `insert`, `undo_edit`.',
          'type': 'string',
        },
        'path': const {
          'description': 'Absolute path to file or directory.',
          'type': 'string',
        },
        'file_text': const {
          'description': 'Required parameter of `create` command, with the '
              'content of the file to be created.',
          'type': 'string',
        },
        'old_str': const {
          'description': 'Required parameter of `str_replace` command '
              'containing the string in `path` to replace.',
          'type': 'string',
        },
        'new_str': const {
          'description': 'Optional parameter of `str_replace` command '
              'containing the new string (if not given, no string will be '
              'added). Required parameter of `insert` command containing the '
              'string to insert.',
          'type': 'string',
        },
        'insert_line': const {
          'description': 'Required parameter of `insert` command. The '
              '`new_str` will be inserted AFTER the line `insert_line` of '
              '`path`.',
          'type': 'integer',
        },
        'view_range': const {
          'items': {'type': 'integer'},
          'description': 'Optional parameter of `view` command when `path` '
              'points to a file. If none is given, the full file is shown. If '
              'provided, the file will be shown in the indicated line number '
              'range, e.g. [11, 12] will show lines 11 and 12. Indexing at 1 '
              'to start. Setting `[start_line, -1]` shows all lines from '
              '`start_line` to the end of the file.',
          'type': 'array',
        },
      },
      'required': const ['command', 'path'],
      'type': 'object',
    },
  );

  /// Where the files are.
  final CommandLineOperator operator;

  /// The content each path had before each of its edits, oldest first (Go:
  /// `fileHistory`).
  final Map<String, List<String>> _fileHistory = {};

  /// Port of `StrReplaceEditor.Info`.
  @override
  Future<ToolInfo> info() async => _info;

  /// Port of `StrReplaceEditor.InvokableRun`.
  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      execute(ctx, _decodeParams(argumentsJson));

  /// The same as [invokableRun] with a context that is never cancelled, for
  /// code that still calls the tool the old way.
  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);

  /// Runs [params]' command and returns the text for the model.
  ///
  /// Port of `StrReplaceEditor.Execute`.
  Future<String> execute(RunContext ctx, StrReplaceEditorParams params) async {
    switch (params.command) {
      case StrReplaceEditorCommand.view:
        return _view(ctx, params.path, params.viewRange);
      case StrReplaceEditorCommand.create:
        final fileText = params.fileText;
        if (fileText == null) {
          throw const ThreepioException(
            'parameter `file_text` is required for create command',
          );
        }
        await operator.writeFile(ctx, params.path, fileText);
        (_fileHistory[params.path] ??= []).add(fileText);
        return 'file successfully created at: ${params.path}';
      case StrReplaceEditorCommand.strReplace:
        final oldStr = params.oldStr;
        if (oldStr == null) {
          throw const ThreepioException(
            'parameter `old_str` is required for str_replace command',
          );
        }
        return _strReplace(ctx, params.path, oldStr, params.newStr ?? '');
      case StrReplaceEditorCommand.insert:
        final insertLine = params.insertLine;
        if (insertLine == null) {
          throw const ThreepioException(
            'parameter `insert_line` is required for insert command',
          );
        }
        final newStr = params.newStr;
        if (newStr == null) {
          throw const ThreepioException(
            'parameter `new_str` is required for insert command',
          );
        }
        return _insert(ctx, params.path, insertLine, newStr);
      case StrReplaceEditorCommand.undoEdit:
        return _undoEdit(ctx, params.path);
    }
  }

  /// Checks [path] for [command]: it must be absolute; for `create` nothing
  /// may exist there; for the other commands it must exist, and only `view`
  /// takes a directory.
  ///
  /// Port of the unexported Go `validatePath`. Go's `Execute` never calls
  /// it, and neither does [execute]: call it before [execute] to refuse
  /// what it refuses. "Absolute" is decided by `package:path` for this
  /// platform, as Go's `filepath.IsAbs` does.
  Future<void> validatePath(
    RunContext ctx,
    StrReplaceEditorCommand command,
    String path,
  ) async {
    if (!p.isAbsolute(path)) {
      throw ThreepioException('path $path is not an absolute path');
    }
    final exists = await operator.exists(ctx, path);
    if (command == StrReplaceEditorCommand.create) {
      if (exists) {
        throw ThreepioException(
          'file already exists at: $path. Cannot use `create` command to '
          'overwrite files',
        );
      }
      return;
    }
    if (!exists) {
      throw ThreepioException(
        'path $path does not exist. Please provide a valid path',
      );
    }
    final isDirectory = await operator.isDirectory(ctx, path);
    if (isDirectory && command != StrReplaceEditorCommand.view) {
      throw ThreepioException(
        'path $path is a directory, only the `view` command can be used on '
        'directories',
      );
    }
  }

  /// Port of `view`.
  Future<String> _view(
    RunContext ctx,
    String path,
    List<int>? viewRange,
  ) async {
    final isDirectory = await operator.isDirectory(ctx, path);
    if (!isDirectory) return _viewFile(ctx, path, viewRange);
    if (viewRange != null && viewRange.isNotEmpty) {
      throw const ThreepioException(
        'parameter `view_range` is not allowed when `path` points to a '
        'directory',
      );
    }
    // Port of `viewDirectory`.
    final output = await operator.runCommand(
      ctx,
      ['find', path, '-maxdepth', '2', '-not', '-path', r'*/\.*'],
    );
    return output.stdout;
  }

  /// Port of `viewFile`.
  Future<String> _viewFile(
    RunContext ctx,
    String path,
    List<int>? viewRange,
  ) async {
    var fileContent = await operator.readFile(ctx, path);
    // Go shadows this variable inside the range branch, so its output is
    // always numbered from 1; here the range's first line numbers it.
    var initLine = 1;
    if (viewRange != null && viewRange.isNotEmpty) {
      if (viewRange.length != 2) {
        throw const ThreepioException(
          'invalid `view_range`, it should be a list of two integers',
        );
      }
      final fileLines = fileContent.split('\n');
      final lineCount = fileLines.length;
      final [first, last] = viewRange;
      final range = _goIntList(viewRange);
      if (first < 1 || first > lineCount) {
        throw ThreepioException(
          'invalid `view_range`: $range. Its first element `$first` should be '
          "within the file's line range: [1, $lineCount]",
        );
      }
      if (last > lineCount) {
        throw ThreepioException(
          'invalid `view_range`: $range. Its second element `$last` should be '
          'less than the number of lines in the file: `$lineCount`',
        );
      }
      if (last != -1 && last < first) {
        throw ThreepioException(
          'invalid `view_range`: $range. Its second element `$last` should be '
          'greater than or equal to its first `$first`',
        );
      }
      fileContent = (last == -1
              ? fileLines.sublist(first - 1)
              : fileLines.sublist(first - 1, last))
          .join('\n');
      initLine = first;
    }
    return _makeOutput(fileContent, path, initLine);
  }

  /// Port of `strReplace`.
  Future<String> _strReplace(
    RunContext ctx,
    String path,
    String oldText,
    String newText,
  ) async {
    final fileContent = expandTabs(await operator.readFile(ctx, path));
    final oldStr = expandTabs(oldText);
    final newStr = newText.isEmpty ? newText : expandTabs(newText);

    final occurrences = _goCount(fileContent, oldStr);
    if (occurrences == 0) {
      throw ThreepioException(
        'replacement not performed, old_str `$oldStr` does not appear '
        'verbatim in $path',
      );
    }
    if (occurrences > 1) {
      final fileContentLines = fileContent.split('\n');
      final lines = [
        for (var i = 0; i < fileContentLines.length; i++)
          if (fileContentLines[i].contains(oldStr)) i + 1,
      ];
      throw ThreepioException(
        'replacement not performed. old_str `$oldStr` appears multiple times '
        'at lines ${_goIntList(lines)}. please ensure it is unique',
      );
    }

    final newFileContent = fileContent.replaceFirst(oldStr, newStr);
    await operator.writeFile(ctx, path, newFileContent);
    (_fileHistory[path] ??= []).add(fileContent);

    // Go: strings.Count(strings.Split(fileContent, oldStr)[0], "\n"), the
    // line breaks before the replaced text. (For an empty old_str in an
    // empty file Go's Split returns no parts and indexing it panics; here
    // the edit succeeds with the snippet from line 1.)
    final replacementLine =
        _goCount(fileContent.substring(0, fileContent.indexOf(oldStr)), '\n');
    final startLine = max(0, replacementLine - snippetLines);
    var endLine = replacementLine + snippetLines + _goCount(newStr, '\n');
    final newFileContentLines = newFileContent.split('\n');
    if (endLine + 1 > newFileContentLines.length) {
      endLine = newFileContentLines.length - 1;
    }
    final snippet =
        newFileContentLines.sublist(startLine, endLine + 1).join('\n');

    final output = _makeOutput(snippet, 'a snippet of $path', startLine + 1);
    return 'File $path has been edited. $output'
        'Check the changes and make sure they are as expected. Edit the file '
        'again if necessary.';
  }

  /// Port of `insert`.
  Future<String> _insert(
    RunContext ctx,
    String path,
    int insertLine,
    String newText,
  ) async {
    final fileText = expandTabs(await operator.readFile(ctx, path));
    final newStr = expandTabs(newText);
    final fileTextLines = fileText.split('\n');
    final lineCount = fileTextLines.length;
    if (insertLine < 0 || insertLine > lineCount) {
      throw ThreepioException(
        'invalid `insert_line` parameter: $insertLine. It should be within '
        "the file's line range: [0, $lineCount]",
      );
    }

    final newStrLines = newStr.split('\n');
    final newFileTextLines = [
      ...fileTextLines.sublist(0, insertLine),
      ...newStrLines,
      ...fileTextLines.sublist(insertLine),
    ];
    final snippet = [
      ...fileTextLines.sublist(max(0, insertLine - snippetLines), insertLine),
      ...newStrLines,
      ...fileTextLines.sublist(
        insertLine,
        min(lineCount, insertLine + snippetLines),
      ),
    ].join('\n');

    await operator.writeFile(ctx, path, newFileTextLines.join('\n'));
    (_fileHistory[path] ??= []).add(fileText);

    final output = _makeOutput(
      snippet,
      'a snippet of the edited file',
      max(1, insertLine - snippetLines + 1),
    );
    return 'File $path has been edited. $output'
        'Check the changes and make sure they are as expected (correct '
        'indentation, no duplicate lines, etc). Edit the file again if '
        'necessary.';
  }

  /// Port of `undoEdit`. As in Go, the entry is taken off the history
  /// before it is written back, also when the write fails.
  Future<String> _undoEdit(RunContext ctx, String path) async {
    final history = _fileHistory[path];
    if (history == null || history.isEmpty) {
      throw ThreepioException('no edit history found for $path');
    }
    final oldText = history.removeLast();
    await operator.writeFile(ctx, path, oldText);
    return 'Successfully undid last edit to $path. '
        '${_makeOutput(oldText, path, 1)}';
  }

  /// [content] cut after [truncateAfter] bytes of its UTF-8 form and
  /// followed by [truncatedMessage], or [content] itself when it is not
  /// longer than that or [truncateAfter] is 0.
  ///
  /// Port of Go's `truncate`, which counts and cuts bytes: a character cut
  /// in two becomes U+FFFD, which is what Go's broken UTF-8 turns into when
  /// it is sent to a model.
  @visibleForTesting
  static String truncate(String content, int truncateAfter) {
    // A UTF-16 code unit is at most three bytes of UTF-8.
    if (truncateAfter == 0 || content.length * 3 <= truncateAfter) {
      return content;
    }
    final bytes = utf8.encode(content);
    if (bytes.length <= truncateAfter) return content;
    return utf8.decode(bytes.sublist(0, truncateAfter), allowMalformed: true) +
        truncatedMessage;
  }

  /// [text] with every tab replaced by four spaces. Port of Go's
  /// `expandTabs`.
  @visibleForTesting
  static String expandTabs(String text) => text.replaceAll('\t', '    ');

  /// Port of `makeOutput`: [fileContent] cut to [maxResponseLen] bytes, tabs
  /// expanded, each line numbered as `%6d\t` from [initLine].
  static String _makeOutput(
    String fileContent,
    String fileDescriptor,
    int initLine,
  ) {
    final lines = expandTabs(truncate(fileContent, maxResponseLen)).split('\n');
    final numbered = [
      for (var i = 0; i < lines.length; i++)
        '${'${i + initLine}'.padLeft(6)}\t${lines[i]}',
    ].join('\n');
    return "Here's the result of running `cat -n` on $fileDescriptor:\n"
        '$numbered\n';
  }
}

/// Go's `json.Unmarshal([]byte(argumentsInJSON), &StrReplaceEditorParams{})`
/// with its `failed to extract input: %w`, followed by the check of the
/// command Go's `Execute` makes.
StrReplaceEditorParams _decodeParams(String argumentsJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(argumentsJson);
  } on FormatException catch (error) {
    throw ThreepioFormatException(
      'failed to extract input: ${error.message}',
      source: argumentsJson,
      offset: error.offset,
      cause: error,
    );
  }
  if (decoded != null && decoded is! Map<String, Object?>) {
    throw ThreepioFormatException(
      'failed to extract input: json: cannot unmarshal '
      '${_goJsonKind(decoded)} into Go value of type '
      'commandline.StrReplaceEditorParams',
      source: argumentsJson,
    );
  }
  // Go: `null` leaves every field empty, so the command is unrecognized.
  return StrReplaceEditorParams.fromJson(
    decoded as Map<String, Object?>? ?? const {},
  );
}

String _string(String field, Object value, String goType) {
  if (value is String) return value;
  throw _typeError(field, value, goType);
}

int _int(String field, Object value, String goType) {
  if (value is int) return value;
  throw _typeError(field, value, goType);
}

List<int> _intList(String field, Object value) {
  if (value is! List<Object?>) throw _typeError(field, value, '[]int');
  return [
    for (final element in value)
      if (element == null) 0 else _int(field, element, 'int'),
  ];
}

/// Go's `*json.UnmarshalTypeError` for [field], under `failed to extract
/// input: %w`.
ThreepioFormatException _typeError(String field, Object value, String goType) {
  final kind = value is num && goType == 'int' ? 'number $value' : _goJsonKind(value);
  return ThreepioFormatException(
    'failed to extract input: json: cannot unmarshal $kind into Go struct '
    'field StrReplaceEditorParams.$field of type $goType',
  );
}

/// [key] folded the way Go's `encoding/json` matches object keys with field
/// names when none matches exactly (`bytes.EqualFold`). The field names here
/// are lower-case ASCII, so only the runes that fold to ASCII letters
/// matter: `A`-`Z`, the Kelvin sign (`k`) and the long s (`s`).
String _goFoldedKey(String key) {
  final buffer = StringBuffer();
  for (final rune in key.runes) {
    buffer.writeCharCode(switch (rune) {
      >= 0x41 && <= 0x5A => rune + 0x20,
      0x212A => 0x6B,
      0x017F => 0x73,
      _ => rune,
    });
  }
  return buffer.toString();
}

/// The name Go's `encoding/json` gives the kind of a JSON value in its type
/// errors.
String _goJsonKind(Object? value) => switch (value) {
      String() => 'string',
      bool() => 'bool',
      num() => 'number',
      List<Object?>() => 'array',
      _ => 'object',
    };

/// Go's `strings.Count`: the non-overlapping occurrences of [sep] in [text],
/// or the number of characters plus one when [sep] is empty.
int _goCount(String text, String sep) {
  if (sep.isEmpty) return text.runes.length + 1;
  var count = 0;
  var index = text.indexOf(sep);
  while (index >= 0) {
    count++;
    index = text.indexOf(sep, index + sep.length);
  }
  return count;
}

/// A list of ints as Go's `%v` prints it: `[2 4]`.
String _goIntList(List<int> values) => '[${values.join(' ')}]';
