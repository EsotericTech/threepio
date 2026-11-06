// Ports of eino-ext components/model/gemini/gemini_test.go.
//
// The Go tests mock the genai SDK (mockey on `Models.GenerateContent`,
// `GenerateContentStream`, `Caches.Create`) or call the package's internal
// converters. Here the model runs against a fake HTTP client that answers
// with recorded-shape Gemini REST JSON, and the converters are tested through
// `GeminiConverters`, whose REST JSON is what the SDK would send.
//
// Ported: TestGemini (common, stream, structure, function, media — media with
// `userInputMultiContent`, the replacement of the deprecated `MultiContent`),
// TestWithTools, Test_toMultiOutPart, TestChatModel_convMedia (convInputMedia,
// convOutputMedia), TestThoughtSignatureRoundTrip, TestCreatePrefixCache,
// TestSpecialPart, TestPopulateToolChoice, TestUniqueToolCallIDs,
// TestConvSchemaMessageToolCallOrder, TestConvLogprobs,
// TestLogprobsOptionsOverride, TestWithLabels (Gemini API cases),
// TestConvCandidateLogprobs.
//
// Ported with the deviations of this port, each named in the test:
// * a text tool result is sent as `{"result": content}` (the existing
//   threepio wire format, pinned by gemini_converters_test.dart) instead of
//   Go's parsed JSON object / `{"output": content}`;
// * the text of a response stays in `Message.content` and its thought
//   signature on the message; Go also mirrors text parts into
//   `AssistantGenMultiContent` with per-part signatures;
// * inline output data of a non-image, non-audio, non-video MIME type is
//   dropped instead of failing the response (`Test_toMultiOutPart`
//   "unsupported type").
//
// Not ported: TestPanicErr (Go's recover wrapper of the stream goroutine has
// no Dart counterpart), the `convMedia` cases of TestChatModel_convMedia
// (deprecated `MultiContent`), the "empty tool choice" case of
// TestPopulateToolChoice (`ToolChoice` is an enum, an unknown value cannot be
// built), and the "labels applied on vertex backend" case of TestWithLabels
// (this model talks to the Gemini API only).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/chat_model_options.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_chat_model.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_config.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_converters.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_message_extras.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_options.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_response_parser.dart';
import 'package:threepio_core/src/errors.dart';
import 'package:threepio_core/src/schema/message.dart';
import 'package:threepio_core/src/schema/tool_info.dart';

const _config = GeminiConfig(apiKey: 'test-key', defaultModel: 'test-model');

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// A REST `GenerateContentResponse` with one candidate.
Map<String, Object?> _response(
  List<Map<String, Object?>> parts, {
  String? finishReason,
  Map<String, Object?>? usage,
}) =>
    {
      'candidates': [
        {
          'content': {'role': 'model', 'parts': parts},
          if (finishReason != null) 'finishReason': finishReason,
        },
      ],
      if (usage != null) 'usageMetadata': usage,
    };

/// A model whose requests are recorded and answered by [respond].
({GeminiChatModel model, List<http.Request> requests}) _model(
  Map<String, Object?> Function(http.Request request) respond, {
  GeminiConfig config = _config,
}) {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    return http.Response(
      jsonEncode(respond(request)),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  return (
    model: GeminiChatModel(config: config, httpClient: client),
    requests: requests,
  );
}

Map<String, dynamic> _body(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

String _b64(String text) => base64Encode(utf8.encode(text));

List<Map<String, dynamic>> _parts(Map<String, dynamic> content) =>
    (content['parts'] as List).cast<Map<String, dynamic>>();

ToolCall _call(String id, String name, String arguments) => ToolCall(
      id: id,
      function: FunctionCall(name: name, arguments: arguments),
    );

const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  group('TestGemini', () {
    test('common', () async {
      final fake = _model(
        (_) => _response(
          [
            {'text': 'Hello, how can I help you?'},
          ],
          usage: {
            'totalTokenCount': 100,
            'thoughtsTokenCount': 50,
            'candidatesTokenCount': 50,
          },
        ),
      );

      final resp = await fake.model.generate([Message.user('Hi')]);

      expect(resp.content, 'Hello, how can I help you?');
      expect(resp.role, RoleType.assistant);
      expect(resp.responseMeta!.usage!.totalTokens, 100);
      expect(resp.responseMeta!.usage!.completionTokens, 100);
      expect(
        resp.responseMeta!.usage!.completionTokenDetails!.reasoningTokens,
        50,
      );
    });

    test('stream', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = MockClient.streaming((request, bodyStream) async {
        bodies.add(jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>);
        final chunks = ['Hello,', ' how can I ', 'help you?'];
        return http.StreamedResponse(
          Stream.fromIterable([
            for (final chunk in chunks)
              utf8.encode(
                'data: ${jsonEncode(_response([
                      {'text': chunk},
                    ]))}\n\n',
              ),
          ]),
          200,
        );
      });
      final model = GeminiChatModel(config: _config, httpClient: client);

      final reader = await model.stream(
        [Message.user('Hi')],
        options: GeminiRequestOptions(
          topK: 0,
          responseJsonSchema: const {
            'type': 'string',
            'enum': ['1', '2'],
          },
        ).toOptions(),
      );
      final content = (await reader.collectAll()).map((m) => m.content).join();
      await reader.close();

      expect(content, 'Hello, how can I help you?');
      final generationConfig = bodies.single['generationConfig'] as Map;
      expect(generationConfig['topK'], 0);
      expect(generationConfig['responseMimeType'], 'application/json');
      expect(generationConfig['responseJsonSchema'], {
        'type': 'string',
        'enum': ['1', '2'],
      });
    });

    test('structure', () async {
      const responseSchema = {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'age': {'type': 'integer'},
        },
      };
      final fake = _model(
        (_) => _response([
          {'text': '{"name":"John","age":25}'},
        ]),
        config: _config.copyWith(responseJsonSchema: responseSchema),
      );

      final resp = await fake.model.generate([Message.user('Get user info')]);

      expect(resp.content, '{"name":"John","age":25}');
      final generationConfig = _body(fake.requests.single)['generationConfig'];
      expect(generationConfig['responseJsonSchema'], responseSchema);
      expect(generationConfig['responseMimeType'], 'application/json');
    });

    test('function', () async {
      final fake = _model(
        (_) => _response([
          {
            'functionCall': {
              'name': 'get_weather',
              'args': {'city': 'Beijing'},
            },
          },
        ]),
      );
      final model = fake.model.withTools([
        ToolInfo.simple(
          name: 'get_weather',
          description: 'Get weather information',
          properties: {'city': JSONSchemaProperty.string()},
        ),
      ]);

      final resp =
          await model.generate([Message.user("What's the weather in Beijing?")]);

      expect(resp.toolCalls, hasLength(1));
      expect(resp.toolCalls![0].function.name, 'get_weather');
      final args =
          jsonDecode(resp.toolCalls![0].function.arguments) as Map<String, dynamic>;
      expect(args['city'], 'Beijing');
    });

    test('media', () async {
      final fake = _model(
        (_) => _response([
          {'text': 'I see a beautiful sunset image'},
        ]),
      );

      final resp = await fake.model.generate([
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart.text("What's in this image?"),
            const MessageInputPart(
              type: ChatMessagePartType.imageUrl,
              image: MessageInputImage(
                common: MessagePartCommon(
                  url: 'https://example.com/sunset.jpg',
                  mimeType: 'image/jpeg',
                ),
              ),
            ),
          ],
        ),
      ]);

      expect(resp.content, 'I see a beautiful sunset image');
      final parts = _parts(
        (_body(fake.requests.single)['contents'] as List).single
            as Map<String, dynamic>,
      );
      expect(parts[1]['file_data'], {
        'mime_type': 'image/jpeg',
        'file_uri': 'https://example.com/sunset.jpg',
      });
    });
  });

  test('TestWithTools', () {
    final cm = GeminiChatModel(config: _config);
    final ncm = cm.withTools([
      const ToolInfo(function: FunctionInfo(name: 'test tool name')),
    ]) as GeminiChatModel;
    expect(ncm.config.defaultModel, 'test-model');
    expect(ncm.tools![0].name, 'test tool name');
    expect(cm.tools, isNull);
  });

  group('Test_toMultiOutPart', () {
    Message convert(Map<String, Object?> part) =>
        GeminiConverters.geminiToMessage({
          'content': {
            'role': 'model',
            'parts': [part],
          },
        });

    test('nil inline data', () {
      final message = convert({
        'inlineData': {'mimeType': 'image/png'},
      });
      expect(message.assistantGenMultiContent, isNull);
    });

    test('image part', () {
      final encoded = _b64('fake-image-data');
      final message = convert({
        'inlineData': {'mimeType': 'image/png', 'data': encoded},
      });
      final part = message.assistantGenMultiContent!.single;
      expect(part.type, ChatMessagePartType.imageUrl);
      expect(part.image!.mimeType, 'image/png');
      expect(part.image!.url, 'data:image/png;base64,$encoded');
    });

    test('unsupported type is dropped (deviation: Go fails the response)', () {
      final message = convert({
        'inlineData': {
          'mimeType': 'application/pdf',
          'data': _b64('fake-pdf-data'),
        },
      });
      expect(message.assistantGenMultiContent, isNull);
    });
  });

  group('TestChatModel_convMedia', () {
    final decoded = base64Encode(base64Decode(_pngBase64));

    group('convInputMedia', () {
      MessageInputPart media(ChatMessagePartType type, String mimeType,
          {String data = _pngBase64}) {
        final common = MessagePartCommon(base64Data: data, mimeType: mimeType);
        return switch (type) {
          ChatMessagePartType.imageUrl => MessageInputPart(
              type: type,
              image: MessageInputImage(common: common),
            ),
          ChatMessagePartType.audioUrl => MessageInputPart(
              type: type,
              audio: MessageInputAudio(common: common),
            ),
          ChatMessagePartType.videoUrl => MessageInputPart(
              type: type,
              video: MessageInputVideo(common: common),
            ),
          _ => MessageInputPart(
              type: type,
              file: MessageInputFile(common: common),
            ),
        };
      }

      List<Map<String, dynamic>> convert(List<MessageInputPart> parts) =>
          _parts(
            GeminiConverters.messageToGemini(
              Message(role: RoleType.user, userInputMultiContent: parts),
            ),
          );

      test('success', () {
        final parts = convert([
          MessageInputPart.text('hello'),
          media(ChatMessagePartType.imageUrl, 'image/png'),
          media(ChatMessagePartType.audioUrl, 'audio/mp3'),
          media(ChatMessagePartType.videoUrl, 'video/mp4'),
          media(ChatMessagePartType.fileUrl, 'application/pdf'),
        ]);
        expect(parts, hasLength(5));
        expect(parts[0]['text'], 'hello');
        expect(parts[1]['inline_data']['mime_type'], 'image/png');
        expect(parts[2]['inline_data']['mime_type'], 'audio/mp3');
        expect(parts[3]['inline_data']['mime_type'], 'video/mp4');
        expect(parts[4]['inline_data']['mime_type'], 'application/pdf');
        expect(parts[1]['inline_data']['data'], decoded);
      });

      test('with video metadata', () {
        final video = media(ChatMessagePartType.videoUrl, 'video/mp4')
            .withGeminiInputVideoMetadata(
          const GeminiVideoMetadata(
            startOffset: Duration(seconds: 1),
            endOffset: Duration(seconds: 5),
          ),
        );
        final parts = convert([video]);
        expect(parts, hasLength(1));
        expect(parts[0]['videoMetadata'], {
          'startOffset': '1s',
          'endOffset': '5s',
        });
        expect(parts[0]['inline_data'], isNotNull);
      });

      group('error cases', () {
        const invalid = 'invalid-base64';
        final cases = <String, MessageInputPart>{
          'Image with invalid base64':
              media(ChatMessagePartType.imageUrl, 'image/png', data: invalid),
          'Audio with invalid base64':
              media(ChatMessagePartType.audioUrl, 'audio/mp3', data: invalid),
          'Video with invalid base64':
              media(ChatMessagePartType.videoUrl, 'video/mp4', data: invalid),
          'File with invalid base64':
              media(ChatMessagePartType.fileUrl, 'application/pdf', data: invalid),
          'Image with nil media':
              const MessageInputPart(type: ChatMessagePartType.imageUrl),
          'Audio with nil media':
              const MessageInputPart(type: ChatMessagePartType.audioUrl),
          'Video with nil media':
              const MessageInputPart(type: ChatMessagePartType.videoUrl),
          'File with nil media':
              const MessageInputPart(type: ChatMessagePartType.fileUrl),
        };
        for (final MapEntry(key: name, value: part) in cases.entries) {
          test(name, () {
            expect(
              () => convert([part]),
              throwsA(isA<ThreepioFormatException>()),
            );
          });
        }
      });
    });

    group('convOutputMedia', () {
      MessageOutputPart media(ChatMessagePartType type, String? mimeType,
          {String data = _pngBase64}) {
        final common = MessagePartCommon(base64Data: data, mimeType: mimeType);
        return switch (type) {
          ChatMessagePartType.imageUrl =>
            MessageOutputPart(type: type, image: common),
          ChatMessagePartType.audioUrl =>
            MessageOutputPart(type: type, audio: common),
          _ => MessageOutputPart(type: type, video: common),
        };
      }

      List<Map<String, dynamic>> convert(List<MessageOutputPart> parts) =>
          _parts(
            GeminiConverters.messageToGemini(
              Message(role: RoleType.assistant, assistantGenMultiContent: parts),
            ),
          );

      test('success', () {
        final parts = convert([
          const MessageOutputPart(type: ChatMessagePartType.text, text: 'hello'),
          media(ChatMessagePartType.imageUrl, 'image/png'),
          media(ChatMessagePartType.audioUrl, 'audio/mp3'),
          media(ChatMessagePartType.videoUrl, 'video/mp4'),
        ]);
        expect(parts, hasLength(4));
        expect(parts[0]['text'], 'hello');
        expect(parts[1]['inline_data']['mime_type'], 'image/png');
        expect(parts[2]['inline_data']['mime_type'], 'audio/mp3');
        expect(parts[3]['inline_data']['mime_type'], 'video/mp4');
        expect(parts[1]['inline_data']['data'], decoded);
      });

      group('error cases', () {
        const invalid = 'invalid-base64';
        final cases = <String, MessageOutputPart>{
          'Image with invalid base64':
              media(ChatMessagePartType.imageUrl, null, data: invalid),
          'Audio with invalid base64':
              media(ChatMessagePartType.audioUrl, null, data: invalid),
          'Video with invalid base64':
              media(ChatMessagePartType.videoUrl, null, data: invalid),
          'Image with nil media':
              const MessageOutputPart(type: ChatMessagePartType.imageUrl),
          'Audio with nil media':
              const MessageOutputPart(type: ChatMessagePartType.audioUrl),
          'Video with nil media':
              const MessageOutputPart(type: ChatMessagePartType.videoUrl),
        };
        for (final MapEntry(key: name, value: part) in cases.entries) {
          test(name, () {
            expect(
              () => convert([part]),
              throwsA(isA<ThreepioFormatException>()),
            );
          });
        }
      });
    });
  });

  group('TestThoughtSignatureRoundTrip', () {
    test('convToolMessageToPart (deviation: text results are {"result": …})',
        () {
      final content = GeminiConverters.messageToGemini(
        Message(role: RoleType.tool, content: '{"result":"ok"}', toolName: 'tool_1'),
      );
      final response = _parts(content).single['functionResponse'];
      expect(response['name'], 'tool_1');
      expect(response['response'], {'result': '{"result":"ok"}'});
    });

    test('convToolMessageToPart fallback to output', () {
      final content = GeminiConverters.messageToGemini(
        Message(role: RoleType.tool, content: 'raw-response', toolName: 'tool_2'),
      );
      final response = _parts(content).single['functionResponse'];
      expect(response['name'], 'tool_2');
      expect(response['response'], {'result': 'raw-response'});
    });

    test('convSchemaMessages merges consecutive tool responses', () {
      final contents = GeminiConverters.messagesToGemini([
        Message(
          role: RoleType.assistant,
          toolCalls: [
            _call('call_a', 'fn_a', '{"x":1}'),
            _call('call_b', 'fn_b', '{"y":2}'),
          ],
        ),
        Message.tool(content: '{"res":"A"}', toolCallId: 'call_a'),
        Message.tool(content: '{"res":"B"}', toolCallId: 'call_b'),
      ]);

      expect(contents, hasLength(2));
      expect(contents[0]['role'], 'model');
      expect(contents[1]['role'], 'user');
      final parts = _parts(contents[1]);
      expect(parts, hasLength(2));
      expect(parts[0]['functionResponse']['name'], 'call_a');
      expect(parts[0]['functionResponse']['response'], {'result': '{"res":"A"}'});
      expect(parts[1]['functionResponse']['name'], 'call_b');
      expect(parts[1]['functionResponse']['response'], {'result': '{"res":"B"}'});
    });

    test('convSchemaMessage without thought signature', () {
      final content = GeminiConverters.messageToGemini(
        Message(
          role: RoleType.assistant,
          toolCalls: [_call('test_call', 'test_function', '{"param":"value"}')],
        ),
      );
      final parts = _parts(content);
      expect(parts, hasLength(1));
      expect(parts[0].containsKey('thoughtSignature'), isFalse);
      expect(parts[0]['functionCall'], isNotNull);
    });

    test(
        'convSchemaMessage restores reasoning content with thought signature '
        'on final part', () {
      final signature = utf8.encode('reasoning_thought_signature');
      final message = const Message(
        role: RoleType.assistant,
        content: 'final answer',
        reasoningContent: 'thinking process',
      ).withGeminiThoughtSignature(signature);

      final parts = _parts(GeminiConverters.messageToGemini(message));

      expect(parts, hasLength(2));
      expect(parts[0]['thought'], isTrue);
      expect(parts[0]['text'], 'thinking process');
      expect(parts[0].containsKey('thoughtSignature'), isFalse);
      expect(parts[1].containsKey('thought'), isFalse);
      expect(parts[1]['text'], 'final answer');
      expect(parts[1]['thoughtSignature'], base64Encode(signature));
    });

    test('convSchemaMessage restores reasoning content without thought signature',
        () {
      final parts = _parts(
        GeminiConverters.messageToGemini(
          const Message(
            role: RoleType.assistant,
            content: 'final answer',
            reasoningContent: 'thinking process',
          ),
        ),
      );
      expect(parts, hasLength(2));
      expect(parts[0]['thought'], isTrue);
      expect(parts[0]['text'], 'thinking process');
      expect(parts[0].containsKey('thoughtSignature'), isFalse);
    });

    test(
        'convSchemaMessage with reasoning content and tool calls with '
        'signature on functionCall', () {
      final fcSignature = utf8.encode('function_call_signature');
      final parts = _parts(
        GeminiConverters.messageToGemini(
          Message(
            role: RoleType.assistant,
            reasoningContent: 'thinking before calling tool',
            toolCalls: [
              _call('test_call', 'test_function', '{"param":"value"}')
                  .withGeminiThoughtSignature(fcSignature),
            ],
          ),
        ),
      );
      expect(parts, hasLength(2));
      expect(parts[0]['thought'], isTrue);
      expect(parts[0]['text'], 'thinking before calling tool');
      expect(parts[0].containsKey('thoughtSignature'), isFalse);
      expect(parts[1]['functionCall']['name'], 'test_function');
      expect(parts[1]['thoughtSignature'], base64Encode(fcSignature));
    });

    test('convSchemaMessage with tool call signature on functionCall part', () {
      final signature = utf8.encode('function_call_signature');
      final parts = _parts(
        GeminiConverters.messageToGemini(
          Message(
            role: RoleType.assistant,
            toolCalls: [
              _call('test_call', 'check_flight', '{"flight":"AA100"}')
                  .withGeminiThoughtSignature(signature),
            ],
          ),
        ),
      );
      expect(parts, hasLength(1));
      expect(parts[0]['functionCall']['name'], 'check_flight');
      expect(parts[0]['thoughtSignature'], base64Encode(signature));
    });

    test('convSchemaMessage with parallel tool calls (first has signature)', () {
      final signature = utf8.encode('parallel_signature');
      final parts = _parts(
        GeminiConverters.messageToGemini(
          Message(
            role: RoleType.assistant,
            toolCalls: [
              _call('call_1', 'get_weather', '{"location":"Paris"}')
                  .withGeminiThoughtSignature(signature),
              _call('call_2', 'get_weather', '{"location":"London"}'),
            ],
          ),
        ),
      );
      expect(parts, hasLength(2));
      expect(parts[0]['functionCall']['name'], 'get_weather');
      expect(parts[0]['thoughtSignature'], base64Encode(signature));
      expect(parts[1]['functionCall']['name'], 'get_weather');
      expect(parts[1].containsKey('thoughtSignature'), isFalse);
    });

    test('convSchemaMessage with text part signature', () {
      final signature = utf8.encode('text_signature');
      final parts = _parts(
        GeminiConverters.messageToGemini(
          const Message(role: RoleType.assistant, content: 'This is the response')
              .withGeminiThoughtSignature(signature),
        ),
      );
      expect(parts, hasLength(1));
      expect(parts[0]['text'], 'This is the response');
      expect(parts[0]['thoughtSignature'], base64Encode(signature));
    });

    test('convCandidate extracts signature from functionCall part', () {
      final signature = utf8.encode('extracted_signature');
      final message = GeminiConverters.geminiToMessage({
        'content': {
          'role': 'model',
          'parts': [
            {
              'functionCall': {
                'name': 'check_flight',
                'args': {'flight': 'AA100'},
              },
              'thoughtSignature': base64Encode(signature),
            },
          ],
        },
      });

      expect(message.toolCalls, hasLength(1));
      final onCall = geminiThoughtSignatureFromExtra(message.toolCalls![0].extra);
      expect(onCall.present, isTrue);
      expect(onCall.signature, signature);
      final onMessage = geminiThoughtSignatureFromExtra(message.extra);
      expect(onMessage.present, isFalse);
      expect(onMessage.signature, isNull);
    });

    test(
        'convCandidate extracts signature from text part (deviation: kept on '
        'the message, the text is the content)', () {
      final signature = utf8.encode('text_part_signature');
      final message = GeminiConverters.geminiToMessage({
        'content': {
          'role': 'model',
          'parts': [
            {'text': 'Final response', 'thoughtSignature': base64Encode(signature)},
          ],
        },
      });

      expect(message.content, 'Final response');
      expect(message.assistantGenMultiContent, isNull);
      final onMessage = geminiThoughtSignatureFromExtra(message.extra);
      expect(onMessage.present, isTrue);
      expect(onMessage.signature, signature);
    });

    test(
        'convCandidate stores signatures and convSchemaMessage restores them '
        '(deviation: the text parts are joined, the last signature is kept)',
        () {
      final sigA = utf8.encode('sig_A');
      final sigB = utf8.encode('sig_B');
      final message = GeminiConverters.geminiToMessage({
        'content': {
          'role': 'model',
          'parts': [
            {'text': 'A', 'thoughtSignature': base64Encode(sigA)},
            {'text': 'B', 'thoughtSignature': base64Encode(sigB)},
          ],
        },
      });
      expect(message.content, 'AB');
      expect(message.geminiThoughtSignature, sigB);

      final parts = _parts(GeminiConverters.messageToGemini(message));
      expect(parts, hasLength(1));
      expect(parts[0]['text'], 'AB');
      expect(parts[0]['thoughtSignature'], base64Encode(sigB));
    });

    test('signatures on generated media parts stay on their parts', () {
      final sigA = utf8.encode('sig_A');
      final sigB = utf8.encode('sig_B');
      final message = GeminiConverters.geminiToMessage({
        'content': {
          'role': 'model',
          'parts': [
            {
              'inlineData': {'mimeType': 'image/png', 'data': _pngBase64},
              'thoughtSignature': base64Encode(sigA),
            },
            {
              'inlineData': {'mimeType': 'image/png', 'data': _pngBase64},
              'thoughtSignature': base64Encode(sigB),
            },
          ],
        },
      });
      expect(message.extra, isNull);
      expect(message.assistantGenMultiContent![0].geminiThoughtSignature, sigA);
      expect(message.assistantGenMultiContent![1].geminiThoughtSignature, sigB);

      final parts = _parts(GeminiConverters.messageToGemini(message));
      expect(parts, hasLength(2));
      expect(parts[0]['thoughtSignature'], base64Encode(sigA));
      expect(parts[1]['thoughtSignature'], base64Encode(sigB));
      expect(parts[0]['inline_data']['data'], base64Encode(base64Decode(_pngBase64)));
    });

    test('sequential function call signatures are preserved separately', () {
      final sigA = utf8.encode('signature_A');
      final sigB = utf8.encode('signature_B');
      Message step(String name, Map<String, Object?> args, List<int> sig) =>
          GeminiConverters.geminiToMessage({
            'content': {
              'role': 'model',
              'parts': [
                {
                  'functionCall': {'name': name, 'args': args},
                  'thoughtSignature': base64Encode(sig),
                },
              ],
            },
          });

      final msg1 = step('check_flight', {'flight': 'AA100'}, sigA);
      expect(msg1.toolCalls![0].geminiThoughtSignature, sigA);
      final msg2 = step('book_taxi', {'time': '10 AM'}, sigB);
      expect(msg2.toolCalls![0].geminiThoughtSignature, sigB);

      expect(
        _parts(GeminiConverters.messageToGemini(msg1))[0]['thoughtSignature'],
        base64Encode(sigA),
      );
      expect(
        _parts(GeminiConverters.messageToGemini(msg2))[0]['thoughtSignature'],
        base64Encode(sigB),
      );
    });
  });

  group('TestCreatePrefixCache', () {
    final tool = ToolInfo.fromParams(name: 'tool_a', desc: 'desc', params: {});

    test('basic', () async {
      final fake = _model((_) => {'name': 'cached/basic'});
      final cache = await fake.model.createPrefixCache([Message.user('Hello')]);
      expect(cache.name, 'cached/basic');
      expect(fake.requests.single.url.path, endsWith('/cachedContents'));
      expect(fake.requests.single.method, 'POST');
    });

    test('cache_instruction_tools_messages', () async {
      final fake = _model(
        (_) => {'name': 'cached/cache_instruction_tools_messages'},
        config: _config.copyWith(
          cache: const GeminiCacheConfig(ttl: Duration(minutes: 1)),
          enableCodeExecution: true,
        ),
      );

      final cache = await fake.model.createPrefixCache(
        [Message.system('sys'), Message.user('hello')],
        options: ChatModelOptions(tools: [tool]),
      );

      expect(cache.name, 'cached/cache_instruction_tools_messages');
      final body = _body(fake.requests.single);
      expect(body['model'], 'models/test-model');
      expect(body['ttl'], '60s');
      expect(body['contents'][0]['parts'][0]['text'], 'hello');
      expect(body['systemInstruction']['parts'][0]['text'], 'sys');
      final tools = body['tools'] as List;
      expect(tools, hasLength(2));
      expect(tools[0]['functionDeclarations'][0]['name'], 'tool_a');
      expect(tools[1]['codeExecution'], isNotNull);
    });

    test('cache_and_generate', () async {
      final fake = _model(
        (request) => request.url.path.endsWith('/cachedContents')
            ? {'name': 'cachedContents/cache_and_generate'}
            : _response([
                {'text': 'bye too'},
              ]),
        config: _config.copyWith(
          cache: const GeminiCacheConfig(ttl: Duration(minutes: 1)),
          enableCodeExecution: true,
        ),
      );

      final cache = await fake.model.createPrefixCache(
        [Message.system('sys'), Message.user('hello')],
        options: ChatModelOptions(tools: [tool]),
      );
      await fake.model.generate(
        [Message.user('bye')],
        options: GeminiRequestOptions(cachedContentName: cache.name).toOptions(),
      );

      final generateBody = _body(fake.requests.last);
      expect(generateBody['cachedContent'], 'cachedContents/cache_and_generate');
      expect(generateBody.containsKey('systemInstruction'), isFalse);
      expect(generateBody.containsKey('tools'), isFalse);
    });
  });

  test('TestSpecialPart', () {
    final message = GeminiConverters.geminiToMessage({
      'content': {
        'role': 'model',
        'parts': [
          {
            'executableCode': {'code': 'code', 'language': 'language'},
          },
          {
            'codeExecutionResult': {'outcome': 'outcome', 'output': 'output'},
          },
        ],
      },
    });

    final parts = _parts(GeminiConverters.messageToGemini(message));

    expect(parts[0]['executableCode']['code'], 'code');
    expect(parts[0]['executableCode']['language'], 'language');
    expect(parts[1]['codeExecutionResult']['output'], 'output');
    expect(parts[1]['codeExecutionResult']['outcome'], 'outcome');
  });

  group('TestPopulateToolChoice', () {
    final tools = [
      {
        'functionDeclarations': [
          {'name': 'tool1'},
        ],
      },
    ];

    test('nil tool choice', () {
      expect(GeminiConverters.toolConfigToGemini(null, tools: const []), isNull);
      expect(GeminiConverters.toolConfigToGemini(null, tools: tools), isNull);
    });

    test('allowed tool not found', () {
      expect(
        () => GeminiConverters.toolConfigToGemini(
          ToolChoice.allowed,
          tools: tools,
          allowedToolNames: ['tool2'],
        ),
        throwsArgumentError,
      );
    });

    test('tool choice forbidden', () {
      expect(
        GeminiConverters.toolConfigToGemini(ToolChoice.forbidden, tools: const []),
        {
          'functionCallingConfig': {'mode': 'NONE'},
        },
      );
    });

    test('tool choice allowed', () {
      expect(
        GeminiConverters.toolConfigToGemini(ToolChoice.allowed, tools: tools),
        {
          'functionCallingConfig': {'mode': 'AUTO'},
        },
      );
    });

    test('tool choice allowed with allowed_tools', () {
      expect(
        GeminiConverters.toolConfigToGemini(
          ToolChoice.allowed,
          tools: tools,
          allowedToolNames: ['tool1'],
        ),
        {
          'functionCallingConfig': {
            'mode': 'VALIDATED',
            'allowedFunctionNames': ['tool1'],
          },
        },
      );
    });

    test('tool choice required', () {
      expect(
        GeminiConverters.toolConfigToGemini(ToolChoice.forced, tools: tools),
        {
          'functionCallingConfig': {'mode': 'ANY'},
        },
      );
    });

    test('tool choice required with allowed_tools', () {
      expect(
        GeminiConverters.toolConfigToGemini(
          ToolChoice.forced,
          tools: tools,
          allowedToolNames: ['tool1'],
        ),
        {
          'functionCallingConfig': {
            'mode': 'ANY',
            'allowedFunctionNames': ['tool1'],
          },
        },
      );
    });

    test('tool choice required without tools', () {
      expect(
        () => GeminiConverters.toolConfigToGemini(ToolChoice.forced, tools: const []),
        throwsArgumentError,
      );
    });
  });

  group('TestUniqueToolCallIDs', () {
    Map<String, Object?> candidate(List<(String, Map<String, Object?>)> calls) =>
        {
          'content': {
            'role': 'model',
            'parts': [
              for (final (name, args) in calls)
                {
                  'functionCall': {'name': name, 'args': args},
                },
            ],
          },
        };

    test('single tool call gets UUID as ID', () {
      final message = GeminiConverters.geminiToMessage(
        candidate([
          ('get_weather', {'city': 'Paris'}),
        ]),
      );
      expect(message.toolCalls, hasLength(1));
      expect(message.toolCalls![0].id, matches(_uuidPattern));
      expect(message.toolCalls![0].function.name, 'get_weather');
    });

    test('multiple calls to same function get unique UUID IDs', () {
      final message = GeminiConverters.geminiToMessage(
        candidate([
          ('get_weather', {'city': 'Paris'}),
          ('get_weather', {'city': 'London'}),
          ('get_weather', {'city': 'Tokyo'}),
        ]),
      );
      final calls = message.toolCalls!;
      expect(calls, hasLength(3));
      for (final call in calls) {
        expect(call.id, matches(_uuidPattern));
      }
      expect(calls.map((c) => c.id).toSet(), hasLength(3));
      expect(
        [for (final c in calls) (jsonDecode(c.function.arguments) as Map)['city']],
        ['Paris', 'London', 'Tokyo'],
      );
    });

    test('multiple calls to different functions get unique UUID IDs', () {
      final message = GeminiConverters.geminiToMessage(
        candidate([
          ('get_weather', {'city': 'Paris'}),
          ('get_time', {'timezone': 'UTC'}),
          ('calculate', {'expression': '2+2'}),
        ]),
      );
      final ids = message.toolCalls!.map((c) => c.id).toList();
      expect(ids, everyElement(matches(_uuidPattern)));
      expect(ids.toSet(), hasLength(3));
    });

    test('mixed scenario with multiple function calls', () {
      final message = GeminiConverters.geminiToMessage(
        candidate([
          ('function_a', {'param': '1'}),
          ('function_a', {'param': '2'}),
          ('function_b', {'param': '3'}),
          ('function_a', {'param': '4'}),
          ('function_a', {'param': '5'}),
        ]),
      );
      final ids = message.toolCalls!.map((c) => c.id).toList();
      expect(ids, hasLength(5));
      expect(ids, everyElement(matches(_uuidPattern)));
      expect(ids.toSet(), hasLength(5));
    });

    test('multiple responses generate unique UUIDs', () {
      const parser = GeminiResponseParser();
      final message1 = parser.parseCompletionResponse({
        'candidates': [
          candidate([
            ('search', {'query': 'first'}),
            ('search', {'query': 'second'}),
          ]),
        ],
      });
      final message2 = parser.parseCompletionResponse({
        'candidates': [
          candidate([
            ('search', {'query': 'third'}),
          ]),
        ],
      });
      final ids = [
        ...message1.toolCalls!.map((c) => c.id),
        ...message2.toolCalls!.map((c) => c.id),
      ];
      expect(ids, hasLength(3));
      expect(ids, everyElement(matches(_uuidPattern)));
      expect(ids.toSet(), hasLength(3));
    });
  });

  group('TestConvSchemaMessageToolCallOrder', () {
    test(
        'AssistantGenMultiContent with tool calls - tool calls come after '
        'media parts', () {
      final data = base64Encode(utf8.encode('123'));
      final parts = _parts(
        GeminiConverters.messageToGemini(
          Message(
            role: RoleType.assistant,
            assistantGenMultiContent: [
              const MessageOutputPart(
                type: ChatMessagePartType.text,
                text: "Here's the image:",
              ),
              MessageOutputPart(
                type: ChatMessagePartType.imageUrl,
                image: MessagePartCommon(base64Data: data, mimeType: 'image/png'),
              ),
            ],
            toolCalls: [_call('call_1', 'analyze_image', '{"image_id":"123"}')],
          ),
        ),
      );
      expect(parts, hasLength(3));
      expect(parts[0]['text'], "Here's the image:");
      expect(parts[1]['inline_data']['mime_type'], 'image/png');
      expect(parts[2]['functionCall']['name'], 'analyze_image');
    });

    test('Content with reasoning and tool calls - correct order', () {
      final parts = _parts(
        GeminiConverters.messageToGemini(
          Message(
            role: RoleType.assistant,
            content: 'Final answer',
            reasoningContent: 'Thinking process',
            toolCalls: [_call('call_1', 'tool', '{}')],
          ),
        ),
      );
      expect(parts, hasLength(3));
      expect(parts[0]['thought'], isTrue);
      expect(parts[0]['text'], 'Thinking process');
      expect(parts[1]['text'], 'Final answer');
      expect(parts[2]['functionCall']['name'], 'tool');
    });

    test('Multiple tool calls with content - all tool calls come after text',
        () {
      final parts = _parts(
        GeminiConverters.messageToGemini(
          Message(
            role: RoleType.assistant,
            content: 'I need to check several things:',
            toolCalls: [
              _call('call_1', 'tool1', '{"a":1}'),
              _call('call_2', 'tool2', '{"b":2}'),
            ],
          ),
        ),
      );
      expect(parts, hasLength(3));
      expect(parts[0]['text'], 'I need to check several things:');
      expect(parts[1]['functionCall']['name'], 'tool1');
      expect(parts[2]['functionCall']['name'], 'tool2');
    });
  });

  group('TestConvLogprobs', () {
    test('nil input / empty chosen candidates', () {
      expect(GeminiConverters.logprobsToSchema(const {}), isNull);
      expect(
        GeminiConverters.logprobsToSchema(const {'chosenCandidates': <Object?>[]}),
        isNull,
      );
    });

    test('all chosen candidates nil', () {
      expect(
        GeminiConverters.logprobsToSchema(const {
          'chosenCandidates': [null, null],
        }),
        isNull,
      );
    });

    test('normal with top candidates', () {
      final got = GeminiConverters.logprobsToSchema(const {
        'chosenCandidates': [
          {'token': 'hello', 'logProbability': -0.1},
          {'token': 'world', 'logProbability': -0.2},
        ],
        'topCandidates': [
          {
            'candidates': [
              {'token': 'hello', 'logProbability': -0.1},
              {'token': 'hi', 'logProbability': -1.5},
            ],
          },
          {
            'candidates': [
              {'token': 'world', 'logProbability': -0.2},
            ],
          },
        ],
      })!;
      expect(got.content, hasLength(2));
      expect(got.content[0].token, 'hello');
      expect(got.content[0].logProb, closeTo(-0.1, 1e-6));
      expect(got.content[0].topLogProbs, hasLength(2));
      expect(got.content[0].topLogProbs[1].token, 'hi');
      expect(got.content[0].topLogProbs[1].logProb, closeTo(-1.5, 1e-6));
      expect(got.content[1].topLogProbs, hasLength(1));
    });

    test('top candidates length mismatch', () {
      final got = GeminiConverters.logprobsToSchema(const {
        'chosenCandidates': [
          {'token': 'a', 'logProbability': -0.1},
          {'token': 'b', 'logProbability': -0.2},
        ],
        'topCandidates': [
          {
            'candidates': [
              {'token': 'a', 'logProbability': -0.1},
            ],
          },
        ],
      })!;
      expect(got.content, hasLength(2));
      expect(got.content[0].topLogProbs, hasLength(1));
      expect(got.content[1].topLogProbs, isEmpty);
    });

    test('top candidate entry nil and inner nil', () {
      final got = GeminiConverters.logprobsToSchema(const {
        'chosenCandidates': [
          {'token': 'a', 'logProbability': -0.1},
        ],
        'topCandidates': [
          {
            'candidates': [
              null,
              {'token': 'x', 'logProbability': -0.5},
            ],
          },
        ],
      })!;
      expect(got.content, hasLength(1));
      expect(got.content[0].topLogProbs, hasLength(1));
      expect(got.content[0].topLogProbs[0].token, 'x');
    });
  });

  group('TestLogprobsOptionsOverride', () {
    final config = _config.copyWith(responseLogprobs: true, logprobs: 5);

    Future<Map<String, dynamic>> generationConfig(ChatModelOptions? options) async {
      final fake = _model(
        (_) => _response([
          {'text': 'ok'},
        ]),
        config: config,
      );
      await fake.model.generate([Message.user('hi')], options: options);
      return _body(fake.requests.single)['generationConfig'] as Map<String, dynamic>;
    }

    test('config defaults applied', () async {
      final m = await generationConfig(null);
      expect(m['responseLogprobs'], isTrue);
      expect(m['logprobs'], 5);
    });

    test('option overrides response logprobs to false', () async {
      final m = await generationConfig(
        GeminiRequestOptions(responseLogprobs: false).toOptions(),
      );
      expect(m.containsKey('responseLogprobs'), isFalse);
    });

    test('option overrides logprobs top-K', () async {
      final m = await generationConfig(GeminiRequestOptions(logprobs: 3).toOptions());
      expect(m['logprobs'], 3);
    });
  });

  group('TestWithLabels', () {
    test('labels rejected on gemini api backend', () async {
      final fake = _model(
        (_) => _response([
          {'text': 'ok'},
        ]),
      );
      await expectLater(
        fake.model.generate(
          [Message.user('hi')],
          options: GeminiRequestOptions(
            labels: {'team': 'search', 'env': 'prod'},
          ).toOptions(),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Vertex AI'),
          ),
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('no labels leaves field unset on gemini api backend', () async {
      final fake = _model(
        (_) => _response([
          {'text': 'ok'},
        ]),
      );
      await fake.model.generate([Message.user('hi')]);
      expect(_body(fake.requests.single).containsKey('labels'), isFalse);
    });
  });

  test('TestConvCandidateLogprobs', () {
    final message = GeminiConverters.geminiToMessage({
      'content': {
        'role': 'model',
        'parts': [
          {'text': 'hi'},
        ],
      },
      'logprobsResult': {
        'chosenCandidates': [
          {'token': 'hi', 'logProbability': -0.05},
        ],
      },
    });
    expect(message.responseMeta!.logProbs!.content, hasLength(1));
    expect(message.responseMeta!.logProbs!.content[0].token, 'hi');
  });
}
