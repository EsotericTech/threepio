// Tests written for the port: LocalOperator is threepio's substitute for
// eino-ext's Docker sandbox (`commandline/sandbox`, whose sandbox_test.go
// needs Docker and is not ported). Everything happens in a temporary
// directory; the only programs run are /bin/sh and coreutils (echo, cat,
// sleep). The last groups run StrReplaceEditorTool and PyExecutorTool over a
// LocalOperator (the executor with `cat`, `true` or `/bin/sh` in place of
// python3).
@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/components/tool/command_line/command_line_operator.dart';
import 'package:threepio_core/src/components/tool/command_line/local_operator.dart';
import 'package:threepio_core/src/components/tool/command_line/py_executor_tool.dart';
import 'package:threepio_core/src/components/tool/command_line/str_replace_editor_tool.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';

void main() {
  late Directory dir;
  late LocalOperator operator;
  final ctx = RunContext.background();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('threepio_p12_');
    operator = LocalOperator(workingDirectory: dir.path);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('files', () {
    test('a relative path is in the working directory', () async {
      await operator.writeFile(ctx, 'a/b/c.txt', 'hello\nworld');
      expect(
        File(p.join(dir.path, 'a', 'b', 'c.txt')).readAsStringSync(),
        'hello\nworld',
      );
      expect(await operator.readFile(ctx, 'a/b/c.txt'), 'hello\nworld');
      expect(await operator.exists(ctx, 'a/b/c.txt'), isTrue);
      expect(await operator.isDirectory(ctx, 'a/b/c.txt'), isFalse);
      expect(await operator.isDirectory(ctx, 'a/b'), isTrue);
      expect(await operator.exists(ctx, 'a/b'), isTrue);
      expect(await operator.exists(ctx, 'nope'), isFalse);
      expect(await operator.isDirectory(ctx, 'nope'), isFalse);
    });

    test('an absolute path is used as it is', () async {
      final path = p.join(dir.path, 'abs.txt');
      await const LocalOperator().writeFile(ctx, path, 'x');
      expect(await operator.readFile(ctx, path), 'x');
      await operator.writeFile(ctx, path, 'replaced');
      expect(File(path).readAsStringSync(), 'replaced');
    });

    test('UTF-8 in and out; malformed bytes become U+FFFD', () async {
      final text = 'caf${String.fromCharCode(0xE9)} ${String.fromCharCode(0x1F600)}';
      await operator.writeFile(ctx, 'u.txt', text);
      expect(await operator.readFile(ctx, 'u.txt'), text);
      File(p.join(dir.path, 'bad.txt')).writeAsBytesSync([0x61, 0xFF, 0x62]);
      expect(
        await operator.readFile(ctx, 'bad.txt'),
        'a${String.fromCharCode(0xFFFD)}b',
      );
    });

    test('a missing file', () async {
      final error = await operator
          .readFile(ctx, 'missing.txt')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(
        error,
        isA<ThreepioException>()
            .having(
              (e) => e.message,
              'message',
              startsWith(
                'failed to read file ${p.join(dir.path, 'missing.txt')}: ',
              ),
            )
            .having((e) => e.cause, 'cause', isA<FileSystemException>()),
      );
    });

    test('a file that cannot be written', () async {
      File(p.join(dir.path, 'plain')).writeAsStringSync('');
      await expectLater(
        operator.writeFile(ctx, 'plain/child.txt', 'x'),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            startsWith('failed to write file '),
          ),
        ),
      );
    });
  });

  group('runCommand', () {
    test('stdout of a successful command', () async {
      expect(
        await operator.runCommand(ctx, ['echo', 'hello']),
        const CommandLineOutput(stdout: 'hello\n'),
      );
    });

    test('stdout, stderr and the exit code of a failing command', () async {
      expect(
        await operator.runCommand(
          ctx,
          ['/bin/sh', '-c', 'echo out; echo err >&2; exit 3'],
        ),
        const CommandLineOutput(stdout: 'out\n', stderr: 'err\n', exitCode: 3),
      );
    });

    test('no shell: arguments are passed as they are', () async {
      expect(
        (await operator.runCommand(ctx, ['echo', r'$HOME', '*'])).stdout,
        '\$HOME *\n',
      );
    });

    test('runs in the working directory, with an empty stdin', () async {
      File(p.join(dir.path, 'rel.txt')).writeAsStringSync('relative');
      expect(
        (await operator.runCommand(ctx, ['cat', 'rel.txt'])).stdout,
        'relative',
      );
      expect(await operator.runCommand(ctx, ['cat']), const CommandLineOutput());
    });

    test('a command killed by a signal exits with 128 + signal', () async {
      final output =
          await operator.runCommand(ctx, ['/bin/sh', '-c', r'kill -9 $$']);
      expect(output.exitCode, 137);
    });

    test('malformed output becomes U+FFFD', () async {
      expect(
        (await operator.runCommand(ctx, ['/bin/sh', '-c', r"printf 'a\377b'"]))
            .stdout,
        'a${String.fromCharCode(0xFFFD)}b',
      );
    });

    test('a program that does not exist', () async {
      await expectLater(
        operator.runCommand(ctx, ['threepio-no-such-program-p12']),
        throwsA(
          isA<ThreepioException>()
              .having(
                (e) => e.message,
                'message',
                startsWith(
                  'failed to start command: threepio-no-such-program-p12: ',
                ),
              )
              .having((e) => e.cause, 'cause', isA<ProcessException>()),
        ),
      );
    });

    test('an empty command is a mistake', () async {
      await expectLater(
        operator.runCommand(ctx, const []),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('cancelling kills the command', () async {
      final token = CancelToken();
      final watch = Stopwatch()..start();
      final run = operator.runCommand(
        RunContext.background(cancelToken: token),
        ['sleep', '5'],
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel('enough');
      await expectLater(
        run,
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'enough'),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a cancelled context starts nothing', () async {
      final cancelled =
          RunContext.background(cancelToken: CancelToken()..cancel('before'));
      final marker = p.join(dir.path, 'marker');
      await expectLater(
        operator.runCommand(cancelled, ['/bin/sh', '-c', 'echo > $marker']),
        throwsA(isA<CancelledException>()),
      );
      expect(File(marker).existsSync(), isFalse);
      await expectLater(
        operator.readFile(cancelled, 'x'),
        throwsA(isA<CancelledException>()),
      );
      await expectLater(
        operator.writeFile(cancelled, 'x', 'y'),
        throwsA(isA<CancelledException>()),
      );
      expect(File(p.join(dir.path, 'x')).existsSync(), isFalse);
      await expectLater(
        operator.exists(cancelled, 'x'),
        throwsA(isA<CancelledException>()),
      );
      await expectLater(
        operator.isDirectory(cancelled, 'x'),
        throwsA(isA<CancelledException>()),
      );
    });

    test('a command that runs too long is killed', () async {
      final quick = LocalOperator(
        workingDirectory: dir.path,
        timeout: const Duration(milliseconds: 20),
      );
      final watch = Stopwatch()..start();
      await expectLater(
        quick.runCommand(ctx, ['sleep', '5']),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'command timed out after 20ms',
          ),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      // The operator still works afterwards.
      expect((await quick.runCommand(ctx, ['echo', 'ok'])).stdout, 'ok\n');
    });

    test('the default timeout is the sandbox default', () {
      expect(LocalOperator.defaultTimeout, const Duration(seconds: 30));
      expect(const LocalOperator().timeout, isNull);
      expect(const LocalOperator().workingDirectory, isNull);
    });
  });

  group('StrReplaceEditorTool over a LocalOperator', () {
    test('create, view, str_replace, insert, undo_edit', () async {
      final editor =
          StrReplaceEditorTool(StrReplaceEditorConfig(operator: operator));
      final path = p.join(dir.path, 'src', 'main.txt');
      const cat = "Here's the result of running `cat -n` on";

      expect(
        await editor.invokableRun(
          ctx,
          '{"command":"create","path":"$path","file_text":"alpha\\nbeta"}',
        ),
        'file successfully created at: $path',
      );
      expect(File(path).readAsStringSync(), 'alpha\nbeta');

      expect(
        await editor.invokableRun(ctx, '{"command":"view","path":"$path"}'),
        '$cat $path:\n     1\talpha\n     2\tbeta\n',
      );

      await editor.invokableRun(
        ctx,
        '{"command":"str_replace","path":"$path","old_str":"beta",'
        '"new_str":"gamma"}',
      );
      expect(File(path).readAsStringSync(), 'alpha\ngamma');

      await editor.invokableRun(
        ctx,
        '{"command":"insert","path":"$path","insert_line":1,'
        '"new_str":"inserted"}',
      );
      expect(File(path).readAsStringSync(), 'alpha\ninserted\ngamma');

      await editor.invokableRun(ctx, '{"command":"undo_edit","path":"$path"}');
      expect(File(path).readAsStringSync(), 'alpha\ngamma');
      await editor.invokableRun(ctx, '{"command":"undo_edit","path":"$path"}');
      expect(File(path).readAsStringSync(), 'alpha\nbeta');

      await editor.validatePath(ctx, StrReplaceEditorCommand.view, path);
      await expectLater(
        editor.validatePath(ctx, StrReplaceEditorCommand.create, path),
        throwsA(isA<ThreepioException>()),
      );
    });
  });

  group('PyExecutorTool over a LocalOperator', () {
    test('writes <uuid>.py in the working directory and runs it', () async {
      final exec = PyExecutorTool(
        PyExecutorConfig(operator: operator, command: 'cat'),
      );
      expect(
        await exec.invokableRun(ctx, '{"code":"print(\'hi\')\\n"}'),
        "print('hi')\n",
      );
      // As in Go, the file stays.
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(p.extension(files.single.path), '.py');
      expect(files.single.readAsStringSync(), "print('hi')\n");
    });

    test('cancelling the call kills the program and is not wrapped',
        () async {
      // /bin/sh runs the <uuid>.py file as a script: a program that waits
      // (exec, so that killing it leaves no orphaned sleep behind).
      final exec = PyExecutorTool(
        PyExecutorConfig(operator: operator, command: '/bin/sh'),
      );
      final token = CancelToken();
      final watch = Stopwatch()..start();
      final run = exec.invokableRun(
        RunContext.background(cancelToken: token),
        '{"code":"exec sleep 5"}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel('enough');
      await expectLater(
        run,
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'enough'),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a command that prints nothing', () async {
      final exec = PyExecutorTool(
        PyExecutorConfig(operator: operator, command: 'true'),
      );
      await expectLater(
        exec.invokableRun(ctx, '{"code":"x"}'),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'execute result is empty'),
        ),
      );
    });
  });
}
