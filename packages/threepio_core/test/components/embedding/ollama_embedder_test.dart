// Ports eino-ext components/embedding/ollama/embedding_test.go: TestEmbedding,
// 4 of its 5 cases. The Go test mocks `api.Client.Embed` with mockey; here the
// embedder talks to a fake HTTP client that answers with the recorded shape of
// Ollama's `/api/embed` response. Not ported: "invalid param - missing
// config" (the configuration is a required, non-nullable parameter in Dart).
// "full param" checks the callback `Extra` map as Go does (total_duration,
// load_duration, prompt_eval_count); the port also reports the prompt token
// count as the token usage, which is checked as well.
//
// Plus tests written for the port: request body from the configuration, the
// model of a call, error classification, malformed answers, cancellation
// through the run context, callbacks, dispose.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/embedding/ollama_embedder.dart';
import 'package:threepio_core/src/components/model/providers/ollama/ollama_chat_model.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../support/log_capture.dart';

const _model = 'nomic-embed-text';

/// Go's mockEmbeddings.
const _vector = [
  -0.006788351107388735,
  -0.0013259865809231997,
  -0.17136646807193756,
  0.008495260030031204,
];

/// The recorded shape of an `/api/embed` answer (Go's mockResponse).
Map<String, Object?> _answer({
  List<List<double>> embeddings = const [_vector],
  int? promptEvalCount = 2,
}) =>
    {
      'model': _model,
      'embeddings': embeddings,
      'total_duration': 30318500,
      'load_duration': 17898200,
      if (promptEvalCount != null) 'prompt_eval_count': promptEvalCount,
    };

typedef _Request = ({Uri url, Map<String, String> headers, Object? body});

MockClient _answering(List<_Request> log, Object body, {int status = 200}) =>
    MockClient((request) async {
      log.add((
        url: request.url,
        headers: request.headers,
        body: jsonDecode(request.body),
      ));
      return http.Response(
        body is String ? body : jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

/// Records the callbacks of embedders with their payloads; like Go's
/// `HandlerHelper.Embedding`, it ignores other components (a chain).
final class _Recorder extends ComponentCallbackHandler {
  final List<String> timings = [];
  final List<RunInfo> infos = [];
  EmbeddingCallbackInput? input;
  EmbeddingCallbackOutput? output;
  Object? error;

  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    if (info.componentType != ComponentType.embedder) return ctx;
    timings.add('start');
    infos.add(info);
    this.input = EmbeddingCallbackInput.from(input);
    return ctx;
  }

  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    if (info.componentType != ComponentType.embedder) return ctx;
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
    if (info.componentType != ComponentType.embedder) return ctx;
    timings.add('error');
    this.error = error;
    return ctx;
  }
}

EmbedderOptions _with(ComponentCallbackHandler handler) => EmbedderOptions(
      runContext: RunContext.background().withHandlers([handler]),
    );

final class _RecordingClient extends http.BaseClient {
  int requests = 0;
  bool isClosed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(_answer()))),
      200,
    );
  }

  @override
  void close() => isClosed = true;
}

void main() {
  setUp(() {
    GlobalCallbacks.clear();
    failOnLoggedWarnings('threepio.callbacks');
  });
  tearDown(GlobalCallbacks.clear);

  group('TestEmbedding', () {
    test('invalid param - invalid base_url', () {
      expect(
        () => OllamaEmbedder(
          config: const OllamaEmbedderConfig(
            baseUrl: 'http://example.com:port',
            model: _model,
            timeout: Duration(seconds: 10),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('optional base_url', () async {
      final log = <_Request>[];
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(
          baseUrl: '',
          model: _model,
          timeout: Duration(seconds: 10),
        ),
        httpClient: _answering(log, _answer()),
      );

      await embedder.embedStrings(['hello world']);

      expect(log.single.url, Uri.parse('http://localhost:11434/api/embed'));
    });

    test('invalid param - missing model', () async {
      // What Ollama answers to a request without a model.
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(
          model: '',
          timeout: Duration(seconds: 10),
        ),
        httpClient: _answering([], {'error': 'model is required'}, status: 400),
      );

      await expectLater(
        embedder.embedStrings(['hello world']),
        throwsA(isA<OllamaException>()),
      );
    });

    test('full param', () async {
      final log = <_Request>[];
      final emb = OllamaEmbedder(
        config: const OllamaEmbedderConfig(
          baseUrl: 'http://localhost:11434',
          model: _model,
          timeout: Duration(seconds: 10),
        ),
        httpClient: _answering(log, _answer()),
      );
      final recorder = _Recorder();
      final ctx = RunContext.background();
      final chain = Chain<List<String>, List<List<double>>>()
        ..appendEmbedding(emb);
      final run = await chain.compile(ctx);

      final outEmbeddings = await run.invoke(
        ctx,
        ['hello world'],
        options: [CallOption.callbacks([recorder])],
      );

      expect(log.single.body, {
        'model': _model,
        'input': ['hello world'],
        'options': null,
      });
      expect(outEmbeddings.single, hasLength(_vector.length));
      expect(recorder.timings, ['start', 'end']);
      expect(recorder.input!.texts, ['hello world']);
      expect(recorder.input!.config!.model, _model);
      expect(recorder.output!.embeddings.single, hasLength(_vector.length));
      expect(recorder.output!.extra, {
        ollamaTotalDurationKey: 30318500,
        ollamaLoadDurationKey: 17898200,
        ollamaPromptEvalCountKey: 2,
      });
      expect(recorder.output!.tokenUsage!.promptTokens, 2);
    });
  });

  group('request', () {
    test('the configuration sets keep_alive, truncate and options', () async {
      final log = <_Request>[];
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(
          model: _model,
          baseUrl: 'http://gpu.local:11434/ollama',
          truncate: false,
          keepAlive: Duration(minutes: 30),
          options: {'num_ctx': 8192},
        ),
        httpClient: _answering(log, _answer()),
      );

      await embedder.embedStrings(['a', 'b']);

      final request = log.single;
      expect(request.url, Uri.parse('http://gpu.local:11434/ollama/api/embed'));
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(request.headers['Accept'], 'application/json');
      expect(request.body, {
        'model': _model,
        'input': ['a', 'b'],
        'keep_alive': '30m0s',
        'truncate': false,
        'options': {'num_ctx': 8192},
      });
    });

    test('a negative keep_alive is -1', () async {
      final log = <_Request>[];
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(
          model: _model,
          keepAlive: Duration(seconds: -1),
        ),
        httpClient: _answering(log, _answer()),
      );

      await embedder.embedStrings(['a']);

      expect((log.single.body! as Map)['keep_alive'], -1);
    });

    test('the model of a call is the one sent and reported', () async {
      // Go reports the model of the call but sends the configured one.
      final log = <_Request>[];
      final recorder = _Recorder();
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: _answering(log, _answer()),
      );

      await embedder.embedStrings(
        ['a'],
        options: _with(recorder).copyWith(model: 'mxbai-embed-large'),
      );

      expect((log.single.body! as Map)['model'], 'mxbai-embed-large');
      expect(recorder.input!.config!.model, 'mxbai-embed-large');
    });
  });

  group('response', () {
    test('one vector for each text, in order', () async {
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: _answering(
          [],
          _answer(
            embeddings: [
              [0.1, 0.2],
              [0.3, 0.4],
              [1, 0],
            ],
          ),
        ),
      );

      expect(await embedder.embedStrings(['a', 'b', 'c']), [
        [0.1, 0.2],
        [0.3, 0.4],
        [1.0, 0.0],
      ]);
    });

    test('an empty body has no vectors, as in Go', () async {
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: _answering([], ''),
      );

      expect(await embedder.embedStrings(['a']), isEmpty);
    });

    test('malformed answers fail with an OllamaException', () async {
      for (final body in [
        'not json',
        '[1, 2]',
        '{"embeddings": 3}',
        '{"embeddings": [3]}',
        '{"embeddings": [["x"]]}',
      ]) {
        final embedder = OllamaEmbedder(
          config: const OllamaEmbedderConfig(model: _model),
          httpClient: _answering([], body),
        );
        await expectLater(
          embedder.embedStrings(['a']),
          throwsA(
            isA<OllamaException>()
                .having((e) => e.message, 'message', startsWith('Malformed'))
                .having((e) => e.isRetryable, 'isRetryable', isFalse),
          ),
          reason: body,
        );
      }
    });

    test('parseEmbedResponse: the usage is the prompt token count, if any', () {
      final withCount = OllamaEmbedder.parseEmbedResponse(jsonEncode(_answer()));
      expect(
        withCount.usage,
        const TokenUsage(promptTokens: 2, completionTokens: 0, totalTokens: 2),
      );
      final without = OllamaEmbedder.parseEmbedResponse(
        jsonEncode(_answer(promptEvalCount: null)),
      );
      expect(without.usage, isNull);
      expect(without.vectors.single, _vector);
    });

    test('parseEmbedResponse: the extra has Go keys, zero when left out', () {
      expect(ollamaTotalDurationKey, 'total_duration');
      expect(ollamaLoadDurationKey, 'load_duration');
      expect(ollamaPromptEvalCountKey, 'prompt_eval_count');
      expect(
        OllamaEmbedder.parseEmbedResponse(
          jsonEncode(_answer(promptEvalCount: null)),
        ).extra,
        {
          ollamaTotalDurationKey: 30318500,
          ollamaLoadDurationKey: 17898200,
          ollamaPromptEvalCountKey: 0,
        },
      );
      expect(OllamaEmbedder.parseEmbedResponse('').extra, {
        ollamaTotalDurationKey: 0,
        ollamaLoadDurationKey: 0,
        ollamaPromptEvalCountKey: 0,
      });
    });
  });

  group('errors', () {
    Future<OllamaException> failure(int status, Object body) async {
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: _answering([], body, status: status),
      );
      try {
        await embedder.embedStrings(['a']);
      } on OllamaException catch (error) {
        return error;
      }
      fail('no OllamaException');
    }

    test('404 with an unknown model is model-unavailable', () async {
      final error = await failure(404, {
        'error': 'model "nomic-embed-text" not found, try pulling it first',
      });
      expect(error.isModelUnavailable, isTrue);
      expect(error.isRetryable, isFalse);
      expect(error.statusCode, 404);
      expect(error.message, contains('try pulling it first'));
    });

    test('429 and 500 are retryable; 400 is neither', () async {
      expect((await failure(429, {'error': 'busy'})).isRetryable, isTrue);
      expect((await failure(500, {'error': 'crashed'})).isRetryable, isTrue);
      final bad = await failure(400, {
        'error': 'the input length exceeds the context length',
      });
      expect(bad.isRetryable, isFalse);
      expect(bad.isModelUnavailable, isFalse);
    });

    test('a failed connection is retryable and keeps its cause', () async {
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: MockClient(
          (request) async => throw http.ClientException('Connection refused'),
        ),
      );

      await expectLater(
        embedder.embedStrings(['a']),
        throwsA(
          isA<OllamaException>()
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.cause, 'cause', isA<http.ClientException>()),
        ),
      );
    });

    test('a timeout is retryable', () async {
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(
          model: _model,
          timeout: Duration(milliseconds: 10),
        ),
        httpClient: MockClient((request) => Completer<http.Response>().future),
      );

      await expectLater(
        embedder.embedStrings(['a']),
        throwsA(
          isA<OllamaException>()
              .having((e) => e.isRetryable, 'isRetryable', isTrue)
              .having((e) => e.message, 'message', contains('timed out')),
        ),
      );
    });
  });

  group('cancellation', () {
    test('a cancelled run context sends nothing', () async {
      final log = <_Request>[];
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: _answering(log, _answer()),
      );

      await expectLater(
        embedder.embedStrings(
          ['a'],
          options: EmbedderOptions(
            runContext: RunContext.background(
              cancelToken: CancelToken()..cancel('no'),
            ),
          ),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(log, isEmpty);
    });

    test('a call cancelled while it waits for the answer', () async {
      final sent = Completer<void>();
      final token = CancelToken();
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: MockClient((request) {
          sent.complete();
          return Completer<http.Response>().future; // never answers
        }),
      );

      final vectors = embedder.embedStrings(
        ['a'],
        options: EmbedderOptions(
          runContext: RunContext.background(cancelToken: token),
        ),
      );
      await sent.future;
      token.cancel('user');

      await expectLater(vectors, throwsA(isA<CancelledException>()));
    });
  });

  group('callbacks', () {
    test('a call reports its texts, model, vectors and usage', () async {
      final recorder = _Recorder();
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: _answering([], _answer()),
      );

      final vectors = await embedder.embedStrings(
        ['hello world'],
        options: _with(recorder),
      );

      expect(recorder.timings, ['start', 'end']);
      expect(
        recorder.infos.single,
        const RunInfo(
          name: '',
          type: 'Ollama',
          componentType: ComponentType.embedder,
        ),
      );
      expect(recorder.input!.texts, ['hello world']);
      expect(recorder.input!.config!.model, _model);
      expect(recorder.output!.embeddings, vectors);
      expect(recorder.output!.config!.model, _model);
      expect(recorder.output!.tokenUsage!.totalTokens, 2);
      expect(recorder.output!.extra![ollamaPromptEvalCountKey], 2);
    });

    test('a failed call is reported to the error callback and rethrown',
        () async {
      final recorder = _Recorder();
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: _answering([], {'error': 'boom'}, status: 500),
      );

      await expectLater(
        embedder.embedStrings(['a'], options: _with(recorder)),
        throwsA(isA<OllamaException>()),
      );
      expect(recorder.timings, ['start', 'error']);
      expect(recorder.error, isA<OllamaException>());
    });

    test('global handlers hear a call that has no run context', () async {
      final recorder = _Recorder();
      GlobalCallbacks.append([recorder]);
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: _answering([], _answer()),
      );

      await embedder.embedStrings(['a']);

      expect(recorder.timings, ['start', 'end']);
      expect(recorder.infos.single.type, 'Ollama');
    });
  });

  group('component and lifecycle', () {
    test('type name and callback awareness (Go: GetType, IsCallbacksEnabled)',
        () {
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
      );
      expect(embedder.componentTypeName, 'Ollama');
      expect(embedder.isCallbacksEnabled, isTrue);
      expect(componentTypeNameOf(embedder), 'Ollama');
      expect(isCallbacksEnabled(embedder), isTrue);
      expect(embedder.config.baseUrl, 'http://localhost:11434');
      expect(embedder.config.toString(), contains(_model));
    });

    test('dispose leaves an injected client open', () async {
      final client = _RecordingClient();
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
        httpClient: client,
      );

      await embedder.embedStrings(['a']);
      embedder.dispose();

      expect(client.requests, 1);
      expect(client.isClosed, isFalse);
    });

    test('an embedder used after dispose throws a StateError', () async {
      final embedder = OllamaEmbedder(
        config: const OllamaEmbedderConfig(model: _model),
      );
      embedder.dispose();

      await expectLater(embedder.embedStrings(['a']), throwsStateError);
      embedder.dispose(); // safe to repeat
    });
  });
}
