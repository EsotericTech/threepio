// Ports eino-ext `adk/backend/local/local_test.go`, the filesystem tests:
//   TestLsInfo, TestRead, TestWrite, TestEdit, TestGrepRaw, TestGlobInfo,
//   TestPathCleaning, TestResolveMultiModalReadConfig, TestParsePagesParam,
//   TestDetectImageMIME, TestIsPDFBytes, TestLocal_MultiModalRead_NonMedia,
//   TestLocal_MultiModalRead_Image, TestLocal_MultiModalRead_BadImageContent,
//   TestLocal_MultiModalRead_OversizeImage,
//   TestLocal_MultiModalRead_BadPDFContent, TestLocal_ReadAllBytes_NotFound,
//   TestLocal_ReadAllBytes_Directory, and TestLocal_MultiModalRead_PagedPDF
//   (adapted, see below). TestExecute and TestExecuteStreaming are in
//   local_shell_test.dart.
// Not ported: TestRenderPDFPagesToImages_Success, _DefaultDPI,
//   _RespectsCanceledCtx and TestResolvePDFiumPoolConfig — they test the
//   PDFium renderer and its worker pool, which this port does not have (plan
//   §2.4).
// Adapted:
// * TestGrepRaw: Go puts a fake `rg` script on PATH and checks how its JSON
//   is parsed; the port searches in-process, so each sub-test writes the
//   files whose search gives that output and checks the same fields.
// * TestLocal_MultiModalRead_PagedPDF: reading PDF pages needs PDFium; the
//   three sub-tests check that a paged read of the same minimal PDF fails
//   with the port's "not supported" error (the start-page sub-test fails in
//   both).
// * TestResolveMultiModalReadConfig: the PDFRenderDPI and
//   PDFiumAcquireTimeout assertions are dropped with those fields.
// * Paths Go takes outside its temporary directory (`/non-existent-dir`,
//   `/non-existent-file.txt`, `/no/such/file/here`) are taken inside it.
// * TestPathCleaning: Go's "dirty" paths go through filepath.Join, which
//   cleans them; the port passes really dirty paths.
// The groups whose names end in "(port)" hold the tests written for this
// port.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/src/adk/filesystem/backend.dart';
import 'package:threepio_core/src/adk/filesystem/local_backend.dart';
import 'package:threepio_core/src/adk/filesystem/requests.dart';
import 'package:threepio_core/src/components/model/cancel_token.dart';
import 'package:threepio_core/src/core/run_context.dart';
import 'package:threepio_core/src/errors.dart';

final ctx = RunContext.background();

final RunContext _cancelled =
    RunContext.background(cancelToken: CancelToken()..cancel('stop'));

/// A [ThreepioException] whose message is (or matches) [message].
Matcher _throwsMessage(Object message) => throwsA(
      isA<ThreepioException>().having((e) => e.message, 'message', message),
    );

/// Go's `assert.Error`.
final Matcher _throwsError = throwsA(isA<ThreepioException>());

void _write(String path, String content) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
}

void _writeBytes(String path, List<int> bytes) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
}

/// Runs [body] with the process's working directory set to [directory].
Future<T> _inDirectory<T>(Directory directory, Future<T> Function() body) async {
  final previous = Directory.current;
  Directory.current = directory;
  try {
    return await body();
  } finally {
    Directory.current = previous;
  }
}

/// Makes [path] unreadable for this test; `false` when that has no effect
/// (the tests run as root).
bool _lock(String path) {
  Process.runSync('chmod', ['000', path]);
  addTearDown(() => Process.runSync('chmod', ['755', path]));
  try {
    if (FileSystemEntity.isDirectorySync(path)) {
      Directory(path).listSync();
    } else {
      File(path).readAsBytesSync();
    }
    return false;
  } on FileSystemException {
    return true;
  }
}

List<String> _paths(List<FileInfo> infos) => [for (final i in infos) i.path];

List<String> _hits(List<GrepMatch> matches) =>
    [for (final m in matches) '${m.path}:${m.line}'];

/// Go's `minimalValidPDF`, a hand-made one-page PDF.
final Uint8List _minimalValidPdf = Uint8List.fromList([
  ...latin1.encode('%PDF-1.1\n%'),
  0xa5,
  0xb1,
  0xeb,
  ...latin1.encode(
    '\n\n1 0 obj\n  << /Type /Catalog\n     /Pages 2 0 R\n  >>\nendobj\n\n'
    '2 0 obj\n  << /Type /Pages\n     /Kids [3 0 R]\n     /Count 1\n'
    '     /MediaBox [0 0 100 100]\n  >>\nendobj\n\n3 0 obj\n'
    '  <<  /Type /Page\n      /Parent 2 0 R\n      /Resources << >>\n  >>\n'
    'endobj\n\nxref\n0 4\n0000000000 65535 f \n0000000018 00000 n \n'
    '0000000077 00000 n \n0000000178 00000 n \ntrailer\n  <<  /Root 1 0 R\n'
    '      /Size 4\n  >>\nstartxref\n240\n%%EOF\n',
  ),
]);

const String _unsupportedPages = 'paged PDF reading is not supported';

void main() {
  late Directory tmp;
  late String dir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('threepio_p11_');
    dir = tmp.path;
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('TestLsInfo', () {
    final s = LocalFilesystemBackend();

    test('list directory successfully', () async {
      _write('$dir/file1.txt', '');
      Directory('$dir/subdir').createSync();

      final files = await s.lsInfo(ctx, LsInfoRequest(path: dir));
      expect(files, hasLength(2));
      expect(files[0].path, 'file1.txt');
      expect(files[1].path, 'subdir');
    });

    test('list non-existent directory', () async {
      final files =
          await s.lsInfo(ctx, LsInfoRequest(path: '$dir/non-existent-dir'));
      expect(files, isEmpty);
    });

    test('path is a file, not a directory', () async {
      _write('$dir/file.txt', '');
      await expectLater(
        s.lsInfo(ctx, LsInfoRequest(path: '$dir/file.txt')),
        _throwsError,
      );
    });
  });

  group('TestRead', () {
    final s = LocalFilesystemBackend();

    test('read file successfully', () async {
      _write('$dir/test.txt', 'line 1\nline 2\nline 3');
      final result = await s.read(
        ctx,
        ReadRequest(filePath: '$dir/test.txt', offset: 2, limit: 1),
      );
      expect(result.content, contains('line 2'));
    });

    test('read file from first line (offset=1)', () async {
      _write('$dir/test.txt', 'line 1\nline 2\nline 3');
      final result = await s.read(
        ctx,
        ReadRequest(filePath: '$dir/test.txt', offset: 1, limit: 1),
      );
      expect(result.content, contains('line 1'));
      expect(result.content, isNot(contains('line 2')));
    });

    test('read empty file', () async {
      _write('$dir/empty.txt', '');
      final result = await s.read(ctx, ReadRequest(filePath: '$dir/empty.txt'));
      expect(result.content, '');
    });

    test('read non-existent file', () async {
      await expectLater(
        s.read(ctx, ReadRequest(filePath: '$dir/non-existent-file.txt')),
        _throwsMessage(contains('file not found')),
      );
    });

    test('read large file with pagination', () async {
      _write(
        '$dir/large.txt',
        [for (var i = 1; i <= 1000; i++) 'line $i\n'].join(),
      );
      final result = await s.read(
        ctx,
        ReadRequest(filePath: '$dir/large.txt', offset: 500, limit: 5),
      );
      final lines = result.content.trim().split('\n');
      expect(lines, hasLength(5));
      expect(lines[0], contains('line 500'));
      expect(lines[4], contains('line 504'));
    });
  });

  group('TestWrite', () {
    final s = LocalFilesystemBackend();

    test('write new file successfully', () async {
      await s.write(
        ctx,
        WriteRequest(filePath: '$dir/newfile.txt', content: 'hello'),
      );
      expect(File('$dir/newfile.txt').readAsStringSync(), 'hello');
    });

    test('write to existing file', () async {
      _write('$dir/existing.txt', 'initial');
      await s.write(
        ctx,
        WriteRequest(filePath: '$dir/existing.txt', content: 'new content'),
      );
    });
  });

  group('TestEdit', () {
    final s = LocalFilesystemBackend();

    test('edit file successfully - replace one', () async {
      _write('$dir/test.txt', 'hello world');
      await s.edit(
        ctx,
        EditRequest(filePath: '$dir/test.txt', oldString: 'world', newString: 'go'),
      );
      expect(File('$dir/test.txt').readAsStringSync(), 'hello go');
    });

    test('edit file successfully - replace all', () async {
      _write('$dir/test.txt', 'hello world, beautiful world');
      await s.edit(
        ctx,
        EditRequest(
          filePath: '$dir/test.txt',
          oldString: 'world',
          newString: 'go',
          replaceAll: true,
        ),
      );
      expect(File('$dir/test.txt').readAsStringSync(), 'hello go, beautiful go');
    });

    test('string not found in file', () async {
      _write('$dir/test.txt', 'hello world');
      await expectLater(
        s.edit(
          ctx,
          EditRequest(
            filePath: '$dir/test.txt',
            oldString: 'nonexistent',
            newString: 'go',
          ),
        ),
        _throwsMessage(contains('string not found')),
      );
    });

    test('multiple occurrences without replace_all', () async {
      _write('$dir/test.txt', 'hello world, beautiful world');
      await expectLater(
        s.edit(
          ctx,
          EditRequest(filePath: '$dir/test.txt', oldString: 'world', newString: 'go'),
        ),
        _throwsMessage(contains('appears multiple times')),
      );
    });
  });

  group('TestGrepRaw', () {
    final s = LocalFilesystemBackend();

    test('grep successfully', () async {
      _write('$dir/test.txt', 'hello\ngo\nworld\ngo\n');
      final matches =
          await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'go'));
      expect(matches, hasLength(2));
      expect(matches[0].path, '$dir/test.txt');
      expect(matches[0].line, 2);
      expect(matches[0].content, 'go');
    });

    test('grep with glob', () async {
      _write('$dir/test.txt', 'hello go\n');
      _write('$dir/notes.md', 'go\n');
      final matches = await s.grepRaw(
        ctx,
        GrepRequest(path: dir, pattern: 'go', glob: '*.txt'),
      );
      expect(matches, hasLength(1));
      expect(matches[0].path, endsWith('.txt'));
    });

    test('grep with no matches', () async {
      _write('$dir/test.txt', 'hello\n');
      final matches = await s.grepRaw(
        ctx,
        GrepRequest(path: dir, pattern: 'nonexistent'),
      );
      expect(matches, isEmpty);
    });

    test('grep with empty pattern', () async {
      await expectLater(
        s.grepRaw(ctx, GrepRequest(path: dir, pattern: '')),
        _throwsMessage(contains('pattern is required')),
      );
    });
  });

  group('TestGlobInfo', () {
    final s = LocalFilesystemBackend();

    test('glob successfully', () async {
      _write('$dir/a.txt', '');
      _write('$dir/b.txt', '');
      _write('$dir/c.log', '');
      final files =
          await s.globInfo(ctx, GlobInfoRequest(path: dir, pattern: '*.txt'));
      expect(files, hasLength(2));
      expect(files[0].path, 'a.txt');
      expect(files[1].path, 'b.txt');
    });

    test('glob with no matches', () async {
      final files = await s.globInfo(
        ctx,
        GlobInfoRequest(path: dir, pattern: '*.nonexistent'),
      );
      expect(files, isEmpty);
    });

    test('glob recursive', () async {
      _write('$dir/root.txt', '');
      _write('$dir/sub/sub.txt', '');
      _write('$dir/sub/subsub/deep.txt', '');
      final files =
          await s.globInfo(ctx, GlobInfoRequest(path: dir, pattern: '**/*.txt'));
      expect(files, hasLength(3));
      // Expected paths are relative and use forward slash
      expect(
        _paths(files),
        unorderedEquals(['root.txt', 'sub/sub.txt', 'sub/subsub/deep.txt']),
      );
    });

    test('glob with question mark', () async {
      _write('$dir/file1.txt', '');
      _write('$dir/fileA.txt', '');
      _write('$dir/file10.txt', '');
      final files = await s.globInfo(
        ctx,
        GlobInfoRequest(path: dir, pattern: 'file?.txt'),
      );
      expect(files, hasLength(2));
      expect(_paths(files), unorderedEquals(['file1.txt', 'fileA.txt']));
    });

    test('glob with brackets', () async {
      _write('$dir/file1.txt', '');
      _write('$dir/file2.txt', '');
      _write('$dir/file3.txt', '');
      final files = await s.globInfo(
        ctx,
        GlobInfoRequest(path: dir, pattern: 'file[13].txt'),
      );
      expect(files, hasLength(2));
      expect(_paths(files), unorderedEquals(['file1.txt', 'file3.txt']));
    });
  });

  group('TestPathCleaning', () {
    final s = LocalFilesystemBackend();
    const content = 'hello world';

    setUp(() => _write('$dir/test.txt', content));

    test('Read with dirty path', () async {
      final name = dir.split('/').last;
      final res = await s.read(
        ctx,
        ReadRequest(filePath: '$dir/../$name/./test.txt'),
      );
      expect(res.content, contains(content));
    });

    test('Read with repeated slashes', () async {
      final dirtyPath = '/${'$dir/test.txt'.substring(1)}'.replaceFirst('/', '//');
      expect(dirtyPath, startsWith('//'));
      final res = await s.read(ctx, ReadRequest(filePath: dirtyPath));
      expect(res.content, contains(content));
    });

    test('Write with dirty path', () async {
      // Cleaned lexically: "subdir" never has to exist.
      await s.write(
        ctx,
        WriteRequest(filePath: '$dir/subdir/../write_test.txt', content: 'new content'),
      );
      expect(File('$dir/write_test.txt').existsSync(), isTrue);
      expect(Directory('$dir/subdir').existsSync(), isFalse);
    });

    test('LsInfo with dirty path', () async {
      final files = await s.lsInfo(ctx, LsInfoRequest(path: '$dir/./'));
      expect(_paths(files), contains('test.txt'));
    });

    test('Relative path allowed', () async {
      await _inDirectory(tmp, () async {
        _write('relative/path.txt', content);
        final res =
            await s.read(ctx, const ReadRequest(filePath: 'relative/path.txt'));
        expect(res.content, contains(content));
      });
    });
  });

  group('TestResolveMultiModalReadConfig', () {
    test('zero values fall back to defaults', () {
      final got = const LocalMultiModalReadConfig().resolve();
      expect(got.maxImageSizeMB, LocalMultiModalReadConfig.defaultMaxImageSizeMB);
      expect(got.maxPdfSizeMB, LocalMultiModalReadConfig.defaultMaxPdfSizeMB);
      expect(
        got.maxPagedPdfSizeMB,
        LocalMultiModalReadConfig.defaultMaxPagedPdfSizeMB,
      );
      expect(
        got.maxPdfPagesPerRequest,
        LocalMultiModalReadConfig.defaultMaxPdfPagesPerRequest,
      );
      final zeros = const LocalMultiModalReadConfig(
        maxImageSizeMB: 0,
        maxPdfSizeMB: 0,
        maxPagedPdfSizeMB: 0,
        maxPdfPagesPerRequest: 0,
      ).resolve();
      expect(zeros, got);
    });

    test('user values within caps are preserved', () {
      final got = const LocalMultiModalReadConfig(
        maxImageSizeMB: 15,
        maxPdfSizeMB: 25,
        maxPagedPdfSizeMB: 200,
        maxPdfPagesPerRequest: 50,
      ).resolve();
      expect(got.maxImageSizeMB, 15);
      expect(got.maxPdfSizeMB, 25);
      expect(got.maxPagedPdfSizeMB, 200);
      expect(got.maxPdfPagesPerRequest, 50);
    });

    test('over-cap values are clamped', () {
      final got = const LocalMultiModalReadConfig(
        maxImageSizeMB: 9999,
        maxPdfSizeMB: 9999,
        maxPagedPdfSizeMB: 9999,
        maxPdfPagesPerRequest: 99999,
      ).resolve();
      expect(got.maxImageSizeMB, LocalMultiModalReadConfig.maxConfigurableMB);
      expect(got.maxPdfSizeMB, LocalMultiModalReadConfig.maxConfigurableMB);
      expect(got.maxPagedPdfSizeMB, LocalMultiModalReadConfig.maxConfigurableMB);
      expect(
        got.maxPdfPagesPerRequest,
        LocalMultiModalReadConfig.maxConfigurablePdfPagesPerRequest,
      );
    });

    test('negative values fall back to defaults', () {
      final got = const LocalMultiModalReadConfig(maxImageSizeMB: -1).resolve();
      expect(got.maxImageSizeMB, LocalMultiModalReadConfig.defaultMaxImageSizeMB);
    });
  });

  group('TestParsePagesParam', () {
    const cases = [
      (name: 'single page', pages: '5', maxPages: 20, start: 5, end: 5, wantErr: false),
      (name: 'valid range', pages: '1-3', maxPages: 20, start: 1, end: 3, wantErr: false),
      (name: 'with whitespace', pages: ' 2 - 4 ', maxPages: 20, start: 2, end: 4, wantErr: false),
      (name: 'empty', pages: '', maxPages: 20, start: 0, end: 0, wantErr: true),
      (name: 'open-ended', pages: '1-', maxPages: 20, start: 0, end: 0, wantErr: true),
      (name: 'multi range', pages: '1-2-3', maxPages: 20, start: 0, end: 0, wantErr: true),
      (name: 'non integer', pages: 'a-b', maxPages: 20, start: 0, end: 0, wantErr: true),
      (name: 'zero start', pages: '0', maxPages: 20, start: 0, end: 0, wantErr: true),
      (name: 'end before start', pages: '5-2', maxPages: 20, start: 0, end: 0, wantErr: true),
      (name: 'exceeds maxPages', pages: '1-30', maxPages: 20, start: 0, end: 0, wantErr: true),
      (name: 'non-positive maxPages defaults', pages: '1-3', maxPages: 0, start: 1, end: 3, wantErr: false),
    ];
    for (final tc in cases) {
      test(tc.name, () {
        if (tc.wantErr) {
          expect(() => parsePagesParam(tc.pages, tc.maxPages), _throwsError);
          return;
        }
        expect(parsePagesParam(tc.pages, tc.maxPages), (tc.start, tc.end));
      });
    }
  });

  group('TestDetectImageMIME', () {
    final cases = [
      (name: 'png', data: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00], want: 'image/png'),
      (name: 'jpeg', data: [0xFF, 0xD8, 0xFF, 0xE0], want: 'image/jpeg'),
      (name: 'gif87', data: ascii.encode('GIF87a...'), want: 'image/gif'),
      (name: 'gif89', data: ascii.encode('GIF89a...'), want: 'image/gif'),
      (name: 'bmp', data: ascii.encode('BM12345'), want: 'image/bmp'),
      (name: 'webp', data: [...ascii.encode('RIFF1234WEBP'), 0x00], want: 'image/webp'),
      (name: 'tiff-le', data: [0x49, 0x49, 0x2A, 0x00, 0x00], want: 'image/tiff'),
      (name: 'tiff-be', data: [0x4D, 0x4D, 0x00, 0x2A, 0x00], want: 'image/tiff'),
      (name: 'unknown', data: ascii.encode('hello world'), want: ''),
      (name: 'too short', data: [0x89], want: ''),
    ];
    for (final tc in cases) {
      test(tc.name, () => expect(detectImageMime(tc.data), tc.want));
    }
  });

  group('TestIsPDFBytes', () {
    test('signature', () {
      expect(isPdfBytes(ascii.encode('%PDF-1.7\n...')), isTrue);
      expect(isPdfBytes(ascii.encode('not a pdf')), isFalse);
      expect(isPdfBytes(ascii.encode('%PDF')), isFalse);
    });
  });

  group('TestLocal_MultiModalRead_NonMedia', () {
    test('a text file is read as text', () async {
      final s = LocalFilesystemBackend();
      _write('$dir/hello.txt', 'line1\nline2');
      final resp = await s.multiModalRead(
        ctx,
        MultiModalReadRequest(filePath: '$dir/hello.txt'),
      );
      expect(resp.fileContent, isNotNull);
      expect(resp.fileContent!.content, contains('line1'));
      expect(resp.parts, isEmpty);
    });
  });

  group('TestLocal_MultiModalRead_Image', () {
    final s = LocalFilesystemBackend();
    final cases = [
      (ext: '.png', header: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01], wantMime: 'image/png'),
      (ext: '.jpg', header: [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10], wantMime: 'image/jpeg'),
    ];
    for (final tc in cases) {
      test(tc.ext, () async {
        final path = '$dir/img${tc.ext}';
        _writeBytes(path, tc.header);
        final resp =
            await s.multiModalRead(ctx, MultiModalReadRequest(filePath: path));
        expect(resp.parts, hasLength(1));
        expect(resp.parts[0].type, FileContentPartType.image);
        expect(resp.parts[0].mimeType, tc.wantMime);
        expect(resp.parts[0].data, tc.header);
      });
    }
  });

  group('TestLocal_MultiModalRead_BadImageContent', () {
    test('an image extension needs an image signature', () async {
      final s = LocalFilesystemBackend();
      _write('$dir/fake.png', 'not really png');
      await expectLater(
        s.multiModalRead(ctx, MultiModalReadRequest(filePath: '$dir/fake.png')),
        _throwsMessage(contains('not a recognized image format')),
      );
    });
  });

  group('TestLocal_MultiModalRead_OversizeImage', () {
    test('an image over the limit is refused before it is read', () async {
      // Use a tiny limit so we can exceed it cheaply.
      final s = LocalFilesystemBackend(
        multiModalRead: const LocalMultiModalReadConfig(maxImageSizeMB: 1),
      );
      // 2 MB > 1 MB limit; the content need not be a real PNG.
      _writeBytes('$dir/big.png', Uint8List(2 * 1024 * 1024));
      Object? error;
      try {
        await s.multiModalRead(
          ctx,
          MultiModalReadRequest(filePath: '$dir/big.png'),
        );
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<ThreepioException>());
      expect(
        ThreepioException.findCause<ReadAllBytesTooLargeException>(error),
        isNotNull,
      );
    });
  });

  group('TestLocal_MultiModalRead_BadPDFContent', () {
    test('a .pdf needs the PDF signature', () async {
      final s = LocalFilesystemBackend();
      _write('$dir/fake.pdf', 'not a pdf');
      await expectLater(
        s.multiModalRead(ctx, MultiModalReadRequest(filePath: '$dir/fake.pdf')),
        _throwsMessage(contains('not a valid PDF')),
      );
    });
  });

  group('TestLocal_ReadAllBytes_NotFound', () {
    test('a missing file', () async {
      final s = LocalFilesystemBackend();
      await expectLater(
        s.readAllBytes(ctx, '$dir/no/such/file/here', 1024),
        _throwsMessage(contains('file not found')),
      );
    });
  });

  group('TestLocal_ReadAllBytes_Directory', () {
    test('a directory', () async {
      final s = LocalFilesystemBackend();
      await expectLater(
        s.readAllBytes(ctx, dir, 1024),
        _throwsMessage(contains('directory')),
      );
    });
  });

  group('TestLocal_MultiModalRead_PagedPDF', () {
    final s = LocalFilesystemBackend();
    late String path;

    setUp(() {
      path = '$dir/doc.pdf';
      _writeBytes(path, _minimalValidPdf);
    });

    test('happy path: single page rendered to PNG', () async {
      await expectLater(
        s.multiModalRead(ctx, MultiModalReadRequest(filePath: path, pages: '1')),
        _throwsMessage(startsWith(_unsupportedPages)),
      );
    });

    test('range exceeding totalPages is clamped to last page', () async {
      await expectLater(
        s.multiModalRead(ctx, MultiModalReadRequest(filePath: path, pages: '1-10')),
        _throwsMessage(startsWith(_unsupportedPages)),
      );
    });

    test('start page beyond totalPages returns error', () async {
      await expectLater(
        s.multiModalRead(ctx, MultiModalReadRequest(filePath: path, pages: '5')),
        _throwsError,
      );
    });
  });

  group('LsInfo (port)', () {
    final s = LocalFilesystemBackend();

    test('entries carry only their names, as in Go', () async {
      _write('$dir/file.txt', 'content');
      Directory('$dir/subdir').createSync();
      final files = await s.lsInfo(ctx, LsInfoRequest(path: dir));
      expect(files, const [FileInfo(path: 'file.txt'), FileInfo(path: 'subdir')]);
    });

    test('names are sorted by code point and links are listed', () async {
      _write('$dir/b.txt', '');
      _write('$dir/A.txt', '');
      _write('$dir/~.txt', '');
      Link('$dir/link').createSync('$dir/b.txt');
      final files = await s.lsInfo(ctx, LsInfoRequest(path: dir));
      expect(_paths(files), ['A.txt', 'b.txt', 'link', '~.txt']);
    });

    test('an empty path lists the working directory', () async {
      _write('$dir/here.txt', '');
      final files = await _inDirectory(
        tmp,
        () => s.lsInfo(ctx, const LsInfoRequest()),
      );
      expect(_paths(files), ['here.txt']);
    });

    test('a path that is a file has Go’s error text', () async {
      _write('$dir/file.txt', '');
      final op = Platform.isMacOS ? 'fdopendir' : 'readdirent';
      await expectLater(
        s.lsInfo(ctx, LsInfoRequest(path: '$dir/file.txt')),
        _throwsMessage(
          'failed to read directory: $op $dir/file.txt: not a directory',
        ),
      );
    });

    test('a path through a file fails to open', () async {
      _write('$dir/file.txt', '');
      await expectLater(
        s.lsInfo(ctx, LsInfoRequest(path: '$dir/file.txt/x')),
        _throwsMessage(
          'failed to read directory: open $dir/file.txt/x: not a directory',
        ),
      );
    });
  });

  group('Read (port)', () {
    final s = LocalFilesystemBackend();

    test('without a limit at most 2000 lines are read', () async {
      _write(
        '$dir/big.txt',
        [for (var i = 1; i <= 2500; i++) 'line$i'].join('\n'),
      );
      final content = await s.read(ctx, ReadRequest(filePath: '$dir/big.txt'));
      final lines = content.content.split('\n');
      expect(lines, hasLength(LocalFilesystemBackend.defaultReadLimit));
      expect(lines.last, 'line2000');
      final rest = await s.read(
        ctx,
        ReadRequest(filePath: '$dir/big.txt', offset: 2001, limit: -1),
      );
      expect(rest.content.split('\n'), hasLength(500));
    });

    test('one trailing line break is removed', () async {
      _write('$dir/f.txt', 'a\nb\n\n');
      final content = await s.read(ctx, ReadRequest(filePath: '$dir/f.txt'));
      expect(content.content, 'a\nb\n');
    });

    test(r'lines keep a \r', () async {
      _write('$dir/f.txt', 'a\r\nb\r\n');
      final content = await s.read(ctx, ReadRequest(filePath: '$dir/f.txt'));
      expect(content.content, 'a\r\nb\r');
    });

    test('lines longer than a read chunk', () async {
      final long = List.filled(100000, 'x').join();
      _write('$dir/f.txt', '$long\n${long}y\n${long}z');
      final second = await s.read(
        ctx,
        ReadRequest(filePath: '$dir/f.txt', offset: 2, limit: 1),
      );
      expect(second.content, '${long}y');
      final last = await s.read(
        ctx,
        ReadRequest(filePath: '$dir/f.txt', offset: 3),
      );
      expect(last.content, '${long}z');
    });

    test('an offset after the last line gives nothing', () async {
      _write('$dir/f.txt', 'a\nb');
      final content = await s.read(
        ctx,
        ReadRequest(filePath: '$dir/f.txt', offset: 3, limit: 5),
      );
      expect(content.content, '');
    });

    test('bytes that are not UTF-8 become U+FFFD', () async {
      _writeBytes('$dir/f.txt', [0x61, 0xFF, 0x62]);
      final content = await s.read(ctx, ReadRequest(filePath: '$dir/f.txt'));
      expect(content.content, String.fromCharCodes([0x61, 0xFFFD, 0x62]));
    });

    test('a missing file is a plain ThreepioException with Go’s text', () async {
      final path = '$dir/missing.txt';
      Object? error;
      try {
        await s.read(ctx, ReadRequest(filePath: path));
      } on Object catch (e) {
        error = e;
      }
      expect(
        error,
        isA<ThreepioException>()
            .having((e) => e.message, 'message', 'file not found: $path'),
      );
      expect(error, isNot(isA<FileNotFoundException>()));
    });

    test('a directory cannot be read', () async {
      await expectLater(
        s.read(ctx, ReadRequest(filePath: dir)),
        _throwsMessage('error reading file: read $dir: is a directory'),
      );
    });

    test('a path through a file cannot be opened', () async {
      _write('$dir/f.txt', 'x');
      await expectLater(
        s.read(ctx, ReadRequest(filePath: '$dir/f.txt/y')),
        _throwsMessage('failed to open file: open $dir/f.txt/y: not a directory'),
      );
    });

    test('a cancelled context stops the read', () async {
      _write('$dir/f.txt', 'x');
      await expectLater(
        s.read(_cancelled, ReadRequest(filePath: '$dir/f.txt')),
        throwsA(isA<CancelledException>()),
      );
    });
  });

  group('Write and Edit (port)', () {
    final s = LocalFilesystemBackend();

    test('write creates the parent directories', () async {
      await s.write(ctx, WriteRequest(filePath: '$dir/a/b/c.txt', content: 'deep'));
      expect(File('$dir/a/b/c.txt').readAsStringSync(), 'deep');
    });

    test('write replaces the whole content', () async {
      _write('$dir/f.txt', 'a long first content');
      await s.write(ctx, WriteRequest(filePath: '$dir/f.txt', content: 'short'));
      expect(File('$dir/f.txt').readAsStringSync(), 'short');
    });

    test('write with a file where a parent should be', () async {
      _write('$dir/file.txt', '');
      await expectLater(
        s.write(ctx, WriteRequest(filePath: '$dir/file.txt/x.txt', content: '')),
        _throwsMessage(
          'failed to create parent directory: mkdir $dir/file.txt: not a directory',
        ),
      );
    });

    test('write to a directory', () async {
      Directory('$dir/sub').createSync();
      await expectLater(
        s.write(ctx, WriteRequest(filePath: '$dir/sub', content: '')),
        _throwsMessage('failed to open file for writing: open $dir/sub: is a directory'),
      );
    });

    test('write opens the file write-only, as Go does', () async {
      final path = '$dir/f.txt';
      _write(path, 'old text');
      Process.runSync('chmod', ['200', path]);
      addTearDown(() => Process.runSync('chmod', ['644', path]));
      await s.write(ctx, WriteRequest(filePath: path, content: 'new text'));
      Process.runSync('chmod', ['644', path]);
      expect(File(path).readAsStringSync(), 'new text');
    });

    test('edit errors have Go’s texts', () async {
      _write('$dir/f.txt', 'foo bar foo');
      final path = '$dir/f.txt';
      await expectLater(
        s.edit(ctx, EditRequest(filePath: path, oldString: '', newString: 'x')),
        _throwsMessage('old string is required'),
      );
      await expectLater(
        s.edit(ctx, EditRequest(filePath: path, oldString: 'foo', newString: 'foo')),
        _throwsMessage('new string must be different from old string'),
      );
      await expectLater(
        s.edit(ctx, EditRequest(filePath: path, oldString: 'baz', newString: 'x')),
        _throwsMessage("string not found in file: 'baz'"),
      );
      await expectLater(
        s.edit(ctx, EditRequest(filePath: path, oldString: 'foo', newString: 'x')),
        _throwsMessage(
          "string 'foo' appears multiple times. Use replace_all=True to replace "
          'all occurrences',
        ),
      );
      await expectLater(
        s.edit(
          ctx,
          EditRequest(filePath: '$dir/missing.txt', oldString: 'a', newString: 'b'),
        ),
        _throwsMessage(
          'failed to read file: open $dir/missing.txt: no such file or directory',
        ),
      );
      await expectLater(
        s.edit(ctx, EditRequest(filePath: dir, oldString: 'a', newString: 'b')),
        _throwsMessage('failed to read file: read $dir: is a directory'),
      );
      expect(File(path).readAsStringSync(), 'foo bar foo');
    });

    test('edit keeps bytes that are not UTF-8', () async {
      final path = '$dir/latin1.txt';
      _writeBytes(path, [0xFF, ...ascii.encode('hello world'), 0xFE]);
      await s.edit(ctx, EditRequest(filePath: path, oldString: 'world', newString: 'dart'));
      expect(File(path).readAsBytesSync(), [0xFF, ...ascii.encode('hello dart'), 0xFE]);
    });

    test('occurrences are counted without overlapping', () async {
      final path = '$dir/f.txt';
      _write(path, 'aaa');
      await s.edit(ctx, EditRequest(filePath: path, oldString: 'aa', newString: 'X'));
      expect(File(path).readAsStringSync(), 'Xa');
      _write(path, 'aaaa');
      await s.edit(
        ctx,
        EditRequest(filePath: path, oldString: 'aa', newString: 'b', replaceAll: true),
      );
      expect(File(path).readAsStringSync(), 'bb');
    });

    test('a new string may be empty and delete the old one', () async {
      final path = '$dir/f.txt';
      _write(path, 'keep drop keep');
      await s.edit(ctx, EditRequest(filePath: path, oldString: ' drop', newString: ''));
      expect(File(path).readAsStringSync(), 'keep keep');
    });
  });

  group('GrepRaw (port)', () {
    final s = LocalFilesystemBackend();

    test('paths are the searched path joined with the relative path', () async {
      _write('$dir/a.txt', 'needle\n');
      _write('$dir/sub/b.txt', 'x\nneedle\n');
      expect(
        _hits(await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle'))),
        ['$dir/a.txt:1', '$dir/sub/b.txt:2'],
      );
      expect(
        _hits(
          await s.grepRaw(
            ctx,
            GrepRequest(path: '$dir/sub/b.txt', pattern: 'needle'),
          ),
        ),
        ['$dir/sub/b.txt:2'],
      );
      expect(
        _hits(
          await s.grepRaw(ctx, GrepRequest(path: '$dir/sub/../sub/', pattern: 'needle')),
        ),
        ['$dir/sub/b.txt:2'],
      );
    });

    test('an empty path searches . and a relative path stays relative', () async {
      _write('$dir/a.txt', 'needle\n');
      _write('$dir/sub/b.txt', 'needle\n');
      await _inDirectory(tmp, () async {
        expect(
          _hits(await s.grepRaw(ctx, const GrepRequest(pattern: 'needle'))),
          ['./a.txt:1', './sub/b.txt:1'],
        );
        expect(
          _hits(
            await s.grepRaw(ctx, const GrepRequest(path: 'sub', pattern: 'needle')),
          ),
          ['sub/b.txt:1'],
        );
      });
    });

    test('files are searched in name order, directory by directory', () async {
      for (final name in ['a.txt', 'a/b.txt', 'B.txt', '~.txt']) {
        _write('$dir/$name', 'needle\n');
      }
      expect(
        _hits(await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle'))),
        ['$dir/B.txt:1', '$dir/a/b.txt:1', '$dir/a.txt:1', '$dir/~.txt:1'],
      );
    });

    test('hidden entries are skipped unless given explicitly', () async {
      _write('$dir/.hidden.txt', 'needle\n');
      _write('$dir/.git/config', 'needle\n');
      _write('$dir/visible.txt', 'needle\n');
      expect(
        _hits(await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle'))),
        ['$dir/visible.txt:1'],
      );
      expect(
        _hits(
          await s.grepRaw(ctx, GrepRequest(path: '$dir/.hidden.txt', pattern: 'needle')),
        ),
        ['$dir/.hidden.txt:1'],
      );
      expect(
        _hits(await s.grepRaw(ctx, GrepRequest(path: '$dir/.git', pattern: 'needle'))),
        ['$dir/.git/config:1'],
      );
    });

    test('a glob that matches a hidden file lets it be searched', () async {
      _write('$dir/.hidden.txt', 'needle\n');
      _write('$dir/.git/config.txt', 'needle\n');
      _write('$dir/visible.txt', 'needle\n');
      expect(
        _hits(
          await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle', glob: '*.txt')),
        ),
        ['$dir/.hidden.txt:1', '$dir/visible.txt:1'],
      );
    });

    test('symbolic links are not followed, unless given explicitly', () async {
      _write('$dir/real/x.txt', 'needle\n');
      Link('$dir/link').createSync('$dir/real');
      Link('$dir/filelink.txt').createSync('$dir/real/x.txt');
      expect(
        _hits(await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle'))),
        ['$dir/real/x.txt:1'],
      );
      expect(
        _hits(await s.grepRaw(ctx, GrepRequest(path: '$dir/link', pattern: 'needle'))),
        ['$dir/link/x.txt:1'],
      );
    });

    test('a walked file is searched up to the 64 KiB fill with its first NUL', () async {
      // A NUL in the first fill: ripgrep searches nothing of the file.
      _writeBytes('$dir/early.dat', [
        ...ascii.encode('needle one\nneedle'),
        0,
        ...ascii.encode('two\nneedle three\n'),
      ]);
      expect(await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle')), isEmpty);

      // 'needle early' ends in the first fill, 'needle late' in the second,
      // which holds the NUL: only the first fill is searched.
      final filler = '${'x' * 99}\n' * 700; // 70000 bytes
      final late = 'needle early\n$filler${'y' * 10}needle late\n';
      _writeBytes('$dir/late.dat', [...ascii.encode(late), 0, ...ascii.encode('needle z\n')]);
      expect(
        await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle')),
        [GrepMatch(path: '$dir/late.dat', line: 1, content: 'needle early')],
      );

      // A NUL after the second fill: both fills are searched.
      File('$dir/late.dat').writeAsBytesSync([
        ...ascii.encode(late),
        ...ascii.encode(filler),
        0,
        ...ascii.encode('needle z\n'),
      ]);
      expect(
        _hits(await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle'))),
        ['$dir/late.dat:1', '$dir/late.dat:702'],
      );
    });

    test('a multiline search skips a walked file with a NUL in its first 64 KiB', () async {
      _writeBytes('$dir/early.dat', [...ascii.encode('needle\n'), 0]);
      _writeBytes('$dir/late.dat', [
        ...ascii.encode('needle\n'),
        ...Uint8List(70000).map((_) => 0x78),
        0,
        ...ascii.encode('\nneedle\n'),
      ]);
      final matches = await s.grepRaw(
        ctx,
        GrepRequest(path: dir, pattern: r'^needle$', enableMultiline: true),
      );
      expect(_hits(matches), ['$dir/late.dat:1', '$dir/late.dat:3']);
    });

    test('a file given explicitly is searched whole', () async {
      final path = '$dir/bin.dat';
      _writeBytes(path, [
        ...ascii.encode('needle one\nneedle'),
        0,
        ...ascii.encode('two\nneedle three\n'),
      ]);
      final matches = await s.grepRaw(ctx, GrepRequest(path: path, pattern: 'needle'));
      if (Platform.isMacOS) {
        // ripgrep reads the file and turns its NUL bytes into line breaks.
        expect(matches, [
          GrepMatch(path: path, line: 1, content: 'needle one'),
          GrepMatch(path: path, line: 2, content: 'needle'),
          GrepMatch(path: path, line: 4, content: 'needle three'),
        ]);
      } else {
        // ripgrep maps the file and keeps its NUL bytes.
        expect(_hits(matches), ['$path:1', '$path:2', '$path:3']);
        expect(matches[1].content, 'needle${String.fromCharCode(0)}two');
      }
    });

    test('context lines come once each, in line order', () async {
      _write('$dir/f.txt', 'l1\nl2\nhit3\nl4\nhit5\nl6\nl7\nl8\n');
      final matches = await s.grepRaw(
        ctx,
        GrepRequest(path: dir, pattern: 'hit', beforeLines: 1, afterLines: 1),
      );
      expect(
        [for (final m in matches) '${m.line}:${m.content}'],
        ['2:l2', '3:hit3', '4:l4', '5:hit5', '6:l6'],
      );
    });

    test('multiline: matches on touching lines are one block', () async {
      _write('$dir/f.txt', 'foo\nfoo\nbar\nfoo\n');
      Future<List<String>> grep(String pattern) async => [
            for (final m in await s.grepRaw(
              ctx,
              GrepRequest(path: dir, pattern: pattern, enableMultiline: true),
            ))
              '${m.line}:${m.content}',
          ];
      // Patterns that can match or look at a line break run over the file.
      for (final pattern in ['fo.', 'fo[^x]', r'fo\W?', r'fo\D', r'o$', r'^foo$']) {
        expect(await grep(pattern), ['1:foo\nfoo', '4:foo'], reason: pattern);
      }
      // The others are searched line by line, as ripgrep does.
      for (final pattern in ['foo', r'\w+o', 'f[a-z]o', r'\bfoo\b', '(?i)FOO', '[fo]+o', 'foo|bar']) {
        expect(
          (await grep(pattern)).where((m) => m.contains('foo')).toList(),
          ['1:foo', '2:foo', '4:foo'],
          reason: pattern,
        );
      }
    });

    test('multiline: an empty match right after a match counts', () async {
      _write('$dir/f.txt', 'foo\nbar\nbaz\n');
      expect(
        await s.grepRaw(
          ctx,
          GrepRequest(path: dir, pattern: r'foo\n|^\s*', enableMultiline: true),
        ),
        [GrepMatch(path: '$dir/f.txt', line: 1, content: 'foo\nbar\nbaz')],
      );
    });

    test('a line break in the pattern needs multiline mode', () async {
      _write('$dir/f.txt', 'a\nb\n');
      final refusal =
          'ripgrep failed with exit code 2: rg: the literal "${String.fromCharCode(0x5C)}n" '
          'is not allowed in a regex\n\nConsider enabling multiline mode with the '
          '--multiline flag (or -U for short).\nWhen multiline mode is enabled, new '
          'line characters can be matched.\n';
      for (final pattern in [r'a\nb', r'\x0A', r'[\n]', 'a\nb', r'\u{a}']) {
        await expectLater(
          s.grepRaw(ctx, GrepRequest(path: dir, pattern: pattern)),
          _throwsMessage(refusal),
          reason: pattern,
        );
      }
      // A class that holds something else drops the line break.
      expect(
        _hits(await s.grepRaw(ctx, GrepRequest(path: dir, pattern: r'a[\nb]'))),
        isEmpty,
      );
      expect(
        await s.grepRaw(
          ctx,
          GrepRequest(path: dir, pattern: r'a\nb', enableMultiline: true),
        ),
        [GrepMatch(path: '$dir/f.txt', line: 1, content: 'a\nb')],
      );
    });

    test('a line that is not UTF-8 has an empty content, as Go reads it', () async {
      _writeBytes('$dir/f.txt', [
        ...ascii.encode('needle '),
        0xFF,
        ...ascii.encode('\nneedle ok\nafter\n'),
      ]);
      expect(
        await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle', afterLines: 1)),
        [
          GrepMatch(path: '$dir/f.txt', line: 1),
          GrepMatch(path: '$dir/f.txt', line: 2, content: 'needle ok'),
          GrepMatch(path: '$dir/f.txt', line: 3, content: 'after'),
        ],
      );
    });

    test(r'multiline: . crosses line breaks, ^ and $ match at them', () async {
      _write('$dir/f.txt', 'start\nmiddle\nend\nother\n');
      expect(
        await s.grepRaw(
          ctx,
          GrepRequest(path: dir, pattern: 'start.*end', enableMultiline: true),
        ),
        [GrepMatch(path: '$dir/f.txt', line: 1, content: 'start\nmiddle\nend')],
      );
      expect(
        await s.grepRaw(
          ctx,
          GrepRequest(path: dir, pattern: r'^middle$', enableMultiline: true),
        ),
        [GrepMatch(path: '$dir/f.txt', line: 2, content: 'middle')],
      );
      expect(
        await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'start.*end')),
        isEmpty,
      );
    });

    test('multiline context surrounds the block', () async {
      _write('$dir/f.txt', 'a\nb\nstart\nx\nend\nc\nd\n');
      final matches = await s.grepRaw(
        ctx,
        GrepRequest(
          path: dir,
          pattern: 'start.*?end',
          enableMultiline: true,
          beforeLines: 1,
          afterLines: 1,
        ),
      );
      expect(
        [for (final m in matches) '${m.line}:${m.content}'],
        ['2:b', '3:start\nx\nend', '6:c'],
      );
    });

    test('a type keeps its files; with a glob too, Go filters the results', () async {
      for (final name in ['main.go', 'util.go', 'sub/main.go', 'readme.md']) {
        _write('$dir/$name', 'package needle\n');
      }
      Future<List<String>> grep({String glob = ''}) async => _hits(
            await s.grepRaw(
              ctx,
              GrepRequest(path: dir, pattern: 'needle', fileType: 'go', glob: glob),
            ),
          );
      expect(await grep(), ['$dir/main.go:1', '$dir/sub/main.go:1', '$dir/util.go:1']);
      // By path or by file name, with eino's glob rules.
      expect(await grep(glob: 'main.go'), ['$dir/main.go:1', '$dir/sub/main.go:1']);
      expect(await grep(glob: '**/sub/*.go'), ['$dir/sub/main.go:1']);
      // A relative glob with a directory never matches the absolute paths
      // ripgrep prints (as in Go), and a bad glob matches nothing.
      expect(await grep(glob: 'sub/*.go'), isEmpty);
      expect(await grep(glob: '['), isEmpty);
    });

    test('a glob follows gitignore rules', () async {
      for (final name in ['a.go', 'sub/b.go', 'sub/deep/c.go', 'x.md']) {
        _write('$dir/$name', 'needle\n');
      }
      Future<List<String>> grep(String glob, {String path = ''}) async => [
            for (final m in await s.grepRaw(
              ctx,
              GrepRequest(path: path.isEmpty ? dir : path, pattern: 'needle', glob: glob),
            ))
              m.path.substring((path.isEmpty ? dir : path).length + 1),
          ];
      // Without a slash: the file name, at any depth.
      expect(await grep('*.go'), ['a.go', 'sub/b.go', 'sub/deep/c.go']);
      expect(await grep('!*.md'), ['a.go', 'sub/b.go', 'sub/deep/c.go']);
      expect(await grep('**/*.go'), ['a.go', 'sub/b.go', 'sub/deep/c.go']);
      // With a slash: the path relative to the working directory, which an
      // absolute path elsewhere never is (as in Go).
      expect(await grep('sub/*.go'), isEmpty);
      expect(await grep('/a.go'), isEmpty);
      await _inDirectory(tmp, () async {
        expect(await grep('sub/*.go', path: '.'), ['sub/b.go']);
        expect(await grep('sub/**', path: '.'), ['sub/b.go', 'sub/deep/c.go']);
        expect(await grep('/a.go', path: '.'), ['a.go']);
        expect(await grep('sub/', path: '.'), isEmpty);
        // An absolute path inside the working directory is made relative.
        final real = tmp.resolveSymbolicLinksSync();
        expect(await grep('sub/*.go', path: real), ['sub/b.go']);
      });
    });

    test('failures are ripgrep’s exit code 2', () async {
      _write('$dir/f.txt', 'x\n');
      await expectLater(
        s.grepRaw(ctx, GrepRequest(path: '$dir/missing', pattern: 'x')),
        _throwsMessage(
          'ripgrep failed with exit code 2: rg: $dir/missing: IO error for '
          'operation on $dir/missing: No such file or directory (os error 2)\n',
        ),
      );
      await expectLater(
        s.grepRaw(ctx, GrepRequest(path: dir, pattern: '(')),
        _throwsMessage(
          startsWith('ripgrep failed with exit code 2: rg: regex parse error:'),
        ),
      );
      await expectLater(
        s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'x', glob: '[')),
        _throwsMessage(
          startsWith("ripgrep failed with exit code 2: rg: error parsing glob '['"),
        ),
      );
      // A bad glob is reported before a bad pattern.
      await expectLater(
        s.grepRaw(ctx, GrepRequest(path: dir, pattern: '(', glob: '[')),
        _throwsMessage(contains('error parsing glob')),
      );
    });

    test('a file that cannot be read fails the search', () async {
      _write('$dir/a.txt', 'needle\n');
      _write('$dir/locked.txt', 'needle\n');
      if (!_lock('$dir/locked.txt')) return; // running as root
      await expectLater(
        s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle')),
        _throwsMessage(
          'ripgrep failed with exit code 2: rg: $dir/locked.txt: Permission '
          'denied (os error 13)\n',
        ),
      );
    });

    test('the end of the last line is not a line', () async {
      _write('$dir/f.txt', 'a\nb\n');
      expect(
        _hits(await s.grepRaw(ctx, GrepRequest(path: dir, pattern: '^'))),
        ['$dir/f.txt:1', '$dir/f.txt:2'],
      );
    });

    test(r'a \r stays part of the line', () async {
      _write('$dir/f.txt', 'foo\r\nbar\r\n');
      expect(
        await s.grepRaw(ctx, GrepRequest(path: dir, pattern: r'foo$')),
        isEmpty,
      );
      expect(
        await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'foo')),
        [GrepMatch(path: '$dir/f.txt', line: 1, content: 'foo\r')],
      );
    });

    test('case insensitive search and a leading flag group', () async {
      _write('$dir/f.txt', 'NEEDLE\n');
      expect(
        await s.grepRaw(
          ctx,
          GrepRequest(path: dir, pattern: 'needle', caseInsensitive: true),
        ),
        hasLength(1),
      );
      expect(
        await s.grepRaw(ctx, GrepRequest(path: dir, pattern: '(?i)needle')),
        hasLength(1),
      );
      expect(
        await s.grepRaw(ctx, GrepRequest(path: dir, pattern: 'needle')),
        isEmpty,
      );
    });

    test('a cancelled context stops the search', () async {
      _write('$dir/f.txt', 'x\n');
      await expectLater(
        s.grepRaw(_cancelled, GrepRequest(path: dir, pattern: 'x')),
        throwsA(isA<CancelledException>()),
      );
    });
  });

  group('GlobInfo (port)', () {
    final s = LocalFilesystemBackend();

    setUp(() {
      _write('$dir/project/src/main.go', '');
      _write('$dir/project/src/utils/helper.go', '');
    });

    test('directories match as well as files', () async {
      final project = '$dir/project';
      expect(
        _paths(await s.globInfo(ctx, GlobInfoRequest(path: project, pattern: 'src/**'))),
        ['src', 'src/main.go', 'src/utils', 'src/utils/helper.go'],
      );
      expect(
        _paths(await s.globInfo(ctx, GlobInfoRequest(path: project, pattern: '*'))),
        ['src'],
      );
    });

    test('an absolute pattern matches nothing', () async {
      expect(
        await s.globInfo(
          ctx,
          GlobInfoRequest(path: '$dir/project', pattern: '$dir/project/**/*.go'),
        ),
        isEmpty,
      );
    });

    test('a pattern that does not compile matches nothing', () async {
      expect(
        await s.globInfo(ctx, GlobInfoRequest(path: dir, pattern: '[')),
        isEmpty,
      );
    });

    test('a missing start directory fails', () async {
      await expectLater(
        s.globInfo(ctx, GlobInfoRequest(path: '$dir/missing', pattern: '*')),
        _throwsMessage(
          'failed to walk directory: lstat $dir/missing: no such file or directory',
        ),
      );
    });

    test('a start path that is a file or a link finds nothing', () async {
      Link('$dir/link').createSync('$dir/project');
      expect(
        await s.globInfo(
          ctx,
          GlobInfoRequest(path: '$dir/project/src/main.go', pattern: '**'),
        ),
        isEmpty,
      );
      expect(
        await s.globInfo(ctx, GlobInfoRequest(path: '$dir/link', pattern: '**')),
        isEmpty,
      );
    });

    test('links inside are matched by name and not followed', () async {
      Link('$dir/project/ln').createSync('$dir/project/src');
      expect(
        _paths(
          await s.globInfo(ctx, GlobInfoRequest(path: '$dir/project', pattern: '**')),
        ),
        ['ln', 'src', 'src/main.go', 'src/utils', 'src/utils/helper.go'],
      );
    });

    test('the result is sorted by code point', () async {
      // Distinct names on a case-insensitive file system too.
      for (final name in ['b', 'Z', 'a', '~']) {
        _write('$dir/sorted/$name', '');
      }
      expect(
        _paths(await s.globInfo(ctx, GlobInfoRequest(path: '$dir/sorted', pattern: '*'))),
        ['Z', 'a', 'b', '~'],
      );
    });

    test('a directory that cannot be read is matched and skipped', () async {
      _write('$dir/locked/x.go', '');
      if (!_lock('$dir/locked')) return; // running as root
      expect(
        _paths(await s.globInfo(ctx, GlobInfoRequest(path: dir, pattern: 'locked/**'))),
        ['locked'],
      );
    });

    test('a cancelled context stops the walk', () async {
      await expectLater(
        s.globInfo(_cancelled, GlobInfoRequest(path: dir, pattern: '**')),
        throwsA(isA<CancelledException>()),
      );
    });
  });

  group('MultiModalRead (port)', () {
    final s = LocalFilesystemBackend();

    test('a whole PDF is one part', () async {
      _writeBytes('$dir/doc.pdf', _minimalValidPdf);
      final resp = await s.multiModalRead(
        ctx,
        MultiModalReadRequest(filePath: '$dir/doc.pdf'),
      );
      expect(resp.fileContent, isNull);
      expect(resp.parts, [
        FileContentPart(
          type: FileContentPartType.pdf,
          mimeType: 'application/pdf',
          data: _minimalValidPdf,
        ),
      ]);
    });

    test('PDF pages are checked before anything is read', () async {
      await expectLater(
        s.multiModalRead(
          ctx,
          MultiModalReadRequest(filePath: '$dir/missing.pdf', pages: '0'),
        ),
        _throwsMessage(
          'invalid pages parameter: "0" (start page must be a positive integer)',
        ),
      );
    });

    test('a PDF that is too large', () async {
      final small = LocalFilesystemBackend(
        multiModalRead: const LocalMultiModalReadConfig(
          maxPdfSizeMB: 1,
          maxPagedPdfSizeMB: 1,
        ),
      );
      final path = '$dir/big.pdf';
      _writeBytes(path, [...ascii.encode('%PDF-'), ...Uint8List(1024 * 1024 - 4)]);
      const tooLarge = 'file exceeds max allowed size';
      await expectLater(
        small.multiModalRead(ctx, MultiModalReadRequest(filePath: path)),
        _throwsMessage(
          '$tooLarge: file $path (1048577 bytes, limit 1MB); PDF full-read size '
          "limit is 1MB, use the 'pages' parameter to read page ranges (limit "
          'raised to 1MB)',
        ),
      );
      await expectLater(
        small.multiModalRead(ctx, MultiModalReadRequest(filePath: path, pages: '1')),
        _throwsMessage(
          '$tooLarge: file $path (1048577 bytes, limit 1MB); paged PDF size '
          'limit is 1MB, the file is too large even for paged reading',
        ),
      );
    });

    test('an image that is too large has Go’s text', () async {
      final small = LocalFilesystemBackend(
        multiModalRead: const LocalMultiModalReadConfig(maxImageSizeMB: 1),
      );
      final path = '$dir/big.png';
      _writeBytes(path, Uint8List(2 * 1024 * 1024));
      await expectLater(
        small.multiModalRead(ctx, MultiModalReadRequest(filePath: path)),
        _throwsMessage(
          'file exceeds max allowed size: file $path (2097152 bytes, limit 1MB); '
          'image size limit is 1MB, please compress or downsample the image '
          'before reading',
        ),
      );
    });

    test('a missing image', () async {
      await expectLater(
        s.multiModalRead(ctx, MultiModalReadRequest(filePath: '$dir/missing.png')),
        _throwsMessage('failed to read file bytes: file not found: $dir/missing.png'),
      );
    });

    test('the extension is compared in lower case, dot files included', () async {
      const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      _writeBytes('$dir/IMG.PNG', png);
      _writeBytes('$dir/.png', png);
      for (final name in ['IMG.PNG', '.png']) {
        final resp = await s.multiModalRead(
          ctx,
          MultiModalReadRequest(filePath: '$dir/$name'),
        );
        expect(resp.parts.single.mimeType, 'image/png', reason: name);
      }
    });

    test('a text file is read with offset and limit', () async {
      _write('$dir/f.md', 'a\nb\nc');
      final resp = await s.multiModalRead(
        ctx,
        MultiModalReadRequest(filePath: '$dir/f.md', offset: 2, limit: 1),
      );
      expect(resp.fileContent, const FileContent('b'));
    });

    test('a file that cannot be read', () async {
      final path = '$dir/locked.png';
      _writeBytes(path, [0xFF, 0xD8, 0xFF]);
      if (!_lock(path)) return; // running as root
      await expectLater(
        s.readAllBytes(ctx, path, 1024),
        _throwsMessage('failed to read file: open $path: permission denied'),
      );
    });

    test('a cancelled context stops the read', () async {
      _writeBytes('$dir/img.png', [0xFF, 0xD8, 0xFF]);
      await expectLater(
        s.multiModalRead(_cancelled, MultiModalReadRequest(filePath: '$dir/img.png')),
        throwsA(isA<CancelledException>()),
      );
    });

    test('the backend keeps its limits resolved', () {
      expect(
        LocalFilesystemBackend(
          multiModalRead: const LocalMultiModalReadConfig(maxPdfSizeMB: 5000),
        ).multiModalReadConfig,
        const LocalMultiModalReadConfig(
          maxImageSizeMB: 10,
          maxPdfSizeMB: 2048,
          maxPagedPdfSizeMB: 100,
          maxPdfPagesPerRequest: 20,
        ),
      );
    });

    test('pages errors have Go’s texts', () {
      void expectInvalid(String pages, String why, [int max = 20]) => expect(
            () => parsePagesParam(pages, max),
            _throwsMessage('invalid pages parameter: $why'),
          );
      expectInvalid('', '"" (empty)');
      expectInvalid('1-2-3', '"1-2-3" (only a single range is supported, e.g. "1-5")');
      expectInvalid('1-', '"1-" (open-ended range is not supported, end page is required)');
      expectInvalid('a-b', '"a-b" (start page must be a positive integer)');
      expectInvalid('1-x', '"1-x" (end page must be a positive integer)');
      expectInvalid('5-2', '"5-2" (end page 2 < start page 5)');
      expectInvalid('1-30', '"1-30" (range spans 30 pages, exceeds limit 20)');
      expectInvalid('0x10', '"0x10" (start page must be a positive integer)');
      expectInvalid('1\t-', r'"1\t-" (open-ended range is not supported, end page is required)');
      expect(parsePagesParam('+3', 20), (3, 3));
      // Go's TrimSpace keeps U+FEFF (Dart's trim drops it) and %q escapes
      // characters that are not printable.
      final bom = String.fromCharCode(0xFEFF);
      final nbsp = String.fromCharCode(0xA0);
      final backslash = String.fromCharCode(0x5C);
      expectInvalid('${bom}3', '"${backslash}ufeff3" (start page must be a positive integer)');
      expect(parsePagesParam('${nbsp}3$nbsp', 20), (3, 3));
    });
  });
}
