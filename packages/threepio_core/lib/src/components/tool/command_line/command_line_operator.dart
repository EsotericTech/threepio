/// The machine the command-line tools work on.
///
/// Port of eino-ext `components/tool/commandline/operator.go`.
library;

import 'package:meta/meta.dart';

import '../../../core/run_context.dart';

/// What a command wrote and how it ended.
///
/// Port of eino-ext `commandline.CommandOutput`.
@immutable
final class CommandLineOutput {
  /// The result of a command that wrote [stdout] and [stderr] and exited
  /// with [exitCode].
  const CommandLineOutput({
    this.stdout = '',
    this.stderr = '',
    this.exitCode = 0,
  });

  /// What the command wrote to its standard output: usually the "normal"
  /// output of a successful command.
  final String stdout;

  /// What the command wrote to its standard error: warnings, errors and
  /// diagnostics, which a command may write even when it succeeds.
  final String stderr;

  /// The exit status of the command.
  ///
  /// 0 usually means success and 1 to 255 failure. Values above 128 usually
  /// mean that the process was killed by signal `exitCode - 128` (137: signal
  /// 9, `SIGKILL`, often because it ran out of memory).
  final int exitCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CommandLineOutput &&
          other.stdout == stdout &&
          other.stderr == stderr &&
          other.exitCode == exitCode;

  @override
  int get hashCode => Object.hash(stdout, stderr, exitCode);

  @override
  String toString() =>
      'CommandLineOutput(exitCode: $exitCode, stdout: $stdout, '
      'stderr: $stderr)';
}

/// Files and commands on the machine a command-line tool works on.
///
/// Port of eino-ext `commandline.Operator`. `PyExecutorTool` and
/// `StrReplaceEditorTool` do all their work through one: an operator decides
/// where the files are and where the commands run. `LocalOperator`
/// (`package:threepio_core/io.dart`) is this machine; eino-ext's Docker
/// sandbox is not ported.
///
/// Every method takes the [RunContext] of the call first, for its cancel
/// token. A method reports a failure by throwing; the tools pass what it
/// throws on.
abstract interface class CommandLineOperator {
  /// The content of the file at [path].
  ///
  /// Port of `Operator.ReadFile`.
  Future<String> readFile(RunContext ctx, String path);

  /// Writes [content] to the file at [path], replacing what it held.
  ///
  /// Port of `Operator.WriteFile`.
  Future<void> writeFile(RunContext ctx, String path, String content);

  /// Whether [path] is a directory.
  ///
  /// Port of `Operator.IsDirectory`.
  Future<bool> isDirectory(RunContext ctx, String path);

  /// Whether something exists at [path].
  ///
  /// Port of `Operator.Exists`.
  Future<bool> exists(RunContext ctx, String path);

  /// Runs [command] (the program, then its arguments; no shell) and returns
  /// what it wrote and its exit code once it has finished.
  ///
  /// A command that runs and fails is a result with a non-zero
  /// [CommandLineOutput.exitCode], not an exception. Port of
  /// `Operator.RunCommand`.
  Future<CommandLineOutput> runCommand(RunContext ctx, List<String> command);
}
