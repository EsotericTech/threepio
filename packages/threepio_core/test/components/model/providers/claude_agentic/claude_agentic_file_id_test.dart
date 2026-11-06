// Port of eino-ext components/model/agenticclaude/file_id_test.go (both
// tests: TestInputFileID, TestInputFileIDPrecedence): a Files API id is
// sent as a `file` source, and only when there is neither a URL nor base64
// data, whose results (and errors) it never changes.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/claude_agentic/claude_agentic_convertor.dart';
import 'package:threepio_core/threepio_core.dart';

typedef _Convert =
    Map<String, Object?> Function(
      String url,
      String base64Data,
      String mimeType,
      String fileId,
    );

void main() {
  group('TestInputFileID', () {
    for (final media in ['image', 'file']) {
      test(media, () {
        final block = media == 'image'
            ? claudeAgenticImageBlock(const UserInputImage(fileId: 'file-123'))
            : claudeAgenticDocumentBlock(
                const UserInputFile(fileId: 'file-123'),
              );
        final decoded = jsonDecode(jsonEncode(block)) as Map<String, Object?>;
        expect(decoded['source'], {'type': 'file', 'file_id': 'file-123'});
        expect(decoded['type'], media == 'image' ? 'image' : 'document');
      });
    }
  });

  group('TestInputFileIDPrecedence', () {
    final medias = <String, _Convert>{
      'image': (url, base64Data, mimeType, fileId) => claudeAgenticImageBlock(
        UserInputImage(
          url: url,
          base64Data: base64Data,
          mimeType: mimeType,
          fileId: fileId,
        ),
      ),
      'file': (url, base64Data, mimeType, fileId) => claudeAgenticDocumentBlock(
        UserInputFile(
          url: url,
          base64Data: base64Data,
          mimeType: mimeType,
          fileId: fileId,
        ),
      ),
    };
    final cases =
        <({String name, String url, String base64Data, String mimeType})>[
          (
            name: 'URL',
            url: 'https://example.com/media',
            base64Data: '',
            mimeType: '',
          ),
          (
            name: 'Base64Data',
            url: '',
            base64Data: 'YWJj',
            mimeType: 'image/png',
          ),
          (
            name: 'URL_and_Base64Data',
            url: 'https://example.com/media',
            base64Data: 'YWJj',
            mimeType: 'image/png',
          ),
          (
            name: 'invalid_Base64Data',
            url: '',
            base64Data: 'data:image/png;base64,YWJj',
            mimeType: 'image/png',
          ),
          (name: 'missing_MIMEType', url: '', base64Data: 'YWJj', mimeType: ''),
        ];
    for (final MapEntry(key: media, value: convert) in medias.entries) {
      group(media, () {
        for (final c in cases) {
          test(c.name, () {
            Object? want;
            Object? wantError;
            try {
              want = convert(c.url, c.base64Data, c.mimeType, '');
            } on ThreepioFormatException catch (error) {
              wantError = error.message;
            }
            Object? got;
            Object? gotError;
            try {
              got = convert(c.url, c.base64Data, c.mimeType, 'file-123');
            } on ThreepioFormatException catch (error) {
              gotError = error.message;
            }
            expect(gotError, wantError);
            expect(jsonEncode(got), jsonEncode(want));
          });
        }
      });
    }

    test('a missing image MIME type is an error, as in Go', () {
      expect(
        () => claudeAgenticImageBlock(
          const UserInputImage(base64Data: 'YWJj', fileId: 'file-123'),
        ),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'invalid image mime type ""',
          ),
        ),
      );
    });
  });
}
