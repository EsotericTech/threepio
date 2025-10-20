import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/examples/calculator_tool.dart';

void main() {
  group('CalculatorTool', () {
    late CalculatorTool calculator;

    setUp(() {
      calculator = CalculatorTool();
    });

    test('has correct tool info', () async {
      final info = await calculator.info();

      expect(info.function.name, equals('calculator'));
      expect(info.function.description, isNotEmpty);
      expect(info.function.parameters, isNotNull);
      expect(info.function.parameters!.required, contains('operation'));
      expect(info.function.parameters!.required, contains('a'));
      expect(info.function.parameters!.required, contains('b'));
    });

    test('adds two numbers correctly', () async {
      final args = jsonEncode({'operation': 'add', 'a': 5, 'b': 3});
      final result = await calculator.run(args);
      final output = jsonDecode(result) as Map<String, dynamic>;

      expect(output['result'], equals(8));
    });

    test('subtracts two numbers correctly', () async {
      final args = jsonEncode({'operation': 'subtract', 'a': 10, 'b': 4});
      final result = await calculator.run(args);
      final output = jsonDecode(result) as Map<String, dynamic>;

      expect(output['result'], equals(6));
    });

    test('multiplies two numbers correctly', () async {
      final args = jsonEncode({'operation': 'multiply', 'a': 6, 'b': 7});
      final result = await calculator.run(args);
      final output = jsonDecode(result) as Map<String, dynamic>;

      expect(output['result'], equals(42));
    });

    test('divides two numbers correctly', () async {
      final args = jsonEncode({'operation': 'divide', 'a': 15, 'b': 3});
      final result = await calculator.run(args);
      final output = jsonDecode(result) as Map<String, dynamic>;

      expect(output['result'], equals(5));
    });

    test('handles decimal numbers', () async {
      final args = jsonEncode({'operation': 'multiply', 'a': 2.5, 'b': 4});
      final result = await calculator.run(args);
      final output = jsonDecode(result) as Map<String, dynamic>;

      expect(output['result'], equals(10));
    });

    test('throws on division by zero', () async {
      final args = jsonEncode({'operation': 'divide', 'a': 10, 'b': 0});

      expect(
        () => calculator.run(args),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on unknown operation', () async {
      final args = jsonEncode({'operation': 'modulo', 'a': 10, 'b': 3});

      expect(
        () => calculator.run(args),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
