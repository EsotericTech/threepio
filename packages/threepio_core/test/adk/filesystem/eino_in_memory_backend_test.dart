// Ports eino v0.9.22 `adk/filesystem/backend_inmemory_test.go`, all 25 tests:
//   TestInMemoryBackend_WriteAndRead, TestInMemoryBackend_LsInfo,
//   TestInMemoryBackend_QueryResultsAreDeterministic, TestInMemoryBackend_Edit,
//   TestInMemoryBackend_LsInfo_PathIsFilename, TestInMemoryBackend_GlobInfo,
//   TestInMemoryBackend_GlobInfo_RelativePath,
//   TestInMemoryBackend_GlobInfo_RecursivePattern,
//   TestInMemoryBackend_Concurrent, TestInMemoryBackend_LsInfo_FileInfoMetadata,
//   TestInMemoryBackend_GlobInfo_FileInfoMetadata,
//   TestInMemoryBackend_WriteAndEdit_ModifiedAt,
//   TestInMemoryBackend_Read_EdgeCases, TestInMemoryBackend_Edit_EdgeCases,
//   TestInMemoryBackend_NormalizePath, TestInMemoryBackend_MatchFileType,
//   TestInMemoryBackend_GrepRaw, TestInMemoryBackend_GrepRaw_WithContext,
//   TestInMemoryBackend_GrepRaw_Multiline, TestInMemoryBackend_GrepRaw_EmptyFiles,
//   TestInMemoryBackend_GrepRaw_SpecialCharacters,
//   TestInMemoryBackend_GrepRaw_Concurrent,
//   TestInMemoryBackend_GrepRaw_ComplexScenarios,
//   TestInMemoryBackend_Read_Scenarios, TestInMemoryBackend_Read_NoLimit.
// BenchmarkInMemoryBackend_GrepRaw is a benchmark, not a test: not ported.
//
// Go sub-tests that share the backend of their test function share it here
// too (created and filled in `setUpAll`, tests run in declaration order).
// Go's `time.Sleep` for distinct modification times is `fakeAsync` time.
import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/adk/filesystem/in_memory_backend.dart';
import 'package:threepio_core/src/adk/filesystem/requests.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';

final ctx = RunContext.background();

/// Go's `require.Error` on a backend call.
final Matcher _throwsError = throwsA(isA<ThreepioException>());

/// Go's `err != nil && strings.Contains(err.Error(), text)`.
Matcher _throwsContaining(String text) => throwsA(
      isA<ThreepioException>().having((e) => '$e', 'toString()', contains(text)),
    );

/// What Go's `time.Parse(time.RFC3339Nano, s)` accepts.
final _rfc3339 = RegExp(
  r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$',
);

/// Go's `fileInfoPaths`.
List<String> _fileInfoPaths(List<FileInfo> infos) => [
      for (final info in infos) info.path,
    ];

/// Go's `len(s)`: the UTF-8 byte length.
int _len(String s) => utf8.encode(s).length;

/// Runs [future] to completion inside [async] and returns its value.
T _settle<T>(FakeAsync async, Future<T> future) {
  T? value;
  Object? error;
  StackTrace stackTrace = StackTrace.empty;
  var done = false;
  unawaited(
    future.then(
      (v) {
        value = v;
        done = true;
      },
      onError: (Object e, StackTrace s) {
        error = e;
        stackTrace = s;
        done = true;
      },
    ),
  );
  async.flushMicrotasks();
  final failure = error;
  if (failure != null) Error.throwWithStackTrace(failure, stackTrace);
  expect(done, isTrue, reason: 'the backend call did not complete');
  return value as T;
}

void main() {
  group('TestInMemoryBackend_WriteAndRead', () {
    test('write, read whole, read a range, read a missing file', () async {
      final backend = InMemoryBackend();

      // Test Write
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/test.txt',
          content: 'line1\nline2\nline3\nline4\nline5',
        ),
      );

      // Test Read - full content
      var content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/test.txt', limit: 100),
      );
      expect(content.content, 'line1\nline2\nline3\nline4\nline5');

      // Test Read - with offset and limit
      content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/test.txt', offset: 1, limit: 2),
      );
      expect(content.content, 'line1\nline2');

      // Test Read - non-existent file
      await expectLater(
        backend.read(
          ctx,
          const ReadRequest(filePath: '/nonexistent.txt', limit: 10),
        ),
        _throwsError,
      );
    });
  });

  group('TestInMemoryBackend_LsInfo', () {
    test('lists the root and a directory', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/file1.txt', content: 'content1'),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/file2.txt', content: 'content2'),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/dir1/file3.txt', content: 'content3'),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/dir1/subdir/file4.txt',
          content: 'content4',
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/dir2/file5.txt', content: 'content5'),
      );

      // Test LsInfo - root
      var infos = await backend.lsInfo(ctx, const LsInfoRequest(path: '/'));
      expect(infos, hasLength(4)); // file1.txt, file2.txt, dir1, dir2

      // Test LsInfo - specific directory
      infos = await backend.lsInfo(ctx, const LsInfoRequest(path: '/dir1'));
      expect(infos, hasLength(2)); // file3.txt, subdir
    });
  });

  group('TestInMemoryBackend_QueryResultsAreDeterministic', () {
    test('lsInfo, globInfo and grepRaw are sorted', () async {
      final backend = InMemoryBackend();
      for (final filePath in ['/z.txt', '/a.txt', '/m.txt']) {
        await backend.write(
          ctx,
          WriteRequest(filePath: filePath, content: 'before\nneedle\nafter'),
        );
      }

      var infos = await backend.lsInfo(ctx, const LsInfoRequest(path: '/'));
      expect(_fileInfoPaths(infos), ['a.txt', 'm.txt', 'z.txt']);

      infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(path: '/', pattern: '*.txt'),
      );
      expect(_fileInfoPaths(infos), ['a.txt', 'm.txt', 'z.txt']);

      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'needle', path: '/', afterLines: 1),
      );
      final gotMatches = [
        for (final match in matches) '${match.path}:${match.line}',
      ];
      expect(gotMatches, [
        '/a.txt:2',
        '/a.txt:3',
        '/m.txt:2',
        '/m.txt:3',
        '/z.txt:2',
        '/z.txt:3',
      ]);
    });
  });

  group('TestInMemoryBackend_Edit', () {
    test('edit errors and replace-all', () async {
      final backend = InMemoryBackend();

      // Create a file
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/edit.txt',
          content: 'hello world\nhello again\nhello world',
        ),
      );

      // Test Edit - report error if old string occurs
      await expectLater(
        backend.edit(
          ctx,
          const EditRequest(
            filePath: '/edit.txt',
            oldString: 'hello',
            newString: 'hi',
            replaceAll: false,
          ),
        ),
        _throwsError,
      );

      // Test Edit - replace all occurrences
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/edit2.txt',
          content: 'hello world\nhello again\nhello world',
        ),
      );
      await backend.edit(
        ctx,
        const EditRequest(
          filePath: '/edit2.txt',
          oldString: 'hello',
          newString: 'hi',
          replaceAll: true,
        ),
      );

      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/edit2.txt', limit: 100),
      );
      expect(content.content, 'hi world\nhi again\nhi world');

      // Test Edit - non-existent file
      await expectLater(
        backend.edit(
          ctx,
          const EditRequest(
            filePath: '/nonexistent.txt',
            oldString: 'old',
            newString: 'new',
            replaceAll: false,
          ),
        ),
        _throwsError,
      );

      // Test Edit - empty oldString
      await expectLater(
        backend.edit(
          ctx,
          const EditRequest(
            filePath: '/edit.txt',
            oldString: '',
            newString: 'new',
            replaceAll: false,
          ),
        ),
        _throwsError,
      );
    });
  });

  group('TestInMemoryBackend_LsInfo_PathIsFilename', () {
    late InMemoryBackend backend;

    setUpAll(() async {
      backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/file1.txt', content: 'content1'),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/file2.txt', content: 'content2'),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/dir1/file3.txt', content: 'content3'),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/dir1/subdir/file4.txt',
          content: 'content4',
        ),
      );
    });

    test('RootDirectory', () async {
      final infos = await backend.lsInfo(ctx, const LsInfoRequest(path: '/'));
      for (final info in infos) {
        expect(
          info.path,
          isNot(contains('/')),
          reason: 'Path should be filename only',
        );
        if (info.isDir) {
          expect(info.path, 'dir1');
        } else {
          expect(info.path, anyOf('file1.txt', 'file2.txt'));
        }
      }
    });

    test('Subdirectory', () async {
      final infos =
          await backend.lsInfo(ctx, const LsInfoRequest(path: '/dir1'));
      for (final info in infos) {
        expect(
          info.path,
          isNot(contains('/')),
          reason: 'Path should be filename only',
        );
        if (info.isDir) {
          expect(info.path, 'subdir');
        } else {
          expect(info.path, 'file3.txt');
        }
      }
    });

    test('NestedSubdirectory', () async {
      final infos = await backend.lsInfo(
        ctx,
        const LsInfoRequest(path: '/dir1/subdir'),
      );
      expect(infos, hasLength(1));

      final info = infos[0];
      expect(info.path, 'file4.txt');
      expect(
        info.path,
        isNot(contains('/')),
        reason: 'Path should be filename only',
      );
    });
  });

  group('TestInMemoryBackend_GlobInfo', () {
    test('matches in the root and in a directory', () async {
      final backend = InMemoryBackend();

      // Create some files
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/file1.txt', content: 'content1'),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/file2.py', content: 'content2'),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/dir1/file3.txt', content: 'content3'),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/dir1/file4.py', content: 'content4'),
      );

      // Test GlobInfo - match .txt files in root only
      var infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(pattern: '*.txt', path: '/'),
      );
      expect(infos, hasLength(1)); // only file1.txt in root
      expect(infos[0].path, 'file1.txt');

      // Test GlobInfo - match all .py files in dir1
      infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(pattern: '*.py', path: '/dir1'),
      );
      expect(infos, hasLength(1)); // file4.py
      expect(infos[0].path, 'file4.py');
    });
  });

  group('TestInMemoryBackend_GlobInfo_RelativePath', () {
    late InMemoryBackend backend;

    setUpAll(() async {
      backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/Users/bytedance/Desktop/github/eino/file1.go',
          content: 'content1',
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath:
              '/Users/bytedance/Desktop/github/openai-go/paginationmanual_test.go',
          content: 'content2',
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath:
              '/Users/bytedance/Desktop/github/openai-go/paginationauto_test.go',
          content: 'content3',
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/Users/bytedance/Desktop/other/test.go',
          content: 'content4',
        ),
      );
    });

    test('GlobFromRootWithPattern', () async {
      final infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(
          pattern: '**/*.go',
          path: '/Users/bytedance/Desktop/github',
        ),
      );
      expect(infos, hasLength(3));
      expect(_fileInfoPaths(infos), unorderedEquals(<String>[
        'eino/file1.go',
        'openai-go/paginationmanual_test.go',
        'openai-go/paginationauto_test.go',
      ]));
    });

    test('GlobFromSubdirectory', () async {
      final infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(
          pattern: '*.go',
          path: '/Users/bytedance/Desktop/github/openai-go',
        ),
      );
      expect(infos, hasLength(2));
      expect(_fileInfoPaths(infos), unorderedEquals(<String>[
        'paginationmanual_test.go',
        'paginationauto_test.go',
      ]));
    });

    test('GlobFromRootWithAbsolutePattern', () async {
      final infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(
          pattern: '/Users/bytedance/Desktop/github/**/*.go',
          path: '/',
        ),
      );
      // Go checks only that each expected absolute path is found.
      expect(_fileInfoPaths(infos), containsAll(<String>[
        '/Users/bytedance/Desktop/github/eino/file1.go',
        '/Users/bytedance/Desktop/github/openai-go/paginationmanual_test.go',
        '/Users/bytedance/Desktop/github/openai-go/paginationauto_test.go',
      ]));
    });

    test('GlobRecursiveWithRelativePattern', () async {
      final infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(
          pattern: '**/*.go',
          path: '/Users/bytedance/Desktop/github',
        ),
      );
      expect(infos, hasLength(3));
      expect(_fileInfoPaths(infos), unorderedEquals(<String>[
        'eino/file1.go',
        'openai-go/paginationmanual_test.go',
        'openai-go/paginationauto_test.go',
      ]));
    });
  });

  group('TestInMemoryBackend_GlobInfo_RecursivePattern', () {
    late InMemoryBackend backend;

    setUpAll(() async {
      backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/project/src/main.go', content: 'main'),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/project/src/utils/helper.go',
          content: 'helper',
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/project/src/utils/deep/nested.go',
          content: 'nested',
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/project/test/test.go', content: 'test'),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/project/README.md', content: 'readme'),
      );
    });

    test('DoubleStarMatchesAllSubdirectories', () async {
      final infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(pattern: '**/*.go', path: '/project'),
      );
      expect(infos, hasLength(4));
      expect(_fileInfoPaths(infos), unorderedEquals(<String>[
        'src/main.go',
        'src/utils/helper.go',
        'src/utils/deep/nested.go',
        'test/test.go',
      ]));
    });

    test('DoubleStarInMiddleOfPattern', () async {
      final infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(pattern: 'src/**/*.go', path: '/project'),
      );
      expect(infos, hasLength(3));
      expect(_fileInfoPaths(infos), unorderedEquals(<String>[
        'src/main.go',
        'src/utils/helper.go',
        'src/utils/deep/nested.go',
      ]));
    });

    test('DoubleStarAtEnd', () async {
      final infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(pattern: 'src/**', path: '/project'),
      );
      expect(infos, hasLength(3));
      // Go checks only that each expected path is found.
      expect(_fileInfoPaths(infos), containsAll(<String>[
        'src/main.go',
        'src/utils/helper.go',
        'src/utils/deep/nested.go',
      ]));
    });

    test('AbsolutePatternWithDoubleStarRecursive', () async {
      final infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(pattern: '/project/**/*.go', path: '/'),
      );
      expect(infos, hasLength(4));
      expect(_fileInfoPaths(infos), unorderedEquals(<String>[
        '/project/src/main.go',
        '/project/src/utils/helper.go',
        '/project/src/utils/deep/nested.go',
        '/project/test/test.go',
      ]));
    });
  });

  group('TestInMemoryBackend_Concurrent', () {
    test('concurrent writes and reads', () async {
      final backend = InMemoryBackend();

      // Test concurrent writes and reads (Go: 10 goroutines).
      await Future.wait([
        for (var i = 0; i < 10; i++)
          () async {
            await backend.write(
              ctx,
              const WriteRequest(filePath: '/concurrent.txt', content: 'content'),
            );
            await backend.read(
              ctx,
              const ReadRequest(filePath: '/concurrent.txt', limit: 10),
            );
          }(),
      ]);
    });
  });

  group('TestInMemoryBackend_LsInfo_FileInfoMetadata', () {
    late InMemoryBackend backend;

    setUpAll(() {
      backend = InMemoryBackend();
    });

    test('FileMetadata', () async {
      const content = 'hello world';
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/test.txt', content: content),
      );

      final infos = await backend.lsInfo(ctx, const LsInfoRequest(path: '/'));
      expect(infos, hasLength(1));

      final info = infos[0];
      expect(info.path, 'test.txt');
      expect(info.isDir, isFalse, reason: 'Expected IsDir to be false for file');
      expect(info.size, _len(content));
      expect(info.modifiedAt, isNotEmpty);
      expect(
        info.modifiedAt,
        matches(_rfc3339),
        reason: 'ModifiedAt is not valid RFC3339 format',
      );
      expect(() => DateTime.parse(info.modifiedAt), returnsNormally);
    });

    test('DirectoryMetadata', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/dir1/file1.txt', content: 'content1'),
      );

      final infos = await backend.lsInfo(ctx, const LsInfoRequest(path: '/'));
      expect(infos, hasLength(1));

      final info = infos[0];
      expect(info.path, 'dir1');
      expect(info.isDir, isTrue, reason: 'Expected IsDir to be true for directory');
      expect(info.size, 0);
      expect(
        info.modifiedAt,
        isNotEmpty,
        reason: 'Expected ModifiedAt to be non-empty for directory',
      );
    });

    test('MixedFilesAndDirectories', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/file1.txt', content: 'content1'),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/dir1/file2.txt', content: 'content2'),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/dir1/subdir/file3.txt',
          content: 'content3',
        ),
      );

      final infos = await backend.lsInfo(ctx, const LsInfoRequest(path: '/'));
      expect(infos, hasLength(2)); // file1.txt, dir1

      var fileCount = 0;
      var dirCount = 0;
      for (final info in infos) {
        if (info.isDir) {
          dirCount++;
          expect(info.path, 'dir1');
        } else {
          fileCount++;
          expect(info.path, 'file1.txt');
          expect(info.size, _len('content1'));
        }
      }

      expect(fileCount, 1);
      expect(dirCount, 1);
    });

    test('SubdirectoryListing', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/dir1/file1.txt', content: 'short'),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/dir1/subdir/file2.txt',
          content: 'longer content here',
        ),
      );

      final infos =
          await backend.lsInfo(ctx, const LsInfoRequest(path: '/dir1'));
      expect(infos, hasLength(2)); // file1.txt, subdir

      for (final info in infos) {
        if (info.path == 'file1.txt') {
          expect(info.isDir, isFalse, reason: 'Expected file1.txt to be a file');
          expect(info.size, _len('short'));
        } else if (info.path == 'subdir') {
          expect(
            info.isDir,
            isTrue,
            reason: 'Expected subdir to be a directory',
          );
        } else {
          fail('Unexpected path: ${info.path}');
        }
      }
    });

    test('DirectoryModifiedAtUsesLatestFile', () {
      fakeAsync((async) {
        final backend = InMemoryBackend();

        _settle(
          async,
          backend.write(
            ctx,
            const WriteRequest(filePath: '/dir1/file1.txt', content: 'content1'),
          ),
        );
        async.elapse(const Duration(milliseconds: 10));

        _settle(
          async,
          backend.write(
            ctx,
            const WriteRequest(filePath: '/dir1/file2.txt', content: 'content2'),
          ),
        );

        final infos =
            _settle(async, backend.lsInfo(ctx, const LsInfoRequest(path: '/')));
        expect(infos, hasLength(1));

        final dirInfo = infos[0];
        expect(dirInfo.isDir, isTrue, reason: 'Expected directory');

        final dirModTime = DateTime.parse(dirInfo.modifiedAt);

        final subInfos = _settle(
          async,
          backend.lsInfo(ctx, const LsInfoRequest(path: '/dir1')),
        );
        var latestFileTime = DateTime.utc(1);
        for (final info in subInfos) {
          final fileTime = DateTime.parse(info.modifiedAt);
          if (fileTime.isAfter(latestFileTime)) latestFileTime = fileTime;
        }

        // Go only logs here (t.Logf), it asserts nothing.
        if (!dirModTime.isAtSameMomentAs(latestFileTime) &&
            dirModTime.isBefore(latestFileTime)) {
          printOnFailure(
            'Directory mod time: $dirModTime, Latest file time: $latestFileTime',
          );
        }
      });
    });
  });

  group('TestInMemoryBackend_GlobInfo_FileInfoMetadata', () {
    late InMemoryBackend backend;

    setUpAll(() {
      backend = InMemoryBackend();
    });

    test('BasicMetadata', () async {
      const content = 'test content';
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/test.txt', content: content),
      );

      final infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(pattern: '*.txt', path: '/'),
      );
      expect(infos, hasLength(1));

      final info = infos[0];
      expect(info.path, 'test.txt');
      expect(info.isDir, isFalse);
      expect(info.size, _len(content));
      expect(info.modifiedAt, isNotEmpty);
    });

    test('MultipleFilesMetadata', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/file1.txt', content: 'short'),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/file2.txt',
          content: 'much longer content',
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/file3.py', content: 'python'),
      );

      final infos = await backend.globInfo(
        ctx,
        const GlobInfoRequest(pattern: '*.txt', path: '/'),
      );
      expect(infos, hasLength(2));

      for (final info in infos) {
        expect(
          info.isDir,
          isFalse,
          reason: 'Expected IsDir to be false for ${info.path}',
        );
        expect(
          info.size,
          greaterThan(0),
          reason: 'Expected positive size for ${info.path}',
        );
        expect(
          info.modifiedAt,
          isNotEmpty,
          reason: 'Expected ModifiedAt to be non-empty for ${info.path}',
        );
      }
    });
  });

  group('TestInMemoryBackend_WriteAndEdit_ModifiedAt', () {
    test('WriteUpdatesModifiedAt', () {
      fakeAsync((async) {
        final backend = InMemoryBackend();
        final beforeWrite = clock.now();
        async.elapse(const Duration(milliseconds: 1));

        _settle(
          async,
          backend.write(
            ctx,
            const WriteRequest(filePath: '/test.txt', content: 'initial content'),
          ),
        );

        async.elapse(const Duration(milliseconds: 1));
        final afterWrite = clock.now();

        final infos =
            _settle(async, backend.lsInfo(ctx, const LsInfoRequest(path: '/')));
        expect(infos, hasLength(1));

        final modTime = DateTime.parse(infos[0].modifiedAt);

        expect(
          modTime.isBefore(beforeWrite) || modTime.isAfter(afterWrite),
          isFalse,
          reason:
              'ModifiedAt $modTime should be between $beforeWrite and $afterWrite',
        );
      });
    });

    test('EditUpdatesModifiedAt', () {
      fakeAsync((async) {
        final backend = InMemoryBackend();
        _settle(
          async,
          backend.write(
            ctx,
            const WriteRequest(filePath: '/edit.txt', content: 'hello world'),
          ),
        );

        final infos1 =
            _settle(async, backend.lsInfo(ctx, const LsInfoRequest(path: '/')));
        expect(infos1, hasLength(1));
        final modTime1 = DateTime.parse(infos1[0].modifiedAt);

        async.elapse(const Duration(milliseconds: 10));

        _settle(
          async,
          backend.edit(
            ctx,
            const EditRequest(
              filePath: '/edit.txt',
              oldString: 'hello',
              newString: 'hi',
              replaceAll: true,
            ),
          ),
        );

        final infos2 =
            _settle(async, backend.lsInfo(ctx, const LsInfoRequest(path: '/')));
        expect(infos2, hasLength(1));
        final modTime2 = DateTime.parse(infos2[0].modifiedAt);

        expect(
          modTime2.isAfter(modTime1),
          isTrue,
          reason: 'ModifiedAt should be updated after edit. '
              'Before: $modTime1, After: $modTime2',
        );
      });
    });

    test('OverwriteUpdatesModifiedAt', () {
      fakeAsync((async) {
        final backend = InMemoryBackend();
        _settle(
          async,
          backend.write(
            ctx,
            const WriteRequest(filePath: '/overwrite.txt', content: 'original'),
          ),
        );

        final infos1 =
            _settle(async, backend.lsInfo(ctx, const LsInfoRequest(path: '/')));
        expect(infos1, hasLength(1));
        final modTime1 = DateTime.parse(infos1[0].modifiedAt);

        async.elapse(const Duration(milliseconds: 10));

        _settle(
          async,
          backend.write(
            ctx,
            const WriteRequest(
              filePath: '/overwrite.txt',
              content: 'new content',
            ),
          ),
        );

        final infos2 =
            _settle(async, backend.lsInfo(ctx, const LsInfoRequest(path: '/')));
        expect(infos2, hasLength(1));
        final modTime2 = DateTime.parse(infos2[0].modifiedAt);

        expect(
          modTime2.isAfter(modTime1),
          isTrue,
          reason: 'ModifiedAt should be updated after overwrite. '
              'Before: $modTime1, After: $modTime2',
        );
      });
    });

    test('SizeUpdatesAfterEdit', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/size.txt', content: 'hello'),
      );

      final infos1 = await backend.lsInfo(ctx, const LsInfoRequest(path: '/'));
      expect(infos1, hasLength(1));
      final size1 = infos1[0].size;

      await backend.edit(
        ctx,
        const EditRequest(
          filePath: '/size.txt',
          oldString: 'hello',
          newString: 'hello world',
          replaceAll: true,
        ),
      );

      final infos2 = await backend.lsInfo(ctx, const LsInfoRequest(path: '/'));
      expect(infos2, hasLength(1));
      final size2 = infos2[0].size;

      expect(
        size2,
        greaterThan(size1),
        reason: 'Size should increase after edit',
      );
      expect(size2, _len('hello world'));
    });
  });

  group('TestInMemoryBackend_Read_EdgeCases', () {
    late InMemoryBackend backend;

    setUpAll(() async {
      backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/test.txt', content: 'line1\nline2\nline3'),
      );
    });

    test('negative offset should be treated as zero', () async {
      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/test.txt', offset: -5, limit: 2),
      );
      expect(content.content, 'line1\nline2');
    });

    test('offset exceeds file length', () async {
      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/test.txt', offset: 100, limit: 10),
      );
      expect(content.content, '');
    });

    test('zero or negative limit should use default 200', () async {
      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/test.txt', offset: 0, limit: 0),
      );
      final lines = content.content.split('\n');
      expect(lines, hasLength(3));
    });

    test('limit exceeds remaining lines', () async {
      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/test.txt', offset: 1, limit: 100),
      );
      final lines = content.content.split('\n');
      expect(lines, hasLength(3));
    });
  });

  group('TestInMemoryBackend_Edit_EdgeCases', () {
    late InMemoryBackend backend;

    setUpAll(() {
      backend = InMemoryBackend();
    });

    test('edit non-existent file', () async {
      await expectLater(
        backend.edit(
          ctx,
          const EditRequest(
            filePath: '/nonexistent.txt',
            oldString: 'old',
            newString: 'new',
          ),
        ),
        _throwsContaining('not found'),
      );
    });

    test('empty oldString', () async {
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/test.txt', content: 'content'),
      );

      await expectLater(
        backend.edit(
          ctx,
          const EditRequest(filePath: '/test.txt', oldString: '', newString: 'new'),
        ),
        _throwsContaining('non-empty'),
      );
    });

    test('oldString not found', () async {
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/test.txt', content: 'hello world'),
      );

      await expectLater(
        backend.edit(
          ctx,
          const EditRequest(
            filePath: '/test.txt',
            oldString: 'notfound',
            newString: 'new',
          ),
        ),
        _throwsContaining('not found in file'),
      );
    });

    test('multiple occurrences with ReplaceAll false', () async {
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/test.txt', content: 'foo bar foo baz'),
      );

      await expectLater(
        backend.edit(
          ctx,
          const EditRequest(
            filePath: '/test.txt',
            oldString: 'foo',
            newString: 'FOO',
            replaceAll: false,
          ),
        ),
        _throwsContaining('multiple occurrences'),
      );
    });

    test('single occurrence with ReplaceAll false', () async {
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/test.txt', content: 'foo bar baz'),
      );

      await backend.edit(
        ctx,
        const EditRequest(
          filePath: '/test.txt',
          oldString: 'foo',
          newString: 'FOO',
          replaceAll: false,
        ),
      );

      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/test.txt', limit: 100),
      );
      expect(content.content, contains('FOO'));
    });

    test('ReplaceAll replaces all occurrences', () async {
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/test.txt', content: 'foo bar foo baz foo'),
      );

      await backend.edit(
        ctx,
        const EditRequest(
          filePath: '/test.txt',
          oldString: 'foo',
          newString: 'FOO',
          replaceAll: true,
        ),
      );

      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/test.txt', limit: 100),
      );
      expect(
        content.content,
        isNot(contains('foo')),
        reason: "Expected all 'foo' to be replaced",
      );
      expect('FOO'.allMatches(content.content), hasLength(3));
    });
  });

  group('TestInMemoryBackend_NormalizePath', () {
    test('paths are normalized on write', () async {
      final backend = InMemoryBackend();
      const testCases = [
        (inputPath: 'test.txt', normalizedPath: '/test.txt'),
        (inputPath: '/test.txt', normalizedPath: '/test.txt'),
        (inputPath: '//test.txt', normalizedPath: '/test.txt'),
        (inputPath: '/dir//file.txt', normalizedPath: '/dir/file.txt'),
        (inputPath: '/dir/../file.txt', normalizedPath: '/file.txt'),
      ];

      for (final tc in testCases) {
        await backend.write(
          ctx,
          WriteRequest(filePath: tc.inputPath, content: 'content'),
        );

        final content = await backend.read(
          ctx,
          ReadRequest(filePath: tc.normalizedPath, limit: 10),
        );
        expect(
          content.content,
          contains('content'),
          reason: 'Content not found for normalized path '
              '${tc.normalizedPath} (from ${tc.inputPath})',
        );
      }
    });
  });

  group('TestInMemoryBackend_MatchFileType', () {
    const testCases = [
      (ext: 'go', fileType: 'go', expected: true),
      (ext: 'py', fileType: 'python', expected: true),
      (ext: 'py', fileType: 'py', expected: true),
      (ext: 'js', fileType: 'js', expected: true),
      (ext: 'ts', fileType: 'typescript', expected: true),
      (ext: 'ts', fileType: 'ts', expected: true),
      (ext: 'cpp', fileType: 'cpp', expected: true),
      (ext: 'c', fileType: 'c', expected: true),
      (ext: 'h', fileType: 'c', expected: true),
      (ext: 'md', fileType: 'markdown', expected: true),
      (ext: 'txt', fileType: 'txt', expected: true),
      (ext: 'go', fileType: 'python', expected: false),
      (ext: 'js', fileType: 'typescript', expected: false),
      (ext: 'unknown', fileType: 'go', expected: false),
    ];

    for (final tc in testCases) {
      test('${tc.ext} matches ${tc.fileType}', () {
        expect(
          matchFileType(tc.ext, tc.fileType),
          tc.expected,
          reason: 'matchFileType("${tc.ext}", "${tc.fileType}")',
        );
      });
    }
  });

  group('TestInMemoryBackend_GrepRaw', () {
    late InMemoryBackend backend;

    setUpAll(() async {
      backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/test.go',
          content: 'package main\nfunc main() {\n\tlog.Error("error")\n'
              '\tfmt.Println("hello")\n}',
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/test.py',
          content: "def hello():\n    print('error')\n    print('world')",
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/dir/file.go',
          content: 'package test\nfunc TestError() {\n'
              '\tlog.Error("test error")\n}',
        ),
      );
    });

    test('basic pattern search', () async {
      final matches =
          await backend.grepRaw(ctx, const GrepRequest(pattern: 'error'));
      expect(matches, hasLength(3));
    });

    test('empty pattern error', () async {
      await expectLater(
        backend.grepRaw(ctx, const GrepRequest(pattern: '')),
        _throwsContaining('cannot be empty'),
      );
    });

    test('invalid regex pattern', () async {
      await expectLater(
        backend.grepRaw(ctx, const GrepRequest(pattern: '[invalid')),
        _throwsContaining('invalid regex'),
      );
    });

    test('case sensitive search', () async {
      final matches =
          await backend.grepRaw(ctx, const GrepRequest(pattern: 'Error'));
      expect(matches, hasLength(3));
    });

    test('case insensitive search', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'ERROR', caseInsensitive: true),
      );
      expect(matches.length, greaterThanOrEqualTo(3));
    });

    test('filter by file type', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'error', fileType: 'go'),
      );
      for (final match in matches) {
        expect(match.path, endsWith('.go'), reason: 'Expected only .go files');
      }
    });

    test('filter by glob pattern', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'Error', glob: '*.go'),
      );
      for (final match in matches) {
        expect(match.path, endsWith('.go'), reason: 'Expected only .go files');
      }
    });

    test('invalid glob pattern', () async {
      await expectLater(
        backend.grepRaw(
          ctx,
          const GrepRequest(pattern: 'error', glob: '[invalid'),
        ),
        _throwsContaining('invalid glob'),
      );
    });

    test('search in specific path', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'Error', path: '/dir'),
      );
      for (final match in matches) {
        expect(
          match.path,
          startsWith('/dir'),
          reason: 'Expected matches only from /dir',
        );
      }
    });

    test('search with non-existent path', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'error', path: '/nonexistent'),
      );
      expect(matches, isEmpty);
    });

    test('regex pattern matching', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: r'log\..*Error'),
      );
      expect(matches.length, greaterThanOrEqualTo(1));
    });

    test('no matches found', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'nonexistent_pattern_xyz'),
      );
      expect(matches, isEmpty);
    });

    test('match line numbers', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: r'log\.Error', fileType: 'go'),
      );
      for (final match in matches) {
        expect(
          match.line,
          greaterThan(0),
          reason: 'Expected positive line number',
        );
      }
    });

    test('match content is returned', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'package main'),
      );
      expect(matches, isNotEmpty, reason: 'Expected at least 1 match');
      expect(
        matches.any((match) => match.content.contains('package main')),
        isTrue,
        reason: "Expected match content to contain 'package main'",
      );
    });
  });

  group('TestInMemoryBackend_GrepRaw_WithContext', () {
    late InMemoryBackend backend;

    setUpAll(() async {
      backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/context.txt',
          content: 'line1\nline2\ntarget line\nline4\nline5\nline6',
        ),
      );
    });

    test('with before context', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'target', beforeLines: 2),
      );
      expect(
        matches.length,
        greaterThanOrEqualTo(3),
        reason: 'Expected at least 3 matches (2 before + target)',
      );
    });

    test('with after context', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'target', afterLines: 2),
      );
      expect(
        matches.length,
        greaterThanOrEqualTo(3),
        reason: 'Expected at least 3 matches (target + 2 after)',
      );
    });

    test('with both before and after context', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'target', beforeLines: 1, afterLines: 1),
      );
      expect(
        matches.length,
        greaterThanOrEqualTo(3),
        reason: 'Expected at least 3 matches (1 before + target + 1 after)',
      );
    });

    test('context at file boundaries', () async {
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/boundary.txt',
          content: 'first line target\nsecond line',
        ),
      );
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(
          pattern: 'target',
          path: '/boundary.txt',
          beforeLines: 5,
          afterLines: 5,
        ),
      );
      expect(matches, isNotEmpty, reason: 'Expected at least 1 match');
    });

    test('zero context lines', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'target', beforeLines: 0, afterLines: 0),
      );
      expect(matches, isNotEmpty, reason: 'Expected at least 1 match');
    });

    test('negative context lines treated as zero', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'target', beforeLines: -5, afterLines: -5),
      );
      expect(matches, isNotEmpty, reason: 'Expected at least 1 match');
    });
  });

  group('TestInMemoryBackend_GrepRaw_Multiline', () {
    late InMemoryBackend backend;

    setUpAll(() async {
      backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/multiline.txt',
          content: 'start\nmiddle line\nend',
        ),
      );
    });

    test('single line mode (default)', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'start.*end', enableMultiline: false),
      );
      expect(
        matches,
        isEmpty,
        reason: 'Expected 0 matches in single-line mode',
      );
    });

    test('multiline mode enabled', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: r'start[\s\S]*end', enableMultiline: true),
      );
      expect(matches, isNotEmpty, reason: 'Expected matches in multiline mode');
    });

    test('multiline with multiple matches', () async {
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/multiline2.txt',
          content: 'block1 start\nblock1 middle\nblock1 end\n\n'
              'block2 start\nblock2 end',
        ),
      );
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(
          pattern: r'start[\s\S]*?end',
          path: '/multiline2.txt',
          enableMultiline: true,
        ),
      );
      expect(matches, isNotEmpty, reason: 'Expected matches in multiline mode');
    });

    test('multiline with multiple matches v2', () async {
      // Go's raw string literal, which starts with a line break.
      const content = '\n'
          'const a = 1;\n'
          'function calculateTotal(\n'
          '  items,\n'
          '  discount\n'
          ') {\n'
          '  return items.reduce((sum, item) => sum + item.price, 0);\n'
          '}\n'
          '\n'
          'const b = 2;\n'
          '\n'
          '/*\n'
          ' * This is a comment\n'
          ' * spanning multiple lines\n'
          ' */\n'
          '\n'
          'class UserService {\n'
          '  constructor(db) {\n'
          '    this.db = db;\n'
          '  }\n'
          '}\n';
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/multiline3.txt', content: content),
      );
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(
          pattern: r'function calculateTotal\([^\)]*\)',
          path: '/multiline3.txt',
          enableMultiline: true,
        ),
      );
      expect(matches, isNotEmpty, reason: 'Expected matches in multiline mode');

      final foundLastLine = matches.any(
        (match) => match.line == 6 && match.content.contains(') {'),
      );
      expect(
        foundLastLine,
        isTrue,
        reason: "Expected to find line 5 with ') {' in content; got "
            '${[for (final m in matches) 'Line ${m.line}: ${m.content}']}',
      );
    });
  });

  group('TestInMemoryBackend_GrepRaw_EmptyFiles', () {
    late InMemoryBackend backend;

    setUpAll(() {
      backend = InMemoryBackend();
    });

    test('search in empty file', () async {
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/empty.txt', content: ''),
      );
      final matches =
          await backend.grepRaw(ctx, const GrepRequest(pattern: 'anything'));
      expect(matches, isEmpty);
    });

    test('search with no files', () async {
      final emptyBackend = InMemoryBackend();
      final matches = await emptyBackend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'anything'),
      );
      expect(matches, isEmpty);
    });
  });

  group('TestInMemoryBackend_GrepRaw_SpecialCharacters', () {
    late InMemoryBackend backend;

    setUpAll(() async {
      backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/special.txt',
          content: 'interface{}\nmap[string]int\nfunc() error\n'
              r'$variable'
              '\n*pointer',
        ),
      );
    });

    test('match curly braces', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: r'interface\{\}'),
      );
      expect(matches, hasLength(1));
    });

    test('match square brackets', () async {
      final matches =
          await backend.grepRaw(ctx, const GrepRequest(pattern: r'map\[.*\]'));
      expect(matches, hasLength(1));
    });

    test('match parentheses', () async {
      final matches =
          await backend.grepRaw(ctx, const GrepRequest(pattern: r'func\(\)'));
      expect(matches, hasLength(1));
    });

    test('match dollar sign', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: r'\$variable'),
      );
      expect(matches, hasLength(1));
    });

    test('match asterisk', () async {
      final matches =
          await backend.grepRaw(ctx, const GrepRequest(pattern: r'\*pointer'));
      expect(matches, hasLength(1));
    });
  });

  group('TestInMemoryBackend_GrepRaw_Concurrent', () {
    late InMemoryBackend backend;

    setUpAll(() async {
      backend = InMemoryBackend();
      for (var i = 0; i < 10; i++) {
        await backend.write(
          ctx,
          WriteRequest(
            filePath: '/file$i.txt',
            content: 'content$i with error message',
          ),
        );
      }
    });

    test('concurrent grep operations', () async {
      // Go: 10 goroutines.
      await Future.wait([
        for (var i = 0; i < 10; i++)
          backend.grepRaw(ctx, const GrepRequest(pattern: 'error')),
      ]);
    });

    test('parallel file processing', () async {
      final backend = InMemoryBackend();
      for (var i = 0; i < 100; i++) {
        await backend.write(
          ctx,
          WriteRequest(
            filePath: '/large/file$i.go',
            content: 'package main\nimport "log"\nfunc test$i() {\n'
                '\tlog.Error("error $i")\n}',
          ),
        );
      }

      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: r'log\.Error', fileType: 'go'),
      );
      expect(matches, hasLength(100));
    });

    test('single file no parallelism', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/single.txt',
          content: 'error line 1\nerror line 2\nerror line 3',
        ),
      );

      final matches =
          await backend.grepRaw(ctx, const GrepRequest(pattern: 'error'));
      expect(matches, hasLength(3));
    });

    test('empty files list', () async {
      final backend = InMemoryBackend();
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'anything', path: '/nonexistent'),
      );
      expect(matches, isEmpty);
    });

    test('concurrent operations are safe', () async {
      final backend = InMemoryBackend();
      for (var i = 0; i < 20; i++) {
        await backend.write(
          ctx,
          WriteRequest(
            filePath: '/concurrent/file$i.txt',
            content: 'line1\nline2\npattern$i\nline4',
          ),
        );
      }

      // Go: 5 goroutines, each error reported.
      await Future.wait([
        for (var i = 0; i < 5; i++)
          backend.grepRaw(ctx, const GrepRequest(pattern: r'pattern\d+')),
      ]);
    });
  });

  group('TestInMemoryBackend_GrepRaw_ComplexScenarios', () {
    late InMemoryBackend backend;

    setUpAll(() async {
      backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/project/src/main.go',
          content: 'package main\nimport "log"\nfunc main() {\n'
              '\tlog.Error("error")\n}',
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/project/src/utils/helper.go',
          content: 'package utils\nfunc Helper() error {\n\treturn nil\n}',
        ),
      );
      await backend.write(
        ctx,
        const WriteRequest(
          filePath: '/project/test/main_test.go',
          content: 'package main\nimport "testing"\n'
              'func TestMain(t *testing.T) {\n}',
        ),
      );
    });

    test('combine path and file type filters', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(
          pattern: 'package',
          path: '/project/src',
          fileType: 'go',
        ),
      );
      for (final match in matches) {
        expect(match.path, startsWith('/project/src'));
        expect(match.path, endsWith('.go'));
      }
    });

    test('complex regex with case insensitive', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: r'func\s+\w+', caseInsensitive: true),
      );
      expect(
        matches,
        isNotEmpty,
        reason: 'Expected at least 1 match for function declarations',
      );
    });

    test('glob with directory structure', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'package', glob: '*_test.go'),
      );
      for (final match in matches) {
        expect(match.path, endsWith('_test.go'), reason: 'Expected test file');
      }
    });

    test('glob with recursive pattern', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'package', glob: '**/*.go'),
      );
      for (final match in matches) {
        expect(match.path, endsWith('.go'), reason: 'Expected .go file');
      }
      expect(
        matches,
        isNotEmpty,
        reason: 'Expected at least 1 match for **/*.go pattern',
      );
    });

    test('glob with path prefix', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(
          pattern: 'package',
          glob: 'src/**/*.go',
          path: '/project',
        ),
      );
      for (final match in matches) {
        expect(match.path, startsWith('/project/src'));
        expect(match.path, endsWith('.go'));
      }
    });

    test('glob simple filename pattern', () async {
      final matches = await backend.grepRaw(
        ctx,
        const GrepRequest(pattern: 'package', glob: 'main.go'),
      );
      for (final match in matches) {
        // Go: filepath.Base(match.Path).
        expect(
          match.path.split('/').last,
          'main.go',
          reason: "Expected filename 'main.go', got: ${match.path}",
        );
      }
    });
  });

  group('TestInMemoryBackend_Read_Scenarios', () {
    test('empty file returns empty content', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/empty.txt', content: ''),
      );

      final content =
          await backend.read(ctx, const ReadRequest(filePath: '/empty.txt'));
      expect(content.content, '');
    });

    test('single-line file without newline', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/single.txt', content: 'hello'),
      );

      final content =
          await backend.read(ctx, const ReadRequest(filePath: '/single.txt'));
      expect(content.content, 'hello');
    });

    test('offset 0 and offset 1 both start from first line', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/f.txt', content: 'a\nb\nc'),
      );

      final c0 = await backend.read(
        ctx,
        const ReadRequest(filePath: '/f.txt', offset: 0, limit: 1),
      );
      final c1 = await backend.read(
        ctx,
        const ReadRequest(filePath: '/f.txt', offset: 1, limit: 1),
      );
      expect(
        c0.content,
        c1.content,
        reason: 'Offset=0 and Offset=1 should return the same first line',
      );
      expect(c0.content, 'a');
    });

    test('file with trailing newline preserves trailing empty line', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/trail.txt', content: 'line1\nline2\n'),
      );

      final content =
          await backend.read(ctx, const ReadRequest(filePath: '/trail.txt'));
      expect(content.content, 'line1\nline2\n');
      final lines = content.content.split('\n');
      expect(lines, hasLength(3)); // ["line1", "line2", ""]
    });

    test('offset exactly at last line', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/f.txt', content: 'a\nb\nc'),
      );

      // Offset=3 (1-based) → last line "c"
      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/f.txt', offset: 3, limit: 10),
      );
      expect(content.content, 'c');
    });

    test('offset one beyond last line returns empty', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/f.txt', content: 'a\nb\nc'),
      );

      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/f.txt', offset: 4, limit: 10),
      );
      expect(content.content, '');
    });

    test('limit=1 reads exactly one line', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/f.txt', content: 'a\nb\nc'),
      );

      for (final (i, expected) in ['a', 'b', 'c'].indexed) {
        final content = await backend.read(
          ctx,
          ReadRequest(filePath: '/f.txt', offset: i + 1, limit: 1),
        );
        expect(content.content, expected, reason: 'line ${i + 1}');
      }
    });

    test('sliding window reads consecutive ranges correctly', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/f.txt', content: 'l1\nl2\nl3\nl4\nl5'),
      );

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
          ReadRequest(filePath: '/f.txt', offset: tt.offset, limit: tt.limit),
        );
        expect(
          content.content,
          tt.expected,
          reason: 'offset=${tt.offset} limit=${tt.limit}',
        );
      }
    });

    test('file with only newlines', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/newlines.txt', content: '\n\n\n'),
      );

      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/newlines.txt', offset: 2, limit: 1),
      );
      // Line 2 is an empty string between two newlines
      expect(content.content, '');
    });
  });

  group('TestInMemoryBackend_Read_NoLimit', () {
    test('limit=0 reads all lines', () async {
      final backend = InMemoryBackend();
      const fullContent = 'line1\nline2\nline3\nline4\nline5';
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/f.txt', content: fullContent),
      );

      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/f.txt', limit: 0),
      );
      expect(content.content, fullContent);
    });

    test('negative limit reads all lines', () async {
      final backend = InMemoryBackend();
      const fullContent = 'a\nb\nc';
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/f.txt', content: fullContent),
      );

      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/f.txt', limit: -1),
      );
      expect(content.content, fullContent);
    });

    test('limit=0 with offset reads from offset to end', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/f.txt', content: 'a\nb\nc\nd\ne'),
      );

      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/f.txt', offset: 3, limit: 0),
      );
      expect(content.content, 'c\nd\ne');
    });

    test('limit=0 with offset beyond content returns empty', () async {
      final backend = InMemoryBackend();
      await backend.write(
        ctx,
        const WriteRequest(filePath: '/f.txt', content: 'a\nb'),
      );

      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/f.txt', offset: 10, limit: 0),
      );
      expect(content.content, '');
    });

    test('limit=0 reads file with more than 2000 lines', () async {
      final backend = InMemoryBackend();
      final b = StringBuffer();
      const totalLines = 2500;
      for (var i = 1; i <= totalLines; i++) {
        if (i > 1) b.write('\n');
        b.write('line$i');
      }
      final fullContent = b.toString();
      await backend.write(
        ctx,
        WriteRequest(filePath: '/big.txt', content: fullContent),
      );

      final content = await backend.read(
        ctx,
        const ReadRequest(filePath: '/big.txt', limit: 0),
      );
      expect(
        content.content == fullContent,
        isTrue,
        reason: 'expected all $totalLines lines, got '
            '${'\n'.allMatches(content.content).length + 1} lines',
      );
    });
  });
}
