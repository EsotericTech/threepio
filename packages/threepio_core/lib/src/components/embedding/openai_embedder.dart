import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../callbacks/callback_manager.dart';
import '../../callbacks/run_info.dart';
import '../../errors.dart';
import '../../internal/embedding_call_callbacks.dart';
import '../../internal/provider_http.dart';
import '../../internal/shared_http_client.dart';
import '../../schema/message.dart';
import '../component_type.dart';
import '../model/cancel_token.dart';
import '../model/openai_compatible/client.dart';
import '../model/providers/openai/openai_config.dart';
import 'embedder.dart';

/// The format OpenAI-compatible APIs return vectors in.
///
/// Port of eino-ext `openai.EmbeddingEncodingFormat`. Either way the
/// embedder returns doubles: `base64` vectors (little-endian float32) are
/// decoded.
enum EmbeddingEncodingFormat {
  /// JSON numbers.
  float,

  /// Base64-encoded little-endian float32 values.
  base64,
}

/// OpenAI embeddings implementation
///
/// Supports OpenAI's embedding models:
/// - text-embedding-3-small (1536 dimensions, fast & efficient)
/// - text-embedding-3-large (3072 dimensions, higher quality)
/// - text-embedding-ada-002 (1536 dimensions, legacy)
///
/// Example usage:
/// ```dart
/// final config = OpenAIConfig(apiKey: 'your-api-key');
/// final embedder = OpenAIEmbedder(config: config);
///
/// // Embed single text
/// final embeddings = await embedder.embedStrings(['Hello world']);
/// print('Dimensions: ${embeddings.first.length}');
///
/// // Embed multiple texts
/// final batch = await embedder.embedStrings([
///   'First document',
///   'Second document',
///   'Third document',
/// ]);
/// ```
///
/// Port of eino-ext `embedding/openai` (over `libs/acl/openai`
/// `EmbeddingClient`): [dimensions], [encodingFormat] and [user] are Go's
/// `EmbeddingConfig` fields, Azure routing comes from `config.byAzure`, and
/// each call reports to the callback handlers of `options.runContext` (and
/// the global ones) with the token usage. [OpenAIEmbedder.dashScope] is
/// eino-ext's `embedding/dashscope`.
class OpenAIEmbedder implements Embedder, TypedComponent, CallbackAwareComponent {
  OpenAIEmbedder({
    required this.config,
    this.httpClient,
    this.defaultModel = 'text-embedding-3-small',
    this.dimensions,
    this.encodingFormat = EmbeddingEncodingFormat.float,
    this.user,
  })  : componentTypeName = 'OpenAI',
        _http = SharedHttpClient(httpClient, owner: 'OpenAIEmbedder');

  /// Alibaba DashScope's text embeddings through its OpenAI-compatible mode
  /// (`https://dashscope.aliyuncs.com/compatible-mode/v1`).
  ///
  /// Port of eino-ext `dashscope.NewEmbedder`: [dimensions] defaults to
  /// 1024 and vectors are requested as floats.
  OpenAIEmbedder.dashScope({
    required String apiKey,
    required String model,
    int dimensions = 1024,
    Duration timeout = const Duration(seconds: 60),
    this.httpClient,
  })  : config = OpenAIConfig(
          apiKey: apiKey,
          baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
          defaultModel: model,
          timeout: timeout,
        ),
        defaultModel = model,
        dimensions = dimensions,
        encodingFormat = EmbeddingEncodingFormat.float,
        user = null,
        componentTypeName = 'DashScope',
        _http = SharedHttpClient(httpClient, owner: 'OpenAIEmbedder');

  /// OpenAI configuration
  final OpenAIConfig config;

  /// HTTP client for making requests.
  ///
  /// When omitted, the embedder creates one client on first use, reuses it
  /// for every request and closes it in [dispose].
  final http.Client? httpClient;

  /// Default embedding model
  final String defaultModel;

  /// The number of dimensions of the vectors (models that support it).
  final int? dimensions;

  /// The format the vectors are requested in.
  final EmbeddingEncodingFormat encodingFormat;

  /// An id for the end user, for abuse monitoring.
  final String? user;

  /// `OpenAI`, or `DashScope` for [OpenAIEmbedder.dashScope] (Go
  /// `GetType()`).
  @override
  final String componentTypeName;

  /// The embedder reports its calls to callback handlers itself.
  @override
  bool get isCallbacksEnabled => true;

  final SharedHttpClient _http;

  http.Client get _client => _http.client;

  /// Releases the HTTP client this embedder created for itself.
  ///
  /// Call it when the embedder is no longer needed; using it afterwards throws
  /// a [StateError]. A client passed as [httpClient] is left open: whoever created it
  /// closes it.
  void dispose() => _http.close();

  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async {
    if (texts.isEmpty) {
      return [];
    }

    // Get callback manager if available
    final callbackManager = options?.callbackManager as CallbackManager?;

    if (callbackManager != null) {
      // Execute with callbacks
      final runInfo = RunInfo(
        name: 'OpenAIEmbedder',
        type: 'OpenAIEmbedder',
        componentType: ComponentType.embedder,
        metadata: {
          'model': options?.model ?? defaultModel,
          'batch_size': texts.length,
          ...?options?.extra,
        },
      );

      return await callbackManager.runWithCallbacks(
        options?.context ?? {},
        runInfo,
        texts,
        () => _embedStringsInternal(texts, options),
      );
    } else {
      // Execute without callbacks
      return _embedStringsInternal(texts, options);
    }
  }

  /// Internal embedding implementation: the call reported to the callback
  /// handlers of its run context.
  Future<List<List<double>>> _embedStringsInternal(
    List<String> texts,
    EmbedderOptions? options,
  ) {
    final model = options?.model ?? defaultModel;
    return EmbeddingCallCallbacks.run(
      options,
      typeName: componentTypeName,
      texts: texts,
      defaultModel: defaultModel,
      encodingFormat: encodingFormat.name,
      embed: () async {
        final requestBody = <String, dynamic>{
          'input': texts,
          'model': model,
          'encoding_format': encodingFormat.name,
          if (dimensions != null && dimensions != 0) 'dimensions': dimensions,
          if (user != null && user!.isNotEmpty) 'user': user,
        };
        // Add extra options, except the two entries `withCallbacks` keeps
        // there for the older callback API (they are not request fields).
        if (options?.extra != null) {
          for (final entry in options!.extra!.entries) {
            if (entry.key == 'callbackManager' || entry.key == 'context') {
              continue;
            }
            requestBody[entry.key] = entry.value;
          }
        }
        final response = await _makeRequest(
          requestBody,
          model,
          options?.runContext?.cancelToken,
        );
        return (
          vectors: _parseEmbeddingsResponse(response),
          usage: _usage(response['usage']),
        );
      },
    );
  }

  static TokenUsage? _usage(Object? raw) {
    if (raw is! Map) return null;
    final prompt = (raw['prompt_tokens'] as num?)?.toInt() ?? 0;
    return TokenUsage(
      promptTokens: prompt,
      completionTokens: (raw['completion_tokens'] as num?)?.toInt() ?? 0,
      totalTokens: (raw['total_tokens'] as num?)?.toInt() ?? prompt,
    );
  }

  /// Make API request
  Future<Map<String, dynamic>> _makeRequest(
    Map<String, dynamic> requestBody,
    String model,
    CancelToken? cancelToken,
  ) async {
    final endpoint = OpenAIEndpoint(
      baseUrl: config.baseUrl,
      byAzure: config.byAzure,
      apiVersion: config.apiVersion,
      azureModelMapper: config.azureModelMapper,
    );
    final url = endpoint.url('/embeddings', model);
    final headers = _buildHeaders();

    // Outside the try: using a disposed embedder is a programming error,
    // not a failed request.
    final client = _client;

    try {
      final response = await sendRequest(
        client,
        url,
        headers: headers,
        body: jsonEncode(requestBody),
        timeout: config.timeout,
        cancelToken: cancelToken,
      );

      if (response.statusCode != 200) {
        throw OpenAIEmbedderException(
          'API request failed with status ${response.statusCode}: ${response.body}',
          statusCode: response.statusCode,
          response: response.body,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    } on TimeoutException {
      throw OpenAIEmbedderException(
        'Request timed out after ${config.timeout}',
      );
    } on CancelledException {
      rethrow;
    } catch (e) {
      if (e is OpenAIEmbedderException) rethrow;
      throw OpenAIEmbedderException('Request failed: $e');
    }
  }

  /// Parse embeddings from API response
  List<List<double>> _parseEmbeddingsResponse(Map<String, dynamic> response) {
    final data = response['data'] as List<dynamic>?;

    if (data == null || data.isEmpty) {
      throw OpenAIEmbedderException('No embeddings in response');
    }

    // Sort by index to ensure correct order
    final sortedData = List<Map<String, dynamic>>.from(data)
      ..sort((a, b) {
        final indexA = a['index'] as int;
        final indexB = b['index'] as int;
        return indexA.compareTo(indexB);
      });

    // Extract embedding vectors
    final embeddings = <List<double>>[];
    for (final item in sortedData) {
      final embedding = item['embedding'];
      embeddings.add(
        embedding is String
            ? decodeBase64Embedding(embedding)
            : [for (final e in embedding as List) (e as num).toDouble()],
      );
    }

    return embeddings;
  }

  /// The doubles of a base64 vector of little-endian float32 values, as
  /// go-openai decodes `encoding_format: base64`.
  static List<double> decodeBase64Embedding(String encoded) {
    final bytes = base64Decode(encoded);
    if (bytes.length % 4 != 0) {
      throw OpenAIEmbedderException(
        'base64 embedding has ${bytes.length} bytes, not a multiple of 4',
      );
    }
    final data = ByteData.sublistView(bytes);
    return [
      for (var i = 0; i < bytes.length; i += 4)
        data.getFloat32(i, Endian.little),
    ];
  }

  /// Build request headers
  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      ...(config.byAzure
          ? {'api-key': config.apiKey}
          : {'Authorization': 'Bearer ${config.apiKey}'}),
      ...?config.customHeaders,
    };

    if (config.organization != null) {
      headers['OpenAI-Organization'] = config.organization!;
    }

    return headers;
  }

  /// Get embedding dimensions for a model
  ///
  /// Returns the number of dimensions in the embedding vector for the
  /// specified model. Useful for initializing vector stores.
  static int getDimensionsForModel(String model) {
    switch (model) {
      case 'text-embedding-3-large':
        return 3072;
      case 'text-embedding-3-small':
      case 'text-embedding-ada-002':
        return 1536;
      default:
        throw ArgumentError('Unknown embedding model: $model');
    }
  }

  /// Batch embed with automatic chunking
  ///
  /// OpenAI has a limit on batch size (typically 2048 texts or 8191 tokens per request).
  /// This method automatically chunks large batches.
  Future<List<List<double>>> embedStringsChunked(
    List<String> texts, {
    EmbedderOptions? options,
    int chunkSize = 100,
  }) async {
    if (texts.length <= chunkSize) {
      return embedStrings(texts, options: options);
    }

    // Process in chunks
    final allEmbeddings = <List<double>>[];

    for (var i = 0; i < texts.length; i += chunkSize) {
      final end = (i + chunkSize < texts.length) ? i + chunkSize : texts.length;
      final chunk = texts.sublist(i, end);

      final embeddings = await embedStrings(chunk, options: options);
      allEmbeddings.addAll(embeddings);

      // Small delay to avoid rate limiting
      if (end < texts.length) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    return allEmbeddings;
  }
}

/// Extension to EmbedderOptions for OpenAI-specific options
extension OpenAIEmbedderOptions on EmbedderOptions {
  /// Create options with callback support
  EmbedderOptions withCallbacks({
    required dynamic callbackManager,
    Map<String, dynamic>? context,
  }) {
    return copyWith(
      extra: {
        ...?extra,
        'callbackManager': callbackManager,
        'context': context,
      },
    );
  }

  /// Get callback manager from options
  dynamic get callbackManager => extra?['callbackManager'];

  /// Get context from options
  Map<String, dynamic>? get context =>
      extra?['context'] as Map<String, dynamic>?;
}

/// OpenAI Embedder exception
class OpenAIEmbedderException implements ThreepioException {
  OpenAIEmbedderException(
    this.message, {
    this.statusCode,
    this.response,
  });

  @override
  final String message;
  final int? statusCode;
  final String? response;

  @override
  Object? get cause => null;

  @override
  String toString() =>
      'OpenAIEmbedderException: $message${statusCode != null ? ' (status: $statusCode)' : ''}';
}
