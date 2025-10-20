import 'package:test/test.dart';
import 'package:threepio_core/src/components/prompt/prompt_template.dart';

void main() {
  group('PromptTemplate', () {
    test('formats template with variables', () {
      final template = PromptTemplate(
        template: 'Hello {name}, welcome to {place}!',
        inputVariables: ['name', 'place'],
      );

      final result = template.format({
        'name': 'Alice',
        'place': 'Wonderland',
      });

      expect(result, equals('Hello Alice, welcome to Wonderland!'));
    });

    test('throws on missing required variable', () {
      final template = PromptTemplate(
        template: 'Hello {name}!',
        inputVariables: ['name'],
      );

      expect(
        () => template.format({}),
        throwsArgumentError,
      );
    });

    test('handles multiple occurrences of same variable', () {
      final template = PromptTemplate(
        template: '{name} said "{name}"',
        inputVariables: ['name'],
      );

      final result = template.format({'name': 'Bob'});
      expect(result, equals('Bob said "Bob"'));
    });

    test('handles empty variables', () {
      final template = PromptTemplate(
        template: 'Hello {name}!',
        inputVariables: ['name'],
        validateTemplate: false,
      );

      final result = template.format({'name': ''});
      expect(result, equals('Hello !'));
    });

    test('partial variables work', () {
      final template = PromptTemplate(
        template: '{greeting} {name}!',
        inputVariables: ['greeting', 'name'],
        partialVariables: {'greeting': 'Hello'},
      );

      final result = template.format({'name': 'World'});
      expect(result, equals('Hello World!'));
    });

    test('partial() creates new template with preset variables', () {
      final template = PromptTemplate(
        template: '{greeting} {name}!',
        inputVariables: ['greeting', 'name'],
      );

      final partial = template.partial({'greeting': 'Hi'});

      expect(partial.inputVariables, equals(['name']));
      expect(partial.format({'name': 'There'}), equals('Hi There!'));
    });

    test('extractVariables finds all variables', () {
      final vars = PromptTemplate.extractVariables(
        'Hello {name}, you are {age} years old. Welcome {name}!',
      );

      expect(vars, hasLength(2));
      expect(vars, contains('name'));
      expect(vars, contains('age'));
    });

    test('fromTemplate auto-extracts variables', () {
      final template = PromptTemplate.fromTemplate(
        'Tell me about {topic} in {style} style.',
      );

      expect(template.inputVariables, hasLength(2));
      expect(template.inputVariables, contains('topic'));
      expect(template.inputVariables, contains('style'));

      final result = template.format({
        'topic': 'AI',
        'style': 'simple',
      });

      expect(result, equals('Tell me about AI in simple style.'));
    });

    test('formatAsync works', () async {
      final template = PromptTemplate.fromTemplate('Hello {name}!');
      final result = await template.formatAsync({'name': 'Async'});
      expect(result, equals('Hello Async!'));
    });

    test('handles null values', () {
      final template = PromptTemplate(
        template: 'Value: {value}',
        inputVariables: ['value'],
      );

      final result = template.format({'value': null});
      expect(result, equals('Value: '));
    });

    test('handles numeric values', () {
      final template = PromptTemplate(
        template: 'Count: {count}',
        inputVariables: ['count'],
      );

      final result = template.format({'count': 42});
      expect(result, equals('Count: 42'));
    });

    test('validates template when enabled', () {
      final template = PromptTemplate(
        template: 'Hello {name}!',
        inputVariables: ['name', 'extra'],
        validateTemplate: true,
      );

      expect(
        () => template.format({'name': 'Alice'}),
        throwsArgumentError,
      );
    });

    test('skips validation when disabled', () {
      final template = PromptTemplate(
        template: 'Hello {name}!',
        inputVariables: ['name', 'extra'],
        validateTemplate: false,
      );

      final result = template.format({'name': 'Alice'});
      expect(result, equals('Hello Alice!'));
    });
  });
}
