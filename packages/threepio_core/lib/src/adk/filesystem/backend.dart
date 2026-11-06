/// The filesystem an agent works on, and the shell it runs commands in.
///
/// Port of the interfaces of eino `adk/filesystem/backend.go`. P8's
/// filesystem, reduction, agents.md and skill middlewares work through these
/// contracts; `InMemoryBackend` is the pure Dart implementation.
library;

import '../../core/run_context.dart';
import '../../errors.dart';
import '../../streaming/stream_reader.dart';
import 'requests.dart';

/// A file that does not exist.
///
/// The Dart counterpart of a Go error that wraps `os.ErrNotExist`: the
/// agents.md middleware skips a missing file (with a warning) only when its
/// backend reports it this way, and fails on any other error. A backend that
/// wants missing agents.md files skipped throws it. Like eino's backends,
/// `InMemoryBackend` does not: it reports a missing file with a plain
/// `ThreepioException`, so a missing agents.md fails the run there.
final class FileNotFoundException extends ThreepioException {
  /// [path] does not exist; [message] defaults to `file not found: <path>`.
  const FileNotFoundException(this.path, {String? message, super.cause})
      : super(message ?? 'file not found: $path');

  /// The path that was not found.
  final String path;
}

/// The read half of a file store: what the agents.md middleware needs.
///
/// Port of eino `agentsmd.Backend`. Every [FilesystemBackend] is one.
abstract interface class FileReadBackend {
  /// The content of a file, or of a range of its lines. Port of
  /// `Backend.Read`. Throw [FileNotFoundException] for a missing file that
  /// the agents.md middleware should skip.
  Future<FileContent> read(RunContext ctx, ReadRequest request);
}

/// The write half of a file store: what the tool reduction middleware needs
/// to offload results.
///
/// Port of eino `reduction.Backend`. Every [FilesystemBackend] is one.
abstract interface class FileWriteBackend {
  /// Creates a file or replaces its content. Port of `Backend.Write`.
  Future<void> write(RunContext ctx, WriteRequest request);
}

/// A pluggable file store: list, read, search, find, write and edit files.
///
/// Port of eino `filesystem.Backend`. Every method takes a request object, so
/// that fields can be added later without breaking implementations. Methods
/// fail by throwing (`InMemoryBackend`, like eino's backends, throws a plain
/// `ThreepioException` for a missing file; [FileNotFoundException] marks one
/// that the agents.md middleware skips).
abstract interface class FilesystemBackend
    implements FileReadBackend, FileWriteBackend {
  /// The entries directly under [request]'s path. Port of `Backend.LsInfo`.
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request);

  /// The content of a file, or of a range of its lines. Port of
  /// `Backend.Read`.
  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request);

  /// The lines of files that match a regular expression, with context lines
  /// if asked for. Port of `Backend.GrepRaw`.
  Future<List<GrepMatch>> grepRaw(RunContext ctx, GrepRequest request);

  /// The files that match a glob pattern. Port of `Backend.GlobInfo`.
  Future<List<FileInfo>> globInfo(RunContext ctx, GlobInfoRequest request);

  /// Creates a file or replaces its content. Port of `Backend.Write`.
  @override
  Future<void> write(RunContext ctx, WriteRequest request);

  /// Replaces text in a file. Port of `Backend.Edit`.
  Future<void> edit(RunContext ctx, EditRequest request);
}

/// A backend that can also read images and PDFs, as parts instead of text.
///
/// Port of eino `filesystem.MultiModalReader`, an optional extension of a
/// [FilesystemBackend]. Size limits (refusing large files, downsampling)
/// belong in the implementation or in a tool middleware.
abstract interface class MultiModalReader {
  /// The file as text or as parts. Port of `MultiModalReader.MultiModalRead`.
  Future<MultiFileContent> multiModalRead(
    RunContext ctx,
    MultiModalReadRequest request,
  );
}

/// Runs a command and returns its whole output. Port of eino
/// `filesystem.Shell`.
abstract interface class Shell {
  /// Runs [request]'s command. Port of `Shell.Execute`.
  Future<ExecuteResponse> execute(RunContext ctx, ExecuteRequest request);
}

/// Runs a command and streams its output as it comes. Port of eino
/// `filesystem.StreamingShell`.
abstract interface class StreamingShell {
  /// Runs [request]'s command. Port of `StreamingShell.ExecuteStreaming`.
  Future<StreamReader<ExecuteResponse>> executeStreaming(
    RunContext ctx,
    ExecuteRequest request,
  );
}
