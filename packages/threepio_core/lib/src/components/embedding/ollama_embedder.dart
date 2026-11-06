/// The Ollama embedder.
///
/// Port of eino-ext `components/embedding/ollama/embedding.go`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../core/interrupt_signal.dart';
import '../../internal/embedding_call_callbacks.dart';
import '../../internal/provider_http.dart';
import '../../internal/shared_http_client.dart';
import '../../schema/message.dart';
import '../component_type.dart';
import '../model/cancel_token.dart';
import '../model/providers/ollama/ollama_chat_model.dart';
import '../model/providers/ollama/ollama_config.dart';
import '../model/providers/ollama/ollama_converters.dart';
import 'embedder.dart';

/// The key of the request's total duration, in nanoseconds, in the `extra`
/// of an [OllamaEmbedder]'s callback output.
///
/// Port of eino-ext `ollama.TotalDuration` (Go's comment says milliseconds;
/// the value is Ollama's `time.Duration`, nanoseconds).
const String ollamaTotalDurationKey = 'total_duration';

/// The key of the model's load duration, in nanoseconds, in the `extra` of
/// an [OllamaEmbedder]'s callback output.
///
/// Port of eino-ext `ollama.LoadDuration`.
const String ollamaLoadDurationKey = 'load_duration';

/// The key of the number of prompt tokens in the `extra` of an
/// [OllamaEmbedder]'s callback output.
///
/// Port of eino-ext `ollama.PromptEvalCount`.
const String ollamaPromptEvalCountKey = 'prompt_eval_count';

/// Configuration of an [OllamaEmbedder].
///
/// Port of eino-ext `ollama.EmbeddingConfig`. Go's `HTTPClient` is the
/// embedder's `httpClient` constructor parameter.
@immutable
final class OllamaEmbedderConfig {
  /// The configuration of an embedder that uses [model] on the Ollama server
  /// at [baseUrl].
  const OllamaEmbedderConfig({
    required this.model,
    this.baseUrl = OllamaConfig.defaultBaseUrl,
    this.timeout,
    this.truncate,
    this.keepAlive,
    this.options,
  });

  /// The address of the Ollama server (Go: `BaseURL`), without `/api`.
  /// Defaults to `http://localhost:11434`; an empty string means the same.
  final String baseUrl;

  /// The embedding model (Go: `Model`), `nomic-embed-text` for example. A
  /// call can name another one in `EmbedderOptions.model`.
  final String model;

  /// The longest wait for the response (Go: `Timeout`). `null`, the
  /// default, waits as long as it takes, as Go's zero `Timeout` does.
  final Duration? timeout;

  /// Whether input longer than the model's context is cut to fit (Go:
  /// `Truncate`). With `false` such input fails the request. `null` leaves
  /// the server's default (`true`).
  final bool? truncate;

  /// How long the model stays loaded after the request (Go: `KeepAlive`).
  /// [Duration.zero] unloads it at once, a negative duration keeps it loaded
  /// indefinitely, `null` leaves the server's default (five minutes).
  final Duration? keepAlive;

  /// Model options (Go: `Options`), as Ollama names them: `{'num_ctx':
  /// 8192}`.
  final Map<String, Object?>? options;

  @override
  String toString() =>
      'OllamaEmbedderConfig(baseUrl: $baseUrl, model: $model)';
}

/// Embeds texts with a model served by Ollama (`POST /api/embed`).
///
/// Port of eino-ext `ollama.Embedder` (`NewEmbedder`, `EmbedStrings`,
/// `GetType`, `IsCallbacksEnabled`). Failed requests throw an
/// [OllamaException].
///
/// ```dart
/// final embedder = OllamaEmbedder(
///   config: const OllamaEmbedderConfig(model: 'nomic-embed-text'),
/// );
/// final vectors = await embedder.embedStrings(['hello world']);
/// embedder.dispose();
/// ```
class OllamaEmbedder
    implements Embedder, TypedComponent, CallbackAwareComponent {
  /// An embedder configured by [config].
  ///
  /// [httpClient] replaces the client the embedder would create for itself
  /// (Go: `EmbeddingConfig.HTTPClient`). Throws an [ArgumentError] when
  /// `config.baseUrl` is not a valid URL (Go: "invalid base URL").
  OllamaEmbedder({required this.config, this.httpClient})
      : _http = SharedHttpClient(httpClient, owner: 'OllamaEmbedder'),
        _embedUrl = OllamaConverters.endpoint(config.baseUrl, '/api/embed');

  /// The configuration.
  final OllamaEmbedderConfig config;

  /// The HTTP client the requests are sent with (tests inject a fake).
  ///
  /// When omitted, the embedder creates one client on first use, reuses it
  /// for every request and closes it in [dispose].
  final http.Client? httpClient;

  final SharedHttpClient _http;
  final Uri _embedUrl;

  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  /// Go's zero `Timeout` means no limit. The request helper needs a
  /// duration; 24 days stays below the longest timer every platform runs.
  static const Duration _noTimeout = Duration(days: 24);

  /// Releases the HTTP client this embedder created for itself.
  ///
  /// Call it when the embedder is no longer needed; using it afterwards
  /// throws a [StateError]. A client passed as [httpClient] is left open:
  /// whoever created it closes it.
  void dispose() => _http.close();

  /// `Ollama` (Go: `GetType`).
  @override
  String get componentTypeName => 'Ollama';

  /// The embedder reports its calls to the callback handlers of
  /// `options.runContext` (and to the global ones) itself (Go:
  /// `IsCallbacksEnabled`).
  @override
  bool get isCallbacksEnabled => true;

  /// One vector for each of [texts], in their order.
  ///
  /// Port of `Embedder.EmbedStrings`. The model is the one of [options], or
  /// the configured one. The callback output's `extra` holds Ollama's
  /// durations and prompt token count under [ollamaTotalDurationKey],
  /// [ollamaLoadDurationKey] and [ollamaPromptEvalCountKey], as in Go; the
  /// prompt token count is also its token usage. The call is cancelled
  /// through the token of `options.runContext`.
  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) {
    final keepAlive = config.keepAlive;
    final truncate = config.truncate;
    final body = <String, Object?>{
      'model': options?.model ?? config.model,
      'input': [...texts],
      if (keepAlive != null)
        'keep_alive': OllamaConverters.keepAliveToJson(keepAlive),
      if (truncate != null) 'truncate': truncate,
      'options': config.options,
    };
    Map<String, Object?>? extra;
    return EmbeddingCallCallbacks.run(
      options,
      typeName: componentTypeName,
      texts: texts,
      defaultModel: config.model,
      embed: () async {
        final response =
            await _embed(body, options?.runContext?.cancelToken);
        extra = response.extra;
        return (vectors: response.vectors, usage: response.usage);
      },
      outputExtra: () => extra,
    );
  }

  Future<OllamaEmbedResponse> _embed(
    Map<String, Object?> body,
    CancelToken? cancelToken,
  ) async {
    // Outside the try: using a disposed embedder is a programming error, not
    // a failed request.
    final client = _http.client;
    final timeout = config.timeout ?? _noTimeout;
    final http.Response response;
    try {
      response = await sendRequest(
        client,
        _embedUrl,
        headers: _headers,
        body: jsonEncode(body),
        timeout: timeout,
        cancelToken: cancelToken,
      );
    } on TimeoutException {
      throw OllamaException(
        'Request timed out after $timeout',
        isRetryable: true,
      );
    } on CancelledException {
      rethrow;
    } on Exception catch (error) {
      if (isInterrupt(error)) rethrow;
      throw OllamaException(
        'Request failed: $error',
        isRetryable: true,
        cause: error,
      );
    }

    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode >= 400) {
      throw OllamaException.fromHttp(response.statusCode, text);
    }
    return parseEmbedResponse(text);
  }

  /// The vectors, token usage and callback extra of an `/api/embed` answer.
  /// An empty body has no vectors and zero metrics, as in Go. Public in
  /// `src/` for the tests.
  @internal
  static OllamaEmbedResponse parseEmbedResponse(String body) {
    if (body.trim().isEmpty) {
      return (
        vectors: <List<double>>[],
        usage: null,
        extra: _extraOf(const {}),
      );
    }
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException catch (error) {
      throw OllamaException(
        'Malformed Ollama embed response: ${error.message}',
        cause: error,
      );
    }
    if (json is! Map) throw _malformed('the answer is not a JSON object');
    final embeddings = json['embeddings'] ?? const <Object?>[];
    if (embeddings is! List) throw _malformed('"embeddings" is not a list');
    final vectors = <List<double>>[];
    for (final vector in embeddings) {
      if (vector is! List) throw _malformed('a vector is not a list');
      vectors.add([
        for (final value in vector)
          if (value is num)
            value.toDouble()
          else
            throw _malformed('a vector holds a value that is not a number'),
      ]);
    }
    final promptTokens = json['prompt_eval_count'];
    return (
      vectors: vectors,
      usage: promptTokens is num
          ? TokenUsage(
              promptTokens: promptTokens.toInt(),
              completionTokens: 0,
              totalTokens: promptTokens.toInt(),
            )
          : null,
      extra: _extraOf(json),
    );
  }

  /// Go's callback extra: the durations (nanoseconds) and the prompt token
  /// count, zero when Ollama left them out.
  static Map<String, Object?> _extraOf(Map<Object?, Object?> json) {
    int value(String key) {
      final number = json[key];
      return number is num ? number.toInt() : 0;
    }

    return {
      ollamaTotalDurationKey: value(ollamaTotalDurationKey),
      ollamaLoadDurationKey: value(ollamaLoadDurationKey),
      ollamaPromptEvalCountKey: value(ollamaPromptEvalCountKey),
    };
  }

  static OllamaException _malformed(String reason) =>
      OllamaException('Malformed Ollama embed response: $reason');
}

/// What [OllamaEmbedder.parseEmbedResponse] reads from an `/api/embed`
/// answer: the vectors, the token usage and the callback extra.
@internal
typedef OllamaEmbedResponse = ({
  List<List<double>> vectors,
  TokenUsage? usage,
  Map<String, Object?> extra,
});
