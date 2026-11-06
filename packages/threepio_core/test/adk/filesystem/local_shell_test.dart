// Ports eino-ext `adk/backend/local/local_test.go`, the shell tests:
//   TestExecute (all 8 sub-tests) and TestExecuteStreaming (12 of its 13
//   sub-tests).
// Not ported: TestExecuteStreaming "ExecuteStreaming with ping" — `ping` is
// neither /bin/sh nor a coreutils program and takes two seconds (one second
// between pings); the line-by-line streaming it checks is covered by the
// echo and seq sub-tests.
// Adapted:
// * Go's two background sub-tests start `sleep 10` / `sleep 5` and leave them
//   running; here the command is `exec sleep 5` and is killed through the
//   context at the end of the test.
// * "context cancellation during execution" cancels after 5 ms (Go: 100 ms).
//   Go accepts an error or a result with a non-zero exit code; Dart reports
//   a cancellation as a CancelledException, which the test expects.
// * "ExecuteStreaming with invalid command": Go's `lastErr` is the io.EOF that
//   ends the stream; here the stream's last response has exit code 127 and the
//   stream then ends.
// * "ExecuteStreaming with context cancellation": the stream ends with a
//   CancelledException (Go: context.Canceled).
// The group "LocalShell (port)" holds the tests written for this port.
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:threepio_core/src/adk/filesystem/local_backend.dart';
import 'package:threepio_core/src/adk/filesystem/local_shell.dart';
import 'package:threepio_core/src/adk/filesystem/requests.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';
import 'package:threepio_core/src/streaming/stream_reader.dart';

final ctx = RunContext.background();

/// Go's read loop over a stream: every response until the stream ends or
/// fails (`error` is null when it ended normally).
Future<({List<ExecuteResponse> responses, Object? error})> _drain(
  StreamReader<ExecuteResponse> reader, {
  void Function(ExecuteResponse response)? onResponse,
}) async {
  final responses = <ExecuteResponse>[];
  Object? error;
  try {
    while (true) {
      final response = await reader.recv();
      responses.add(response);
      onResponse?.call(response);
    }
  } on StreamEOFException {
    // The end of the stream.
  } on Object catch (e) {
    error = e;
  } finally {
    await reader.close();
  }
  return (responses: responses, error: error);
}

/// The outputs of [responses] that are not empty, trimmed (Go's
/// `strings.TrimSpace(resp.Output)`).
List<String> _outputs(List<ExecuteResponse> responses) => [
      for (final response in responses)
        if (response.output.isNotEmpty) response.output.trim(),
    ];

/// Waits (10 ms at a time, two seconds at most) until [condition] holds.
Future<bool> _eventually(FutureOr<bool> Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return condition();
}

/// Whether the process [pid] is still running.
bool _isRunning(int pid) =>
    Process.runSync('/bin/sh', ['-c', 'kill -0 $pid 2>/dev/null']).exitCode ==
    0;

/// A context whose token is cancelled [after] the given time.
RunContext _cancelledAfter(Duration after) {
  final token = CancelToken();
  Timer(after, () => token.cancel('test timeout'));
  return RunContext.background(cancelToken: token);
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('threepio_p11_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('TestExecuteStreaming', () {
    const s = LocalShell();

    test('ExecuteStreaming with echo', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(command: 'echo line1 && echo line2 && echo line3'),
      );
      final outputs = _outputs((await _drain(sr)).responses);
      expect(outputs, hasLength(3));
      expect(outputs[0], 'line1');
      expect(outputs[1], 'line2');
      expect(outputs[2], 'line3');
    });

    test('ExecuteStreaming with seq command', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(command: 'seq 1 5'),
      );
      final numbers = _outputs((await _drain(sr)).responses);
      expect(numbers, hasLength(5));
      expect(numbers[0], '1');
      expect(numbers[4], '5');
    });

    test('ExecuteStreaming with context cancellation', () async {
      final token = CancelToken();
      final cancelCtx = RunContext.background(cancelToken: token);
      final sr = await s.executeStreaming(
        cancelCtx,
        const ExecuteRequest(command: 'seq 1 1000000'),
      );
      var lineCount = 0;
      final result = await _drain(
        sr,
        onResponse: (response) {
          if (response.output.isNotEmpty) {
            lineCount++;
            if (lineCount >= 5) token.cancel();
          }
        },
      );
      expect(
        lineCount,
        greaterThanOrEqualTo(5),
        reason: 'should receive at least 5 lines before cancellation',
      );
      expect(result.error, isA<CancelledException>());
      expect(lineCount, lessThan(1000000));
    });

    test('ExecuteStreaming with command failure', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(command: 'echo output && exit 1'),
      );
      final responses = (await _drain(sr)).responses;
      expect(
        responses.any((r) => r.output.isNotEmpty),
        isTrue,
        reason: 'should receive output before final response',
      );
      final lastResp = responses.last;
      expect(lastResp.exitCode, 1);
      expect(lastResp.output, contains('non-zero code'));
    });

    test('ExecuteStreaming with stderr output', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(
          command: 'echo stdout && echo stderr >&2 && exit 1',
        ),
      );
      final responses = (await _drain(sr)).responses;
      final lastResp = responses.last;
      expect(lastResp.exitCode, 1);
      expect(lastResp.output, contains('non-zero code'));
      expect(lastResp.output, contains('stderr'));
      // stdout is streamed separately
      final outputs = _outputs(responses);
      expect(outputs.length, greaterThanOrEqualTo(1));
      expect(outputs, contains('stdout'));
    });

    test('ExecuteStreaming with empty command', () async {
      await expectLater(
        s.executeStreaming(ctx, const ExecuteRequest(command: '')),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            contains('command is required'),
          ),
        ),
      );
    });

    test('ExecuteStreaming with large output', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(command: 'seq 1 100'),
      );
      final lines = _outputs((await _drain(sr)).responses);
      expect(lines, hasLength(100), reason: 'should receive all 100 lines');
    });

    test('ExecuteStreaming with normal completion', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(command: 'echo test'),
      );
      final responses = (await _drain(sr)).responses;
      expect(
        responses.any((r) => r.output.isNotEmpty),
        isTrue,
        reason: 'should receive output',
      );
    });

    test('ExecuteStreaming with invalid command', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(command: '/nonexistent/command'),
      );
      final result = await _drain(sr);
      // Go's loop stops at the io.EOF that ends the stream.
      expect(result.error, isNull);
      expect(result.responses.last.exitCode, 127);
      expect(result.responses.last.output, contains('non-zero code 127'));
    });

    test('ExecuteStreaming with no stdout output', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(command: 'true'),
      );
      final responses = (await _drain(sr)).responses;
      expect(
        responses,
        isNotEmpty,
        reason: 'should receive at least one response even with no stdout',
      );
      final exitCodes = [
        for (final r in responses)
          if (r.exitCode != null) r.exitCode,
      ];
      expect(exitCodes, isNotEmpty, reason: 'should receive exit code');
      expect(exitCodes.last, 0);
    });

    test('ExecuteStreaming with RunInBackendGround', () async {
      final token = CancelToken();
      addTearDown(token.cancel);
      final sr = await s.executeStreaming(
        RunContext.background(cancelToken: token),
        const ExecuteRequest(command: 'exec sleep 5', runInBackground: true),
      );
      final responses = (await _drain(sr)).responses;
      expect(
        responses,
        isNotEmpty,
        reason: 'should receive response for background command',
      );
      expect(responses.last.output, contains('background'));
      expect(responses.last.exitCode, 0);
    });

    test('ExecuteStreaming with RunInBackendGround returns immediately', () async {
      final token = CancelToken();
      addTearDown(token.cancel);
      final stopwatch = Stopwatch()..start();
      final sr = await s.executeStreaming(
        RunContext.background(cancelToken: token),
        const ExecuteRequest(command: 'exec sleep 5', runInBackground: true),
      );
      await _drain(sr);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: 'background command should return immediately without waiting',
      );
    });
  });

  group('TestExecute', () {
    const s = LocalShell();

    test('simple echo', () async {
      final resp = await s.execute(ctx, const ExecuteRequest(command: 'echo hello'));
      expect(resp.output, 'hello\n');
      expect(resp.exitCode, 0);
    });

    test('multi-line output', () async {
      final resp = await s.execute(
        ctx,
        const ExecuteRequest(command: 'echo line1 && echo line2 && echo line3'),
      );
      expect(resp.output, 'line1\nline2\nline3\n');
      expect(resp.exitCode, 0);
    });

    test('empty command', () async {
      await expectLater(
        s.execute(ctx, const ExecuteRequest(command: '')),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            contains('command is required'),
          ),
        ),
      );
    });

    test('non-zero exit code', () async {
      final resp = await s.execute(ctx, const ExecuteRequest(command: 'exit 1'));
      expect(resp.exitCode, 1);
      expect(resp.output, contains('non-zero code'));
    });

    test('non-zero exit code with stderr', () async {
      final resp = await s.execute(
        ctx,
        const ExecuteRequest(command: 'echo fail >&2 && exit 2'),
      );
      expect(resp.exitCode, 2);
      expect(resp.output, contains('non-zero code 2'));
      expect(resp.output, contains('fail'));
    });

    test('command not found', () async {
      final resp = await s.execute(
        ctx,
        const ExecuteRequest(command: 'nonexistent_command_xyz'),
      );
      expect(resp.exitCode, isNotNull);
      expect(resp.exitCode, isNot(0));
    });

    test('context cancellation', () async {
      final token = CancelToken()..cancel();
      await expectLater(
        s.execute(
          RunContext.background(cancelToken: token),
          const ExecuteRequest(command: 'sleep 10'),
        ),
        throwsA(isA<CancelledException>()),
      );
    });

    test('context cancellation during execution', () async {
      final stopwatch = Stopwatch()..start();
      await expectLater(
        s.execute(
          _cancelledAfter(const Duration(milliseconds: 5)),
          const ExecuteRequest(command: 'exec sleep 5'),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('LocalShell (port)', () {
    const s = LocalShell();

    test('a failure shows stdout and stderr in their sections', () async {
      final resp = await s.execute(
        ctx,
        const ExecuteRequest(command: 'echo out; echo err >&2; exit 3'),
      );
      expect(resp.exitCode, 3);
      expect(
        resp.output,
        'command exited with non-zero code 3\n[stdout]:\nout\n\n[stderr]:\nerr\n',
      );
    });

    test('a failure without output is the exit line alone', () async {
      final resp = await s.execute(ctx, const ExecuteRequest(command: 'exit 4'));
      expect(resp, const ExecuteResponse(output: 'command exited with non-zero code 4', exitCode: 4));
    });

    test('a success returns stdout only and drops stderr', () async {
      final resp = await s.execute(
        ctx,
        const ExecuteRequest(command: 'echo out; echo err >&2'),
      );
      expect(resp, const ExecuteResponse(output: 'out\n', exitCode: 0));
    });

    test('the command reads end-of-file from its standard input', () async {
      final resp = await s.execute(ctx, const ExecuteRequest(command: 'cat'));
      expect(resp, const ExecuteResponse(exitCode: 0));
    });

    test('a command killed by a signal has exit code -1, as in Go', () async {
      final resp = await s.execute(
        ctx,
        const ExecuteRequest(command: r'kill -TERM $$'),
      );
      expect(resp.exitCode, -1);
      expect(resp.output, 'command exited with non-zero code -1');
    });

    test('the command runs in the working directory of the process', () async {
      final resp = await s.execute(ctx, const ExecuteRequest(command: 'pwd -P'));
      expect(
        resp.output.trim(),
        Directory.current.resolveSymbolicLinksSync(),
      );
    });

    test('a cancellation kills the command', () async {
      final pidFile = '${dir.path}/pid';
      final run = s.execute(
        _cancelledAfter(const Duration(milliseconds: 20)),
        ExecuteRequest(command: 'echo \$\$ > "$pidFile"; exec sleep 5'),
      );
      await expectLater(run, throwsA(isA<CancelledException>()));
      // The command may not have written its pid before it was killed.
      if (File(pidFile).existsSync()) {
        final pid = int.parse(File(pidFile).readAsStringSync().trim());
        expect(await _eventually(() => !_isRunning(pid)), isTrue);
      }
    });

    test('validateCommand refuses a command before it runs', () async {
      final marker = '${dir.path}/marker';
      final seen = <String>[];
      final shell = LocalShell(
        validateCommand: (command) {
          seen.add(command);
          throw ThreepioException('command not allowed: $command');
        },
      );
      final command = 'touch "$marker"';
      await expectLater(
        shell.execute(ctx, ExecuteRequest(command: command)),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'command not allowed: $command',
          ),
        ),
      );
      await expectLater(
        shell.executeStreaming(ctx, ExecuteRequest(command: command)),
        throwsA(isA<ThreepioException>()),
      );
      expect(seen, [command, command]);
      expect(File(marker).existsSync(), isFalse);
    });

    test('validateCommand may be asynchronous', () async {
      final shell = LocalShell(
        validateCommand: (command) async {
          await Future<void>.delayed(Duration.zero);
          if (command.startsWith('rm')) {
            throw StateError('refused: $command');
          }
        },
      );
      expect(
        await shell.execute(ctx, const ExecuteRequest(command: 'echo ok')),
        const ExecuteResponse(output: 'ok\n', exitCode: 0),
      );
      await expectLater(
        shell.execute(ctx, const ExecuteRequest(command: 'rm -rf x')),
        throwsA(isA<StateError>()),
      );
    });

    test('an empty command is refused before validateCommand', () async {
      var called = false;
      final shell = LocalShell(validateCommand: (_) => called = true);
      await expectLater(
        shell.execute(ctx, const ExecuteRequest(command: '')),
        throwsA(isA<ThreepioException>()),
      );
      expect(called, isFalse);
    });

    test('streamed chunks are lines with their line breaks', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(command: r"printf 'a\nb\nc'"),
      );
      final result = await _drain(sr);
      expect(result.error, isNull);
      // A command that succeeded with output sends no exit code, as in Go.
      expect(result.responses, const [
        ExecuteResponse(output: 'a\n'),
        ExecuteResponse(output: 'b\n'),
        ExecuteResponse(output: 'c'),
      ]);
    });

    test('a streamed failure ends with the exit code and stderr', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(command: 'echo out; echo err >&2; exit 2'),
      );
      final result = await _drain(sr);
      expect(result.responses, const [
        ExecuteResponse(output: 'out\n'),
        ExecuteResponse(
          output: 'command exited with non-zero code 2\n[stderr]:\nerr\n',
          exitCode: 2,
        ),
      ]);
    });

    test('a streamed success without output is exit code 0 alone', () async {
      final sr = await s.executeStreaming(
        ctx,
        const ExecuteRequest(command: 'echo err >&2'),
      );
      expect((await _drain(sr)).responses, const [ExecuteResponse(exitCode: 0)]);
    });

    test('a cancelled context gives a stream with the cancellation', () async {
      final marker = '${dir.path}/marker';
      final token = CancelToken()..cancel('stop');
      final sr = await s.executeStreaming(
        RunContext.background(cancelToken: token),
        ExecuteRequest(command: 'touch "$marker"'),
      );
      final result = await _drain(sr);
      expect(result.responses, isEmpty);
      expect(
        result.error,
        isA<CancelledException>().having((e) => e.reason, 'reason', 'stop'),
      );
      expect(File(marker).existsSync(), isFalse);
    });

    test('a cancellation ends a silent streamed command', () async {
      final stopwatch = Stopwatch()..start();
      final sr = await s.executeStreaming(
        _cancelledAfter(const Duration(milliseconds: 5)),
        const ExecuteRequest(command: 'exec sleep 5'),
      );
      final result = await _drain(sr);
      expect(result.responses, isEmpty);
      expect(result.error, isA<CancelledException>());
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('closing the reader early lets the command run to its end', () async {
      final marker = '${dir.path}/done';
      final sr = await s.executeStreaming(
        ctx,
        ExecuteRequest(command: 'seq 1 5000; echo done > "$marker"'),
      );
      expect((await sr.recv()).output, '1\n');
      await sr.close();
      expect(await _eventually(() => File(marker).existsSync()), isTrue);
    });

    test('a background command drains its output and runs on', () async {
      final marker = '${dir.path}/done';
      final sr = await s.executeStreaming(
        ctx,
        ExecuteRequest(
          command: 'seq 1 100000; seq 1 1000 >&2; echo done > "$marker"',
          runInBackground: true,
        ),
      );
      expect((await _drain(sr)).responses, const [
        ExecuteResponse(output: 'command started in background\n', exitCode: 0),
      ]);
      expect(await _eventually(() => File(marker).existsSync()), isTrue);
    });

    test('a cancellation kills a background command', () async {
      final pidFile = File('${dir.path}/pid');
      final token = CancelToken();
      addTearDown(token.cancel);
      final sr = await s.executeStreaming(
        RunContext.background(cancelToken: token),
        ExecuteRequest(
          command: 'echo \$\$ > "${pidFile.path}"; exec sleep 5',
          runInBackground: true,
        ),
      );
      await _drain(sr);
      expect(
        await _eventually(
          () => pidFile.existsSync() && pidFile.readAsStringSync().endsWith('\n'),
        ),
        isTrue,
      );
      final pid = int.parse(pidFile.readAsStringSync().trim());
      expect(_isRunning(pid), isTrue);
      token.cancel();
      expect(await _eventually(() => !_isRunning(pid)), isTrue);
    });

    test('LocalFilesystemBackend runs commands through its shell', () async {
      final refused = <String>[];
      final backend = LocalFilesystemBackend(
        validateCommand: (command) {
          if (command.contains('forbidden')) {
            refused.add(command);
            throw ThreepioException('command not allowed: $command');
          }
        },
      );
      expect(
        await backend.execute(ctx, const ExecuteRequest(command: 'echo hi')),
        const ExecuteResponse(output: 'hi\n', exitCode: 0),
      );
      final sr = await backend.executeStreaming(
        ctx,
        const ExecuteRequest(command: 'echo a; echo b'),
      );
      expect(_outputs((await _drain(sr)).responses), ['a', 'b']);
      await expectLater(
        backend.execute(ctx, const ExecuteRequest(command: 'echo forbidden')),
        throwsA(isA<ThreepioException>()),
      );
      await expectLater(
        backend.executeStreaming(
          ctx,
          const ExecuteRequest(command: 'echo forbidden'),
        ),
        throwsA(isA<ThreepioException>()),
      );
      expect(refused, ['echo forbidden', 'echo forbidden']);
    });
  });
}
