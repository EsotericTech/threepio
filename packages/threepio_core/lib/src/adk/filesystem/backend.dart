/// The filesystem an agent works on, and the shell it runs commands in.
///
/// Port of the interfaces of eino `adk/filesystem/backend.go`. P8's
/// filesystem, reduction, agents.md and skill middlewares work through these
/// contracts; `InMemoryBackend` is the pure Dart implementation.
library;

import '../../core/run_context.dart';
import '../../streaming/stream_reader.dart';
import 'requests.dart';

/// A pluggable file store: list, read, search, find, write and edit files.
///
/// Port of eino `filesystem.Backend`. Every method takes a request object, so
/// that fields can be added later without breaking implementations. Methods
/// fail by throwing (for example a `ThreepioException` for a missing file).
abstract interface class FilesystemBackend {
  /// The entries directly under [request]'s path. Port of `Backend.LsInfo`.
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request);

  /// The content of a file, or of a range of its lines. Port of
  /// `Backend.Read`.
  Future<FileContent> read(RunContext ctx, ReadRequest request);

  /// The lines of files that match a regular expression, with context lines
  /// if asked for. Port of `Backend.GrepRaw`.
  Future<List<GrepMatch>> grepRaw(RunContext ctx, GrepRequest request);

  /// The files that match a glob pattern. Port of `Backend.GlobInfo`.
  Future<List<FileInfo>> globInfo(RunContext ctx, GlobInfoRequest request);

  /// Creates a file or replaces its content. Port of `Backend.Write`.
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
