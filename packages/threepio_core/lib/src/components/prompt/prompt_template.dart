/// Basic prompt template with variable substitution
///
/// Supports string templates with variable placeholders using curly braces.
///
/// Example usage:
/// ```dart
/// final template = PromptTemplate(
///   template: 'Tell me a {length} story about {topic}.',
///   inputVariables: ['length', 'topic'],
/// );
///
/// final prompt = template.format({
///   'length': 'short',
///   'topic': 'robots',
/// });
/// print(prompt); // "Tell me a short story about robots."
/// ```
class PromptTemplate {
  const PromptTemplate({
    required this.template,
    required this.inputVariables,
    this.templateFormat = TemplateFormat.fString,
    this.validateTemplate = true,
    this.partialVariables,
  });

  /// The template string with variable placeholders
  final String template;

  /// List of variable names that should be provided
  final List<String> inputVariables;

  /// Format of the template (currently only f-string style is supported)
  final TemplateFormat templateFormat;

  /// Whether to validate that all variables are present
  final bool validateTemplate;

  /// Variables with preset values (don't need to be provided in format())
  final Map<String, dynamic>? partialVariables;

  /// Format the template with the given variables
  ///
  /// Returns the formatted string with all variables substituted.
  /// Throws [ArgumentError] if required variables are missing.
  String format(Map<String, dynamic> variables) {
    // Merge partial variables with provided variables
    final allVariables = <String, dynamic>{
      ...?partialVariables,
      ...variables,
    };

    // Validate required variables are present
    if (validateTemplate) {
      for (final varName in inputVariables) {
        if (!allVariables.containsKey(varName)) {
          throw ArgumentError(
            'Missing required variable: $varName. '
            'Required variables: $inputVariables',
          );
        }
      }
    }

    // Perform substitution based on template format
    return _substituteVariables(template, allVariables);
  }

  /// Format the template asynchronously
  Future<String> formatAsync(Map<String, dynamic> variables) async {
    return format(variables);
  }

  /// Create a partial template with some variables preset
  ///
  /// Returns a new template with the given variables already filled in.
  PromptTemplate partial(Map<String, dynamic> variables) {
    final newPartialVariables = <String, dynamic>{
      ...?partialVariables,
      ...variables,
    };

    // Remove preset variables from required input variables
    final newInputVariables = inputVariables
        .where((v) => !newPartialVariables.containsKey(v))
        .toList();

    return PromptTemplate(
      template: template,
      inputVariables: newInputVariables,
      templateFormat: templateFormat,
      validateTemplate: validateTemplate,
      partialVariables: newPartialVariables,
    );
  }

  /// Extract variables from a template string
  static List<String> extractVariables(String template) {
    final regex = RegExp(r'\{([^}]+)\}');
    final matches = regex.allMatches(template);
    return matches.map((m) => m.group(1)!).toSet().toList();
  }

  /// Create a template from a string, automatically extracting variables
  factory PromptTemplate.fromTemplate(String template) {
    final variables = extractVariables(template);
    return PromptTemplate(
      template: template,
      inputVariables: variables,
    );
  }

  /// Substitute variables in the template string
  String _substituteVariables(String template, Map<String, dynamic> variables) {
    var result = template;

    // Replace each variable placeholder with its value
    for (final entry in variables.entries) {
      final placeholder = '{${entry.key}}';
      final value = entry.value?.toString() ?? '';
      result = result.replaceAll(placeholder, value);
    }

    return result;
  }
}

/// Template format types
enum TemplateFormat {
  /// f-string style: {variable_name}
  fString,

  /// Jinja2 style: {{ variable_name }}
  jinja2,

  /// Mustache style: {{variable_name}}
  mustache,
}

/// Exception thrown when template formatting fails
class TemplateFormatException implements Exception {
  TemplateFormatException(this.message);

  final String message;

  @override
  String toString() => 'TemplateFormatException: $message';
}
