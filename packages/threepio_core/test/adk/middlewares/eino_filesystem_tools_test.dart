// Port of eino `adk/middlewares/filesystem/filesystem_test.go` (v0.9.22), the
// tests of the individual filesystem tools and their format helpers. The
// middleware construction, tool lists, multimodal read, streaming execute and
// `validatePages` tests are in `eino_filesystem_test.dart`.
//
// Ported here: TestLsTool, TestReadFileTool, TestReadFileTool_DefaultLimit,
// TestWriteFileTool, TestEditFileTool, TestGlobTool, TestGrepTool,
// TestExecuteTool, TestGrepToolWithSortingAndPagination,
// TestGrepToolSortsCustomBackendResultsByFullPath,
// TestGlobToolSortsCustomBackendResultsByFullPath, TestApplyPagination,
// TestConvExecuteResponse_NilResponse, TestConvExecuteResponse_NilExitCode,
// TestNewExecuteTool_ShellError, TestFormatLineNumbers_EmptyContent,
// TestReadFileTool_OffsetBeyondEOF, TestReadFileTool_EmptyFile.
//
// Not portable: TestReadFileTool_NilResult (its backend's `Read` returns
// `nil, nil`; Dart's `FileReadBackend.read` returns a non-nullable
// `FileContent`, so the tool has no nil branch to test).
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/filesystem/filesystem.dart';

final ctx = RunContext.background();

/// Port of `setupTestBackend`.
Future<InMemoryBackend> _setupTestBackend() async {
  final backend = InMemoryBackend();
  await backend.write(
    ctx,
    const WriteRequest(filePath: '/file1.txt', content: 'line1\nline2\nline3\nline4\nline5'),
  );
  await backend.write(
    ctx,
    const WriteRequest(filePath: '/file2.go', content: 'package main\n\nfunc main() {\n\tprintln("hello")\n}'),
  );
  await backend.write(
    ctx,
    const WriteRequest(filePath: '/dir1/file3.txt', content: 'hello world\nfoo bar\nhello again'),
  );
  await backend.write(
    ctx,
    const WriteRequest(filePath: '/dir1/file4.py', content: "print('hello')\nprint('world')"),
  );
  await backend.write(
    ctx,
    const WriteRequest(filePath: '/dir2/file5.go', content: 'package test\n\nfunc test() {}'),
  );
  return backend;
}

/// Port of `invokeTool`.
Future<String> _invokeTool(BaseTool tool, String input) => (tool as InvokableTool).invokableRun(ctx, input);

/// Port of `mockShellBackend` (only its `Execute` is used by these tests).
final class _MockShell implements Shell {
  _MockShell(this.resp);

  final ExecuteResponse resp;

  @override
  Future<ExecuteResponse> execute(RunContext ctx, ExecuteRequest request) async => resp;
}

/// Port of `mockShellBackendWithError`.
final class _ShellWithError implements Shell {
  @override
  Future<ExecuteResponse> execute(RunContext ctx, ExecuteRequest request) async =>
      throw const ThreepioException('shell execution error');
}

/// Port of `unorderedQueryBackend`: returns its results out of order.
final class _UnorderedQueryBackend implements FilesystemBackend {
  @override
  Future<List<GrepMatch>> grepRaw(RunContext ctx, GrepRequest request) async => const [
        GrepMatch(path: '/z/a.txt', line: 2, content: 'second'),
        GrepMatch(path: '/a/b.txt', line: 1, content: 'first'),
      ];

  @override
  Future<List<FileInfo>> globInfo(RunContext ctx, GlobInfoRequest request) async => const [
        FileInfo(path: '/z/a.txt'),
        FileInfo(path: '/a/b.txt'),
      ];

  @override
  Future<List<FileInfo>> lsInfo(RunContext ctx, LsInfoRequest request) => throw UnimplementedError();

  @override
  Future<FileContent> read(RunContext ctx, ReadRequest request) => throw UnimplementedError();

  @override
  Future<void> write(RunContext ctx, WriteRequest request) => throw UnimplementedError();

  @override
  Future<void> edit(RunContext ctx, EditRequest request) => throw UnimplementedError();
}

void main() {
  group('TestLsTool', () {
    late BaseTool lsTool;

    setUp(() async {
      lsTool = newLsTool(await _setupTestBackend(), '', '');
    });

    final cases = <({String name, String input, List<String> expected})>[
      (name: 'list root', input: '{"path": "/"}', expected: ['file1.txt', 'file2.go', 'dir1', 'dir2']),
      (
        name: 'list empty path (defaults to root)',
        input: '{"path": ""}',
        expected: ['file1.txt', 'file2.go', 'dir1', 'dir2'],
      ),
      (name: 'list dir1', input: '{"path": "/dir1"}', expected: ['file3.txt', 'file4.py']),
    ];
    for (final tt in cases) {
      test(tt.name, () async {
        final result = await _invokeTool(lsTool, tt.input);
        for (final expectedPath in tt.expected) {
          expect(result, contains(expectedPath));
        }
      });
    }
  });

  group('TestReadFileTool', () {
    late BaseTool readTool;

    setUp(() async {
      readTool = newReadFileTool(await _setupTestBackend(), '', '');
    });

    final cases = <({String name, String input, String expected, bool shouldError})>[
      (
        name: 'read full file',
        input: '{"file_path": "/file1.txt", "offset": 0, "limit": 100}',
        expected: '     1\tline1\n     2\tline2\n     3\tline3\n     4\tline4\n     5\tline5',
        shouldError: false,
      ),
      (
        name: 'read with offset',
        input: '{"file_path": "/file1.txt", "offset": 2, "limit": 2}',
        expected: '     2\tline2\n     3\tline3',
        shouldError: false,
      ),
      (
        name: 'read with default limit',
        input: '{"file_path": "/file1.txt", "offset": 0, "limit": 0}',
        expected: '     1\tline1\n     2\tline2\n     3\tline3\n     4\tline4\n     5\tline5',
        shouldError: false,
      ),
      (
        name: 'read with negative offset (treated as 0)',
        input: '{"file_path": "/file1.txt", "offset": -1, "limit": 2}',
        expected: '     1\tline1\n     2\tline2',
        shouldError: false,
      ),
      (
        name: 'read non-existent file',
        input: '{"file_path": "/nonexistent.txt", "offset": 0, "limit": 10}',
        expected: '',
        shouldError: true,
      ),
    ];
    for (final tt in cases) {
      test(tt.name, () async {
        if (tt.shouldError) {
          await expectLater(_invokeTool(readTool, tt.input), throwsA(anything));
          return;
        }
        expect(await _invokeTool(readTool, tt.input), tt.expected);
      });
    }
  });

  group('TestReadFileTool_DefaultLimit', () {
    // A file with more than 2000 lines, to check that the tool layer applies
    // the default limit.
    const totalLines = 2500;
    late InMemoryBackend backend;
    late BaseTool readTool;

    setUp(() async {
      backend = InMemoryBackend();
      final b = StringBuffer();
      for (var i = 1; i <= totalLines; i++) {
        if (i > 1) b.write('\n');
        b.write('line$i');
      }
      await backend.write(ctx, WriteRequest(filePath: '/big.txt', content: b.toString()));
      readTool = newReadFileTool(backend, '', '');
    });

    test('limit=0 defaults to 2000 lines in tool layer', () async {
      final result = await _invokeTool(readTool, '{"file_path": "/big.txt", "offset": 0, "limit": 0}');
      expect(result.split('\n'), hasLength(2000));
    });

    test('explicit limit is respected', () async {
      final result = await _invokeTool(readTool, '{"file_path": "/big.txt", "offset": 0, "limit": 10}');
      expect(result.split('\n'), hasLength(10));
    });

    test('backend read with limit=0 returns all lines', () async {
      final content = await backend.read(ctx, const ReadRequest(filePath: '/big.txt', offset: 0, limit: 0));
      expect(content.content.split('\n'), hasLength(totalLines));
    });
  });

  group('TestWriteFileTool', () {
    // As in Go, the sub-tests share one backend, and the last test checks
    // what the first one wrote.
    late InMemoryBackend backend;
    late BaseTool writeTool;

    setUpAll(() async {
      backend = await _setupTestBackend();
      writeTool = newWriteFileTool(backend, '', '');
    });

    final cases = <({String name, String input, String expected, bool isError})>[
      (
        name: 'write new file',
        input: '{"file_path": "/newfile.txt", "content": "new content"}',
        expected: 'Updated file /newfile.txt',
        isError: false,
      ),
      (
        name: 'overwrite existing file',
        input: '{"file_path": "/file1.txt", "content": "overwritten"}',
        expected: 'Updated file /file1.txt',
        isError: false,
      ),
    ];
    for (final tt in cases) {
      test(tt.name, () async {
        if (tt.isError) {
          await expectLater(_invokeTool(writeTool, tt.input), throwsA(anything));
          return;
        }
        expect(await _invokeTool(writeTool, tt.input), tt.expected);
      });
    }

    test('the file was actually written', () async {
      final content = await backend.read(ctx, const ReadRequest(filePath: '/newfile.txt', offset: 0, limit: 100));
      expect(content.content, 'new content');
    });
  });

  group('TestEditFileTool', () {
    late InMemoryBackend backend;
    late BaseTool editTool;

    setUpAll(() async {
      backend = await _setupTestBackend();
      editTool = newEditFileTool(backend, '', '');
    });

    final cases = <({
      String name,
      String setupFile,
      String setupContent,
      String input,
      String expected,
      bool shouldError,
    })>[
      (
        name: 'replace first occurrence',
        setupFile: '/edit1.txt',
        setupContent: 'hello world\nhello again\nhello world',
        input: '{"file_path": "/edit1.txt", "old_string": "hello again", "new_string": "hi", "replace_all": false}',
        expected: 'hello world\nhi\nhello world',
        shouldError: false,
      ),
      (
        name: 'replace all occurrences',
        setupFile: '/edit2.txt',
        setupContent: 'hello world\nhello again\nhello world',
        input: '{"file_path": "/edit2.txt", "old_string": "hello", "new_string": "hi", "replace_all": true}',
        expected: 'hi world\nhi again\nhi world',
        shouldError: false,
      ),
      (
        name: 'non-existent file',
        setupFile: '',
        setupContent: '',
        input: '{"file_path": "/nonexistent.txt", "old_string": "old", "new_string": "new", "replace_all": false}',
        expected: '',
        shouldError: true,
      ),
      (
        name: 'empty old_string',
        setupFile: '/edit3.txt',
        setupContent: 'content',
        input: '{"file_path": "/edit3.txt", "old_string": "", "new_string": "new", "replace_all": false}',
        expected: '',
        shouldError: true,
      ),
    ];
    for (final tt in cases) {
      test(tt.name, () async {
        if (tt.setupFile.isNotEmpty) {
          await backend.write(ctx, WriteRequest(filePath: tt.setupFile, content: tt.setupContent));
        }
        if (tt.shouldError) {
          await expectLater(_invokeTool(editTool, tt.input), throwsA(anything));
          return;
        }
        await _invokeTool(editTool, tt.input);
        final result = await backend.read(ctx, ReadRequest(filePath: tt.setupFile, offset: 0, limit: 0));
        expect(result.content, tt.expected);
      });
    }
  });

  group('TestGlobTool', () {
    late BaseTool globTool;

    setUp(() async {
      globTool = newGlobTool(await _setupTestBackend(), '', '');
    });

    final cases = <({String name, String input, List<String> expected})>[
      (name: 'match all .txt files in root', input: '{"pattern": "*.txt", "path": "/"}', expected: ['file1.txt']),
      (name: 'match all .go files in root', input: '{"pattern": "*.go", "path": "/"}', expected: ['file2.go']),
      (name: 'match all .txt files in dir1', input: '{"pattern": "*.txt", "path": "/dir1"}', expected: ['file3.txt']),
      (name: 'match all .py files in dir1', input: '{"pattern": "*.py", "path": "/dir1"}', expected: ['file4.py']),
      (name: 'empty path defaults to root', input: '{"pattern": "*.go", "path": ""}', expected: ['file2.go']),
      (
        name: 'match all .txt files in dir1 in root dir',
        input: '{"pattern": "/dir1/*.txt", "path": "/"}',
        expected: ['/dir1/file3.txt'],
      ),
    ];
    for (final tt in cases) {
      test(tt.name, () async {
        final result = await _invokeTool(globTool, tt.input);
        for (final expectedPath in tt.expected) {
          expect(result, contains(expectedPath));
        }
      });
    }
  });

  group('TestGrepTool', () {
    late BaseTool grepTool;

    setUp(() async {
      grepTool = newGrepTool(await _setupTestBackend(), '', '');
    });

    final cases = <({String name, String input, String expected, List<String> contains})>[
      (
        name: 'grep with count mode',
        input: '{"pattern": "hello", "output_mode": "count"}',
        // 2 in file3.txt, 1 in file4.py, 1 in file2.go
        expected: '/dir1/file3.txt:2\n/dir1/file4.py:1\n/file2.go:1\n\nFound 4 total occurrences across 3 files.',
        contains: const [],
      ),
      (
        name: 'grep with content mode',
        input: '{"pattern": "hello", "output_mode": "content"}',
        expected: '',
        contains: const [
          '/dir1/file3.txt:1:hello world',
          '/dir1/file3.txt:3:hello again',
          "/dir1/file4.py:1:print('hello')",
        ],
      ),
      (
        name: 'grep with files_with_matches mode (default)',
        input: '{"pattern": "hello", "output_mode": "files_with_matches"}',
        expected: '',
        contains: const ['/dir1/file3.txt', '/dir1/file4.py'],
      ),
      (
        name: 'grep with glob filter',
        input: '{"pattern": "hello", "glob": "*.txt", "output_mode": "count"}',
        // only in file3.txt
        expected: '/dir1/file3.txt:2\n\nFound 2 total occurrences across 1 file.',
        contains: const [],
      ),
      (
        name: 'grep  withpath filter',
        input: '{"pattern": "package", "path": "/dir2", "output_mode": "count"}',
        // only in dir2/file5.go
        expected: '/dir2/file5.go:1\n\nFound 1 total occurrence across 1 file.',
        contains: const [],
      ),
    ];
    for (final tt in cases) {
      test(tt.name, () async {
        final result = await _invokeTool(grepTool, tt.input);
        if (tt.expected.isNotEmpty) expect(result, tt.expected);
        for (final expectedStr in tt.contains) {
          expect(result, contains(expectedStr));
        }
      });
    }
  });

  group('TestExecuteTool', () {
    final cases = <({String name, ExecuteResponse resp, String input, String expected, bool shouldError})>[
      (
        name: 'successful command execution',
        resp: const ExecuteResponse(output: 'hello world', exitCode: 0),
        input: '{"command": "echo hello world"}',
        expected: 'hello world',
        shouldError: false,
      ),
      (
        name: 'command with non-zero exit code',
        resp: const ExecuteResponse(output: 'error: file not found', exitCode: 1),
        input: '{"command": "cat nonexistent.txt"}',
        expected: 'error: file not found\n[Command failed with exit code 1]',
        shouldError: false,
      ),
      (
        name: 'command with truncated output',
        resp: const ExecuteResponse(output: 'partial output...', exitCode: 0, truncated: true),
        input: '{"command": "cat largefile.txt"}',
        expected: 'partial output...\n[Output was truncated due to size limits]',
        shouldError: false,
      ),
      (
        name: 'command with both non-zero exit code and truncated output',
        resp: const ExecuteResponse(output: 'error output...', exitCode: 2, truncated: true),
        input: '{"command": "failing command"}',
        expected: 'error output...\n[Command failed with exit code 2]\n[Output was truncated due to size limits]',
        shouldError: false,
      ),
      (
        name: 'successful command with no output',
        resp: const ExecuteResponse(exitCode: 0),
        input: '{"command": "mkdir /tmp/test"}',
        expected: '[Command executed successfully with no output]',
        shouldError: false,
      ),
    ];
    for (final tt in cases) {
      test(tt.name, () async {
        final executeTool = newExecuteTool(_MockShell(tt.resp), '', '');
        if (tt.shouldError) {
          await expectLater(_invokeTool(executeTool, tt.input), throwsA(anything));
          return;
        }
        expect(await _invokeTool(executeTool, tt.input), tt.expected);
      });
    }
  });

  group('TestGrepToolWithSortingAndPagination', () {
    late BaseTool grepTool;

    setUp(() async {
      final backend = InMemoryBackend();
      await backend.write(ctx, const WriteRequest(filePath: '/zebra.txt', content: 'match1\nmatch2\nmatch3'));
      await backend.write(ctx, const WriteRequest(filePath: '/apple.txt', content: 'match4\nmatch5'));
      await backend.write(ctx, const WriteRequest(filePath: '/banana.txt', content: 'match6\nmatch7\nmatch8'));
      grepTool = newGrepTool(backend, '', '');
    });

    Future<List<String>> lines(String input) async => (await _invokeTool(grepTool, input)).trim().split('\n');

    test('files sorted by basename', () async {
      final l = await lines('{"pattern": "match", "output_mode": "files_with_matches"}');
      expect(l, hasLength(4)); // 1 summary + 3 files
      expect(l[0], contains('Found 3 files'));
      expect(l[1], contains('apple.txt'));
      expect(l[2], contains('banana.txt'));
      expect(l[3], contains('zebra.txt'));
    });

    test('files_with_matches with offset', () async {
      final l = await lines('{"pattern": "match", "output_mode": "files_with_matches", "offset": 1}');
      expect(l, hasLength(3)); // 1 summary + 2 files (pagination applied)
      expect(l[0], contains('Found 3 files')); // total count before pagination
      expect(l[1], contains('banana.txt'));
      expect(l[2], contains('zebra.txt'));
    });

    test('files_with_matches with head_limit', () async {
      final l = await lines('{"pattern": "match", "output_mode": "files_with_matches", "head_limit": 2}');
      expect(l, hasLength(3)); // 1 summary + 2 files (pagination applied)
      expect(l[0], contains('Found 3 files')); // total count before pagination
      expect(l[1], contains('apple.txt'));
      expect(l[2], contains('banana.txt'));
    });

    test('files_with_matches with offset and head_limit', () async {
      final l = await lines('{"pattern": "match", "output_mode": "files_with_matches", "offset": 1, "head_limit": 1}');
      expect(l, hasLength(2)); // 1 summary + 1 file (pagination applied)
      expect(l[0], contains('Found 3 files')); // total count before pagination
      expect(l[1], contains('banana.txt'));
    });

    test('content mode sorted and paginated', () async {
      final l = await lines('{"pattern": "match", "output_mode": "content", "head_limit": 3}');
      expect(l, hasLength(3));
      expect(l[0], contains('apple.txt'));
    });

    test('content mode with offset', () async {
      final l = await lines('{"pattern": "match", "output_mode": "content", "offset": 2, "head_limit": 2}');
      expect(l, hasLength(2));
    });

    test('count mode sorted', () async {
      final l = await lines('{"pattern": "match", "output_mode": "count"}');
      expect(l, hasLength(5)); // 3 file counts + 1 empty line + 1 summary line
      expect(l[0], contains('apple.txt:2'));
      expect(l[1], contains('banana.txt:3'));
      expect(l[2], contains('zebra.txt:3'));
      expect(l[4], contains('Found 8 total occurrences across 3 files.'));
    });

    test('count mode with pagination', () async {
      final l = await lines('{"pattern": "match", "output_mode": "count", "offset": 1, "head_limit": 1}');
      expect(l, hasLength(3)); // 1 file count + 1 empty line + 1 summary line
      expect(l[0], contains('banana.txt:3'));
      // The summary shows the total before pagination.
      expect(l[2], contains('Found 8 total occurrences across 3 files.'));
    });

    test('offset exceeds result count', () async {
      final result =
          await _invokeTool(grepTool, '{"pattern": "match", "output_mode": "files_with_matches", "offset": 100}');
      expect(result, contains('Found 3 files')); // still shows total count
    });

    test('negative offset treated as zero', () async {
      final l = await lines('{"pattern": "match", "output_mode": "files_with_matches", "offset": -5}');
      expect(l, hasLength(4)); // 1 summary + 3 files
    });
  });

  test('TestGrepToolSortsCustomBackendResultsByFullPath', () async {
    final grepTool = newGrepTool(_UnorderedQueryBackend(), '', '');
    final result = await _invokeTool(grepTool, '{"pattern": "match", "output_mode": "content"}');
    final lines = result.trim().split('\n');
    expect(lines, hasLength(2));
    expect(lines[0], contains('/a/b.txt'));
    expect(lines[1], contains('/z/a.txt'));
  });

  test('TestGlobToolSortsCustomBackendResultsByFullPath', () async {
    final globTool = newGlobTool(_UnorderedQueryBackend(), '', '');
    final result = await _invokeTool(globTool, '{"pattern": "**/*.txt"}');
    expect(result, '/a/b.txt\n/z/a.txt');
  });

  group('TestApplyPagination', () {
    test('basic pagination', () {
      expect(applyPagination(['a', 'b', 'c', 'd', 'e'], 0, 3), ['a', 'b', 'c']);
    });

    test('with offset', () {
      expect(applyPagination(['a', 'b', 'c', 'd', 'e'], 2, 2), ['c', 'd']);
    });

    test('offset exceeds length', () {
      expect(applyPagination(['a', 'b', 'c'], 10, 5), <String>[]);
    });

    test('negative offset', () {
      expect(applyPagination(['a', 'b', 'c'], -1, 2), ['a', 'b']);
    });

    test('zero head limit means no limit', () {
      expect(applyPagination(['a', 'b', 'c', 'd', 'e'], 1, 0), ['b', 'c', 'd', 'e']);
    });
  });

  test('TestConvExecuteResponse_NilResponse', () {
    expect(convExecuteResponse(null), '');
  });

  test('TestConvExecuteResponse_NilExitCode', () {
    expect(convExecuteResponse(const ExecuteResponse(output: 'some output')), 'some output');
  });

  test('TestNewExecuteTool_ShellError', () async {
    final executeTool = newExecuteTool(_ShellWithError(), '', '');
    // Go also checks that the result is "": a Dart tool that throws has no
    // result.
    await expectLater(
      _invokeTool(executeTool, '{"command": "fail"}'),
      throwsA(predicate((e) => '$e'.contains('shell execution error'))),
    );
  });

  test('TestFormatLineNumbers_EmptyContent', () {
    expect(formatLineNumbers('', 300), '');
    expect(formatLineNumbers('a', 300), '   300\ta');
  });

  test('TestReadFileTool_OffsetBeyondEOF', () async {
    final readTool = newReadFileTool(await _setupTestBackend(), '', '');
    // /file1.txt has 5 lines.
    final out = await _invokeTool(readTool, '{"file_path": "/file1.txt", "offset": 300, "limit": 100}');
    expect(out, isNot('   300\t'));
    expect(out, contains('/file1.txt'));
    expect(out, contains('offset 300'));
  });

  test('TestReadFileTool_EmptyFile', () async {
    final backend = await _setupTestBackend();
    await backend.write(ctx, const WriteRequest(filePath: '/empty.txt', content: ''));
    final readTool = newReadFileTool(backend, '', '');
    final out = await _invokeTool(readTool, '{"file_path": "/empty.txt"}');
    expect(out, isNot('     1\t'));
    expect(out, contains('/empty.txt'));
  });
}
