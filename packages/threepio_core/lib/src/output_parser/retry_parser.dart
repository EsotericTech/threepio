import '../components/model/base_chat_model.dart';
import '../schema/message.dart';
import 'output_parser.dart';

/// Parser that retries with LLM when parsing fails
///
/// **Framework Source: LangChain** - RetryOutputParser and OutputFixingParser
///
/// When parsing fails, this parser:
/// 1. Shows the LLM the error message
/// 2. Asks it to fix the output
/// 3. Retries parsing
///
/// This is especially useful for structured outputs where small
/// formatting mistakes can be easily corrected.
///
/// Example:
/// ```dart
/// final baseParser = JsonOutputParser(schema: mySchema);
/// final retryParser = RetryOutputParser(
///   parser: baseParser,
///   llm: chatModel,
///   maxRetries: 3,
/// );
///
/// // Will automatically retry if parsing fails
/// final result = await retryParser.parse(llmOutput);
/// ```
class RetryOutputParser<T> extends OutputParser<T> {
  RetryOutputParser({
    required this.parser,
    required this.llm,
    this.maxRetries = 2,
    this.verbose = false,
  });

  /// The underlying parser to use
  final OutputParser<T> parser;

  /// LLM to use for fixing errors
  final BaseChatModel llm;

  /// Maximum number of retry attempts
  final int maxRetries;

  /// Whether to print verbose debug output
  final bool verbose;

  @override
  Future<T> parse(String text) async {
    var currentText = text;
    var attempt = 0;

    while (attempt <= maxRetries) {
      try {
        // Try to parse
        if (verbose) {
          print('Attempt ${attempt + 1}/${maxRetries + 1}: Parsing output...');
        }

        return await parser.parse(currentText);
      } on OutputParserException catch (e) {
        // Check if we should retry
        if (!e.sendToLLM || attempt >= maxRetries) {
          if (verbose) {
            print('Max retries reached or error not retryable');
          }
          rethrow;
        }

        // Ask LLM to fix the output
        if (verbose) {
          print('Parse failed: ${e.message}');
          print('Asking LLM to fix output...');
        }

        currentText = await _retryWithLLM(text, e);
        attempt++;
      }
    }

    // Should not reach here
    throw OutputParserException(
      'Failed to parse after $maxRetries retries',
      output: currentText,
    );
  }

  /// Ask the LLM to fix the output
  Future<String> _retryWithLLM(
    String originalText,
    OutputParserException error,
  ) async {
    final fixPrompt = '''I tried to parse your output but encountered an error:

${error.message}

Your original output was:
${error.output}

Please fix the output to match the required format. Here are the format instructions:

${parser.getFormatInstructions()}

Provide ONLY the corrected output, with no additional explanation.''';

    final response = await llm.generate([Message.user(fixPrompt)]);
    return response.content;
  }

  @override
  String getFormatInstructions() {
    return parser.getFormatInstructions();
  }
}

/// Parser that fixes output using an LLM before parsing
///
/// Similar to RetryOutputParser but proactively fixes the output
/// rather than waiting for an error.
///
/// Useful when you know the output needs cleanup.
///
/// Example:
/// ```dart
/// final parser = OutputFixingParser(
///   parser: JsonOutputParser(),
///   llm: chatModel,
/// );
///
/// // LLM will clean up the output before parsing
/// final result = await parser.parse(messyOutput);
/// ```
class OutputFixingParser<T> extends OutputParser<T> {
  OutputFixingParser({
    required this.parser,
    required this.llm,
  });

  final OutputParser<T> parser;
  final BaseChatModel llm;

  @override
  Future<T> parse(String text) async {
    // First, try direct parsing
    try {
      return await parser.parse(text);
    } on OutputParserException {
      // If that fails, ask LLM to fix it
      final fixed = await _fixOutput(text);
      return await parser.parse(fixed);
    }
  }

  Future<String> _fixOutput(String text) async {
    final fixPrompt =
        '''I have some output that needs to be reformatted to match a specific format.

Output to fix:
$text

Required format:
${parser.getFormatInstructions()}

Please reformat the output to match the required format exactly. Provide ONLY the reformatted output, with no additional explanation.''';

    final response = await llm.generate([Message.user(fixPrompt)]);
    return response.content;
  }

  @override
  String getFormatInstructions() {
    return parser.getFormatInstructions();
  }
}

/// Parser that falls back to another parser if the first fails
///
/// Tries multiple parsing strategies in order.
///
/// Example:
/// ```dart
/// final parser = FallbackOutputParser([
///   JsonOutputParser(), // Try strict JSON first
///   AutoFixingJsonOutputParser(), // Then try with auto-fixing
///   StringOutputParser(), // Finally, just return the string
/// ]);
/// ```
class FallbackOutputParser<T> extends OutputParser<T> {
  FallbackOutputParser(this.parsers) : assert(parsers.isNotEmpty);

  final List<OutputParser<T>> parsers;

  @override
  Future<T> parse(String text) async {
    OutputParserException? lastError;

    for (final parser in parsers) {
      try {
        return await parser.parse(text);
      } on OutputParserException catch (e) {
        lastError = e;
        continue;
      }
    }

    // All parsers failed
    throw lastError ??
        OutputParserException(
          'All parsers failed',
          output: text,
        );
  }

  @override
  String getFormatInstructions() {
    // Use instructions from first parser
    return parsers.first.getFormatInstructions();
  }
}

/// Parser with validation callback
///
/// Allows custom validation logic after parsing.
///
/// Example:
/// ```dart
/// final parser = ValidatingOutputParser(
///   parser: NumberOutputParser(),
///   validator: (value) {
///     if (value < 0) {
///       throw OutputParserException('Number must be positive');
///     }
///   },
/// );
/// ```
class ValidatingOutputParser<T> extends OutputParser<T> {
  ValidatingOutputParser({
    required this.parser,
    required this.validator,
  });

  final OutputParser<T> parser;
  final void Function(T value) validator;

  @override
  Future<T> parse(String text) async {
    final result = await parser.parse(text);

    try {
      validator(result);
    } catch (e) {
      throw OutputParserException(
        'Validation failed: $e',
        output: text,
        sendToLLM: true,
      );
    }

    return result;
  }

  @override
  String getFormatInstructions() {
    return parser.getFormatInstructions();
  }
}

/// Parser with transformation callback
///
/// Transforms the parsed output before returning.
///
/// Example:
/// ```dart
/// final parser = TransformingOutputParser(
///   parser: StringOutputParser(),
///   transform: (value) => value.toUpperCase(),
/// );
/// ```
class TransformingOutputParser<TInput, TOutput> extends OutputParser<TOutput> {
  TransformingOutputParser({
    required this.parser,
    required this.transform,
  });

  final OutputParser<TInput> parser;
  final TOutput Function(TInput value) transform;

  @override
  Future<TOutput> parse(String text) async {
    final input = await parser.parse(text);
    try {
      return transform(input);
    } catch (e) {
      throw OutputParserException(
        'Transformation failed: $e',
        output: text,
      );
    }
  }

  @override
  String getFormatInstructions() {
    return parser.getFormatInstructions();
  }
}
