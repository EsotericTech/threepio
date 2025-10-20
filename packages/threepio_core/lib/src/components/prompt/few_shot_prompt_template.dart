import '../../schema/message.dart';
import 'chat_template.dart';
import 'prompt_template.dart';

/// A single example for few-shot learning
class Example {
  const Example(this.data);

  /// The example data as key-value pairs
  final Map<String, dynamic> data;

  /// Get a value from the example
  dynamic operator [](String key) => data[key];

  /// Check if the example contains a key
  bool containsKey(String key) => data.containsKey(key);
}

/// Selector for choosing which examples to include
abstract class ExampleSelector {
  /// Select examples relevant to the input variables
  Future<List<Example>> selectExamples(Map<String, dynamic> inputVariables);

  /// Add an example to the selector's knowledge
  Future<void> addExample(Example example);
}

/// Simple selector that returns all examples
class AllExamplesSelector implements ExampleSelector {
  AllExamplesSelector(this.examples);

  final List<Example> examples;

  @override
  Future<List<Example>> selectExamples(
      Map<String, dynamic> inputVariables) async {
    return examples;
  }

  @override
  Future<void> addExample(Example example) async {
    examples.add(example);
  }
}

/// Selector that returns the first N examples
class FirstNExamplesSelector implements ExampleSelector {
  FirstNExamplesSelector({
    required this.examples,
    required this.n,
  });

  final List<Example> examples;
  final int n;

  @override
  Future<List<Example>> selectExamples(
      Map<String, dynamic> inputVariables) async {
    return examples.take(n).toList();
  }

  @override
  Future<void> addExample(Example example) async {
    examples.add(example);
  }
}

/// Template for few-shot learning with examples
///
/// Formats a prompt with a prefix, examples, and a suffix.
/// Each example is formatted using an example template.
///
/// Example usage:
/// ```dart
/// final template = FewShotPromptTemplate(
///   prefix: 'Translate English to French:\n',
///   exampleTemplate: PromptTemplate.fromTemplate(
///     'English: {english}\nFrench: {french}',
///   ),
///   examples: [
///     Example({'english': 'Hello', 'french': 'Bonjour'}),
///     Example({'english': 'Goodbye', 'french': 'Au revoir'}),
///   ],
///   suffix: '\nEnglish: {input}\nFrench:',
///   inputVariables: ['input'],
/// );
///
/// final prompt = await template.format({'input': 'How are you?'});
/// ```
class FewShotPromptTemplate {
  const FewShotPromptTemplate({
    this.prefix = '',
    required this.exampleTemplate,
    this.examples,
    this.exampleSelector,
    this.suffix = '',
    required this.inputVariables,
    this.exampleSeparator = '\n\n',
  });

  /// Text to prepend before examples
  final String prefix;

  /// Template for formatting each example
  final PromptTemplate exampleTemplate;

  /// Static list of examples (used if exampleSelector is null)
  final List<Example>? examples;

  /// Dynamic example selector (used if provided)
  final ExampleSelector? exampleSelector;

  /// Text to append after examples
  final String suffix;

  /// Variables that need to be provided in format()
  final List<String> inputVariables;

  /// Separator between examples
  final String exampleSeparator;

  /// Format the template with examples
  Future<String> format(Map<String, dynamic> variables) async {
    // Get examples (either static or dynamic)
    final selectedExamples = exampleSelector != null
        ? await exampleSelector!.selectExamples(variables)
        : examples ?? [];

    // Format each example
    final formattedExamples = <String>[];
    for (final example in selectedExamples) {
      final formatted = exampleTemplate.format(example.data);
      formattedExamples.add(formatted);
    }

    // Combine prefix, examples, and suffix
    final parts = <String>[];

    if (prefix.isNotEmpty) {
      parts.add(prefix);
    }

    if (formattedExamples.isNotEmpty) {
      parts.add(formattedExamples.join(exampleSeparator));
    }

    if (suffix.isNotEmpty) {
      // Format suffix with input variables
      final suffixTemplate = PromptTemplate(
        template: suffix,
        inputVariables: inputVariables,
        validateTemplate:
            false, // Don't validate, suffix might not use all vars
      );
      parts.add(suffixTemplate.format(variables));
    }

    return parts.join('\n\n');
  }
}

/// Few-shot template for chat conversations
///
/// Formats examples as message pairs (user/assistant) in a conversation.
///
/// Example usage:
/// ```dart
/// final template = FewShotChatPromptTemplate(
///   systemTemplate: 'You are a translator.',
///   examples: [
///     Example({
///       'input': 'Hello',
///       'output': 'Bonjour',
///     }),
///     Example({
///       'input': 'Goodbye',
///       'output': 'Au revoir',
///     }),
///   ],
///   inputVariables: ['input'],
/// );
///
/// final messages = await template.format({'input': 'How are you?'});
/// ```
class FewShotChatPromptTemplate implements ChatTemplate {
  const FewShotChatPromptTemplate({
    this.systemTemplate,
    required this.examples,
    this.exampleInputKey = 'input',
    this.exampleOutputKey = 'output',
    required this.inputVariables,
    this.userTemplate = '{input}',
  });

  /// Optional system message template
  final String? systemTemplate;

  /// Examples to include in the conversation
  final List<Example> examples;

  /// Key in example data for user input
  final String exampleInputKey;

  /// Key in example data for assistant output
  final String exampleOutputKey;

  /// Variables required in the final user message
  final List<String> inputVariables;

  /// Template for the final user message
  final String userTemplate;

  @override
  Future<List<Message>> format(
    Map<String, dynamic> variables, {
    ChatTemplateOptions? options,
  }) async {
    final messages = <Message>[];

    // Add system message if provided
    if (systemTemplate != null) {
      messages.add(Message(
        role: RoleType.system,
        content: systemTemplate!,
      ));
    }

    // Add example pairs
    for (final example in examples) {
      // User example
      final input = example[exampleInputKey]?.toString() ?? '';
      messages.add(Message.user(input));

      // Assistant example
      final output = example[exampleOutputKey]?.toString() ?? '';
      messages.add(Message(
        role: RoleType.assistant,
        content: output,
      ));
    }

    // Add final user input
    final userPromptTemplate = PromptTemplate(
      template: userTemplate,
      inputVariables: inputVariables,
    );
    final userContent = userPromptTemplate.format(variables);
    messages.add(Message.user(userContent));

    return messages;
  }
}
