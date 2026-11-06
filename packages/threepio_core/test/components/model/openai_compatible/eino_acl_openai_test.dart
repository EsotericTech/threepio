// Port of eino-ext libs/acl/openai: chat_model_test.go, option_test.go,
// message_extra_test.go.
//
// The Go tests mock go-openai with mockey. Here the same behaviour is tested
// through a fake HTTP server (`MockClient`, fixtures in the wire format of
// the Chat Completions API) or directly on `buildChatCompletionBody` (Go
// `genRequest`), `openAIToolChoice` (Go `populateToolChoice`),
// `OpenAIConverters.messageToOpenAI(goCompatible: true)` (Go
// `buildMessageFrom…`) and `OpenAICompatibleResponseParser` (Go
// `buildGenerateResponse` / `streamMessageBuilder`).
//
// Ported: TestStream, TestGenerate, TestToXXXUtils (roles, tool calls and
// usage, the converters that exist), TestToOpenAIToolCalls, TestLogProbs,
// TestWithTools, TestBuildMessages (the assistant part),
// TestBuildMessageFromUserInputMultiContent, Test_newStreamMessageBuilder,
// Test_streamMessageBuilder_setOutputMessageAudio,
// Test_streamMessageBuilder_build, Test_genRequest, TestPopulateToolChoice,
// Test_OpenAIOptions_Setters, TestConcatMessages, TestSetGetRequestID,
// TestPopulateRCFromExtra.
//
// Not ported:
// * TestToXXXUtils/toOpenAIMultiContent and
//   TestBuildMessages/buildMessageFromMultiContent: they convert the
//   deprecated `Message.MultiContent`, which threepio does not have.
// * TestPanicErr: Dart has no panics to recover from.
// * TestToTools: Go sorts `required` arrays; not ported (intended).
// * Test_OpenAIOptions_Setters/WithRequestBodyModifier: deprecated in Go.
// * TestSetMsgExtra: a private helper of the Go package.
// * TestPopulateToolChoice/unsupported tool choice: `ToolChoice` is an enum.
// * agentic_convert_test.go: the agentic client is P13.
// embedding_test.go (TestEmbedStrings) is ported in
// test/components/embedding/openai_embedder_upgrade_test.dart.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/openai_compatible/client.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_converters.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_options.dart';
import 'package:threepio_core/threepio_core.dart';

typedef _Sent = ({Uri url, Map<String, String> headers, Map<String, Object?> body});

/// A fake Chat Completions endpoint that records what it was sent.
final class _FakeApi {
  final sent = <_Sent>[];

  Map<String, Object?> get body => sent.last.body;

  http.Client json(Object response, {int status = 200}) =>
      MockClient((request) async {
        sent.add((
          url: request.url,
          headers: request.headers,
          body: jsonDecode(request.body) as Map<String, Object?>,
        ));
        return http.Response(
          jsonEncode(response),
          status,
          headers: const {'content-type': 'application/json'},
        );
      });

  http.Client sse(List<String> chunks, {int status = 200}) =>
      MockClient.streaming((request, bytes) async {
        final text = await bytes.bytesToString();
        sent.add((
          url: request.url,
          headers: request.headers,
          body: jsonDecode(text) as Map<String, Object?>,
        ));
        return http.StreamedResponse(
          Stream.fromIterable([for (final c in chunks) utf8.encode(c)]),
          status,
        );
      });
}

String _data(Object chunk) => 'data: ${jsonEncode(chunk)}\n\n';

const _done = 'data: [DONE]\n\n';

const _config = OpenAIConfig(
  apiKey: 'test-key',
  baseUrl: 'https://api.example.com/v1',
  defaultModel: 'test-model',
);

Map<String, Object?> _completion(
  Map<String, Object?> message, {
  String? id = 'chatcmpl-1',
  Map<String, Object?>? usage,
  int index = 0,
}) =>
    {
      if (id != null) 'id': id,
      'object': 'chat.completion',
      'created': 1735689600,
      'model': 'test-model',
      'choices': [
        {'index': index, 'message': message, 'finish_reason': 'stop'},
      ],
      if (usage != null) 'usage': usage,
    };

Map<String, Object?> _chunk(Map<String, Object?> delta, {String? finish}) => {
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    };

Map<String, Object?> _build(
  List<Message> input, {
  ChatModelOptions options = const ChatModelOptions(),
  OpenAIChatSettings settings = const OpenAIChatSettings(model: 'test-model'),
  OpenAIRequestOptions? requestOptions,
  bool stream = false,
}) =>
    buildChatCompletionBody(
      input: input,
      options: options,
      settings: settings,
      stream: stream,
      requestOptions: requestOptions,
    );

Map<String, dynamic> _wire(Message message) =>
    OpenAIConverters.messageToOpenAI(message, goCompatible: true);

ToolInfo _tool(String name) => ToolInfo.fromParams(
      name: name,
      desc: 'desc of $name',
      params: const {
        'param': ParameterInfo(type: DataType.string, required: true),
      },
    );

const _parser = OpenAICompatibleResponseParser();

/// Records the start and end payloads of a model call.
final class _Recorder extends ComponentCallbackHandler {
  ModelCallbackInput? input;
  ModelCallbackOutput? output;

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    this.input = ModelCallbackInput.from(input);
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    this.output = ModelCallbackOutput.from(output);
    return ctx;
  }
}

void main() {
  group('TestStream', () {
    test('stream applies RequestPayloadModifier', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: api.sse(['{"error":{"message":"stop early"}}'], status: 500),
      );
      final input = [Message.user('hello')];
      var calls = 0;

      await expectLater(
        model.stream(
          input,
          options: OpenAIRequestOptions(
            requestPayloadModifier: (ctx, messages, body) {
              calls++;
              expect(messages, same(input));
              return {...body, 'modified': true};
            },
          ).toOptions(),
        ),
        throwsA(isA<OpenAIException>()),
      );
      expect(calls, 1);
      expect(api.body['modified'], isTrue);
    });

    test('stream_with_ResponseChunkMessageModifier', () async {
      final chunk = _chunk({'role': 'assistant', 'content': 'hello'});
      final model = OpenAIChatModel(
        config: _config,
        httpClient: _FakeApi().sse([_data(chunk), _done]),
      );
      final seenBodies = <Map<String, Object?>?>[];
      final seenEnds = <bool>[];

      final out = await model.stream(
        [Message.user('hello')],
        options: OpenAIRequestOptions(
          responseChunkMessageModifier: (ctx, message, raw, {required end}) {
            seenBodies.add(raw);
            seenEnds.add(end);
            if (message == null) return null;
            // Go appends the raw bytes; here the decoded chunk, re-encoded.
            return message.copyWith(
              content: '${message.content}|mod|${jsonEncode(raw)}',
            );
          },
        ).toOptions(),
      );

      final message = await out.recv();
      expect(message.role, RoleType.assistant);
      expect(message.content, 'hello|mod|${jsonEncode(chunk)}');
      await expectLater(out.recv(), throwsA(isA<StreamEOFException>()));
      expect(seenEnds, [false, true]);
      expect(seenBodies, hasLength(2));
      expect(seenBodies[0], chunk);
      // Go: "Some versions may not carry RawBody on EOF; accept empty".
      expect(seenBodies[1], isNull);
    });
  });

  group('TestGenerate', () {
    test('payload and response modifiers', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: api.json(
          _completion(
            {'role': 'assistant', 'content': 'hello'},
            id: 'resp-id-123',
            usage: {
              'prompt_tokens': 10,
              'completion_tokens': 0,
              'total_tokens': 10,
              'completion_tokens_details': {'reasoning_tokens': 10},
            },
          ),
        ),
      );
      final input = [Message.user('hi')];
      var payloadCalls = 0;

      final out = await model.generate(
        input,
        options: OpenAIRequestOptions(
          requestPayloadModifier: (ctx, messages, body) {
            payloadCalls++;
            return body;
          },
          responseMessageModifier: (ctx, message, raw) {
            final choice = (raw['choices']! as List).first as Map;
            return Message(
              role: message.role,
              name: message.name,
              content: '${message.content}|mod|${jsonEncode(choice['message'])}',
              toolCallId: message.toolCallId,
              toolCalls: message.toolCalls,
              responseMeta: message.responseMeta,
            );
          },
        ).toOptions(),
      );

      expect(payloadCalls, 1);
      expect(out.role, RoleType.assistant);
      expect(
        out.responseMeta!.usage!.completionTokenDetails!.reasoningTokens,
        10,
      );
      expect(out.content, 'hello|mod|{"role":"assistant","content":"hello"}');
    });
  });

  group('TestToXXXUtils', () {
    test('toOpenAIRole', () {
      expect(_wire(Message.user('x'))['role'], 'user');
      expect(_wire(Message.assistant('x'))['role'], 'assistant');
      expect(_wire(Message.system('x'))['role'], 'system');
      expect(
        _wire(Message.tool(content: 'x', toolCallId: 'c'))['role'],
        'tool',
      );
    });

    test('toMessageRole', () {
      Message parse(Object? role) => _parser.parseCompletionResponse(
            _completion({'role': role, 'content': 'x'}),
          );
      expect(parse('assistant').role, RoleType.assistant);
      expect(parse('user').role, RoleType.user);
      expect(parse('system').role, RoleType.system);
      expect(parse('tool').role, RoleType.tool);
      // Intended: '' and a missing role are the assistant, `developer` is
      // the system, an unknown role is a format error (Go keeps it as is).
      expect(parse('').role, RoleType.assistant);
      expect(parse(null).role, RoleType.assistant);
      expect(parse('developer').role, RoleType.system);
      expect(() => parse('robot'), throwsA(isA<ThreepioFormatException>()));
    });

    test('toMessageToolCalls', () {
      final message = _parser.parseCompletionResponse(
        _completion({
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'index': 5,
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'get_weather', 'arguments': '{"city":"Paris"}'},
            },
          ],
        }),
      );
      expect(message.content, '');
      expect(message.toolCalls, [
        const ToolCall(
          index: 5,
          id: 'call_1',
          type: 'function',
          function: FunctionCall(
            name: 'get_weather',
            arguments: '{"city":"Paris"}',
          ),
        ),
      ]);
    });

    test('toEinoTokenUsage', () {
      final message = _parser.parseCompletionResponse(
        _completion(
          {'role': 'assistant', 'content': 'x'},
          usage: {
            'prompt_tokens': 100,
            'completion_tokens': 20,
            'total_tokens': 120,
            'prompt_tokens_details': {
              'cached_tokens': 60,
              'cache_write_tokens': 30,
            },
            'completion_tokens_details': {'reasoning_tokens': 12},
          },
        ),
      );
      final usage = message.responseMeta!.usage!;
      expect(usage.promptTokens, 100);
      expect(usage.completionTokens, 20);
      expect(usage.totalTokens, 120);
      expect(usage.promptTokenDetails!.cachedTokens, 60);
      expect(usage.promptTokenDetails!.cacheWriteTokens, 30);
      expect(usage.completionTokenDetails!.reasoningTokens, 12);
    });
  });

  group('TestToOpenAIToolCalls', () {
    test('empty tools', () {
      final wire = _wire(Message.assistant('x', toolCalls: const []));
      expect(wire.containsKey('tool_calls'), isFalse);
    });

    test('normal tools', () {
      const call = ToolCall(
        id: 'abcdefgh',
        function: FunctionCall(name: 'ijklmnop', arguments: 'qrstuvwx'),
      );
      final wire = _wire(Message.assistant('', toolCalls: const [call]));
      final calls = wire['tool_calls'] as List;
      expect(calls, hasLength(1));
      expect((calls.single as Map)['id'], call.id);
      expect(((calls.single as Map)['function'] as Map)['name'], call.function.name);
      expect(
        ((calls.single as Map)['function'] as Map)['arguments'],
        call.function.arguments,
      );
    });
  });

  group('TestLogProbs', () {
    test('converts tokens, bytes and top log probabilities', () {
      expect(
        parseOpenAILogProbs({
          'content': [
            {
              'token': '1',
              'logprob': 1,
              'bytes': [97],
              'top_logprobs': [
                {
                  'token': '2',
                  'logprob': 2,
                  'bytes': [98],
                },
              ],
            },
          ],
        }),
        const LogProbs(
          content: [
            LogProb(
              token: '1',
              logProb: 1,
              bytes: [97],
              topLogProbs: [TopLogProb(token: '2', logProb: 2, bytes: [98])],
            ),
          ],
        ),
      );
      expect(parseOpenAILogProbs(null), isNull);
    });
  });

  group('TestWithTools', () {
    test('keeps the config and binds the tools', () {
      final model = OpenAIChatModel(
        config: const OpenAIConfig(apiKey: 'test-key', defaultModel: 'test model'),
      );
      final bound = model.withTools([ToolInfo.function(name: 'test tool name')])
          as OpenAIChatModel;
      expect(bound.config.defaultModel, 'test model');
      expect(bound.tools!.first.name, 'test tool name');
    });
  });

  group('TestBuildMessages', () {
    group('buildMessageFromAssistantGenMultiContent', () {
      test('success with audio', () {
        final wire = _wire(
          const Message(
            role: RoleType.assistant,
            name: 'test-assistant',
            assistantGenMultiContent: [
              MessageOutputPart(type: ChatMessagePartType.text, text: 'some text'),
              MessageOutputPart(
                type: ChatMessagePartType.audioUrl,
                audio: MessagePartCommon(),
                extra: {openAIGeneratedAudioIdKey: 'audio-id-123'},
              ),
              MessageOutputPart(
                type: ChatMessagePartType.text,
                text: 'this should be ignored',
              ),
            ],
          ),
        );
        expect(wire['role'], 'assistant');
        expect(wire['name'], 'test-assistant');
        expect(wire['audio'], {'id': 'audio-id-123'});
        expect(wire['content'], isNull,
            reason: 'MultiContent should be empty when audio is present');
      });

      test('success with text only', () {
        final wire = _wire(
          const Message(
            role: RoleType.assistant,
            name: 'test-assistant',
            assistantGenMultiContent: [
              MessageOutputPart(type: ChatMessagePartType.text, text: 'some text'),
            ],
          ),
        );
        expect(wire['role'], 'assistant');
        expect(wire.containsKey('audio'), isFalse);
        expect(wire['content'], [
          {'type': 'text', 'text': 'some text'},
        ]);
      });

      test('error on getting audio id', () {
        // Intended deviation: Go fails ("failed to get audio ID"); the
        // lenient conversion skips an audio part without an id.
        final wire = _wire(
          const Message(
            role: RoleType.assistant,
            assistantGenMultiContent: [
              MessageOutputPart(
                type: ChatMessagePartType.audioUrl,
                audio: MessagePartCommon(),
              ),
            ],
          ),
        );
        expect(wire.containsKey('audio'), isFalse);
        expect(wire['content'], isNull);
      });

      test('error on unsupported part type', () {
        // Intended deviation: Go fails ("unsupported chat message part
        // type"); unsupported assistant output parts are skipped.
        final wire = _wire(
          const Message(
            role: RoleType.assistant,
            assistantGenMultiContent: [
              MessageOutputPart(
                type: ChatMessagePartType.imageUrl,
                image: MessagePartCommon(url: 'https://example.com/a.png'),
              ),
            ],
          ),
        );
        expect(wire['content'], isNull);
      });

      test('a reasoning part is sent as reasoning_content', () {
        final wire = _wire(
          const Message(
            role: RoleType.assistant,
            content: 'answer',
            reasoningContent: 'from the field',
            assistantGenMultiContent: [
              MessageOutputPart(
                type: ChatMessagePartType.reasoning,
                reasoning: MessageOutputReasoning(text: 'from the part'),
              ),
            ],
          ),
        );
        expect(wire['reasoning_content'], 'from the part');
        expect(wire['content'], 'answer');
      });
    });

    test('a plain assistant message carries its reasoning_content', () {
      final wire = _wire(
        const Message(
          role: RoleType.assistant,
          content: 'hi',
          reasoningContent: 'think',
        ),
      );
      expect(wire, {
        'role': 'assistant',
        'content': 'hi',
        'reasoning_content': 'think',
      });
      expect(
        _wire(const Message(role: RoleType.user, content: 'hi', reasoningContent: 'x'))
            .containsKey('reasoning_content'),
        isFalse,
      );
    });
  });

  group('TestBuildMessageFromUserInputMultiContent', () {
    const base64Data = 'base64data';
    const text = 'hello';

    test('success', () {
      final wire = _wire(
        const Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart(type: ChatMessagePartType.text, text: text),
            MessageInputPart(
              type: ChatMessagePartType.imageUrl,
              image: MessageInputImage(
                common: MessagePartCommon(
                  base64Data: base64Data,
                  mimeType: 'image/png',
                ),
                detail: ImageURLDetail.high,
              ),
            ),
            MessageInputPart(
              type: ChatMessagePartType.audioUrl,
              audio: MessageInputAudio(
                common: MessagePartCommon(
                  base64Data: base64Data,
                  mimeType: 'audio/wav',
                ),
              ),
            ),
            MessageInputPart(
              type: ChatMessagePartType.videoUrl,
              video: MessageInputVideo(
                common: MessagePartCommon(
                  base64Data: base64Data,
                  mimeType: 'video/mp4',
                ),
              ),
            ),
          ],
        ),
      );
      expect(wire, {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:image/png;base64,base64data',
              'detail': 'high',
            },
          },
          {
            'type': 'input_audio',
            'input_audio': {'data': base64Data, 'format': 'wav'},
          },
          {
            'type': 'video_url',
            'video_url': {'url': 'data:video/mp4;base64,base64data'},
          },
        ],
      });
    });

    test('tool role success', () {
      final wire = _wire(
        const Message(
          role: RoleType.tool,
          userInputMultiContent: [
            MessageInputPart(type: ChatMessagePartType.text, text: text),
          ],
        ),
      );
      expect(wire, {
        'role': 'tool',
        'content': [
          {'type': 'text', 'text': text},
        ],
      });
    });

    test('unsupported role', () {
      // Intended deviation: Go accepts user input parts on user and tool
      // messages only; the lenient conversion sends them for any role.
      final wire = _wire(
        const Message(
          role: RoleType.system,
          userInputMultiContent: [
            MessageInputPart(type: ChatMessagePartType.text, text: text),
          ],
        ),
      );
      expect(wire['role'], 'system');
      expect(wire['content'], [
        {'type': 'text', 'text': text},
      ]);
    });

    test('unsupported type', () {
      expect(
        () => _wire(
          const Message(
            role: RoleType.user,
            userInputMultiContent: [
              MessageInputPart(type: ChatMessagePartType.reasoning),
            ],
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('the errors of the Go conversion', () {
      Map<String, dynamic> one(MessageInputPart part) =>
          _wire(Message(role: RoleType.user, userInputMultiContent: [part]));

      expect(
        () => one(const MessageInputPart(type: ChatMessagePartType.imageUrl)),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            "the 'image' field is required for parts of type 'image_url'")),
      );
      expect(
        () => one(MessageInputPart.video(base64Data: 'AAA')),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'mimetype is required when using base64data')),
      );
      expect(
        () => one(MessageInputPart.audio(url: 'https://example.com/a.wav')),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            contains('does not accept URL'))),
      );
      expect(
        () => one(MessageInputPart.audio(base64Data: 'AAA', mimeType: 'audio/ogg')),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            contains("the 'format' field is required"))),
      );
      expect(
        one(MessageInputPart.imageUrl('https://example.com/a.png'))['content'],
        [
          {
            'type': 'image_url',
            'image_url': {'url': 'https://example.com/a.png'},
          },
        ],
      );
    });

    test('mp3 MIME types become the mp3 format (Go swaps them; intended)', () {
      final wire = _wire(
        Message(
          role: RoleType.user,
          userInputMultiContent: [
            MessageInputPart.audio(base64Data: 'AAA', mimeType: 'audio/mpeg'),
            MessageInputPart.audio(base64Data: 'BBB', mimeType: 'audio/x-wav'),
          ],
        ),
      );
      final parts = wire['content'] as List;
      expect(((parts[0] as Map)['input_audio'] as Map)['format'], 'mp3');
      expect(((parts[1] as Map)['input_audio'] as Map)['format'], 'wav');
    });
  });

  group('Test_newStreamMessageBuilder', () {
    test('keeps the audio format', () {
      expect(
        const OpenAICompatibleResponseParser(audioFormat: 'mp3').audioFormat,
        'mp3',
      );
    });
  });

  group('Test_streamMessageBuilder_setOutputMessageAudio', () {
    test('an audio delta becomes an audio part with id and transcript', () {
      final message = const OpenAICompatibleResponseParser(audioFormat: 'mp3')
          .parseStreamChunk(
        _chunk({
          'audio': {
            'id': 'audio-id',
            'data': 'audio-data',
            'transcript': 'audio-transcript',
          },
        }),
      )!;
      final parts = message.assistantGenMultiContent!;
      expect(parts, hasLength(1));
      expect(parts.single.type, ChatMessagePartType.audioUrl);
      expect(parts.single.audio, isNotNull);
      expect(parts.single.extra![openAIGeneratedAudioIdKey], 'audio-id');
      expect(parts.single.audio!.base64Data, 'audio-data');
      expect(parts.single.audio!.mimeType, 'audio/mpeg');
      expect(parts.single.extra![openAIAudioTranscriptKey], 'audio-transcript');
    });

    test('a later audio delta without an id still belongs to that audio',
        () async {
      // Go's builder remembers the id of the first delta (b.audioID) and
      // gives it to every later part; after concatenation the part has it.
      final model = OpenAIChatModel(
        config: _config.copyWith(
          modalities: const [OpenAIModality.text, OpenAIModality.audio],
          audio: const OpenAIAudioConfig(format: 'mp3', voice: 'alloy'),
        ),
        httpClient: _FakeApi().sse([
          _data(_chunk({'role': 'assistant', 'audio': {'id': 'audio-id', 'data': 'AAAA'}})),
          _data(_chunk({'audio': {'data': 'BBBB'}})),
          _data(_chunk({}, finish: 'stop')),
          _done,
        ]),
      );
      final reader = await model.stream([Message.user('speak')]);
      final message = concatMessages(await reader.collectAll());
      final audio = message.assistantGenMultiContent!
          .where((p) => p.type == ChatMessagePartType.audioUrl && p.audio?.base64Data != null)
          .single;
      expect(audio.audio!.base64Data, 'AAAABBBB');
      expect(audio.extra![openAIGeneratedAudioIdKey], 'audio-id');
    });

    test('audio data without an audio config is an error', () {
      expect(
        () => _parser.parseStreamChunk(_chunk({'audio': {'id': 'a', 'data': 'x'}})),
        throwsA(isA<ThreepioFormatException>().having((e) => e.message,
            'message', 'audio config must be set when audio data is present')),
      );
      expect(
        () => const OpenAICompatibleResponseParser(audioFormat: 'aac')
            .parseStreamChunk(_chunk({'audio': {'id': 'a', 'data': 'x'}})),
        throwsA(isA<ThreepioFormatException>().having((e) => e.message,
            'message', 'audio mime type not found for config audio format aac')),
      );
    });
  });

  group('Test_streamMessageBuilder_build', () {
    test('builds the message of choice 0', () {
      final message = const OpenAICompatibleResponseParser(audioFormat: 'mp3')
          .parseStreamChunk(
        _chunk({
          'role': 'assistant',
          'content': 'hello',
          'audio': {'id': 'audio-id', 'data': 'audio-data'},
        }),
      )!;
      expect(message.role, RoleType.assistant);
      expect(message.content, 'hello');
      expect(message.assistantGenMultiContent, hasLength(1));
    });

    test('other choices are skipped; a usage-only chunk is found', () {
      expect(
        _parser.parseStreamChunk({
          'choices': [
            {'index': 1, 'delta': {'content': 'skip'}},
          ],
        }),
        isNull,
      );
      final usage = _parser.parseStreamChunk({
        'choices': <Object?>[],
        'usage': {'prompt_tokens': 1, 'completion_tokens': 2, 'total_tokens': 3},
      })!;
      expect(usage.responseMeta!.usage!.totalTokens, 3);
      expect(usage.content, '');
    });
  });

  group('Test_genRequest', () {
    test('basic request', () async {
      final input = [Message.user('hello')];
      expect(_build(input), {
        'model': 'test-model',
        'messages': [
          {'role': 'user', 'content': 'hello'},
        ],
        'stream': false,
      });

      final api = _FakeApi();
      final recorder = _Recorder();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: api.json(_completion({'role': 'assistant', 'content': 'ok'})),
      );
      await model.generate(
        input,
        options: ChatModelOptions(
          runContext: RunContext.background().withHandlers([recorder]),
        ),
      );
      expect(recorder.input!.config!.model, 'test-model');
      expect(recorder.input!.messages, same(input));
      // No request option: only the content type and the key.
      expect(
        api.sent.single.headers.keys.map((k) => k.toLowerCase()).toSet(),
        {'content-type', 'authorization'},
      );
    });

    test('multi-content conflict error', () {
      expect(
        () => _build([
          const Message(
            role: RoleType.user,
            userInputMultiContent: [
              MessageInputPart(type: ChatMessagePartType.text, text: 'hi'),
            ],
            assistantGenMultiContent: [
              MessageOutputPart(type: ChatMessagePartType.text, text: 'out'),
            ],
          ),
        ]),
        throwsArgumentError,
      );
    });

    test('payload modifier and extra header options', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: api.json(_completion({'role': 'assistant', 'content': 'ok'})),
      );
      var calls = 0;
      await model.generate(
        [Message.user('hello')],
        options: OpenAIRequestOptions(
          requestPayloadModifier: (ctx, messages, body) {
            calls++;
            return body;
          },
          extraHeaders: const {'x-test': 'y'},
        ).toOptions(),
      );
      expect(calls, 1);
      expect(api.sent.single.headers['x-test'], 'y');
    });

    test('config custom headers', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config.copyWith(customHeaders: const {'x-test': 'y'}),
        httpClient: api.json(_completion({'role': 'assistant', 'content': 'ok'})),
      );
      await model.generate([Message.user('hello')]);
      expect(api.sent.single.headers['x-test'], 'y');
    });

    test('request extra fields replace defaults without mutating inputs', () {
      final defaultExtraFields = <String, Object?>{'default': 'value'};
      final requestExtraFields = <String, Object?>{'request': 'value'};
      final settings = OpenAIChatSettings(
        model: 'test-model',
        extraFields: defaultExtraFields,
        modalities: const [OpenAIModality.text],
      );
      final input = [Message.user('hello')];

      final first = _build(
        input,
        settings: settings,
        requestOptions: OpenAIRequestOptions(extraFields: requestExtraFields),
      );
      expect(first['request'], 'value');
      expect(first['modalities'], ['text']);
      expect(first.containsKey('default'), isFalse);
      expect(defaultExtraFields, {'default': 'value'});
      expect(requestExtraFields, {'request': 'value'});

      final second = _build(input, settings: settings);
      expect(second['default'], 'value');
      expect(second['modalities'], ['text']);
      expect(second.containsKey('request'), isFalse);
      expect(defaultExtraFields, {'default': 'value'});
    });

    test('forced tool choice without tools returns error', () {
      expect(
        () => _build(
          [Message.user('hello')],
          options: const ChatModelOptions(toolChoice: ToolChoice.forced),
        ),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'tool_choice is forced but no tools are provided')),
      );
    });

    test('forced tool choice with multiple tools becomes required', () {
      final body = _build(
        [Message.user('hello')],
        options: ChatModelOptions(
          tools: [_tool('tool1'), _tool('tool2')],
          toolChoice: ToolChoice.forced,
        ),
      );
      expect(body['tools'] as List, hasLength(2));
      expect(body['tool_choice'], 'required');
    });

    test('modalities audio requires audio config', () {
      expect(
        () => _build(
          [Message.user('hello')],
          settings: const OpenAIChatSettings(
            model: 'test-model',
            modalities: [OpenAIModality.audio],
          ),
        ),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            "audio configuration is mandatory when 'audio' modality is specified")),
      );
    });

    test('modalities audio with config populates extra fields', () {
      final body = _build(
        [Message.user('hello')],
        settings: const OpenAIChatSettings(
          model: 'test-model',
          modalities: [OpenAIModality.audio],
          audio: OpenAIAudioConfig(format: 'mp3', voice: 'alloy'),
        ),
      );
      expect(body['modalities'], ['audio']);
      expect(body['audio'], {'format': 'mp3', 'voice': 'alloy'});
    });

    test('response format mapping', () {
      // threepio's ResponseFormat has no `text` form (Go's test uses
      // `text`); the mapping is the same for json_object.
      final body = _build(
        [Message.user('hello')],
        settings: const OpenAIChatSettings(
          model: 'test-model',
          responseFormat: ResponseFormat.jsonObject(),
        ),
      );
      expect(body['response_format'], {'type': 'json_object'});
    });

    test('request payload modifier wiring', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: api.json(_completion({'role': 'assistant', 'content': 'ok'})),
      );
      final input = [Message.user('hello')];
      await model.generate(
        input,
        options: OpenAIRequestOptions(
          requestPayloadModifier: (ctx, messages, body) {
            expect(messages, same(input));
            return {...body, 'x': 'appended'};
          },
        ).toOptions(),
      );
      expect(api.body['x'], 'appended');
      expect(api.body['model'], 'test-model');
    });

    test('response message modifier wiring', () async {
      final model = OpenAIChatModel(
        config: _config,
        httpClient: _FakeApi().json(_completion({'role': 'assistant', 'content': 'resp'})),
      );
      final out = await model.generate(
        [Message.user('hello')],
        options: OpenAIRequestOptions(
          responseMessageModifier: (ctx, message, raw) => Message(
            role: message.role,
            name: message.name,
            content: '${message.content}|mod',
            toolCallId: message.toolCallId,
            toolCalls: message.toolCalls,
            responseMeta: message.responseMeta,
          ),
        ).toOptions(),
      );
      expect(out.content, 'resp|mod');
      expect(out.role, RoleType.assistant);
    });
  });

  group('TestPopulateToolChoice', () {
    Object choice(
      ToolChoice toolChoice, {
      List<String> allowed = const [],
      List<String> tools = const [],
    }) =>
        openAIToolChoice(toolChoice, allowedToolNames: allowed, toolNames: tools);

    test('nil tool choice', () {
      final body = _build(
        [Message.user('x')],
        options: ChatModelOptions(tools: [_tool('t')]),
      );
      expect(body.containsKey('tool_choice'), isFalse);
    });

    test('tool choice forbidden', () {
      expect(choice(ToolChoice.forbidden), 'none');
    });

    test('tool choice allowed', () {
      expect(choice(ToolChoice.allowed), 'auto');
    });

    test('tool choice allowed with allowed tools', () {
      final result =
          choice(ToolChoice.allowed, allowed: ['test-tool'], tools: ['test-tool']);
      expect((result as Map)['allowed_tools'], {
        'mode': 'auto',
        'tools': [
          {
            'type': 'function',
            'function': {'name': 'test-tool'},
          },
        ],
      });
      expect(result['type'], 'allowed_tools');
    });

    test('tool choice allowed with invalid allowed tool', () {
      expect(
        () => choice(ToolChoice.allowed, allowed: ['invalid-tool'], tools: ['test-tool']),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'allowed tool invalid-tool not found in request tools')),
      );
    });

    test('tool choice forced with no tools', () {
      expect(
        () => choice(ToolChoice.forced),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'tool_choice is forced but no tools are provided')),
      );
    });

    test('tool choice forced with one tool', () {
      expect(choice(ToolChoice.forced, tools: ['test-tool']), {
        'type': 'function',
        'function': {'name': 'test-tool'},
      });
    });

    test('tool choice forced with multiple tools', () {
      expect(
        choice(ToolChoice.forced, tools: ['test-tool-1', 'test-tool-2']),
        'required',
      );
    });

    test('tool choice forced with allowed tools', () {
      expect(
        choice(
          ToolChoice.forced,
          allowed: ['test-tool-1'],
          tools: ['test-tool-1', 'test-tool-2'],
        ),
        {
          'type': 'function',
          'function': {'name': 'test-tool-1'},
        },
      );
    });

    test('tool choice forced with several allowed tools (Go source)', () {
      expect(
        choice(
          ToolChoice.forced,
          allowed: ['test-tool-1', 'test-tool-2'],
          tools: ['test-tool-1', 'test-tool-2', 'test-tool-3'],
        ),
        {
          'type': 'allowed_tools',
          'allowed_tools': {
            'mode': 'required',
            'tools': [
              {
                'type': 'function',
                'function': {'name': 'test-tool-1'},
              },
              {
                'type': 'function',
                'function': {'name': 'test-tool-2'},
              },
            ],
          },
        },
      );
    });

    test('tool choice forced with invalid allowed tool', () {
      expect(
        () => choice(ToolChoice.forced, allowed: ['invalid-tool'], tools: ['test-tool']),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'allowed tool invalid-tool not found in request tools')),
      );
    });

    test('allowed_tools set without tools', () {
      expect(
        () => choice(ToolChoice.forced, allowed: ['test-tool']),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message',
            'tool_choice is forced but no tools are provided')),
      );
    });

    test('the request carries the choice', () {
      final body = _build(
        [Message.user('x')],
        options: ChatModelOptions(
          tools: [_tool('a'), _tool('b')],
          toolChoice: ToolChoice.allowed,
          allowedToolNames: const ['b'],
        ),
      );
      expect((body['tool_choice']! as Map)['type'], 'allowed_tools');
    });
  });

  group('Test_OpenAIOptions_Setters', () {
    test('WithExtraFields', () {
      final fields = <String, Object?>{'a': 1, 'b': 'x'};
      final options = OpenAIRequestOptions(extraFields: fields).toOptions();
      expect(options.extension<OpenAIRequestOptions>()!.extraFields, fields);
    });

    test('WithExtraFields replaces previous fields', () {
      const first = OpenAIRequestOptions(extraFields: {'a': 1});
      const last = OpenAIRequestOptions(extraFields: {'b': 2});
      final options = const ChatModelOptions(extensions: [first])
          .merge(const ChatModelOptions(extensions: [last]));
      expect(options.extension<OpenAIRequestOptions>()!.extraFields, {'b': 2});
    });

    test('WithReasoningEffort', () {
      final options =
          const OpenAIRequestOptions(reasoningEffort: ReasoningEffort.high).toOptions();
      expect(
        options.extension<OpenAIRequestOptions>()!.reasoningEffort,
        ReasoningEffort.high,
      );
      expect(
        _build([Message.user('x')], requestOptions: options.extension())['reasoning_effort'],
        'high',
      );
    });

    test('WithRequestPayloadModifier', () {
      final options = OpenAIRequestOptions(
        requestPayloadModifier: (ctx, messages, body) => {...body, 'x': true},
      ).toOptions();
      final modifier =
          options.extension<OpenAIRequestOptions>()!.requestPayloadModifier!;
      expect(
        modifier(null, [Message.user('')], {'body': 1}),
        {'body': 1, 'x': true},
      );
    });

    test('WithResponseMessageModifier', () {
      final options = OpenAIRequestOptions(
        responseMessageModifier: (ctx, message, raw) => Message(
          role: message.role,
          content: '${message.content}|m',
        ),
      ).toOptions();
      final modifier =
          options.extension<OpenAIRequestOptions>()!.responseMessageModifier!;
      final out = modifier(null, Message.assistant('resp'), const {'raw': 1});
      expect(out.content, 'resp|m');
      expect(out.role, RoleType.assistant);
    });

    test('WithResponseChunkMessageModifier', () {
      final options = OpenAIRequestOptions(
        responseChunkMessageModifier: (ctx, message, raw, {required end}) {
          if (end) return message;
          return Message(role: message!.role, content: '${message.content}|chunk');
        },
      ).toOptions();
      final modifier =
          options.extension<OpenAIRequestOptions>()!.responseChunkMessageModifier!;
      expect(
        modifier(null, Message.assistant('resp'), const {}, end: false)!.content,
        'resp|chunk',
      );
      expect(
        modifier(null, Message.assistant('resp'), const {}, end: true)!.content,
        'resp',
      );
    });

    test('WithExtraHeader', () {
      final options =
          const OpenAIRequestOptions(extraHeaders: {'x': '1'}).toOptions();
      expect(options.extension<OpenAIRequestOptions>()!.extraHeaders, {'x': '1'});
    });

    test('WithMaxCompletionTokens', () {
      final options =
          const OpenAIRequestOptions(maxCompletionTokens: 123).toOptions();
      expect(options.extension<OpenAIRequestOptions>()!.maxCompletionTokens, 123);
      expect(
        _build([Message.user('x')], requestOptions: options.extension())['max_completion_tokens'],
        123,
      );
    });

    test('toOptions carries the common options too', () {
      final options = const OpenAIRequestOptions().toOptions(
        model: 'm',
        temperature: 0.5,
        maxTokens: 9,
        topP: 0.1,
        stop: ['s'],
      );
      expect(
        [options.model, options.temperature, options.maxTokens, options.topP, options.stop],
        ['m', 0.5, 9, 0.1, ['s']],
      );
    });
  });

  group('TestConcatMessages', () {
    test('extra values and the reasoning are joined', () {
      final message = concatMessages(const [
        Message(
          role: RoleType.assistant,
          reasoningContent: 'how ',
          extra: {'key_of_string': 'hi!', 'key_of_int': 10},
        ),
        Message(
          role: RoleType.assistant,
          reasoningContent: 'are you',
          extra: {'key_of_string': 'hello!', 'key_of_int': 50},
        ),
      ]);
      expect(message.extra!['key_of_string'], 'hi!hello!');
      expect(message.extra!['key_of_int'], 50);
      expect(message.reasoningContent, 'how are you');
    });
  });

  group('TestSetGetRequestID', () {
    test('the response id is kept under openai-request-id', () {
      final message = _parser.parseCompletionResponse(
        _completion({'role': 'assistant', 'content': 'x'}, id: 'req-123'),
      );
      expect(message.extra![openAIRequestIdKey], 'req-123');
      expect(openAIRequestIdKey, 'openai-request-id');
    });

    test('a response without an id has no request id', () {
      final message = _parser.parseCompletionResponse(
        _completion({'role': 'assistant', 'content': 'x'}, id: null),
      );
      expect(message.extra, isNull);
    });
  });

  group('TestPopulateRCFromExtra', () {
    final cases = <String, (Object? value, String? wantRC, bool present)>{
      'normal string value': ('thinking step by step', 'thinking step by step', true),
      'null value': (null, null, true),
      'empty string value': ('', null, true),
      'non-string json type': ({'key': 'val'}, null, true),
      'key not present': (null, null, false),
    };

    for (final MapEntry(key: name, value: (value, wantRC, present)) in cases.entries) {
      test(name, () {
        final message = {
          'role': 'assistant',
          'content': 'x',
          if (present) 'reasoning': value,
          if (!present) 'other': 'value',
        };
        expect(
          _parser.parseCompletionResponse(_completion(message)).reasoningContent,
          wantRC,
        );
        expect(_parser.parseStreamChunk(_chunk(message))!.reasoningContent, wantRC);
      });
    }

    test('nil extra', () {
      expect(
        _parser
            .parseCompletionResponse(_completion({'role': 'assistant', 'content': 'x'}))
            .reasoningContent,
        isNull,
      );
    });

    test('reasoning_content wins over reasoning', () {
      final message = {
        'role': 'assistant',
        'content': 'x',
        'reasoning_content': 'first',
        'reasoning': 'second',
      };
      expect(
        _parser.parseCompletionResponse(_completion(message)).reasoningContent,
        'first',
      );
    });
  });

  group('buildGenerateResponse', () {
    test('the choice with index 0 is the message', () {
      final message = _parser.parseCompletionResponse({
        'id': 'x',
        'choices': [
          {'index': 1, 'message': {'role': 'assistant', 'content': 'one'}},
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': 'zero', 'name': 'n'},
            'finish_reason': 'length',
            'logprobs': {'content': <Object?>[]},
          },
        ],
      });
      expect(message.content, 'zero');
      expect(message.name, 'n');
      expect(message.responseMeta!.finishReason, 'length');
      expect(message.responseMeta!.logProbs, const LogProbs());
    });

    test('empty choices and a missing choice 0 are errors with Go\'s texts',
        () {
      expect(
        () => _parser.parseCompletionResponse({'choices': <Object?>[]}),
        throwsA(isA<ThreepioFormatException>().having((e) => e.message,
            'message', 'received empty choices from OpenAI API response')),
      );
      expect(
        () => _parser.parseCompletionResponse(
          _completion({'role': 'assistant', 'content': 'x'}, index: 2),
        ),
        throwsA(isA<ThreepioFormatException>().having((e) => e.message,
            'message', 'invalid response format: choice with index 0 not found')),
      );
    });

    test('generated audio needs an id', () {
      expect(
        () => const OpenAICompatibleResponseParser(audioFormat: 'wav')
            .parseCompletionResponse(
          _completion({
            'role': 'assistant',
            'content': null,
            'audio': {'data': 'UklG', 'transcript': 'hi'},
          }),
        ),
        throwsA(isA<ThreepioFormatException>().having((e) => e.message,
            'message', contains('missing audio ID'))),
      );
    });
  });
}
