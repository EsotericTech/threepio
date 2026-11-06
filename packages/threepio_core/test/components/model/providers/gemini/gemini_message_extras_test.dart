// Ports of eino-ext components/model/gemini/message_extra_test.go and
// file_id_test.go, plus tests of the rest of gemini_message_extras.dart.
//
// Ported: TestVideoMetaDataFunctions, TestMessageThoughtSignatureFunctions,
// TestToolCallThoughtSignatureFunctions (the JSON round trips through
// `Message.toJson` / `ToolCall.toJson`), TestInputFileID,
// TestInputFileIDPrecedence (user and tool media, seven sources each).
//
// Not ported: the nil-receiver boundary cases (`SetInputVideoMetaData(nil)`,
// `setMessageThoughtSignature(nil, …)`): the extension members cannot be
// called on null. TestCustomConcat: Go registers concat functions for the
// genai values it keeps in `Extra`; here those values are JSON maps that
// `concatMessages` merges by itself, and streamed code execution parts are
// kept apart by their streaming index (tested in gemini_port_test.dart).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_converters.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_message_extras.dart';
import 'package:threepio_core/src/errors.dart';
import 'package:threepio_core/src/schema/message.dart';

MessagePartCommon _common({
  String? url,
  String? base64Data,
  String? fileId,
  String? mimeType,
}) =>
    MessagePartCommon(
      url: url,
      base64Data: base64Data,
      fileId: fileId,
      mimeType: mimeType,
    );

MessageInputPart _media(ChatMessagePartType type, MessagePartCommon common) =>
    switch (type) {
      ChatMessagePartType.imageUrl =>
        MessageInputPart(type: type, image: MessageInputImage(common: common)),
      ChatMessagePartType.audioUrl =>
        MessageInputPart(type: type, audio: MessageInputAudio(common: common)),
      ChatMessagePartType.videoUrl =>
        MessageInputPart(type: type, video: MessageInputVideo(common: common)),
      _ => MessageInputPart(type: type, file: MessageInputFile(common: common)),
    };

List<Map<String, dynamic>> _userParts(List<MessageInputPart> inputs) =>
    (GeminiConverters.messageToGemini(
      Message(role: RoleType.user, userInputMultiContent: inputs),
    )['parts'] as List)
        .cast<Map<String, dynamic>>();

Map<String, dynamic> _toolResponse(List<MessageInputPart> inputs) =>
    ((GeminiConverters.messageToGemini(
      Message(role: RoleType.tool, toolName: 'tool', userInputMultiContent: inputs),
    )['parts'] as List)
            .single as Map<String, dynamic>)['functionResponse']
        as Map<String, dynamic>;

const _mediaTypes = [
  ChatMessagePartType.imageUrl,
  ChatMessagePartType.audioUrl,
  ChatMessagePartType.videoUrl,
  ChatMessagePartType.fileUrl,
];

void main() {
  group('TestVideoMetaDataFunctions', () {
    test('TestSetInputVideoMetaData', () {
      final input = _media(ChatMessagePartType.videoUrl, _common(url: 'u'));
      const metadata = GeminiVideoMetadata(fps: 10);

      final withMetadata = input.withGeminiInputVideoMetadata(metadata);

      expect(withMetadata.geminiInputVideoMetadata, metadata);
      expect(input.geminiInputVideoMetadata, isNull, reason: 'a copy');
      expect(withMetadata.extra!['gemini_video_meta_data'], {'fps': 10.0});
    });

    test('survives a JSON round trip', () {
      final input = _media(ChatMessagePartType.videoUrl, _common(url: 'u'))
          .withGeminiInputVideoMetadata(
        const GeminiVideoMetadata(
          startOffset: Duration(seconds: 2),
          endOffset: Duration(seconds: 9),
          fps: 2,
        ),
      );
      final restored = MessageInputPart.fromJson(
        jsonDecode(jsonEncode(input.toJson())) as Map<String, dynamic>,
      );
      expect(
        restored.geminiInputVideoMetadata,
        const GeminiVideoMetadata(
          startOffset: Duration(seconds: 2),
          endOffset: Duration(seconds: 9),
          fps: 2,
        ),
      );
    });

    test('offsets are whole seconds, and an end alone starts at 0s', () {
      expect(
        const GeminiVideoMetadata(endOffset: Duration(milliseconds: 4600)).toJson(),
        {'startOffset': '0s', 'endOffset': '5s'},
      );
      expect(const GeminiVideoMetadata().toJson(), isEmpty);
      expect(
        GeminiVideoMetadata.fromJson(const {'startOffset': '1.5s'}).startOffset,
        const Duration(milliseconds: 1500),
      );
    });
  });

  group('TestMessageThoughtSignatureFunctions', () {
    test('TestSetMessageThoughtSignature', () {
      const message = Message(
        role: RoleType.assistant,
        reasoningContent: 'thinking process',
      );
      final signature = utf8.encode('message_thought_signature_data');

      final signed = message.withGeminiThoughtSignature(signature);

      final retrieved = geminiThoughtSignatureFromExtra(signed.extra);
      expect(retrieved.present, isTrue);
      expect(retrieved.signature, signature);
      expect(signed.geminiThoughtSignature, signature);
      // Stored under Go's key, as the base64 text a JSON round trip of Go's
      // []byte leaves.
      expect(signed.extra!['gemini_thought_signature'], base64Encode(signature));
    });

    test('TestSetMessageThoughtSignature_EmptySignature', () {
      const message = Message(role: RoleType.assistant);
      final signed = message.withGeminiThoughtSignature(const []);
      final retrieved = geminiThoughtSignatureFromExtra(signed.extra);
      expect(retrieved.present, isFalse);
      expect(retrieved.signature, isNull);
    });

    test('TestGetMessageThoughtSignature_NilExtra', () {
      const message = Message(role: RoleType.assistant);
      final retrieved = geminiThoughtSignatureFromExtra(message.extra);
      expect(retrieved.present, isFalse);
      expect(retrieved.signature, isNull);
      expect(geminiThoughtSignatureFromExtra(null).present, isFalse);
    });

    test('MessageThoughtSignatureCanRoundTripJSON', () {
      final signature = utf8.encode('msg_sig_json');
      final message = const Message(
        role: RoleType.assistant,
        reasoningContent: 'thinking',
      ).withGeminiThoughtSignature(signature);

      final restored = Message.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );

      final retrieved = geminiThoughtSignatureFromExtra(restored.extra);
      expect(retrieved.present, isTrue);
      expect(retrieved.signature, signature);
    });

    test('reads a list of bytes, and reports undecodable values as present',
        () {
      expect(
        geminiThoughtSignatureFromExtra(const {
          'gemini_thought_signature': [1, 2, 3],
        }).signature,
        [1, 2, 3],
      );
      for (final value in <Object?>['', '!!not base64!!', 42, <int>[]]) {
        final read =
            geminiThoughtSignatureFromExtra({'gemini_thought_signature': value});
        expect(read.present, isTrue, reason: '$value');
        expect(read.signature, isNull, reason: '$value');
      }
    });
  });

  group('TestToolCallThoughtSignatureFunctions', () {
    const toolCall = ToolCall(
      id: 'test_call',
      function: FunctionCall(name: 'test_function', arguments: '{"param":"value"}'),
    );

    test('TestSetToolCallThoughtSignature', () {
      final signature = utf8.encode('toolcall_thought_signature_data');
      final signed = toolCall.withGeminiThoughtSignature(signature);
      final retrieved = geminiThoughtSignatureFromExtra(signed.extra);
      expect(retrieved.present, isTrue);
      expect(retrieved.signature, signature);
      expect(signed.geminiThoughtSignature, signature);
      expect(signed.extra!['gemini_thought_signature'], base64Encode(signature));
    });

    test('TestSetToolCallThoughtSignature_EmptySignature', () {
      final signed = toolCall.withGeminiThoughtSignature(const []);
      expect(geminiThoughtSignatureFromExtra(signed.extra).present, isFalse);
    });

    test('TestGetToolCallThoughtSignature_NilExtra', () {
      final retrieved = geminiThoughtSignatureFromExtra(toolCall.extra);
      expect(retrieved.present, isFalse);
      expect(retrieved.signature, isNull);
    });

    test('ToolCallThoughtSignatureCanRoundTripJSON', () {
      final signature = utf8.encode('tc_sig_json');
      final signed = const ToolCall(
        id: 'test_call',
        function: FunctionCall(name: 'check_flight', arguments: '{"flight":"AA100"}'),
      ).withGeminiThoughtSignature(signature);

      final restored = ToolCall.fromJson(
        jsonDecode(jsonEncode(signed.toJson())) as Map<String, dynamic>,
      );

      expect(geminiThoughtSignatureFromExtra(restored.extra).signature, signature);
    });
  });

  group('output part extras', () {
    test('thought signature', () {
      final signature = utf8.encode('part_sig');
      const part = MessageOutputPart(type: ChatMessagePartType.text, text: 'x');
      expect(part.geminiThoughtSignature, isNull);
      expect(part.withGeminiThoughtSignature(signature).geminiThoughtSignature,
          signature);
      expect(part.withGeminiThoughtSignature(const []), part);
    });

    test('code execution parts', () {
      final message = GeminiConverters.geminiToMessage({
        'content': {
          'role': 'model',
          'parts': [
            {
              'executableCode': {'language': 'PYTHON', 'code': 'print(1)'},
            },
            {
              'codeExecutionResult': {'outcome': 'OUTCOME_OK', 'output': '1\n'},
            },
          ],
        },
      });
      final [code, result] = message.assistantGenMultiContent!;
      expect(code.text, 'print(1)');
      expect(code.geminiExecutableCode!.code, 'print(1)');
      expect(code.geminiExecutableCode!.language, 'PYTHON');
      expect(code.geminiCodeExecutionResult, isNull);
      expect(result.text, '1\n');
      expect(result.geminiCodeExecutionResult!.outcome, 'OUTCOME_OK');
      expect(result.geminiCodeExecutionResult!.output, '1\n');
      expect(result.geminiExecutableCode, isNull);
      expect(
        const GeminiExecutableCode(code: 'c', language: 'PYTHON').toJson(),
        {'language': 'PYTHON', 'code': 'c'},
      );
      expect(
        const GeminiCodeExecutionResult(output: 'o', outcome: 'OUTCOME_OK').toJson(),
        {'outcome': 'OUTCOME_OK', 'output': 'o'},
      );
    });
  });

  group('message extras', () {
    test('grounding metadata', () {
      const message = Message(role: RoleType.assistant, content: 'a');
      expect(message.geminiGroundingMetadata, isNull);
      final grounded = message.withGeminiGroundingMetadata({
        'webSearchQueries': ['q'],
      });
      expect(grounded.geminiGroundingMetadata, {
        'webSearchQueries': ['q'],
      });
      expect(grounded.extra!.keys, ['gemini_ground_metadata']);
    });

    test('tool result display name', () {
      final part = _media(ChatMessagePartType.imageUrl, _common(url: 'u'));
      expect(part.geminiToolResultDisplayName, isNull);
      final named = part.withGeminiToolResultDisplayName('chart.png');
      expect(named.geminiToolResultDisplayName, 'chart.png');
      expect(named.extra!['gemini_display_name'], 'chart.png');
    });

    test('a display name reaches the function response part', () {
      final response = _toolResponse([
        MessageInputPart.text('{"rows": 3}'),
        _media(
          ChatMessagePartType.imageUrl,
          _common(base64Data: 'YWJj', mimeType: 'image/png'),
        ).withGeminiToolResultDisplayName('chart.png'),
        _media(
          ChatMessagePartType.fileUrl,
          _common(url: 'https://example.com/a.pdf', mimeType: 'application/pdf'),
        ),
      ]);
      expect(response['name'], 'tool');
      expect(response['response'], {'rows': 3});
      expect(response['parts'], [
        {
          'inlineData': {
            'mimeType': 'image/png',
            'data': 'YWJj',
            'displayName': 'chart.png',
          },
        },
        {
          'fileData': {
            'mimeType': 'application/pdf',
            'fileUri': 'https://example.com/a.pdf',
          },
        },
      ]);
    });

    test('the text of a multimodal tool result that is not a JSON object', () {
      final response = _toolResponse([
        MessageInputPart.text('plain'),
        MessageInputPart.text(' text'),
        _media(ChatMessagePartType.imageUrl, _common(url: 'https://x/y.png')),
      ]);
      expect(response['response'], {'output': 'plain text'});
    });
  });

  test('TestInputFileID', () {
    const uri = 'https://generativelanguage.googleapis.com/v1beta/files/example';
    final common = _common(fileId: uri, mimeType: 'application/octet-stream');
    final inputs = [for (final type in _mediaTypes) _media(type, common)];

    final parts = _userParts(inputs);
    expect(parts, hasLength(4));
    for (final part in parts) {
      expect(part['file_data'], {
        'mime_type': 'application/octet-stream',
        'file_uri': uri,
      });
      expect(part.containsKey('inline_data'), isFalse);
    }

    final toolParts = (_toolResponse(inputs)['parts'] as List).cast<Map>();
    expect(toolParts, hasLength(4));
    for (final part in toolParts) {
      expect(part['fileData']['fileUri'], uri);
      expect(part.containsKey('inlineData'), isFalse);
    }

    // Without a MIME type no wildcard type is made up for a file id.
    expect(
      _userParts([
        _media(ChatMessagePartType.fileUrl, _common(fileId: 'files/abc')),
        _media(ChatMessagePartType.imageUrl, _common(fileId: 'files/x.png')),
      ]),
      [
        {
          'file_data': {'file_uri': 'files/abc'},
        },
        {
          'file_data': {'mime_type': 'image/png', 'file_uri': 'files/x.png'},
        },
      ],
    );

    expect(
      () => _userParts([_media(ChatMessagePartType.imageUrl, _common(fileId: ''))]),
      throwsA(
        isA<ThreepioFormatException>()
            .having((e) => e.message, 'message', 'FileID must not be empty'),
      ),
    );
  });

  group('TestInputFileIDPrecedence', () {
    const id = 'file-123';
    const url = 'https://example.com/media';
    const base64Data = 'YWJj';
    const dataUrlAsBase64 = 'data:image/png;base64,YWJj';
    final sources = <String, MessagePartCommon>{
      'URL': _common(url: url),
      'Base64Data': _common(base64Data: base64Data, mimeType: 'image/png'),
      'URL_and_Base64Data':
          _common(url: url, base64Data: base64Data, mimeType: 'image/png'),
      'invalid_Base64Data':
          _common(base64Data: dataUrlAsBase64, mimeType: 'image/png'),
      'missing_MIMEType': _common(base64Data: base64Data),
      'empty_URL': _common(url: ''),
      'empty_Base64Data': _common(base64Data: '', mimeType: 'image/png'),
    };

    Object convert(
      String target,
      ChatMessagePartType type,
      MessagePartCommon common,
    ) {
      try {
        final part = _media(type, common);
        return jsonEncode(
          target == 'user' ? _userParts([part]) : _toolResponse([part]),
        );
      } on ThreepioFormatException catch (error) {
        return error;
      }
    }

    for (final target in ['user', 'tool']) {
      for (final type in _mediaTypes) {
        group('${target}_${type.name}', () {
          for (final MapEntry(key: name, value: common) in sources.entries) {
            test(name, () {
              final want = convert(target, type, common);
              final got = convert(target, type, common.copyWith(fileId: id));
              if (want is ThreepioFormatException) {
                expect(got, isA<ThreepioFormatException>());
                expect((got as ThreepioFormatException).message, want.message,
                    reason: 'FileID changed the selected source error');
              } else {
                expect(got, want, reason: 'FileID changed the selected source');
              }
            });
          }
        });
      }
    }
  });
}
