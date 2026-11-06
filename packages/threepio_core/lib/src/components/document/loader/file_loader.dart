/// eino-ext's file loader: reads a local file and hands it to a parser.
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../../../callbacks/callback_context.dart';
import '../../../callbacks/component_callbacks.dart';
import '../../../callbacks/global_callbacks.dart';
import '../../../callbacks/run_info.dart';
import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/parser_utils.dart';
import '../../../schema/document.dart';
import '../../component_type.dart';
import '../../model/cancel_token.dart';
import '../document_callbacks.dart';
import '../loader.dart';
import '../parser/ext_parser.dart';
import '../parser/go_text.dart';
import '../parser/parser.dart';
import '../parser/text_parser.dart';

/// The metadata key of the name of the loaded file (`notes.md`).
///
/// Port of eino-ext `file.MetaKeyFileName`. The path itself is under
/// [metaKeySource].
const String fileLoaderMetaKeyFileName = '_file_name';

/// The metadata key of the extension of the loaded file, with its dot
/// (`.md`), or `''`.
///
/// Port of eino-ext `file.MetaKeyExtension`.
const String fileLoaderMetaKeyExtension = '_extension';

/// The configuration of [FileLoader].
///
/// Port of eino-ext `file.FileLoaderConfig`.
@immutable
final class FileLoaderConfig {
  /// A configuration; every field has a default.
  const FileLoaderConfig({this.useNameAsId = false, this.parser});

  /// Whether the documents get the file name as their id: the name itself
  /// when the parser returns one document, `<name>_<index>` for each of
  /// several (Go: `UseNameAsID`).
  final bool useNameAsId;

  /// The parser of the file content. Defaults to an [ExtParser] that falls
  /// back to the [TextParser] (and has no other parser), as in Go.
  final Parser? parser;
}

/// Loads a local file: reads it and parses its content.
///
/// Port of eino-ext `loader/file` (`file.NewFileLoader`, `FileLoader.Load`).
/// The URI of the source is a file path. The parser gets it as its
/// [ParserOptions.uri] and, as [ParserOptions.extraMeta], the file name
/// ([fileLoaderMetaKeyFileName]), its extension
/// ([fileLoaderMetaKeyExtension]) and the path ([metaKeySource]); the
/// [LoaderOptions.parserOptions] of the call are merged on top (they win).
///
/// ```dart
/// final loader = FileLoader(const FileLoaderConfig(useNameAsId: true));
/// final docs = await loader.load(ctx, const DocumentSource(uri: 'notes.md'));
/// ```
///
/// The loader fires its own callbacks (type `FileLoader`, kind
/// [ComponentType.loader]): a [LoaderCallbackInput] at the start, a
/// [LoaderCallbackOutput] at the end, the error when it fails.
///
/// Errors carry Go's messages: an empty path, a path that does not exist or
/// is a directory, or a file that cannot be opened throw a
/// [ThreepioException] with the text of eino-ext's `validateSingleFilePath`
/// and `openFile`; a failing parser `file parse err of [<path>]: <error>`,
/// with the parser's error as `cause`. A cancellation or an interrupt
/// raised by the parser gets through as it is, and so does an [Error] (a
/// programming error); a context cancelled before the load starts throws a
/// [CancelledException].
///
/// Where this differs from Go: `dart:io` reports every failure to stat a
/// path as a missing file, so a path that cannot be examined (a directory
/// on the way without search permission) gets the message of a path that
/// does not exist; the file is opened once to check it can be read and
/// then read as a stream (Go keeps the file it opened).
final class FileLoader
    implements Loader, TypedComponent, CallbackAwareComponent {
  /// A loader configured by [config].
  ///
  /// Port of eino-ext `file.NewFileLoader`.
  FileLoader([FileLoaderConfig config = const FileLoaderConfig()])
      : useNameAsId = config.useNameAsId,
        parser = config.parser ?? ExtParser();

  /// See [FileLoaderConfig.useNameAsId].
  final bool useNameAsId;

  /// The parser of the file content.
  final Parser parser;

  @override
  String get componentTypeName => 'FileLoader';

  @override
  bool get isCallbacksEnabled => true;

  @override
  Future<List<Document>> load(
    RunContext ctx,
    DocumentSource source, {
    LoaderOptions? options,
  }) async {
    if (!ctx.hasCallbacks && GlobalCallbacks.isEmpty) {
      return _load(ctx, source, options);
    }
    var runCtx = ensureRunInfo(ctx, componentTypeName, ComponentType.loader);
    runCtx = await onStart(runCtx, LoaderCallbackInput(source: source));
    final List<Document> docs;
    try {
      docs = await _load(runCtx, source, options);
    } catch (error, stackTrace) {
      await onError(runCtx, error, stackTrace);
      rethrow;
    }
    await onEnd(runCtx, LoaderCallbackOutput(source: source, docs: docs));
    return docs;
  }

  Future<List<Document>> _load(
    RunContext ctx,
    DocumentSource source,
    LoaderOptions? options,
  ) async {
    ctx.cancelToken.throwIfCancelled();
    final path = source.uri;
    final file = await _openFile(path);

    // Go's filepath.Base; the path is not empty here.
    final name = p.basename(path);
    final parserOptions = ParserOptions(
      uri: path,
      extraMeta: {
        fileLoaderMetaKeyExtension: fileExtensionOf(path),
        fileLoaderMetaKeyFileName: name,
        metaKeySource: path,
      },
    ).merge(options?.parserOptions);

    List<Document> docs;
    try {
      docs = await parser.parse(ctx, file.openRead(), options: parserOptions);
    } on Exception catch (error) {
      if (error is CancelledException || isInterrupt(error)) rethrow;
      throw ThreepioException(
        'file parse err of [$path]: ${goErrorText(error)}',
        cause: error,
      );
    }

    if (useNameAsId) {
      docs = docs.length == 1
          ? [docs.single.copyWith(id: name)]
          : [
              for (final (index, doc) in docs.indexed)
                doc.copyWith(id: '${name}_$index'),
            ];
    }
    return docs;
  }

  /// The file at [path], after the checks of eino-ext's `openFile` and
  /// `validateSingleFilePath`. The texts of the operating system errors are
  /// written as Go's `os` package writes them (`stat <path>: no such file or
  /// directory`, `open <path>: permission denied`).
  static Future<File> _openFile(String path) async {
    if (path.isEmpty) {
      throw const ThreepioException(
        'read single file from path, path is empty',
      );
    }
    final stat = await FileStat.stat(path);
    if (stat.type == FileSystemEntityType.notFound) {
      throw ThreepioException(
        'read single file from path, error while checking file stat: '
        'stat $path: no such file or directory, path= $path',
      );
    }
    if (stat.type == FileSystemEntityType.directory) {
      throw ThreepioException(
        'read single file from path can only accept non-dir path, '
        'actual= $path',
      );
    }

    final file = File(path);
    try {
      // Opening the file here, as Go's os.Open does, reports a file that
      // cannot be read before the parser starts.
      await (await file.open()).close();
    } on FileSystemException catch (error) {
      final reason = error.osError?.message.toLowerCase() ?? error.message;
      throw ThreepioException(
        'flat loader open file path failed with err: open $path: $reason, '
        'path= $path',
        cause: error,
      );
    }
    return file;
  }
}
