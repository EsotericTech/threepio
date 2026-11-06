// Port of eino-ext components/model/agenticopenai/file_id_test.go (the
// Responses parts: TestInputFileID, TestToolResultFileID,
// TestInputFileIDPrecedence). The request items are JSON maps here, so the
// checks run on their jsonEncode text, as Go's do on json.Marshal.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_convertor.dart';

void _assertFileIdJson(Object? value) {
  final data = jsonEncode(value);
  expect(data, contains('"file_id":"file-123"'));
  for (final field in [
    'image_url',
    'file_url',
    'video_url',
    'audio_url',
    'file_data',
  ]) {
    expect(data, isNot(contains('"$field"')),
        reason: 'unexpected $field alongside FileID in $data');
  }
}

void _checkFileIdPrecedence(
  Object? Function(String url, String base64Data, String mimeType, String fileId)
      convert,
) {
  final cases = [
    (name: 'URL', url: 'https://example.com/media', b64: '', mime: ''),
    (name: 'Base64Data', url: '', b64: 'YWJj', mime: 'image/png'),
    (
      name: 'URL_and_Base64Data',
      url: 'https://example.com/media',
      b64: 'YWJj',
      mime: 'image/png'
    ),
    (
      name: 'invalid_Base64Data',
      url: '',
      b64: 'data:image/png;base64,YWJj',
      mime: 'image/png'
    ),
    (name: 'missing_MIMEType', url: '', b64: 'YWJj', mime: ''),
  ];
  for (final c in cases) {
    test(c.name, () {
      Object? want;
      Object? wantError;
      try {
        want = convert(c.url, c.b64, c.mime, '');
      } catch (error) {
        wantError = error;
      }
      if (wantError != null) {
        expect(
          () => convert(c.url, c.b64, c.mime, 'file-123'),
          throwsA(
            predicate((Object e) => e.toString() == wantError.toString()),
          ),
          reason: 'FileID changed the selected source error',
        );
        return;
      }
      final got = convert(c.url, c.b64, c.mime, 'file-123');
      expect(jsonEncode(got), jsonEncode(want),
          reason: 'FileID changed the selected source');
    });
  }
}

void main() {
  group('TestInputFileID', () {
    test('image', () {
      _assertFileIdJson(
        userInputImageToInputItem('user', const UserInputImage(fileId: 'file-123')),
      );
    });
    test('file', () {
      _assertFileIdJson(
        userInputFileToInputItem('user', const UserInputFile(fileId: 'file-123')),
      );
    });
  });

  test('TestToolResultFileID', () {
    final value = functionToolResultContentToOutput([
      FunctionToolResultContentBlock(const UserInputImage(fileId: 'file-123')),
      FunctionToolResultContentBlock(const UserInputFile(fileId: 'file-123')),
    ]);
    _assertFileIdJson(value);
    expect(
      '"file_id":"file-123"'.allMatches(jsonEncode(value)).length,
      2,
      reason: 'both tool media references must survive',
    );
  });

  group('TestInputFileIDPrecedence', () {
    group('image', () {
      _checkFileIdPrecedence(
        (url, b64, mime, fileId) => userInputImageToInputItem(
          'user',
          UserInputImage(
            url: url,
            base64Data: b64,
            mimeType: mime,
            fileId: fileId,
          ),
        ),
      );
    });
    group('tool_image', () {
      _checkFileIdPrecedence(
        (url, b64, mime, fileId) => functionToolResultContentToOutput([
          FunctionToolResultContentBlock(
            UserInputImage(
              url: url,
              base64Data: b64,
              mimeType: mime,
              fileId: fileId,
            ),
          ),
        ]),
      );
    });
    group('file', () {
      _checkFileIdPrecedence(
        (url, b64, mime, fileId) => userInputFileToInputItem(
          'user',
          UserInputFile(
            url: url,
            base64Data: b64,
            mimeType: mime,
            fileId: fileId,
          ),
        ),
      );
    });
    group('tool_file', () {
      _checkFileIdPrecedence(
        (url, b64, mime, fileId) => functionToolResultContentToOutput([
          FunctionToolResultContentBlock(
            UserInputFile(
              url: url,
              base64Data: b64,
              mimeType: mime,
              fileId: fileId,
            ),
          ),
        ]),
      );
    });
  });
}
