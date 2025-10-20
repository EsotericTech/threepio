/// Base interface for output parsers
///
/// **Framework Sources:**
/// - **LangChain**: OutputParser abstraction pattern
/// - **Instructor**: Structured extraction approach
///
/// Output parsers transform LLM text output into structured, type-safe data.
/// They provide:
/// - Parsing of text into structured formats
/// - Validation of parsed output
/// - Format instructions for the LLM
/// - Error handling and retry logic
///
/// Example:
/// ```dart
/// final parser = JsonOutputParser<WeatherData>();
/// final instructions = parser.getFormatInstructions();
///
/// // Add instructions to prompt
/// final prompt = 'Get weather data for Paris.\n\n$instructions';
///
/// // Parse LLM response
/// final result = await parser.parse(llmOutput);
/// print(result.temperature);
/// ```
abstract class OutputParser<T> {
  /// Parse the LLM output text into structured type T
  ///
  /// Throws [OutputParserException] if parsing fails.
  Future<T> parse(String text);

  /// Try to parse the output, returning null on failure
  ///
  /// Useful when you want to handle errors gracefully.
  Future<T?> tryParse(String text) async {
    try {
      return await parse(text);
    } catch (e) {
      return null;
    }
  }

  /// Get instructions to include in the prompt
  ///
  /// These instructions tell the LLM how to format its output
  /// so that this parser can successfully parse it.
  String getFormatInstructions();

  /// Get the type name for this parser
  ///
  /// Useful for debugging and error messages.
  String get outputType => T.toString();
}

/// Base class for parsers that transform one type into another
abstract class TransformingParser<TInput, TOutput>
    implements OutputParser<TOutput> {
  /// Parse input into an intermediate representation
  Future<TInput> parseInput(String text);

  /// Transform the intermediate representation into the output type
  Future<TOutput> transform(TInput input);

  @override
  Future<TOutput> parse(String text) async {
    final input = await parseInput(text);
    return await transform(input);
  }
}

/// Exception thrown when output parsing fails
class OutputParserException implements Exception {
  OutputParserException(this.message, {this.output, this.sendToLLM = false});

  /// Error message describing what went wrong
  final String message;

  /// The output that failed to parse
  final String? output;

  /// Whether to send this error back to the LLM to try again
  ///
  /// If true, the LLM can see the error and attempt to fix its output.
  final bool sendToLLM;

  @override
  String toString() {
    if (output != null) {
      return 'OutputParserException: $message\nOutput: $output';
    }
    return 'OutputParserException: $message';
  }

  /// Create an error message to send back to the LLM
  String toLLMMessage() {
    return '''The output could not be parsed. Error: $message

Please try again and ensure your output follows the required format exactly.''';
  }
}

/// Parser configuration
class ParserConfig {
  const ParserConfig({
    this.retryOnFailure = true,
    this.maxRetries = 3,
    this.stripWhitespace = true,
    this.fixQuotes = true,
  });

  /// Whether to retry parsing on failure
  final bool retryOnFailure;

  /// Maximum number of retry attempts
  final int maxRetries;

  /// Whether to strip leading/trailing whitespace before parsing
  final bool stripWhitespace;

  /// Whether to attempt fixing common quote issues
  final bool fixQuotes;
}

/// Parser that returns the raw string output
///
/// Useful as a no-op parser or for testing.
class StringOutputParser extends OutputParser<String> {
  @override
  Future<String> parse(String text) async {
    return text.trim();
  }

  @override
  String getFormatInstructions() {
    return 'Provide your response as plain text.';
  }
}

/// Parser that extracts a specific section from markdown-style output
///
/// Useful when the LLM wraps output in markdown code blocks.
///
/// Example:
/// ```dart
/// final parser = MarkdownCodeBlockParser('json');
/// final result = await parser.parse('''
/// Here's the data:
/// ```json
/// {"name": "John", "age": 30}
/// ```
/// ''');
/// // result = '{"name": "John", "age": 30}'
/// ```
class MarkdownCodeBlockParser extends OutputParser<String> {
  MarkdownCodeBlockParser({this.language});

  /// Optional language identifier (e.g., 'json', 'dart', 'python')
  final String? language;

  @override
  Future<String> parse(String text) async {
    final pattern = language != null
        ? RegExp('```$language\\s*\\n(.+?)\\n```', dotAll: true)
        : RegExp('```\\s*\\n(.+?)\\n```', dotAll: true);

    final match = pattern.firstMatch(text);
    if (match == null) {
      // Try without language specifier
      final fallbackPattern = RegExp('```(.+?)```', dotAll: true);
      final fallbackMatch = fallbackPattern.firstMatch(text);

      if (fallbackMatch == null) {
        throw OutputParserException(
          'Could not find markdown code block${language != null ? " with language '$language'" : ""}',
          output: text,
          sendToLLM: true,
        );
      }

      return fallbackMatch.group(1)!.trim();
    }

    return match.group(1)!.trim();
  }

  @override
  String getFormatInstructions() {
    final lang = language ?? '';
    return '''Wrap your output in a markdown code block:

```$lang
your output here
```''';
  }
}

/// Parser that splits output by a delimiter
///
/// Useful for parsing lists or multi-part responses.
///
/// Example:
/// ```dart
/// final parser = ListOutputParser(itemSeparator: '\n');
/// final items = await parser.parse('- Item 1\n- Item 2\n- Item 3');
/// // items = ['- Item 1', '- Item 2', '- Item 3']
/// ```
class ListOutputParser extends OutputParser<List<String>> {
  ListOutputParser({
    this.itemSeparator = '\n',
    this.trimItems = true,
    this.removeEmpty = true,
  });

  /// Separator between list items
  final String itemSeparator;

  /// Whether to trim whitespace from each item
  final bool trimItems;

  /// Whether to remove empty items
  final bool removeEmpty;

  @override
  Future<List<String>> parse(String text) async {
    var items = text.split(itemSeparator);

    if (trimItems) {
      items = items.map((item) => item.trim()).toList();
    }

    if (removeEmpty) {
      items = items.where((item) => item.isNotEmpty).toList();
    }

    return items;
  }

  @override
  String getFormatInstructions() {
    return 'Provide your response as a list with items separated by "$itemSeparator".';
  }
}

/// Parser for comma-separated values
class CommaSeparatedListOutputParser extends ListOutputParser {
  CommaSeparatedListOutputParser()
      : super(
          itemSeparator: ',',
          trimItems: true,
          removeEmpty: true,
        );

  @override
  String getFormatInstructions() {
    return 'Provide your response as comma-separated values.';
  }
}

/// Parser that combines multiple parsers in sequence
///
/// Applies parsers in order, passing output from one to the next.
class ChainedOutputParser<T> extends OutputParser<T> {
  ChainedOutputParser(this.parsers) : assert(parsers.isNotEmpty);

  final List<OutputParser> parsers;

  @override
  Future<T> parse(String text) async {
    dynamic current = text;

    for (final parser in parsers) {
      if (current is String) {
        current = await parser.parse(current);
      } else {
        throw OutputParserException(
          'Chained parser expected String but got ${current.runtimeType}',
        );
      }
    }

    if (current is! T) {
      throw OutputParserException(
        'Final output type ${current.runtimeType} does not match expected type $T',
      );
    }

    return current as T;
  }

  @override
  String getFormatInstructions() {
    // Combine instructions from all parsers
    return parsers
        .map((p) => p.getFormatInstructions())
        .where((i) => i.isNotEmpty)
        .join('\n\n');
  }
}
