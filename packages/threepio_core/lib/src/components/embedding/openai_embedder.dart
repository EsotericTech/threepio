import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../callbacks/callback_handler.dart';
import '../../callbacks/callback_manager.dart';
import '../../callbacks/run_info.dart';
import '../model/providers/openai/openai_config.dart';
import 'embedder.dart';

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
class OpenAIEmbedder implements Embedder {
  OpenAIEmbedder({
    required this.config,
    this.httpClient,
    this.defaultModel = 'text-embedding-3-small',
  });

  /// OpenAI configuration
  final OpenAIConfig config;

  /// HTTP client for making requests
  final http.Client? httpClient;

  /// Default embedding model
  final String defaultModel;

  /// Get or create HTTP client
  http.Client get _client => httpClient ?? http.Client();

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

  /// Internal embedding implementation
  Future<List<List<double>>> _embedStringsInternal(
    List<String> texts,
    EmbedderOptions? options,
  ) async {
    final model = options?.model ?? defaultModel;

    // Build request body
    final requestBody = <String, dynamic>{
      'input': texts,
      'model': model,
    };

    // Add extra options
    if (options?.extra != null) {
      for (final entry in options!.extra!.entries) {
        requestBody[entry.key] = entry.value;
      }
    }

    // Make API call
    final response = await _makeRequest(requestBody);

    // Parse embeddings from response
    return _parseEmbeddingsResponse(response);
  }

  /// Make API request
  Future<Map<String, dynamic>> _makeRequest(
    Map<String, dynamic> requestBody,
  ) async {
    final url = Uri.parse('${config.baseUrl}/embeddings');
    final headers = _buildHeaders();

    try {
      final response = await _client
          .post(
            url,
            headers: headers,
            body: jsonEncode(requestBody),
          )
          .timeout(config.timeout);

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
      final embedding = item['embedding'] as List<dynamic>;
      embeddings.add(
        embedding.map((e) => (e as num).toDouble()).toList(),
      );
    }

    return embeddings;
  }

  /// Build request headers
  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${config.apiKey}',
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
        await Future.delayed(const Duration(milliseconds: 100));
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
    return EmbedderOptions(
      model: model,
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
class OpenAIEmbedderException implements Exception {
  OpenAIEmbedderException(
    this.message, {
    this.statusCode,
    this.response,
  });

  final String message;
  final int? statusCode;
  final String? response;

  @override
  String toString() =>
      'OpenAIEmbedderException: $message${statusCode != null ? ' (status: $statusCode)' : ''}';
}
