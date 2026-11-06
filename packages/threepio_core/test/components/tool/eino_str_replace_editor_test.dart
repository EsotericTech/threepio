// Port of eino-ext `components/tool/commandline/editor_test.go`:
// TestNewStrReplaceEditor, TestStrReplaceEditor_ValidatePath,
// TestStrReplaceEditor_View, TestStrReplaceEditor_Create,
// TestStrReplaceEditor_StrReplace, TestStrReplaceEditor_Insert,
// TestStrReplaceEditor_UndoEdit, TestTruncate, TestExpandTabs,
// TestStrReplaceEditor_InvalidCommand. Go's testify mock is replaced by an
// in-memory FakeCommandLineOperator. TestStrReplaceEditor_InvalidCommand goes
// through invokableRun: the Dart command is an enum, so only arguments can
// name an unknown one.
//
// The groups after the ported ones were written for the port: the exact tool
// info and outputs (derived from editor.go, not copied from a Go test), every
// command's errors, the history, and argument decoding (encoding/json's key
// matching and type errors).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/component_type.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/components/tool/command_line/command_line_operator.dart';
import 'package:threepio_core/src/components/tool/command_line/str_replace_editor_tool.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';

import 'fake_command_line_operator.dart';

const _fiveLines = 'line 1\nline 2\nline 3\nline 4\nline 5';
const _cat = "Here's the result of running `cat -n` on";

/// `%6d\t<line>` for each line, numbered from [first], joined with `\n`.
String _numbered(List<String> lines, [int first = 1]) => [
      for (var i = 0; i < lines.length; i++)
        '${'${i + first}'.padLeft(6)}\t${lines[i]}',
    ].join('\n');

Matcher _threepio(Object message) => isA<ThreepioException>()
    .having((e) => e.message, 'message', message);

void main() {
  final ctx = RunContext.background();

  StrReplaceEditorTool editorOver(FakeCommandLineOperator operator) =>
      StrReplaceEditorTool(StrReplaceEditorConfig(operator: operator));

  group('TestNewStrReplaceEditor', () {
    test('creates an editor', () async {
      final editor = editorOver(FakeCommandLineOperator());
      final info = await editor.info();
      expect(info.name, 'str_replace_editor');
      expect(info.desc, isNotEmpty);
    });
  });

  group('TestStrReplaceEditor_ValidatePath', () {
    test('checks paths as Go validatePath does', () async {
      final operator = FakeCommandLineOperator(
        files: {'/valid/file.txt': ''},
        directories: {'/valid/dir'},
      );
      final editor = editorOver(operator);

      // valid file path
      await editor.validatePath(
          ctx, StrReplaceEditorCommand.view, '/valid/file.txt');
      // valid directory path with view command
      await editor.validatePath(ctx, StrReplaceEditorCommand.view, '/valid/dir');
      // valid directory path with non-view command
      await expectLater(
        editor.validatePath(
            ctx, StrReplaceEditorCommand.strReplace, '/valid/dir'),
        throwsA(_threepio(contains('is a directory'))),
      );
      // non-existent path
      await expectLater(
        editor.validatePath(
            ctx, StrReplaceEditorCommand.view, '/nonexistent/file.txt'),
        throwsA(_threepio(contains('does not exist'))),
      );
      // relative path
      await expectLater(
        editor.validatePath(
            ctx, StrReplaceEditorCommand.view, 'relative/path.txt'),
        throwsA(_threepio(contains('not an absolute path'))),
      );
      // create command with new file
      await editor.validatePath(
          ctx, StrReplaceEditorCommand.create, '/new/file.txt');
      // create command with existing file
      await expectLater(
        editor.validatePath(
            ctx, StrReplaceEditorCommand.create, '/valid/file.txt'),
        throwsA(_threepio(contains('file already exists'))),
      );
    });

    test("Go's messages", () async {
      final editor = editorOver(FakeCommandLineOperator(directories: {'/d'}));
      await expectLater(
        editor.validatePath(ctx, StrReplaceEditorCommand.insert, '/d'),
        throwsA(_threepio('path /d is a directory, only the `view` command '
            'can be used on directories')),
      );
      await expectLater(
        editor.validatePath(ctx, StrReplaceEditorCommand.undoEdit, '/x'),
        throwsA(_threepio('path /x does not exist. Please provide a valid '
            'path')),
      );
      await expectLater(
        editor.validatePath(ctx, StrReplaceEditorCommand.view, 'x'),
        throwsA(_threepio('path x is not an absolute path')),
      );
      await expectLater(
        editor.validatePath(ctx, StrReplaceEditorCommand.create, '/d'),
        throwsA(_threepio('file already exists at: /d. Cannot use `create` '
            'command to overwrite files')),
      );
    });
  });

  group('TestStrReplaceEditor_View', () {
    test('views files and directories', () async {
      final operator = FakeCommandLineOperator(
        files: {'/test/file.txt': _fiveLines},
        directories: {'/test/dir'},
        commandOutputs: {
          r'find /test/dir -maxdepth 2 -not -path */\.*':
              const CommandLineOutput(
            stdout: '/test/dir\n/test/dir/file1.txt\n/test/dir/file2.txt',
          ),
        },
      );
      final editor = editorOver(operator);

      // view file
      var result = await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.view,
          path: '/test/file.txt',
        ),
      );
      expect(result, contains('line 1'));
      expect(result, contains('line 5'));
      // The operator gets the caller's context, for its cancel token.
      expect(operator.contexts, everyElement(same(ctx)));

      // view file with range
      result = await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.view,
          path: '/test/file.txt',
          viewRange: const [2, 4],
        ),
      );
      expect(result, contains('line 2'));
      expect(result, contains('line 3'));
      expect(result, isNot(contains('line 1')));
      expect(result, isNot(contains('line 5')));

      // view directory
      result = await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.view,
          path: '/test/dir',
        ),
      );
      expect(result, contains('/test/dir/file1.txt'));
      expect(result, contains('/test/dir/file2.txt'));

      // view directory with range (should fail)
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(
            command: StrReplaceEditorCommand.view,
            path: '/test/dir',
            viewRange: const [1, 2],
          ),
        ),
        throwsA(_threepio(contains('view_range'))),
      );
    });
  });

  group('TestStrReplaceEditor_Create', () {
    test('creates a file', () async {
      final operator = FakeCommandLineOperator();
      final result = await editorOver(operator).execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.create,
          path: '/test/new_file.txt',
          fileText: 'test content',
        ),
      );
      expect(result, contains('successfully created'));
      expect(operator.writes, [('/test/new_file.txt', 'test content')]);
    });
  });

  group('TestStrReplaceEditor_StrReplace', () {
    test('replaces, and refuses what Go refuses', () async {
      final operator =
          FakeCommandLineOperator(files: {'/test/file.txt': _fiveLines});
      final editor = editorOver(operator);

      final result = await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.strReplace,
          path: '/test/file.txt',
          oldStr: 'line 2\nline 3',
          newStr: 'replaced line 2\nreplaced line 3',
        ),
      );
      expect(result, contains('has been edited'));
      expect(result, contains('replaced line 2'));

      // without old_str
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(
            command: StrReplaceEditorCommand.strReplace,
            path: '/test/file.txt',
            newStr: 'replaced line 2\nreplaced line 3',
          ),
        ),
        throwsA(_threepio(contains('old_str'))),
      );

      // with an old_str that is not there
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(
            command: StrReplaceEditorCommand.strReplace,
            path: '/test/file.txt',
            oldStr: 'non-existent',
            newStr: 'replaced line 2\nreplaced line 3',
          ),
        ),
        throwsA(_threepio(contains('does not appear verbatim'))),
      );
    });
  });

  group('TestStrReplaceEditor_Insert', () {
    test('inserts, and refuses what Go refuses', () async {
      final operator =
          FakeCommandLineOperator(files: {'/test/file.txt': _fiveLines});
      final editor = editorOver(operator);

      final result = await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.insert,
          path: '/test/file.txt',
          insertLine: 2,
          newStr: 'inserted line',
        ),
      );
      expect(result, contains('has been edited'));
      expect(result, contains('inserted line'));

      // without insert_line
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(
            command: StrReplaceEditorCommand.insert,
            path: '/test/file.txt',
            newStr: 'inserted line',
          ),
        ),
        throwsA(_threepio(contains('insert_line'))),
      );

      // without new_str
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(
            command: StrReplaceEditorCommand.insert,
            path: '/test/file.txt',
            insertLine: 2,
          ),
        ),
        throwsA(_threepio(contains('new_str'))),
      );

      // with a line out of range
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(
            command: StrReplaceEditorCommand.insert,
            path: '/test/file.txt',
            insertLine: 10,
            newStr: 'inserted line',
          ),
        ),
        throwsA(_threepio(contains('invalid `insert_line`'))),
      );
    });
  });

  group('TestStrReplaceEditor_UndoEdit', () {
    test('undoes the last edit', () async {
      final operator =
          FakeCommandLineOperator(files: {'/test/file.txt': _fiveLines});
      final editor = editorOver(operator);

      await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.strReplace,
          path: '/test/file.txt',
          oldStr: 'line 2\nline 3',
          newStr: 'replaced line 2\nreplaced line 3',
        ),
      );
      final result = await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.undoEdit,
          path: '/test/file.txt',
        ),
      );
      expect(result, contains('Successfully undid'));
      expect(result, contains('line 2'));
      expect(result, isNot(contains('replaced line 2')));
    });
  });

  group('TestTruncate', () {
    test('cuts after the given length', () {
      final longContent = 'a' * 100;
      expect(StrReplaceEditorTool.truncate(longContent, 0), longContent);
      expect(StrReplaceEditorTool.truncate(longContent, 200), longContent);
      expect(
        StrReplaceEditorTool.truncate(longContent, 50),
        longContent.substring(0, 50) + StrReplaceEditorTool.truncatedMessage,
      );
    });
  });

  group('TestExpandTabs', () {
    test('replaces each tab with four spaces', () {
      expect(
        StrReplaceEditorTool.expandTabs('line\twith\ttabs'),
        'line    with    tabs',
      );
    });
  });

  group('TestStrReplaceEditor_InvalidCommand', () {
    test('an unknown command is refused', () async {
      final editor = editorOver(FakeCommandLineOperator());
      await expectLater(
        editor.invokableRun(
          ctx,
          '{"command":"invalid_command","path":"/test/file.txt"}',
        ),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'unrecognized command invalid_command. Allowed commands are: '
                'view, create, str_replace, insert, undo_edit',
          ),
        ),
      );
    });
  });

  group('tool info', () {
    test("Go's name, description and parameters", () async {
      final info = await editorOver(FakeCommandLineOperator()).info();
      expect(info.name, StrReplaceEditorTool.toolName);
      final desc = info.desc!;
      expect(desc, StrReplaceEditorTool.description);
      // Measured on Go's StrReplaceEditorDescription: 988 bytes (all
      // ASCII), 10 line breaks, no line break at the end.
      expect(desc.length, 988);
      expect('\n'.allMatches(desc), hasLength(10));
      expect(
        desc,
        startsWith('Custom editing tool for viewing, creating and editing '
            'files\n* State is persistent'),
      );
      expect(
        desc,
        contains("'path'\n\nNotes for using the 'str_replace' command:\n"),
      );
      expect(
        desc,
        endsWith("edited lines that should replace the 'old_str'"),
      );

      // Go's jsonschema.Schema literal: `required` but no
      // `additionalProperties`, and the keys in the order jsonschema.Schema
      // writes them (`enum`/`items` before `description`, `type` last).
      // Derived from the Go code.
      expect(
        jsonEncode(info.function.parametersJsonSchema),
        '{"properties":{'
        '"command":{"enum":["view","create","str_replace","insert","undo_edit"],'
        '"description":"The commands to run. Allowed options are: `view`, '
        '`create`, `str_replace`, `insert`, `undo_edit`.","type":"string"},'
        '"path":{"description":"Absolute path to file or directory.",'
        '"type":"string"},'
        '"file_text":{"description":"Required parameter of `create` command, '
        'with the content of the file to be created.","type":"string"},'
        '"old_str":{"description":"Required parameter of `str_replace` command '
        'containing the string in `path` to replace.","type":"string"},'
        '"new_str":{"description":"Optional parameter of `str_replace` command '
        'containing the new string (if not given, no string will be added). '
        'Required parameter of `insert` command containing the string to '
        'insert.","type":"string"},'
        '"insert_line":{"description":"Required parameter of `insert` command. '
        'The `new_str` will be inserted AFTER the line `insert_line` of '
        '`path`.","type":"integer"},'
        '"view_range":{"items":{"type":"integer"},"description":"Optional '
        'parameter of `view` command when `path` points to a file. If none is '
        'given, the full file is shown. If provided, the file will be shown in '
        'the indicated line number range, e.g. [11, 12] will show lines 11 and '
        '12. Indexing at 1 to start. Setting `[start_line, -1]` shows all lines '
        'from `start_line` to the end of the file.","type":"array"}'
        '},"required":["command","path"],"type":"object"}',
      );
      expect(info.paramsOneOf!.jsonSchemaMap, info.function.parametersJsonSchema);
      // The JSONSchema view of it, for code that reads `parameters`.
      final schema = info.paramsOneOf!.toJsonSchema();
      expect(schema.required, ['command', 'path']);
      expect(schema.properties.keys, [
        'command',
        'path',
        'file_text',
        'old_str',
        'new_str',
        'insert_line',
        'view_range',
      ]);
      expect(schema.properties['command']!.enumValues,
          ['view', 'create', 'str_replace', 'insert', 'undo_edit']);
      expect(schema.properties['view_range']!.items!.type, 'integer');
    });

    test("Go's constants, and no component type (Go has no GetType)", () {
      expect(StrReplaceEditorTool.snippetLines, 4);
      expect(StrReplaceEditorTool.maxResponseLen, 16000);
      expect(
        StrReplaceEditorTool.truncatedMessage,
        '<response clipped><NOTE>To save on context only part of this file has '
        'been shown to you. You should retry this tool after you have searched '
        'inside the file with `grep -n` in order to find the line numbers of '
        'what you are looking for.</NOTE>',
      );
      expect(componentTypeNameOf(editorOver(FakeCommandLineOperator())), isNull);
      expect(
        StrReplaceEditorCommand.values.map((c) => c.value),
        ['view', 'create', 'str_replace', 'insert', 'undo_edit'],
      );
      expect(StrReplaceEditorCommand.tryParse('undo_edit'),
          StrReplaceEditorCommand.undoEdit);
      expect(StrReplaceEditorCommand.tryParse('View'), isNull);
    });
  });

  group('view', () {
    late FakeCommandLineOperator operator;
    late StrReplaceEditorTool editor;
    setUp(() {
      operator = FakeCommandLineOperator(files: {'/f': _fiveLines});
      editor = editorOver(operator);
    });

    Future<String> view(List<int>? range) => editor.execute(
          ctx,
          StrReplaceEditorParams(
            command: StrReplaceEditorCommand.view,
            path: '/f',
            viewRange: range,
          ),
        );

    test('a whole file, as cat -n', () async {
      expect(
        await view(null),
        '$_cat /f:\n${_numbered(_fiveLines.split('\n'))}\n',
      );
      expect(await view([]), await view(null));
      expect(operator.calls.take(2), ['isDirectory /f', 'readFile /f']);
    });

    test('a range is numbered from its first line (Go numbers it from 1, a '
        'shadowed variable)', () async {
      expect(
        await view([2, 4]),
        '$_cat /f:\n${_numbered(['line 2', 'line 3', 'line 4'], 2)}\n',
      );
      expect(
        await view([3, -1]),
        '$_cat /f:\n${_numbered(['line 3', 'line 4', 'line 5'], 3)}\n',
      );
      expect(await view([5, 5]), '$_cat /f:\n${_numbered(['line 5'], 5)}\n');
      expect(
        await view([1, 2]),
        '$_cat /f:\n${_numbered(['line 1', 'line 2'])}\n',
      );
    });

    test('range errors', () async {
      Future<void> refused(List<int> range, String message) => expectLater(
            view(range),
            throwsA(_threepio(message)),
          );
      await refused(
        [1, 2, 3],
        'invalid `view_range`, it should be a list of two integers',
      );
      await refused(
        [0, 2],
        'invalid `view_range`: [0 2]. Its first element `0` should be within '
        "the file's line range: [1, 5]",
      );
      await refused(
        [6, 7],
        'invalid `view_range`: [6 7]. Its first element `6` should be within '
        "the file's line range: [1, 5]",
      );
      await refused(
        [2, 6],
        'invalid `view_range`: [2 6]. Its second element `6` should be less '
        'than the number of lines in the file: `5`',
      );
      await refused(
        [4, 2],
        'invalid `view_range`: [4 2]. Its second element `2` should be greater '
        'than or equal to its first `4`',
      );
      await refused(
        [4, -2],
        'invalid `view_range`: [4 -2]. Its second element `-2` should be '
        'greater than or equal to its first `4`',
      );
    });

    test('a directory is listed by find, run by the operator', () async {
      operator
        ..directories.add('/d')
        ..commandOutputs[r'find /d -maxdepth 2 -not -path */\.*'] =
            const CommandLineOutput(
          stdout: '/d\n/d/a\n',
          stderr: 'ignored',
          exitCode: 1,
        );
      final result = await editor.execute(
        ctx,
        StrReplaceEditorParams(command: StrReplaceEditorCommand.view, path: '/d'),
      );
      expect(result, '/d\n/d/a\n');
      expect(operator.commands.single, [
        'find',
        '/d',
        '-maxdepth',
        '2',
        '-not',
        '-path',
        r'*/\.*',
      ]);
    });

    test('tabs are expanded and long content is clipped', () async {
      operator.files['/t'] = 'a\tb';
      expect(
        await editor.execute(
          ctx,
          StrReplaceEditorParams(command: StrReplaceEditorCommand.view, path: '/t'),
        ),
        '$_cat /t:\n     1\ta    b\n',
      );
      operator.files['/big'] = 'x' * 16010;
      expect(
        await editor.execute(
          ctx,
          StrReplaceEditorParams(
              command: StrReplaceEditorCommand.view, path: '/big'),
        ),
        '$_cat /big:\n     1\t${'x' * 16000}'
        '${StrReplaceEditorTool.truncatedMessage}\n',
      );
    });

    test('the path is not checked (Go never calls validatePath)', () async {
      operator.files['relative.txt'] = 'r';
      expect(
        await editor.execute(
          ctx,
          StrReplaceEditorParams(
            command: StrReplaceEditorCommand.view,
            path: 'relative.txt',
          ),
        ),
        '$_cat relative.txt:\n     1\tr\n',
      );
      expect(operator.calls, isNot(contains('exists relative.txt')));
    });
  });

  group('create', () {
    test("Go's message, and the content goes into the history", () async {
      final operator = FakeCommandLineOperator(files: {'/f': 'old'});
      final editor = editorOver(operator);
      // As in Go, create does not refuse an existing file.
      expect(
        await editor.execute(
          ctx,
          StrReplaceEditorParams(
            command: StrReplaceEditorCommand.create,
            path: '/f',
            fileText: 'new\ttext',
          ),
        ),
        'file successfully created at: /f',
      );
      expect(operator.files['/f'], 'new\ttext');
      // Undo writes the created content again: Go records it, not the old.
      expect(
        await editor.execute(
          ctx,
          StrReplaceEditorParams(command: StrReplaceEditorCommand.undoEdit, path: '/f'),
        ),
        'Successfully undid last edit to /f. $_cat /f:\n     1\tnew    text\n',
      );
      expect(operator.files['/f'], 'new\ttext');
    });

    test('file_text is required; an empty one is not missing', () async {
      final operator = FakeCommandLineOperator();
      final editor = editorOver(operator);
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(command: StrReplaceEditorCommand.create, path: '/f'),
        ),
        throwsA(_threepio(
            'parameter `file_text` is required for create command')),
      );
      await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.create,
          path: '/f',
          fileText: '',
        ),
      );
      expect(operator.files['/f'], '');
    });
  });

  group('str_replace', () {
    test('the snippet of a small file is the whole file', () async {
      final operator = FakeCommandLineOperator(files: {'/f': _fiveLines});
      final result = await editorOver(operator).execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.strReplace,
          path: '/f',
          oldStr: 'line 2\nline 3',
          newStr: 'replaced line 2\nreplaced line 3',
        ),
      );
      final lines = [
        'line 1',
        'replaced line 2',
        'replaced line 3',
        'line 4',
        'line 5',
      ];
      expect(
        result,
        'File /f has been edited. $_cat a snippet of /f:\n'
        '${_numbered(lines)}\n'
        'Check the changes and make sure they are as expected. Edit the file '
        'again if necessary.',
      );
      expect(operator.files['/f'], lines.join('\n'));
    });

    test('the snippet shows four lines around the edit', () async {
      final lines = [for (var i = 1; i <= 15; i++) 'l$i'];
      final operator = FakeCommandLineOperator(files: {'/f': lines.join('\n')});
      final result = await editorOver(operator).execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.strReplace,
          path: '/f',
          oldStr: 'l8',
          newStr: 'L8',
        ),
      );
      // replacementLine 7: lines 3..11 (0-based), numbered from 4.
      expect(
        result,
        'File /f has been edited. $_cat a snippet of /f:\n'
        '${_numbered(['l4', 'l5', 'l6', 'l7', 'L8', 'l9', 'l10', 'l11', 'l12'], 4)}\n'
        'Check the changes and make sure they are as expected. Edit the file '
        'again if necessary.',
      );
    });

    test('without new_str the text is removed', () async {
      final operator = FakeCommandLineOperator(files: {'/f': 'keep drop keep'});
      await editorOver(operator).execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.strReplace,
          path: '/f',
          oldStr: 'drop ',
        ),
      );
      expect(operator.files['/f'], 'keep keep');
    });

    test('tabs of the whole file are expanded', () async {
      final operator = FakeCommandLineOperator(files: {'/f': 'a\tb\nc'});
      final editor = editorOver(operator);
      await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.strReplace,
          path: '/f',
          oldStr: 'c',
          newStr: 'd\te',
        ),
      );
      expect(operator.files['/f'], 'a    b\nd    e');
      // The history holds the expanded original.
      await editor.execute(
        ctx,
        StrReplaceEditorParams(command: StrReplaceEditorCommand.undoEdit, path: '/f'),
      );
      expect(operator.files['/f'], 'a    b\nc');
    });

    test('an old_str found several times is refused with its lines', () async {
      final operator = FakeCommandLineOperator(files: {
        '/f': 'foo\nbar foo\nbaz\nfoo',
        '/m': 'a\nb\na\nb',
        '/e': 'ab\ncd',
      });
      final editor = editorOver(operator);
      Future<void> refused(String path, String oldStr, String message) =>
          expectLater(
            editor.execute(
              ctx,
              StrReplaceEditorParams(
                command: StrReplaceEditorCommand.strReplace,
                path: path,
                oldStr: oldStr,
                newStr: 'x',
              ),
            ),
            throwsA(_threepio(message)),
          );
      await refused(
        '/f',
        'foo',
        'replacement not performed. old_str `foo` appears multiple times at '
        'lines [1 2 4]. please ensure it is unique',
      );
      // No single line holds a multi-line old_str: Go's list is empty.
      await refused(
        '/m',
        'a\nb',
        'replacement not performed. old_str `a\nb` appears multiple times at '
        'lines []. please ensure it is unique',
      );
      // Go counts an empty string once per character, plus one.
      await refused(
        '/e',
        '',
        'replacement not performed. old_str `` appears multiple times at '
        'lines [1 2]. please ensure it is unique',
      );
      await refused(
        '/f',
        'qux',
        'replacement not performed, old_str `qux` does not appear verbatim in '
        '/f',
      );
      expect(operator.writes, isEmpty);
    });

    test('an empty old_str in an empty file inserts new_str', () async {
      final operator = FakeCommandLineOperator(files: {'/f': ''});
      final result = await editorOver(operator).execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.strReplace,
          path: '/f',
          oldStr: '',
          newStr: 'x\ny',
        ),
      );
      expect(operator.files['/f'], 'x\ny');
      expect(result, contains('$_cat a snippet of /f:\n     1\tx\n     2\ty\n'));
    });
  });

  group('insert', () {
    test("Go's snippet at the top of a file", () async {
      final operator = FakeCommandLineOperator(files: {'/f': _fiveLines});
      final result = await editorOver(operator).execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.insert,
          path: '/f',
          insertLine: 2,
          newStr: 'inserted line',
        ),
      );
      final lines = [
        'line 1',
        'line 2',
        'inserted line',
        'line 3',
        'line 4',
        'line 5',
      ];
      expect(
        result,
        'File /f has been edited. $_cat a snippet of the edited file:\n'
        '${_numbered(lines)}\n'
        'Check the changes and make sure they are as expected (correct '
        'indentation, no duplicate lines, etc). Edit the file again if '
        'necessary.',
      );
      expect(operator.files['/f'], lines.join('\n'));
    });

    test('the snippet shows four lines before and after', () async {
      final lines = [for (var i = 1; i <= 15; i++) 'l$i'];
      final operator = FakeCommandLineOperator(files: {'/f': lines.join('\n')});
      final result = await editorOver(operator).execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.insert,
          path: '/f',
          insertLine: 10,
          newStr: 'new a\nnew\tb',
        ),
      );
      expect(
        result,
        contains(
          '$_cat a snippet of the edited file:\n'
          '${_numbered(['l7', 'l8', 'l9', 'l10', 'new a', 'new    b', 'l11', 'l12', 'l13', 'l14'], 7)}\n',
        ),
      );
      expect(
        operator.files['/f'],
        [...lines.take(10), 'new a', 'new    b', ...lines.skip(10)].join('\n'),
      );
    });

    test('at 0 and at the end', () async {
      final operator = FakeCommandLineOperator(files: {'/f': 'a\nb'});
      final editor = editorOver(operator);
      await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.insert,
          path: '/f',
          insertLine: 0,
          newStr: 'first',
        ),
      );
      expect(operator.files['/f'], 'first\na\nb');
      final result = await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.insert,
          path: '/f',
          insertLine: 3,
          newStr: '',
        ),
      );
      expect(operator.files['/f'], 'first\na\nb\n');
      expect(
        result,
        contains('$_cat a snippet of the edited file:\n'
            '${_numbered(['first', 'a', 'b', ''])}\n'),
      );
    });

    test('a line out of range', () async {
      final editor =
          editorOver(FakeCommandLineOperator(files: {'/f': _fiveLines}));
      for (final line in [-1, 6]) {
        await expectLater(
          editor.execute(
            ctx,
            StrReplaceEditorParams(
              command: StrReplaceEditorCommand.insert,
              path: '/f',
              insertLine: line,
              newStr: 'x',
            ),
          ),
          throwsA(_threepio('invalid `insert_line` parameter: $line. It '
              "should be within the file's line range: [0, 5]")),
        );
      }
    });
  });

  group('undo_edit', () {
    test('steps back through the history, then has none', () async {
      final operator = FakeCommandLineOperator(files: {'/f': 'one'});
      final editor = editorOver(operator);
      Future<String> replace(String oldStr, String newStr) => editor.execute(
            ctx,
            StrReplaceEditorParams(
              command: StrReplaceEditorCommand.strReplace,
              path: '/f',
              oldStr: oldStr,
              newStr: newStr,
            ),
          );
      Future<String> undo() => editor.execute(
            ctx,
            StrReplaceEditorParams(
                command: StrReplaceEditorCommand.undoEdit, path: '/f'),
          );

      await replace('one', 'two');
      await replace('two', 'three');
      expect(await undo(),
          'Successfully undid last edit to /f. $_cat /f:\n     1\ttwo\n');
      expect(operator.files['/f'], 'two');
      expect(await undo(),
          'Successfully undid last edit to /f. $_cat /f:\n     1\tone\n');
      expect(operator.files['/f'], 'one');
      await expectLater(
        undo(),
        throwsA(_threepio('no edit history found for /f')),
      );
    });

    test('a path never edited has no history', () async {
      await expectLater(
        editorOver(FakeCommandLineOperator()).execute(
          ctx,
          StrReplaceEditorParams(
              command: StrReplaceEditorCommand.undoEdit, path: '/x'),
        ),
        throwsA(_threepio('no edit history found for /x')),
      );
    });

    test('the history is per tool', () async {
      final operator = FakeCommandLineOperator(files: {'/f': 'a'});
      await editorOver(operator).execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.strReplace,
          path: '/f',
          oldStr: 'a',
          newStr: 'b',
        ),
      );
      await expectLater(
        editorOver(operator).execute(
          ctx,
          StrReplaceEditorParams(
              command: StrReplaceEditorCommand.undoEdit, path: '/f'),
        ),
        throwsA(_threepio('no edit history found for /f')),
      );
    });
  });

  group('operator errors', () {
    test('are passed on unchanged', () async {
      final readError = Exception('read failed');
      final operator = FakeCommandLineOperator(files: {'/f': 'a'})
        ..readError = readError;
      final editor = editorOver(operator);
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(command: StrReplaceEditorCommand.view, path: '/f'),
        ),
        throwsA(same(readError)),
      );
      operator.readError = null;
      final writeError = Exception('write failed');
      operator.writeError = writeError;
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(
            command: StrReplaceEditorCommand.strReplace,
            path: '/f',
            oldStr: 'a',
            newStr: 'b',
          ),
        ),
        throwsA(same(writeError)),
      );
      // A failed write is not recorded.
      operator.writeError = null;
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(
              command: StrReplaceEditorCommand.undoEdit, path: '/f'),
        ),
        throwsA(_threepio('no edit history found for /f')),
      );
      const cancelled = CancelledException('stop');
      operator.isDirectoryError = cancelled;
      await expectLater(
        editor.execute(
          ctx,
          StrReplaceEditorParams(command: StrReplaceEditorCommand.view, path: '/f'),
        ),
        throwsA(same(cancelled)),
      );
    });

    test('an undo whose write fails still drops the entry, as in Go', () async {
      final operator = FakeCommandLineOperator(files: {'/f': 'a'});
      final editor = editorOver(operator);
      await editor.execute(
        ctx,
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.strReplace,
          path: '/f',
          oldStr: 'a',
          newStr: 'b',
        ),
      );
      operator.writeError = Exception('write failed');
      final undo = StrReplaceEditorParams(
          command: StrReplaceEditorCommand.undoEdit, path: '/f');
      await expectLater(editor.execute(ctx, undo), throwsException);
      operator.writeError = null;
      await expectLater(
        editor.execute(ctx, undo),
        throwsA(_threepio('no edit history found for /f')),
      );
    });
  });

  group('arguments', () {
    late FakeCommandLineOperator operator;
    late StrReplaceEditorTool editor;
    setUp(() {
      operator = FakeCommandLineOperator(files: {'/f': _fiveLines});
      editor = editorOver(operator);
    });

    Future<void> refused(String args, String message) => expectLater(
          editor.invokableRun(ctx, args),
          throwsA(isA<ThreepioFormatException>()
              .having((e) => e.message, 'message', message)),
        );

    test('a call through invokableRun', () async {
      expect(
        await editor.invokableRun(
          ctx,
          '{"command":"view","path":"/f","view_range":[2,3],"extra":1}',
        ),
        '$_cat /f:\n${_numbered(['line 2', 'line 3'], 2)}\n',
      );
      expect(
        await editor.run('{"command":"view","path":"/f","view_range":null}'),
        '$_cat /f:\n${_numbered(_fiveLines.split('\n'))}\n',
      );
    });

    test('decoding errors carry Go messages', () async {
      await expectLater(
        editor.invokableRun(ctx, '{"command":'),
        throwsA(isA<ThreepioFormatException>().having(
            (e) => e.message, 'message', startsWith('failed to extract input: '))),
      );
      await refused(
        '[]',
        'failed to extract input: json: cannot unmarshal array into Go value '
            'of type commandline.StrReplaceEditorParams',
      );
      await refused(
        '"view"',
        'failed to extract input: json: cannot unmarshal string into Go value '
            'of type commandline.StrReplaceEditorParams',
      );
      await refused(
        '{"command":"view","path":5}',
        'failed to extract input: json: cannot unmarshal number into Go struct '
            'field StrReplaceEditorParams.path of type string',
      );
      await refused(
        '{"command":5,"path":"/f"}',
        'failed to extract input: json: cannot unmarshal number into Go struct '
            'field StrReplaceEditorParams.command of type commandline.Command',
      );
      await refused(
        '{"command":"insert","path":"/f","insert_line":1.5,"new_str":"x"}',
        'failed to extract input: json: cannot unmarshal number 1.5 into Go '
            'struct field StrReplaceEditorParams.insert_line of type int',
      );
      await refused(
        '{"command":"view","path":"/f","view_range":"1,2"}',
        'failed to extract input: json: cannot unmarshal string into Go struct '
            'field StrReplaceEditorParams.view_range of type []int',
      );
      await refused(
        '{"command":"view","path":"/f","view_range":[1,"2"]}',
        'failed to extract input: json: cannot unmarshal string into Go struct '
            'field StrReplaceEditorParams.view_range of type int',
      );
      await refused(
        '{"command":"create","path":"/f","file_text":true}',
        'failed to extract input: json: cannot unmarshal bool into Go struct '
            'field StrReplaceEditorParams.file_text of type string',
      );
      // A type error is found before the command is looked at.
      await refused(
        '{"command":"nope","old_str":{}}',
        'failed to extract input: json: cannot unmarshal object into Go struct '
            'field StrReplaceEditorParams.old_str of type string',
      );
      expect(operator.calls, isEmpty);
    });

    test('null and missing commands are unrecognized', () async {
      const message = 'unrecognized command . Allowed commands are: view, '
          'create, str_replace, insert, undo_edit';
      await refused('null', message);
      await refused('{}', message);
      await refused('{"command":null,"path":"/f"}', message);
    });

    test('keys match ignoring case, as encoding/json does', () async {
      final longS = String.fromCharCode(0x017F);
      // bytes.EqualFold: the long s folds to s.
      expect(
        StrReplaceEditorParams.fromJson({
          'COMMAND': 'str_replace',
          'Path': '/f',
          'old_${longS}tr': 'line 2',
          'New_Str': 'two',
        }),
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.strReplace,
          path: '/f',
          oldStr: 'line 2',
          newStr: 'two',
        ),
      );
      expect(
        await editor.invokableRun(
          ctx,
          '{"Command":"view","PATH":"/f","View_Range":[2,2]}',
        ),
        '$_cat /f:\n${_numbered(['line 2'], 2)}\n',
      );
      // A later key overwrites an earlier one. null leaves a string field
      // as it is and clears a pointer or slice field, as in Go.
      expect(
        StrReplaceEditorParams.fromJson({
          'command': 'view',
          'Command': 'insert',
          'path': '/f',
          'PATH': null,
          'new_str': 'x',
          'NEW_STR': null,
          'view_range': [1, 2],
          'View_Range': null,
          'insert_line': 1,
        }),
        StrReplaceEditorParams(
          command: StrReplaceEditorCommand.insert,
          path: '/f',
          insertLine: 1,
        ),
      );
      // The first field of the wrong type fails, whatever follows.
      await refused(
        '{"Path":1,"path":"/f","command":"view"}',
        'failed to extract input: json: cannot unmarshal number into Go struct '
            'field StrReplaceEditorParams.path of type string',
      );
    });

    test('a null element of view_range is 0', () async {
      await expectLater(
        editor.invokableRun(
            ctx, '{"command":"view","path":"/f","view_range":[null,2]}'),
        throwsA(_threepio(startsWith('invalid `view_range`: [0 2].'))),
      );
    });

    test('params read back what they write', () {
      final params = StrReplaceEditorParams(
        command: StrReplaceEditorCommand.insert,
        path: '/f',
        fileText: 't',
        viewRange: const [1, 2],
        oldStr: 'o',
        newStr: 'n',
        insertLine: 3,
      );
      expect(params.toJson(), {
        'command': 'insert',
        'path': '/f',
        'file_text': 't',
        'view_range': [1, 2],
        'old_str': 'o',
        'new_str': 'n',
        'insert_line': 3,
      });
      expect(StrReplaceEditorParams.fromJson(params.toJson()), params);
      expect(
        StrReplaceEditorParams.fromJson(params.toJson()).hashCode,
        params.hashCode,
      );
      final minimal = StrReplaceEditorParams(
          command: StrReplaceEditorCommand.view, path: '/f');
      expect(minimal.toJson(), {'command': 'view', 'path': '/f'});
      expect(() => params.viewRange!.add(4), throwsUnsupportedError);
    });
  });

  group('truncate', () {
    test('counts and cuts UTF-8 bytes, as Go does', () {
      final e = String.fromCharCode(0xE9); // two bytes
      final text = e * 10; // 20 bytes, 10 characters
      expect(StrReplaceEditorTool.truncate(text, 20), text);
      expect(
        StrReplaceEditorTool.truncate(text, 4),
        '$e$e${StrReplaceEditorTool.truncatedMessage}',
      );
      // A character cut in two is U+FFFD.
      expect(
        StrReplaceEditorTool.truncate(text, 5),
        '$e$e${String.fromCharCode(0xFFFD)}'
        '${StrReplaceEditorTool.truncatedMessage}',
      );
    });
  });
}
