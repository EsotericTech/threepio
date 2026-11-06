// Tests written for the port of eino-ext's `gemini` chat model (no Go
// counterpart): the request body built from `GeminiConfig`,
// `GeminiRequestOptions` and the messages; thought signatures round-tripping
// through the model; server tool results; SSE edge cases; cancellation
// before and during a call and mid-stream; error classification; callbacks;
// `withTools` sharing the client; `dispose`; `createPrefixCache`; the value
// types. HTTP is faked with `MockClient`; the fixtures are Gemini REST JSON.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_converters.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_message_extras.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_options.dart';
import 'package:threepio_core/src/components/model/providers/gemini/gemini_response_parser.dart';
import 'package:threepio_core/threepio_core.dart';

const _config = GeminiConfig(apiKey: 'test-key', defaultModel: 'gemini-test');

Map<String, Object?> _response(
  List<Map<String, Object?>> parts, {
  String? finishReason,
  Map<String, Object?>? usage,
  Map<String, Object?>? candidateFields,
}) =>
    {
      'candidates': [
        {
          'content': {'role': 'model', 'parts': parts},
          if (finishReason != null) 'finishReason': finishReason,
          ...?candidateFields,
        },
      ],
      if (usage != null) 'usageMetadata': usage,
    };

String _sse(Map<String, Object?> json) => 'data: ${jsonEncode(json)}\n\n';

String _b64(String text) => base64Encode(utf8.encode(text));

/// A model answering every request with [respond]; requests are recorded.
({GeminiChatModel model, List<http.Request> requests}) _jsonModel(
  Object? Function(http.Request request) respond, {
  GeminiConfig config = _config,
  int status = 200,
}) {
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    final answer = respond(request);
    return http.Response(
      answer is String ? answer : jsonEncode(answer),
      status,
      headers: {'content-type': 'application/json'},
    );
  });
  return (
    model: GeminiChatModel(config: config, httpClient: client),
    requests: requests,
  );
}

/// A model that streams [chunks] (each a piece of the body as it arrives).
({GeminiChatModel model, List<Map<String, dynamic>> bodies}) _sseModel(
  List<String> chunks, {
  GeminiConfig config = _config,
  int status = 200,
}) {
  final bodies = <Map<String, dynamic>>[];
  final client = MockClient.streaming((request, bodyStream) async {
    bodies.add(jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>);
    return http.StreamedResponse(
      Stream.fromIterable([for (final chunk in chunks) utf8.encode(chunk)]),
      status,
    );
  });
  return (
    model: GeminiChatModel(config: config, httpClient: client),
    bodies: bodies,
  );
}

Map<String, dynamic> _body(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

Future<List<Message>> _collect(StreamReader<Message> reader) async {
  try {
    return await reader.collectAll();
  } finally {
    await reader.close();
  }
}

final _ok = _response([
  {'text': 'ok'},
], finishReason: 'STOP');

/// Records every callback with its payload.
final class _Recorder extends ComponentCallbackHandler {
  final List<String> timings = [];
  final List<RunInfo> infos = [];
  ModelCallbackInput? input;
  ModelCallbackOutput? output;
  Object? error;
  final List<ModelCallbackOutput?> chunks = [];
  final Completer<void> streamDone = Completer<void>();

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    timings.add('start');
    infos.add(info);
    this.input = ModelCallbackInput.from(input);
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    timings.add('end');
    this.output = ModelCallbackOutput.from(output);
    return ctx;
  }

  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    timings.add('error');
    this.error = error;
    return ctx;
  }

  @override
  RunContext onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) {
    timings.add('endStream');
    unawaited(() async {
      try {
        for (final chunk in await output.collectAll()) {
          chunks.add(ModelCallbackOutput.from(chunk));
        }
      } on Object catch (error) {
        this.error = error;
      } finally {
        await output.close();
        streamDone.complete();
      }
    }());
    return ctx;
  }
}

ChatModelOptions _with(ComponentCallbackHandler handler, {List<Object> extensions = const []}) =>
    ChatModelOptions(
      runContext: RunContext.background().withHandlers([handler]),
      extensions: extensions,
    );

/// A client that forwards to [inner] and records whether it was closed.
final class _TrackingClient extends http.BaseClient {
  _TrackingClient(this.inner);
  final http.Client inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => inner.send(request);

  @override
  void close() => closed = true;
}

void main() {
  setUp(GlobalCallbacks.clear);

  group('request body', () {
    test('carries every knob of GeminiConfig', () async {
      final fake = _jsonModel(
        (_) => _ok,
        config: GeminiConfig(
          apiKey: 'test-key',
          defaultModel: 'gemini-test',
          maxTokens: 64,
          temperature: 0.3,
          topP: 0.8,
          topK: 20,
          responseJsonSchema: const {'type': 'object'},
          enableCodeExecution: true,
          enableGoogleSearch: GeminiGoogleSearch(
            timeRangeFilter: GeminiInterval(
              startTime: DateTime.utc(2026, 1, 1),
              endTime: DateTime.utc(2026, 2, 1),
            ),
          ),
          enableGoogleSearchRetrieval: const GeminiGoogleSearchRetrieval(
            dynamicRetrievalConfig: GeminiDynamicRetrievalConfig(
              mode: GeminiDynamicRetrievalMode.dynamicRetrieval,
              dynamicThreshold: 0.5,
            ),
          ),
          enableComputerUse: const GeminiComputerUse(
            excludedPredefinedFunctions: ['drag_and_drop'],
          ),
          enableUrlContext: const GeminiUrlContext(),
          enableFileSearch: const GeminiFileSearch(
            fileSearchStoreNames: ['fileSearchStores/a'],
            topK: 4,
            metadataFilter: 'lang = "en"',
          ),
          enableGoogleMaps: const GeminiGoogleMaps(enableWidget: true),
          safetySettings: const [
            GeminiSafetySetting(
              category: GeminiHarmCategory.dangerousContent,
              threshold: GeminiHarmBlockThreshold.blockOnlyHigh,
            ),
          ],
          thinkingConfig: const GeminiThinkingConfig(
            includeThoughts: true,
            thinkingBudget: 0,
          ),
          imageConfig: const GeminiImageConfig(aspectRatio: '16:9', imageSize: '2K'),
          responseModalities: const [
            GeminiResponseModality.text,
            GeminiResponseModality.image,
          ],
          mediaResolution: GeminiMediaResolution.low,
          responseLogprobs: true,
          logprobs: 2,
        ),
      );

      await fake.model.generate([Message.user('hi')]);

      final body = _body(fake.requests.single);
      expect(body['generationConfig'], {
        'temperature': 0.3,
        'maxOutputTokens': 64,
        'topP': 0.8,
        'topK': 20,
        'responseMimeType': 'application/json',
        'responseJsonSchema': {'type': 'object'},
        'responseModalities': ['TEXT', 'IMAGE'],
        'mediaResolution': 'MEDIA_RESOLUTION_LOW',
        'thinkingConfig': {'includeThoughts': true, 'thinkingBudget': 0},
        'imageConfig': {'aspectRatio': '16:9', 'imageSize': '2K'},
        'responseLogprobs': true,
        'logprobs': 2,
      });
      expect(body['tools'], [
        {'codeExecution': <String, Object?>{}},
        {
          'googleSearch': {
            'timeRangeFilter': {
              'startTime': '2026-01-01T00:00:00.000Z',
              'endTime': '2026-02-01T00:00:00.000Z',
            },
          },
        },
        {
          'googleSearchRetrieval': {
            'dynamicRetrievalConfig': {
              'mode': 'MODE_DYNAMIC',
              'dynamicThreshold': 0.5,
            },
          },
        },
        {
          'computerUse': {
            'environment': 'ENVIRONMENT_BROWSER',
            'excludedPredefinedFunctions': ['drag_and_drop'],
          },
        },
        {'urlContext': <String, Object?>{}},
        {
          'fileSearch': {
            'fileSearchStoreNames': ['fileSearchStores/a'],
            'topK': 4,
            'metadataFilter': 'lang = "en"',
          },
        },
        {
          'googleMaps': {'enableWidget': true},
        },
      ]);
      expect(body['safetySettings'], [
        {
          'category': 'HARM_CATEGORY_DANGEROUS_CONTENT',
          'threshold': 'BLOCK_ONLY_HIGH',
        },
      ]);
      expect(body.containsKey('toolConfig'), isFalse);
    });

    test('a default config adds nothing to the body', () async {
      final fake = _jsonModel((_) => _ok);
      await fake.model.generate([Message.user('hi')]);
      expect(_body(fake.requests.single).keys, ['contents']);
      expect(fake.requests.single.url.path, '/v1beta/models/gemini-test:generateContent');
    });

    test('the options of a call win over the config', () async {
      final fake = _jsonModel(
        (_) => _ok,
        config: _config.copyWith(
          temperature: 0.3,
          maxTokens: 64,
          topK: 20,
          thinkingConfig: const GeminiThinkingConfig(thinkingBudget: 100),
          responseModalities: const [GeminiResponseModality.text],
          imageConfig: const GeminiImageConfig(aspectRatio: '1:1'),
          responseJsonSchema: const {'type': 'object'},
        ),
      );

      await fake.model.generate(
        [Message.user('hi')],
        options: GeminiRequestOptions(
          topK: 5,
          thinkingConfig: const GeminiThinkingConfig(
            thinkingLevel: GeminiThinkingLevel.high,
          ),
          responseModalities: const [GeminiResponseModality.audio],
          imageConfig: const GeminiImageConfig(imageSize: '4K'),
          responseJsonSchema: const {'type': 'string'},
        ).toOptions(temperature: 0.9, model: 'models/gemini-other'),
      );

      final request = fake.requests.single;
      expect(request.url.path, '/v1beta/models/gemini-other:generateContent');
      final generationConfig = _body(request)['generationConfig'] as Map;
      expect(generationConfig['temperature'], 0.9);
      expect(generationConfig['maxOutputTokens'], 64);
      expect(generationConfig['topK'], 5);
      expect(generationConfig['thinkingConfig'], {'thinkingLevel': 'HIGH'});
      expect(generationConfig['responseModalities'], ['AUDIO']);
      expect(generationConfig['imageConfig'], {'imageSize': '4K'});
      expect(generationConfig['responseJsonSchema'], {'type': 'string'});
    });

    test('the older extra keys still work, and typed options win over them',
        () async {
      final fake = _jsonModel(
        (_) => _ok,
        config: _config.copyWith(
          topK: 1,
          safetySettings: const [
            GeminiSafetySetting(
              category: GeminiHarmCategory.harassment,
              threshold: GeminiHarmBlockThreshold.off,
            ),
          ],
        ),
      );
      const extra = {
        'topK': 7,
        'candidateCount': 2,
        'responseMimeType': 'text/x.enum',
        'responseSchema': {'type': 'STRING'},
        'responseModalities': ['IMAGE'],
        'safetySettings': [
          {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'BLOCK_NONE'},
        ],
      };

      await fake.model.generate(
        [Message.user('a')],
        options: const ChatModelOptions(extra: extra),
      );
      await fake.model.generate(
        [Message.user('b')],
        options: GeminiRequestOptions(
          topK: 9,
          responseModalities: const [GeminiResponseModality.text],
        ).applyTo(const ChatModelOptions(extra: extra)),
      );

      final legacy = _body(fake.requests[0]);
      expect(legacy['generationConfig'], {
        'topK': 7,
        'candidateCount': 2,
        'responseMimeType': 'text/x.enum',
        'responseSchema': {'type': 'STRING'},
        'responseModalities': ['IMAGE'],
      });
      expect(legacy['safetySettings'], extra['safetySettings']);
      final typed = _body(fake.requests[1])['generationConfig'] as Map;
      expect(typed['topK'], 9);
      expect(typed['responseModalities'], ['TEXT']);
    });

    test('tool choice: bound tools are allowed, names restrict the choice',
        () async {
      final fake = _jsonModel((_) => _ok);
      final tools = [
        ToolInfo.simple(name: 'a', description: 'A', properties: {}),
        ToolInfo.simple(name: 'b', description: 'B', properties: {}),
      ];
      final bound = fake.model.withTools(tools);

      await bound.generate([Message.user('1')]);
      await bound.generate(
        [Message.user('2')],
        options: const ChatModelOptions(allowedToolNames: ['b']),
      );
      await bound.generate(
        [Message.user('3')],
        options: const ChatModelOptions(
          toolChoice: ToolChoice.forced,
          allowedToolNames: ['a'],
        ),
      );
      await bound.generate(
        [Message.user('4')],
        options: const ChatModelOptions(toolChoice: ToolChoice.forbidden),
      );
      // Without function declarations no function calling config is sent:
      // the API rejects one.
      await fake.model.generate(
        [Message.user('5')],
        options: const ChatModelOptions(toolChoice: ToolChoice.forbidden),
      );
      await bound.generate(
        [Message.user('6')],
        options: const ChatModelOptions(tools: []),
      );

      List<Object?> config(int i) => [
            _body(fake.requests[i])['toolConfig']?['functionCallingConfig']?['mode'],
            _body(fake.requests[i])['toolConfig']?['functionCallingConfig']
                ?['allowedFunctionNames'],
          ];
      expect(config(0), ['AUTO', null]);
      expect(config(1), ['VALIDATED', ['b']]);
      expect(config(2), ['ANY', ['a']]);
      expect(config(3), ['NONE', null]);
      expect(_body(fake.requests[4]).containsKey('toolConfig'), isFalse);
      expect(_body(fake.requests[5]).containsKey('toolConfig'), isFalse);
      expect(_body(fake.requests[5]).containsKey('tools'), isFalse);
      expect(
        (_body(fake.requests[0])['tools'] as List).single['functionDeclarations'],
        hasLength(2),
      );

      await expectLater(
        fake.model.generate(
          [Message.user('7')],
          options: const ChatModelOptions(toolChoice: ToolChoice.forced),
        ),
        throwsArgumentError,
      );
      await expectLater(
        bound.generate(
          [Message.user('8')],
          options: const ChatModelOptions(
            toolChoice: ToolChoice.allowed,
            allowedToolNames: ['missing'],
          ),
        ),
        throwsArgumentError,
      );
      expect(fake.requests, hasLength(6));
    });

    test('without an API key no key header is sent', () async {
      final fake = _jsonModel(
        (_) => _ok,
        config: const GeminiConfig(apiKey: ''),
      );
      await fake.model.generate(
        [Message.user('q')],
        options: GeminiRequestOptions(
          customHeaders: {'Authorization': 'Bearer token'},
        ).toOptions(),
      );
      final headers = fake.requests.single.headers;
      expect(headers.containsKey('x-goog-api-key'), isFalse);
      expect(headers['authorization'], 'Bearer token');
    });

    test('tool results that follow each other are merged into one content',
        () async {
      final fake = _jsonModel((_) => _ok);
      await fake.model.generate([
        Message.user('weather in two cities?'),
        Message.assistant(
          '',
          toolCalls: const [
            ToolCall(id: '1', function: FunctionCall(name: 'w', arguments: '{"c":"A"}')),
            ToolCall(id: '2', function: FunctionCall(name: 'w', arguments: '{"c":"B"}')),
          ],
        ),
        Message.tool(content: 'sunny', toolCallId: '1', toolName: 'w'),
        Message.tool(content: 'rain', toolCallId: '2', toolName: 'w'),
      ]);

      final contents = _body(fake.requests.single)['contents'] as List;
      expect(contents, hasLength(3));
      expect(contents[2], {
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': 'w',
              'response': {'result': 'sunny'},
            },
          },
          {
            'functionResponse': {
              'name': 'w',
              'response': {'result': 'rain'},
            },
          },
        ],
      });
    });

    test('an empty input is refused', () async {
      final fake = _jsonModel((_) => _ok);
      await expectLater(fake.model.generate(const []), throwsArgumentError);
      await expectLater(fake.model.stream(const []), throwsArgumentError);
      expect(fake.requests, isEmpty);
    });
  });

  group('thinking and thought signatures', () {
    test('round trip through two calls of the model', () async {
      final sigF = _b64('function-signature');
      final sigA = _b64('answer-signature');
      final answers = [
        _response([
          {'text': 'I should look it up.', 'thought': true},
          {
            'functionCall': {
              'name': 'lookup',
              'args': {'q': 'x'},
            },
            'thoughtSignature': sigF,
          },
        ]),
        _response([
          {'text': 'The answer.', 'thoughtSignature': sigA},
        ], finishReason: 'STOP'),
        _ok,
      ];
      var call = 0;
      final fake = _jsonModel((_) => answers[call++]);
      final options = GeminiRequestOptions(
        thinkingConfig: const GeminiThinkingConfig(includeThoughts: true),
      ).toOptions();

      final history = [Message.user('q')];
      final first = await fake.model.generate(history, options: options);
      expect(first.reasoningContent, 'I should look it up.');
      expect(first.content, '');
      expect(first.toolCalls!.single.geminiThoughtSignature, utf8.encode('function-signature'));

      history
        ..add(first)
        ..add(
          Message.tool(
            content: '42',
            toolCallId: first.toolCalls!.single.id,
            toolName: 'lookup',
          ),
        );
      final second = await fake.model.generate(history, options: options);
      expect(second.content, 'The answer.');
      expect(second.geminiThoughtSignature, utf8.encode('answer-signature'));

      final secondRequest = _body(fake.requests[1]);
      expect(secondRequest['generationConfig'], {
        'thinkingConfig': {'includeThoughts': true},
      });
      expect((secondRequest['contents'] as List)[1], {
        'role': 'model',
        'parts': [
          {'text': 'I should look it up.', 'thought': true},
          {
            'functionCall': {
              'name': 'lookup',
              'args': {'q': 'x'},
            },
            'thoughtSignature': sigF,
          },
        ],
      });

      history
        ..add(second)
        ..add(Message.user('thanks'));
      await fake.model.generate(history, options: options);
      expect((_body(fake.requests[2])['contents'] as List)[3], {
        'role': 'model',
        'parts': [
          {'text': 'The answer.', 'thoughtSignature': sigA},
        ],
      });
    });

    test('a stream of thoughts, a signed call and a final usage chunk',
        () async {
      final sigF = _b64('sig-f');
      final sigT = _b64('sig-t');
      final fake = _sseModel([
        _sse(_response([
          {'text': 'Let me think', 'thought': true},
        ])),
        _sse(_response([
          {'text': ' more.', 'thought': true},
        ])),
        _sse(_response([
          {
            'functionCall': {
              'name': 'lookup',
              'args': {'q': 'x'},
            },
            'thoughtSignature': sigF,
          },
        ])),
        _sse(_response([
          {'text': 'Done'},
        ])),
        _sse(_response(
          [
            {'text': '', 'thoughtSignature': sigT},
          ],
          finishReason: 'STOP',
          usage: {
            'promptTokenCount': 3,
            'candidatesTokenCount': 4,
            'thoughtsTokenCount': 5,
            'cachedContentTokenCount': 2,
            'totalTokenCount': 12,
          },
        )),
      ]);

      final chunks = await _collect(await fake.model.stream([Message.user('q')]));

      expect(chunks, hasLength(5), reason: 'the usage chunk is kept');
      final message = concatMessages(chunks);
      expect(message.reasoningContent, 'Let me think more.');
      expect(message.content, 'Done');
      expect(message.toolCalls!.single.function.name, 'lookup');
      expect(message.toolCalls!.single.geminiThoughtSignature, utf8.encode('sig-f'));
      expect(message.geminiThoughtSignature, utf8.encode('sig-t'));
      expect(message.responseMeta!.finishReason, 'stop');
      final usage = message.responseMeta!.usage!;
      expect(usage.promptTokens, 3);
      expect(usage.completionTokens, 9);
      expect(usage.totalTokens, 12);
      expect(usage.completionTokenDetails!.reasoningTokens, 5);
      expect(usage.promptTokenDetails!.cachedTokens, 2);
    });
  });

  group('streamed thought signatures', () {
    test('several text signatures end up as one, on the final chunk',
        () async {
      final fake = _sseModel([
        _sse(_response([
          {'text': 'Hel', 'thoughtSignature': _b64('first')},
        ])),
        _sse(_response([
          {'text': 'lo', 'thoughtSignature': _b64('second')},
        ])),
        _sse(_response([
          {'text': '!'},
        ], finishReason: 'STOP')),
      ]);

      final chunks = await _collect(await fake.model.stream([Message.user('q')]));

      expect(chunks, hasLength(3));
      expect(chunks[0].extra, isNull);
      expect(chunks[1].extra, isNull);
      final message = concatMessages(chunks);
      expect(message.content, 'Hello!');
      expect(message.geminiThoughtSignature, utf8.encode('second'));
      expect(
        GeminiConverters.messageToGemini(message)['parts'],
        [
          {'text': 'Hello!', 'thoughtSignature': _b64('second')},
        ],
      );
    });

    test('a signature-only chunk without a finish reason is not sent alone',
        () async {
      final chunks = await _collect(
        await _sseModel([
          _sse(_response([
            {'text': 'a'},
          ])),
          _sse(_response([
            {'text': '', 'thoughtSignature': _b64('sig')},
          ])),
          _sse(_response([], finishReason: 'STOP')),
        ]).model.stream([Message.user('q')]),
      );
      expect(chunks, hasLength(2));
      expect(chunks.last.responseMeta!.finishReason, 'stop');
      expect(chunks.last.geminiThoughtSignature, utf8.encode('sig'));
    });
  });

  group('server tool results', () {
    test('code execution and grounding in a response', () async {
      final fake = _jsonModel(
        (_) => _response(
          [
            {'text': 'Computing. '},
            {
              'executableCode': {'language': 'PYTHON', 'code': 'print(2+2)'},
            },
            {
              'codeExecutionResult': {'outcome': 'OUTCOME_OK', 'output': '4\n'},
            },
            {'text': 'It is 4.'},
          ],
          finishReason: 'STOP',
          candidateFields: {
            'groundingMetadata': {
              'webSearchQueries': ['2+2'],
              'groundingChunks': [
                {
                  'web': {'uri': 'https://example.com', 'title': 'Example'},
                },
              ],
            },
          },
        ),
        config: _config.copyWith(
          enableCodeExecution: true,
          enableGoogleSearch: const GeminiGoogleSearch(),
        ),
      );

      final message = await fake.model.generate([Message.user('2+2?')]);

      expect(message.content, 'Computing. It is 4.');
      final [code, result] = message.assistantGenMultiContent!;
      expect(code.geminiExecutableCode!.code, 'print(2+2)');
      expect(result.geminiCodeExecutionResult!.output, '4\n');
      expect(message.geminiGroundingMetadata!['webSearchQueries'], ['2+2']);
      expect(
        (_body(fake.requests.single)['tools'] as List).map((t) => (t as Map).keys.single),
        ['codeExecution', 'googleSearch'],
      );
    });

    test('streamed code execution parts stay apart and go back in order',
        () async {
      final fake = _sseModel([
        _sse(_response([
          {'text': 'Computing.'},
        ])),
        _sse(_response([
          {
            'executableCode': {'language': 'PYTHON', 'code': 'print(2+2)'},
          },
        ])),
        _sse(_response([
          {
            'codeExecutionResult': {'outcome': 'OUTCOME_OK', 'output': '4'},
          },
        ])),
        _sse(_response([
          {'text': ' It is 4.'},
        ], finishReason: 'STOP')),
      ]);

      final message =
          concatMessages(await _collect(await fake.model.stream([Message.user('q')])));

      expect(message.content, 'Computing. It is 4.');
      final parts = message.assistantGenMultiContent!;
      expect(parts, hasLength(2));
      expect(parts[0].geminiExecutableCode!.code, 'print(2+2)');
      expect(parts[1].geminiCodeExecutionResult!.output, '4');

      final content = GeminiConverters.messageToGemini(message);
      expect(content['parts'], [
        {'text': 'Computing. It is 4.'},
        {
          'executableCode': {'language': 'PYTHON', 'code': 'print(2+2)'},
        },
        {
          'codeExecutionResult': {'outcome': 'OUTCOME_OK', 'output': '4'},
        },
      ]);
    });
  });

  group('SSE edge cases', () {
    final hello = _sse(_response([
      {'text': 'Hello'},
    ]));
    final world = _sse(_response([
      {'text': ' world'},
    ], finishReason: 'STOP'));

    Future<String> text(List<String> chunks) async =>
        (await _collect(await _sseModel(chunks).model.stream([Message.user('q')])))
            .map((m) => m.content)
            .join();

    test('lines split across chunks of the body', () async {
      final whole = hello + world;
      expect(
        await text([
          for (var i = 0; i < whole.length; i += 7)
            whole.substring(i, i + 7 > whole.length ? whole.length : i + 7),
        ]),
        'Hello world',
      );
    });

    test('comments, event names, empty data and CRLF line ends', () async {
      expect(
        await text([
          ': keep-alive\n\n',
          'event: message\n${hello.replaceAll('\n', '\r\n')}',
          'data: \n\n',
          world,
        ]),
        'Hello world',
      );
    });

    test('a last event without its blank line', () async {
      expect(await text([hello, world.trimRight()]), 'Hello world');
    });

    test('[DONE] ends the stream', () async {
      expect(await text([hello, 'data: [DONE]\n\n', world]), 'Hello');
    });

    test('a chunk without candidates keeps its usage, if it has one',
        () async {
      final chunks = await _collect(
        await _sseModel([
          hello,
          _sse({
            'usageMetadata': {
              'promptTokenCount': 1,
              'candidatesTokenCount': 2,
              'totalTokenCount': 3,
            },
          }),
          _sse(<String, Object?>{}),
          world,
        ]).model.stream([Message.user('q')]),
      );
      expect(chunks, hasLength(3));
      expect(chunks.map((m) => m.content).join(), 'Hello world');
      expect(chunks[1].content, '');
      expect(chunks[1].responseMeta!.usage!.totalTokens, 3);
    });

    test('a malformed chunk ends the stream with a format error', () async {
      final reader = await _sseModel([hello, 'data: {not json\n\n', world])
          .model
          .stream([Message.user('q')]);
      expect((await reader.recv()).content, 'Hello');
      await expectLater(reader.recv(), throwsA(isA<ThreepioFormatException>()));
      await reader.close();
    });

    test('an error event ends the stream with a classified GeminiException',
        () async {
      final reader = await _sseModel([
        hello,
        _sse({
          'error': {
            'code': 429,
            'message': 'Resource has been exhausted',
            'status': 'RESOURCE_EXHAUSTED',
          },
        }),
      ]).model.stream([Message.user('q')]);
      expect((await reader.recv()).content, 'Hello');
      await expectLater(
        reader.recv(),
        throwsA(
          isA<GeminiException>()
              .having((e) => e.code, 'code', 429)
              .having((e) => e.status, 'status', 'RESOURCE_EXHAUSTED')
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.isModelUnavailable, 'isModelUnavailable', isFalse),
        ),
      );
      await reader.close();
    });

    test('a blocked prompt ends the stream with its block reason', () async {
      final reader = await _sseModel([
        _sse({
          'promptFeedback': {'blockReason': 'SAFETY'},
        }),
      ]).model.stream([Message.user('q')]);
      await expectLater(
        reader.recv(),
        throwsA(
          isA<GeminiParseException>()
              .having((e) => e.blockReason, 'blockReason', 'SAFETY'),
        ),
      );
      await reader.close();
    });

    test('an HTTP error opening the stream is classified', () async {
      final fake = _sseModel(
        [
          jsonEncode({
            'error': {'code': 503, 'message': 'overloaded', 'status': 'UNAVAILABLE'},
          }),
        ],
        status: 503,
      );
      await expectLater(
        fake.model.stream([Message.user('q')]),
        throwsA(
          isA<GeminiException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', 'overloaded')
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        ),
      );
    });
  });

  group('cancellation', () {
    test('a cancelled token sends nothing', () async {
      final fake = _jsonModel((_) => _ok);
      final token = CancelToken()..cancel('stop');
      await expectLater(
        fake.model.generate(
          [Message.user('q')],
          options: ChatModelOptions(cancelToken: token),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(fake.requests, isEmpty);
    });

    test('cancelling while the response is awaited', () async {
      final pending = Completer<http.Response>();
      final model = GeminiChatModel(
        config: _config,
        httpClient: MockClient((_) => pending.future),
      );
      final token = CancelToken();
      final call = model.generate(
        [Message.user('q')],
        options: ChatModelOptions(
          runContext: RunContext.background(cancelToken: token),
        ),
      );
      await pumpEventQueue();
      token.cancel('user stop');
      await expectLater(
        call,
        throwsA(isA<CancelledException>().having((e) => e.reason, 'reason', 'user stop')),
      );
      pending.complete(http.Response(jsonEncode(_ok), 200));
    });

    test('cancelling mid-stream releases the body', () async {
      var released = false;
      final body = StreamController<List<int>>(onCancel: () => released = true);
      final model = GeminiChatModel(
        config: _config,
        httpClient: MockClient.streaming(
          (_, __) async => http.StreamedResponse(body.stream, 200),
        ),
      );
      final fromOptions = CancelToken();
      final fromContext = CancelToken();
      final reader = await model.stream(
        [Message.user('q')],
        options: ChatModelOptions(
          cancelToken: fromOptions,
          runContext: RunContext.background(cancelToken: fromContext),
        ),
      );
      body.add(utf8.encode(_sse(_response([
        {'text': 'partial'},
      ]))));
      expect((await reader.recv()).content, 'partial');

      fromContext.cancel('enough');

      await expectLater(reader.recv(), throwsA(isA<CancelledException>()));
      await reader.close();
      expect(released, isTrue);
      expect(fromOptions.isCancelled, isFalse, reason: 'the caller token is left alone');
      unawaited(body.close());
    });

    test('closing the reader early stops reading the body', () async {
      var released = false;
      final body = StreamController<List<int>>(onCancel: () => released = true);
      final model = GeminiChatModel(
        config: _config,
        httpClient: MockClient.streaming(
          (_, __) async => http.StreamedResponse(body.stream, 200),
        ),
      );
      final reader = await model.stream([Message.user('q')]);
      body.add(utf8.encode(_sse(_response([
        {'text': 'one'},
      ]))));
      expect((await reader.recv()).content, 'one');
      await reader.close();
      body.add(utf8.encode(_sse(_response([
        {'text': 'two'},
      ]))));
      await pumpEventQueue();
      expect(released, isTrue);
      unawaited(body.close());
    });
  });

  group('error classification', () {
    final cases = <String, (int, String, bool, bool)>{
      '429 RESOURCE_EXHAUSTED is retryable': (
        429,
        '{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED"}}',
        true,
        false,
      ),
      '500 INTERNAL is retryable': (
        500,
        '{"error":{"code":500,"message":"internal","status":"INTERNAL"}}',
        true,
        false,
      ),
      '503 UNAVAILABLE is retryable': (
        503,
        '{"error":{"code":503,"message":"overloaded","status":"UNAVAILABLE"}}',
        true,
        false,
      ),
      '404 NOT_FOUND means the model is unavailable': (
        404,
        '{"error":{"code":404,"message":"models/x is not found for API version v1beta","status":"NOT_FOUND"}}',
        false,
        true,
      ),
      '400 INVALID_ARGUMENT is neither': (
        400,
        '{"error":{"code":400,"message":"Invalid value","status":"INVALID_ARGUMENT"}}',
        false,
        false,
      ),
      'a 502 that is not JSON is retryable': (502, 'Bad Gateway', true, false),
    };
    for (final MapEntry(key: name, value: (status, body, retryable, unavailable))
        in cases.entries) {
      test(name, () async {
        final fake = _jsonModel((_) => body, status: status);
        await expectLater(
          fake.model.generate([Message.user('q')]),
          throwsA(
            isA<GeminiException>()
                .having((e) => e.statusCode, 'statusCode', status)
                .having((e) => e.isRetryable, 'isRetryable', retryable)
                .having((e) => e.isModelUnavailable, 'isModelUnavailable', unavailable),
          ),
        );
      });
    }

    test('the status alone classifies, and explicit flags win', () {
      expect(GeminiException('x', status: 'DEADLINE_EXCEEDED').isRetryable, isTrue);
      expect(GeminiException('x', code: 429).isRetryable, isTrue);
      expect(GeminiException('x', status: 'NOT_FOUND').isModelUnavailable, isTrue);
      expect(
        GeminiException('x', status: 'UNAVAILABLE', isRetryable: false).isRetryable,
        isFalse,
      );
      expect(GeminiException('x'), isA<ChatModelException>());
      expect(GeminiException('quota').isRetryable, isFalse);
    });

    test('fromHttp reads Gemini errors, plain text and empty bodies', () {
      final json = GeminiException.fromHttp(
        429,
        '{"error":{"code":429,"message":"slow down","status":"RESOURCE_EXHAUSTED"}}',
      );
      expect(json.message, 'slow down');
      expect(json.code, 429);
      expect(json.status, 'RESOURCE_EXHAUSTED');
      expect(GeminiException.fromHttp(502, 'Bad Gateway').message, 'Bad Gateway');
      expect(GeminiException.fromHttp(500, '').message, contains('500'));
    });

    test('a timeout is retryable', () async {
      final model = GeminiChatModel(
        config: _config.copyWith(timeout: const Duration(milliseconds: 20)),
        httpClient: MockClient((_) => Completer<http.Response>().future),
      );
      await expectLater(
        model.generate([Message.user('q')]),
        throwsA(
          isA<GeminiException>()
              .having((e) => e.message, 'message', contains('timed out'))
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        ),
      );
    });

    test('a transport failure is retryable and keeps its cause', () async {
      final failure = http.ClientException('connection reset');
      final model = GeminiChatModel(
        config: _config,
        httpClient: MockClient((_) async => throw failure),
      );
      await expectLater(
        model.generate([Message.user('q')]),
        throwsA(
          isA<GeminiException>()
              .having((e) => e.cause, 'cause', same(failure))
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.isModelUnavailable, 'isModelUnavailable', isFalse),
        ),
      );
      await expectLater(
        model.stream([Message.user('q')]),
        throwsA(isA<GeminiException>().having((e) => e.cause, 'cause', same(failure))),
      );
    });
  });

  group('callbacks', () {
    test('generate reports typed start and end payloads', () async {
      final recorder = _Recorder();
      final fake = _jsonModel(
        (_) => _response(
          [
            {'text': 'answer'},
          ],
          finishReason: 'STOP',
          usage: {
            'promptTokenCount': 5,
            'candidatesTokenCount': 2,
            'thoughtsTokenCount': 3,
            'totalTokenCount': 10,
          },
        ),
        config: _config.copyWith(temperature: 0.4, maxTokens: 50),
      );
      final model = fake.model.withTools([
        ToolInfo.simple(name: 't', description: 'T', properties: {}),
      ]);

      await model.generate([Message.user('q')], options: _with(recorder));

      expect(recorder.timings, ['start', 'end']);
      expect(recorder.infos.single.type, 'Gemini');
      expect(recorder.infos.single.componentType, ComponentType.chatModel);
      final input = recorder.input!;
      expect(input.messages.single.content, 'q');
      expect(input.tools!.single.name, 't');
      expect(input.toolChoice, ToolChoice.allowed);
      expect(input.config!.model, 'gemini-test');
      expect(input.config!.temperature, 0.4);
      expect(input.config!.maxTokens, 50);
      final output = recorder.output!;
      expect(output.message!.content, 'answer');
      expect(output.tokenUsage!.completionTokens, 5);
      expect(output.tokenUsage!.completionTokenDetails!.reasoningTokens, 3);
    });

    test('stream gives the handler a copy with every chunk', () async {
      final recorder = _Recorder();
      final fake = _sseModel([
        _sse(_response([
          {'text': 'a'},
        ])),
        _sse(_response([
          {'text': 'b'},
        ], finishReason: 'STOP')),
      ]);

      final chunks =
          await _collect(await fake.model.stream([Message.user('q')], options: _with(recorder)));
      await recorder.streamDone.future;

      expect(chunks.map((m) => m.content).join(), 'ab');
      expect(recorder.timings, ['start', 'endStream']);
      expect(recorder.chunks.map((c) => c!.message!.content).join(), 'ab');
    });

    test('a failed call reports the error', () async {
      final recorder = _Recorder();
      final fake = _jsonModel(
        (_) => '{"error":{"code":400,"message":"bad","status":"INVALID_ARGUMENT"}}',
        status: 400,
      );
      await expectLater(
        fake.model.generate([Message.user('q')], options: _with(recorder)),
        throwsA(isA<GeminiException>()),
      );
      expect(recorder.timings, ['start', 'error']);
      expect(recorder.error, isA<GeminiException>());
    });
  });

  group('lifecycle', () {
    test('withTools shares the client the model created', () async {
      final model = GeminiChatModel(config: _config);
      final bound = model.withTools([
        ToolInfo.simple(name: 't', description: 'T', properties: {}),
      ]);
      model.dispose();
      await expectLater(bound.generate([Message.user('q')]), throwsStateError);
      await expectLater(model.stream([Message.user('q')]), throwsStateError);
      model.dispose();
    });

    test('an injected client is used by withTools copies and never closed',
        () async {
      final client = _TrackingClient(
        MockClient((_) async => http.Response(jsonEncode(_ok), 200)),
      );
      final model = GeminiChatModel(config: _config, httpClient: client);
      final bound = model.withTools([
        ToolInfo.simple(name: 't', description: 'T', properties: {}),
      ]) as GeminiChatModel;
      expect(bound.httpClient, same(client));
      expect((await bound.generate([Message.user('q')])).content, 'ok');
      model.dispose();
      expect(client.closed, isFalse);
    });

    test('says what it is', () {
      final model = GeminiChatModel(config: _config);
      expect(model.componentTypeName, 'Gemini');
      expect(model.isCallbacksEnabled, isTrue);
    });
  });

  group('createPrefixCache', () {
    test('sends the expire time and neither headers nor extra fields', () async {
      final fake = _jsonModel(
        (_) => {
          'name': 'cachedContents/abc',
          'model': 'models/gemini-test',
          'expireTime': '2026-12-01T00:00:00Z',
          'usageMetadata': {'totalTokenCount': 4096},
        },
        config: _config.copyWith(
          cache: GeminiCacheConfig(expireTime: DateTime.utc(2026, 12)),
        ),
      );

      final cache = await fake.model.createPrefixCache(
        [Message.user('long document')],
        options: GeminiRequestOptions(
          customHeaders: {'X-Extra': '1'},
          extraFields: {'prompt_cache_key': 'k'},
        ).toOptions(),
      );

      expect(cache.name, 'cachedContents/abc');
      expect(cache.model, 'models/gemini-test');
      expect(cache.expireTime, DateTime.utc(2026, 12));
      expect(cache.totalTokenCount, 4096);
      final request = fake.requests.single;
      expect(request.headers.containsKey('x-extra'), isFalse);
      expect(_body(request), {
        'model': 'models/gemini-test',
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': 'long document'},
            ],
          },
        ],
        'expireTime': '2026-12-01T00:00:00.000Z',
      });
    });

    test('is cancellable and reports HTTP errors', () async {
      final fake = _jsonModel(
        (_) => '{"error":{"code":400,"message":"too small","status":"INVALID_ARGUMENT"}}',
        status: 400,
      );
      await expectLater(
        fake.model.createPrefixCache([Message.user('x')]),
        throwsA(isA<GeminiException>().having((e) => e.message, 'message', 'too small')),
      );
      await expectLater(
        fake.model.createPrefixCache(
          [Message.user('x')],
          options: ChatModelOptions(cancelToken: CancelToken()..cancel()),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(fake.requests, hasLength(1));
    });
  });

  group('value types', () {
    test('GeminiRequestOptions copies its collections and travels as an extension',
        () {
      final headers = {'X-A': '1'};
      final modalities = [GeminiResponseModality.text];
      final options = GeminiRequestOptions(
        customHeaders: headers,
        responseModalities: modalities,
        labels: {'team': 'x'},
      );
      headers['X-A'] = '2';
      modalities.add(GeminiResponseModality.image);
      expect(options.customHeaders, {'X-A': '1'});
      expect(options.responseModalities, [GeminiResponseModality.text]);
      expect(() => options.customHeaders!['X-B'] = '3', throwsUnsupportedError);

      final built = options.toOptions(temperature: 0.1, maxTokens: 9);
      expect(built.extension<GeminiRequestOptions>(), same(options));
      expect(built.temperature, 0.1);
      final applied = options.applyTo(
        ChatModelOptions(model: 'm', extensions: [GeminiRequestOptions(topK: 1)]),
      );
      expect(applied.extension<GeminiRequestOptions>(), same(options));
      expect(applied.model, 'm');
      expect(
        const ChatModelOptions().merge(applied).extension<GeminiRequestOptions>(),
        same(options),
      );
    });

    test('GeminiConfig keeps its defaults and copies the new fields', () {
      const config = GeminiConfig(apiKey: 'k');
      expect(config.enableCodeExecution, isFalse);
      expect(config.responseLogprobs, isFalse);
      expect(config.thinkingConfig, isNull);
      expect(config.safetySettings, isNull);
      final copy = config.copyWith(
        topK: 3,
        enableUrlContext: const GeminiUrlContext(),
        mediaResolution: GeminiMediaResolution.high,
        cache: const GeminiCacheConfig(ttl: Duration(hours: 1)),
      );
      expect(copy.apiKey, 'k');
      expect(copy.topK, 3);
      expect(copy.enableUrlContext, const GeminiUrlContext());
      expect(copy.mediaResolution, GeminiMediaResolution.high);
      expect(copy.cache, const GeminiCacheConfig(ttl: Duration(hours: 1)));
      expect(copy.copyWith().topK, 3);
    });

    test('the settings write the REST JSON', () {
      expect(const GeminiThinkingConfig().toJson(), isEmpty);
      expect(
        const GeminiThinkingConfig(
          includeThoughts: true,
          thinkingBudget: -1,
          thinkingLevel: GeminiThinkingLevel.minimal,
        ).toJson(),
        {'includeThoughts': true, 'thinkingBudget': -1, 'thinkingLevel': 'MINIMAL'},
      );
      expect(const GeminiImageConfig().toJson(), isEmpty);
      expect(const GeminiGoogleSearch().toJson(), isEmpty);
      expect(const GeminiGoogleMaps().toJson(), isEmpty);
      expect(const GeminiComputerUse().toJson(), {'environment': 'ENVIRONMENT_BROWSER'});
      expect(
        const GeminiFileSearch(fileSearchStoreNames: []).toJson(),
        isEmpty,
      );
      expect(
        const GeminiSafetySetting(
          category: GeminiHarmCategory.civicIntegrity,
          threshold: GeminiHarmBlockThreshold.blockLowAndAbove,
        ),
        const GeminiSafetySetting(
          category: GeminiHarmCategory.civicIntegrity,
          threshold: GeminiHarmBlockThreshold.blockLowAndAbove,
        ),
      );
      expect(
        [for (final m in GeminiResponseModality.values) m.wireValue],
        ['TEXT', 'IMAGE', 'AUDIO'],
      );
    });

    test('the parser still reads a response the old way', () {
      const parser = GeminiResponseParser();
      final message = parser.parseCompletionResponse(_response([
        {'text': 'x', 'thought': true},
        {'text': 'y'},
      ]));
      expect(message.reasoningContent, 'x');
      expect(message.content, 'y');
    });
  });
}
