// Port of eino-ext components/model/openai/chatmodel_test.go
// (TestOpenAIGenerate: "all param" and "stream all param"), through a fake
// HTTP server instead of mockey on go-openai, plus tests written for the
// port of the upgraded `OpenAIChatModel`: config → request body (and the
// per-call overrides), Azure routing, headers per call vs config,
// cancellation before and during a stream, error classification (429
// retryable, 404 unavailable, 400 neither), `RetryingChatModel` over it,
// callbacks, `stream_options.include_usage`, `withTools` sharing the HTTP
// client, `dispose`, log probabilities, reasoning and audio output.
//
// Adapted: Go's config `MaxTokens` is deprecated and not ported, the test
// passes `ChatModelOptions.maxTokens`; Go's image detail "detail" is not an
// `ImageURLDetail`, the test uses `auto`; the tools are compared by name,
// description and properties because `OpenAIConverters.toolInfoToOpenAI`
// adds `additionalProperties` (intended).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/model/openai_compatible/client.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_converters.dart';
import 'package:threepio_core/src/components/model/providers/openai/openai_options.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../../../support/log_capture.dart';

typedef _Sent = ({Uri url, Map<String, String> headers, Map<String, Object?> body});

final class _FakeApi {
  final sent = <_Sent>[];

  Map<String, Object?> get body => sent.last.body;

  /// Answers each request with the next of [responses] (the last repeats).
  http.Client json(List<(int, Object)> responses) {
    var i = 0;
    return MockClient((request) async {
      sent.add((
        url: request.url,
        headers: request.headers,
        body: jsonDecode(request.body) as Map<String, Object?>,
      ));
      final (status, body) = responses[i < responses.length ? i++ : responses.length - 1];
      return http.Response(
        body is String ? body : jsonEncode(body),
        status,
        headers: const {'content-type': 'application/json'},
      );
    });
  }

  http.Client ok(Object response) => json([(200, response)]);

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

/// A streamed body the test feeds line by line.
final class _LiveBody {
  _LiveBody() {
    controller = StreamController<List<int>>(
      onCancel: () async => cancelled = true,
    );
  }

  late final StreamController<List<int>> controller;
  bool cancelled = false;
  int requests = 0;

  http.Client get client => MockClient.streaming((request, bytes) async {
        requests++;
        return http.StreamedResponse(controller.stream, 200);
      });

  void add(String text) => controller.add(utf8.encode(text));
}

String _data(Object chunk) => 'data: ${jsonEncode(chunk)}\n\n';

const _done = 'data: [DONE]\n\n';

Map<String, Object?> _chunk(
  Map<String, Object?> delta, {
  String? finish,
  Map<String, Object?>? logprobs,
}) =>
    {
      'id': 'chatcmpl-1',
      'object': 'chat.completion.chunk',
      'model': 'gpt-4o-mini',
      'choices': [
        {
          'index': 0,
          'delta': delta,
          'finish_reason': finish,
          if (logprobs != null) 'logprobs': logprobs,
        },
      ],
    };

Map<String, Object?> _usageChunk(int prompt, int completion) => {
      'id': 'chatcmpl-1',
      'object': 'chat.completion.chunk',
      'choices': <Object?>[],
      'usage': {
        'prompt_tokens': prompt,
        'completion_tokens': completion,
        'total_tokens': prompt + completion,
      },
    };

Map<String, Object?> _completion(
  Map<String, Object?> message, {
  Map<String, Object?>? usage,
  Map<String, Object?>? logprobs,
}) =>
    {
      'id': 'chatcmpl-9',
      'object': 'chat.completion',
      'model': 'gpt-4o-mini',
      'choices': [
        {
          'index': 0,
          'message': message,
          'finish_reason': 'stop',
          if (logprobs != null) 'logprobs': logprobs,
        },
      ],
      'usage': usage ??
          {'prompt_tokens': 7, 'completion_tokens': 3, 'total_tokens': 10},
    };

const _config = OpenAIConfig(apiKey: 'test-key');

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
  RunContext onError(RunContext ctx, RunInfo info, Object error, StackTrace stackTrace) {
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

ChatModelOptions _with(ComponentCallbackHandler handler) => ChatModelOptions(
      runContext: RunContext.background().withHandlers([handler]),
    );

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('TestOpenAIGenerate', () {
    final js = JSONSchema(
      properties: {
        'a': const JSONSchemaProperty(type: 'string'),
        'b': const JSONSchemaProperty(type: 'integer'),
      },
    );
    final tools = [
      ToolInfo.fromJsonSchema(name: 'tool1', desc: 'tool1', schema: js),
      ToolInfo.fromJsonSchema(name: 'tool2', desc: 'tool2', schema: js),
    ];
    final config = _config.copyWith(
      defaultModel: 'gpt-4',
      maxCompletionTokens: 1,
      temperature: 0.1,
      topP: 0.2,
      stop: ['stop'],
      presencePenalty: 0.3,
      responseFormat: const ResponseFormat.jsonObject(),
      seed: 4,
      frequencyPenalty: 0.4,
      logitBias: {'1024': 100},
      user: 'megumin',
    );
    final input = [
      Message.system('system'),
      Message(
        role: RoleType.user,
        userInputMultiContent: [
          MessageInputPart.imageUrl('http://a.b.c', detail: ImageURLDetail.auto),
          MessageInputPart.text('text'),
        ],
      ),
      Message.tool(content: 'tool', toolCallId: 'tool call id'),
    ];
    final expectedRequestBody = <String, Object?>{
      'model': 'gpt-4',
      'messages': [
        {'role': 'system', 'content': 'system'},
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'http://a.b.c', 'detail': 'auto'},
            },
            {'type': 'text', 'text': 'text'},
          ],
        },
        {'role': 'tool', 'content': 'tool', 'tool_call_id': 'tool call id'},
      ],
      'stream': false,
      'max_tokens': 1,
      'max_completion_tokens': 1,
      'temperature': 0.1,
      'top_p': 0.2,
      'stop': ['stop'],
      'presence_penalty': 0.3,
      'seed': 4,
      'frequency_penalty': 0.4,
      'logit_bias': {'1024': 100},
      'user': 'megumin',
      'tool_choice': 'required',
      'response_format': {'type': 'json_object'},
    };

    void expectTools(Object? sent) {
      final list = sent! as List;
      expect(list, hasLength(2));
      for (final (i, name) in ['tool1', 'tool2'].indexed) {
        final tool = list[i] as Map;
        expect(tool['type'], 'function');
        final function = tool['function'] as Map;
        expect(function['name'], name);
        expect(function['description'], name);
        expect((function['parameters'] as Map)['type'], 'object');
        expect((function['parameters'] as Map)['properties'], {
          'a': {'type': 'string'},
          'b': {'type': 'integer'},
        });
      }
    }

    // Go binds the tools with BindForcedTools; here they are bound with
    // withTools and forced in the options.
    ChatModelOptions forced(ChatModelOptions base) =>
        base.copyWith(maxTokens: 1, toolChoice: ToolChoice.forced);

    test('all param', () async {
      final api = _FakeApi();
      final recorder = _Recorder();
      final model = OpenAIChatModel(
        config: config,
        httpClient: api.ok({
          'id': 'request id',
          'object': 'chat.completion',
          'model': 'gpt-4',
          'choices': [
            {
              'index': 0,
              'message': {
                'role': 'assistant',
                'content': 'response content',
                'name': 'response name',
                'tool_calls': [
                  {
                    'index': 5,
                    'id': 'id',
                    'type': 'function',
                    'function': {'name': 'name', 'arguments': 'arguments'},
                  },
                ],
              },
            },
          ],
          'usage': {'prompt_tokens': 1, 'completion_tokens': 2, 'total_tokens': 3},
        }),
      ).withTools(tools);

      final result = await model.generate(input, options: forced(_with(recorder)));

      final sent = Map.of(api.body);
      expectTools(sent.remove('tools'));
      expect(sent, expectedRequestBody);

      expect(recorder.output!.tokenUsage!.promptTokens, 1);
      expect(recorder.output!.tokenUsage!.completionTokens, 2);
      expect(recorder.output!.tokenUsage!.totalTokens, 3);

      expect(result.role, RoleType.assistant);
      expect(result.content, 'response content');
      expect(result.name, 'response name');
      expect(result.toolCalls, [
        const ToolCall(
          index: 5,
          id: 'id',
          type: 'function',
          function: FunctionCall(name: 'name', arguments: 'arguments'),
        ),
      ]);
      expect(result.responseMeta!.usage!.promptTokens, 1);
      expect(result.responseMeta!.usage!.completionTokens, 2);
      expect(result.responseMeta!.usage!.totalTokens, 3);
      expect(result.extra, {'openai-request-id': 'request id'});
    });

    test('stream all param', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: config,
        httpClient: api.sse(['{"error":{"message":"expected error"}}'], status: 500),
      ).withTools(tools);

      await expectLater(
        model.stream(input, options: forced(const ChatModelOptions())),
        throwsA(isA<OpenAIException>()),
      );

      final sent = Map.of(api.body);
      expectTools(sent.remove('tools'));
      expect(sent, {
        ...expectedRequestBody,
        'stream': true,
        'stream_options': {'include_usage': true},
      });
    });
  });

  group('request body', () {
    test('the config settings are sent with every call', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config.copyWith(
          logProbs: true,
          topLogProbs: 2,
          reasoningEffort: ReasoningEffort.low,
          extraFields: {'service_tier': 'flex'},
        ),
        httpClient: api.ok(_completion({'role': 'assistant', 'content': 'x'})),
      );
      await model.generate([Message.user('hi')]);
      expect(api.body['model'], 'gpt-4o-mini');
      expect(api.body['logprobs'], isTrue);
      expect(api.body['top_logprobs'], 2);
      expect(api.body['reasoning_effort'], 'low');
      expect(api.body['service_tier'], 'flex');
      expect(api.body.containsKey('stream_options'), isFalse);
      expect(api.body['stream'], isFalse);
    });

    test('zero and empty settings are left out, as go-openai omits them',
        () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config.copyWith(
          topP: 0,
          presencePenalty: 0,
          frequencyPenalty: 0,
          maxCompletionTokens: 0,
          topLogProbs: 0,
          stop: const [],
          logitBias: const {},
          user: '',
        ),
        httpClient: api.ok(_completion({'role': 'assistant', 'content': 'x'})),
      );
      await model.generate(
        [Message.user('hi')],
        options: const ChatModelOptions(maxTokens: 0),
      );
      expect(api.body.keys.toSet(), {'model', 'messages', 'stream'});
    });

    test('the common options of a call override the config', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config.copyWith(temperature: 0.1, topP: 0.2, stop: ['a']),
        httpClient: api.ok(_completion({'role': 'assistant', 'content': 'x'})),
      );
      await model.generate(
        [Message.user('hi')],
        options: const ChatModelOptions(
          model: 'gpt-4.1',
          temperature: 0.9,
          topP: 0.8,
          stop: ['b'],
          maxTokens: 50,
          extra: {'temperature': 0.5, 'store': true},
        ),
      );
      expect(api.body['model'], 'gpt-4.1');
      expect(api.body['top_p'], 0.8);
      expect(api.body['stop'], ['b']);
      expect(api.body['max_tokens'], 50);
      // `options.extra` is merged last.
      expect(api.body['temperature'], 0.5);
      expect(api.body['store'], isTrue);
    });

    test('OpenAIRequestOptions replace the config settings Go lets a call '
        'override', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config.copyWith(
          reasoningEffort: ReasoningEffort.low,
          maxCompletionTokens: 100,
          extraFields: {'from_config': 1},
        ),
        httpClient: api.ok(_completion({'role': 'assistant', 'content': 'x'})),
      );
      await model.generate(
        [Message.user('hi')],
        options: const OpenAIRequestOptions(
          reasoningEffort: ReasoningEffort.high,
          maxCompletionTokens: 200,
          extraFields: {'from_call': 2},
        ).toOptions(),
      );
      expect(api.body['reasoning_effort'], 'high');
      expect(api.body['max_completion_tokens'], 200);
      expect(api.body['from_call'], 2);
      expect(api.body.containsKey('from_config'), isFalse);
    });

    test('a json_schema response format is sent as given', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config.copyWith(
          responseFormat: ResponseFormat.jsonSchema(
            name: 'answer',
            description: 'The answer',
            schema: const {
              'type': 'object',
              'properties': {
                'n': {'type': 'integer'},
              },
            },
          ),
        ),
        httpClient: api.ok(_completion({'role': 'assistant', 'content': '{"n":1}'})),
      );
      await model.generate([Message.user('hi')]);
      expect(api.body['response_format'], {
        'type': 'json_schema',
        'json_schema': {
          'name': 'answer',
          'description': 'The answer',
          'strict': true,
          'schema': {
            'type': 'object',
            'properties': {
              'n': {'type': 'integer'},
            },
          },
        },
      });
    });

    test('a contradictory setup fails before anything is sent', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: api.ok(_completion({'role': 'assistant', 'content': 'x'})),
      );
      await expectLater(
        model.generate(
          [Message.user('hi')],
          options: const ChatModelOptions(toolChoice: ToolChoice.forced),
        ),
        throwsArgumentError,
      );
      expect(api.sent, isEmpty);
    });

    test('allowedToolNames restricts the choice (Go allowed_tools)', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: api.ok(_completion({'role': 'assistant', 'content': 'x'})),
      ).withTools([ToolInfo.function(name: 'a'), ToolInfo.function(name: 'b')]);
      await model.generate(
        [Message.user('hi')],
        options: const ChatModelOptions(
          toolChoice: ToolChoice.forced,
          allowedToolNames: ['b'],
        ),
      );
      expect(api.body['tool_choice'], {
        'type': 'function',
        'function': {'name': 'b'},
      });
      expect((api.body['tools']! as List), hasLength(2));
    });
  });

  group('Azure OpenAI', () {
    test('the deployment URL with the API version and an api-key header',
        () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config.copyWith(
          baseUrl: 'https://res.openai.azure.com/',
          byAzure: true,
          apiVersion: '2024-06-01',
          defaultModel: 'gpt-3.5-turbo',
        ),
        httpClient: api.ok(_completion({'role': 'assistant', 'content': 'x'})),
      );
      await model.generate([Message.user('hi')]);

      final sent = api.sent.single;
      expect(
        sent.url.toString(),
        'https://res.openai.azure.com/openai/deployments/gpt-35-turbo/chat/completions?api-version=2024-06-01',
      );
      expect(sent.headers['api-key'], 'test-key');
      expect(sent.headers.containsKey('Authorization'), isFalse);
      expect(sent.body['model'], 'gpt-3.5-turbo');
    });

    test('the default API version, a model mapper and the model of a call',
        () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config.copyWith(
          baseUrl: 'https://res.openai.azure.com',
          byAzure: true,
          azureModelMapper: (model) => 'deploy-$model',
        ),
        httpClient: api.sse([_done]),
      );
      final reader = await model.stream(
        [Message.user('hi')],
        options: const ChatModelOptions(model: 'gpt-4o'),
      );
      await reader.collectAll();
      expect(
        api.sent.single.url.toString(),
        'https://res.openai.azure.com/openai/deployments/deploy-gpt-4o/chat/completions?api-version=2023-05-15',
      );
    });

    test('OpenAIEndpoint builds both URL forms', () {
      const openAI = OpenAIEndpoint(baseUrl: 'https://api.openai.com/v1/');
      expect(
        openAI.url('/chat/completions', 'gpt-4').toString(),
        'https://api.openai.com/v1/chat/completions',
      );
      expect(openAI.authHeaders('k'), {'Authorization': 'Bearer k'});
      const azure = OpenAIEndpoint(baseUrl: 'https://r.azure.com', byAzure: true);
      expect(
        azure.url('/embeddings', 'text:embedding.3').toString(),
        'https://r.azure.com/openai/deployments/textembedding3/embeddings?api-version=2023-05-15',
      );
      expect(azure.authHeaders('k'), {'api-key': 'k'});
      expect(OpenAIEndpoint.defaultAzureApiVersion, '2023-05-15');
    });
  });

  group('headers', () {
    test('config headers and the organization go with every call', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config.copyWith(
          organization: 'org-1',
          customHeaders: {'X-Config': '1'},
        ),
        httpClient: api.ok(_completion({'role': 'assistant', 'content': 'x'})),
      );
      await model.generate([Message.user('hi')]);
      final headers = api.sent.single.headers;
      expect(headers['Authorization'], 'Bearer test-key');
      expect(headers['OpenAI-Organization'], 'org-1');
      expect(headers['X-Config'], '1');
    });

    test('the headers of a call replace the config headers (Go '
        'WithExtraHeader)', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config.copyWith(customHeaders: {'X-Config': '1'}),
        httpClient: api.sse([_done]),
      );
      final reader = await model.stream(
        [Message.user('hi')],
        options: const OpenAIRequestOptions(extraHeaders: {'X-Call': '2'}).toOptions(),
      );
      await reader.collectAll();
      final headers = api.sent.single.headers;
      expect(headers['X-Call'], '2');
      expect(headers.containsKey('X-Config'), isFalse);
    });
  });

  group('cancellation', () {
    test('a token cancelled before generate sends nothing', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: api.ok(_completion({'role': 'assistant', 'content': 'x'})),
      );
      await expectLater(
        model.generate(
          [Message.user('hi')],
          options: ChatModelOptions(cancelToken: CancelToken()..cancel()),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(api.sent, isEmpty);
    });

    test('a run context cancelled before stream sends nothing', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(config: _config, httpClient: api.sse([_done]));
      final token = CancelToken()..cancel('ctx');
      await expectLater(
        model.stream(
          [Message.user('hi')],
          options: ChatModelOptions(
            runContext: RunContext.background().withCancelToken(token),
          ),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(api.sent, isEmpty);
    });

    test('a token cancelled during the stream ends it and releases the body',
        () async {
      final body = _LiveBody();
      final token = CancelToken();
      final model = OpenAIChatModel(config: _config, httpClient: body.client);
      final reader = await model.stream(
        [Message.user('hi')],
        options: ChatModelOptions(cancelToken: token),
      );
      body.add(_data(_chunk({'role': 'assistant', 'content': 'Hel'})));
      expect((await reader.recv()).content, 'Hel');

      token.cancel('user');
      await expectLater(reader.recv(), throwsA(isA<CancelledException>()));
      await expectLater(reader.recv(), throwsA(isA<StreamEOFException>()));
      await pumpEventQueue();
      expect(body.cancelled, isTrue);
    });

    test('a token cancelled while waiting for the response abandons it',
        () async {
      final pending = Completer<http.Response>();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: MockClient((request) => pending.future),
      );
      final token = CancelToken();
      final future = model.generate(
        [Message.user('hi')],
        options: ChatModelOptions(cancelToken: token),
      );
      await pumpEventQueue();
      token.cancel();
      await expectLater(future, throwsA(isA<CancelledException>()));
    });
  });

  group('errors', () {
    Future<OpenAIException> failure(int status, String body) async {
      final model = OpenAIChatModel(
        config: _config,
        httpClient: _FakeApi().json([(status, body)]),
      );
      try {
        await model.generate([Message.user('hi')]);
      } on OpenAIException catch (error) {
        return error;
      }
      fail('no exception');
    }

    test('429 is retryable', () async {
      final error = await failure(
        429,
        '{"error":{"message":"Rate limit reached for gpt-4o","type":"requests","code":"rate_limit_exceeded"}}',
      );
      expect(error.statusCode, 429);
      expect(error.isRetryable, isTrue);
      expect(error.isModelUnavailable, isFalse);
      expect(error.errorCode, 'rate_limit_exceeded');
      expect(error, isA<ChatModelException>());
    });

    test('5xx is retryable', () async {
      expect((await failure(503, 'Service Unavailable')).isRetryable, isTrue);
    });

    test('404 and an unknown model are unavailable, not retryable', () async {
      final notFound = await failure(404, '{"error":{"message":"Not found"}}');
      expect(notFound.isModelUnavailable, isTrue);
      expect(notFound.isRetryable, isFalse);

      final unknown = await failure(
        400,
        '{"error":{"message":"The model `gpt-9` does not exist or you do not have access to it.","code":"model_not_found"}}',
      );
      expect(unknown.isModelUnavailable, isTrue);
      expect(unknown.isRetryable, isFalse);
    });

    test('400 is neither', () async {
      final error = await failure(
        400,
        '{"error":{"message":"Invalid value for temperature","type":"invalid_request_error"}}',
      );
      expect(error.isRetryable, isFalse);
      expect(error.isModelUnavailable, isFalse);
      expect(error.message, contains('status 400'));
      expect(error.response, contains('Invalid value'));
      expect(error.toString(), contains('(status: 400)'));
    });

    test('OpenAIException classifies by status unless told otherwise', () {
      expect(OpenAIException('x', statusCode: 502).isRetryable, isTrue);
      expect(OpenAIException('x', statusCode: 404).isModelUnavailable, isTrue);
      expect(OpenAIException('x', statusCode: 429, isRetryable: false).isRetryable,
          isFalse);
      expect(OpenAIException('x').isRetryable, isFalse);
    });

    test('RetryingChatModel retries a 429 and stops at a 404', () async {
      final api = _FakeApi();
      final retrying = RetryingChatModel(
        OpenAIChatModel(
          config: _config,
          httpClient: api.json([
            (429, '{"error":{"message":"slow down"}}'),
            (200, _completion({'role': 'assistant', 'content': 'after retry'})),
          ]),
        ),
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 2),
      );
      expect((await retrying.generate([Message.user('hi')])).content, 'after retry');
      expect(api.sent, hasLength(2));

      final gone = _FakeApi();
      final notRetried = RetryingChatModel(
        OpenAIChatModel(
          config: _config,
          httpClient: gone.json([(404, '{"error":{"message":"no such model"}}')]),
        ),
        baseDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 2),
      );
      await expectLater(
        notRetried.generate([Message.user('hi')]),
        throwsA(isA<OpenAIException>()),
      );
      expect(gone.sent, hasLength(1));
    });
  });

  group('callbacks', () {
    test('generate reports start and end with the typed payloads', () async {
      final recorder = _Recorder();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: _FakeApi().ok(_completion({'role': 'assistant', 'content': 'hi'})),
      );
      final input = [Message.user('hello')];
      final answer = await model.generate(
        input,
        options: _with(recorder).copyWith(temperature: 0.3),
      );

      expect(recorder.timings, ['start', 'end']);
      expect(
        recorder.infos.single,
        const RunInfo(name: '', type: 'OpenAI', componentType: ComponentType.chatModel),
      );
      expect(recorder.input!.messages, same(input));
      expect(recorder.input!.config!.model, 'gpt-4o-mini');
      expect(recorder.input!.config!.temperature, 0.3);
      expect(recorder.output!.message, same(answer));
      expect(recorder.output!.tokenUsage!.totalTokens, 10);
    });

    test('a failure is reported to the error callback', () async {
      final recorder = _Recorder();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: _FakeApi().json([(500, 'boom')]),
      );
      await expectLater(
        model.generate([Message.user('x')], options: _with(recorder)),
        throwsA(isA<OpenAIException>()),
      );
      expect(recorder.timings, ['start', 'error']);
    });

    test('stream reports the chunks; the usage arrives with the last one',
        () async {
      final recorder = _Recorder();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: _FakeApi().sse([
          _data(_chunk({'role': 'assistant', 'content': 'Hel'})),
          _data(_chunk({'content': 'lo'}, finish: 'stop')),
          _data(_usageChunk(5, 2)),
          _done,
        ]),
      );
      final reader = await model.stream([Message.user('x')], options: _with(recorder));
      final messages = await reader.collectAll();
      await recorder.streamDone.future;

      expect(recorder.timings, ['start', 'endStream']);
      expect(concatMessages(messages).content, 'Hello');
      expect(recorder.chunks, hasLength(messages.length));
      expect(recorder.chunks.last!.tokenUsage!.totalTokens, 7);
      expect(concatMessages(messages).responseMeta!.usage!.totalTokens, 7);
    });
  });

  group('stream', () {
    test('asks for the usage with stream_options.include_usage', () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(config: _config, httpClient: api.sse([_done]));
      await (await model.stream([Message.user('hi')])).collectAll();
      expect(api.body['stream'], isTrue);
      expect(api.body['stream_options'], {'include_usage': true});
    });

    test('reasoning, tool calls and log probabilities are streamed', () async {
      final model = OpenAIChatModel(
        config: _config.copyWith(logProbs: true, topLogProbs: 1),
        httpClient: _FakeApi().sse([
          _data(_chunk({'role': 'assistant', 'reasoning_content': 'Think'})),
          _data(_chunk(
            {'content': 'A'},
            logprobs: {
              'content': [
                {'token': 'A', 'logprob': -0.1, 'bytes': [65], 'top_logprobs': <Object?>[]},
              ],
            },
          )),
          _data(_chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'f', 'arguments': '{"a"'},
              },
            ],
          })),
          _data(_chunk({
            'tool_calls': [
              {'index': 0, 'function': {'arguments': ':1}'}},
            ],
          })),
          _data(_chunk({}, finish: 'tool_calls')),
          _done,
        ]),
      );
      final message =
          concatMessages(await (await model.stream([Message.user('x')])).collectAll());
      expect(message.reasoningContent, 'Think');
      expect(message.content, 'A');
      expect(message.toolCalls!.single.function.arguments, '{"a":1}');
      expect(message.toolCalls!.single.type, 'function');
      expect(message.responseMeta!.logProbs!.content.single.token, 'A');
      expect(message.responseMeta!.finishReason, 'tool_calls');
      expect(message.extra![openAIRequestIdKey], 'chatcmpl-1');
    });

    test('closing the reader early releases the body', () async {
      final body = _LiveBody();
      final model = OpenAIChatModel(config: _config, httpClient: body.client);
      final reader = await model.stream([Message.user('hi')]);
      body.add(_data(_chunk({'role': 'assistant', 'content': 'a'})));
      expect((await reader.recv()).content, 'a');
      await reader.close();
      body.add(_data(_chunk({'content': 'b'})));
      await pumpEventQueue();
      expect(body.cancelled, isTrue);
    });
  });

  group('generate', () {
    test('log probabilities of the response', () async {
      final model = OpenAIChatModel(
        config: _config.copyWith(logProbs: true),
        httpClient: _FakeApi().ok(_completion(
          {'role': 'assistant', 'content': 'Hi'},
          logprobs: {
            'content': [
              {
                'token': 'Hi',
                'logprob': -0.5,
                'bytes': [72, 105],
                'top_logprobs': [
                  {'token': 'Hi', 'logprob': -0.5, 'bytes': [72, 105]},
                ],
              },
            ],
          },
        )),
      );
      final message = await model.generate([Message.user('x')]);
      final logProb = message.responseMeta!.logProbs!.content.single;
      expect(logProb.token, 'Hi');
      expect(logProb.logProb, -0.5);
      expect(logProb.bytes, [72, 105]);
      expect(logProb.topLogProbs.single.token, 'Hi');
    });

    test('reasoning_content becomes reasoningContent only', () async {
      final model = OpenAIChatModel(
        config: _config,
        httpClient: _FakeApi().ok(_completion(
          {'role': 'assistant', 'content': 'A', 'reasoning_content': 'R'},
        )),
      );
      final message = await model.generate([Message.user('x')]);
      expect(message.reasoningContent, 'R');
      expect(message.extra, {openAIRequestIdKey: 'chatcmpl-9'});
    });
  });

  group('audio output', () {
    final audioConfig = _config.copyWith(
      modalities: const [OpenAIModality.text, OpenAIModality.audio],
      audio: const OpenAIAudioConfig(format: 'wav', voice: 'alloy'),
    );

    test('is requested, parsed, and referred to by id in the next request',
        () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: audioConfig,
        httpClient: api.ok(_completion({
          'role': 'assistant',
          'content': null,
          'audio': {
            'id': 'audio_abc123',
            'expires_at': 1729018505,
            'data': 'UklGRg==',
            'transcript': 'Hello there',
          },
        })),
      );

      final answer = await model.generate([Message.user('Say hello')]);
      expect(api.body['modalities'], ['text', 'audio']);
      expect(api.body['audio'], {'format': 'wav', 'voice': 'alloy'});

      final part = answer.assistantGenMultiContent!.single;
      expect(part.type, ChatMessagePartType.audioUrl);
      expect(part.audio!.base64Data, 'UklGRg==');
      expect(part.audio!.mimeType, 'audio/wav');
      expect(part.extra![openAIGeneratedAudioIdKey], 'audio_abc123');
      expect(part.extra![openAIAudioTranscriptKey], 'Hello there');

      await model.generate([Message.user('Say hello'), answer, Message.user('Again')]);
      final echoed = (api.body['messages']! as List)[1] as Map;
      expect(echoed['role'], 'assistant');
      expect(echoed['audio'], {'id': 'audio_abc123'});
      expect(echoed['content'], isNull);
    });

    test('audio data without an audio config fails', () async {
      final model = OpenAIChatModel(
        config: _config,
        httpClient: _FakeApi().ok(_completion({
          'role': 'assistant',
          'audio': {'id': 'a', 'data': 'UklGRg==', 'transcript': ''},
        })),
      );
      await expectLater(
        model.generate([Message.user('x')]),
        throwsA(isA<OpenAIException>().having((e) => e.message, 'message',
            contains('audio config must be set when audio data is present'))),
      );
    });

    test('the audio modality without an audio config is an ArgumentError',
        () async {
      final model = OpenAIChatModel(
        config: _config.copyWith(modalities: const [OpenAIModality.audio]),
        httpClient: _FakeApi().ok(_completion({'role': 'assistant', 'content': 'x'})),
      );
      await expectLater(model.generate([Message.user('x')]), throwsArgumentError);
    });
  });

  group('withTools and dispose', () {
    test('the copy with tools shares the HTTP client and sends the tools',
        () async {
      final api = _FakeApi();
      final model = OpenAIChatModel(
        config: _config,
        httpClient: api.ok(_completion({'role': 'assistant', 'content': 'x'})),
      );
      final bound =
          model.withTools([ToolInfo.function(name: 'search')]) as OpenAIChatModel;

      await model.generate([Message.user('a')]);
      await bound.generate([Message.user('b')]);

      expect(identical(bound.httpClient, model.httpClient), isTrue);
      expect(api.sent, hasLength(2));
      expect(api.sent.first.body.containsKey('tools'), isFalse);
      expect(
        ((api.sent.last.body['tools']! as List).single as Map)['function'],
        {'name': 'search'},
      );
      expect(bound.componentTypeName, 'OpenAI');
      expect(bound.isCallbacksEnabled, isTrue);
    });

    test('dispose closes the client the model created, for its copies too',
        () async {
      final model = OpenAIChatModel(config: _config);
      final bound = model.withTools([ToolInfo.function(name: 'search')]);
      model.dispose();
      await expectLater(model.generate([Message.user('x')]), throwsStateError);
      await expectLater(bound.stream([Message.user('x')]), throwsStateError);
    });

    test('dispose leaves an injected client open', () async {
      final api = _FakeApi();
      final client = api.ok(_completion({'role': 'assistant', 'content': 'x'}));
      OpenAIChatModel(config: _config, httpClient: client).dispose();
      final other = OpenAIChatModel(config: _config, httpClient: client);
      expect((await other.generate([Message.user('x')])).content, 'x');
    });
  });

  group('OpenAIConfig', () {
    test('copyWith keeps and replaces the new fields', () {
      String mapper(String model) => model;
      final config = _config.copyWith(
        byAzure: true,
        apiVersion: 'v',
        azureModelMapper: mapper,
        idleTimeout: const Duration(seconds: 3),
        seed: 1,
      );
      final copy = config.copyWith(seed: 2);
      expect(copy.byAzure, isTrue);
      expect(copy.apiVersion, 'v');
      expect(copy.azureModelMapper, same(mapper));
      expect(copy.idleTimeout, const Duration(seconds: 3));
      expect(copy.seed, 2);
      expect(copy.logProbs, isFalse);
    });

    test('OpenAIModality and OpenAIAudioConfig are sent in wire form', () {
      expect(OpenAIModality.values.map((m) => m.wireName), ['text', 'audio']);
      expect(
        const OpenAIAudioConfig(format: 'mp3', voice: 'coral').toJson(),
        {'format': 'mp3', 'voice': 'coral'},
      );
    });
  });
}
