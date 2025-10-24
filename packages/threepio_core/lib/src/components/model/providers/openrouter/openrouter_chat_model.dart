import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../callbacks/callback_manager.dart';
import '../../../../callbacks/run_info.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import '../../../../streaming/stream_reader.dart';
import '../../../../streaming/stream_utils.dart';
import '../../../../streaming/stream_writer.dart';
import '../../base_chat_model.dart';
import '../../chat_model_options.dart';
import '../openai/openai_converters.dart';
import 'openrouter_config.dart';
import 'openrouter_response_parser.dart';

/// OpenRouter chat model implementation
///
/// OpenRouter (https://openrouter.ai) is a unified API gateway that provides
/// access to multiple LLM providers through a single OpenAI-compatible interface.
///
/// This implementation supports:
/// - Standard text generation from various providers
/// - Image generation (e.g., via Gemini, DALL-E)
/// - Streaming responses
/// - Tool calling
/// - Multi-modal outputs
///
/// Example usage:
/// ```dart
/// final config = OpenRouterConfig(
///   apiKey: 'your-api-key',
///   siteName: 'My App',
///   siteUrl: 'https://myapp.com',
/// );
///
/// final model = OpenRouterChatModel(config: config);
///
/// // Text generation
/// final messages = [Message.user('What is the capital of France?')];
/// final response = await model.generate(messages);
/// print(response.content); // "The capital of France is Paris."
///
/// // Image generation
/// final imageMessages = [Message.user('Generate an image of a sunset')];
/// final imageResponse = await model.generate(
///   imageMessages,
///   options: ChatModelOptions(model: 'google/gemini-2.5-flash-image'),
/// );
/// final imageContent = imageResponse.assistantGenMultiContent?.first;
/// ```
class OpenRouterChatModel extends ToolCallingChatModel {
  OpenRouterChatModel({
    required this.config,
    this.httpClient,
    this.tools,
    this.responseParser = const OpenRouterResponseParser(),
  });

  /// OpenRouter configuration
  final OpenRouterConfig config;

  /// HTTP client for making requests
  final http.Client? httpClient;

  /// Tools bound to this model instance
  final List<ToolInfo>? tools;

  /// Response parser for handling API responses
  final OpenRouterResponseParser responseParser;

  /// Get or create HTTP client
  http.Client get _client => httpClient ?? http.Client();

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    // Merge options with tools if bound
    final mergedOptions = _mergeOptions(options);

    // Get callback manager if available
    final callbackManager = mergedOptions.callbackManager as CallbackManager?;

    if (callbackManager != null) {
      // Execute with callbacks
      final runInfo = RunInfo(
        name: 'OpenRouterChatModel',
        type: 'OpenRouterChatModel',
        componentType: ComponentType.chatModel,
        metadata: {
          'model': mergedOptions.model ?? config.defaultModel,
          ...?mergedOptions.metadata,
        },
      );

      return await callbackManager.runWithCallbacks(
        mergedOptions.getOrCreateContext(),
        runInfo,
        input,
        () async {
          // Build request body
          final requestBody = _buildRequestBody(
            input,
            mergedOptions,
            stream: false,
          );

          // Make API call
          final response = await _makeRequest(requestBody);

          // Parse response
          return responseParser.parseCompletionResponse(response);
        },
      );
    } else {
      // Execute without callbacks
      final requestBody = _buildRequestBody(
        input,
        mergedOptions,
        stream: false,
      );

      final response = await _makeRequest(requestBody);
      return responseParser.parseCompletionResponse(response);
    }
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    // Merge options with tools if bound
    final mergedOptions = _mergeOptions(options);

    // Build request body
    final requestBody = _buildRequestBody(
      input,
      mergedOptions,
      stream: true,
    );

    // Make streaming API call
    final stream = await _makeStreamingRequest(requestBody);

    return stream;
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) {
    return OpenRouterChatModel(
      config: config,
      httpClient: httpClient,
      tools: tools,
      responseParser: responseParser,
    );
  }

  /// Merge options with bound tools
  ChatModelOptions _mergeOptions(ChatModelOptions? options) {
    if (tools == null || tools!.isEmpty) {
      return options ?? const ChatModelOptions();
    }

    final baseOptions = ChatModelOptions(tools: tools);
    return options == null ? baseOptions : baseOptions.merge(options);
  }

  /// Build request body for API call
  Map<String, dynamic> _buildRequestBody(
    List<Message> messages,
    ChatModelOptions options, {
    required bool stream,
  }) {
    final body = <String, dynamic>{
      'model': options.model ?? config.defaultModel,
      'messages': messages.map(OpenAIConverters.messageToOpenAI).toList(),
      'stream': stream,
    };

    // Add optional parameters
    if (options.temperature != null) {
      body['temperature'] = options.temperature;
    }
    if (options.maxTokens != null) {
      body['max_tokens'] = options.maxTokens;
    }
    if (options.topP != null) {
      body['top_p'] = options.topP;
    }
    if (options.stop != null && options.stop!.isNotEmpty) {
      body['stop'] = options.stop;
    }

    // Add tools if present
    if (options.tools != null && options.tools!.isNotEmpty) {
      body['tools'] = options.tools!
          .map((t) => OpenAIConverters.toolInfoToOpenAI(t))
          .toList();

      // Add tool choice if specified
      if (options.toolChoice != null) {
        body['tool_choice'] =
            OpenAIConverters.toolChoiceToOpenAI(options.toolChoice!);
      }
    }

    // Add OpenRouter-specific transforms
    if (config.transforms != null) {
      body['transforms'] = config.transforms;
    }

    // Add extra options
    if (options.extra != null) {
      body.addAll(options.extra!);
    }

    return body;
  }

  /// Make API request
  Future<Map<String, dynamic>> _makeRequest(
    Map<String, dynamic> requestBody,
  ) async {
    final url = Uri.parse('${config.baseUrl}/chat/completions');
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
        throw OpenRouterException(
          'API request failed with status ${response.statusCode}: ${response.body}',
          statusCode: response.statusCode,
          response: response.body,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    } on TimeoutException {
      throw OpenRouterException('Request timed out after ${config.timeout}');
    } catch (e) {
      if (e is OpenRouterException) rethrow;
      throw OpenRouterException('Request failed: $e');
    }
  }

  /// Make streaming API request
  Future<StreamReader<Message>> _makeStreamingRequest(
    Map<String, dynamic> requestBody,
  ) async {
    final url = Uri.parse('${config.baseUrl}/chat/completions');
    final headers = _buildHeaders();

    try {
      final request = http.Request('POST', url)
        ..headers.addAll(headers)
        ..body = jsonEncode(requestBody);

      final response = await _client.send(request).timeout(config.timeout);

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw OpenRouterException(
          'API request failed with status ${response.statusCode}: $body',
          statusCode: response.statusCode,
          response: body,
        );
      }

      // Create stream reader from HTTP stream
      return _createStreamReader(response.stream);
    } on TimeoutException {
      throw OpenRouterException('Request timed out after ${config.timeout}');
    } catch (e) {
      if (e is OpenRouterException) rethrow;
      throw OpenRouterException('Streaming request failed: $e');
    }
  }

  /// Create StreamReader from HTTP byte stream
  StreamReader<Message> _createStreamReader(Stream<List<int>> byteStream) {
    final (reader, writer) = pipe<Message>();

    // Process stream in background
    _processStream(byteStream, writer);

    return reader;
  }

  /// Process SSE stream
  Future<void> _processStream(
    Stream<List<int>> byteStream,
    StreamWriter<Message> writer,
  ) async {
    try {
      final stream = byteStream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((line) => line.startsWith('data: '));

      await for (final line in stream) {
        final data = line.substring(6).trim(); // Remove 'data: ' prefix

        // Check for stream end
        if (data == '[DONE]') {
          break;
        }

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final message = responseParser.parseStreamChunk(json);
          if (message != null) {
            writer.send(message);
          }
        } catch (e) {
          // Skip malformed chunks
          continue;
        }
      }
    } catch (e) {
      writer.sendError(OpenRouterException('Stream processing failed: $e'));
    } finally {
      await writer.close();
    }
  }

  /// Build request headers
  Map<String, String> _buildHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${config.apiKey}',
    };

    // Add OpenRouter-specific headers
    if (config.siteUrl != null) {
      headers['HTTP-Referer'] = config.siteUrl!;
    }
    if (config.siteName != null) {
      headers['X-Title'] = config.siteName!;
    }

    return headers;
  }
}

/// OpenRouter API exception
class OpenRouterException implements Exception {
  OpenRouterException(this.message, {this.statusCode, this.response});

  final String message;
  final int? statusCode;
  final String? response;

  @override
  String toString() =>
      'OpenRouterException: $message${statusCode != null ? ' (status: $statusCode)' : ''}';
}
