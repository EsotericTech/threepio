/// The `python_execute` tool.
///
/// Port of eino-ext `components/tool/commandline/pyexecutor.go`.
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../../core/interrupt_signal.dart';
import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../schema/tool_info.dart';
import '../../model/cancel_token.dart';
import '../invokable_tool.dart';
import '../tool_options.dart';
import 'command_line_operator.dart';

/// The configuration of a [PyExecutorTool].
///
/// Port of eino-ext `commandline.PyExecutorConfig`.
@immutable
final class PyExecutorConfig {
  /// Runs Python code through [operator] with [command].
  const PyExecutorConfig({required this.operator, this.command});

  /// The program that runs the code file; `null` or empty means
  /// [PyExecutorTool.defaultCommand] (`python3`), as in Go.
  final String? command;

  /// Where the code file is written and the command runs.
  final CommandLineOperator operator;
}

/// The arguments of the `python_execute` tool.
///
/// Port of eino-ext `commandline.Input`.
@immutable
final class PyExecutorInput {
  /// Arguments that run [code].
  const PyExecutorInput({this.code = ''});

  /// Reads the tool's arguments the way Go's `encoding/json` does: the key
  /// `code` matches ignoring case (`bytes.EqualFold`) and a later key
  /// overwrites an earlier one, a missing or `null` `code` is empty, other
  /// fields are ignored, and a `code` that is not a string is a
  /// [ThreepioFormatException].
  factory PyExecutorInput.fromJson(Map<String, Object?> json) {
    var code = '';
    for (final MapEntry(:key, :value) in json.entries) {
      // Go: `null` leaves the field as it is.
      if (value == null || _goFoldedKey(key) != 'code') continue;
      if (value is! String) {
        throw ThreepioFormatException(
          'json: cannot unmarshal ${_goJsonKind(value)} into Go struct field '
          'Input.code of type string',
        );
      }
      code = value;
    }
    return PyExecutorInput(code: code);
  }

  /// The Python code to run.
  final String code;

  /// The JSON form (Go's field name).
  Map<String, Object?> toJson() => {'code': code};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is PyExecutorInput && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'PyExecutorInput($code)';
}

/// A tool that runs Python code and answers with what it printed.
///
/// Port of eino-ext `commandline.PyExecutor` (`NewPyExecutor`). For every
/// call the tool writes the code to a new file named `<uuid>.py` through its
/// [CommandLineOperator] (a relative path, so the operator decides where it
/// lands) and runs `<command> <uuid>.py` there. As in Go the file is not
/// deleted afterwards.
///
/// The model gets the command's standard output. Standard error and the
/// exit code are not passed on: a run that printed nothing to standard
/// output, including one that failed, makes the call throw
/// `execute result is empty`. [execute] gives the whole [CommandLineOutput].
///
/// Errors are Go's: `extract argument fail: …` for arguments that are not
/// the JSON object the tool takes ([ThreepioFormatException]),
/// `execute error: failed to create python file: …` when the operator cannot
/// write the file and `execute error: execute error: …` when it cannot run
/// the command (both [ThreepioException]s with the operator's exception as
/// the [ThreepioException.cause]). A [CancelledException] or an interrupt
/// from the operator is passed on unchanged.
final class PyExecutorTool extends InvokableTool {
  /// A tool configured by [config].
  ///
  /// Port of eino-ext `commandline.NewPyExecutor`. Go's checks for a missing
  /// config or operator are done by the type system here.
  PyExecutorTool(PyExecutorConfig config)
      : command = (config.command?.isEmpty ?? true)
            ? defaultCommand
            : config.command!,
        operator = config.operator;

  /// The name of the tool.
  static const String toolName = 'python_execute';

  /// The description of the tool, as the model sees it.
  static const String description =
      'Executes Python code string. Note: Only print outputs are visible, '
      'function return values are not captured. Use print statements to see '
      'results.';

  /// The command a config without one runs the code with (Go:
  /// `defaultPythonCommand`).
  static const String defaultCommand = 'python3';

  static const Uuid _uuid = Uuid();

  /// Go's `ToolInfo` literal: one string parameter, `code`, with no
  /// `required` and no `additionalProperties` (Go's `jsonschema.Schema`
  /// writes neither). Kept as a JSON Schema document, with the keys in the
  /// order Go writes them (`type` last), so that every provider sends the
  /// schema Go sends.
  static final ToolInfo _info = ToolInfo.fromJsonSchemaMap(
    name: toolName,
    desc: description,
    schema: const {
      'properties': {
        'code': {
          'description': 'The Python code to execute.',
          'type': 'string',
        },
      },
      'type': 'object',
    },
  );

  /// The program that runs the code file.
  final String command;

  /// Where the code file is written and the command runs.
  final CommandLineOperator operator;

  /// Port of `PyExecutor.Info`.
  @override
  Future<ToolInfo> info() async => _info;

  /// Writes [input]'s code to a new `<uuid>.py` file and runs it.
  ///
  /// Port of `PyExecutor.Execute`. Returns the command's output whatever its
  /// exit code. Throws `failed to create python file: …` when the file cannot
  /// be written and `execute error: …` when the command cannot be run.
  Future<CommandLineOutput> execute(
    RunContext ctx,
    PyExecutorInput input,
  ) async {
    final fileName = '${_uuid.v4()}.py';
    await _wrapping(
      'failed to create python file',
      () => operator.writeFile(ctx, fileName, input.code),
    );
    return _wrapping(
      'execute error',
      () => operator.runCommand(ctx, [command, fileName]),
    );
  }

  /// Port of `PyExecutor.InvokableRun`.
  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    final input = _decodeInput(argumentsJson);
    final result = await _wrapping('execute error', () => execute(ctx, input));
    if (result.stdout.isEmpty) {
      throw const ThreepioException('execute result is empty');
    }
    return result.stdout;
  }

  /// The same as [invokableRun] with a context that is never cancelled, for
  /// code that still calls the tool the old way.
  @override
  Future<String> run(String argumentsJson) =>
      invokableRun(RunContext.background(), argumentsJson);
}

/// Go's `json.Unmarshal([]byte(argumentsInJSON), &Input{})` and its
/// `extract argument fail: %w`.
PyExecutorInput _decodeInput(String argumentsJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(argumentsJson);
  } on FormatException catch (error) {
    throw ThreepioFormatException(
      'extract argument fail: ${error.message}',
      source: argumentsJson,
      offset: error.offset,
      cause: error,
    );
  }
  // Go: `null` leaves the struct as it is.
  if (decoded == null) return const PyExecutorInput();
  if (decoded is! Map<String, Object?>) {
    throw ThreepioFormatException(
      'extract argument fail: json: cannot unmarshal ${_goJsonKind(decoded)} '
      'into Go value of type commandline.Input',
      source: argumentsJson,
    );
  }
  try {
    return PyExecutorInput.fromJson(decoded);
  } on ThreepioFormatException catch (error) {
    throw ThreepioFormatException(
      'extract argument fail: ${error.message}',
      source: argumentsJson,
      cause: error,
    );
  }
}

/// Runs [action] and wraps what it throws as Go's `fmt.Errorf("<prefix>:
/// %w", err)` does; cancellations and interrupts pass unchanged.
Future<T> _wrapping<T>(String prefix, Future<T> Function() action) async {
  try {
    return await action();
  } on CancelledException {
    rethrow;
  } on Exception catch (error) {
    if (isInterrupt(error)) rethrow;
    throw ThreepioException('$prefix: ${_errorText(error)}', cause: error);
  }
}

/// The text of [error] as Go's `err.Error()` would give it.
String _errorText(Exception error) =>
    error is ThreepioException ? error.message : '$error';

/// [key] folded the way Go's `encoding/json` matches object keys with field
/// names when none matches exactly (`bytes.EqualFold`). The field names here
/// are lower-case ASCII, so only the runes that fold to ASCII letters
/// matter: `A`-`Z`, the Kelvin sign (`k`) and the long s (`s`).
String _goFoldedKey(String key) {
  final buffer = StringBuffer();
  for (final rune in key.runes) {
    buffer.writeCharCode(switch (rune) {
      >= 0x41 && <= 0x5A => rune + 0x20,
      0x212A => 0x6B,
      0x017F => 0x73,
      _ => rune,
    });
  }
  return buffer.toString();
}

/// The name Go's `encoding/json` gives the kind of a JSON value in its type
/// errors.
String _goJsonKind(Object? value) => switch (value) {
      String() => 'string',
      bool() => 'bool',
      num() => 'number',
      List<Object?>() => 'array',
      _ => 'object',
    };
