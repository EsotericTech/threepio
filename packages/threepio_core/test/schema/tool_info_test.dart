import 'package:test/test.dart';
import 'package:threepio_core/src/schema/tool_info.dart';

void main() {
  group('JSONSchemaProperty', () {
    test('creates string property', () {
      final prop = JSONSchemaProperty.string(description: 'A string');
      expect(prop.type, 'string');
      expect(prop.description, 'A string');
    });

    test('creates number property', () {
      final prop = JSONSchemaProperty.number(description: 'A number');
      expect(prop.type, 'number');
      expect(prop.description, 'A number');
    });

    test('creates boolean property', () {
      final prop = JSONSchemaProperty.boolean(description: 'A boolean');
      expect(prop.type, 'boolean');
      expect(prop.description, 'A boolean');
    });

    test('creates array property', () {
      final prop = JSONSchemaProperty.array(
        description: 'An array',
        items: JSONSchemaProperty.string(),
      );
      expect(prop.type, 'array');
      expect(prop.items?.type, 'string');
    });

    test('creates object property', () {
      final prop = JSONSchemaProperty.object(
        description: 'An object',
        properties: {
          'name': JSONSchemaProperty.string(),
          'age': JSONSchemaProperty.number(),
        },
        required: ['name'],
      );
      expect(prop.type, 'object');
      expect(prop.properties?.length, 2);
      expect(prop.required, ['name']);
    });

    test('serializes and deserializes correctly', () {
      final original = JSONSchemaProperty.string(
        description: 'Test',
        enumValues: ['a', 'b'],
      );
      final json = original.toJson();
      final deserialized = JSONSchemaProperty.fromJson(json);

      expect(deserialized.type, original.type);
      expect(deserialized.description, original.description);
      expect(deserialized.enumValues, original.enumValues);
    });
  });

  group('ToolInfo', () {
    test('creates function tool', () {
      final tool = ToolInfo.function(
        name: 'get_weather',
        description: 'Get the weather',
      );
      expect(tool.type, 'function');
      expect(tool.function.name, 'get_weather');
      expect(tool.function.description, 'Get the weather');
    });

    test('creates simple tool with parameters', () {
      final tool = ToolInfo.simple(
        name: 'calculator',
        description: 'Calculate something',
        properties: {
          'expression': JSONSchemaProperty.string(
            description: 'Math expression',
          ),
        },
        required: ['expression'],
      );
      expect(tool.function.name, 'calculator');
      expect(tool.function.parameters?.properties.length, 1);
      expect(tool.function.parameters?.required, ['expression']);
    });

    test('serializes and deserializes correctly', () {
      final original = ToolInfo.simple(
        name: 'test_tool',
        description: 'Test',
        properties: {
          'param1': JSONSchemaProperty.string(),
        },
      );
      final json = original.toJson();
      final deserialized = ToolInfo.fromJson(json);

      expect(deserialized.type, original.type);
      expect(deserialized.function.name, original.function.name);
      expect(deserialized.function.description, original.function.description);
    });
  });

  group('ToolInfoBuilder', () {
    test('builds simple tool', () {
      final tool = ToolInfoBuilder()
          .name('test_tool')
          .description('A test tool')
          .addStringParam(
            'param1',
            description: 'First parameter',
            required: true,
          )
          .build();

      expect(tool.function.name, 'test_tool');
      expect(tool.function.description, 'A test tool');
      expect(tool.function.parameters?.properties.length, 1);
      expect(tool.function.parameters?.required, ['param1']);
    });

    test('adds multiple parameter types', () {
      final tool = ToolInfoBuilder()
          .name('complex_tool')
          .description('Complex tool')
          .addStringParam('str_param', description: 'String', required: true)
          .addNumberParam('num_param', description: 'Number')
          .addBooleanParam('bool_param', description: 'Boolean')
          .build();

      expect(tool.function.parameters?.properties.length, 3);
      expect(tool.function.parameters?.required, ['str_param']);
      expect(
        tool.function.parameters?.properties['str_param']?.type,
        'string',
      );
      expect(tool.function.parameters?.properties['num_param']?.type, 'number');
      expect(
        tool.function.parameters?.properties['bool_param']?.type,
        'boolean',
      );
    });

    test('adds array parameter', () {
      final tool = ToolInfoBuilder()
          .name('array_tool')
          .description('Has array')
          .addArrayParam(
            'items',
            description: 'List of items',
            items: JSONSchemaProperty.string(),
            required: true,
          )
          .build();

      expect(tool.function.parameters?.properties['items']?.type, 'array');
      expect(tool.function.parameters?.required, ['items']);
    });

    test('adds object parameter', () {
      final tool = ToolInfoBuilder()
          .name('object_tool')
          .description('Has object')
          .addObjectParam(
        'config',
        description: 'Configuration',
        properties: {
          'host': JSONSchemaProperty.string(),
          'port': JSONSchemaProperty.number(),
        },
        requiredFields: ['host'],
      ).build();

      expect(tool.function.parameters?.properties['config']?.type, 'object');
      expect(
        tool.function.parameters?.properties['config']?.properties?.length,
        2,
      );
    });

    test('throws if name not set', () {
      expect(
        () => ToolInfoBuilder().description('No name').build(),
        throwsStateError,
      );
    });

    test('adds enum values', () {
      final tool = ToolInfoBuilder()
          .name('enum_tool')
          .description('Has enum')
          .addStringParam(
        'color',
        description: 'Color choice',
        enumValues: ['red', 'green', 'blue'],
      ).build();

      expect(
        tool.function.parameters?.properties['color']?.enumValues,
        ['red', 'green', 'blue'],
      );
    });
  });
}
