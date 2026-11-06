// Port of eino-ext components/embedding/gemini/embedding_test.go
// (Test_EmbedStrings: the Go test mocks genai's `Models.EmbedContent`; here
// the embedder runs against a fake HTTP client answering with the REST JSON
// of `batchEmbedContents`), plus tests written for the port: the request
// body, the options, the Vertex-only settings, the usage, callbacks,
// cancellation, error classification and the client lifecycle.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/embedding/gemini_embedder.dart';
import 'package:threepio_core/threepio_core.dart';

const _config = GeminiEmbeddingConfig(
  apiKey: 'test-key',
  model: 'gemini-embedding-001',
);

/// An embedder whose requests are recorded and answered by [respond].
({GeminiEmbedder embedder, List<http.Request> requests}) _embedder(
  Object Function(http.Request request) respond, {
  GeminiEmbeddingConfig config = _config,
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
    embedder: GeminiEmbedder(config: config, httpClient: client),
    requests: requests,
  );
}

Map<String, Object?> _embeddings(List<List<double>> vectors) => {
      'embeddings': [
        for (final values in vectors) {'values': values},
      ],
    };

Map<String, dynamic> _body(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

final class _Recorder extends ComponentCallbackHandler {
  final List<String> timings = [];
  final List<RunInfo> infos = [];
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
}

EmbedderOptions _with(ComponentCallbackHandler handler, {String? model}) =>
    EmbedderOptions(
      model: model,
      runContext: RunContext.background().withHandlers([handler]),
    );

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

  group('Test_EmbedStrings', () {
    test('test embedding success', () async {
      final fake = _embedder(
        (_) => _embeddings([
          [0.1, 0.2],
          [0.3],
          [0.4, 0.5, 0.6],
        ]),
      );

      final result = await fake.embedder
          .embedStrings(['hello world', 'second text', 'third text']);

      expect(result, hasLength(3));
      expect(result, [
        [0.1, 0.2],
        [0.3],
        [0.4, 0.5, 0.6],
      ]);
    });
  });

  group('request', () {
    test('one request per text, as batchEmbedContents', () async {
      final fake = _embedder(
        (_) => _embeddings([
          [1],
          [2],
        ]),
        config: const GeminiEmbeddingConfig(
          apiKey: 'test-key',
          model: 'gemini-embedding-001',
          taskType: GeminiEmbeddingTaskType.retrievalDocument,
          title: 'Doc',
          outputDimensionality: 768,
        ),
      );

      await fake.embedder.embedStrings(['a', 'b']);

      final request = fake.requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:batchEmbedContents',
      );
      expect(request.headers['x-goog-api-key'], 'test-key');
      expect(request.headers['content-type'], startsWith('application/json'));
      Map<String, Object?> one(String text) => {
            'model': 'models/gemini-embedding-001',
            'content': {
              'parts': [
                {'text': text},
              ],
              'role': 'user',
            },
            'taskType': 'RETRIEVAL_DOCUMENT',
            'title': 'Doc',
            'outputDimensionality': 768,
          };
      expect(_body(request), {
        'requests': [one('a'), one('b')],
      });
    });

    test('the model of the options wins, a models/ prefix is kept', () async {
      final fake = _embedder(
        (_) => _embeddings([
          [1],
        ]),
      );
      await fake.embedder.embedStrings(
        ['a'],
        options: const EmbedderOptions(model: 'models/text-embedding-004'),
      );
      final request = fake.requests.single;
      expect(request.url.path, '/v1beta/models/text-embedding-004:batchEmbedContents');
      expect((_body(request)['requests'] as List).single['model'],
          'models/text-embedding-004');
    });

    test('without an API key no key header is sent', () async {
      final fake = _embedder(
        (_) => _embeddings([
          [1],
        ]),
        config: const GeminiEmbeddingConfig(apiKey: '', model: 'm'),
      );
      await fake.embedder.embedStrings(['a']);
      expect(fake.requests.single.headers.containsKey('x-goog-api-key'), isFalse);
    });

    test('no texts, no request', () async {
      final fake = _embedder((_) => _embeddings(const []));
      expect(await fake.embedder.embedStrings(const []), isEmpty);
      expect(fake.requests, isEmpty);
    });

    test('the Vertex-only settings fail as the SDK fails on the Gemini API',
        () async {
      for (final config in const [
        GeminiEmbeddingConfig(apiKey: 'k', model: 'm', mimeType: 'text/plain'),
        GeminiEmbeddingConfig(apiKey: 'k', model: 'm', autoTruncate: true),
      ]) {
        final fake = _embedder((_) => _embeddings(const []), config: config);
        await expectLater(
          fake.embedder.embedStrings(['a']),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('not supported in Gemini API'),
            ),
          ),
        );
        expect(fake.requests, isEmpty);
      }
    });

    test('an empty model is refused', () async {
      final fake = _embedder((_) => _embeddings(const []));
      await expectLater(
        fake.embedder.embedStrings(['a'], options: const EmbedderOptions(model: '')),
        throwsArgumentError,
      );
    });
  });

  group('response', () {
    test('the usage is the sum of the statistics when they are reported',
        () async {
      final fake = _embedder(
        (_) => {
          'embeddings': [
            {
              'values': [0.1],
              'statistics': {'tokenCount': 3, 'truncated': false},
            },
            {
              'values': [0.2],
              'statistics': {'tokenCount': 4},
            },
          ],
        },
      );
      final recorder = _Recorder();
      await fake.embedder.embedStrings(['a', 'b'], options: _with(recorder));
      final usage = recorder.output!.tokenUsage!;
      expect(usage.promptTokens, 7);
      expect(usage.totalTokens, 7);
      expect(usage.completionTokens, 0);
    });

    test('a count that does not match the texts is an error', () async {
      final fake = _embedder(
        (_) => _embeddings([
          [1],
        ]),
      );
      await expectLater(
        fake.embedder.embedStrings(['a', 'b']),
        throwsA(isA<GeminiException>()),
      );
    });

    test('a body that is not JSON is an error', () async {
      final fake = _embedder((_) => 'not json');
      await expectLater(
        fake.embedder.embedStrings(['a']),
        throwsA(isA<GeminiException>()),
      );
    });
  });

  group('errors', () {
    final cases = <String, (int, String, bool, bool)>{
      '429 is retryable': (
        429,
        '{"error":{"code":429,"message":"quota","status":"RESOURCE_EXHAUSTED"}}',
        true,
        false,
      ),
      '404 means the model is unavailable': (
        404,
        '{"error":{"code":404,"message":"models/x is not found","status":"NOT_FOUND"}}',
        false,
        true,
      ),
      '400 is neither': (
        400,
        '{"error":{"code":400,"message":"bad","status":"INVALID_ARGUMENT"}}',
        false,
        false,
      ),
    };
    for (final MapEntry(key: name, value: (status, body, retryable, unavailable))
        in cases.entries) {
      test(name, () async {
        final fake = _embedder((_) => body, status: status);
        await expectLater(
          fake.embedder.embedStrings(['a']),
          throwsA(
            isA<GeminiException>()
                .having((e) => e.statusCode, 'statusCode', status)
                .having((e) => e.isRetryable, 'isRetryable', retryable)
                .having((e) => e.isModelUnavailable, 'isModelUnavailable', unavailable),
          ),
        );
      });
    }

    test('a timeout and a transport failure are retryable', () async {
      final slow = GeminiEmbedder(
        config: const GeminiEmbeddingConfig(
          apiKey: 'k',
          model: 'm',
          timeout: Duration(milliseconds: 20),
        ),
        httpClient: MockClient((_) => Completer<http.Response>().future),
      );
      await expectLater(
        slow.embedStrings(['a']),
        throwsA(isA<GeminiException>().having((e) => e.isRetryable, 'isRetryable', isTrue)),
      );

      final failure = http.ClientException('reset');
      final broken = GeminiEmbedder(
        config: _config,
        httpClient: MockClient((_) async => throw failure),
      );
      await expectLater(
        broken.embedStrings(['a']),
        throwsA(
          isA<GeminiException>()
              .having((e) => e.cause, 'cause', same(failure))
              .having((e) => e.isRetryable, 'isRetryable', isTrue),
        ),
      );
    });
  });

  group('callbacks', () {
    test('start and end with typed payloads', () async {
      final fake = _embedder(
        (_) => _embeddings([
          [0.5, 0.25],
        ]),
      );
      final recorder = _Recorder();

      await fake.embedder.embedStrings(['hello'], options: _with(recorder, model: 'other'));

      expect(recorder.timings, ['start', 'end']);
      expect(recorder.infos.single.type, 'Gemini');
      expect(recorder.infos.single.componentType, ComponentType.embedder);
      expect(recorder.input!.texts, ['hello']);
      expect(recorder.input!.config!.model, 'other');
      expect(recorder.output!.embeddings, [
        [0.5, 0.25],
      ]);
      expect(recorder.output!.config!.model, 'other');
      expect(recorder.output!.tokenUsage, isNull);
      expect(fake.requests.single.url.path, contains('models/other:'));
    });

    test('an error is reported', () async {
      final fake = _embedder(
        (_) => '{"error":{"code":500,"message":"boom","status":"INTERNAL"}}',
        status: 500,
      );
      final recorder = _Recorder();
      await expectLater(
        fake.embedder.embedStrings(['a'], options: _with(recorder)),
        throwsA(isA<GeminiException>()),
      );
      expect(recorder.timings, ['start', 'error']);
      expect(recorder.error, isA<GeminiException>());
      expect(recorder.input!.config!.model, 'gemini-embedding-001');
    });
  });

  group('cancellation', () {
    test('a cancelled run context sends nothing', () async {
      final fake = _embedder(
        (_) => _embeddings([
          [1],
        ]),
      );
      await expectLater(
        fake.embedder.embedStrings(
          ['a'],
          options: EmbedderOptions(
            runContext: RunContext.background(cancelToken: CancelToken()..cancel()),
          ),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(fake.requests, isEmpty);
    });

    test('cancelling while the response is awaited', () async {
      final pending = Completer<http.Response>();
      final embedder = GeminiEmbedder(
        config: _config,
        httpClient: MockClient((_) => pending.future),
      );
      final token = CancelToken();
      final call = embedder.embedStrings(
        ['a'],
        options: EmbedderOptions(runContext: RunContext.background(cancelToken: token)),
      );
      await pumpEventQueue();
      token.cancel('stop');
      await expectLater(call, throwsA(isA<CancelledException>()));
      expect(token.reason, 'stop');
      pending.complete(http.Response(jsonEncode(_embeddings(const [])), 200));
    });
  });

  group('lifecycle', () {
    test('says what it is', () {
      final embedder = GeminiEmbedder(config: _config);
      expect(embedder.componentTypeName, 'Gemini');
      expect(embedder.isCallbacksEnabled, isTrue);
      expect(componentTypeNameOf(embedder), 'Gemini');
      expect(isCallbacksEnabled(embedder), isTrue);
      expect(embedder, isA<Embedder>());
      expect(_config.toString(), isNot(contains('test-key')));
    });

    test('dispose closes its own client only', () async {
      final own = GeminiEmbedder(config: _config);
      own.dispose();
      await expectLater(own.embedStrings(['a']), throwsStateError);

      final client = _TrackingClient(
        MockClient(
          (_) async => http.Response(
            jsonEncode(_embeddings([
              [1],
            ])),
            200,
          ),
        ),
      );
      final injected = GeminiEmbedder(config: _config, httpClient: client);
      expect(await injected.embedStrings(['a']), [
        [1.0],
      ]);
      injected.dispose();
      expect(client.closed, isFalse);
    });
  });
}
