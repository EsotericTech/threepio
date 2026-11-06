/// A filesystem backend that keeps its files in memory.
///
/// Port of eino `adk/filesystem/backend_inmemory.go`.
library;

import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:glob/glob.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../core/run_context.dart';
import '../../errors.dart';
import 'backend.dart';
import 'requests.dart';

/// POSIX paths, resolved against the root whatever the process's directory.
final p.Context _paths = p.Context(style: p.Style.posix, current: '/');

final class _FileEntry {
  _FileEntry(this.content, this.modifiedAt);

  final String content;
  final DateTime modifiedAt;

  int get size => utf8.encode(content).length;
}

/// A [FilesystemBackend] whose files live in a map: for tests, for agents
/// that need a scratch space, and as the reference implementation.
///
/// Port of eino `filesystem.InMemoryBackend` (`NewInMemoryBackend`). Paths
/// are POSIX paths; every path is made absolute and cleaned (`a//b/../c` is
/// `/a/c`). Directories exist only as prefixes of file paths. `grepRaw` takes
/// a Dart regular expression (eino: RE2); a leading inline flag group such as
/// `(?i)`, `(?m)` or `(?s)` is understood, and `.` matches `\r` as in RE2.
/// Globs have eino's (doublestar's) syntax: `*` does not cross `/`; `**` as
/// a whole path segment crosses directories (`**/` may match none) and
/// elsewhere is `*`; `?`, `[abc]`, `{a,b}`; `(`, `)` are plain characters.
///
/// A missing file is a plain [ThreepioException] (`file not found: <path>`),
/// as in eino, whose in-memory backend does not wrap `os.ErrNotExist`: the
/// agents.md middleware therefore fails the run for a missing file on this
/// backend instead of skipping it (see [FileNotFoundException]).
final class InMemoryBackend implements FilesystemBackend {
  /// An empty backend.
  InMemoryBackend();

  final Map<String, _FileEntry> _files = {};

  @override
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request) async {
    final path = normalizePath(request.path);
    final result = <FileInfo>[];
    final seen = <String>{};
    final directories = <String, (String name, DateTime modifiedAt)>{};

    for (final MapEntry(key: filePath, value: entry) in _files.entries) {
      if (!(path == '/' ||
          filePath.startsWith('$path/') ||
          filePath == path)) {
        continue;
      }
      var relative = filePath.substring(path.length);
      if (relative.startsWith('/')) relative = relative.substring(1);

      if (relative.isEmpty) {
        // The path is the file itself.
        if (seen.add(filePath)) {
          result.add(_infoOf(_paths.basename(filePath), entry));
        }
        continue;
      }

      final slash = relative.indexOf('/');
      final name = slash < 0 ? relative : relative.substring(0, slash);
      final isDir = slash >= 0;
      final childPath = path == '/' ? '/$name' : '$path/$name';
      if (seen.add(childPath)) {
        if (isDir) {
          directories[childPath] = (name, entry.modifiedAt);
        } else {
          result.add(_infoOf(name, entry));
        }
      } else if (isDir) {
        final existing = directories[childPath];
        if (existing != null && entry.modifiedAt.isAfter(existing.$2)) {
          directories[childPath] = (existing.$1, entry.modifiedAt);
        }
      }
    }

    for (final (name, modifiedAt) in directories.values) {
      result.add(
        FileInfo(path: name, isDir: true, modifiedAt: _format(modifiedAt)),
      );
    }
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) async {
    final filePath = normalizePath(request.filePath);
    final entry = _files[filePath];
    if (entry == null) {
      // Eino's in-memory backend does not wrap os.ErrNotExist: a missing
      // file is a plain error, which the agents.md middleware does not skip.
      throw ThreepioException('file not found: $filePath');
    }

    // 1-based offset to a 0-based line index; below 1 means the first line.
    final offset = request.offset - 1 < 0 ? 0 : request.offset - 1;
    final limit = request.limit;
    final content = entry.content;

    if (offset == 0 && limit <= 0) return FileContent(content);
    if (offset == 0 && '\n'.allMatches(content).length + 1 <= limit) {
      return FileContent(content);
    }

    var start = 0;
    for (var i = 0; i < offset; i++) {
      final index = content.indexOf('\n', start);
      if (index < 0) return const FileContent(); // offset beyond the last line
      start = index + 1;
    }
    if (limit <= 0) return FileContent(content.substring(start));

    var end = start;
    for (var i = 0; i < limit; i++) {
      final index = content.indexOf('\n', end);
      if (index < 0) return FileContent(content.substring(start));
      end = index + 1;
    }
    // Without the line break of the last line.
    return FileContent(content.substring(start, end - 1));
  }

  @override
  Future<List<GrepMatch>> grepRaw(RunContext ctx, GrepRequest request) async {
    if (request.pattern.isEmpty) {
      throw const ThreepioException('pattern cannot be empty');
    }
    final regExp = compileGrepPattern(
      request.pattern,
      caseInsensitive: request.caseInsensitive,
    );
    final searchPath =
        request.path.isEmpty ? '/' : normalizePath(request.path);
    final files = _filterFiles(searchPath, request);
    if (files.isEmpty) return [];

    var matches = <GrepMatch>[
      for (final file in files)
        ...(request.enableMultiline
            ? _multilineMatches(file, _files[file]!.content, regExp)
            : _singleLineMatches(file, _files[file]!.content, regExp)),
    ];
    if (request.beforeLines > 0 || request.afterLines > 0) {
      matches = _withContext(matches, request);
    }
    _sortMatches(matches);
    return matches;
  }

  @override
  Future<List<FileInfo>> globInfo(
    RunContext ctx,
    GlobInfoRequest request,
  ) async {
    final basePath = normalizePath(request.path);
    final isAbsolutePattern = request.pattern.startsWith('/');
    // Compiled at the first file, as eino's doublestar meets a bad pattern
    // only when it matches.
    _GlobMatcher? glob;
    final result = <FileInfo>[];

    for (final MapEntry(key: filePath, value: entry) in _files.entries) {
      final String matchPath;
      if (isAbsolutePattern) {
        matchPath = filePath;
      } else {
        if (basePath != '/' &&
            !filePath.startsWith('$basePath/') &&
            filePath != basePath) {
          continue;
        }
        matchPath = basePath == '/'
            ? filePath.substring(1)
            : _withoutPrefix(filePath, '$basePath/');
      }
      glob ??= _GlobMatcher(request.pattern);
      if (glob.matches(matchPath)) result.add(_infoOf(matchPath, entry));
    }
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  @override
  Future<void> write(RunContext ctx, WriteRequest request) async {
    _files[normalizePath(request.filePath)] =
        _FileEntry(request.content, clock.now());
  }

  @override
  Future<void> edit(RunContext ctx, EditRequest request) async {
    final filePath = normalizePath(request.filePath);
    final entry = _files[filePath];
    if (entry == null) {
      // Eino's in-memory backend does not wrap os.ErrNotExist: a missing
      // file is a plain error, which the agents.md middleware does not skip.
      throw ThreepioException('file not found: $filePath');
    }
    final old = request.oldString;
    if (old.isEmpty) {
      throw const ThreepioException('oldString must be non-empty');
    }
    final content = entry.content;
    final first = content.indexOf(old);
    if (first < 0) {
      throw ThreepioException('oldString not found in file: $filePath');
    }
    if (!request.replaceAll && content.indexOf(old, first + old.length) >= 0) {
      throw ThreepioException(
        'multiple occurrences of oldString found in file $filePath, but '
        'ReplaceAll is false',
      );
    }
    final updated = request.replaceAll
        ? content.replaceAll(old, request.newString)
        : content.replaceFirst(old, request.newString);
    _files[filePath] = _FileEntry(updated, clock.now());
  }

  List<String> _filterFiles(String searchPath, GrepRequest request) {
    var candidates = [
      for (final filePath in _files.keys)
        if (searchPath == '/' ||
            filePath.startsWith('$searchPath/') ||
            filePath == searchPath)
          filePath,
    ];
    if (request.glob.isNotEmpty && candidates.isNotEmpty) {
      final glob = _GlobMatcher(request.glob);
      final byPath =
          request.glob.contains('/') || request.glob.contains('**');
      candidates = [
        for (final filePath in candidates)
          if (glob.matches(
            !byPath
                ? _paths.basename(filePath)
                : searchPath == '/'
                    ? filePath.substring(1)
                    : _withoutPrefix(filePath, '$searchPath/'),
          ))
            filePath,
      ];
    }
    if (request.fileType.isNotEmpty) {
      candidates = [
        for (final filePath in candidates)
          if (matchFileType(_extensionOf(filePath), request.fileType))
            filePath,
      ];
    }
    return candidates;
  }

  List<GrepMatch> _withContext(List<GrepMatch> matches, GrepRequest request) {
    if (matches.isEmpty) return matches;
    final before = request.beforeLines > 0 ? request.beforeLines : 0;
    final after = request.afterLines > 0 ? request.afterLines : 0;
    if (before <= 0 && after <= 0) return matches;

    final byFile = <String, List<GrepMatch>>{};
    for (final match in matches) {
      (byFile[match.path] ??= []).add(match);
    }
    final result = <GrepMatch>[];
    for (final MapEntry(key: filePath, value: fileMatches) in byFile.entries) {
      final entry = _files[filePath];
      if (entry == null) {
        result.addAll(fileMatches);
        continue;
      }
      final lines = entry.content.split('\n');
      final done = <int>{};
      for (final match in fileMatches) {
        final first = match.line - before < 1 ? 1 : match.line - before;
        final last =
            match.line + after > lines.length ? lines.length : match.line + after;
        for (var line = first; line <= last; line++) {
          if (done.add(line)) {
            result.add(
              GrepMatch(path: filePath, line: line, content: lines[line - 1]),
            );
          }
        }
      }
    }
    return result;
  }

  static List<GrepMatch> _singleLineMatches(
    String filePath,
    String content,
    RegExp regExp,
  ) {
    final lines = content.split('\n');
    return [
      for (final (index, line) in lines.indexed)
        if (regExp.hasMatch(line))
          GrepMatch(path: filePath, line: index + 1, content: line),
    ];
  }

  static List<GrepMatch> _multilineMatches(
    String filePath,
    String content,
    RegExp regExp,
  ) {
    final lines = content.split('\n');
    // The offset at which each line starts, to find a match's lines.
    final starts = <int>[0];
    for (var i = content.indexOf('\n');
        i >= 0;
        i = content.indexOf('\n', i + 1)) {
      starts.add(i + 1);
    }
    int lineAt(int offset) {
      var low = 0;
      var high = starts.length - 1;
      while (low < high) {
        final mid = (low + high + 1) >> 1;
        if (starts[mid] <= offset) {
          low = mid;
        } else {
          high = mid - 1;
        }
      }
      return low + 1;
    }

    final result = <GrepMatch>[];
    int? previousEnd;
    for (final match in regExp.allMatches(content)) {
      // RE2 (Go's FindAll) drops an empty match right after a match.
      final abutting = match.start == match.end && match.start == previousEnd;
      previousEnd = match.end;
      if (abutting) continue;
      final first = lineAt(match.start);
      final last = lineAt(match.end);
      for (var line = first; line <= last && line <= lines.length; line++) {
        result.add(
          GrepMatch(path: filePath, line: line, content: lines[line - 1]),
        );
      }
    }
    return result;
  }

  static void _sortMatches(List<GrepMatch> matches) {
    // A stable sort by path, then line.
    final indexed = matches.indexed.toList()
      ..sort((a, b) {
        final byPath = a.$2.path.compareTo(b.$2.path);
        if (byPath != 0) return byPath;
        final byLine = a.$2.line.compareTo(b.$2.line);
        return byLine != 0 ? byLine : a.$1.compareTo(b.$1);
      });
    matches
      ..clear()
      ..addAll(indexed.map((entry) => entry.$2));
  }

  static FileInfo _infoOf(String path, _FileEntry entry) => FileInfo(
        path: path,
        size: entry.size,
        modifiedAt: _format(entry.modifiedAt),
      );

  static String _format(DateTime time) => time.toUtc().toIso8601String();

  static String _withoutPrefix(String value, String prefix) =>
      value.startsWith(prefix) ? value.substring(prefix.length) : value;

  /// The extension after the last dot of the last segment, without the dot
  /// (`.env` for `/a/.env`). Port of Go's `filepath.Ext`.
  static String _extensionOf(String filePath) {
    for (var i = filePath.length - 1; i >= 0 && filePath[i] != '/'; i--) {
      if (filePath[i] == '.') return filePath.substring(i + 1);
    }
    return '';
  }
}

/// A glob pattern in eino's syntax (`github.com/bmatcuk/doublestar/v4`),
/// matched with `package:glob`.
///
/// Everything is matched as an absolute path: a relative pattern and a
/// relative path get a leading `/` (which also keeps `package:glob` away from
/// a leading brace group with an empty option, `{,src/}*.dart`, which it
/// cannot match). As in doublestar, a relative pattern matches an absolute
/// path only through the empty segment before its `/`: when it starts with a
/// `**` segment, or with a `*` segment followed by the rest of the path; an
/// absolute pattern never matches a relative path; and `a/**` also matches
/// `a` itself.
final class _GlobMatcher {
  factory _GlobMatcher(String pattern) {
    final relative = !pattern.startsWith('/');
    final translated = pattern.isEmpty ? '' : globSyntaxOf(pattern);
    if (translated.isEmpty) {
      return _GlobMatcher._(relative, null, null, false, null);
    }
    final absolute = relative ? '/$translated' : translated;
    final directory = absolute.endsWith('/**') && absolute.length > 3
        ? _compile(absolute.substring(0, absolute.length - 3))
        : null;
    // `*/rest`: the `*` can match the empty first segment of an absolute
    // path, whose remainder must then match `rest`.
    final starRest = relative && translated.startsWith('*/')
        ? _GlobMatcher(pattern.substring(2))
        : null;
    return _GlobMatcher._(
      relative,
      _compile(absolute),
      directory,
      translated == '**' || translated.startsWith('**/'),
      starRest,
    );
  }

  _GlobMatcher._(
    this._relative,
    this._glob,
    this._directory,
    this._crossesRoot,
    this._starRest,
  );

  final bool _relative;
  final Glob? _glob;

  /// For a pattern ending in `/**`: the directory itself.
  final Glob? _directory;

  /// Whether a relative pattern starts with a `**` segment.
  final bool _crossesRoot;

  /// For a relative pattern `*/rest`: the matcher of `rest`.
  final _GlobMatcher? _starRest;

  static Glob _compile(String pattern) {
    try {
      return Glob(pattern, context: _paths, caseSensitive: true);
    } on FormatException catch (error) {
      throw ThreepioException(
        'invalid glob pattern: ${error.message}',
        cause: error,
      );
    }
  }

  /// Whether [path] matches; an empty pattern matches only the empty path.
  bool matches(String path) {
    final glob = _glob;
    if (glob == null) return path.isEmpty;
    final String absolute;
    if (_relative) {
      if (path.startsWith('/')) {
        final starRest = _starRest;
        if (starRest != null) return starRest.matches(path.substring(1));
        if (!_crossesRoot) return false;
        absolute = path;
      } else {
        absolute = '/$path';
      }
    } else {
      if (!path.startsWith('/')) return false;
      absolute = path;
    }
    return glob.matches(absolute) || (_directory?.matches(absolute) ?? false);
  }
}

/// [pattern], a doublestar glob, in `package:glob`'s syntax: `(`, `)` and a
/// `]` or `}` without its opening bracket become plain characters, a brace
/// group with one option becomes that option, and a `**` that is not a whole
/// path segment becomes `*`.
@internal
String globSyntaxOf(String pattern) {
  final buffer = StringBuffer();
  var i = 0;
  while (i < pattern.length) {
    final char = pattern[i];
    if (char == r'\' && i + 1 < pattern.length) {
      buffer.write(pattern.substring(i, i + 2));
      i += 2;
      continue;
    }
    if (char == '[') {
      final end = _classEnd(pattern, i);
      if (end >= 0) {
        buffer.write(pattern.substring(i, end + 1));
        i = end + 1;
        continue;
      }
      // An unclosed class is a bad pattern for both.
      buffer.write(char);
      i++;
      continue;
    }
    if (char == '{') {
      final end = _braceEnd(pattern, i);
      if (end >= 0) {
        final options = [
          for (final option in _splitOptions(pattern.substring(i + 1, end)))
            globSyntaxOf(option),
        ];
        buffer.write(
          options.length == 1 ? options.single : '{${options.join(',')}}',
        );
        i = end + 1;
        continue;
      }
      buffer.write(char);
      i++;
      continue;
    }
    if (char == '(' || char == ')' || char == ']' || char == '}') {
      buffer.write('\\$char');
      i++;
      continue;
    }
    if (char == '*') {
      var end = i;
      while (end < pattern.length && pattern[end] == '*') {
        end++;
      }
      final wholeSegment = end - i == 2 &&
          (i == 0 || pattern[i - 1] == '/') &&
          (end == pattern.length || pattern[end] == '/');
      buffer.write(wholeSegment ? '**' : '*');
      i = end;
      continue;
    }
    buffer.write(char);
    i++;
  }
  return buffer.toString();
}

/// The index of the `]` that closes the class opened at [start], or -1.
int _classEnd(String pattern, int start) {
  var i = start + 1;
  if (i < pattern.length && (pattern[i] == '!' || pattern[i] == '^')) i++;
  var first = true;
  while (i < pattern.length) {
    final char = pattern[i];
    if (char == r'\') {
      i += 2;
      first = false;
      continue;
    }
    if (char == ']' && !first) return i;
    first = false;
    i++;
  }
  return -1;
}

/// The index of the `}` that closes the group opened at [start], or -1.
int _braceEnd(String pattern, int start) {
  var depth = 0;
  var i = start;
  while (i < pattern.length) {
    final char = pattern[i];
    if (char == r'\') {
      i += 2;
      continue;
    }
    if (char == '[') {
      final end = _classEnd(pattern, i);
      if (end >= 0) {
        i = end + 1;
        continue;
      }
    }
    if (char == '{') depth++;
    if (char == '}') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

/// The options of a brace group's [body], split at its own commas.
List<String> _splitOptions(String body) {
  final options = <String>[];
  var depth = 0;
  var start = 0;
  var i = 0;
  while (i < body.length) {
    final char = body[i];
    if (char == r'\') {
      i += 2;
      continue;
    }
    if (char == '[') {
      final end = _classEnd(body, i);
      if (end >= 0) {
        i = end + 1;
        continue;
      }
    }
    if (char == '{') depth++;
    if (char == '}') depth--;
    if (char == ',' && depth == 0) {
      options.add(body.substring(start, i));
      start = i + 1;
    }
    i++;
  }
  options.add(body.substring(start));
  return options;
}

/// [path] made absolute and cleaned: `''` is `/`, `a//b/../c` is `/a/c`, no
/// trailing `/`. Port of eino `normalizePath`.
@internal
String normalizePath(String path) {
  if (path.isEmpty) return '/';
  return _paths.normalize(path.startsWith('/') ? path : '/$path');
}

/// Whether a file with the extension [extension] (without the dot) is of the
/// ripgrep type [fileType] (`'py'`, `'python'`, `'ts'`, ...), or has
/// [fileType] as its extension. Port of eino `matchFileType`.
@internal
bool matchFileType(String extension, String fileType) {
  final extensions = _fileTypes[fileType];
  if (extensions != null && extensions.contains(extension)) return true;
  return extension == fileType;
}

/// [pattern] as a Dart regular expression: a leading inline flag group
/// (`(?i)`, `(?m)`, `(?s)` or a combination) becomes the flags Dart takes as
/// arguments, and without `s` a `.` matches everything but `\n`, as in RE2
/// (a Dart `.` also stops at `\r`, U+2028 and U+2029). Throws
/// [ThreepioException] for a pattern that does not compile.
@internal
RegExp compileGrepPattern(
  String pattern, {
  bool caseInsensitive = false,
  bool dotAll = false,
}) {
  var source = pattern;
  var ignoreCase = caseInsensitive;
  var multiLine = false;
  var matchAll = dotAll;
  final flags = RegExp(r'^\(\?([imsU]+)\)').firstMatch(source);
  if (flags != null) {
    final letters = flags.group(1)!;
    ignoreCase |= letters.contains('i');
    multiLine = letters.contains('m');
    matchAll |= letters.contains('s');
    source = source.substring(flags.end);
  }
  if (!matchAll) source = _dotsAsRe2(source);
  try {
    return RegExp(
      source,
      caseSensitive: !ignoreCase,
      multiLine: multiLine,
      dotAll: matchAll,
    );
  } on FormatException catch (error) {
    throw ThreepioException(
      'invalid regex pattern: ${error.message}',
      cause: error,
    );
  }
}

/// [source] with every `.` that is not escaped or in a class written as
/// `[^\n]`, RE2's meaning of `.`. A `]` right after `[` or `[^` is a plain
/// character in RE2 and is escaped for Dart.
String _dotsAsRe2(String source) {
  final buffer = StringBuffer();
  var inClass = false;
  var i = 0;
  while (i < source.length) {
    final char = source[i];
    if (char == r'\' && i + 1 < source.length) {
      buffer.write(source.substring(i, i + 2));
      i += 2;
      continue;
    }
    if (inClass) {
      if (char == ']') inClass = false;
      buffer.write(char);
      i++;
      continue;
    }
    if (char == '[') {
      inClass = true;
      buffer.write(char);
      i++;
      if (i < source.length && source[i] == '^') {
        buffer.write('^');
        i++;
      }
      if (i < source.length && source[i] == ']') {
        buffer.write(r'\]');
        i++;
      }
      continue;
    }
    buffer.write(char == '.' ? r'[^\n]' : char);
    i++;
  }
  return buffer.toString();
}

/// The ripgrep file types eino knows, with their extensions.
const Map<String, List<String>> _fileTypes = {
  'ada': ['adb', 'ads'],
  'agda': ['agda', 'lagda'],
  'aidl': ['aidl'],
  'amake': ['bp', 'mk'],
  'asciidoc': ['adoc', 'asc', 'asciidoc'],
  'asm': ['S', 'asm', 's'],
  'asp': ['ascx', 'asp', 'aspx'],
  'ats': ['ats', 'dats', 'hats', 'sats'],
  'avro': ['avdl', 'avpr', 'avsc'],
  'awk': ['awk'],
  'bat': ['bat'],
  'bazel': ['BUILD', 'bazel', 'bzl'],
  'bitbake': ['bb', 'bbappend', 'bbclass', 'conf', 'inc'],
  'c': ['c', 'h', 'H', 'cats'],
  'cabal': ['cabal'],
  'cbor': ['cbor'],
  'ceylon': ['ceylon'],
  'clojure': ['clj', 'cljc', 'cljs', 'cljx'],
  'cmake': ['cmake'],
  'coffeescript': ['coffee'],
  'config': ['cfg', 'conf', 'config', 'ini'],
  'coq': ['v'],
  'cpp': [
    'C', 'cc', 'cpp', 'cxx', 'c++', 'h', 'hh', 'hpp', 'hxx', 'h++', 'inl', //
  ],
  'crystal': ['cr', 'ecr'],
  'cs': ['cs'],
  'csharp': ['cs'],
  'cshtml': ['cshtml'],
  'css': ['css', 'scss', 'sass', 'less'],
  'csv': ['csv'],
  'cuda': ['cu', 'cuh'],
  'cython': ['pxd', 'pxi', 'pyx'],
  'd': ['d'],
  'dart': ['dart'],
  'devicetree': ['dts', 'dtsi'],
  'dhall': ['dhall'],
  'diff': ['diff', 'patch'],
  'docker': ['dockerfile'],
  'go': ['go'],
  'groovy': ['gradle', 'groovy'],
  'haskell': ['c2hs', 'cpphs', 'hs', 'hsc', 'lhs'],
  'html': ['ejs', 'htm', 'html'],
  'java': ['java', 'jsp', 'jspx', 'properties'],
  'js': ['cjs', 'js', 'jsx', 'mjs', 'vue'],
  'json': ['json', 'sarif'],
  'jsonl': ['jsonl'],
  'julia': ['jl'],
  'jupyter': ['ipynb', 'jpynb'],
  'kotlin': ['kt', 'kts'],
  'less': ['less'],
  'lua': ['lua'],
  'make': ['mak', 'mk'],
  'markdown': ['markdown', 'md', 'mdown', 'mdwn', 'mdx', 'mkd', 'mkdn'],
  'md': ['markdown', 'md', 'mdown', 'mdwn', 'mdx', 'mkd', 'mkdn'],
  'matlab': ['m'],
  'ocaml': ['ml', 'mli', 'mll', 'mly'],
  'perl': ['PL', 'perl', 'pl', 'plh', 'plx', 'pm', 't'],
  'php': ['php', 'php3', 'php4', 'php5', 'php7', 'php8', 'pht', 'phtml'],
  'python': ['py', 'pyi'],
  'py': ['py', 'pyi'],
  'ruby': ['gemspec', 'rb', 'rbw'],
  'rust': ['rs'],
  'sass': ['sass', 'scss'],
  'scala': ['sbt', 'scala'],
  'sh': ['bash', 'sh', 'zsh'],
  'sql': ['psql', 'sql'],
  'swift': ['swift'],
  'toml': ['toml'],
  'ts': ['cts', 'mts', 'ts', 'tsx'],
  'typescript': ['cts', 'mts', 'ts', 'tsx'],
  'txt': ['txt'],
  'vue': ['vue'],
  'xml': ['dtd', 'xml', 'xsd', 'xsl', 'xslt'],
  'yaml': ['yaml', 'yml'],
  'zig': ['zig'],
};
