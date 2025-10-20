import 'dart:convert';

import '../schema/tool_info.dart';
import 'json_output_parser.dart';
import 'output_parser.dart';

/// Parser for enum values
///
/// **Framework Source: LangChain** - EnumOutputParser pattern
///
/// Extracts enum values from LLM output with automatic normalization.
///
/// Example:
/// ```dart
/// enum Sentiment { positive, negative, neutral }
///
/// final parser = EnumOutputParser<Sentiment>(
///   enumValues: Sentiment.values,
///   enumName: 'Sentiment',
/// );
///
/// // Handles various formats:
/// final result1 = await parser.parse('positive'); // Sentiment.positive
/// final result2 = await parser.parse('POSITIVE'); // Sentiment.positive
/// final result3 = await parser.parse('Sentiment.positive'); // Sentiment.positive
/// ```
class EnumOutputParser<T extends Enum> extends OutputParser<T> {
  EnumOutputParser({
    required this.enumValues,
    required this.enumName,
    this.caseSensitive = false,
  });

  final List<T> enumValues;
  final String enumName;
  final bool caseSensitive;

  @override
  Future<T> parse(String text) async {
    final cleaned = text.trim();

    // Remove enum prefix if present (e.g., "Sentiment.positive" -> "positive")
    final withoutPrefix = cleaned.replaceFirst('$enumName.', '');

    // Try to match enum value
    for (final value in enumValues) {
      final valueName = value.name;

      if (caseSensitive) {
        if (withoutPrefix == valueName) {
          return value;
        }
      } else {
        if (withoutPrefix.toLowerCase() == valueName.toLowerCase()) {
          return value;
        }
      }
    }

    throw OutputParserException(
      'Invalid $enumName value: $text. Must be one of: ${enumValues.map((e) => e.name).join(", ")}',
      output: text,
      sendToLLM: true,
    );
  }

  @override
  String getFormatInstructions() {
    return '''Respond with one of the following $enumName values:
${enumValues.map((e) => '- ${e.name}').join('\n')}

Respond with just the value name, nothing else.''';
  }
}

/// Parser for boolean values with flexible input
///
/// Handles various representations of boolean values.
///
/// Example:
/// ```dart
/// final parser = BooleanOutputParser();
/// final result1 = await parser.parse('yes'); // true
/// final result2 = await parser.parse('NO'); // false
/// final result3 = await parser.parse('true'); // true
/// ```
class BooleanOutputParser extends OutputParser<bool> {
  BooleanOutputParser({
    this.trueValues = const ['true', 'yes', 'y', '1', 'correct', 'right'],
    this.falseValues = const ['false', 'no', 'n', '0', 'incorrect', 'wrong'],
  });

  final List<String> trueValues;
  final List<String> falseValues;

  @override
  Future<bool> parse(String text) async {
    final cleaned = text.trim().toLowerCase();

    if (trueValues.contains(cleaned)) {
      return true;
    }

    if (falseValues.contains(cleaned)) {
      return false;
    }

    throw OutputParserException(
      'Cannot parse boolean from: $text. Expected one of: ${[
        ...trueValues,
        ...falseValues
      ].join(", ")}',
      output: text,
      sendToLLM: true,
    );
  }

  @override
  String getFormatInstructions() {
    return '''Respond with a boolean value:
- True: ${trueValues.take(3).join(", ")}
- False: ${falseValues.take(3).join(", ")}''';
  }
}

/// Parser for numeric values with optional bounds
///
/// Example:
/// ```dart
/// final parser = NumberOutputParser(min: 0, max: 100);
/// final result = await parser.parse('42'); // 42
/// ```
class NumberOutputParser extends OutputParser<num> {
  NumberOutputParser({
    this.min,
    this.max,
    this.allowDecimals = true,
  });

  final num? min;
  final num? max;
  final bool allowDecimals;

  @override
  Future<num> parse(String text) async {
    final cleaned = text.trim();

    // Try to parse number
    final number = num.tryParse(cleaned);
    if (number == null) {
      throw OutputParserException(
        'Cannot parse number from: $text',
        output: text,
        sendToLLM: true,
      );
    }

    // Check if decimals are allowed
    if (!allowDecimals && number != number.toInt()) {
      throw OutputParserException(
        'Decimal values not allowed, got: $number',
        output: text,
        sendToLLM: true,
      );
    }

    // Check bounds
    if (min != null && number < min!) {
      throw OutputParserException(
        'Number $number is below minimum $min',
        output: text,
        sendToLLM: true,
      );
    }

    if (max != null && number > max!) {
      throw OutputParserException(
        'Number $number is above maximum $max',
        output: text,
        sendToLLM: true,
      );
    }

    return number;
  }

  @override
  String getFormatInstructions() {
    final buffer = StringBuffer();
    buffer.write('Respond with a numeric value');

    if (!allowDecimals) {
      buffer.write(' (integer only)');
    }

    if (min != null && max != null) {
      buffer.write(' between $min and $max');
    } else if (min != null) {
      buffer.write(' greater than or equal to $min');
    } else if (max != null) {
      buffer.write(' less than or equal to $max');
    }

    buffer.write('.');
    return buffer.toString();
  }
}

/// Pydantic-style structured output parser
///
/// **Framework Sources:**
/// - **LangChain**: PydanticOutputParser
/// - **Instructor**: Structured extraction patterns
/// - **Pydantic**: Schema-based validation
///
/// This parser combines JSON parsing, schema validation, and
/// transformation into type-safe Dart objects.
///
/// Example:
/// ```dart
/// // Define your schema
/// final schema = JSONSchema(
///   properties: {
///     'name': JSONSchemaProperty.string(description: 'Person name'),
///     'age': JSONSchemaProperty.number(description: 'Person age'),
///     'email': JSONSchemaProperty.string(description: 'Email address'),
///   },
///   required: ['name', 'age'],
/// );
///
/// // Create parser with transformer
/// final parser = PydanticOutputParser<Person>(
///   schema: schema,
///   fromJson: (json) => Person.fromJson(json),
/// );
///
/// // Parse LLM output into type-safe object
/// final person = await parser.parse(llmOutput);
/// print(person.name); // Type-safe access
/// ```
class PydanticOutputParser<T> extends OutputParser<T> {
  PydanticOutputParser({
    required this.schema,
    required this.fromJson,
    this.includeSchema = true,
  }) : _jsonParser = JsonOutputParser(schema: schema);

  final JSONSchema schema;
  final T Function(Map<String, dynamic>) fromJson;
  final bool includeSchema;

  final JsonOutputParser _jsonParser;

  @override
  Future<T> parse(String text) async {
    final json = await _jsonParser.parse(text);
    try {
      return fromJson(json);
    } catch (e) {
      throw OutputParserException(
        'Failed to transform JSON to ${T.toString()}: $e',
        output: jsonEncode(json),
      );
    }
  }

  @override
  String getFormatInstructions() {
    final buffer = StringBuffer();
    buffer.writeln(
        'Respond with valid JSON matching this ${T.toString()} schema:');
    buffer.writeln();

    if (includeSchema) {
      buffer.writeln('```json');
      buffer.writeln(jsonEncode(_schemaToExample(schema)));
      buffer.writeln('```');
      buffer.writeln();
    }

    buffer.writeln('Field requirements:');
    for (final entry in schema.properties.entries) {
      final name = entry.key;
      final prop = entry.value;
      final required = schema.required.contains(name);

      buffer.write('- $name (${prop.type})');
      if (required) {
        buffer.write(' [REQUIRED]');
      }
      if (prop.description != null) {
        buffer.write(': ${prop.description}');
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  Map<String, dynamic> _schemaToExample(JSONSchema schema) {
    final example = <String, dynamic>{};
    for (final entry in schema.properties.entries) {
      example[entry.key] = _propertyToExample(entry.value);
    }
    return example;
  }

  dynamic _propertyToExample(JSONSchemaProperty property) {
    switch (property.type) {
      case 'string':
        return property.enumValues?.first ?? 'example_string';
      case 'number':
      case 'integer':
        return 0;
      case 'boolean':
        return false;
      case 'array':
        return property.items != null
            ? [_propertyToExample(property.items!)]
            : [];
      case 'object':
        if (property.properties != null) {
          final obj = <String, dynamic>{};
          for (final entry in property.properties!.entries) {
            obj[entry.key] = _propertyToExample(entry.value);
          }
          return obj;
        }
        return {};
      default:
        return null;
    }
  }
}

/// Regex-based output parser
///
/// Extracts structured data using regular expressions.
///
/// Example:
/// ```dart
/// final parser = RegexOutputParser(
///   pattern: r'Answer: (.+)',
///   outputKeys: ['answer'],
/// );
///
/// final result = await parser.parse('Answer: 42');
/// print(result['answer']); // '42'
/// ```
class RegexOutputParser extends OutputParser<Map<String, String>> {
  RegexOutputParser({
    required String pattern,
    required this.outputKeys,
    this.dotAll = false,
  }) : _regex = RegExp(pattern, dotAll: dotAll);

  final RegExp _regex;
  final List<String> outputKeys;
  final bool dotAll;

  @override
  Future<Map<String, String>> parse(String text) async {
    final match = _regex.firstMatch(text);

    if (match == null) {
      throw OutputParserException(
        'Text does not match pattern: ${_regex.pattern}',
        output: text,
        sendToLLM: true,
      );
    }

    final result = <String, String>{};

    for (var i = 0; i < outputKeys.length && i < match.groupCount; i++) {
      final key = outputKeys[i];
      final value = match.group(i + 1);
      if (value != null) {
        result[key] = value;
      }
    }

    return result;
  }

  @override
  String getFormatInstructions() {
    return 'Your response should match the pattern: ${_regex.pattern}';
  }
}

/// Multi-choice output parser
///
/// Forces the LLM to choose from a predefined set of options.
///
/// Example:
/// ```dart
/// final parser = MultiChoiceOutputParser(
///   choices: ['Option A', 'Option B', 'Option C'],
/// );
///
/// final choice = await parser.parse('I choose Option B');
/// // Returns: 'Option B'
/// ```
class MultiChoiceOutputParser extends OutputParser<String> {
  MultiChoiceOutputParser({
    required this.choices,
    this.caseSensitive = false,
  });

  final List<String> choices;
  final bool caseSensitive;

  @override
  Future<String> parse(String text) async {
    final cleaned = text.trim();

    for (final choice in choices) {
      if (caseSensitive) {
        if (cleaned.contains(choice)) {
          return choice;
        }
      } else {
        if (cleaned.toLowerCase().contains(choice.toLowerCase())) {
          return choice;
        }
      }
    }

    throw OutputParserException(
      'Could not find any of the valid choices in the output. Valid choices: ${choices.join(", ")}',
      output: text,
      sendToLLM: true,
    );
  }

  @override
  String getFormatInstructions() {
    return '''Choose exactly ONE of the following options:

${choices.map((c) => '- $c').join('\n')}

Include your chosen option in your response.''';
  }
}
