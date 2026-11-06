/// A filesystem backend on the local machine's files.
///
/// Port of eino-ext `adk/backend/local` (`local.go`): `local.NewBackend`,
/// `local.Config`, `local.MultiModalReadConfig` and the `Local` methods
/// `LsInfo`, `Read`, `MultiModalRead`, `GrepRaw`, `GlobInfo`, `Write`,
/// `Edit` (the shell methods are in `local_shell.dart`).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../components/model/cancel_token.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../streaming/stream_reader.dart';
import '../middlewares/internal/go_compat.dart' show goClean, goDir, goExt;
import 'backend.dart';
import 'in_memory_backend.dart'
    show GlobMatcher, compileGrepPattern, matchFileType;
import 'local_shell.dart';
import 'requests.dart';

/// The limits of [LocalFilesystemBackend.multiModalRead].
///
/// Port of eino-ext `local.MultiModalReadConfig`. A limit that is `null`,
/// zero or negative takes its default; a limit above its hard cap is cut to
/// the cap, which keeps the size arithmetic safe. Go's `PDFRenderDPI`,
/// `PDFiumPool` and `PDFiumAcquireTimeout` only configure the rendering of
/// PDF pages, which this port does not do, and are left out.
@immutable
final class LocalMultiModalReadConfig {
  /// Limits for multimodal reads; every one left out takes its default.
  const LocalMultiModalReadConfig({
    this.maxImageSizeMB,
    this.maxPdfSizeMB,
    this.maxPagedPdfSizeMB,
    this.maxPdfPagesPerRequest,
  });

  /// The default of [maxImageSizeMB] (Go `defaultMaxImageSizeMB`).
  static const int defaultMaxImageSizeMB = 10;

  /// The default of [maxPdfSizeMB] (Go `defaultMaxPDFSizeMB`).
  static const int defaultMaxPdfSizeMB = 20;

  /// The default of [maxPagedPdfSizeMB] (Go `defaultMaxPagedPDFSizeMB`).
  static const int defaultMaxPagedPdfSizeMB = 100;

  /// The default of [maxPdfPagesPerRequest] (Go
  /// `defaultMaxPDFPagesPerRequest`).
  static const int defaultMaxPdfPagesPerRequest = 20;

  /// The cap of every size limit (Go `maxConfigurableMB`).
  static const int maxConfigurableMB = 2048;

  /// The cap of [maxPdfPagesPerRequest] (Go
  /// `maxConfigurablePDFPagesPerRequest`).
  static const int maxConfigurablePdfPagesPerRequest = 1000;

  /// The largest image read, in MB. Default 10, cap 2048.
  final int? maxImageSizeMB;

  /// The largest PDF read whole (without pages), in MB. Default 20, cap
  /// 2048.
  final int? maxPdfSizeMB;

  /// The largest PDF read with pages, in MB. Default 100, cap 2048.
  final int? maxPagedPdfSizeMB;

  /// The most pages one paged read may ask for. Default 20, cap 1000.
  final int? maxPdfPagesPerRequest;

  /// This config with every limit set: the defaults filled in and the caps
  /// applied. Port of `resolveMultiModalReadConfig`.
  LocalMultiModalReadConfig resolve() => LocalMultiModalReadConfig(
        maxImageSizeMB:
            _clamp(maxImageSizeMB, defaultMaxImageSizeMB, maxConfigurableMB),
        maxPdfSizeMB:
            _clamp(maxPdfSizeMB, defaultMaxPdfSizeMB, maxConfigurableMB),
        maxPagedPdfSizeMB: _clamp(
          maxPagedPdfSizeMB,
          defaultMaxPagedPdfSizeMB,
          maxConfigurableMB,
        ),
        maxPdfPagesPerRequest: _clamp(
          maxPdfPagesPerRequest,
          defaultMaxPdfPagesPerRequest,
          maxConfigurablePdfPagesPerRequest,
        ),
      );

  /// Port of `clampInt`: [fallback] for `null` or a value of 0 or less,
  /// [max] for a larger value.
  static int _clamp(int? value, int fallback, int max) {
    if (value == null || value <= 0) return fallback;
    return value > max ? max : value;
  }

  @override
  bool operator ==(Object other) =>
      other is LocalMultiModalReadConfig &&
      other.maxImageSizeMB == maxImageSizeMB &&
      other.maxPdfSizeMB == maxPdfSizeMB &&
      other.maxPagedPdfSizeMB == maxPagedPdfSizeMB &&
      other.maxPdfPagesPerRequest == maxPdfPagesPerRequest;

  @override
  int get hashCode => Object.hash(
        maxImageSizeMB,
        maxPdfSizeMB,
        maxPagedPdfSizeMB,
        maxPdfPagesPerRequest,
      );
}

/// A file that is larger than a multimodal read allows.
///
/// The Dart form of Go's unexported `errReadAllBytesTooLarge`, which callers
/// in the package detect with `errors.Is`; it is the cause of the error
/// [LocalFilesystemBackend.multiModalRead] throws for such a file.
@visibleForTesting
final class ReadAllBytesTooLargeException extends ThreepioException {
  /// The file at [path] has [size] bytes, more than [maxBytes].
  ReadAllBytesTooLargeException(this.path, this.size, this.maxBytes)
      : super(
          'file exceeds max allowed size: file $path ($size bytes, limit '
          '${maxBytes ~/ 1024 ~/ 1024}MB)',
        );

  /// The file.
  final String path;

  /// Its size in bytes.
  final int size;

  /// The limit it exceeds, in bytes.
  final int maxBytes;
}

/// A [FilesystemBackend] on this machine's files, which is also a
/// [MultiModalReader], a [Shell] and a [StreamingShell].
///
/// Port of eino-ext `local.Local` (`local.NewBackend(ctx, &local.Config{…})`).
/// Unix and macOS only, as in Go. Every path is cleaned lexically (Go
/// `filepath.Clean`: `a//b/../c` is `a/c`, before any symbolic link is
/// looked at) and used as it is: an absolute path, or a path relative to the
/// process's working directory (eino-ext's README asks for absolute paths,
/// its code accepts both). There is no root directory the paths are confined
/// to; give the backend only to agents that may see these files.
///
/// What each method returns, as in Go:
///
/// * [lsInfo] — the names of the entries of a directory, sorted, without
///   any other information ([FileInfo.isDir], [FileInfo.size] and
///   [FileInfo.modifiedAt] are not set); an empty list for a directory that
///   does not exist.
/// * [read] — lines `offset` (from 1) to `offset + limit - 1`; a `limit` of
///   0 or less means **2000 lines** (not the whole file, unlike
///   `InMemoryBackend`); the trailing line break of the result is removed.
/// * [multiModalRead] — images as one part, a PDF read whole as one part,
///   anything else as [read] does (see there for PDF pages).
/// * [grepRaw] — the lines that match, searched in this process (see there
///   for how it follows ripgrep, which Go runs).
/// * [globInfo] — the paths, relative to the search directory, of the files
///   *and directories* that match, sorted; the search starts at `/` when no
///   path is given.
/// * [write] — creates the parent directories and the file, or replaces the
///   file's content.
/// * [edit] — replaces text in a file, byte for byte (content that is not
///   UTF-8 elsewhere in the file is kept).
/// * [execute], [executeStreaming] — `/bin/sh -c <command>` through a
///   [LocalShell] (see there).
///
/// Errors are [ThreepioException]s with eino-ext's texts. A missing file is
/// a plain [ThreepioException] (`file not found: <path>` from [read], `failed
/// to read file: open <path>: no such file or directory` from [edit]), not
/// a [FileNotFoundException]: eino-ext's errors do not wrap
/// `os.ErrNotExist`, so the agents.md middleware fails on a missing file
/// here as it does in Go. A cancelled `ctx.cancelToken` stops [read],
/// [grepRaw], [globInfo] and [multiModalRead] with a [CancelledException]
/// (Go: `context canceled`).
final class LocalFilesystemBackend
    implements FilesystemBackend, MultiModalReader, Shell, StreamingShell {
  /// A backend on the local files.
  ///
  /// [validateCommand] checks every command before [execute] or
  /// [executeStreaming] runs it (Go `Config.ValidateCommand`; `null`
  /// accepts all of them). [multiModalRead] sets the limits of
  /// [multiModalRead] (Go `Config.MultiModalRead`).
  LocalFilesystemBackend({
    CommandValidator? validateCommand,
    LocalMultiModalReadConfig multiModalRead =
        const LocalMultiModalReadConfig(),
  })  : multiModalReadConfig = multiModalRead.resolve(),
        _shell = LocalShell(validateCommand: validateCommand);

  /// The limits of [multiModalRead] in effect: the given ones with the
  /// defaults filled in and the caps applied.
  final LocalMultiModalReadConfig multiModalReadConfig;

  final LocalShell _shell;

  /// The number of lines [read] returns when no limit is given.
  static const int defaultReadLimit = 2000;

  /// The names of the entries of a directory. Port of `Local.LsInfo`.
  ///
  /// A directory that does not exist gives an empty list; a path that is a
  /// file fails (`failed to read directory: …`).
  @override
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request) async {
    final path = goClean(request.path);
    final names = <String>[];
    try {
      await for (final entity in Directory(path).list(followLinks: false)) {
        names.add(_paths.basename(entity.path));
      }
    } on FileSystemException catch (error) {
      if (error is PathNotFoundException) return [];
      if (error is PathAccessException) {
        throw ThreepioException('permission denied: $path', cause: error);
      }
      final op = _errno(error) == _enotdir &&
              (await _typeOf(path)).$1 != FileSystemEntityType.notFound
          ? _readDirOp
          : 'open';
      throw ThreepioException(
        'failed to read directory: ${_pathError(op, path, error)}',
        cause: error,
      );
    }
    names.sort(_compareCodePoints);
    return [for (final name in names) FileInfo(path: name)];
  }

  /// Lines of a file. Port of `Local.Read`.
  ///
  /// [ReadRequest.offset] is the first line, from 1 (below 1 means 1);
  /// [ReadRequest.limit] the number of lines, [defaultReadLimit] when it is
  /// 0 or less. Lines keep their own line breaks (`\r\n` stays); the line
  /// break at the end of the result is removed. Bytes that are not UTF-8
  /// become U+FFFD (Go returns them as they are).
  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) async {
    final path = goClean(request.filePath);
    final RandomAccessFile file;
    try {
      file = await File(path).open();
    } on FileSystemException catch (error) {
      if (error is PathNotFoundException) {
        throw ThreepioException('file not found: $path', cause: error);
      }
      if (_errno(error) == _eisdir) {
        // Go opens a directory and fails when it reads it.
        throw ThreepioException(
          'error reading file: ${_pathError('read', path, error)}',
          cause: error,
        );
      }
      throw ThreepioException(
        'failed to open file: ${_pathError('open', path, error)}',
        cause: error,
      );
    }

    try {
      final int size;
      try {
        size = await file.length();
      } on FileSystemException catch (error) {
        throw ThreepioException(
          'failed to stat file: ${_pathError('stat', path, error)}',
          cause: error,
        );
      }
      if (size == 0) return const FileContent();

      final offset = request.offset <= 0 ? 1 : request.offset;
      final limit = request.limit <= 0 ? defaultReadLimit : request.limit;
      final result = BytesBuilder();
      final buffer = Uint8List(_readChunkSize);
      var lineNumber = 1;
      var linesRead = 0;
      var done = false;
      while (!done) {
        ctx.cancelToken.throwIfCancelled();
        final int count;
        try {
          count = await file.readInto(buffer);
        } on FileSystemException catch (error) {
          throw ThreepioException(
            'error reading file: ${_pathError('read', path, error)}',
            cause: error,
          );
        }
        if (count == 0) break;
        var lineStart = 0;
        for (var i = 0; i < count; i++) {
          if (buffer[i] != 0x0A) continue;
          if (lineNumber >= offset) {
            result.add(Uint8List.sublistView(buffer, lineStart, i + 1));
            linesRead++;
            if (linesRead >= limit) {
              done = true;
              break;
            }
          }
          lineNumber++;
          lineStart = i + 1;
        }
        // The start of a line that goes on in the next chunk (or is the
        // last line, without a line break).
        if (!done && lineStart < count && lineNumber >= offset) {
          result.add(Uint8List.sublistView(buffer, lineStart, count));
        }
      }
      final text = _decode(result.takeBytes());
      return FileContent(
        text.endsWith('\n') ? text.substring(0, text.length - 1) : text,
      );
    } finally {
      await file.close();
    }
  }

  /// A file as text, or an image or PDF as parts. Port of
  /// `Local.MultiModalRead`.
  ///
  /// By the extension (any case): `.jpg`, `.jpeg`, `.png`, `.gif`, `.bmp`,
  /// `.webp`, `.tiff`, `.tif` are images — the content must start with the
  /// signature of one of these formats, which gives the part's MIME type —
  /// and `.pdf` is a PDF, which must start with `%PDF-`; any other file is
  /// read as [read] reads it. The sizes are limited by
  /// [multiModalReadConfig].
  ///
  /// A PDF read without [MultiModalReadRequest.pages] is one part with the
  /// whole file. With pages, Go renders each page to a PNG image with
  /// PDFium; this port checks the pages, the size and the signature as Go
  /// does and then fails, because it has no PDF renderer (`paged PDF
  /// reading is not supported: …`).
  @override
  Future<MultiFileContent> multiModalRead(
    RunContext ctx,
    MultiModalReadRequest request,
  ) async {
    final path = goClean(request.filePath);
    final extension = goExt(path).toLowerCase();
    final isImage = _imageExtensions.contains(extension);
    if (!isImage && extension != '.pdf') {
      return MultiFileContent(fileContent: await read(ctx, request));
    }
    final config = multiModalReadConfig;

    if (isImage) {
      final maxMB = config.maxImageSizeMB!;
      final Uint8List data;
      try {
        data = await readAllBytes(ctx, path, maxMB * _mb);
      } on ReadAllBytesTooLargeException catch (error) {
        throw ThreepioException(
          '${error.message}; image size limit is ${maxMB}MB, please compress '
          'or downsample the image before reading',
          cause: error,
        );
      } on CancelledException {
        rethrow;
      } on ThreepioException catch (error) {
        throw ThreepioException(
          'failed to read file bytes: ${error.message}',
          cause: error,
        );
      }
      final mimeType = detectImageMime(data);
      if (mimeType.isEmpty) {
        throw ThreepioException(
          'file $path has image extension but content is not a recognized '
          'image format',
        );
      }
      return MultiFileContent(
        parts: [
          FileContentPart(
            type: FileContentPartType.image,
            mimeType: mimeType,
            data: data,
          ),
        ],
      );
    }

    // A PDF: the checks that need no PDF renderer come first, as in Go.
    final paged = request.pages.isNotEmpty;
    if (paged) parsePagesParam(request.pages, config.maxPdfPagesPerRequest!);
    final maxPdfMB = config.maxPdfSizeMB!;
    final maxPagedMB = config.maxPagedPdfSizeMB!;
    final Uint8List data;
    try {
      data = await readAllBytes(ctx, path, (paged ? maxPagedMB : maxPdfMB) * _mb);
    } on ReadAllBytesTooLargeException catch (error) {
      throw ThreepioException(
        paged
            ? '${error.message}; paged PDF size limit is ${maxPagedMB}MB, the '
                'file is too large even for paged reading'
            : '${error.message}; PDF full-read size limit is ${maxPdfMB}MB, '
                "use the 'pages' parameter to read page ranges (limit raised "
                'to ${maxPagedMB}MB)',
        cause: error,
      );
    } on CancelledException {
      rethrow;
    } on ThreepioException catch (error) {
      throw ThreepioException(
        'failed to read file bytes: ${error.message}',
        cause: error,
      );
    }
    if (!isPdfBytes(data)) {
      throw ThreepioException(
        'file $path has .pdf extension but content is not a valid PDF',
      );
    }
    if (!paged) {
      return MultiFileContent(
        parts: [
          FileContentPart(
            type: FileContentPartType.pdf,
            mimeType: 'application/pdf',
            data: data,
          ),
        ],
      );
    }
    throw ThreepioException(
      'paged PDF reading is not supported: rendering the pages of $path to '
      'images needs PDFium, which this Dart port does not include; read the '
      "whole PDF without the 'pages' parameter",
    );
  }

  /// The whole file at [path], refused when it is larger than [maxBytes].
  /// Port of `Local.readAllBytes`.
  ///
  /// Throws [ReadAllBytesTooLargeException] for a file that is too large
  /// (checked before it is read and again after), and [ThreepioException]
  /// with Go's text otherwise (`file not found: …`, `permission denied: …`,
  /// `path is a directory, not a file: …`).
  @visibleForTesting
  Future<Uint8List> readAllBytes(
    RunContext ctx,
    String path,
    int maxBytes,
  ) async {
    ctx.cancelToken.throwIfCancelled();
    final (type, typeError) = await _typeOf(path);
    if (type == FileSystemEntityType.notFound) {
      final error = typeError ?? await _openError(path);
      if (error == null || error is PathNotFoundException) {
        throw ThreepioException('file not found: $path', cause: error);
      }
      if (error is PathAccessException) {
        throw ThreepioException('permission denied: $path', cause: error);
      }
      throw ThreepioException(
        'failed to stat file: ${_pathError('stat', path, error)}',
        cause: error,
      );
    }
    if (type == FileSystemEntityType.directory) {
      throw ThreepioException('path is a directory, not a file: $path');
    }
    final int size;
    try {
      size = await File(path).length();
    } on FileSystemException catch (error) {
      throw ThreepioException(
        'failed to stat file: ${_pathError('stat', path, error)}',
        cause: error,
      );
    }
    if (size > maxBytes) {
      throw ReadAllBytesTooLargeException(path, size, maxBytes);
    }

    final Uint8List data;
    try {
      data = await File(path).readAsBytes();
    } on FileSystemException catch (error) {
      throw ThreepioException(
        'failed to read file: ${_pathError('open', path, error)}',
        cause: error,
      );
    }
    // The file may have grown since it was measured.
    if (data.length > maxBytes) {
      throw ReadAllBytesTooLargeException(path, data.length, maxBytes);
    }
    return data;
  }

  /// The lines of files that match a regular expression. Port of
  /// `Local.GrepRaw`.
  ///
  /// Go runs ripgrep (`rg --json`) and returns its `match` and `context`
  /// lines; this port searches in the process with a Dart [RegExp] and
  /// follows ripgrep's rules (checked against ripgrep 14):
  ///
  /// * The pattern is required (`pattern is required`). It is a Dart
  ///   regular expression with ripgrep's adjustments (a leading `(?i)`,
  ///   `(?m)`, `(?s)` flag group is understood; without `s` a `.` does not
  ///   match a line break); [GrepRequest.caseInsensitive] is `-i`. Without
  ///   [GrepRequest.enableMultiline] a pattern that is a line break
  ///   (`a\nb`, `[\n]`) fails, as in ripgrep.
  /// * The path is cleaned; empty is `.`. A directory is searched
  ///   recursively, each directory's entries in name order (ripgrep's
  ///   `--sort path` order; Go runs ripgrep in parallel, which gives no
  ///   order across files). Symbolic links are not followed, only regular
  ///   files are searched, and hidden entries (names starting with `.`) are
  ///   skipped unless the glob or the type selects them. Ignore files
  ///   (`.gitignore`, `.ignore`, `.rgignore`) are **not** read.
  /// * Binary files, by ripgrep's NUL-byte rule: a file found by walking is
  ///   read in 64 KiB fills and searched up to the fill that holds its first
  ///   NUL byte (one with a NUL in its first fill gives nothing); in
  ///   multiline search such a file is skipped when its first 64 KiB hold a
  ///   NUL. A path that is a file is always searched, whole; on macOS its
  ///   NUL bytes count as line breaks (ripgrep reads it and converts them;
  ///   on Linux it maps the file and keeps them).
  /// * [GrepRequest.fileType] keeps the files of that type, by extension
  ///   as `InMemoryBackend` knows them (ripgrep's `--type`; an unknown type
  ///   is taken as an extension, where ripgrep fails). When it is empty,
  ///   [GrepRequest.glob] keeps the files it matches as ripgrep's `--glob`
  ///   does (gitignore rules: without a `/` it matches the file name at any
  ///   depth; with one it matches the path relative to the process's working
  ///   directory, so with a searched path outside it — an absolute path, as
  ///   agents pass — it matches nothing, as in Go; a leading `!` excludes
  ///   instead). When both are given, the type filters the search and the
  ///   glob then filters the results by path or file name with eino's
  ///   (doublestar) glob rules, as Go does.
  /// * Each match is a [GrepMatch] with the path as ripgrep prints it (the
  ///   searched path joined with the file's relative path: `./a.txt` for
  ///   `.`), the line number from 1 and the line without its line break; a
  ///   line that is not valid UTF-8 has an empty content (ripgrep sends its
  ///   bytes, which Go does not read). [GrepRequest.beforeLines] and
  ///   [GrepRequest.afterLines] add context lines (each line once, in line
  ///   order).
  /// * [GrepRequest.enableMultiline] is ripgrep's `-U --multiline-dotall`:
  ///   `.` matches line breaks and `^`/`$` match at them. When the pattern
  ///   can match or look at a line break (`.`, `\s`, `\n`, `\W`, `\D`, a
  ///   negated class, `^`, `$`, …) it runs over the whole file, and the lines
  ///   of matches that touch or follow each other are one [GrepMatch]
  ///   numbered by its first line, whose content is its lines joined by
  ///   `\n`; otherwise the search goes line by line, as ripgrep's does.
  ///
  /// What ripgrep reports as a failure (exit code 2) is a [ThreepioException]
  /// `ripgrep failed with exit code 2: rg: …` as in Go: a path that does
  /// not exist, a glob or pattern that does not compile (the glob is
  /// checked first), a file or directory that cannot be read (the other
  /// files' matches are dropped, as Go drops ripgrep's output then). No
  /// match is an empty list.
  @override
  Future<List<GrepMatch>> grepRaw(RunContext ctx, GrepRequest request) async {
    if (request.pattern.isEmpty) {
      throw const ThreepioException('pattern is required');
    }
    final root = goClean(request.path);

    // ripgrep reports a bad glob before a bad pattern.
    _RgGlob? glob;
    if (request.fileType.isEmpty && request.glob.isNotEmpty) {
      try {
        glob = _RgGlob(request.glob);
      } on ThreepioException catch (error) {
        throw _ripgrepFailure(
          "rg: error parsing glob '${request.glob}': ${_formatMessage(error)}\n",
          error,
        );
      }
    }

    final RegExp regExp;
    try {
      regExp = request.enableMultiline
          ? compileGrepPattern(
              _withMultiLineFlag(request.pattern),
              caseInsensitive: request.caseInsensitive,
              dotAll: true,
            )
          : compileGrepPattern(
              request.pattern,
              caseInsensitive: request.caseInsensitive,
            );
    } on ThreepioException catch (error) {
      throw _ripgrepFailure(
        'rg: regex parse error:\n    ${request.pattern}\nerror: '
        '${_formatMessage(error)}\n',
        error,
      );
    }
    final newlines = _newlineUse(request.pattern);
    if (!request.enableMultiline && newlines.literal) {
      throw _ripgrepFailure(
        'rg: the literal "${_backslash}n" is not allowed in a regex\n\n'
        'Consider enabling multiline mode with the --multiline flag (or -U '
        'for short).\nWhen multiline mode is enabled, new line characters can '
        'be matched.\n',
        null,
      );
    }

    // Go filters ripgrep's results by the glob only when a type is given too
    // (ripgrep then gets the type alone). A bad glob matches nothing there.
    GlobMatcher? resultGlob;
    var resultGlobValid = true;
    if (request.fileType.isNotEmpty && request.glob.isNotEmpty) {
      try {
        resultGlob = GlobMatcher(request.glob);
      } on ThreepioException {
        resultGlobValid = false;
      }
    }

    final search = _RgSearch(
      ctx,
      request,
      regExp,
      glob,
      (path) {
        if (request.fileType.isEmpty || request.glob.isEmpty) return true;
        final matcher = resultGlob;
        if (!resultGlobValid || matcher == null) return false;
        return matcher.matches(path) || matcher.matches(_paths.basename(path));
      },
      multiline: request.enableMultiline && newlines.canMatch,
    );
    await search.run(root);
    if (search.errors.isNotEmpty) {
      throw _ripgrepFailure(search.errors.toString(), null);
    }
    return search.matches;
  }

  /// The files and directories under a directory whose relative path
  /// matches a glob. Port of `Local.GlobInfo`.
  ///
  /// The search starts at [GlobInfoRequest.path] (cleaned; `/` when it is
  /// empty, so an empty path searches the whole machine, as in Go) and
  /// does not follow symbolic links (a path that is one finds nothing). The
  /// pattern has eino's (doublestar) syntax and is matched against each
  /// entry's path relative to the start, with `/` between names: `*` stays
  /// within a name, `**` crosses directories, and an absolute pattern
  /// matches nothing. Directories match as well as files (`src/**` matches
  /// `src` and everything in it). A pattern that does not compile matches
  /// nothing, as in Go. Directories that cannot be read are skipped. The
  /// result is sorted and carries only [FileInfo.path].
  @override
  Future<List<FileInfo>> globInfo(
    RunContext ctx,
    GlobInfoRequest request,
  ) async {
    final root = goClean(request.path.isEmpty ? '/' : request.path);
    GlobMatcher? matcher;
    try {
      matcher = GlobMatcher(request.pattern);
    } on ThreepioException {
      matcher = null;
    }

    final (type, typeError) = await _typeOf(root, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      final error = typeError ?? await _listError(root);
      if (error is PathAccessException) return [];
      throw ThreepioException(
        'failed to walk directory: lstat $root: '
        '${error == null ? 'no such file or directory' : _errnoText(error)}',
        cause: error,
      );
    }
    final matches = <String>[];
    if (type == FileSystemEntityType.directory) {
      await _walkForGlob(ctx, root, '', matcher, matches);
    }
    matches.sort(_compareCodePoints);
    return [for (final match in matches) FileInfo(path: match)];
  }

  Future<void> _walkForGlob(
    RunContext ctx,
    String directory,
    String relative,
    GlobMatcher? matcher,
    List<String> matches,
  ) async {
    ctx.cancelToken.throwIfCancelled();
    final entries = <FileSystemEntity>[];
    try {
      await for (final entity in Directory(directory).list(followLinks: false)) {
        entries.add(entity);
      }
    } on FileSystemException catch (error) {
      // Go skips a directory it may not read (filepath.SkipDir).
      if (error is PathAccessException) return;
      throw ThreepioException(
        'failed to walk directory: ${_pathError('open', directory, error)}',
        cause: error,
      );
    }
    for (final entity in entries) {
      final name = _paths.basename(entity.path);
      final path = relative.isEmpty ? name : '$relative/$name';
      if (matcher != null && matcher.matches(path)) matches.add(path);
      if (entity is Directory) {
        await _walkForGlob(ctx, entity.path, path, matcher, matches);
      }
    }
  }

  /// Creates a file, and its parent directories, or replaces its content.
  /// Port of `Local.Write`.
  @override
  Future<void> write(RunContext ctx, WriteRequest request) async {
    final path = goClean(request.filePath);
    final parent = goDir(path);
    try {
      await Directory(parent).create(recursive: true);
    } on FileSystemException catch (error) {
      // Dart meets a file in the way as "file exists"; Go's MkdirAll
      // reports it as "not a directory".
      final text = error is PathExistsException
          ? 'mkdir ${error.path ?? parent}: not a directory'
          : _pathError('mkdir', error.path ?? parent, error);
      throw ThreepioException(
        'failed to create parent directory: $text',
        cause: error,
      );
    }

    final RandomAccessFile file;
    try {
      // Go opens with O_WRONLY|O_CREATE|O_TRUNC: a write-only file works.
      file = await File(path).open(mode: FileMode.writeOnly);
    } on FileSystemException catch (error) {
      throw ThreepioException(
        'failed to open file for writing: ${_pathError('open', path, error)}',
        cause: error,
      );
    }
    try {
      await file.writeFrom(utf8.encode(request.content));
    } on FileSystemException catch (error) {
      throw ThreepioException(
        'failed to write to file: ${_pathError('write', path, error)}',
        cause: error,
      );
    } finally {
      await file.close();
    }
  }

  /// Replaces text in a file. Port of `Local.Edit`.
  ///
  /// The old text must not be empty (`old string is required`) and must
  /// differ from the new one; it must occur in the file (`string not found
  /// in file: '<old>'`), and exactly once unless [EditRequest.replaceAll]
  /// (`string '<old>' appears multiple times. Use replace_all=True to
  /// replace all occurrences`). Occurrences are counted and replaced from
  /// the start without overlapping, on the file's bytes.
  @override
  Future<void> edit(RunContext ctx, EditRequest request) async {
    final path = goClean(request.filePath);
    final oldString = request.oldString;
    if (oldString.isEmpty) {
      throw const ThreepioException('old string is required');
    }
    if (oldString == request.newString) {
      throw const ThreepioException(
        'new string must be different from old string',
      );
    }

    final Uint8List content;
    try {
      content = await File(path).readAsBytes();
    } on FileSystemException catch (error) {
      final op = _errno(error) == _eisdir ? 'read' : 'open';
      throw ThreepioException(
        'failed to read file: ${_pathError(op, path, error)}',
        cause: error,
      );
    }

    final old = utf8.encode(oldString);
    final positions = _occurrences(content, old, limit: request.replaceAll ? null : 2);
    if (positions.isEmpty) {
      throw ThreepioException("string not found in file: '$oldString'");
    }
    if (positions.length > 1 && !request.replaceAll) {
      throw ThreepioException(
        "string '$oldString' appears multiple times. Use replace_all=True to "
        'replace all occurrences',
      );
    }

    final replacement = utf8.encode(request.newString);
    final updated = BytesBuilder(copy: false);
    var from = 0;
    for (final position in positions) {
      updated
        ..add(Uint8List.sublistView(content, from, position))
        ..add(replacement);
      from = position + old.length;
    }
    updated.add(Uint8List.sublistView(content, from));

    try {
      await File(path)
          .writeAsBytes(updated.takeBytes(), mode: FileMode.writeOnly);
    } on FileSystemException catch (error) {
      // Go returns os.WriteFile's error as it is.
      throw ThreepioException(_pathError('open', path, error), cause: error);
    }
  }

  /// Runs a command with `/bin/sh` and returns its output. Port of
  /// `Local.Execute`; see [LocalShell.execute].
  @override
  Future<ExecuteResponse> execute(RunContext ctx, ExecuteRequest request) =>
      _shell.execute(ctx, request);

  /// Runs a command with `/bin/sh` and streams its output. Port of
  /// `Local.ExecuteStreaming`; see [LocalShell.executeStreaming].
  @override
  Future<StreamReader<ExecuteResponse>> executeStreaming(
    RunContext ctx,
    ExecuteRequest request,
  ) =>
      _shell.executeStreaming(ctx, request);
}

/// The start and end page (from 1, inclusive) of a PDF read's `pages`.
/// Port of `parsePagesParam`.
///
/// `'3'` is page 3 and `'1-5'` pages 1 to 5 (spaces around the numbers are
/// allowed); an empty value, an open range (`'1-'`), several ranges
/// (`'1-2-3'`), a number below 1, an end before the start and a range of
/// more than [maxPages] pages (the default of 20 when it is 0 or less) are
/// refused with `invalid pages parameter: "<pages>" (…)`.
@visibleForTesting
(int start, int end) parsePagesParam(String pages, int maxPages) {
  final limit = maxPages <= 0
      ? LocalMultiModalReadConfig.defaultMaxPdfPagesPerRequest
      : maxPages;
  final quoted = _goQuote(pages);
  ThreepioException invalid(String why) =>
      ThreepioException('invalid pages parameter: $quoted ($why)');

  final trimmed = _goTrimSpace(pages);
  if (trimmed.isEmpty) throw invalid('empty');
  if ('-'.allMatches(trimmed).length > 1) {
    throw invalid('only a single range is supported, e.g. "1-5"');
  }
  final dash = trimmed.indexOf('-');
  final startText =
      _goTrimSpace(dash < 0 ? trimmed : trimmed.substring(0, dash));
  final endText =
      dash < 0 ? null : _goTrimSpace(trimmed.substring(dash + 1));
  if (endText != null && endText.isEmpty) {
    throw invalid('open-ended range is not supported, end page is required');
  }

  final start = _atoi(startText);
  if (start == null || start < 1) {
    throw invalid('start page must be a positive integer');
  }
  if (endText == null) return (start, start);
  final end = _atoi(endText);
  if (end == null || end < 1) {
    throw invalid('end page must be a positive integer');
  }
  if (end < start) throw invalid('end page $end < start page $start');
  if (end - start + 1 > limit) {
    throw invalid('range spans ${end - start + 1} pages, exceeds limit $limit');
  }
  return (start, end);
}

/// The MIME type of an image, by the signature its bytes start with
/// (PNG, JPEG, GIF, BMP, WebP, TIFF), or `''`. Port of `detectImageMIME`.
@visibleForTesting
String detectImageMime(List<int> data) {
  bool startsWith(List<int> signature, [int at = 0]) {
    if (data.length < at + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (data[at + i] != signature[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(ascii.encode('GIF87a')) || startsWith(ascii.encode('GIF89a'))) {
    return 'image/gif';
  }
  if (startsWith(ascii.encode('BM'))) return 'image/bmp';
  if (data.length >= 12 &&
      startsWith(ascii.encode('RIFF')) &&
      startsWith(ascii.encode('WEBP'), 8)) {
    return 'image/webp';
  }
  if (startsWith(const [0x49, 0x49, 0x2A, 0x00]) ||
      startsWith(const [0x4D, 0x4D, 0x00, 0x2A])) {
    return 'image/tiff';
  }
  return '';
}

/// Whether [data] starts with the PDF signature `%PDF-`. Port of
/// `isPDFBytes`.
@visibleForTesting
bool isPdfBytes(List<int> data) {
  const signature = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-
  if (data.length < signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (data[i] != signature[i]) return false;
  }
  return true;
}

/// One search of [LocalFilesystemBackend.grepRaw], with ripgrep's rules.
final class _RgSearch {
  _RgSearch(
    this.ctx,
    this.request,
    this.regExp,
    this.glob,
    this.keepPath, {
    required this.multiline,
  });

  final RunContext ctx;
  final GrepRequest request;
  final RegExp regExp;

  /// The `--glob` filter, when the request has a glob and no type.
  final _RgGlob? glob;

  /// Go's filter of ripgrep's results (a type and a glob given).
  final bool Function(String path) keepPath;

  /// Whether the pattern runs over whole files (ripgrep's `MultiLine`
  /// search) rather than line by line.
  final bool multiline;

  /// The root of ripgrep's `--glob` matching: the working directory.
  final String _cwd = Directory.current.path;

  final List<GrepMatch> matches = [];

  /// What ripgrep would write to its standard error.
  final StringBuffer errors = StringBuffer();

  Future<void> run(String root) async {
    final (type, typeError) = await _typeOf(root);
    switch (type) {
      case FileSystemEntityType.notFound:
        // ripgrep's directory walker reports a root it cannot look up.
        final error = typeError ?? await _openError(root);
        final os = error?.osError;
        errors.write(
          'rg: $root: IO error for operation on $root: '
          '${os == null ? 'No such file or directory (os error 2)' : '${os.message} (os error ${os.errorCode})'}\n',
        );
      case FileSystemEntityType.directory:
        await _walk(root, root);
      default:
        // A path given explicitly is searched whatever the filters say.
        await _searchFile(root, root, explicit: true);
    }
  }

  Future<void> _walk(String directory, String display) async {
    ctx.cancelToken.throwIfCancelled();
    final entries = <FileSystemEntity>[];
    try {
      await for (final entity in Directory(directory).list(followLinks: false)) {
        entries.add(entity);
      }
    } on FileSystemException catch (error) {
      errors.write(_rgIoError(display, error));
      return;
    }
    entries.sort(
      (a, b) => _compareCodePoints(
        _paths.basename(a.path),
        _paths.basename(b.path),
      ),
    );
    for (final entity in entries) {
      if (entity is Link) continue; // not followed, never searched
      final name = _paths.basename(entity.path);
      final shown = display == '/' ? '/$name' : '$display/$name';
      final isDirectory = entity is Directory;
      if (!_included(name, shown, isDirectory: isDirectory)) continue;
      if (isDirectory) {
        await _walk(entity.path, shown);
      } else if ((await entity.stat()).type == FileSystemEntityType.file) {
        await _searchFile(entity.path, shown, explicit: false);
      }
    }
  }

  /// ripgrep's ignore decision for an entry found by walking: the glob (or
  /// the type), then hidden names.
  bool _included(String name, String shown, {required bool isDirectory}) {
    var decision = _RgDecision.none;
    final glob = this.glob;
    if (glob != null) {
      decision = glob.decide(name, _globPath(shown), isDirectory: isDirectory);
    } else if (request.fileType.isNotEmpty && !isDirectory) {
      final extension = goExt(name);
      decision = matchFileType(
        extension.isEmpty ? '' : extension.substring(1),
        request.fileType,
      )
          ? _RgDecision.whitelist
          : _RgDecision.ignore;
    }
    if (decision == _RgDecision.ignore) return false;
    if (decision == _RgDecision.none && name.startsWith('.')) return false;
    return true;
  }

  /// The path ripgrep matches a `--glob` against: the printed path without
  /// a leading `./` and, when it has a directory, without the working
  /// directory in front (the root of ripgrep's override globs).
  String _globPath(String shown) {
    var path = shown.startsWith('./') ? shown.substring(2) : shown;
    if (!path.contains('/')) return path;
    if (_cwd == '/') {
      if (path.startsWith('/')) path = path.substring(1);
    } else if (path.startsWith('$_cwd/')) {
      path = path.substring(_cwd.length + 1);
    }
    return path;
  }

  Future<void> _searchFile(
    String file,
    String display, {
    required bool explicit,
  }) async {
    ctx.cancelToken.throwIfCancelled();
    if (!keepPath(display)) return;
    Uint8List bytes;
    try {
      bytes = await File(file).readAsBytes();
    } on FileSystemException catch (error) {
      errors.write(_rgIoError(display, error));
      return;
    }
    if (explicit) {
      // ripgrep converts the NUL bytes of a file it was given when it reads
      // it line by line (macOS); on Linux it maps the file and keeps them.
      if (!multiline && Platform.isMacOS) bytes = _nulsAsLineBreaks(bytes);
    } else if (multiline) {
      // ripgrep skips the file when its first buffer holds a NUL byte.
      final nul = bytes.indexOf(0);
      if (nul >= 0 && nul < _rgBufferSize) return;
    } else {
      bytes = Uint8List.sublistView(bytes, 0, _lineSearchEnd(bytes));
    }
    if (bytes.isEmpty) return;
    matches.addAll(_matchesIn(display, bytes));
  }

  List<GrepMatch> _matchesIn(String display, Uint8List bytes) {
    String content;
    Set<int>? invalidLines;
    try {
      content = utf8.decode(bytes);
    } on FormatException {
      content = _decode(bytes);
      invalidLines = _invalidUtf8Lines(bytes);
    }
    final lines = content.split('\n');
    if (lines.last.isEmpty) lines.removeLast(); // after the last line break
    final blocks = <_Block>[];
    if (multiline) {
      blocks.addAll(_multilineBlocks(content));
    } else {
      for (var i = 0; i < lines.length; i++) {
        if (regExp.hasMatch(lines[i])) blocks.add(_Block(i + 1, i + 1, lines[i]));
      }
    }
    if (blocks.isEmpty) return const [];

    // ripgrep sends a line that is not UTF-8 as bytes, which Go reads as an
    // empty text.
    String textOf(int first, int last, String text) {
      final invalid = invalidLines;
      if (invalid == null) return text;
      for (var line = first; line <= last; line++) {
        if (invalid.contains(line)) return '';
      }
      return text;
    }

    final before = math.max(0, request.beforeLines);
    final after = math.max(0, request.afterLines);
    final entries = <(int, GrepMatch)>[
      for (final block in blocks)
        (
          block.first,
          GrepMatch(
            path: display,
            line: block.first,
            content: textOf(block.first, block.last, block.text),
          ),
        ),
    ];
    if (before > 0 || after > 0) {
      final covered = <int>{
        for (final block in blocks)
          for (var line = block.first; line <= block.last; line++) line,
      };
      final context = <int>{};
      for (final block in blocks) {
        for (var line = math.max(1, block.first - before); line < block.first; line++) {
          if (!covered.contains(line)) context.add(line);
        }
        final last = math.min(lines.length, block.last + after);
        for (var line = block.last + 1; line <= last; line++) {
          if (!covered.contains(line)) context.add(line);
        }
      }
      for (final line in context) {
        entries.add(
          (
            line,
            GrepMatch(
              path: display,
              line: line,
              content: textOf(line, line, lines[line - 1]),
            ),
          ),
        );
      }
      entries.sort((a, b) => a.$1.compareTo(b.$1));
    }
    return [for (final (_, match) in entries) match];
  }

  /// ripgrep's multiline matching: each match grows to whole lines, and the
  /// lines of a match that starts on or right after the last line of the
  /// one before join that one's block. As in ripgrep's search, which starts
  /// again after each match, an empty match right after a match counts.
  List<_Block> _multilineBlocks(String content) {
    final blocks = <_Block>[];
    var countedTo = 0;
    var lineNumber = 1;
    int lineAt(int offset) {
      for (var i = countedTo; i < offset; i++) {
        if (content.codeUnitAt(i) == 0x0A) lineNumber++;
      }
      countedTo = offset;
      return lineNumber;
    }

    void addBlock(int start, int end) {
      final first = lineAt(start);
      final text = content.substring(start, end);
      var breaks = '\n'.allMatches(text).length;
      if (text.endsWith('\n')) breaks--;
      blocks.add(_Block(first, first + breaks, _trimTrailingNewlines(text)));
    }

    int? blockStart;
    var blockEnd = 0;
    for (final match in regExp.allMatches(content)) {
      final lineStart = match.start == 0
          ? 0
          : content.lastIndexOf('\n', match.start - 1) + 1;
      final int lineEnd;
      if (match.end > lineStart && content.codeUnitAt(match.end - 1) == 0x0A) {
        lineEnd = match.end;
      } else {
        final newline = content.indexOf('\n', match.end);
        lineEnd = newline < 0 ? content.length : newline + 1;
      }
      // An empty match after the last line break: ripgrep stops there.
      if (lineStart == lineEnd) break;
      final start = blockStart;
      if (start != null && blockEnd >= lineStart) {
        blockEnd = math.max(blockEnd, lineEnd);
      } else {
        if (start != null) addBlock(start, blockEnd);
        blockStart = lineStart;
        blockEnd = lineEnd;
      }
    }
    final start = blockStart;
    if (start != null) addBlock(start, blockEnd);
    return blocks;
  }
}

/// The lines [first] to [last] that a match covers, and their text.
final class _Block {
  _Block(this.first, this.last, this.text);

  final int first;
  final int last;
  final String text;
}

enum _RgDecision { none, whitelist, ignore }

/// A `--glob` of ripgrep: gitignore rules on eino's glob syntax.
final class _RgGlob {
  factory _RgGlob(String glob) {
    var pattern = glob;
    final negated = pattern.startsWith('!');
    if (negated) pattern = pattern.substring(1);
    final directoryOnly = pattern.endsWith('/');
    if (directoryOnly) pattern = pattern.substring(0, pattern.length - 1);
    var anchored = pattern.startsWith('/');
    if (anchored) pattern = pattern.substring(1);
    anchored = anchored || pattern.contains('/');
    return _RgGlob._(
      GlobMatcher(pattern),
      negated: negated,
      directoryOnly: directoryOnly,
      anchored: anchored,
    );
  }

  _RgGlob._(
    this._matcher, {
    required bool negated,
    required bool directoryOnly,
    required bool anchored,
  })  : _negated = negated,
        _directoryOnly = directoryOnly,
        _anchored = anchored;

  final GlobMatcher _matcher;
  final bool _negated;
  final bool _directoryOnly;

  /// Whether the glob has a `/`: it is then matched against the relative
  /// path, otherwise against the name.
  final bool _anchored;

  /// An override of ripgrep: a match whitelists (or, negated, ignores) the
  /// entry; a file that does not match a whitelist is ignored; anything
  /// else is left to the other rules.
  _RgDecision decide(String name, String path, {required bool isDirectory}) {
    final matched = (!_directoryOnly || isDirectory) &&
        _matcher.matches(_anchored ? path : name);
    if (matched) return _negated ? _RgDecision.ignore : _RgDecision.whitelist;
    return !_negated && !isDirectory ? _RgDecision.ignore : _RgDecision.none;
  }
}

/// POSIX paths, resolved against the root whatever the process's directory.
final p.Context _paths = p.Context(style: p.Style.posix, current: '/');

const int _mb = 1024 * 1024;
const int _readChunkSize = 64 * 1024;

/// The size of ripgrep's first read buffer (`DEFAULT_BUFFER_CAPACITY`).
const int _rgBufferSize = 64 * 1024;

/// A backslash, for texts that show one before a letter.
final String _backslash = String.fromCharCode(0x5C);

/// POSIX error numbers (the same on Linux and macOS).
const int _enotdir = 20;
const int _eisdir = 21;

/// The operation Go names when listing a path that is not a directory.
final String _readDirOp = Platform.isMacOS ? 'fdopendir' : 'readdirent';

const Set<String> _imageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.bmp',
  '.webp',
  '.tiff',
  '.tif',
};

int? _errno(FileSystemException error) => error.osError?.errorCode;

/// The text Go gives an OS error: the C library's, starting in lower case.
String _errnoText(FileSystemException error) {
  final message = error.osError?.message ?? '';
  if (message.isEmpty) return error.message;
  return '${message[0].toLowerCase()}${message.substring(1)}';
}

/// Go's `*fs.PathError` text: `<op> <path>: <error>`.
String _pathError(String op, String path, FileSystemException error) =>
    '$op $path: ${_errnoText(error)}';

/// How ripgrep reports an I/O error: `rg: <path>: <error> (os error <n>)`.
String _rgIoError(String path, FileSystemException error) {
  final os = error.osError;
  if (os == null) return 'rg: $path: ${error.message}\n';
  return 'rg: $path: ${os.message} (os error ${os.errorCode})\n';
}

ThreepioException _ripgrepFailure(String stderr, Object? cause) =>
    ThreepioException('ripgrep failed with exit code 2: $stderr', cause: cause);

/// The message of the format error behind [error], or its own.
String _formatMessage(ThreepioException error) {
  final cause = error.cause;
  return cause is FormatException ? cause.message : error.message;
}

/// The type of the entry at [path]; `notFound` with the error when looking
/// it up failed for another reason than its absence.
Future<(FileSystemEntityType, FileSystemException?)> _typeOf(
  String path, {
  bool followLinks = true,
}) async {
  try {
    return (await FileSystemEntity.type(path, followLinks: followLinks), null);
  } on FileSystemException catch (error) {
    return (FileSystemEntityType.notFound, error);
  }
}

/// Why [path] cannot be opened, or `null` when it can.
Future<FileSystemException?> _openError(String path) async {
  try {
    final file = await File(path).open();
    await file.close();
    return null;
  } on FileSystemException catch (error) {
    return error;
  }
}

/// Why [path] cannot be listed (which tells why it cannot be looked up), or
/// `null` when it can.
Future<FileSystemException?> _listError(String path) async {
  try {
    await Directory(path).list().isEmpty;
    return null;
  } on FileSystemException catch (error) {
    return error;
  }
}

/// [pattern] with ripgrep's multi-line flag (`^`, `$` at line breaks)
/// added to its leading flag group.
String _withMultiLineFlag(String pattern) {
  final flags = RegExp(r'^\(\?([imsU]+)\)').firstMatch(pattern);
  if (flags == null) return '(?m)$pattern';
  return '(?${flags.group(1)}m)${pattern.substring(flags.end)}';
}

String _trimTrailingNewlines(String text) {
  var end = text.length;
  while (end > 0 && text.codeUnitAt(end - 1) == 0x0A) {
    end--;
  }
  return text.substring(0, end);
}

String _decode(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

/// Orders strings by code point, which is the order of their UTF-8 bytes
/// (Go's string order).
int _compareCodePoints(String a, String b) {
  final left = a.runes.iterator;
  final right = b.runes.iterator;
  while (true) {
    final hasLeft = left.moveNext();
    final hasRight = right.moveNext();
    if (!hasLeft) return hasRight ? -1 : 0;
    if (!hasRight) return 1;
    final difference = left.current - right.current;
    if (difference != 0) return difference;
  }
}

/// The positions of [needle] in [haystack], from the start and without
/// overlapping (Go `strings.Count`/`strings.Replace`), at most [limit].
List<int> _occurrences(Uint8List haystack, List<int> needle, {int? limit}) {
  final positions = <int>[];
  final last = haystack.length - needle.length;
  var i = 0;
  while (i <= last) {
    var found = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        found = false;
        break;
      }
    }
    if (found) {
      positions.add(i);
      if (limit != null && positions.length >= limit) break;
      i += needle.length;
    } else {
      i++;
    }
  }
  return positions;
}

/// Go's `strconv.Atoi` for a decimal number with an optional sign.
int? _atoi(String text) {
  if (!RegExp(r'^[+-]?[0-9]+$').hasMatch(text)) return null;
  return int.tryParse(text, radix: 10);
}

/// [value] quoted as Go's `%q` quotes it.
String _goQuote(String value) {
  final buffer = StringBuffer('"');
  for (final rune in value.runes) {
    switch (rune) {
      case 0x22:
        buffer.write(r'\"');
      case 0x5C:
        buffer.write(r'\\');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      case 0x07:
        buffer.write(r'\a');
      case 0x08:
        buffer.write(r'\b');
      case 0x0C:
        buffer.write(r'\f');
      case 0x0B:
        buffer.write(r'\v');
      default:
        if (rune < 0x20 || rune == 0x7F) {
          buffer
            ..write(r'\x')
            ..write(rune.toRadixString(16).padLeft(2, '0'));
        } else if (!_goPrintable(rune)) {
          final wide = rune > 0xFFFF;
          buffer
            ..write(_backslash)
            ..write(wide ? 'U' : 'u')
            ..write(rune.toRadixString(16).padLeft(wide ? 8 : 4, '0'));
        } else {
          buffer.writeCharCode(rune);
        }
    }
  }
  buffer.write('"');
  return buffer.toString();
}


/// Whether Go's `%q` writes [rune] as it is (`unicode.IsPrint`) — for the
/// characters it escapes most often: C1 controls, spaces other than U+0020,
/// line and paragraph separators, format characters, surrogates, private
/// use and non-characters.
bool _goPrintable(int rune) {
  if (rune >= 0x80 && rune <= 0xA0) return false;
  if (rune == 0xAD || rune == 0x1680 || rune == 0x180E) return false;
  if (rune >= 0x0600 && rune <= 0x0605) return false;
  if (rune == 0x061C || rune == 0x06DD || rune == 0x070F) return false;
  if (rune >= 0x2000 && rune <= 0x200F) return false;
  if (rune >= 0x2028 && rune <= 0x202F) return false;
  if (rune >= 0x205F && rune <= 0x206F) return false;
  if (rune == 0x3000 || rune == 0xFEFF) return false;
  if (rune >= 0xD800 && rune <= 0xF8FF) return false;
  if (rune >= 0xFFF9 && rune <= 0xFFFB) return false;
  if (rune == 0xFFFE || rune == 0xFFFF) return false;
  return true;
}

/// [value] without leading and trailing white space as Go's
/// `strings.TrimSpace` sees it (Dart's `trim` also removes U+FEFF).
String _goTrimSpace(String value) {
  bool isSpace(int c) =>
      (c >= 0x09 && c <= 0x0D) ||
      c == 0x20 ||
      c == 0x85 ||
      c == 0xA0 ||
      c == 0x1680 ||
      (c >= 0x2000 && c <= 0x200A) ||
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x202F ||
      c == 0x205F ||
      c == 0x3000;
  var start = 0;
  var end = value.length;
  while (start < end && isSpace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && isSpace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

/// How much of [bytes] ripgrep searches line by line in a file it found by
/// walking: it reads 64 KiB fills (more when a line does not fit), searches
/// each up to its last line break, and stops, without searching it, at the
/// fill that holds the first NUL byte.
int _lineSearchEnd(Uint8List bytes) {
  final nul = bytes.indexOf(0);
  if (nul < 0) return bytes.length;
  var capacity = _rgBufferSize;
  var searched = 0;
  var read = 0;
  while (read < bytes.length) {
    if (read - searched >= capacity) capacity *= 2;
    final end = math.min(bytes.length, searched + capacity);
    if (nul < end) return searched;
    read = end;
    final lastBreak = bytes.lastIndexOf(0x0A, read - 1);
    if (lastBreak >= searched) searched = lastBreak + 1;
  }
  return searched;
}

/// [bytes] with every NUL byte made a line break (ripgrep's conversion of a
/// binary file it was given).
Uint8List _nulsAsLineBreaks(Uint8List bytes) {
  if (!bytes.contains(0)) return bytes;
  return Uint8List.fromList([for (final byte in bytes) byte == 0 ? 0x0A : byte]);
}

/// The numbers of the lines of [bytes] that are not valid UTF-8.
Set<int> _invalidUtf8Lines(Uint8List bytes) {
  final invalid = <int>{};
  var line = 1;
  var start = 0;
  for (var i = 0; i <= bytes.length; i++) {
    if (i < bytes.length && bytes[i] != 0x0A) continue;
    if (i > start) {
      try {
        utf8.decode(Uint8List.sublistView(bytes, start, i));
      } on FormatException {
        invalid.add(line);
      }
    }
    line++;
    start = i + 1;
  }
  return invalid;
}

/// What ripgrep's line-break rules need to know about a pattern: whether it
/// can match or look at a line break (`canMatch`: multiline search then
/// runs over whole files; otherwise ripgrep searches line by line), and
/// whether it holds a line break that ripgrep refuses outside multiline
/// mode (`literal`: `\n`, `\x0A`, a raw line break, a class of line breaks
/// only).
///
/// A scan of the pattern's syntax that errs towards `canMatch`: `.`, `^`,
/// `$`, `\n`, `\s`, `\W`, `\D`, negated classes and properties, and classes
/// holding a line break (also through a range or `[:space:]`) can.
({bool canMatch, bool literal}) _newlineUse(String pattern) {
  var canMatch = false;
  var literal = false;
  var i = 0;
  while (i < pattern.length) {
    final char = pattern.codeUnitAt(i);
    if (char == 0x5C) {
      final escape = _escapeAt(pattern, i);
      if (escape.value == 0x0A) literal = true;
      if (escape.matchesNewline) canMatch = true;
      i = escape.end;
    } else if (char == 0x5B) {
      final range = _classAt(pattern, i);
      if (range.negated != range.hasNewline) canMatch = true;
      if (!range.negated && range.onlyNewline) literal = true;
      i = range.end;
    } else {
      if (char == 0x0A) literal = true;
      // . (multiline search is dot-all), ^, $ and a raw line break.
      if (char == 0x2E || char == 0x5E || char == 0x24 || char == 0x0A) {
        canMatch = true;
      }
      i++;
    }
  }
  if (literal) canMatch = true;
  return (canMatch: canMatch, literal: literal);
}

/// The escape that starts at [start] (a backslash): where it ends, the
/// character it stands for (when it is one) and whether it can match a line
/// break.
({int end, int? value, bool matchesNewline}) _escapeAt(
  String pattern,
  int start,
) {
  final i = start + 1;
  if (i >= pattern.length) return (end: i, value: null, matchesNewline: false);
  final letter = pattern[i];

  ({int end, int? value, bool matchesNewline}) hex(int digits) {
    final from = i + 1;
    int end;
    String text;
    if (from < pattern.length && pattern[from] == '{') {
      final close = pattern.indexOf('}', from);
      end = close < 0 ? pattern.length : close + 1;
      text = pattern.substring(from + 1, close < 0 ? pattern.length : close);
    } else {
      end = math.min(pattern.length, from + digits);
      text = pattern.substring(from, end);
    }
    final value = int.tryParse(text, radix: 16);
    return (end: end, value: value, matchesNewline: value == 0x0A);
  }

  switch (letter) {
    case 'n':
      return (end: i + 1, value: 0x0A, matchesNewline: true);
    case 't':
      return (end: i + 1, value: 0x09, matchesNewline: false);
    case 'r':
      return (end: i + 1, value: 0x0D, matchesNewline: false);
    case 'f':
      return (end: i + 1, value: 0x0C, matchesNewline: false);
    case 'v':
      return (end: i + 1, value: 0x0B, matchesNewline: false);
    case 'a':
      return (end: i + 1, value: 0x07, matchesNewline: false);
    case 's' || 'W' || 'D':
      return (end: i + 1, value: null, matchesNewline: true);
    case 'x':
      return hex(2);
    case 'u':
      return hex(4);
    case 'U':
      return hex(8);
    case 'p' || 'P':
      var end = i + 1;
      var name = '';
      if (end < pattern.length && pattern[end] == '{') {
        final close = pattern.indexOf('}', end);
        name = pattern.substring(end + 1, close < 0 ? pattern.length : close);
        end = close < 0 ? pattern.length : close + 1;
      } else if (end < pattern.length) {
        name = pattern[end];
        end++;
      }
      var negated = letter == 'P';
      if (name.startsWith('^')) {
        negated = !negated;
        name = name.substring(1);
      }
      // A line break is in the categories Cc, C (Other), Any and in
      // White_Space.
      final key = name.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
      final holds = const {
        'cc',
        'c',
        'control',
        'other',
        'any',
        'whitespace',
        'wspace',
        'space',
      }.contains(key);
      return (end: end, value: null, matchesNewline: negated != holds);
  }
  final code = pattern.codeUnitAt(i);
  final isLetter = (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
  // A letter is a class or an assertion without a line break (\w, \d, \S,
  // \b, \A, \z, …); anything else stands for itself (\., \\, \[).
  return (end: i + 1, value: isLetter ? null : code, matchesNewline: false);
}

/// The bracketed class that starts at [start]: where it ends, whether it is
/// negated, whether it holds a line break, and whether it holds nothing
/// else.
({int end, bool negated, bool hasNewline, bool onlyNewline}) _classAt(
  String pattern,
  int start,
) {
  var i = start + 1;
  var negated = false;
  if (i < pattern.length && pattern[i] == '^') {
    negated = true;
    i++;
  }
  var hasNewline = false;
  var onlyNewline = true;
  var members = 0;
  var first = true;

  (int? value, bool holds, int end) member(int at) {
    if (pattern.codeUnitAt(at) == 0x5C) {
      final escape = _escapeAt(pattern, at);
      return (escape.value, escape.matchesNewline, escape.end);
    }
    return (pattern.codeUnitAt(at), false, at + 1);
  }

  while (i < pattern.length) {
    final char = pattern[i];
    if (char == ']' && !first) {
      return (
        end: i + 1,
        negated: negated,
        hasNewline: hasNewline,
        onlyNewline: members > 0 && onlyNewline,
      );
    }
    first = false;
    if (char == '[') {
      if (pattern.startsWith('[:', i)) {
        final close = pattern.indexOf(':]', i + 2);
        if (close >= 0) {
          var name = pattern.substring(i + 2, close);
          final negatedName = name.startsWith('^');
          if (negatedName) name = name.substring(1);
          final holds = const {'space', 'cntrl', 'ascii'}.contains(name);
          if (negatedName != holds) hasNewline = true;
          onlyNewline = false;
          members++;
          i = close + 2;
          continue;
        }
      }
      final nested = _classAt(pattern, i);
      if (nested.negated != nested.hasNewline) hasNewline = true;
      if (nested.negated || !nested.onlyNewline) onlyNewline = false;
      members++;
      i = nested.end;
      continue;
    }
    if ((char == '&' || char == '~') &&
        i + 1 < pattern.length &&
        pattern[i + 1] == char) {
      onlyNewline = false;
      i += 2;
      continue;
    }
    final (low, holds, next) = member(i);
    if (low != null &&
        next + 1 < pattern.length &&
        pattern[next] == '-' &&
        pattern[next + 1] != ']') {
      final (high, _, end) = member(next + 1);
      if (high != null && low <= 0x0A && 0x0A <= high) hasNewline = true;
      if (low != 0x0A || high != 0x0A) onlyNewline = false;
      members++;
      i = end;
      continue;
    }
    if (holds || low == 0x0A) hasNewline = true;
    if (low != 0x0A) onlyNewline = false;
    members++;
    i = next;
  }
  // Not closed: the pattern does not compile, which is reported before.
  return (end: pattern.length, negated: negated, hasNewline: hasNewline, onlyNewline: false);
}
