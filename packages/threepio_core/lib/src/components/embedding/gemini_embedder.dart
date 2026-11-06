/// The Gemini embedder: eino-ext's `embedding/gemini` over the Gemini REST
/// API.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../core/interrupt_signal.dart';
import '../../internal/call_cancellation.dart';
import '../../internal/embedding_call_callbacks.dart';
import '../../internal/provider_http.dart';
import '../../internal/shared_http_client.dart';
import '../../schema/message.dart';
import '../component_type.dart';
import '../model/cancel_token.dart';
import '../model/providers/gemini/gemini_errors.dart';
import 'embedder.dart';

/// What the embeddings will be used for, so that the model can optimize them.
///
/// The task types of the Gemini API (genai `EmbedContentConfig.TaskType`).
enum GeminiEmbeddingTaskType {
  /// A search query, to be compared with documents.
  retrievalQuery('RETRIEVAL_QUERY'),

  /// A document of a search corpus.
  retrievalDocument('RETRIEVAL_DOCUMENT'),

  /// Text whose similarity to other text is measured.
  semanticSimilarity('SEMANTIC_SIMILARITY'),

  /// Text to be classified.
  classification('CLASSIFICATION'),

  /// Text to be clustered.
  clustering('CLUSTERING'),

  /// A question, to be compared with answers.
  questionAnswering('QUESTION_ANSWERING'),

  /// A statement, to be compared with evidence.
  factVerification('FACT_VERIFICATION'),

  /// A natural-language query for code.
  codeRetrievalQuery('CODE_RETRIEVAL_QUERY');

  const GeminiEmbeddingTaskType(this.wireValue);

  /// The value the REST API expects.
  final String wireValue;
}

/// The configuration of a [GeminiEmbedder].
///
/// Port of eino-ext `gemini.EmbeddingConfig`. Go's `Client` is replaced by
/// [apiKey], [baseUrl] and [timeout] (and the embedder's `httpClient`).
@immutable
final class GeminiEmbeddingConfig {
  /// A configuration for [model], authenticated with [apiKey].
  const GeminiEmbeddingConfig({
    required this.apiKey,
    required this.model,
    this.baseUrl = 'https://generativelanguage.googleapis.com/v1beta',
    this.timeout = const Duration(seconds: 120),
    this.taskType,
    this.title,
    this.outputDimensionality,
    this.mimeType,
    this.autoTruncate = false,
  });

  /// The API key.
  final String apiKey;

  /// The embedding model (Go `Model`), for example `gemini-embedding-001`.
  /// `EmbedderOptions.model` overrides it.
  final String model;

  /// The base URL of the Gemini API.
  final String baseUrl;

  /// How long a request may take until its response arrives.
  final Duration timeout;

  /// What the embeddings will be used for (Go `TaskType`).
  final GeminiEmbeddingTaskType? taskType;

  /// The title of the texts; only for [GeminiEmbeddingTaskType.retrievalDocument]
  /// (Go `Title`).
  final String? title;

  /// The number of dimensions of the vectors; the rest is cut off (Go
  /// `OutputDimensionality`). Newer models only.
  final int? outputDimensionality;

  /// The MIME type of the input (Go `MIMEType`). Only the Vertex AI backend
  /// accepts it; this embedder talks to the Gemini API, so a call with it
  /// fails as the genai SDK fails there.
  final String? mimeType;

  /// Whether too long inputs are cut silently (Go `AutoTruncate`). Only the
  /// Vertex AI backend accepts it; a call with it set fails as the genai SDK
  /// fails on the Gemini API.
  final bool autoTruncate;

  @override
  String toString() => 'GeminiEmbeddingConfig(baseUrl: $baseUrl, model: $model)';
}

/// Embeddings from Google's Gemini embedding models.
///
/// Port of eino-ext `gemini.Embedder` (`NewEmbedder`, `EmbedStrings`): every
/// text is one request of a `batchEmbedContents` call (what the genai SDK's
/// `EmbedContent` sends to the Gemini API). The call is reported to the
/// callback handlers of `options.runContext` (start with the texts and the
/// model, end with the vectors and the token usage when the API reports it)
/// and can be cancelled through that context's cancel token.
///
/// ```dart
/// final embedder = GeminiEmbedder(
///   config: GeminiEmbeddingConfig(
///     apiKey: apiKey,
///     model: 'gemini-embedding-001',
///     taskType: GeminiEmbeddingTaskType.retrievalDocument,
///     outputDimensionality: 768,
///   ),
/// );
/// final vectors = await embedder.embedStrings(['hello', 'world']);
/// ```
class GeminiEmbedder
    implements Embedder, TypedComponent, CallbackAwareComponent {
  /// An embedder with [config]. Requests go through [httpClient] when one is
  /// given.
  GeminiEmbedder({required this.config, this.httpClient})
      : _http = SharedHttpClient(httpClient, owner: 'GeminiEmbedder');

  /// The configuration.
  final GeminiEmbeddingConfig config;

  /// HTTP client for making requests.
  ///
  /// When omitted, the embedder creates one client on first use, reuses it
  /// for every request and closes it in [dispose].
  final http.Client? httpClient;

  final SharedHttpClient _http;

  /// Releases the HTTP client this embedder created for itself.
  ///
  /// Using the embedder afterwards throws a [StateError]. A client passed as
  /// [httpClient] is left open: whoever created it closes it.
  void dispose() => _http.close();

  /// Port of eino-ext `Embedder.GetType`.
  @override
  String get componentTypeName => 'Gemini';

  /// The embedder reports its calls to the callback handlers itself.
  ///
  /// Port of eino-ext `Embedder.IsCallbacksEnabled`.
  @override
  bool get isCallbacksEnabled => true;

  /// The vectors of [texts], in their order.
  ///
  /// Throws a [GeminiException] when the API answers with an error or cannot
  /// be reached, a [CancelledException] when the run context's token is
  /// cancelled, and an [ArgumentError] when the configuration asks for
  /// [GeminiEmbeddingConfig.mimeType] or [GeminiEmbeddingConfig.autoTruncate]
  /// or names no model.
  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) =>
      EmbeddingCallCallbacks.run(
        options,
        typeName: componentTypeName,
        texts: texts,
        defaultModel: config.model,
        embed: () => _embed(texts, options),
      );

  Future<EmbeddingResult> _embed(
    List<String> texts,
    EmbedderOptions? options,
  ) async {
    // The genai SDK refuses these two for the Gemini API.
    final mimeType = config.mimeType;
    if (mimeType != null && mimeType.isNotEmpty) {
      throw ArgumentError.value(
        mimeType,
        'mimeType',
        'mimeType parameter is not supported in Gemini API',
      );
    }
    if (config.autoTruncate) {
      throw ArgumentError.value(
        true,
        'autoTruncate',
        'autoTruncate parameter is not supported in Gemini API',
      );
    }
    final model = options?.model ?? config.model;
    if (model.isEmpty) {
      throw ArgumentError.value(model, 'model', 'model is empty');
    }
    if (texts.isEmpty) return (vectors: <List<double>>[], usage: null);

    final resource = model.startsWith('models/') || model.startsWith('tunedModels/')
        ? model
        : 'models/$model';
    final title = config.title;
    final body = jsonEncode({
      'requests': [
        for (final text in texts)
          {
            'model': resource,
            'content': {
              'parts': [
                {'text': text},
              ],
              'role': 'user',
            },
            if (config.taskType != null) 'taskType': config.taskType!.wireValue,
            if (title != null && title.isNotEmpty) 'title': title,
            if (config.outputDimensionality != null)
              'outputDimensionality': config.outputDimensionality,
          },
      ],
    });

    final cancellation =
        CallCancellation(null, options?.runContext?.cancelToken);
    try {
      final json = await _post(
        Uri.parse('${config.baseUrl}/$resource:batchEmbedContents'),
        body,
        cancellation.token,
      );
      return _parse(json, texts.length);
    } finally {
      cancellation.release();
    }
  }

  Future<Map<String, dynamic>> _post(
    Uri url,
    String body,
    CancelToken? cancelToken,
  ) async {
    // Outside the try: using a disposed embedder is a programming error,
    // not a failed request.
    final client = _http.client;

    final http.Response response;
    try {
      response = await sendRequest(
        client,
        url,
        headers: {
          'Content-Type': 'application/json',
          if (config.apiKey.isNotEmpty) 'x-goog-api-key': config.apiKey,
        },
        body: body,
        timeout: config.timeout,
        cancelToken: cancelToken,
      );
    } on TimeoutException {
      throw GeminiException(
        'Request timed out after ${config.timeout}',
        isRetryable: true,
        isModelUnavailable: false,
      );
    } on CancelledException {
      rethrow;
    } catch (error) {
      if (isInterrupt(error)) rethrow;
      throw GeminiException(
        'Request failed: $error',
        cause: error,
        isRetryable: true,
        isModelUnavailable: false,
      );
    }

    if (response.statusCode != 200) {
      throw GeminiException.fromHttp(response.statusCode, response.body);
    }
    try {
      final json = jsonDecode(response.body);
      if (json is Map<String, dynamic>) return json;
    } on FormatException catch (error) {
      throw GeminiException(
        'Response is not JSON: ${error.message}',
        statusCode: response.statusCode,
        cause: error,
      );
    }
    throw GeminiException(
      'Response is not a JSON object',
      statusCode: response.statusCode,
    );
  }

  /// The vectors and the usage of a `batchEmbedContents` response.
  ///
  /// The usage is the sum of the `statistics.tokenCount` of the embeddings,
  /// when the API reports them (Go sums them the same way).
  static EmbeddingResult _parse(Map<String, dynamic> json, int expected) {
    final embeddings = json['embeddings'];
    final list = embeddings is List ? embeddings : const <Object?>[];
    if (list.length != expected) {
      throw GeminiException(
        'Gemini returned ${list.length} embeddings for $expected texts',
      );
    }
    final vectors = <List<double>>[];
    int? promptTokens;
    for (final embedding in list) {
      final values = embedding is Map ? embedding['values'] : null;
      vectors.add([
        for (final value in values is List ? values : const <Object?>[])
          if (value is num)
            value.toDouble()
          else
            throw GeminiException('Embedding value is not a number: $value'),
      ]);
      final statistics = embedding is Map ? embedding['statistics'] : null;
      final tokens = statistics is Map ? statistics['tokenCount'] : null;
      if (tokens is num) promptTokens = (promptTokens ?? 0) + tokens.toInt();
    }
    return (
      vectors: vectors,
      usage: promptTokens == null
          ? null
          : TokenUsage(
              promptTokens: promptTokens,
              completionTokens: 0,
              totalTokens: promptTokens,
            ),
    );
  }
}
