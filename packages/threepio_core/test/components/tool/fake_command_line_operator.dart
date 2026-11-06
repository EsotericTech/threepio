// An in-memory CommandLineOperator for the command-line tool tests. It takes
// the place of the testify mock of eino-ext's editor_test.go and the
// pyOperator of pyexecutor_test.go: it never runs anything, it records what
// it was asked to do.
import 'package:threepio_core/src/components/tool/command_line/command_line_operator.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';

class FakeCommandLineOperator implements CommandLineOperator {
  FakeCommandLineOperator({
    Map<String, String>? files,
    Set<String>? directories,
    Map<String, CommandLineOutput>? commandOutputs,
  })  : files = files ?? {},
        directories = directories ?? {},
        commandOutputs = commandOutputs ?? {};

  /// The files, by path.
  final Map<String, String> files;

  /// The directories.
  final Set<String> directories;

  /// What a command prints, by the command joined with spaces.
  final Map<String, CommandLineOutput> commandOutputs;

  /// Every call, as `<method> <path or command>`, in order.
  final List<String> calls = [];

  /// Every write, as (path, content).
  final List<(String, String)> writes = [];

  /// Every command run.
  final List<List<String>> commands = [];

  /// The context of every call, in order.
  final List<RunContext> contexts = [];

  /// Errors to throw instead of doing the work.
  Exception? readError;
  Exception? writeError;
  Exception? runError;
  Exception? existsError;
  Exception? isDirectoryError;

  @override
  Future<String> readFile(RunContext ctx, String path) async {
    calls.add('readFile $path');
    contexts.add(ctx);
    if (readError case final error?) throw error;
    final content = files[path];
    if (content == null) throw ThreepioException('no such file: $path');
    return content;
  }

  @override
  Future<void> writeFile(RunContext ctx, String path, String content) async {
    calls.add('writeFile $path');
    contexts.add(ctx);
    writes.add((path, content));
    if (writeError case final error?) throw error;
    files[path] = content;
  }

  @override
  Future<bool> isDirectory(RunContext ctx, String path) async {
    calls.add('isDirectory $path');
    contexts.add(ctx);
    if (isDirectoryError case final error?) throw error;
    return directories.contains(path);
  }

  @override
  Future<bool> exists(RunContext ctx, String path) async {
    calls.add('exists $path');
    contexts.add(ctx);
    if (existsError case final error?) throw error;
    return files.containsKey(path) || directories.contains(path);
  }

  @override
  Future<CommandLineOutput> runCommand(
    RunContext ctx,
    List<String> command,
  ) async {
    calls.add('runCommand ${command.join(' ')}');
    contexts.add(ctx);
    commands.add([...command]);
    if (runError case final error?) throw error;
    return commandOutputs[command.join(' ')] ?? const CommandLineOutput();
  }
}
