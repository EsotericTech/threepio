/// A [CommandLineOperator] for this machine.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../internal/provider_http.dart' show CallWatch;
import '../../model/cancel_token.dart';
import '../../../internal/go_duration.dart';
import 'command_line_operator.dart';

/// The files and commands of this machine, for `PyExecutorTool` and
/// `StrReplaceEditorTool`.
///
/// threepio's substitute for eino-ext's Docker sandbox
/// (`commandline/sandbox`, not ported): the same contract, without the
/// container. **Nothing is isolated**: the tools read and write any file the
/// process may, and the code the Python tool runs has the rights of the
/// process. Give it to a model only where that is acceptable. Desktop only
/// (`dart:io`).
///
/// * A relative path is resolved against [workingDirectory] (the process's
///   working directory when it is `null`), as the sandbox resolves it
///   against its `WorkDir`; an absolute path is used as it is.
/// * [readFile] decodes the file as UTF-8 (malformed bytes become U+FFFD);
///   [writeFile] creates the missing parent directories, as the sandbox
///   does, and writes UTF-8.
/// * [isDirectory] and [exists] follow symbolic links (`test -d` and
///   `test -e`).
/// * [runCommand] starts the program directly, without a shell, in
///   [workingDirectory], with the process's environment and an empty
///   standard input, and waits for it. Its output is decoded as UTF-8. A
///   program killed by a signal reports `128 + signal` as its exit code, as
///   a shell (and the sandbox) would; on Windows the exit code is the
///   unsigned 32-bit value the process reported (Go's `ExitCode` there). A
///   program that cannot be started is a [ThreepioException] `failed to
///   start command: …`.
/// * A command still running after [timeout] is killed (`SIGKILL`) and the
///   call throws `command timed out after <timeout>` (the sandbox's message,
///   with Go's duration format).
/// * Cancelling `ctx.cancelToken` kills a running command (`SIGKILL`) and
///   the call throws a [CancelledException]; every method throws one when
///   the token is cancelled before it starts. Only the program itself is
///   killed; a process it started in the background can outlive it.
final class LocalOperator implements CommandLineOperator {
  /// An operator that works in [workingDirectory] and gives every command
  /// [timeout] to finish.
  const LocalOperator({this.workingDirectory, this.timeout});

  /// The timeout of a command when none is configured: 30 s, the default of
  /// eino-ext's Docker sandbox.
  static const Duration defaultTimeout = Duration(seconds: 30);

  /// Where commands run and relative paths are resolved; `null` is the
  /// working directory of the process.
  final String? workingDirectory;

  /// How long a command may run; `null` or zero means [defaultTimeout], as
  /// in the sandbox.
  final Duration? timeout;

  Duration get _timeout {
    final timeout = this.timeout;
    return timeout == null || timeout == Duration.zero
        ? defaultTimeout
        : timeout;
  }

  String _resolve(String path) {
    final workingDirectory = this.workingDirectory;
    return workingDirectory == null || p.isAbsolute(path)
        ? path
        : p.join(workingDirectory, path);
  }

  @override
  Future<String> readFile(RunContext ctx, String path) async {
    ctx.cancelToken.throwIfCancelled();
    final resolved = _resolve(path);
    try {
      final bytes = await File(resolved).readAsBytes();
      return utf8.decode(bytes, allowMalformed: true);
    } on FileSystemException catch (error) {
      throw ThreepioException(
        'failed to read file $resolved: ${_fileErrorText(error)}',
        cause: error,
      );
    }
  }

  @override
  Future<void> writeFile(RunContext ctx, String path, String content) async {
    ctx.cancelToken.throwIfCancelled();
    final resolved = _resolve(path);
    try {
      final file = File(resolved);
      await file.parent.create(recursive: true);
      await file.writeAsString(content, flush: true);
    } on FileSystemException catch (error) {
      throw ThreepioException(
        'failed to write file $resolved: ${_fileErrorText(error)}',
        cause: error,
      );
    }
  }

  @override
  Future<bool> isDirectory(RunContext ctx, String path) async {
    ctx.cancelToken.throwIfCancelled();
    return FileSystemEntity.isDirectory(_resolve(path));
  }

  @override
  Future<bool> exists(RunContext ctx, String path) async {
    ctx.cancelToken.throwIfCancelled();
    final type = await FileSystemEntity.type(_resolve(path));
    return type != FileSystemEntityType.notFound;
  }

  /// Runs [command] and returns its output; see the class documentation.
  ///
  /// Throws an [ArgumentError] for an empty [command].
  @override
  Future<CommandLineOutput> runCommand(
    RunContext ctx,
    List<String> command,
  ) async {
    if (command.isEmpty) {
      throw ArgumentError.value(command, 'command', 'must not be empty');
    }
    ctx.cancelToken.throwIfCancelled();

    final Process process;
    try {
      process = await Process.start(
        command.first,
        command.sublist(1),
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (error) {
      throw ThreepioException(
        'failed to start command: ${_processErrorText(error)}',
        cause: error,
      );
    }
    // The command reads end-of-file; one that has exited already makes the
    // close fail, which nothing waits for.
    process.stdin.close().ignore();

    final stdout = _ByteCollector(process.stdout);
    final stderr = _ByteCollector(process.stderr);
    var cancelled = false;
    var timedOut = false;
    void stop() {
      process.kill(ProcessSignal.sigkill);
      // A process the command started may hold the pipes open.
      stdout.abandon();
      stderr.abandon();
    }

    final watch = CallWatch(ctx.cancelToken)
      ..onCancel(() {
        cancelled = true;
        stop();
      });
    final timeout = _timeout;
    final timer = Timer(timeout, () {
      timedOut = true;
      stop();
    });
    try {
      await Future.wait([stdout.done, stderr.done]);
      final exitCode = await process.exitCode;
      if (cancelled) throw CancelledException(ctx.cancelToken.reason);
      if (timedOut) {
        throw ThreepioException(
          'command timed out after '
          '${goDurationString(timeout)}',
        );
      }
      return CommandLineOutput(
        stdout: utf8.decode(stdout.takeBytes(), allowMalformed: true),
        stderr: utf8.decode(stderr.takeBytes(), allowMalformed: true),
        exitCode: _exitCode(exitCode),
      );
    } on ThreepioException {
      rethrow;
    } on Object catch (error) {
      // Reading one of the pipes failed.
      stop();
      throw ThreepioException(
        'failed to read the output of the command: $error',
        cause: error,
      );
    } finally {
      timer.cancel();
      watch.release();
    }
  }
}

/// [exitCode] from `Process.exitCode` as a shell reports it: a negative
/// value is the number of the signal that killed the process on POSIX
/// (`128 + signal`), and a 32-bit exit code Dart made signed on Windows
/// (`0xC0000005` arrives as `-1073741819`).
int _exitCode(int exitCode) {
  if (exitCode >= 0) return exitCode;
  return Platform.isWindows ? exitCode & 0xFFFFFFFF : 128 - exitCode;
}

/// The OS error of [error] when there is one (`No such file or directory`),
/// otherwise its message.
String _fileErrorText(FileSystemException error) =>
    error.osError?.message ?? error.message;

String _processErrorText(ProcessException error) {
  final message = error.message;
  return message.isEmpty
      ? '${error.executable}: error ${error.errorCode}'
      : '${error.executable}: $message';
}

/// Collects what a process writes to one of its pipes.
final class _ByteCollector {
  _ByteCollector(Stream<List<int>> stream) {
    _subscription = stream.listen(
      _bytes.add,
      onError: (Object error, StackTrace stackTrace) {
        if (!_done.isCompleted) _done.completeError(error, stackTrace);
      },
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
      cancelOnError: true,
    );
    // A read error before anyone awaits [done] must not be reported as
    // unhandled; whoever awaits it later still gets it.
    _done.future.ignore();
  }

  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;

  /// Completes when the pipe is closed or [abandon] was called; fails when
  /// reading it failed.
  Future<void> get done => _done.future;

  /// What was written so far.
  Uint8List takeBytes() => _bytes.takeBytes();

  /// Stops reading the pipe and completes [done].
  void abandon() {
    unawaited(_subscription.cancel());
    if (!_done.isCompleted) _done.complete();
  }
}
