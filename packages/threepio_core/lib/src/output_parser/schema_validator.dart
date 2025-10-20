import '../schema/tool_info.dart';

/// Validates JSON data against JSON Schema
///
/// **Framework Sources:**
/// - **JSON Schema**: Validation specification
/// - **OpenAI**: Structured outputs validation
///
/// This validator checks:
/// - Required fields are present
/// - Field types match schema
/// - Enum values are valid
/// - Nested objects and arrays conform to schema
///
/// Example:
/// ```dart
/// final schema = JSONSchema(
///   properties: {
///     'name': JSONSchemaProperty.string(description: 'Name'),
///     'age': JSONSchemaProperty.number(description: 'Age'),
///   },
///   required: ['name'],
/// );
///
/// final validator = SchemaValidator(schema);
/// final errors = validator.validate({'name': 'John', 'age': 30});
/// if (errors.isEmpty) {
///   print('Valid!');
/// }
/// ```
class SchemaValidator {
  SchemaValidator(this.schema);

  final JSONSchema schema;

  /// Validate JSON data against the schema
  ///
  /// Returns a list of validation errors. Empty list means valid.
  List<String> validate(Map<String, dynamic> data) {
    final errors = <String>[];

    // Check required fields
    for (final requiredField in schema.required) {
      if (!data.containsKey(requiredField)) {
        errors.add('Missing required field: $requiredField');
      }
    }

    // Validate each property
    for (final entry in data.entries) {
      final fieldName = entry.key;
      final fieldValue = entry.value;

      // Check if field is defined in schema
      if (!schema.properties.containsKey(fieldName)) {
        if (!schema.additionalProperties) {
          errors.add('Unexpected field: $fieldName');
        }
        continue;
      }

      // Validate field value
      final property = schema.properties[fieldName]!;
      final fieldErrors = _validateProperty(fieldName, fieldValue, property);
      errors.addAll(fieldErrors);
    }

    return errors;
  }

  /// Validate a single property
  List<String> _validateProperty(
    String fieldName,
    dynamic value,
    JSONSchemaProperty property,
  ) {
    final errors = <String>[];

    // Check null values
    if (value == null) {
      errors.add('Field $fieldName cannot be null');
      return errors;
    }

    // Validate type
    final typeError = _validateType(fieldName, value, property.type);
    if (typeError != null) {
      errors.add(typeError);
      return errors; // Don't continue if type is wrong
    }

    // Validate enum values
    if (property.enumValues != null && property.enumValues!.isNotEmpty) {
      if (!property.enumValues!.contains(value)) {
        errors.add(
          'Field $fieldName must be one of ${property.enumValues}, got: $value',
        );
      }
    }

    // Validate array items
    if (property.type == 'array' && property.items != null && value is List) {
      for (var i = 0; i < value.length; i++) {
        final itemErrors =
            _validateProperty('$fieldName[$i]', value[i], property.items!);
        errors.addAll(itemErrors);
      }
    }

    // Validate object properties
    if (property.type == 'object' &&
        property.properties != null &&
        value is Map<String, dynamic>) {
      // Check required fields in nested object
      if (property.required != null) {
        for (final requiredField in property.required!) {
          if (!value.containsKey(requiredField)) {
            errors.add('Missing required field in $fieldName: $requiredField');
          }
        }
      }

      // Validate nested properties
      for (final entry in value.entries) {
        final nestedFieldName = entry.key;
        final nestedValue = entry.value;

        if (property.properties!.containsKey(nestedFieldName)) {
          final nestedProperty = property.properties![nestedFieldName]!;
          final nestedErrors = _validateProperty(
            '$fieldName.$nestedFieldName',
            nestedValue,
            nestedProperty,
          );
          errors.addAll(nestedErrors);
        } else if (property.additionalProperties == false) {
          errors.add('Unexpected field in $fieldName: $nestedFieldName');
        }
      }
    }

    return errors;
  }

  /// Validate that value matches expected type
  String? _validateType(String fieldName, dynamic value, String expectedType) {
    switch (expectedType) {
      case 'string':
        if (value is! String) {
          return 'Field $fieldName must be string, got ${value.runtimeType}';
        }
        break;

      case 'number':
        if (value is! num) {
          return 'Field $fieldName must be number, got ${value.runtimeType}';
        }
        break;

      case 'integer':
        if (value is! int) {
          return 'Field $fieldName must be integer, got ${value.runtimeType}';
        }
        break;

      case 'boolean':
        if (value is! bool) {
          return 'Field $fieldName must be boolean, got ${value.runtimeType}';
        }
        break;

      case 'array':
        if (value is! List) {
          return 'Field $fieldName must be array, got ${value.runtimeType}';
        }
        break;

      case 'object':
        if (value is! Map) {
          return 'Field $fieldName must be object, got ${value.runtimeType}';
        }
        break;

      case 'null':
        if (value != null) {
          return 'Field $fieldName must be null, got ${value.runtimeType}';
        }
        break;

      default:
        // Unknown type, skip validation
        break;
    }

    return null;
  }

  /// Validate and return detailed validation result
  ValidationResult validateDetailed(Map<String, dynamic> data) {
    final errors = validate(data);
    return ValidationResult(
      isValid: errors.isEmpty,
      errors: errors,
      data: data,
    );
  }
}

/// Result of schema validation
class ValidationResult {
  const ValidationResult({
    required this.isValid,
    required this.errors,
    required this.data,
  });

  /// Whether the data is valid
  final bool isValid;

  /// List of validation errors
  final List<String> errors;

  /// The validated data
  final Map<String, dynamic> data;

  /// Get a formatted error message
  String get errorMessage => errors.join('\n');

  @override
  String toString() {
    if (isValid) {
      return 'ValidationResult(valid)';
    }
    return 'ValidationResult(invalid: ${errors.length} errors)';
  }
}

/// Exception thrown when validation fails
class ValidationException implements Exception {
  ValidationException(this.result);

  final ValidationResult result;

  @override
  String toString() {
    return 'ValidationException: ${result.errorMessage}';
  }
}
