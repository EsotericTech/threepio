// Port of eino-ext `components/tool/commandline/pyexecutor_test.go`
// (TestPyExecutor). Go's pyOperator becomes the in-memory
// FakeCommandLineOperator: nothing runs Python.
//
// The tests after it were written for the port: the exact tool info, the
// file and command the tool hands to the operator, Go's error messages and
// their wrapping, argument decoding (encoding/json's key matching), and
// cancellation passing through.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/component_type.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/components/tool/command_line/command_line_operator.dart';
import 'package:threepio_core/src/components/tool/command_line/py_executor_tool.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';

import 'fake_command_line_operator.dart';

final _pyFile = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.py$',
);

/// A fake operator whose every command ends with [output].
final class _PrintingOperator extends FakeCommandLineOperator {
  _PrintingOperator(this.output);

  final CommandLineOutput output;

  @override
  Future<CommandLineOutput> runCommand(
    RunContext ctx,
    List<String> command,
  ) async {
    await super.runCommand(ctx, command);
    return output;
  }
}

void main() {
  final ctx = RunContext.background();

  group('TestPyExecutor', () {
    test('answers with what the code printed', () async {
      const code = "print('hello world')";
      final op = _PrintingOperator(
        const CommandLineOutput(stdout: 'hello world\n'),
      );
      final exec = PyExecutorTool(PyExecutorConfig(operator: op));
      final result = await exec.invokableRun(ctx, '{"code": "$code"}');
      expect(result, 'hello world\n');
    });
  });

  group('tool info', () {
    test("Go's name, description and parameter", () async {
      final info = await PyExecutorTool(
        PyExecutorConfig(operator: FakeCommandLineOperator()),
      ).info();
      expect(info.name, 'python_execute');
      expect(
        info.desc,
        'Executes Python code string. Note: Only print outputs are visible, '
        'function return values are not captured. Use print statements to see '
        'results.',
      );
      // Go's jsonschema.Schema literal: no `required`, no
      // `additionalProperties`, `type` written last. Derived from the Go
      // code.
      expect(
        jsonEncode(info.function.parametersJsonSchema),
        '{"properties":{"code":{"description":"The Python code to execute.",'
        '"type":"string"}},"type":"object"}',
      );
      expect(info.paramsOneOf!.jsonSchemaMap, info.function.parametersJsonSchema);
      final schema = info.paramsOneOf!.toJsonSchema();
      expect(schema.properties.keys, ['code']);
      expect(schema.required, isEmpty);
    });

    test('no component type (Go has no GetType)', () {
      expect(
        componentTypeNameOf(
          PyExecutorTool(PyExecutorConfig(operator: FakeCommandLineOperator())),
        ),
        isNull,
      );
    });
  });

  group('execute', () {
    test('writes the code to a new <uuid>.py and runs python3 on it', () async {
      final op = _PrintingOperator(
        const CommandLineOutput(stdout: 'out', stderr: 'err', exitCode: 2),
      );
      final exec = PyExecutorTool(PyExecutorConfig(operator: op));
      expect(exec.command, 'python3');
      expect(PyExecutorTool.defaultCommand, 'python3');

      final output =
          await exec.execute(ctx, const PyExecutorInput(code: 'print(1)'));
      // The whole output, whatever the exit code.
      expect(
        output,
        const CommandLineOutput(stdout: 'out', stderr: 'err', exitCode: 2),
      );
      final (fileName, content) = op.writes.single;
      expect(fileName, matches(_pyFile));
      expect(content, 'print(1)');
      expect(op.commands.single, ['python3', fileName]);
      expect(op.calls, ['writeFile $fileName', 'runCommand python3 $fileName']);
      // The operator gets the caller's context, for its cancel token.
      expect(op.contexts, everyElement(same(ctx)));

      await exec.execute(ctx, const PyExecutorInput(code: 'print(2)'));
      expect(op.writes, hasLength(2));
      expect(op.writes.last.$1, isNot(fileName));
    });

    test('a configured command; an empty one is the default', () async {
      final op = _PrintingOperator(const CommandLineOutput(stdout: 'x'));
      final exec = PyExecutorTool(
        PyExecutorConfig(operator: op, command: '/usr/bin/python3.12'),
      );
      await exec.invokableRun(ctx, '{"code":"1"}');
      expect(op.commands.single.first, '/usr/bin/python3.12');
      expect(
        PyExecutorTool(PyExecutorConfig(operator: op, command: '')).command,
        'python3',
      );
    });
  });

  group('invokableRun errors', () {
    test('no standard output is an error, even with standard error', () async {
      final exec = PyExecutorTool(
        PyExecutorConfig(
          operator: _PrintingOperator(
            const CommandLineOutput(stderr: 'Traceback ...', exitCode: 1),
          ),
        ),
      );
      await expectLater(
        exec.invokableRun(ctx, '{"code":"raise"}'),
        throwsA(
          isA<ThreepioException>()
              .having((e) => e.message, 'message', 'execute result is empty'),
        ),
      );
    });

    test('a file that cannot be written', () async {
      final writeError = Exception('disk full');
      final op = FakeCommandLineOperator()..writeError = writeError;
      final exec = PyExecutorTool(PyExecutorConfig(operator: op));
      final error = await exec
          .invokableRun(ctx, '{"code":"1"}')
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(
        error,
        isA<ThreepioException>().having(
          (e) => e.message,
          'message',
          'execute error: failed to create python file: Exception: disk full',
        ),
      );
      expect(ThreepioException.findCause<Exception>(
        (error! as ThreepioException).cause,
      ), isNotNull);
      final inner = (error as ThreepioException).cause! as ThreepioException;
      expect(inner.message, 'failed to create python file: Exception: disk full');
      expect(inner.cause, same(writeError));
      expect(op.commands, isEmpty);
    });

    test('a command that cannot be run', () async {
      final op = FakeCommandLineOperator()
        ..runError = const ThreepioException('no python here');
      final exec = PyExecutorTool(PyExecutorConfig(operator: op));
      await expectLater(
        exec.invokableRun(ctx, '{"code":"1"}'),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'execute error: execute error: no python here',
          ),
        ),
      );
      await expectLater(
        exec.execute(ctx, const PyExecutorInput(code: '1')),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'execute error: no python here',
          ),
        ),
      );
    });

    test('a cancellation from the operator passes unchanged', () async {
      const cancelled = CancelledException('stop');
      final op = FakeCommandLineOperator()..runError = cancelled;
      final exec = PyExecutorTool(PyExecutorConfig(operator: op));
      await expectLater(
        exec.invokableRun(ctx, '{"code":"1"}'),
        throwsA(same(cancelled)),
      );
      op
        ..runError = null
        ..writeError = cancelled;
      await expectLater(
        exec.invokableRun(ctx, '{"code":"1"}'),
        throwsA(same(cancelled)),
      );
    });
  });

  group('arguments', () {
    late _PrintingOperator op;
    late PyExecutorTool exec;
    setUp(() {
      op = _PrintingOperator(const CommandLineOutput(stdout: 'ok'));
      exec = PyExecutorTool(PyExecutorConfig(operator: op));
    });

    Future<void> refused(String args, Object message) => expectLater(
          exec.invokableRun(ctx, args),
          throwsA(
            isA<ThreepioFormatException>()
                .having((e) => e.message, 'message', message),
          ),
        );

    test("decoding errors carry Go's messages", () async {
      await refused('{"code":', startsWith('extract argument fail: '));
      await refused('', startsWith('extract argument fail: '));
      await refused(
        '[]',
        'extract argument fail: json: cannot unmarshal array into Go value of '
            'type commandline.Input',
      );
      await refused(
        '{"code":5}',
        'extract argument fail: json: cannot unmarshal number into Go struct '
            'field Input.code of type string',
      );
      await refused(
        '{"code":["print(1)"]}',
        'extract argument fail: json: cannot unmarshal array into Go struct '
            'field Input.code of type string',
      );
      expect(op.calls, isEmpty);
    });

    test('null, missing code and unknown fields', () async {
      await exec.invokableRun(ctx, 'null');
      await exec.invokableRun(ctx, '{}');
      await exec.invokableRun(ctx, '{"code":null,"other":1}');
      expect(op.writes.map((w) => w.$2), ['', '', '']);
      await exec.invokableRun(ctx, jsonEncode({'code': 'a\n\tb'}));
      expect(op.writes.last.$2, 'a\n\tb');
    });

    test('the key matches ignoring case, as encoding/json does', () async {
      final longS = String.fromCharCode(0x017F);
      await exec.invokableRun(ctx, '{"CODE":"a"}');
      // A later key overwrites an earlier one; null changes nothing.
      await exec.invokableRun(ctx, '{"code":"a","Code":"b","cOdE":null}');
      expect(op.writes.map((w) => w.$2), ['a', 'b']);
      expect(PyExecutorInput.fromJson({'code$longS': 'x'}).code, '');
      // The first value of the wrong type fails, whatever follows.
      await refused(
        '{"Code":1,"code":"x"}',
        'extract argument fail: json: cannot unmarshal number into Go struct '
            'field Input.code of type string',
      );
    });

    test('run is invokableRun', () async {
      expect(await exec.run('{"code":"1"}'), 'ok');
    });

    test('the input type', () {
      expect(PyExecutorInput.fromJson(const {'code': 'x'}),
          const PyExecutorInput(code: 'x'));
      expect(const PyExecutorInput(code: 'x').toJson(), {'code': 'x'});
      expect(PyExecutorInput.fromJson(const {}).code, '');
      expect(
        () => PyExecutorInput.fromJson(const {'code': true}),
        throwsA(isA<ThreepioFormatException>().having(
          (e) => e.message,
          'message',
          'json: cannot unmarshal bool into Go struct field Input.code of type '
              'string',
        )),
      );
    });
  });
}
