// Ports of TestParamsOneOfToJSONSchema and TestToolInfoSerialization of eino
// `schema/tool_test.go` (v0.9.22), plus the Eino-shaped side of `ToolInfo`.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

void main() {
  group('ParamsOneOf.toJsonSchema (TestParamsOneOfToJSONSchema)', () {
    test('user provides JSON schema directly, use what the user provides', () {
      const schema = JSONSchema(type: 'string');
      const oneOf = ParamsOneOf.jsonSchema(schema);

      expect(oneOf.toJsonSchema(), same(schema));
      expect(oneOf.jsonSchema, same(schema));
      expect(oneOf.params, isNull);
    });

    test('user provides ParameterInfo, converts to json schema', () {
      const oneOf = ParamsOneOf.params({
        'arg1': ParameterInfo(
          type: DataType.string,
          desc: 'this is the first argument',
          required: true,
          enumValues: ['1', '2'],
        ),
        'arg2': ParameterInfo(
          type: DataType.object,
          desc: 'this is the second argument',
          subParams: {
            'sub_arg1': ParameterInfo(
              type: DataType.string,
              desc: 'this is the sub argument',
              required: true,
              enumValues: ['1', '2'],
            ),
            'sub_arg2': ParameterInfo(
              type: DataType.string,
              desc: 'this is the sub argument 2',
            ),
          },
          required: true,
        ),
        'arg3': ParameterInfo(
          type: DataType.array,
          desc: 'this is the third argument',
          elemInfo: ParameterInfo(
            type: DataType.string,
            desc: 'this is the element of the third argument',
            required: true,
            enumValues: ['1', '2'],
          ),
          required: true,
        ),
      });

      final schema = oneOf.toJsonSchema();

      expect(schema.type, 'object');
      expect(schema.required, ['arg1', 'arg2', 'arg3']);
      expect(schema.properties.keys, ['arg1', 'arg2', 'arg3']);

      final arg1 = schema.properties['arg1']!;
      expect(arg1.type, 'string');
      expect(arg1.description, 'this is the first argument');
      expect(arg1.enumValues, ['1', '2']);

      final arg2 = schema.properties['arg2']!;
      expect(arg2.type, 'object');
      expect(arg2.properties!.keys, ['sub_arg1', 'sub_arg2']);
      expect(arg2.required, ['sub_arg1']);
      expect(arg2.properties!['sub_arg2']!.enumValues, isNull);

      final arg3 = schema.properties['arg3']!;
      expect(arg3.type, 'array');
      expect(arg3.items!.type, 'string');
      expect(arg3.items!.enumValues, ['1', '2']);
      expect(arg3.properties, isNull);

      expect(oneOf.params, hasLength(3));
      expect(oneOf.jsonSchema, isNull);
    });

    test('converts to json schema in order', () {
      const params = ParamsOneOf.params({
        'c': ParameterInfo(type: DataType.string),
        'a': ParameterInfo(
          type: DataType.object,
          subParams: {
            'z': ParameterInfo(type: DataType.number),
            'y': ParameterInfo(type: DataType.string),
          },
        ),
        'b': ParameterInfo(
          type: DataType.array,
          elemInfo: ParameterInfo(
            type: DataType.object,
            subParams: {
              'p': ParameterInfo(type: DataType.integer),
              'o': ParameterInfo(type: DataType.boolean),
            },
          ),
        ),
      });

      final json1 = jsonEncode(params.toJsonSchema().toJson());
      final json2 = jsonEncode(params.toJsonSchema().toJson());
      final schema = params.toJsonSchema();

      expect(json1, json2);
      expect(schema.properties.keys, ['a', 'b', 'c']);
      expect(schema.properties['a']!.properties!.keys, ['y', 'z']);
      expect(schema.properties['b']!.items!.properties!.keys, ['o', 'p']);
      expect(schema.required, isEmpty);
    });

    test('every data type has its JSON Schema name', () {
      expect(
        DataType.values.map((type) => type.value),
        ['object', 'number', 'integer', 'string', 'array', 'null', 'boolean'],
      );
      for (final type in DataType.values) {
        expect(DataType.parse(type.value), type);
      }
      expect(() => DataType.parse('date'), throwsFormatException);
    });
  });

  group('serialization (TestToolInfoSerialization)', () {
    final byParams = ToolInfo.fromParams(
      name: 'by_params',
      params: const {
        'a': ParameterInfo(type: DataType.string, desc: 'desc'),
      },
    );
    final bySchema = ToolInfo.fromJsonSchema(
      name: 'by_schema',
      schema: const JSONSchema(type: 'string'),
    );

    ToolInfo roundTrip(ToolInfo info) => ToolInfo.fromJson(
          jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>,
        );

    test('a tool described by parameters survives JSON', () {
      final restored = roundTrip(byParams);

      expect(restored, byParams);
      expect(restored.paramsOneOf, byParams.paramsOneOf);
      expect(
        restored.paramsOneOf!.toJsonSchema().properties['a']!.description,
        'desc',
      );
    });

    test('a tool described by a schema survives JSON', () {
      final restored = roundTrip(bySchema);

      expect(restored, bySchema);
      expect(
        restored.paramsOneOf,
        const ParamsOneOf.jsonSchema(JSONSchema(type: 'string')),
      );
    });

    test('an empty parameter map is not lost', () {
      final empty = ToolInfo.fromParams(name: 'empty', params: const {});

      final restored = roundTrip(empty);

      expect(restored, empty);
      expect(restored.paramsOneOf, isNotNull);
      expect(restored.paramsOneOf!.toJsonSchema().properties, isEmpty);
    });

    test('a tool without parameters has no ParamsOneOf', () {
      final none = ToolInfo.function(name: 'none', description: 'no input');

      expect(none.paramsOneOf, isNull);
      expect(roundTrip(none).paramsOneOf, isNull);
    });

    test('ParamsOneOf survives JSON in both forms', () {
      const params = ParamsOneOf.params({
        'a': ParameterInfo(
          type: DataType.array,
          desc: 'list',
          required: true,
          elemInfo: ParameterInfo(
            type: DataType.object,
            subParams: {
              'b': ParameterInfo(type: DataType.string, enumValues: ['x']),
            },
          ),
        ),
      });
      const schema = ParamsOneOf.jsonSchema(
        JSONSchema(
          properties: {'q': JSONSchemaProperty(type: 'string')},
          required: ['q'],
        ),
      );
      const empty = ParamsOneOf.params({});

      Object? wire(ParamsOneOf oneOf) => jsonDecode(jsonEncode(oneOf.toJson()));

      expect(
        ParamsOneOf.fromJson(wire(params)! as Map<String, Object?>),
        params,
      );
      expect(
        ParamsOneOf.fromJson(wire(schema)! as Map<String, Object?>),
        schema,
      );
      expect(
        ParamsOneOf.fromJson(wire(empty)! as Map<String, Object?>),
        empty,
      );
      expect(ParamsOneOf.fromJson(const {}).params, isEmpty);
    });

    test('ParameterInfo and ParamsOneOf have value equality', () {
      ParameterInfo info() => ParameterInfo(
            type: DataType.object,
            desc: 'd',
            enumValues: ['a'],
            subParams: {'x': ParameterInfo(type: DataType.string)},
            elemInfo: ParameterInfo(type: DataType.integer),
            required: true,
          );

      expect(info(), info());
      expect(info().hashCode, info().hashCode);
      expect(info(), isNot(ParameterInfo(type: DataType.object, desc: 'd')));
      expect(
        ParamsOneOf.params({'a': info()}),
        ParamsOneOf.params({'a': info()}),
      );
      expect(
        ParamsOneOf.params({'a': info()}).hashCode,
        ParamsOneOf.params({'a': info()}).hashCode,
      );
      expect(
        ParamsOneOf.params({'a': info()}),
        isNot(ParamsOneOf.jsonSchema(const JSONSchema())),
      );
      expect('${info()}', contains('object'));
    });
  });

  group('ToolInfo, the Eino way', () {
    test('name, desc and paramsOneOf read the OpenAI-shaped storage', () {
      final info = ToolInfo(
        function: FunctionInfo(
          name: 'get_weather',
          description: 'Current weather',
          parameters: JSONSchema(
            properties: {'city': JSONSchemaProperty.string()},
            required: const ['city'],
          ),
        ),
      );

      expect(info.name, 'get_weather');
      expect(info.desc, 'Current weather');
      expect(info.paramsOneOf!.toJsonSchema(), info.function.parameters);
      expect(info.extra, isNull);
    });

    test('fromParams stores the schema of the parameters', () {
      final info = ToolInfo.fromParams(
        name: 'get_weather',
        desc: 'Current weather',
        params: const {
          'city': ParameterInfo(type: DataType.string, required: true),
          'days': ParameterInfo(type: DataType.integer),
        },
        extra: const {'origin': 'mcp'},
      );

      expect(info.type, 'function');
      expect(info.function.name, 'get_weather');
      expect(info.function.description, 'Current weather');
      expect(info.function.parameters!.required, ['city']);
      expect(info.function.parameters!.properties.keys, ['city', 'days']);
      expect(info.extra, {'origin': 'mcp'});
    });

    test('extra survives JSON and stays out of the function', () {
      final info = ToolInfo.fromJsonSchema(
        name: 'search',
        schema: const JSONSchema(),
        extra: const {'server': 'docs'},
      );

      final json = info.toJson();
      final restored = ToolInfo.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );

      expect(restored.extra, {'server': 'docs'});
      expect(json['function'], isNot(contains('extra')));
    });

    test('JSON written before extra existed is still read', () {
      final restored = ToolInfo.fromJson(const {
        'type': 'function',
        'function': {'name': 'old'},
      });

      expect(restored.name, 'old');
      expect(restored.extra, isNull);
    });
  });

  group('ToolSearchResult', () {
    test('holds tool definitions and survives JSON', () {
      final result = ToolSearchResult(
        tools: [
          ToolInfo.fromParams(
            name: 'found',
            params: const {'q': ParameterInfo(type: DataType.string)},
          ),
        ],
      );

      final restored = ToolSearchResult.fromJson(
        jsonDecode(jsonEncode(result.toJson())) as Map<String, dynamic>,
      );

      expect(restored, result);
      expect(const ToolSearchResult().tools, isEmpty);
    });
  });
}
