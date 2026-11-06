// Port of eino-ext components/embedding/openai/embedding_test.go
// (TestEmbedding "full param"), components/embedding/dashscope/
// embedding_test.go (TestEmbedding "full param") and libs/acl/openai/
// embedding_test.go (TestEmbedStrings, Azure), through a fake HTTP server
// instead of mockey on go-openai, plus tests written for the port of the
// upgraded `OpenAIEmbedder`: `dimensions`, `encodingFormat` (base64 decoded
// as little-endian float32), `user`, Azure routing from the config,
// callbacks with the usage, the `DashScope` type, cancellation through
// `options.runContext`, errors, headers and `dispose`.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../support/log_capture.dart';

typedef _Sent = ({Uri url, Map<String, String> headers, Map<String, Object?> body});

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
          response is String ? response : jsonEncode(response),
          status,
          headers: const {'content-type': 'application/json'},
        );
      });
}

/// The response of the Go fixtures (go-openai serializes both indexes as 0).
const _mockResponse = {
  'object': 'object',
  'data': [
    {
      'object': 'embedding',
      'index': 0,
      'embedding': [0.1, 0.2],
    },
    {
      'object': 'embedding',
      'index': 0,
      'embedding': [0.3, 0.4],
    },
  ],
  'model': 'embedding',
  'usage': {'prompt_tokens': 1, 'completion_tokens': 2, 'total_tokens': 3},
};

/// Records the start, end and error payloads of an embedding call.
final class _Recorder extends ComponentCallbackHandler {
  final timings = <String>[];
  final infos = <RunInfo>[];
  EmbeddingCallbackInput? input;
  EmbeddingCallbackOutput? output;
  Object? error;

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    timings.add('start');
    infos.add(info);
    this.input = EmbeddingCallbackInput.from(input);
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    timings.add('end');
    this.output = EmbeddingCallbackOutput.from(output);
    return ctx;
  }

  @override
  RunContext onError(RunContext ctx, RunInfo info, Object error, StackTrace stackTrace) {
    timings.add('error');
    this.error = error;
    return ctx;
  }
}

EmbedderOptions _with(_Recorder recorder) => EmbedderOptions(
      runContext: RunContext.background().withHandlers([recorder]),
    );

void _expectClose(List<List<double>> result, List<List<double>> expected) {
  expect(result, hasLength(expected.length));
  for (var i = 0; i < expected.length; i++) {
    expect(result[i], hasLength(expected[i].length));
    for (var j = 0; j < expected[i].length; j++) {
      expect((result[i][j] - expected[i][j]).abs(), lessThan(1e-7));
    }
  }
}

String _float32Base64(List<double> values) {
  final data = ByteData(values.length * 4);
  for (final (i, v) in values.indexed) {
    data.setFloat32(i * 4, v, Endian.little);
  }
  return base64Encode(data.buffer.asUint8List());
}

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('TestEmbedding (openai)', () {
    test('full param', () async {
      final api = _FakeApi();
      final recorder = _Recorder();
      final embedder = OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'api_key'),
        defaultModel: 'embedding',
        dimensions: 1024,
        user: 'megumin',
        httpClient: api.json(_mockResponse),
      );

      final result = await embedder.embedStrings(['input'], options: _with(recorder));

      expect(api.body, {
        'input': ['input'],
        'model': 'embedding',
        'user': 'megumin',
        'encoding_format': 'float',
        'dimensions': 1024,
      });
      expect(recorder.output!.tokenUsage!.promptTokens, 1);
      expect(recorder.output!.tokenUsage!.completionTokens, 2);
      expect(recorder.output!.tokenUsage!.totalTokens, 3);
      _expectClose(result, [
        [0.1, 0.2],
        [0.3, 0.4],
      ]);
    });
  });

  group('TestEmbedding (dashscope)', () {
    test('full param', () async {
      final api = _FakeApi();
      final recorder = _Recorder();
      final embedder = OpenAIEmbedder.dashScope(
        apiKey: 'mock_key',
        timeout: const Duration(seconds: 5),
        model: 'mock_model',
        httpClient: api.json(_mockResponse),
      );

      final result = await embedder.embedStrings(['input'], options: _with(recorder));

      expect(api.body, {
        'input': ['input'],
        'model': 'mock_model',
        'encoding_format': 'float',
        'dimensions': 1024,
      });
      expect(
        api.sent.single.url.toString(),
        'https://dashscope.aliyuncs.com/compatible-mode/v1/embeddings',
      );
      expect(api.sent.single.headers['Authorization'], 'Bearer mock_key');
      expect(recorder.output!.tokenUsage!.promptTokens, 1);
      expect(recorder.output!.tokenUsage!.completionTokens, 2);
      expect(recorder.output!.tokenUsage!.totalTokens, 3);
      expect(recorder.infos.single.type, 'DashScope');
      _expectClose(result, [
        [0.1, 0.2],
        [0.3, 0.4],
      ]);
    });

    test('the DashScope type, defaults and dimensions', () {
      final embedder = OpenAIEmbedder.dashScope(apiKey: 'k', model: 'text-embedding-v4');
      expect(embedder.componentTypeName, 'DashScope');
      expect(embedder.dimensions, 1024);
      expect(embedder.encodingFormat, EmbeddingEncodingFormat.float);
      expect(embedder.user, isNull);
      expect(embedder.defaultModel, 'text-embedding-v4');
      expect(embedder.config.baseUrl, 'https://dashscope.aliyuncs.com/compatible-mode/v1');
      expect(
        OpenAIEmbedder.dashScope(apiKey: 'k', model: 'm', dimensions: 512).dimensions,
        512,
      );
    });
  });

  group('TestEmbedStrings (acl, Azure)', () {
    test('embeds through the Azure deployment', () async {
      final api = _FakeApi();
      final embedder = OpenAIEmbedder(
        config: const OpenAIConfig(
          apiKey: 'test-key',
          baseUrl: 'https://xxxx.com/api',
          byAzure: true,
          apiVersion: '2024-06-01',
        ),
        defaultModel: 'gpt-4o-2024-05-13',
        httpClient: api.json({
          'object': 'xx',
          'data': [
            {
              'object': 'embedding',
              'index': 0,
              'embedding': [1, 2, 3],
            },
          ],
          'model': 'text-embedding-ada-002',
          'usage': {'prompt_tokens': 100, 'completion_tokens': 300, 'total_tokens': 400},
        }),
      );

      final embeddings = await embedder.embedStrings(['how are you']);

      expect(embeddings, hasLength(1));
      expect(embeddings[0], [1.0, 2.0, 3.0]);
      expect(
        api.sent.single.url.toString(),
        'https://xxxx.com/api/openai/deployments/gpt-4o-2024-05-13/embeddings?api-version=2024-06-01',
      );
      expect(api.sent.single.headers['api-key'], 'test-key');
      expect(api.sent.single.headers.containsKey('Authorization'), isFalse);
    });

    test('the deployment name drops "." and ":" unless mapped', () async {
      final api = _FakeApi();
      final response = {
        'data': [
          {'index': 0, 'embedding': [1]},
        ],
      };
      await OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k', baseUrl: 'https://r.azure.com', byAzure: true),
        defaultModel: 'text-embedding-3.small',
        httpClient: api.json(response),
      ).embedStrings(['x']);
      expect(
        api.sent.last.url.toString(),
        'https://r.azure.com/openai/deployments/text-embedding-3small/embeddings?api-version=2023-05-15',
      );

      await OpenAIEmbedder(
        config: OpenAIConfig(
          apiKey: 'k',
          baseUrl: 'https://r.azure.com',
          byAzure: true,
          azureModelMapper: (model) => 'emb',
        ),
        httpClient: api.json(response),
      ).embedStrings(['x']);
      expect(api.sent.last.url.path, '/openai/deployments/emb/embeddings');
    });
  });

  group('request', () {
    test('defaults: float, no dimensions, no user', () async {
      final api = _FakeApi();
      await OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: api.json(_mockResponse),
      ).embedStrings(['a', 'b']);
      expect(api.body, {
        'input': ['a', 'b'],
        'model': 'text-embedding-3-small',
        'encoding_format': 'float',
      });
      expect(api.sent.single.url.toString(), 'https://api.openai.com/v1/embeddings');
    });

    test('zero dimensions and an empty user are left out', () async {
      final api = _FakeApi();
      await OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        dimensions: 0,
        user: '',
        httpClient: api.json(_mockResponse),
      ).embedStrings(['a']);
      expect(api.body.containsKey('dimensions'), isFalse);
      expect(api.body.containsKey('user'), isFalse);
    });

    test('the model and extra fields of a call', () async {
      final api = _FakeApi();
      await OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: api.json(_mockResponse),
      ).embedStrings(
        ['a'],
        options: const EmbedderOptions(model: 'text-embedding-3-large', extra: {'x': 1}),
      );
      expect(api.body['model'], 'text-embedding-3-large');
      expect(api.body['x'], 1);
    });

    test('headers: bearer key, organization and custom headers', () async {
      final api = _FakeApi();
      await OpenAIEmbedder(
        config: const OpenAIConfig(
          apiKey: 'k',
          organization: 'org-1',
          customHeaders: {'X-Custom': 'v'},
        ),
        httpClient: api.json(_mockResponse),
      ).embedStrings(['a']);
      final headers = api.sent.single.headers;
      expect(headers['Authorization'], 'Bearer k');
      expect(headers['OpenAI-Organization'], 'org-1');
      expect(headers['X-Custom'], 'v');
    });

    test('no texts, no request', () async {
      final api = _FakeApi();
      final result = await OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: api.json(_mockResponse),
      ).embedStrings([]);
      expect(result, isEmpty);
      expect(api.sent, isEmpty);
    });
  });

  group('response', () {
    test('vectors are ordered by index', () async {
      final result = await OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: _FakeApi().json({
          'data': [
            {'index': 1, 'embedding': [2.0]},
            {'index': 0, 'embedding': [1.0]},
          ],
        }),
      ).embedStrings(['a', 'b']);
      expect(result, [
        [1.0],
        [2.0],
      ]);
    });

    test('base64 vectors are requested and decoded as little-endian float32',
        () async {
      final api = _FakeApi();
      final embedder = OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        encodingFormat: EmbeddingEncodingFormat.base64,
        httpClient: api.json({
          'data': [
            {'index': 0, 'embedding': _float32Base64([1.5, -2, 0.25])},
          ],
          'usage': {'prompt_tokens': 2, 'total_tokens': 2},
        }),
      );
      final result = await embedder.embedStrings(['a']);
      expect(api.body['encoding_format'], 'base64');
      expect(result, [
        [1.5, -2.0, 0.25],
      ]);
    });

    test('decodeBase64Embedding rejects a length that is not a multiple of 4',
        () {
      expect(
        OpenAIEmbedder.decodeBase64Embedding(_float32Base64([3.5])),
        [3.5],
      );
      expect(
        () => OpenAIEmbedder.decodeBase64Embedding(base64Encode([1, 2, 3])),
        throwsA(isA<OpenAIEmbedderException>()),
      );
    });

    test('a response without vectors fails', () async {
      final embedder = OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: _FakeApi().json({'data': <Object?>[]}),
      );
      await expectLater(
        embedder.embedStrings(['a']),
        throwsA(isA<OpenAIEmbedderException>()),
      );
    });
  });

  group('callbacks', () {
    test('start and end carry the texts, the config and the usage', () async {
      final recorder = _Recorder();
      final texts = ['how are you'];
      final embedder = OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        defaultModel: 'text-embedding-3-large',
        httpClient: _FakeApi().json(_mockResponse),
      );

      final vectors = await embedder.embedStrings(texts, options: _with(recorder));

      expect(recorder.timings, ['start', 'end']);
      expect(
        recorder.infos.single,
        const RunInfo(name: '', type: 'OpenAI', componentType: ComponentType.embedder),
      );
      expect(recorder.input!.texts, texts);
      expect(recorder.input!.config!.model, 'text-embedding-3-large');
      expect(recorder.input!.config!.encodingFormat, 'float');
      expect(recorder.output!.embeddings, vectors);
      expect(recorder.output!.config!.model, 'text-embedding-3-large');
    });

    test('a usage without total_tokens counts the prompt tokens', () async {
      final recorder = _Recorder();
      await OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: _FakeApi().json({
          'data': [
            {'index': 0, 'embedding': [1]},
          ],
          'usage': {'prompt_tokens': 8},
        }),
      ).embedStrings(['a'], options: _with(recorder));
      expect(recorder.output!.tokenUsage!.promptTokens, 8);
      expect(recorder.output!.tokenUsage!.totalTokens, 8);
      expect(recorder.output!.tokenUsage!.completionTokens, 0);
    });

    test('no usage, no token usage', () async {
      final recorder = _Recorder();
      await OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: _FakeApi().json({
          'data': [
            {'index': 0, 'embedding': [1]},
          ],
        }),
      ).embedStrings(['a'], options: _with(recorder));
      expect(recorder.output!.tokenUsage, isNull);
    });

    test('a failure is reported to the error callback and rethrown', () async {
      final recorder = _Recorder();
      final embedder = OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: _FakeApi().json('{"error":{"message":"bad key"}}', status: 401),
      );
      await expectLater(
        embedder.embedStrings(['a'], options: _with(recorder)),
        throwsA(isA<OpenAIEmbedderException>()),
      );
      expect(recorder.timings, ['start', 'error']);
      expect(recorder.error, isA<OpenAIEmbedderException>());
    });

    test('global handlers hear a call without a run context', () async {
      final recorder = _Recorder();
      GlobalCallbacks.append([recorder]);
      await OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: _FakeApi().json(_mockResponse),
      ).embedStrings(['a']);
      expect(recorder.timings, ['start', 'end']);
    });

    test('the embedder is a typed, callback-aware component', () {
      final embedder = OpenAIEmbedder(config: const OpenAIConfig(apiKey: 'k'));
      expect(embedder, isA<TypedComponent>());
      expect(embedder.componentTypeName, 'OpenAI');
      expect(embedder.isCallbacksEnabled, isTrue);
    });
  });

  group('cancellation', () {
    test('a run context cancelled before the call sends nothing', () async {
      final api = _FakeApi();
      final embedder = OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: api.json(_mockResponse),
      );
      await expectLater(
        embedder.embedStrings(
          ['a'],
          options: EmbedderOptions(
            runContext: RunContext.background().withCancelToken(CancelToken()..cancel()),
          ),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(api.sent, isEmpty);
    });

    test('a run context cancelled while waiting abandons the request',
        () async {
      final pending = Completer<http.Response>();
      final token = CancelToken();
      final recorder = _Recorder();
      final embedder = OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: MockClient((request) => pending.future),
      );
      final future = embedder.embedStrings(
        ['a'],
        options: EmbedderOptions(
          runContext: RunContext.background()
              .withHandlers([recorder])
              .withCancelToken(token),
        ),
      );
      await pumpEventQueue();
      token.cancel('stop');
      await expectLater(future, throwsA(isA<CancelledException>()));
      expect(recorder.timings, ['start', 'error']);
    });
  });

  group('errors', () {
    test('a status other than 200 keeps the status and the body', () async {
      final embedder = OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: _FakeApi().json('{"error":{"message":"Rate limit"}}', status: 429),
      );
      await expectLater(
        embedder.embedStrings(['a']),
        throwsA(isA<OpenAIEmbedderException>()
            .having((e) => e.statusCode, 'statusCode', 429)
            .having((e) => e.response, 'response', contains('Rate limit'))
            .having((e) => e.toString(), 'toString', contains('(status: 429)'))),
      );
    });

    test('a timeout and a transport failure', () async {
      final slow = OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k', timeout: Duration(milliseconds: 5)),
        httpClient: MockClient((request) => Completer<http.Response>().future),
      );
      await expectLater(
        slow.embedStrings(['a']),
        throwsA(isA<OpenAIEmbedderException>()
            .having((e) => e.message, 'message', startsWith('Request timed out'))),
      );

      final broken = OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: MockClient((request) async => throw http.ClientException('refused')),
      );
      await expectLater(
        broken.embedStrings(['a']),
        throwsA(isA<OpenAIEmbedderException>()
            .having((e) => e.message, 'message', startsWith('Request failed'))),
      );
    });
  });

  group('dispose', () {
    test('closes the client the embedder created', () async {
      final embedder = OpenAIEmbedder(config: const OpenAIConfig(apiKey: 'k'))..dispose();
      await expectLater(embedder.embedStrings(['a']), throwsStateError);
    });

    test('leaves an injected client open', () async {
      final api = _FakeApi();
      final client = api.json(_mockResponse);
      OpenAIEmbedder(config: const OpenAIConfig(apiKey: 'k'), httpClient: client).dispose();
      final result = await OpenAIEmbedder(
        config: const OpenAIConfig(apiKey: 'k'),
        httpClient: client,
      ).embedStrings(['a']);
      expect(result, hasLength(2));
    });
  });
}
