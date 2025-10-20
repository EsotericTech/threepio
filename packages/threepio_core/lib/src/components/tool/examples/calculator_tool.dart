import 'dart:convert';

import 'package:threepio_core/src/schema/tool_info.dart';

import '../invokable_tool.dart';

/// A simple calculator tool for basic arithmetic operations
///
/// Supports addition, subtraction, multiplication, and division.
///
/// Example usage:
/// ```dart
/// final calc = CalculatorTool();
/// final result = await calc.run('{"operation": "add", "a": 5, "b": 3}');
/// print(result); // {"result": 8}
/// ```
class CalculatorTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async {
    return ToolInfo(
      function: FunctionInfo(
        name: 'calculator',
        description:
            'Performs basic arithmetic operations: add, subtract, multiply, divide',
        parameters: JSONSchema(
          type: 'object',
          properties: {
            'operation': JSONSchemaProperty(
              type: 'string',
              description: 'The operation to perform',
              enumValues: ['add', 'subtract', 'multiply', 'divide'],
            ),
            'a': JSONSchemaProperty(
              type: 'number',
              description: 'First number',
            ),
            'b': JSONSchemaProperty(
              type: 'number',
              description: 'Second number',
            ),
          },
          required: ['operation', 'a', 'b'],
          additionalProperties: false,
        ),
      ),
    );
  }

  @override
  Future<String> run(String argumentsJson) async {
    final args = jsonDecode(argumentsJson) as Map<String, dynamic>;

    final operation = args['operation'] as String;
    final a = (args['a'] as num).toDouble();
    final b = (args['b'] as num).toDouble();

    double result;
    switch (operation) {
      case 'add':
        result = a + b;
        break;
      case 'subtract':
        result = a - b;
        break;
      case 'multiply':
        result = a * b;
        break;
      case 'divide':
        if (b == 0) {
          throw ArgumentError('Cannot divide by zero');
        }
        result = a / b;
        break;
      default:
        throw ArgumentError('Unknown operation: $operation');
    }

    return jsonEncode({'result': result});
  }
}
