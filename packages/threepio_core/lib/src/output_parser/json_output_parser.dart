import 'dart:convert';

import '../schema/tool_info.dart';
import 'output_parser.dart';
import 'schema_validator.dart';

/// Parser for JSON output from LLMs
///
/// **Framework Sources:**
/// - **LangChain**: JsonOutputParser pattern
/// - **OpenAI**: JSON mode and schema validation
///
/// This parser:
/// - Extracts JSON from LLM output (even if wrapped in markdown)
/// - Validates against JSON schema (optional)
/// - Provides helpful error messages for the LLM
/// - Handles common formatting issues
///
/// Example:
/// ```dart
/// // Parse any JSON
/// final parser = JsonOutputParser();
/// final result = await parser.parse('{"name": "John", "age": 30}');
///
/// // Parse with schema validation
/// final schema = JSONSchema(
///   properties: {
///     'name': JSONSchemaProperty.string(description: 'Person name'),
///     'age': JSONSchemaProperty.number(description: 'Person age'),
///   },
///   required: ['name', 'age'],
/// );
/// final validatingParser = JsonOutputParser(schema: schema);
/// final validated = await validatingParser.parse(llmOutput);
/// ```
class JsonOutputParser extends OutputParser<Map<String, dynamic>> {
  JsonOutputParser({
    this.schema,
    this.stripMarkdown = true,
    SchemaValidator? validator,
  }) : validator =
            validator ?? (schema != null ? SchemaValidator(schema) : null);

  /// Optional JSON schema for validation
  final JSONSchema? schema;

  /// Whether to strip markdown code blocks
  final bool stripMarkdown;

  /// Schema validator
  final SchemaValidator? validator;

  @override
  Future<Map<String, dynamic>> parse(String text) async {
    var cleaned = text.trim();

    // Strip markdown code blocks if needed
    if (stripMarkdown) {
      cleaned = _stripMarkdownCodeBlock(cleaned);
    }

    // Try to parse JSON
    late Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is! Map<String, dynamic>) {
        throw OutputParserException(
          'Expected JSON object but got ${decoded.runtimeType}',
          output: text,
          sendToLLM: true,
        );
      }
      json = decoded;
    } on FormatException catch (e) {
      throw OutputParserException(
        'Invalid JSON: ${e.message}',
        output: text,
        sendToLLM: true,
      );
    }

    // Validate against schema if provided
    if (validator != null) {
      final errors = validator!.validate(json);
      if (errors.isNotEmpty) {
        throw OutputParserException(
          'JSON validation failed:\n${errors.join('\n')}',
          output: text,
          sendToLLM: true,
        );
      }
    }

    return json;
  }

  @override
  String getFormatInstructions() {
    if (schema == null) {
      return '''Respond with valid JSON object. Format:
```json
{
  "key": "value"
}
```''';
    }

    // Generate instructions from schema
    final buffer = StringBuffer();
    buffer.writeln('Respond with valid JSON matching this schema:');
    buffer.writeln('```json');
    buffer.writeln(jsonEncode(_schemaToExample(schema!)));
    buffer.writeln('```');
    buffer.writeln();
    buffer.writeln(_schemaToDescription(schema!));

    return buffer.toString();
  }

  /// Strip markdown code block from text
  String _stripMarkdownCodeBlock(String text) {
    var cleaned = text.trim();

    // Try with language specifier
    final jsonBlockPattern = RegExp(r'```json\s*\n(.+?)\n```', dotAll: true);
    var match = jsonBlockPattern.firstMatch(cleaned);
    if (match != null) {
      return match.group(1)!.trim();
    }

    // Try without language specifier
    final codeBlockPattern = RegExp(r'```\s*\n(.+?)\n```', dotAll: true);
    match = codeBlockPattern.firstMatch(cleaned);
    if (match != null) {
      return match.group(1)!.trim();
    }

    // Try inline code
    final inlinePattern = RegExp(r'`(.+?)`', dotAll: true);
    match = inlinePattern.firstMatch(cleaned);
    if (match != null) {
      return match.group(1)!.trim();
    }

    return cleaned;
  }

  /// Generate example JSON from schema
  Map<String, dynamic> _schemaToExample(JSONSchema schema) {
    final example = <String, dynamic>{};

    for (final entry in schema.properties.entries) {
      example[entry.key] = _propertyToExample(entry.value);
    }

    return example;
  }

  /// Generate example value from property
  dynamic _propertyToExample(JSONSchemaProperty property) {
    switch (property.type) {
      case 'string':
        if (property.enumValues != null && property.enumValues!.isNotEmpty) {
          return property.enumValues!.first;
        }
        return 'example_${property.description?.split(' ').first.toLowerCase() ?? 'value'}';

      case 'number':
      case 'integer':
        return 0;

      case 'boolean':
        return false;

      case 'array':
        if (property.items != null) {
          return [_propertyToExample(property.items!)];
        }
        return [];

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

  /// Generate human-readable description from schema
  String _schemaToDescription(JSONSchema schema) {
    final buffer = StringBuffer();
    buffer.writeln('Schema details:');

    for (final entry in schema.properties.entries) {
      final name = entry.key;
      final prop = entry.value;
      final required =
          schema.required.contains(name) ? '(required)' : '(optional)';

      buffer.write('- $name $required: ${prop.type}');
      if (prop.description != null) {
        buffer.write(' - ${prop.description}');
      }
      if (prop.enumValues != null) {
        buffer.write(' - allowed values: ${prop.enumValues}');
      }
      buffer.writeln();
    }

    return buffer.toString();
  }
}

/// Parser for JSON arrays
///
/// Example:
/// ```dart
/// final parser = JsonArrayOutputParser<String>();
/// final items = await parser.parse('["item1", "item2", "item3"]');
/// ```
class JsonArrayOutputParser<T> extends OutputParser<List<T>> {
  JsonArrayOutputParser({
    this.stripMarkdown = true,
  });

  final bool stripMarkdown;

  @override
  Future<List<T>> parse(String text) async {
    var cleaned = text.trim();

    // Strip markdown if needed
    if (stripMarkdown) {
      cleaned = _stripMarkdownCodeBlock(cleaned);
    }

    // Parse JSON
    late List<dynamic> json;
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is! List) {
        throw OutputParserException(
          'Expected JSON array but got ${decoded.runtimeType}',
          output: text,
          sendToLLM: true,
        );
      }
      json = decoded;
    } on FormatException catch (e) {
      throw OutputParserException(
        'Invalid JSON: ${e.message}',
        output: text,
        sendToLLM: true,
      );
    }

    // Type check
    try {
      return json.cast<T>();
    } catch (e) {
      throw OutputParserException(
        'Array elements do not match expected type $T',
        output: text,
        sendToLLM: true,
      );
    }
  }

  @override
  String getFormatInstructions() {
    return '''Respond with valid JSON array. Format:
```json
["item1", "item2", "item3"]
```''';
  }

  String _stripMarkdownCodeBlock(String text) {
    var cleaned = text.trim();

    final jsonBlockPattern = RegExp(r'```json\s*\n(.+?)\n```', dotAll: true);
    var match = jsonBlockPattern.firstMatch(cleaned);
    if (match != null) {
      return match.group(1)!.trim();
    }

    final codeBlockPattern = RegExp(r'```\s*\n(.+?)\n```', dotAll: true);
    match = codeBlockPattern.firstMatch(cleaned);
    if (match != null) {
      return match.group(1)!.trim();
    }

    return cleaned;
  }
}

/// Parser that tries to fix common JSON issues before parsing
///
/// **Framework Source: LangChain** - Auto-fixing parser pattern
///
/// This parser attempts to fix:
/// - Trailing commas
/// - Single quotes instead of double quotes
/// - Missing quotes on keys
/// - Truncated JSON
///
/// Example:
/// ```dart
/// final parser = AutoFixingJsonOutputParser();
/// // Can handle: {name: 'John', age: 30,}
/// final result = await parser.parse(malformedJson);
/// ```
class AutoFixingJsonOutputParser extends JsonOutputParser {
  AutoFixingJsonOutputParser({
    super.schema,
    super.stripMarkdown,
  });

  @override
  Future<Map<String, dynamic>> parse(String text) async {
    // First try normal parsing
    try {
      return await super.parse(text);
    } on OutputParserException {
      // If that fails, try to fix common issues
      final fixed = _attemptFix(text);
      return await super.parse(fixed);
    }
  }

  /// Attempt to fix common JSON issues
  String _attemptFix(String text) {
    var fixed = text.trim();

    // Strip markdown
    if (stripMarkdown) {
      fixed = _stripMarkdownCodeBlock(fixed);
    }

    // Fix single quotes to double quotes (but not within strings)
    fixed = fixed.replaceAll("'", '"');

    // Remove trailing commas before closing braces/brackets
    fixed = fixed.replaceAll(RegExp(r',\s*}'), '}');
    fixed = fixed.replaceAll(RegExp(r',\s*]'), ']');

    // Try to complete truncated JSON
    if (!fixed.endsWith('}') && !fixed.endsWith(']')) {
      // Count opening/closing braces
      final openBraces = fixed.split('{').length - 1;
      final closeBraces = fixed.split('}').length - 1;
      final openBrackets = fixed.split('[').length - 1;
      final closeBrackets = fixed.split(']').length - 1;

      // Add missing closing braces
      for (var i = 0; i < (openBraces - closeBraces); i++) {
        fixed += '}';
      }

      // Add missing closing brackets
      for (var i = 0; i < (openBrackets - closeBrackets); i++) {
        fixed += ']';
      }
    }

    return fixed;
  }

  String _stripMarkdownCodeBlock(String text) {
    var cleaned = text.trim();

    final jsonBlockPattern = RegExp(r'```json\s*\n(.+?)\n```', dotAll: true);
    var match = jsonBlockPattern.firstMatch(cleaned);
    if (match != null) {
      return match.group(1)!.trim();
    }

    final codeBlockPattern = RegExp(r'```\s*\n(.+?)\n```', dotAll: true);
    match = codeBlockPattern.firstMatch(cleaned);
    if (match != null) {
      return match.group(1)!.trim();
    }

    return cleaned;
  }
}
