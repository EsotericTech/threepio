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
import 'gemini_config.dart';
import 'gemini_converters.dart';
import 'gemini_response_parser.dart';

/// Google Gemini chat model implementation
///
/// Provides integration with Google's Gemini API, supporting
/// both streaming and non-streaming responses, multimodal content,
/// tool/function calling, and Imagen image generation.
///
/// Example usage:
/// ```dart
/// final config = GeminiConfig(apiKey: 'your-api-key');
/// final model = GeminiChatModel(config: config);
///
/// final messages = [Message.user('Hello, how are you?')];
/// final response = await model.generate(messages);
/// print(response.content);
/// ```
///
/// Multimodal example:
/// ```dart
/// final response = await model.generate([
///   Message(
///     role: RoleType.user,
///     userInputMultiContent: [
///       MessageInputPart.text('What is in this image?'),
///       MessageInputPart.imageUrl('data:image/jpeg;base64,...'),
///     ],
///   ),
/// ]);
/// ```
///
/// Tool calling example:
/// ```dart
/// final toolModel = model.withTools([
///   ToolInfo.simple(
///     name: 'get_weather',
///     description: 'Get weather for a location',
///     properties: {'location': JSONSchemaProperty.string()},
///     required: ['location'],
///   ),
/// ]);
/// final response = await toolModel.generate([
///   Message.user('What is the weather in Tokyo?'),
/// ]);
/// ```
///
/// Imagen image generation example:
/// ```dart
/// final imagenModel = GeminiChatModel(
///   config: GeminiConfig(
///     apiKey: 'your-api-key',
///     defaultModel: 'imagen-4.0-generate-001',
///   ),
/// );
///
/// final response = await imagenModel.generate(
///   [Message.user('A serene mountain landscape at sunset')],
///   options: ChatModelOptions(
///     extra: {
///       'numberOfImages': 2,
///       'aspectRatio': '16:9',
///       'personGeneration': 'dont_allow',
///     },
///   ),
/// );
/// // Images are in response.assistantGenMultiContent
/// ```
class GeminiChatModel extends ToolCallingChatModel {
  GeminiChatModel({
    required this.config,
    this.httpClient,
    this.tools,
  });

  /// Gemini configuration
  final GeminiConfig config;

  /// HTTP client for making requests
  final http.Client? httpClient;

  /// Tools bound to this model instance
  final List<ToolInfo>? tools;

  /// Response parser
  final _responseParser = const GeminiResponseParser();

  /// Get or create HTTP client
  http.Client get _client => httpClient ?? http.Client();

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    // Merge options with tools if bound
    final mergedOptions = _mergeOptions(options);
    final model = mergedOptions.model ?? config.defaultModel;

    // Check if this is an Imagen model
    if (_isImagenModel(model)) {
      return _generateWithImagen(input, mergedOptions, model);
    }

    // Get callback manager if available
    final callbackManager = mergedOptions.callbackManager as CallbackManager?;

    if (callbackManager != null) {
      // Execute with callbacks
      final runInfo = RunInfo(
        name: 'GeminiChatModel',
        type: 'GeminiChatModel',
        componentType: ComponentType.chatModel,
        metadata: {
          'model': model,
          ...?mergedOptions.metadata,
        },
      );

      return await callbackManager.runWithCallbacks(
        mergedOptions.getOrCreateContext(),
        runInfo,
        input,
        () async {
          final requestBody = _buildRequestBody(input, mergedOptions);
          final response = await _makeRequest(requestBody, mergedOptions);
          return _responseParser.parseCompletionResponse(response);
        },
      );
    } else {
      final requestBody = _buildRequestBody(input, mergedOptions);
      final response = await _makeRequest(requestBody, mergedOptions);
      return _responseParser.parseCompletionResponse(response);
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
    final requestBody = _buildRequestBody(input, mergedOptions);

    // Make streaming API call
    return await _makeStreamingRequest(requestBody, mergedOptions);
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) {
    return GeminiChatModel(
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
    ChatModelOptions options,
  ) {
    // Extract system instruction and filter messages
    final (systemInstruction, filteredMessages) =
        GeminiConverters.extractSystemInstruction(messages);

    final body = <String, dynamic>{
      'contents': filteredMessages
          .map((m) => GeminiConverters.messageToGemini(m))
          .toList(),
    };

    // Add system instruction if present
    if (systemInstruction != null) {
      body['systemInstruction'] = {
        'parts': [
          {'text': systemInstruction}
        ],
      };
    }

    // Build generation config
    final generationConfig = <String, dynamic>{};
    if (options.temperature != null) {
      generationConfig['temperature'] = options.temperature;
    }
    if (options.maxTokens != null) {
      generationConfig['maxOutputTokens'] = options.maxTokens;
    }
    if (options.topP != null) {
      generationConfig['topP'] = options.topP;
    }
    if (options.stop != null && options.stop!.isNotEmpty) {
      generationConfig['stopSequences'] = options.stop;
    }

    // Handle extra options for Gemini-specific settings
    if (options.extra != null) {
      if (options.extra!['topK'] != null) {
        generationConfig['topK'] = options.extra!['topK'];
      }
      if (options.extra!['candidateCount'] != null) {
        generationConfig['candidateCount'] = options.extra!['candidateCount'];
      }
      if (options.extra!['responseMimeType'] != null) {
        generationConfig['responseMimeType'] =
            options.extra!['responseMimeType'];
      }
      if (options.extra!['responseSchema'] != null) {
        generationConfig['responseSchema'] = options.extra!['responseSchema'];
      }
      // Image generation support
      if (options.extra!['responseModalities'] != null) {
        generationConfig['responseModalities'] =
            options.extra!['responseModalities'];
      }
    }

    if (generationConfig.isNotEmpty) {
      body['generationConfig'] = generationConfig;
    }

    // Add tools if present
    if (options.tools != null && options.tools!.isNotEmpty) {
      body['tools'] = [
        {
          'functionDeclarations': options.tools!
              .map((t) => GeminiConverters.toolInfoToGemini(t))
              .toList(),
        }
      ];

      // Add tool choice if specified
      if (options.toolChoice != null) {
        body['toolConfig'] = {
          'functionCallingConfig': {
            'mode': GeminiConverters.toolChoiceToGemini(options.toolChoice!),
          },
        };
      }
    }

    // Add safety settings if provided
    if (options.extra?['safetySettings'] != null) {
      body['safetySettings'] = options.extra!['safetySettings'];
    }

    return body;
  }

  /// Make API request
  Future<Map<String, dynamic>> _makeRequest(
    Map<String, dynamic> requestBody,
    ChatModelOptions options,
  ) async {
    final model = options.model ?? config.defaultModel;
    final url = Uri.parse('${config.baseUrl}/models/$model:generateContent');
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
        final errorBody = jsonDecode(response.body) as Map<String, dynamic>;
        throw GeminiException.fromResponse(
          response.statusCode,
          errorBody,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    } on TimeoutException {
      throw GeminiException('Request timed out after ${config.timeout}');
    } catch (e) {
      if (e is GeminiException) rethrow;
      throw GeminiException('Request failed: $e');
    }
  }

  /// Make streaming API request
  Future<StreamReader<Message>> _makeStreamingRequest(
    Map<String, dynamic> requestBody,
    ChatModelOptions options,
  ) async {
    final model = options.model ?? config.defaultModel;
    final url = Uri.parse(
      '${config.baseUrl}/models/$model:streamGenerateContent?alt=sse',
    );
    final headers = _buildHeaders();

    try {
      final request = http.Request('POST', url)
        ..headers.addAll(headers)
        ..body = jsonEncode(requestBody);

      final response = await _client.send(request).timeout(config.timeout);

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        final errorBody = jsonDecode(body) as Map<String, dynamic>;
        throw GeminiException.fromResponse(
          response.statusCode,
          errorBody,
        );
      }

      // Create stream reader from HTTP stream
      return _createStreamReader(response.stream);
    } on TimeoutException {
      throw GeminiException('Request timed out after ${config.timeout}');
    } catch (e) {
      if (e is GeminiException) rethrow;
      throw GeminiException('Streaming request failed: $e');
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

        if (data.isEmpty) continue;

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final message = _responseParser.parseStreamChunk(json);
          if (message != null) {
            writer.send(message);
          }
        } catch (e) {
          // Skip malformed chunks
          continue;
        }
      }
    } catch (e) {
      writer.sendError(GeminiException('Stream processing failed: $e'));
    } finally {
      await writer.close();
    }
  }

  /// Build request headers
  Map<String, String> _buildHeaders() {
    return {
      'Content-Type': 'application/json',
      'x-goog-api-key': config.apiKey,
    };
  }

  // ============================================================
  // Imagen Support
  // ============================================================

  /// Known Imagen model prefixes
  static const _imagenModelPrefixes = [
    'imagen-',
  ];

  /// Check if the model is an Imagen model
  bool _isImagenModel(String model) {
    final lowerModel = model.toLowerCase();
    return _imagenModelPrefixes.any((prefix) => lowerModel.startsWith(prefix));
  }

  /// Generate images using Imagen API
  Future<Message> _generateWithImagen(
    List<Message> input,
    ChatModelOptions options,
    String model,
  ) async {
    // Extract prompt from the last user message
    final prompt = _extractImagenPrompt(input);
    if (prompt.isEmpty) {
      throw GeminiException('No prompt found for Imagen generation');
    }

    // Build Imagen request body
    final requestBody = _buildImagenRequestBody(prompt, options);

    // Make request to Imagen endpoint
    final response = await _makeImagenRequest(requestBody, model);

    // Parse Imagen response
    return _parseImagenResponse(response, prompt);
  }

  /// Extract prompt text from messages for Imagen
  String _extractImagenPrompt(List<Message> messages) {
    // Find the last user message
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message.role == RoleType.user) {
        // Check for multimodal content first
        if (message.userInputMultiContent != null) {
          for (final part in message.userInputMultiContent!) {
            if (part.type == ChatMessagePartType.text && part.text != null) {
              return part.text!;
            }
          }
        }
        // Fall back to content
        if (message.content.isNotEmpty) {
          return message.content;
        }
      }
    }
    return '';
  }

  /// Build Imagen API request body
  ///
  /// Imagen API uses a different format:
  /// ```json
  /// {
  ///   "instances": [{"prompt": "..."}],
  ///   "parameters": {
  ///     "sampleCount": 1-4,
  ///     "aspectRatio": "1:1|3:4|4:3|9:16|16:9",
  ///     "personGeneration": "dont_allow|allow_adult|allow_all",
  ///     "imageSize": "1K|2K"
  ///   }
  /// }
  /// ```
  Map<String, dynamic> _buildImagenRequestBody(
    String prompt,
    ChatModelOptions options,
  ) {
    final body = <String, dynamic>{
      'instances': [
        {'prompt': prompt},
      ],
    };

    // Build parameters from options.extra
    final parameters = <String, dynamic>{};
    final extra = options.extra ?? {};

    // Number of images (1-4, default 1)
    if (extra['numberOfImages'] != null) {
      parameters['sampleCount'] = extra['numberOfImages'];
    } else if (extra['sampleCount'] != null) {
      parameters['sampleCount'] = extra['sampleCount'];
    }

    // Aspect ratio
    if (extra['aspectRatio'] != null) {
      parameters['aspectRatio'] = extra['aspectRatio'];
    }

    // Person generation control
    if (extra['personGeneration'] != null) {
      parameters['personGeneration'] = extra['personGeneration'];
    }

    // Image size (for Standard/Ultra models)
    if (extra['imageSize'] != null) {
      parameters['imageSize'] = extra['imageSize'];
    }

    // Safety filter level
    if (extra['safetyFilterLevel'] != null) {
      parameters['safetyFilterLevel'] = extra['safetyFilterLevel'];
    }

    // Add watermark (default true for Imagen)
    if (extra['addWatermark'] != null) {
      parameters['addWatermark'] = extra['addWatermark'];
    }

    if (parameters.isNotEmpty) {
      body['parameters'] = parameters;
    }

    return body;
  }

  /// Make request to Imagen API endpoint
  Future<Map<String, dynamic>> _makeImagenRequest(
    Map<String, dynamic> requestBody,
    String model,
  ) async {
    // Imagen uses :predict endpoint
    final url = Uri.parse('${config.baseUrl}/models/$model:predict');
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
        final errorBody = jsonDecode(response.body) as Map<String, dynamic>;
        throw GeminiException.fromResponse(
          response.statusCode,
          errorBody,
        );
      }

      return jsonDecode(response.body) as Map<String, dynamic>;
    } on TimeoutException {
      throw GeminiException('Imagen request timed out after ${config.timeout}');
    } catch (e) {
      if (e is GeminiException) rethrow;
      throw GeminiException('Imagen request failed: $e');
    }
  }

  /// Parse Imagen API response
  ///
  /// Imagen response format:
  /// ```json
  /// {
  ///   "predictions": [
  ///     {
  ///       "bytesBase64Encoded": "...",
  ///       "mimeType": "image/png"
  ///     }
  ///   ]
  /// }
  /// ```
  Message _parseImagenResponse(
    Map<String, dynamic> response,
    String prompt,
  ) {
    final predictions = response['predictions'] as List<dynamic>?;

    if (predictions == null || predictions.isEmpty) {
      // Check for error in response
      final error = response['error'] as Map<String, dynamic>?;
      if (error != null) {
        throw GeminiException(
          error['message'] as String? ?? 'Imagen generation failed',
          code: error['code'] as int?,
          status: error['status'] as String?,
        );
      }
      throw GeminiException('No images generated by Imagen');
    }

    // Convert predictions to multimodal output parts
    final outputParts = <MessageOutputPart>[];

    for (final prediction in predictions) {
      final predMap = prediction as Map<String, dynamic>;

      // Handle base64 encoded image
      final base64Data = predMap['bytesBase64Encoded'] as String?;
      final mimeType = predMap['mimeType'] as String? ?? 'image/png';

      if (base64Data != null) {
        final dataUrl = 'data:$mimeType;base64,$base64Data';
        outputParts.add(
          MessageOutputPart(
            type: ChatMessagePartType.imageUrl,
            image: MessagePartCommon(url: dataUrl, mimeType: mimeType),
          ),
        );
      }
    }

    // Build response message
    return Message(
      role: RoleType.assistant,
      content: 'Generated ${outputParts.length} image(s) for: "$prompt"',
      assistantGenMultiContent: outputParts.isNotEmpty ? outputParts : null,
    );
  }
}

/// Gemini API exception
class GeminiException implements Exception {
  GeminiException(
    this.message, {
    this.statusCode,
    this.code,
    this.status,
  });

  factory GeminiException.fromResponse(
    int statusCode,
    Map<String, dynamic> body,
  ) {
    final error = body['error'] as Map<String, dynamic>?;
    if (error != null) {
      return GeminiException(
        error['message'] as String? ?? 'Unknown error',
        statusCode: statusCode,
        code: error['code'] as int?,
        status: error['status'] as String?,
      );
    }
    return GeminiException(
      'API request failed with status $statusCode',
      statusCode: statusCode,
    );
  }

  final String message;
  final int? statusCode;
  final int? code;
  final String? status;

  @override
  String toString() {
    final parts = ['GeminiException: $message'];
    if (statusCode != null) parts.add('statusCode: $statusCode');
    if (code != null) parts.add('code: $code');
    if (status != null) parts.add('status: $status');
    return parts.join(', ');
  }
}
