import '../../schema/tool_info.dart';

/// Common options for chat models
class ChatModelOptions {
  const ChatModelOptions({
    this.temperature,
    this.maxTokens,
    this.model,
    this.topP,
    this.stop,
    this.tools,
    this.toolChoice,
    this.extra,
    this.callbackManager,
    this.context,
    this.metadata,
  });

  /// Temperature for controlling randomness (typically 0.0-2.0)
  final double? temperature;

  /// Maximum number of tokens to generate
  final int? maxTokens;

  /// Model name/identifier
  final String? model;

  /// Top-p sampling parameter for diversity control
  final double? topP;

  /// Stop sequences that halt generation
  final List<String>? stop;

  /// Tools available for the model to call
  final List<ToolInfo>? tools;

  /// Controls which tool is called by the model
  final ToolChoice? toolChoice;

  /// Implementation-specific options
  final Map<String, dynamic>? extra;

  /// Callback manager for execution lifecycle events
  ///
  /// Use this to attach callbacks that track execution, log information,
  /// collect metrics, or perform other cross-cutting concerns.
  final dynamic
      callbackManager; // CallbackManager - keeping dynamic to avoid circular import

  /// Execution context that flows through callbacks
  ///
  /// This context is threaded through all callback invocations,
  /// allowing handlers to store and retrieve request-level information.
  final Map<String, dynamic>? context;

  /// Arbitrary metadata to pass through execution
  final Map<String, dynamic>? metadata;

  /// Copy with method for creating modified copies
  ChatModelOptions copyWith({
    double? temperature,
    int? maxTokens,
    String? model,
    double? topP,
    List<String>? stop,
    List<ToolInfo>? tools,
    ToolChoice? toolChoice,
    Map<String, dynamic>? extra,
    dynamic callbackManager,
    Map<String, dynamic>? context,
    Map<String, dynamic>? metadata,
  }) {
    return ChatModelOptions(
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      model: model ?? this.model,
      topP: topP ?? this.topP,
      stop: stop ?? this.stop,
      tools: tools ?? this.tools,
      toolChoice: toolChoice ?? this.toolChoice,
      extra: extra ?? this.extra,
      callbackManager: callbackManager ?? this.callbackManager,
      context: context ?? this.context,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Merge this options with another, with other taking precedence
  ChatModelOptions merge(ChatModelOptions? other) {
    if (other == null) return this;

    return ChatModelOptions(
      temperature: other.temperature ?? temperature,
      maxTokens: other.maxTokens ?? maxTokens,
      model: other.model ?? model,
      topP: other.topP ?? topP,
      stop: other.stop ?? stop,
      tools: other.tools ?? tools,
      toolChoice: other.toolChoice ?? toolChoice,
      extra: other.extra ?? extra,
      callbackManager: other.callbackManager ?? callbackManager,
      context: other.context ?? context,
      metadata: other.metadata ?? metadata,
    );
  }

  /// Get the context, creating an empty one if null
  Map<String, dynamic> getOrCreateContext() {
    return context ?? {};
  }
}
