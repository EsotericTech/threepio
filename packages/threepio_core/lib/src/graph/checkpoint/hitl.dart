import '../graph_state.dart';
import 'checkpoint.dart';

/// Node that requires human input before continuing execution.
///
/// Human-in-the-loop (HITL) nodes pause graph execution until external input
/// is provided. This is useful for:
/// - Approval workflows
/// - User confirmation steps
/// - Data collection points
/// - Quality assurance checkpoints
///
/// Example:
/// ```dart
/// final approvalNode = HumanInputNode<MyState, bool>(
///   name: 'approval',
///   prompt: (state) => 'Review and approve: ${state.summary}',
///   processInput: (state, approved) => state.copyWith(
///     approved: approved,
///     reviewedAt: DateTime.now(),
///   ),
///   validator: (input) => input is bool,
/// );
///
/// // Add to graph
/// graph.addHumanInputNode(approvalNode);
/// ```
class HumanInputNode<S extends GraphState, I> {
  /// Creates a human input node.
  ///
  /// [name] - Unique node identifier
  /// [prompt] - Function generating prompt text from current state
  /// [processInput] - Function to process input and update state
  /// [validator] - Optional input validator
  /// [timeout] - Optional timeout for human response
  /// [description] - Optional description for documentation
  HumanInputNode({
    required this.name,
    required this.prompt,
    required this.processInput,
    this.validator,
    this.timeout,
    this.description,
  });

  /// Unique identifier for this node.
  final String name;

  /// Function to generate a prompt from the current state.
  ///
  /// The prompt is shown to the human for context.
  final String Function(S state) prompt;

  /// Function to process human input and update the state.
  ///
  /// Called when human input is provided during resume.
  final S Function(S state, I input) processInput;

  /// Optional validator for human input.
  ///
  /// If provided, input must pass validation before being processed.
  final bool Function(I input)? validator;

  /// Optional timeout for human input.
  ///
  /// If set, the workflow may fail or take alternative action
  /// if input is not received within this duration.
  final Duration? timeout;

  /// Optional description for documentation/debugging.
  final String? description;

  /// Validates the provided input.
  ///
  /// Returns true if input is valid, false otherwise.
  /// If no validator is set, all input is considered valid.
  bool validateInput(I input) {
    if (validator == null) return true;
    return validator!(input);
  }

  /// Resume execution with the provided human input.
  ///
  /// Validates input and processes it to update state.
  /// Throws [InvalidHumanInputException] if validation fails.
  S resumeWithInput(S state, I input) {
    if (!validateInput(input)) {
      throw InvalidHumanInputException(
        nodeName: name,
        message: 'Input validation failed',
        input: input,
      );
    }
    return processInput(state, input);
  }

  @override
  String toString() {
    return 'HumanInputNode($name${description != null ? ': $description' : ''})';
  }
}

/// Exception thrown when human input is required.
///
/// When a graph reaches a human input node, execution throws this exception.
/// The exception contains the checkpoint and prompt information needed
/// to collect human input and resume execution.
///
/// Example handling:
/// ```dart
/// try {
///   await graph.invoke(initialState, threadId: 'user-123');
/// } on HumanInputRequired<MyState, bool> catch (e) {
///   // Display prompt to user
///   print(e.prompt);
///
///   // Collect user input (e.g., from UI)
///   final userApproval = await getUserApproval();
///
///   // Resume execution with input
///   await graph.resumeWithHumanInput<bool>(
///     e.checkpoint.id!,
///     input: userApproval,
///     threadId: 'user-123',
///   );
/// }
/// ```
class HumanInputRequired<S extends GraphState, I> implements Exception {
  /// Creates a human input required exception.
  HumanInputRequired({
    required this.nodeName,
    required this.prompt,
    required this.checkpoint,
    this.validator,
    this.timeout,
  });

  /// Name of the HITL node.
  final String nodeName;

  /// Prompt text to show the human.
  final String prompt;

  /// Checkpoint at the point of interruption.
  ///
  /// Contains all state needed to resume execution.
  final Checkpoint<S> checkpoint;

  /// Optional validator function for input.
  final bool Function(I input)? validator;

  /// Optional timeout for human response.
  final Duration? timeout;

  /// Validates the provided input.
  bool validateInput(I input) {
    if (validator == null) return true;
    return validator!(input);
  }

  @override
  String toString() {
    return 'HumanInputRequired(node: $nodeName, prompt: $prompt)';
  }
}

/// Exception thrown when invalid human input is provided.
class InvalidHumanInputException implements Exception {
  /// Creates an invalid human input exception.
  InvalidHumanInputException({
    required this.nodeName,
    required this.message,
    this.input,
  });

  /// Name of the HITL node.
  final String nodeName;

  /// Error message describing the validation failure.
  final String message;

  /// The invalid input that was provided.
  final dynamic input;

  @override
  String toString() {
    return 'InvalidHumanInputException(node: $nodeName, message: $message)';
  }
}

/// Configuration for human input behavior in graphs.
class HumanInputConfig {
  /// Creates human input configuration.
  const HumanInputConfig({
    this.defaultTimeout,
    this.onTimeout,
    this.requireValidation = true,
  });

  /// Default timeout for all HITL nodes (if not overridden per-node).
  final Duration? defaultTimeout;

  /// Callback when a HITL node times out.
  final void Function(String nodeName)? onTimeout;

  /// Whether to require input validation (true by default).
  final bool requireValidation;
}

/// Extension for building HITL nodes with common patterns.
extension HumanInputNodeBuilders<S extends GraphState> on HumanInputNode<S, String> {
  /// Creates a yes/no confirmation node.
  static HumanInputNode<S, bool> confirmation<S extends GraphState>({
    required String name,
    required String Function(S state) prompt,
    required S Function(S state, bool confirmed) processInput,
    String? description,
  }) {
    return HumanInputNode<S, bool>(
      name: name,
      prompt: prompt,
      processInput: processInput,
      // No validator needed - input is already typed as bool
      description: description ?? 'Yes/No confirmation',
    );
  }

  /// Creates a text input node.
  static HumanInputNode<S, String> textInput<S extends GraphState>({
    required String name,
    required String Function(S state) prompt,
    required S Function(S state, String text) processInput,
    int? minLength,
    int? maxLength,
    RegExp? pattern,
    String? description,
  }) {
    return HumanInputNode<S, String>(
      name: name,
      prompt: prompt,
      processInput: processInput,
      validator: (input) {
        if (minLength != null && input.length < minLength) return false;
        if (maxLength != null && input.length > maxLength) return false;
        if (pattern != null && !pattern.hasMatch(input)) return false;
        return true;
      },
      description: description ?? 'Text input',
    );
  }

  /// Creates a choice selection node.
  static HumanInputNode<S, String> choice<S extends GraphState>({
    required String name,
    required String Function(S state) prompt,
    required List<String> options,
    required S Function(S state, String choice) processInput,
    String? description,
  }) {
    return HumanInputNode<S, String>(
      name: name,
      prompt: prompt,
      processInput: processInput,
      validator: (input) => options.contains(input),
      description: description ?? 'Choice selection from: ${options.join(", ")}',
    );
  }

  /// Creates a numeric input node.
  static HumanInputNode<S, num> numericInput<S extends GraphState>({
    required String name,
    required String Function(S state) prompt,
    required S Function(S state, num value) processInput,
    num? min,
    num? max,
    String? description,
  }) {
    return HumanInputNode<S, num>(
      name: name,
      prompt: prompt,
      processInput: processInput,
      validator: (input) {
        if (min != null && input < min) return false;
        if (max != null && input > max) return false;
        return true;
      },
      description: description ?? 'Numeric input${min != null || max != null ? ' ($min-$max)' : ''}',
    );
  }
}
