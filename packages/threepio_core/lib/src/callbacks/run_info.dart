/// Component type classifications
///
/// These represent the abstract component categories in Threepio,
/// matching Eino's component abstraction model.
enum ComponentType {
  /// Chat model or LLM
  chatModel,

  /// Tool or function that can be called
  tool,

  /// Chain or composed runnable
  chain,

  /// Document retriever
  retriever,

  /// Text embedder
  embedder,

  /// Prompt template
  promptTemplate,

  /// Generic runnable or lambda
  runnable,

  /// Agent with autonomous behavior
  agent,

  /// Custom or unknown component type
  custom,
}

/// Metadata about a running component
///
/// Provides identifying information about what component is executing,
/// used by callback handlers to track and log execution.
///
/// The RunInfo follows Eino's three-level identification:
/// - [name]: User-defined meaningful name for this specific instance
/// - [type]: Specific implementation type (e.g., "OpenAIChatModel")
/// - [componentType]: Abstract component category (e.g., ComponentType.chatModel)
///
/// Example:
/// ```dart
/// final info = RunInfo(
///   name: 'summarizer',
///   type: 'LLMChain',
///   componentType: ComponentType.chain,
///   metadata: {
///     'model': 'gpt-4',
///     'temperature': 0.7,
///   },
/// );
/// ```
class RunInfo {
  const RunInfo({
    required this.name,
    required this.type,
    required this.componentType,
    this.metadata,
  });

  /// User-defined meaningful name for this component instance
  ///
  /// This should be a descriptive name that helps identify the purpose
  /// of this specific component in your application.
  /// Example: "question_answerer", "document_summarizer", "code_reviewer"
  final String name;

  /// Specific implementation type
  ///
  /// The concrete class name or implementation identifier.
  /// Example: "OpenAIChatModel", "LLMChain", "VectorRetriever"
  final String type;

  /// Abstract component category
  ///
  /// The high-level component type from the ComponentType enum.
  /// This allows handlers to apply different logic based on component category.
  final ComponentType componentType;

  /// Additional metadata about this component
  ///
  /// Can include configuration details, parameters, or other context
  /// that might be useful for logging or tracing.
  final Map<String, dynamic>? metadata;

  /// Create a copy with modified fields
  RunInfo copyWith({
    String? name,
    String? type,
    ComponentType? componentType,
    Map<String, dynamic>? metadata,
  }) {
    return RunInfo(
      name: name ?? this.name,
      type: type ?? this.type,
      componentType: componentType ?? this.componentType,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() {
    return 'RunInfo(name: $name, type: $type, componentType: $componentType, metadata: $metadata)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is RunInfo &&
        other.name == name &&
        other.type == type &&
        other.componentType == componentType;
  }

  @override
  int get hashCode {
    return name.hashCode ^ type.hashCode ^ componentType.hashCode;
  }
}
