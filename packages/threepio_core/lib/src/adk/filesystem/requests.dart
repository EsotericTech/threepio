/// The requests and results of a filesystem backend.
///
/// Port of the types of eino `adk/filesystem/backend.go`.
library;

import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// What a backend knows about a file or directory.
///
/// Port of eino `filesystem.FileInfo`.
@immutable
final class FileInfo {
  /// The entry at [path].
  const FileInfo({
    required this.path,
    this.isDir = false,
    this.size = 0,
    this.modifiedAt = '',
  });

  /// The path of the entry: a name, a relative or an absolute path,
  /// depending on the request.
  final String path;

  /// Whether the entry is a directory.
  final bool isDir;

  /// The size in bytes; 0 (or what the platform says) for a directory.
  final int size;

  /// When the entry was last changed, in ISO 8601 (for example
  /// `2025-01-15T10:30:00Z`); empty when unknown.
  final String modifiedAt;

  @override
  bool operator ==(Object other) =>
      other is FileInfo &&
      other.path == path &&
      other.isDir == isDir &&
      other.size == size &&
      other.modifiedAt == modifiedAt;

  @override
  int get hashCode => Object.hash(path, isDir, size, modifiedAt);

  @override
  String toString() =>
      'FileInfo($path${isDir ? ', dir' : ''}, $size bytes, $modifiedAt)';
}

/// One line that matched a grep, or a line of context around one.
///
/// Port of eino `filesystem.GrepMatch`.
@immutable
final class GrepMatch {
  /// The line [line] of [path], with its [content].
  const GrepMatch({required this.path, required this.line, this.content = ''});

  /// The text of the line, without its line break.
  final String content;

  /// The file the line is in.
  final String path;

  /// The number of the line, from 1.
  final int line;

  @override
  bool operator ==(Object other) =>
      other is GrepMatch &&
      other.path == path &&
      other.line == line &&
      other.content == content;

  @override
  int get hashCode => Object.hash(path, line, content);

  @override
  String toString() => '$path:$line: $content';
}

/// Lists the entries of a directory. Port of eino
/// `filesystem.LsInfoRequest`.
@immutable
final class LsInfoRequest {
  /// The entries of [path] (the root when empty).
  const LsInfoRequest({this.path = ''});

  /// The directory to list.
  final String path;
}

/// Reads a file, or a range of its lines.
///
/// Port of eino `filesystem.ReadRequest`.
@immutable
final class ReadRequest {
  /// Reads [filePath], from line [offset] (1-based), at most [limit] lines.
  const ReadRequest({required this.filePath, this.offset = 1, this.limit = 0});

  /// The file to read.
  final String filePath;

  /// The first line to read, counted from 1; a value below 1 means 1. Use it
  /// with [limit] for a file too large to read at once.
  final int offset;

  /// The largest number of lines to read; 0 (or less) reads to the end.
  final int limit;
}

/// Reads a file that may be an image or a PDF.
///
/// Port of eino `filesystem.MultiModalReadRequest`.
@immutable
final class MultiModalReadRequest extends ReadRequest {
  /// Reads [filePath]; for a PDF the [pages] given (`'1-5'`, `'3'`).
  const MultiModalReadRequest({
    required super.filePath,
    super.offset,
    super.limit,
    this.pages = '',
  });

  /// The pages of a PDF to read, such as `'1-5'`, `'3'` or `'10-20'`; empty
  /// for all.
  final String pages;
}

/// Searches the contents of files with a regular expression.
///
/// Port of eino `filesystem.GrepRequest`.
@immutable
final class GrepRequest {
  /// Searches for [pattern].
  const GrepRequest({
    required this.pattern,
    this.path = '',
    this.glob = '',
    this.fileType = '',
    this.caseInsensitive = false,
    this.enableMultiline = false,
    this.afterLines = 0,
    this.beforeLines = 0,
  });

  /// The regular expression to look for, in ripgrep syntax (`log.*Error`,
  /// `function\s+\w+`; literal braces escaped: `interface\{\}`).
  final String pattern;

  /// The directory the search is limited to; empty for everywhere.
  final String path;

  /// Only files whose path matches this glob are searched: `*` (not across
  /// `/`), `**` (across directories), `?`, `[abc]`. Empty for all files.
  final String glob;

  /// Only files of this type are searched (`'js'`, `'py'`, `'rust'`, ...).
  final String fileType;

  /// Whether upper and lower case match each other.
  final bool caseInsensitive;

  /// Whether a match may span lines; by default each line is matched alone.
  final bool enableMultiline;

  /// The lines of context shown after each match; 0 or less for none.
  final int afterLines;

  /// The lines of context shown before each match; 0 or less for none.
  final int beforeLines;
}

/// Finds files by a glob pattern. Port of eino
/// `filesystem.GlobInfoRequest`.
@immutable
final class GlobInfoRequest {
  /// The files under [path] that match [pattern].
  const GlobInfoRequest({required this.pattern, this.path = ''});

  /// The glob: `*` (not across `/`), `**` (across directories), `?`,
  /// `[abc]`.
  final String pattern;

  /// The directory the search starts from (the root when empty).
  final String path;
}

/// Creates a file or replaces its whole content.
///
/// Port of eino `filesystem.WriteRequest`.
@immutable
final class WriteRequest {
  /// Writes [content] to [filePath].
  const WriteRequest({required this.filePath, required this.content});

  /// The file to write.
  final String filePath;

  /// The new content of the file.
  final String content;
}

/// Replaces text in a file.
///
/// Port of eino `filesystem.EditRequest`.
@immutable
final class EditRequest {
  /// Replaces [oldString] by [newString] in [filePath].
  const EditRequest({
    required this.filePath,
    required this.oldString,
    required this.newString,
    this.replaceAll = false,
  });

  /// The file to edit.
  final String filePath;

  /// The exact text to replace, whitespace included; must not be empty.
  final String oldString;

  /// The text that replaces it; empty to delete [oldString].
  final String newString;

  /// Whether every occurrence is replaced. Without it the edit fails unless
  /// [oldString] occurs exactly once.
  final bool replaceAll;
}

/// The kind of a part of a file read as images or PDF.
///
/// Port of eino `filesystem.FileContentPartType`.
enum FileContentPartType {
  /// An image (PNG, JPEG, ...).
  image('image'),

  /// A PDF document.
  pdf('pdf');

  const FileContentPartType(this.value);

  /// The name eino uses.
  final String value;
}

/// A part of a file read as images or PDF.
///
/// Port of eino `filesystem.FileContentPart`.
@immutable
final class FileContentPart {
  /// A part of [type] with the raw [data].
  const FileContentPart({
    required this.type,
    required this.mimeType,
    required this.data,
  });

  /// What the part is.
  final FileContentPartType type;

  /// Its MIME type (`image/png`, `application/pdf`).
  final String mimeType;

  /// The raw bytes; whoever uses the part encodes them (Base64, ...).
  final Uint8List data;

  @override
  bool operator ==(Object other) =>
      other is FileContentPart &&
      other.type == type &&
      other.mimeType == mimeType &&
      const ListEquality<int>().equals(other.data, data);

  @override
  int get hashCode =>
      Object.hash(type, mimeType, const ListEquality<int>().hash(data));
}

/// The text a read returned. Port of eino `filesystem.FileContent`.
@immutable
final class FileContent {
  /// The text [content].
  const FileContent([this.content = '']);

  /// The text of the file, or of the lines asked for.
  final String content;

  @override
  bool operator ==(Object other) =>
      other is FileContent && other.content == content;

  @override
  int get hashCode => content.hashCode;

  @override
  String toString() => 'FileContent(${content.length} chars)';
}

/// What a multimodal read returned: either text or parts.
///
/// Port of eino `filesystem.MultiFileContent`. When [parts] is not empty
/// [fileContent] is ignored.
@immutable
final class MultiFileContent {
  /// The result of a multimodal read.
  const MultiFileContent({this.fileContent, this.parts = const []});

  /// The text of the file, for a plain text file.
  final FileContent? fileContent;

  /// The images or PDF pages of the file.
  final List<FileContentPart> parts;
}

/// A shell command to run. Port of eino `filesystem.ExecuteRequest`.
@immutable
final class ExecuteRequest {
  /// Runs [command].
  const ExecuteRequest({required this.command, this.runInBackground = false});

  /// The command line.
  final String command;

  /// Whether the command runs in the background (eino's
  /// `RunInBackendGround`).
  final bool runInBackground;
}

/// What a shell command returned. Port of eino
/// `filesystem.ExecuteResponse`.
@immutable
final class ExecuteResponse {
  /// The result of a command.
  const ExecuteResponse({this.output = '', this.exitCode, this.truncated = false});

  /// What the command printed.
  final String output;

  /// Its exit code; `null` when it has none (yet).
  final int? exitCode;

  /// Whether [output] was cut short.
  final bool truncated;

  @override
  bool operator ==(Object other) =>
      other is ExecuteResponse &&
      other.output == output &&
      other.exitCode == exitCode &&
      other.truncated == truncated;

  @override
  int get hashCode => Object.hash(output, exitCode, truncated);

  @override
  String toString() =>
      'ExecuteResponse(exitCode: $exitCode${truncated ? ', truncated' : ''})';
}
