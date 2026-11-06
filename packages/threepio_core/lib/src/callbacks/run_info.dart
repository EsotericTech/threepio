/// Component type classifications
///
/// These represent the abstract component categories in Threepio,
/// matching Eino's component abstraction model.
///
/// Port of eino `components.Component` and of the component kinds of the
/// compose package. [einoName] is the name Eino gives each kind.
enum ComponentType {
  /// Chat model or LLM
  chatModel('ChatModel'),

  /// Tool or function that can be called
  tool('Tool'),

  /// Chain or composed runnable
  chain('Chain'),

  /// Document retriever
  retriever('Retriever'),

  /// Text embedder
  embedder('Embedding'),

  /// Prompt template
  promptTemplate('ChatTemplate'),

  /// Generic runnable or lambda
  runnable('Runnable'),

  /// Agent with autonomous behavior
  agent('Agent'),

  /// Custom or unknown component type
  custom('Unknown'),

  /// Stores documents so that a retriever finds them again
  indexer('Indexer'),

  /// Loads documents from a source
  loader('Loader'),

  /// Turns a list of documents into another one (splitter, filter, reranker)
  documentTransformer('DocumentTransformer'),

  /// Graph of nodes
  graph('Graph'),

  /// Workflow: a graph whose nodes are wired field by field
  workflow('Workflow'),

  /// Function used as a graph node
  lambda('Lambda'),

  /// Graph node that executes the tool calls of a message
  toolsNode('ToolsNode'),

  /// Model of the agentic path (`AgenticMessage` in and out). **Beta.**
  agenticModel('AgenticModel'),

  /// Chat template of the agentic path. **Beta.**
  agenticChatTemplate('AgenticChatTemplate'),

  /// Tools node of the agentic path. **Beta.**
  agenticToolsNode('AgenticToolsNode'),

  /// Agent of the agentic path. **Beta.**
  agenticAgent('AgenticAgent');

  const ComponentType(this.einoName);

  /// The name of this kind of component in Eino, as it appears in traces and
  /// in callback payloads exchanged with Eino-based tooling.
  ///
  /// [runnable] has no counterpart in Eino and [custom] stands for Eino's
  /// `Unknown`.
  final String einoName;
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

  /// What a callback handler is given when the component that fires a
  /// callback has not said what it is.
  ///
  /// The counterpart of the `nil` run info of eino: a component reports
  /// itself with `ensureRunInfo` or `reuseHandlers` before it fires its start
  /// callback. One that fires two start callbacks in a row, or none at all,
  /// leaves the handlers without that information, and they get this value
  /// instead (an empty name, an empty type and [ComponentType.custom]).
  static const RunInfo unknown = RunInfo(
    name: '',
    type: '',
    componentType: ComponentType.custom,
  );

  /// Whether this is [unknown]: nothing is known about the component.
  bool get isUnknown =>
      name.isEmpty && type.isEmpty && componentType == ComponentType.custom;

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
