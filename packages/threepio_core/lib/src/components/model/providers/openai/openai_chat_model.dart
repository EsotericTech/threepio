import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../../callbacks/callback_handler.dart';
import '../../../../callbacks/callback_manager.dart';
import '../../../../callbacks/run_info.dart';
import '../../../../schema/message.dart';
import '../../../../schema/tool_info.dart';
import '../../../../streaming/stream_reader.dart';
import '../../../../streaming/stream_utils.dart';
import '../../../../streaming/stream_writer.dart';
import '../../base_chat_model.dart';
import '../../chat_model_options.dart';
import 'openai_config.dart';
import 'openai_converters.dart';

/// OpenAI chat model implementation
///
/// Provides integration with OpenAI's Chat Completions API, supporting
/// both streaming and non-streaming responses, along with tool calling.
///
/// Example usage:
/// ```dart
/// final config = OpenAIConfig(apiKey: 'your-api-key');
/// final model = OpenAIChatModel(config: config);
///
/// final messages = [Message.user('Hello, how are you?')];
/// final response = await model.generate(messages);
/// print(response.content);
/// ```
class OpenAIChatModel extends ToolCallingChatModel {
  OpenAIChatModel({
    required this.config,
    this.httpClient,
    this.tools,
  });

  /// OpenAI configuration
  final OpenAIConfig config;

  /// HTTP client for making requests
  final http.Client? httpClient;

  /// Tools bound to this model instance
  final List<ToolInfo>? tools;

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
        name: 'OpenAIChatModel',
        type: 'OpenAIChatModel',
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
          return _parseCompletionResponse(response);
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
      return _parseCompletionResponse(response);
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
    return OpenAIChatModel(
      config: config,
      httpClient: httpClient,
      tools: tools,
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
        throw OpenAIException(
          'API request failed with status ${response.statusCode}: ${response.body}',
          statusCode: response.statusCode,
          response: response.body,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    } on TimeoutException {
      throw OpenAIException('Request timed out after ${config.timeout}');
    } catch (e) {
      if (e is OpenAIException) rethrow;
      throw OpenAIException('Request failed: $e');
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
        throw OpenAIException(
          'API request failed with status ${response.statusCode}: $body',
          statusCode: response.statusCode,
          response: body,
        );
      }

      // Create stream reader from HTTP stream
      return _createStreamReader(response.stream);
    } on TimeoutException {
      throw OpenAIException('Request timed out after ${config.timeout}');
    } catch (e) {
      if (e is OpenAIException) rethrow;
      throw OpenAIException('Streaming request failed: $e');
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
          final message = _parseStreamChunk(json);
          if (message != null) {
            writer.send(message);
          }
        } catch (e) {
          // Skip malformed chunks
          continue;
        }
      }
    } catch (e) {
      writer.sendError(OpenAIException('Stream processing failed: $e'));
    } finally {
      await writer.close();
    }
  }

  /// Parse completion response
  Message _parseCompletionResponse(Map<String, dynamic> response) {
    final choices = response['choices'] as List<dynamic>;
    if (choices.isEmpty) {
      throw OpenAIException('No choices in response');
    }

    final choice = choices.first as Map<String, dynamic>;
    final messageData = choice['message'] as Map<String, dynamic>;
    final usage = response['usage'] as Map<String, dynamic>?;

    return OpenAIConverters.openAIToMessage(
      messageData,
      finishReason: choice['finish_reason'] as String?,
      usage: usage,
    );
  }

  /// Parse streaming chunk
  Message? _parseStreamChunk(Map<String, dynamic> chunk) {
    final choices = chunk['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      return null;
    }

    final choice = choices.first as Map<String, dynamic>;
    final delta = choice['delta'] as Map<String, dynamic>?;
    if (delta == null || delta.isEmpty) {
      return null;
    }

    return OpenAIConverters.openAIDeltaToMessage(
      delta,
      finishReason: choice['finish_reason'] as String?,
    );
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
}

/// OpenAI API exception
class OpenAIException implements Exception {
  OpenAIException(this.message, {this.statusCode, this.response});

  final String message;
  final int? statusCode;
  final String? response;

  @override
  String toString() =>
      'OpenAIException: $message${statusCode != null ? ' (status: $statusCode)' : ''}';
}
