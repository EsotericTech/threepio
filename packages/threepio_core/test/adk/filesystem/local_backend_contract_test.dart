// The cases of eino_in_memory_backend_test.dart (eino v0.9.22
// `adk/filesystem/backend_inmemory_test.go`) that describe behaviour every
// backend shares, run against LocalFilesystemBackend on a temporary
// directory. The in-memory backend's `/x` is `<temporary directory>/x` here,
// and searches that default to `/` there get the temporary directory as
// their path.
//
// Ported (group names are the Go test names): TestInMemoryBackend_
//   WriteAndRead, LsInfo, QueryResultsAreDeterministic, Edit,
//   LsInfo_PathIsFilename, GlobInfo, GlobInfo_RelativePath,
//   GlobInfo_RecursivePattern, Concurrent, Read_EdgeCases, Edit_EdgeCases,
//   NormalizePath, GrepRaw, GrepRaw_WithContext, GrepRaw_Multiline,
//   GrepRaw_EmptyFiles, GrepRaw_SpecialCharacters, GrepRaw_Concurrent,
//   GrepRaw_ComplexScenarios, Read_Scenarios, Read_NoLimit.
//
// Where the local backend differs by design, the test asserts the local
// behaviour and says why ("Differs by design"). The differences all follow
// eino-ext's local backend:
// * lsInfo and globInfo report only paths (no isDir, size or modification
//   time), and globInfo matches directories as well as files.
// * globInfo matches paths relative to its start directory, so an absolute
//   pattern matches nothing (and a start of `/` would walk the machine).
// * read without a limit returns at most 2000 lines and drops the trailing
//   line break.
// * Error texts are eino-ext's; grep failures are ripgrep's exit code 2
//   (a missing search path is one, where the in-memory backend finds
//   nothing).
// * A multiline grep match is one result per block of lines, numbered by its
//   first line (ripgrep), not one result per line.
// * A grep glob with a `/` is matched against the path relative to the
//   working directory (ripgrep), not to the searched path.
//
// Not ported, because they test what only the in-memory backend has:
//   LsInfo_FileInfoMetadata, GlobInfo_FileInfoMetadata,
//   WriteAndEdit_ModifiedAt (the local backend reports no size or time, as in
//   Go) and MatchFileType (a helper of the in-memory backend, which the local
//   one reuses).
import 'dart:io';

import 'package:test/test.dart';
import 'package:threepio_core/src/adk/filesystem/local_backend.dart';
import 'package:threepio_core/src/adk/filesystem/requests.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';

final ctx = RunContext.background();

final Matcher _throwsError = throwsA(isA<ThreepioException>());

Matcher _throwsContaining(String text) => throwsA(
      isA<ThreepioException>().having((e) => e.message, 'message', contains(text)),
    );

List<String> _fileInfoPaths(List<FileInfo> infos) => [
      for (final info in infos) info.path,
    ];

void main() {
  late Directory tmp;
  late String root;
  late LocalFilesystemBackend backend;

  /// The in-memory backend's absolute [path] in the temporary directory.
  String at(String path) => '$root$path';

  /// Writes through the backend, as the in-memory tests do.
  Future<void> put(String path, String content) =>
      backend.write(ctx, WriteRequest(filePath: at(path), content: content));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('threepio_p11_');
    root = tmp.path;
    backend = LocalFilesystemBackend();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('TestInMemoryBackend_WriteAndRead', () {
    test('write, read whole, read a range, read a missing file', () async {
      await put('/test.txt', 'line1\nline2\nline3\nline4\nline5');

      var content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/test.txt'), limit: 100),
      );
      expect(content.content, 'line1\nline2\nline3\nline4\nline5');

      content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/test.txt'), offset: 1, limit: 2),
      );
      expect(content.content, 'line1\nline2');

      await expectLater(
        backend.read(ctx, ReadRequest(filePath: at('/nonexistent.txt'), limit: 10)),
        _throwsError,
      );
    });
  });

  group('TestInMemoryBackend_LsInfo', () {
    test('lists the root and a directory', () async {
      await put('/file1.txt', 'content1');
      await put('/file2.txt', 'content2');
      await put('/dir1/file3.txt', 'content3');
      await put('/dir1/subdir/file4.txt', 'content4');
      await put('/dir2/file5.txt', 'content5');

      var infos = await backend.lsInfo(ctx, LsInfoRequest(path: root));
      expect(infos, hasLength(4)); // file1.txt, file2.txt, dir1, dir2

      infos = await backend.lsInfo(ctx, LsInfoRequest(path: at('/dir1')));
      expect(infos, hasLength(2)); // file3.txt, subdir
    });
  });

  group('TestInMemoryBackend_QueryResultsAreDeterministic', () {
    test('lsInfo, globInfo and grepRaw are sorted', () async {
      for (final filePath in ['/z.txt', '/a.txt', '/m.txt']) {
        await put(filePath, 'before\nneedle\nafter');
      }

      var infos = await backend.lsInfo(ctx, LsInfoRequest(path: root));
      expect(_fileInfoPaths(infos), ['a.txt', 'm.txt', 'z.txt']);

      infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(path: root, pattern: '*.txt'),
      );
      expect(_fileInfoPaths(infos), ['a.txt', 'm.txt', 'z.txt']);

      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(pattern: 'needle', path: root, afterLines: 1),
      );
      expect([for (final m in matches) '${m.path}:${m.line}'], [
        '${at('/a.txt')}:2',
        '${at('/a.txt')}:3',
        '${at('/m.txt')}:2',
        '${at('/m.txt')}:3',
        '${at('/z.txt')}:2',
        '${at('/z.txt')}:3',
      ]);
    });
  });

  group('TestInMemoryBackend_Edit', () {
    test('edit errors and replace-all', () async {
      await put('/edit.txt', 'hello world\nhello again\nhello world');
      await expectLater(
        backend.edit(
          ctx,
          EditRequest(filePath: at('/edit.txt'), oldString: 'hello', newString: 'hi'),
        ),
        _throwsError,
      );

      await put('/edit2.txt', 'hello world\nhello again\nhello world');
      await backend.edit(
        ctx,
        EditRequest(
          filePath: at('/edit2.txt'),
          oldString: 'hello',
          newString: 'hi',
          replaceAll: true,
        ),
      );
      final content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/edit2.txt'), limit: 100),
      );
      expect(content.content, 'hi world\nhi again\nhi world');

      await expectLater(
        backend.edit(
          ctx,
          EditRequest(filePath: at('/nonexistent.txt'), oldString: 'old', newString: 'new'),
        ),
        _throwsError,
      );
      await expectLater(
        backend.edit(
          ctx,
          EditRequest(filePath: at('/edit.txt'), oldString: '', newString: 'new'),
        ),
        _throwsError,
      );
    });
  });

  group('TestInMemoryBackend_LsInfo_PathIsFilename', () {
    setUp(() async {
      await put('/file1.txt', 'content1');
      await put('/file2.txt', 'content2');
      await put('/dir1/file3.txt', 'content3');
      await put('/dir1/subdir/file4.txt', 'content4');
    });

    // Differs by design: the local backend reports names only (no isDir), so
    // the names are checked as a set instead of by kind.
    test('RootDirectory', () async {
      final infos = await backend.lsInfo(ctx, LsInfoRequest(path: root));
      for (final info in infos) {
        expect(info.path, isNot(contains('/')), reason: 'Path should be filename only');
        expect(info.isDir, isFalse);
      }
      expect(_fileInfoPaths(infos), ['dir1', 'file1.txt', 'file2.txt']);
    });

    test('Subdirectory', () async {
      final infos = await backend.lsInfo(ctx, LsInfoRequest(path: at('/dir1')));
      expect(_fileInfoPaths(infos), ['file3.txt', 'subdir']);
    });

    test('NestedSubdirectory', () async {
      final infos =
          await backend.lsInfo(ctx, LsInfoRequest(path: at('/dir1/subdir')));
      expect(infos, hasLength(1));
      expect(infos[0].path, 'file4.txt');
    });
  });

  group('TestInMemoryBackend_GlobInfo', () {
    test('matches in the root and in a directory', () async {
      await put('/file1.txt', 'content1');
      await put('/file2.py', 'content2');
      await put('/dir1/file3.txt', 'content3');
      await put('/dir1/file4.py', 'content4');

      var infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: '*.txt', path: root),
      );
      expect(infos, hasLength(1));
      expect(infos[0].path, 'file1.txt');

      infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: '*.py', path: at('/dir1')),
      );
      expect(infos, hasLength(1));
      expect(infos[0].path, 'file4.py');
    });
  });

  group('TestInMemoryBackend_GlobInfo_RelativePath', () {
    const github = '/Users/bytedance/Desktop/github';

    setUp(() async {
      await put('$github/eino/file1.go', 'content1');
      await put('$github/openai-go/paginationmanual_test.go', 'content2');
      await put('$github/openai-go/paginationauto_test.go', 'content3');
      await put('/Users/bytedance/Desktop/other/test.go', 'content4');
    });

    test('GlobFromRootWithPattern', () async {
      final infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: '**/*.go', path: at(github)),
      );
      expect(infos, hasLength(3));
      expect(_fileInfoPaths(infos), unorderedEquals([
        'eino/file1.go',
        'openai-go/paginationmanual_test.go',
        'openai-go/paginationauto_test.go',
      ]));
    });

    test('GlobFromSubdirectory', () async {
      final infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: '*.go', path: at('$github/openai-go')),
      );
      expect(_fileInfoPaths(infos), unorderedEquals([
        'paginationmanual_test.go',
        'paginationauto_test.go',
      ]));
    });

    // Differs by design: paths are matched relative to the start directory,
    // so an absolute pattern matches nothing (Go's local backend too).
    test('GlobFromRootWithAbsolutePattern', () async {
      final infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: '${at(github)}/**/*.go', path: root),
      );
      expect(infos, isEmpty);
    });

    test('GlobRecursiveWithRelativePattern', () async {
      final infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: '**/*.go', path: at(github)),
      );
      expect(infos, hasLength(3));
    });
  });

  group('TestInMemoryBackend_GlobInfo_RecursivePattern', () {
    setUp(() async {
      await put('/project/src/main.go', 'main');
      await put('/project/src/utils/helper.go', 'helper');
      await put('/project/src/utils/deep/nested.go', 'nested');
      await put('/project/test/test.go', 'test');
      await put('/project/README.md', 'readme');
    });

    test('DoubleStarMatchesAllSubdirectories', () async {
      final infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: '**/*.go', path: at('/project')),
      );
      expect(_fileInfoPaths(infos), unorderedEquals([
        'src/main.go',
        'src/utils/helper.go',
        'src/utils/deep/nested.go',
        'test/test.go',
      ]));
    });

    test('DoubleStarInMiddleOfPattern', () async {
      final infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: 'src/**/*.go', path: at('/project')),
      );
      expect(_fileInfoPaths(infos), unorderedEquals([
        'src/main.go',
        'src/utils/helper.go',
        'src/utils/deep/nested.go',
      ]));
    });

    // Differs by design: directories match too (src, src/utils,
    // src/utils/deep), as they are entries of the walk in Go.
    test('DoubleStarAtEnd', () async {
      final infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: 'src/**', path: at('/project')),
      );
      expect(_fileInfoPaths(infos), containsAll([
        'src/main.go',
        'src/utils/helper.go',
        'src/utils/deep/nested.go',
      ]));
      expect(_fileInfoPaths(infos), [
        'src',
        'src/main.go',
        'src/utils',
        'src/utils/deep',
        'src/utils/deep/nested.go',
        'src/utils/helper.go',
      ]);
    });

    // Differs by design: an absolute pattern matches nothing.
    test('AbsolutePatternWithDoubleStarRecursive', () async {
      final infos = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: '${at('/project')}/**/*.go', path: root),
      );
      expect(infos, isEmpty);
    });
  });

  group('TestInMemoryBackend_Concurrent', () {
    test('concurrent writes and reads', () async {
      await Future.wait([
        for (var i = 0; i < 10; i++)
          () async {
            await put('/concurrent.txt', 'content');
            await backend.read(
              ctx,
              ReadRequest(filePath: at('/concurrent.txt'), limit: 10),
            );
          }(),
      ]);
    });
  });

  group('TestInMemoryBackend_Read_EdgeCases', () {
    setUp(() => put('/test.txt', 'line1\nline2\nline3'));

    test('negative offset should be treated as zero', () async {
      final content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/test.txt'), offset: -5, limit: 2),
      );
      expect(content.content, 'line1\nline2');
    });

    test('offset exceeds file length', () async {
      final content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/test.txt'), offset: 100, limit: 10),
      );
      expect(content.content, '');
    });

    test('zero or negative limit should use default 200', () async {
      final content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/test.txt'), offset: 0, limit: 0),
      );
      expect(content.content.split('\n'), hasLength(3));
    });

    test('limit exceeds remaining lines', () async {
      final content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/test.txt'), offset: 1, limit: 100),
      );
      expect(content.content.split('\n'), hasLength(3));
    });
  });

  group('TestInMemoryBackend_Edit_EdgeCases', () {
    // Differs by design: eino-ext's error texts.
    test('edit non-existent file', () async {
      await expectLater(
        backend.edit(
          ctx,
          EditRequest(filePath: at('/nonexistent.txt'), oldString: 'old', newString: 'new'),
        ),
        _throwsContaining('no such file or directory'),
      );
    });

    test('empty oldString', () async {
      await put('/test.txt', 'content');
      await expectLater(
        backend.edit(
          ctx,
          EditRequest(filePath: at('/test.txt'), oldString: '', newString: 'new'),
        ),
        _throwsContaining('old string is required'),
      );
    });

    test('oldString not found', () async {
      await put('/test.txt', 'hello world');
      await expectLater(
        backend.edit(
          ctx,
          EditRequest(filePath: at('/test.txt'), oldString: 'notfound', newString: 'new'),
        ),
        _throwsContaining('not found in file'),
      );
    });

    test('multiple occurrences with ReplaceAll false', () async {
      await put('/test.txt', 'foo bar foo baz');
      await expectLater(
        backend.edit(
          ctx,
          EditRequest(filePath: at('/test.txt'), oldString: 'foo', newString: 'FOO'),
        ),
        _throwsContaining('appears multiple times'),
      );
    });

    test('single occurrence with ReplaceAll false', () async {
      await put('/test.txt', 'foo bar baz');
      await backend.edit(
        ctx,
        EditRequest(filePath: at('/test.txt'), oldString: 'foo', newString: 'FOO'),
      );
      final content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/test.txt'), limit: 100),
      );
      expect(content.content, contains('FOO'));
    });

    test('ReplaceAll replaces all occurrences', () async {
      await put('/test.txt', 'foo bar foo baz foo');
      await backend.edit(
        ctx,
        EditRequest(
          filePath: at('/test.txt'),
          oldString: 'foo',
          newString: 'FOO',
          replaceAll: true,
        ),
      );
      final content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/test.txt'), limit: 100),
      );
      expect(content.content, isNot(contains('foo')));
      expect('FOO'.allMatches(content.content), hasLength(3));
    });
  });

  group('TestInMemoryBackend_NormalizePath', () {
    // Differs by design: a relative path is relative to the working
    // directory (here the temporary directory), not to a root.
    test('paths are normalized on write', () async {
      const testCases = [
        (inputPath: 'test.txt', normalizedPath: '/test.txt'),
        (inputPath: '/test.txt', normalizedPath: '/test.txt'),
        (inputPath: '//test.txt', normalizedPath: '/test.txt'),
        (inputPath: '/dir//file.txt', normalizedPath: '/dir/file.txt'),
        (inputPath: '/dir/../file.txt', normalizedPath: '/file.txt'),
      ];
      final previous = Directory.current;
      Directory.current = tmp;
      try {
        for (final tc in testCases) {
          final input = tc.inputPath.startsWith('/') ? at(tc.inputPath) : tc.inputPath;
          await backend.write(ctx, WriteRequest(filePath: input, content: 'content'));
          final content = await backend.read(
            ctx,
            ReadRequest(filePath: at(tc.normalizedPath), limit: 10),
          );
          expect(content.content, contains('content'), reason: tc.inputPath);
        }
      } finally {
        Directory.current = previous;
      }
    });
  });

  group('TestInMemoryBackend_GrepRaw', () {
    setUp(() async {
      await put(
        '/test.go',
        'package main\nfunc main() {\n\tlog.Error("error")\n\tfmt.Println("hello")\n}',
      );
      await put('/test.py', "def hello():\n    print('error')\n    print('world')");
      await put(
        '/dir/file.go',
        'package test\nfunc TestError() {\n\tlog.Error("test error")\n}',
      );
    });

    Future<List<GrepMatch>> grep(GrepRequest request) => backend.grepRaw(
          ctx,
          GrepRequest(
            pattern: request.pattern,
            path: request.path.isEmpty ? root : at(request.path),
            glob: request.glob,
            fileType: request.fileType,
            caseInsensitive: request.caseInsensitive,
          ),
        );

    test('basic pattern search', () async {
      expect(await grep(const GrepRequest(pattern: 'error')), hasLength(3));
    });

    // Differs by design: eino-ext's text.
    test('empty pattern error', () async {
      await expectLater(
        grep(const GrepRequest(pattern: '')),
        _throwsContaining('pattern is required'),
      );
    });

    // Differs by design: ripgrep's failure.
    test('invalid regex pattern', () async {
      await expectLater(
        grep(const GrepRequest(pattern: '[invalid')),
        _throwsContaining('regex parse error'),
      );
    });

    test('case sensitive search', () async {
      expect(await grep(const GrepRequest(pattern: 'Error')), hasLength(3));
    });

    test('case insensitive search', () async {
      expect(
        (await grep(const GrepRequest(pattern: 'ERROR', caseInsensitive: true))).length,
        greaterThanOrEqualTo(3),
      );
    });

    test('filter by file type', () async {
      final matches = await grep(const GrepRequest(pattern: 'error', fileType: 'go'));
      expect(matches, isNotEmpty);
      for (final match in matches) {
        expect(match.path, endsWith('.go'));
      }
    });

    test('filter by glob pattern', () async {
      final matches = await grep(const GrepRequest(pattern: 'Error', glob: '*.go'));
      expect(matches, isNotEmpty);
      for (final match in matches) {
        expect(match.path, endsWith('.go'));
      }
    });

    // Differs by design: ripgrep's failure text.
    test('invalid glob pattern', () async {
      await expectLater(
        grep(const GrepRequest(pattern: 'error', glob: '[invalid')),
        _throwsContaining('error parsing glob'),
      );
    });

    test('search in specific path', () async {
      final matches = await grep(const GrepRequest(pattern: 'Error', path: '/dir'));
      expect(matches, isNotEmpty);
      for (final match in matches) {
        expect(match.path, startsWith(at('/dir')));
      }
    });

    // Differs by design: a missing path is ripgrep's exit code 2.
    test('search with non-existent path', () async {
      await expectLater(
        grep(const GrepRequest(pattern: 'error', path: '/nonexistent')),
        _throwsContaining('ripgrep failed with exit code 2'),
      );
    });

    test('regex pattern matching', () async {
      expect(
        (await grep(const GrepRequest(pattern: r'log\..*Error'))).length,
        greaterThanOrEqualTo(1),
      );
    });

    test('no matches found', () async {
      expect(await grep(const GrepRequest(pattern: 'nonexistent_pattern_xyz')), isEmpty);
    });

    test('match line numbers', () async {
      final matches =
          await grep(const GrepRequest(pattern: r'log\.Error', fileType: 'go'));
      expect(matches, hasLength(2));
      for (final match in matches) {
        expect(match.line, greaterThan(0));
      }
    });

    test('match content is returned', () async {
      final matches = await grep(const GrepRequest(pattern: 'package main'));
      expect(matches.any((m) => m.content.contains('package main')), isTrue);
    });
  });

  group('TestInMemoryBackend_GrepRaw_WithContext', () {
    setUp(() => put('/context.txt', 'line1\nline2\ntarget line\nline4\nline5\nline6'));

    Future<List<GrepMatch>> grep({
      int before = 0,
      int after = 0,
      String path = '',
    }) =>
        backend.grepRaw(
          ctx,
          GrepRequest(
            pattern: 'target',
            path: path.isEmpty ? root : at(path),
            beforeLines: before,
            afterLines: after,
          ),
        );

    test('with before context', () async {
      expect((await grep(before: 2)).length, greaterThanOrEqualTo(3));
    });

    test('with after context', () async {
      expect((await grep(after: 2)).length, greaterThanOrEqualTo(3));
    });

    test('with both before and after context', () async {
      final matches = await grep(before: 1, after: 1);
      expect([for (final m in matches) m.line], [2, 3, 4]);
    });

    test('context at file boundaries', () async {
      await put('/boundary.txt', 'first line target\nsecond line');
      final matches = await grep(path: '/boundary.txt', before: 5, after: 5);
      expect([for (final m in matches) m.line], [1, 2]);
    });

    test('zero context lines', () async {
      expect(await grep(), hasLength(1));
    });

    test('negative context lines treated as zero', () async {
      expect(await grep(before: -5, after: -5), hasLength(1));
    });
  });

  group('TestInMemoryBackend_GrepRaw_Multiline', () {
    setUp(() => put('/multiline.txt', 'start\nmiddle line\nend'));

    test('single line mode (default)', () async {
      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(pattern: 'start.*end', path: root),
      );
      expect(matches, isEmpty);
    });

    test('multiline mode enabled', () async {
      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(pattern: r'start[\s\S]*end', path: root, enableMultiline: true),
      );
      expect(matches, isNotEmpty);
    });

    test('multiline with multiple matches', () async {
      await put(
        '/multiline2.txt',
        'block1 start\nblock1 middle\nblock1 end\n\nblock2 start\nblock2 end',
      );
      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(
          pattern: r'start[\s\S]*?end',
          path: at('/multiline2.txt'),
          enableMultiline: true,
        ),
      );
      // Two blocks: lines 1-3 and 5-6 (line 4 separates them).
      expect([for (final m in matches) m.line], [1, 5]);
    });

    // Differs by design: ripgrep reports a multiline match once, numbered by
    // its first line, with all its lines as content (the in-memory backend:
    // one result per line, so line 6 holds ") {").
    test('multiline with multiple matches v2', () async {
      const content = '\n'
          'const a = 1;\n'
          'function calculateTotal(\n'
          '  items,\n'
          '  discount\n'
          ') {\n'
          '  return items.reduce((sum, item) => sum + item.price, 0);\n'
          '}\n';
      await put('/multiline3.txt', content);
      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(
          pattern: r'function calculateTotal\([^\)]*\)',
          path: at('/multiline3.txt'),
          enableMultiline: true,
        ),
      );
      expect(matches, [
        GrepMatch(
          path: at('/multiline3.txt'),
          line: 3,
          content: 'function calculateTotal(\n  items,\n  discount\n) {',
        ),
      ]);
    });
  });

  group('TestInMemoryBackend_GrepRaw_EmptyFiles', () {
    test('search in empty file', () async {
      await put('/empty.txt', '');
      expect(
        await backend.grepRaw(ctx, GrepRequest(pattern: 'anything', path: root)),
        isEmpty,
      );
    });

    test('search with no files', () async {
      expect(
        await backend.grepRaw(ctx, GrepRequest(pattern: 'anything', path: root)),
        isEmpty,
      );
    });
  });

  group('TestInMemoryBackend_GrepRaw_SpecialCharacters', () {
    setUp(
      () => put(
        '/special.txt',
        'interface{}\nmap[string]int\nfunc() error\n'
            r'$variable'
            '\n*pointer',
      ),
    );

    for (final (name, pattern) in [
      ('match curly braces', r'interface\{\}'),
      ('match square brackets', r'map\[.*\]'),
      ('match parentheses', r'func\(\)'),
      ('match dollar sign', r'\$variable'),
      ('match asterisk', r'\*pointer'),
    ]) {
      test(name, () async {
        expect(
          await backend.grepRaw(ctx, GrepRequest(pattern: pattern, path: root)),
          hasLength(1),
        );
      });
    }
  });

  group('TestInMemoryBackend_GrepRaw_Concurrent', () {
    test('concurrent grep operations', () async {
      for (var i = 0; i < 10; i++) {
        await put('/file$i.txt', 'content$i with error message');
      }
      final results = await Future.wait([
        for (var i = 0; i < 10; i++)
          backend.grepRaw(ctx, GrepRequest(pattern: 'error', path: root)),
      ]);
      for (final matches in results) {
        expect(matches, hasLength(10));
      }
    });

    test('parallel file processing', () async {
      for (var i = 0; i < 100; i++) {
        await put(
          '/large/file$i.go',
          'package main\nimport "log"\nfunc test$i() {\n\tlog.Error("error $i")\n}',
        );
      }
      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(pattern: r'log\.Error', fileType: 'go', path: root),
      );
      expect(matches, hasLength(100));
    });

    test('single file no parallelism', () async {
      await put('/single.txt', 'error line 1\nerror line 2\nerror line 3');
      expect(
        await backend.grepRaw(ctx, GrepRequest(pattern: 'error', path: root)),
        hasLength(3),
      );
    });

    // Differs by design: a missing path fails (ripgrep); an empty directory
    // has no files to search.
    test('empty files list', () async {
      Directory(at('/empty')).createSync();
      expect(
        await backend.grepRaw(
          ctx,
          GrepRequest(pattern: 'anything', path: at('/empty')),
        ),
        isEmpty,
      );
    });

    test('concurrent operations are safe', () async {
      for (var i = 0; i < 20; i++) {
        await put('/concurrent/file$i.txt', 'line1\nline2\npattern$i\nline4');
      }
      final results = await Future.wait([
        for (var i = 0; i < 5; i++)
          backend.grepRaw(ctx, GrepRequest(pattern: r'pattern\d+', path: root)),
      ]);
      for (final matches in results) {
        expect(matches, hasLength(20));
      }
    });
  });

  group('TestInMemoryBackend_GrepRaw_ComplexScenarios', () {
    setUp(() async {
      await put(
        '/project/src/main.go',
        'package main\nimport "log"\nfunc main() {\n\tlog.Error("error")\n}',
      );
      await put(
        '/project/src/utils/helper.go',
        'package utils\nfunc Helper() error {\n\treturn nil\n}',
      );
      await put(
        '/project/test/main_test.go',
        'package main\nimport "testing"\nfunc TestMain(t *testing.T) {\n}',
      );
    });

    test('combine path and file type filters', () async {
      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(pattern: 'package', path: at('/project/src'), fileType: 'go'),
      );
      expect(matches, hasLength(2));
      for (final match in matches) {
        expect(match.path, startsWith(at('/project/src')));
        expect(match.path, endsWith('.go'));
      }
    });

    test('complex regex with case insensitive', () async {
      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(pattern: r'func\s+\w+', caseInsensitive: true, path: root),
      );
      expect(matches, isNotEmpty);
    });

    test('glob with directory structure', () async {
      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(pattern: 'package', glob: '*_test.go', path: root),
      );
      expect(matches, hasLength(1));
      expect(matches.single.path, endsWith('_test.go'));
    });

    test('glob with recursive pattern', () async {
      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(pattern: 'package', glob: '**/*.go', path: root),
      );
      expect(matches, hasLength(3));
      for (final match in matches) {
        expect(match.path, endsWith('.go'));
      }
    });

    // Differs by design: ripgrep matches a glob with a `/` against the path
    // relative to the working directory, so with an absolute search path
    // elsewhere it matches nothing (as in Go); searched from the project
    // directory, it works as in the in-memory backend.
    test('glob with path prefix', () async {
      expect(
        await backend.grepRaw(
          ctx,
          GrepRequest(pattern: 'package', glob: 'src/**/*.go', path: at('/project')),
        ),
        isEmpty,
      );
      final previous = Directory.current;
      Directory.current = Directory(at('/project'));
      try {
        final matches = await backend.grepRaw(
          ctx,
          const GrepRequest(pattern: 'package', glob: 'src/**/*.go'),
        );
        expect(matches, hasLength(2));
        for (final match in matches) {
          expect(match.path, startsWith('./src'));
          expect(match.path, endsWith('.go'));
        }
      } finally {
        Directory.current = previous;
      }
    });

    test('glob simple filename pattern', () async {
      final matches = await backend.grepRaw(
        ctx,
        GrepRequest(pattern: 'package', glob: 'main.go', path: root),
      );
      expect(matches, hasLength(1));
      for (final match in matches) {
        expect(match.path.split('/').last, 'main.go');
      }
    });
  });

  group('TestInMemoryBackend_Read_Scenarios', () {
    test('empty file returns empty content', () async {
      await put('/empty.txt', '');
      final content = await backend.read(ctx, ReadRequest(filePath: at('/empty.txt')));
      expect(content.content, '');
    });

    test('single-line file without newline', () async {
      await put('/single.txt', 'hello');
      final content = await backend.read(ctx, ReadRequest(filePath: at('/single.txt')));
      expect(content.content, 'hello');
    });

    test('offset 0 and offset 1 both start from first line', () async {
      await put('/f.txt', 'a\nb\nc');
      final c0 = await backend.read(
        ctx,
        ReadRequest(filePath: at('/f.txt'), offset: 0, limit: 1),
      );
      final c1 = await backend.read(
        ctx,
        ReadRequest(filePath: at('/f.txt'), offset: 1, limit: 1),
      );
      expect(c0.content, c1.content);
      expect(c0.content, 'a');
    });

    // Differs by design: eino-ext's local Read drops the trailing line break.
    test('file with trailing newline preserves trailing empty line', () async {
      await put('/trail.txt', 'line1\nline2\n');
      final content = await backend.read(ctx, ReadRequest(filePath: at('/trail.txt')));
      expect(content.content, 'line1\nline2');
    });

    test('offset exactly at last line', () async {
      await put('/f.txt', 'a\nb\nc');
      final content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/f.txt'), offset: 3, limit: 10),
      );
      expect(content.content, 'c');
    });

    test('offset one beyond last line returns empty', () async {
      await put('/f.txt', 'a\nb\nc');
      final content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/f.txt'), offset: 4, limit: 10),
      );
      expect(content.content, '');
    });

    test('limit=1 reads exactly one line', () async {
      await put('/f.txt', 'a\nb\nc');
      for (final (i, expected) in ['a', 'b', 'c'].indexed) {
        final content = await backend.read(
          ctx,
          ReadRequest(filePath: at('/f.txt'), offset: i + 1, limit: 1),
        );
        expect(content.content, expected, reason: 'line ${i + 1}');
      }
    });

    test('sliding window reads consecutive ranges correctly', () async {
      await put('/f.txt', 'l1\nl2\nl3\nl4\nl5');
      const tests = [
        (offset: 1, limit: 2, expected: 'l1\nl2'),
        (offset: 2, limit: 2, expected: 'l2\nl3'),
        (offset: 3, limit: 2, expected: 'l3\nl4'),
        (offset: 4, limit: 2, expected: 'l4\nl5'),
        (offset: 5, limit: 2, expected: 'l5'),
      ];
      for (final tt in tests) {
        final content = await backend.read(
          ctx,
          ReadRequest(filePath: at('/f.txt'), offset: tt.offset, limit: tt.limit),
        );
        expect(content.content, tt.expected, reason: 'offset=${tt.offset}');
      }
    });

    test('file with only newlines', () async {
      await put('/newlines.txt', '\n\n\n');
      final content = await backend.read(
        ctx,
        ReadRequest(filePath: at('/newlines.txt'), offset: 2, limit: 1),
      );
      expect(content.content, '');
    });
  });

  group('TestInMemoryBackend_Read_NoLimit', () {
    test('limit=0 reads all lines', () async {
      const fullContent = 'line1\nline2\nline3\nline4\nline5';
      await put('/f.txt', fullContent);
      final content =
          await backend.read(ctx, ReadRequest(filePath: at('/f.txt')));
      expect(content.content, fullContent);
    });

    test('negative limit reads all lines', () async {
      const fullContent = 'a\nb\nc';
      await put('/f.txt', fullContent);
      final content =
          await backend.read(ctx, ReadRequest(filePath: at('/f.txt'), limit: -1));
      expect(content.content, fullContent);
    });

    test('limit=0 with offset reads from offset to end', () async {
      await put('/f.txt', 'a\nb\nc\nd\ne');
      final content =
          await backend.read(ctx, ReadRequest(filePath: at('/f.txt'), offset: 3));
      expect(content.content, 'c\nd\ne');
    });

    test('limit=0 with offset beyond content returns empty', () async {
      await put('/f.txt', 'a\nb');
      final content =
          await backend.read(ctx, ReadRequest(filePath: at('/f.txt'), offset: 10));
      expect(content.content, '');
    });

    // Differs by design: without a limit eino-ext's local Read returns at
    // most 2000 lines.
    test('limit=0 reads file with more than 2000 lines', () async {
      await put(
        '/big.txt',
        [for (var i = 1; i <= 2500; i++) 'line$i'].join('\n'),
      );
      final content =
          await backend.read(ctx, ReadRequest(filePath: at('/big.txt')));
      final lines = content.content.split('\n');
      expect(lines, hasLength(2000));
      expect(lines.last, 'line2000');
    });
  });
}
