/// Runs commands on the local machine through `/bin/sh`.
///
/// Port of the shell half of eino-ext `adk/backend/local` (`local.go`):
/// `Local.Execute`, `Local.ExecuteStreaming` and their helpers
/// (`initStreamingCmd`, `runCmdInBackground`, `drainPipesConcurrently`,
/// `streamCmdOutput`, `readStderrAsync`, `streamStdout`,
/// `handleCmdCompletion`). In Go one type, `local.Local`, is the file
/// backend and the shell; in Dart `LocalFilesystemBackend` is both too and
/// runs its commands through a [LocalShell], which can also be used alone.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../components/model/cancel_token.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../streaming/stream_reader.dart';
import 'backend.dart';
import 'requests.dart';

/// Checks a command before it runs; throws to refuse it.
///
/// Port of eino-ext `local.Config.ValidateCommand` (`func(string) error`):
/// where Go's function returns an error, this one throws it, and the error
/// reaches the caller of `execute`/`executeStreaming` unchanged. It may be
/// asynchronous (to ask someone, for example).
typedef CommandValidator = FutureOr<void> Function(String command);

/// The shell eino-ext's local backend runs every command with.
const String _shell = '/bin/sh';

/// The capacity of the pipe a streamed command writes into (Go:
/// `schema.Pipe[*filesystem.ExecuteResponse](100)`).
const int _streamCapacity = 100;

/// A [Shell] and [StreamingShell] that runs each command with
/// `/bin/sh -c <command>` on this machine.
///
/// Port of the `Execute` and `ExecuteStreaming` methods of eino-ext
/// `local.Local` (`NewBackend`). Unix and macOS only, as in Go: Windows has
/// no `/bin/sh`. The command inherits the process's working directory and
/// environment, and reads end-of-file from its standard input (Go's
/// `os/exec` gives it `/dev/null`).
///
/// * [execute] waits for the command. On success the result is what it
///   wrote to standard output (standard error is dropped) with exit code 0;
///   on a non-zero exit it is `command exited with non-zero code <n>`
///   followed by `[stdout]:` and `[stderr]:` sections for the streams that
///   are not empty, with the exit code. A command killed by a signal has the
///   exit code -1, as Go reports it.
/// * [executeStreaming] sends each line of standard output (with its line
///   break) as it comes; then, for a non-zero exit, a last response with
///   the exit code and `command exited with non-zero code <n>` plus a
///   `[stderr]:` section; or, for a command that succeeded without any
///   output, a response with exit code 0 and no text. A command that
///   succeeded with output sends no exit code, as in Go. With
///   [ExecuteRequest.runInBackground] the stream holds only
///   `command started in background\n` with exit code 0 and the command
///   goes on running.
///
/// Cancelling `ctx.cancelToken` kills the command (`SIGKILL`, like Go's
/// `exec.CommandContext`): [execute] throws a [CancelledException], a
/// stream ends with one, and a background command is killed. Go instead
/// returns the killed command's result (exit code -1) or `context
/// canceled`; Dart reports a cancellation the same way everywhere. As in Go
/// only the shell process is killed; a process it started in the background
/// can outlive it.
///
/// A command that is empty is refused with `command is required`;
/// [validateCommand] is called next and may refuse it by throwing.
final class LocalShell implements Shell, StreamingShell {
  /// A shell that runs every command [validateCommand] accepts (all of them
  /// when it is `null`, Go's `defaultValidateCommand`).
  const LocalShell({this.validateCommand});

  /// Checks each command before it runs; `null` accepts every command.
  final CommandValidator? validateCommand;

  /// Runs [request]'s command and returns its output once it has finished.
  ///
  /// Port of eino-ext `Local.Execute`.
  @override
  Future<ExecuteResponse> execute(RunContext ctx, ExecuteRequest request) async {
    await _check(request.command);
    // Go: exec.CommandContext with a cancelled context does not start.
    ctx.cancelToken.throwIfCancelled();

    final Process process;
    try {
      process = await Process.start(_shell, ['-c', request.command]);
    } on ProcessException catch (error) {
      throw ThreepioException(
        'failed to execute command: ${_startErrorText(error)}',
        cause: error,
      );
    }
    _closeStdin(process);

    var cancelled = false;
    var exited = false;
    final stdout = _ByteCollector(process.stdout);
    final stderr = _ByteCollector(process.stderr);
    final watch = _CancelWatch(ctx.cancelToken, () {
      cancelled = true;
      process.kill(ProcessSignal.sigkill);
      stdout.abandon();
      stderr.abandon();
    });
    try {
      await Future.wait([stdout.done, stderr.done]);
      if (cancelled) throw CancelledException(ctx.cancelToken.reason);
      final code = _goExitCode(await process.exitCode);
      exited = true;
      if (cancelled) throw CancelledException(ctx.cancelToken.reason);

      final stdoutText = _decode(stdout.takeBytes());
      if (code == 0) return ExecuteResponse(output: stdoutText, exitCode: 0);
      final stderrText = _decode(stderr.takeBytes());
      return ExecuteResponse(
        output: [
          'command exited with non-zero code $code',
          if (stdoutText.isNotEmpty) '[stdout]:\n$stdoutText',
          if (stderrText.isNotEmpty) '[stderr]:\n$stderrText',
        ].join('\n'),
        exitCode: code,
      );
    } on CancelledException {
      rethrow;
    } on Object catch (error) {
      // Reading one of the pipes failed (Go: an error from cmd.Run that is
      // not an *exec.ExitError).
      if (!exited) process.kill(ProcessSignal.sigkill);
      throw ThreepioException('failed to execute command: $error', cause: error);
    } finally {
      watch.release();
    }
  }

  /// Runs [request]'s command and streams its output as it comes.
  ///
  /// Port of eino-ext `Local.ExecuteStreaming`. An empty or refused command
  /// throws; a command that cannot be started, or a context that is
  /// cancelled already, gives a stream whose only item is that error, as in
  /// Go.
  @override
  Future<StreamReader<ExecuteResponse>> executeStreaming(
    RunContext ctx,
    ExecuteRequest request,
  ) async {
    await _check(request.command);
    final (reader, writer) = pipe<ExecuteResponse>(capacity: _streamCapacity);

    if (ctx.cancelToken.isCancelled) {
      // Go: cmd.Start fails with the context's error, sent into the stream.
      writer.sendError(CancelledException(ctx.cancelToken.reason));
      unawaited(writer.close());
      return reader;
    }
    final Process process;
    try {
      process = await Process.start(_shell, ['-c', request.command]);
    } on ProcessException catch (error) {
      writer.sendError(
        ThreepioException(
          'failed to start command: ${_startErrorText(error)}',
          cause: error,
        ),
      );
      unawaited(writer.close());
      return reader;
    }
    _closeStdin(process);

    if (request.runInBackground) {
      _runInBackground(ctx, process);
      writer.send(
        const ExecuteResponse(
          output: 'command started in background\n',
          exitCode: 0,
        ),
      );
      unawaited(writer.close());
      return reader;
    }
    unawaited(_streamOutput(ctx, process, writer));
    return reader;
  }

  Future<void> _check(String command) async {
    if (command.isEmpty) {
      throw const ThreepioException('command is required');
    }
    final validate = validateCommand;
    if (validate != null) await validate(command);
  }

  /// Port of `runCmdInBackground`: the pipes are drained so that the command
  /// never blocks on them, and the command is killed when [ctx] is
  /// cancelled before it ends.
  static void _runInBackground(RunContext ctx, Process process) {
    final stdout = process.stdout.listen(null, onError: _ignore, cancelOnError: true);
    final stderr = process.stderr.listen(null, onError: _ignore, cancelOnError: true);
    final watch = _CancelWatch(ctx.cancelToken, () {
      process.kill(ProcessSignal.sigkill);
      unawaited(stdout.cancel());
      unawaited(stderr.cancel());
    });
    unawaited(process.exitCode.then((_) => watch.release()));
  }

  /// Port of `streamCmdOutput`, `streamStdout` and `handleCmdCompletion`.
  static Future<void> _streamOutput(
    RunContext ctx,
    Process process,
    StreamWriter<ExecuteResponse> writer,
  ) async {
    var cancelled = false;
    final stderr = _ByteCollector(process.stderr);
    final stdout = StreamIterator<List<int>>(process.stdout);
    final lines = _LineSplitter();
    // moveNext listens to stdout before the watch can fire.
    var next = stdout.moveNext();
    final watch = _CancelWatch(ctx.cancelToken, () {
      cancelled = true;
      process.kill(ProcessSignal.sigkill);
      unawaited(stdout.cancel());
      stderr.abandon();
    });
    void sendCancelled() {
      writer.sendError(CancelledException(ctx.cancelToken.reason));
    }

    try {
      var hasOutput = false;
      try {
        while (await next) {
          for (final line in lines.add(stdout.current)) {
            hasOutput = true;
            if (cancelled) break;
            // A closed reader drops the line; the command still runs to its
            // end, as in Go.
            await writer.sendAsync(ExecuteResponse(output: _decode(line)));
          }
          if (cancelled) break;
          next = stdout.moveNext();
        }
      } on Object catch (error, stackTrace) {
        if (!cancelled) {
          writer.sendError(
            ThreepioException('error reading stdout: $error', cause: error),
            stackTrace,
          );
          process.kill(ProcessSignal.sigkill);
          return;
        }
      }
      if (cancelled) {
        sendCancelled();
        return;
      }
      final rest = lines.flush();
      if (rest != null) {
        hasOutput = true;
        await writer.sendAsync(ExecuteResponse(output: _decode(rest)));
      }

      try {
        await stderr.done;
      } on Object catch (error, stackTrace) {
        if (!cancelled) {
          writer.sendError(
            ThreepioException('failed to read stderr: $error', cause: error),
            stackTrace,
          );
          return;
        }
      }
      if (cancelled) {
        sendCancelled();
        return;
      }
      final code = _goExitCode(await process.exitCode);
      if (cancelled) {
        sendCancelled();
        return;
      }

      if (code != 0) {
        final stderrText = _decode(stderr.takeBytes());
        writer.send(
          ExecuteResponse(
            output: [
              'command exited with non-zero code $code',
              if (stderrText.isNotEmpty) '[stderr]:\n$stderrText',
            ].join('\n'),
            exitCode: code,
          ),
        );
      } else if (!hasOutput) {
        writer.send(const ExecuteResponse(exitCode: 0));
      }
    } finally {
      watch.release();
      unawaited(writer.close());
    }
  }
}

/// The exit code Go's `ExitError.ExitCode()` reports: -1 for a process
/// killed by a signal (Dart: minus the signal number).
int _goExitCode(int code) => code < 0 ? -1 : code;

/// Go's text for an error starting `/bin/sh` (`fork/exec /bin/sh: …`).
String _startErrorText(ProcessException error) {
  final message = error.message;
  final text = message.isEmpty
      ? 'error ${error.errorCode}'
      : '${message[0].toLowerCase()}${message.substring(1)}';
  return 'fork/exec ${error.executable}: $text';
}

/// The command reads end-of-file from its standard input, as with Go's
/// `/dev/null`. A command that has exited already makes the close fail;
/// nothing waits for it.
void _closeStdin(Process process) => process.stdin.close().ignore();

String _decode(List<int> bytes) => utf8.decode(bytes, allowMalformed: true);

void _ignore(Object error) {}

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

  /// Stops reading the pipe (it may be kept open by a process the command
  /// started) and completes [done].
  void abandon() {
    unawaited(_subscription.cancel());
    if (!_done.isCompleted) _done.complete();
  }
}

/// Splits the bytes of a pipe into lines, each with its `\n` (Go's
/// `bufio.Reader.ReadString('\n')`).
final class _LineSplitter {
  final BytesBuilder _partial = BytesBuilder();

  /// The lines [chunk] completes; the rest is kept for the next call.
  List<Uint8List> add(List<int> chunk) {
    final lines = <Uint8List>[];
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 0x0A) continue;
      _partial.add(chunk.sublist(start, i + 1));
      lines.add(_partial.takeBytes());
      start = i + 1;
    }
    if (start < chunk.length) _partial.add(chunk.sublist(start));
    return lines;
  }

  /// The last line, which has no `\n`, or `null` when there is none.
  Uint8List? flush() => _partial.isEmpty ? null : _partial.takeBytes();
}

/// Calls a function once when a token is cancelled, unless it was released
/// first.
///
/// The watch is a token of its own that the watched token holds until
/// [release], so a token that lives as long as the application does not
/// collect one listener per command.
final class _CancelWatch {
  _CancelWatch(CancelToken token, void Function() onCancel)
      : _watch = CancelToken.any([token, CancelToken()])! {
    unawaited(
      _watch.whenCancelled.then((_) {
        if (!_active) return;
        _active = false;
        onCancel();
      }),
    );
  }

  final CancelToken _watch;
  bool _active = true;

  /// Stops watching; the function will not be called any more.
  void release() {
    if (!_active) return;
    _active = false;
    _watch.cancel('command finished');
  }
}
